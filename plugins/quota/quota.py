#!/usr/bin/python3
# -*- coding: utf-8 -*-
"""gcli（原 quota）— cc-switch 套餐限额查询（buddy Launcher command mode 插件）。

数据流：stdin PluginInput JSON → 读 ~/.cc-switch/cc-switch.db（read-only）
→ 域名分类（kimi / GLM）→ (kind, token) 去重 → 并发 fetch 各家 quota 端点
→ 解析双窗（5h 滚动 / 周窗）→ stdout 文本。

协议语义 1:1 移植自 gcli（~/workspace/honeydo/packages/gcli/src/cli.ts:548-820）：
kimi  GET {domain}/coding/v1/usages            Authorization: Bearer <token>
glm   GET {domain}/api/monitor/usage/quota/limit  Authorization: <token>（裸）

纪律：
- 恒 exit 0——所有失败走 stdout 降级文案（exit≠0 会走 pluginCrash，不可控）。
- token 只进 Authorization 头；stdout/stderr/异常消息永不包含 token。
- 畸形输入（DB 缺失 / 非 JSON / 响应畸形）一律降级不抛错（gcli 同款）。
- python3.9（/usr/bin/python3）stdlib-only，无第三方依赖。
"""

import json
import math
import os
import re
import sqlite3
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from urllib import request as _urlrequest

# 分级阈值（对齐 gcli QUOTA_HIGH / QUOTA_MID，statusline-sage 同源）
QUOTA_HIGH = 85
QUOTA_MID = 60

# 触发词（与 plugin.json keywords 同源）；query 剥词后非空才按名称过滤
TRIGGER_WORDS = ("gcli", "限额", "套餐", "用量")

REQUEST_TIMEOUT_S = 3.0   # per-request 超时（plugin timeout 15s 的内部自限）
MAX_WORKERS = 4           # 本机典型条目数 ≤4
MAX_BODY_BYTES = 1 << 20  # 响应体上限 1MiB

WARN_TEXT = "⚠️ 暂时无法获取"
DEGRADE_TEXT = "📶 套餐限额：查询出现问题，请稍后再试\n"

# JS Number(string) 仅在字符串形态走 float()；bool 显式拒（JS typeof 非 number）。
# 已知微小差异：JS Number("") === 0，python float("") 抛错 → 视为无效。
# 实际消费方（limit<=0 / percentage 缺失）两条路径下都等价于「窗口丢弃」。


# ---------------------------------------------------------------------------
# 协议纯函数（gcli cli.ts 移植，语义 1:1）
# ---------------------------------------------------------------------------

def build_quota_request(base_url, token):
    """域名 → (kind, url, auth_header)；不支持 / 信息缺失 → None（零请求）。"""
    if not isinstance(base_url, str) or base_url == "":
        return None
    if not isinstance(token, str) or token == "":
        return None
    m = re.match(r"^https?://[^/]+", base_url)
    if m is None:
        return None
    domain = m.group(0)
    if "kimi.com" in base_url or "moonshot" in base_url:
        return ("kimi", domain + "/coding/v1/usages", "Bearer " + token)
    if "bigmodel" in base_url or "z.ai" in base_url:
        # GLM 契约：裸 token（带 Bearer 前缀会 401）
        return ("glm", domain + "/api/monitor/usage/quota/limit", token)
    return None


def _to_num(v):
    """kimi/glm 数值字段（JSON 字符串形态常见）安全转 float；非法 → None。"""
    if isinstance(v, bool):
        return None
    if isinstance(v, (int, float)):
        n = float(v)
    elif isinstance(v, str):
        try:
            n = float(v)
        except ValueError:
            return None
    else:
        return None
    if not math.isfinite(n):
        return None
    return n


def _to_reset_iso(v):
    """重置时间规整：字符串（ISO）原样透传；正的有限数按 epoch-ms 转 ISO。

    gcli parity：非法字符串原样返回，解析失败推迟到 format_reset（→ 省略 ↻）。
    """
    if isinstance(v, str) and v != "":
        return v
    if isinstance(v, bool):
        return None
    if isinstance(v, (int, float)) and math.isfinite(v) and v > 0:
        total_ms = int(v)  # JS Date(v) 截断小数 ms
        secs, ms = divmod(total_ms, 1000)
        dt = datetime.fromtimestamp(secs, tz=timezone.utc)
        return dt.strftime("%Y-%m-%dT%H:%M:%S") + ".%03dZ" % ms
    return None


_ISO_RE = re.compile(
    r"^(\d{4}-\d{2}-\d{2})[Tt ](\d{2}:\d{2}:\d{2})(?:\.(\d+))?"
    r"\s*(Z|z|[+-]\d{2}:?\d{2})?$"
)


def _parse_iso_ms(s):
    """ISO8601 → epoch-ms；解析失败 → None（3.9 无 fromisoformat 的 Z 支持，手动归一）。"""
    txt = s.strip()
    m = _ISO_RE.match(txt)
    if m is not None:
        date, hms, frac, tz = m.groups()
        if frac:
            frac = frac[:6].ljust(6, "0")
        if tz is None:
            tz = ""
        elif tz in ("Z", "z"):
            tz = "+00:00"
        elif ":" not in tz:
            tz = tz[:3] + ":" + tz[3:]
        txt = date + "T" + hms + (("." + frac) if frac else "") + tz
    try:
        dt = datetime.fromisoformat(txt)
    except ValueError:
        return None
    return int(dt.timestamp() * 1000)


def _kimi_window(detail):
    """单个 kimi 用量窗口：used/limit 字符串；used 缺失用 limit−remaining 兜底。

    任一环节畸形 → None（整窗丢弃，绝不抛错）。pct = floor(used/limit*100)。
    """
    if not isinstance(detail, dict):
        return None
    limit = _to_num(detail.get("limit"))
    used = _to_num(detail.get("used"))
    if used is None:
        remaining = _to_num(detail.get("remaining"))
        if limit is not None and remaining is not None:
            used = limit - remaining
    if limit is None or used is None or limit <= 0:
        return None
    reset_iso = _to_reset_iso(detail.get("resetTime"))
    if reset_iso is None:
        return None
    return (int(math.floor(used / limit * 100)), reset_iso)


def parse_kimi_usages(body):
    """kimi /coding/v1/usages：limits[] 中 duration==300 且 MINUTE → 5h 短窗；
    顶层 usage → 周窗。畸形 → 缺窗口。返回 {"short": (pct, iso)|缺, "weekly": ...}。
    """
    out = {}
    if not isinstance(body, dict):
        return out
    limits = body.get("limits")
    if not isinstance(limits, list):
        limits = []
    for item in limits:
        if not isinstance(item, dict):
            continue
        window = item.get("window")
        if not isinstance(window, dict):
            continue
        if _to_num(window.get("duration")) != 300:
            continue
        unit = window.get("timeUnit")
        if not isinstance(unit, str) or "MINUTE" not in unit:
            continue
        win = _kimi_window(item.get("detail"))
        if win is not None:
            out["short"] = win
    weekly = _kimi_window(body.get("usage"))
    if weekly is not None:
        out["weekly"] = weekly
    return out


def parse_glm_quota(body):
    """GLM /api/monitor/usage/quota/limit：data.limits[] 取 TOKENS_LIMIT /
    CREDIT_LIMIT（percentage + nextResetTime epoch-ms），按重置时间升序——
    首个 = 5h 短窗，末个 = 周窗。畸形 → 缺窗口。
    """
    out = {}
    if not isinstance(body, dict):
        return out
    data = body.get("data")
    if not isinstance(data, dict):
        return out
    limits = data.get("limits")
    if not isinstance(limits, list):
        limits = []
    wins = []
    for item in limits:
        if not isinstance(item, dict):
            continue
        if item.get("type") not in ("TOKENS_LIMIT", "CREDIT_LIMIT"):
            continue
        pct = _to_num(item.get("percentage"))
        if pct is None:
            continue
        reset_iso = _to_reset_iso(item.get("nextResetTime"))
        if reset_iso is None:
            continue
        wins.append((int(math.floor(pct)), reset_iso))
    wins.sort(key=lambda w: w[1])  # ISO 字符串序 = 时间序
    if wins:
        out["short"] = wins[0]
    if len(wins) > 1:
        out["weekly"] = wins[-1]
    return out


def format_reset(reset_iso, now_ms):
    """重置时刻 → 相对时长（3h20m / 2d4h）；<1m（已重置/将重置）或解析失败 → None。"""
    if not isinstance(reset_iso, str) or reset_iso == "":
        return None
    t = _parse_iso_ms(reset_iso)
    if t is None:
        return None
    minutes = int(math.floor((t - now_ms) / 60000.0))
    if minutes < 1:
        return None
    if minutes < 60:
        return "%dm" % minutes
    hours = minutes // 60
    rem_min = minutes % 60
    if hours < 24:
        return ("%dh%dm" % (hours, rem_min)) if rem_min else ("%dh" % hours)
    days = hours // 24
    rem_hours = hours % 24
    return ("%dd%dh" % (days, rem_hours)) if rem_hours else ("%dd" % days)


# ---------------------------------------------------------------------------
# cc-switch 数据源（read-only）
# ---------------------------------------------------------------------------

def read_provider_rows(db_path):
    """providers 表（app_type='claude'）→ [(name, base_url, token, is_current)]。

    read-only URI 打开（WAL 并发安全，不干扰 cc-switch 写入）；解析失败的
    条目降级为 env 空（build_quota_request 会跳过），表级失败向上抛由 run 兜底。
    """
    conn = sqlite3.connect("file:%s?mode=ro" % db_path, uri=True)
    try:
        cur = conn.execute(
            "SELECT name, settings_config, is_current "
            "FROM providers WHERE app_type='claude'")
        raw = cur.fetchall()
    finally:
        conn.close()
    rows = []
    for name, cfg_text, is_current in raw:
        cfg = {}
        if isinstance(cfg_text, str) and cfg_text:
            try:
                loaded = json.loads(cfg_text)
                if isinstance(loaded, dict):
                    cfg = loaded
            except ValueError:
                cfg = {}
        env = cfg.get("env")
        if not isinstance(env, dict):
            env = {}
        rows.append((
            name if isinstance(name, str) else "",
            env.get("ANTHROPIC_BASE_URL"),
            env.get("ANTHROPIC_AUTH_TOKEN"),
            bool(is_current),
        ))
    return rows


def collect_targets(rows):
    """域名分类 + (kind, token) 去重：同 token 条目合入一组（名取首个，
    is_current 按组内任一条目 OR）。不支持条目跳过。保持 DB 出现行序。"""
    groups = {}
    order = []
    for name, base_url, token, is_current in rows:
        req = build_quota_request(base_url, token)
        if req is None:
            continue
        kind, url, auth = req
        key = (kind, token)
        if key not in groups:
            groups[key] = {
                "kind": kind, "url": url, "auth": auth,
                "names": [], "is_current": False,
            }
            order.append(key)
        g = groups[key]
        g["names"].append(name)
        if is_current:
            g["is_current"] = True
    return [groups[k] for k in order]


def display_name(target):
    """展示名：组内首个条目名；多条目合并时附「（等 N 个条目）」。"""
    names = target.get("names") or [""]
    if len(names) > 1:
        return "%s（等 %d 个条目）" % (names[0], len(names))
    return names[0]


def filter_targets(targets, query):
    """query（已剥触发词）非空时按条目名子串过滤（大小写不敏感，任一名字命中即留）。"""
    q = (query or "").strip().lower()
    if not q:
        return list(targets)
    return [t for t in targets
            if any(q in n.lower() for n in t.get("names", []))]


# ---------------------------------------------------------------------------
# 网络 + 渲染
# ---------------------------------------------------------------------------

def fetch_quota_body(url, auth_header):
    """请求 quota 端点并解析 JSON body。token 只进 Authorization 头。"""
    req = _urlrequest.Request(url)
    req.add_header("Authorization", auth_header)
    with _urlrequest.urlopen(req, timeout=REQUEST_TIMEOUT_S) as resp:
        raw = resp.read(MAX_BODY_BYTES)
    return json.loads(raw.decode("utf-8", "replace"))


def windows_for(kind, body):
    if kind == "kimi":
        return parse_kimi_usages(body)
    return parse_glm_quota(body)


def fetch_all(targets):
    """并发 fetch（ThreadPoolExecutor，per-request 3s）；单条目失败 → error 标记降级。"""

    def work(target):
        try:
            body = fetch_quota_body(target["url"], target["auth"])
            return {"windows": windows_for(target["kind"], body), "error": False}
        except Exception:
            return {"windows": {}, "error": True}

    workers = min(MAX_WORKERS, max(1, len(targets)))
    with ThreadPoolExecutor(max_workers=workers) as ex:
        futures = [ex.submit(work, t) for t in targets]
        results = []
        for f in futures:
            try:
                r = f.result(timeout=REQUEST_TIMEOUT_S * 3)
            except Exception:
                r = {"windows": {}, "error": True}
            results.append(r)
        return results


def level_dot(pcts):
    """双窗最大 pct → 状态点：≥85 🔴 / ≥60 🟡 / 其余 🟢；无数据 🟡（未知）。"""
    if not pcts:
        return "🟡"
    m = max(pcts)
    if m >= QUOTA_HIGH:
        return "🔴"
    if m >= QUOTA_MID:
        return "🟡"
    return "🟢"


def format_segment(label, win, now_ms):
    """单窗段：`5h 12% ↻3h20m`；窗口缺失 → ⚠️；重置过期/缺失 → 省 ↻（gcli parity）。"""
    if win is None:
        return WARN_TEXT
    pct, reset_iso = win
    rel = format_reset(reset_iso, now_ms)
    if rel is None:
        return "%s %d%%" % (label, pct)
    return "%s %d%% ↻%s" % (label, pct, rel)


def render_report(results, now_ms):
    """渲染最终文本（纯文本 + emoji，无 ANSI，plain text 下同样可读）。"""
    lines = ["📶 gcli 套餐限额（%d 个）" % len(results), ""]
    for r in results:
        title = r.get("display_name", "")
        if r.get("is_current"):
            # 合并名以「）」结尾时省额外空格，避免「） · 」双分隔
            sep = "" if title.endswith("）") else " "
            title += sep + "· 当前使用中"
        if r.get("error"):
            dot = "🟡"
            detail = WARN_TEXT
        else:
            wins = r.get("windows") or {}
            pcts = [w[0] for w in (wins.get("short"), wins.get("weekly"))
                    if w is not None]
            dot = level_dot(pcts)
            detail = " ｜ ".join([
                format_segment("5h", wins.get("short"), now_ms),
                format_segment("周窗", wins.get("weekly"), now_ms),
            ])
        lines.append("%s %s" % (dot, title))
        lines.append("　 " + detail)
        lines.append("")
    return "\n".join(lines).rstrip("\n") + "\n"


def card_level(pcts):
    """双窗最大 pct → level 字符串（阈值沿用 level_dot：<60 ok / 60-85 warn / ≥85 danger；
    无数据 warn，与 🟡「未知」同语义）。"""
    if not pcts:
        return "warn"
    m = max(pcts)
    if m >= QUOTA_HIGH:
        return "danger"
    if m >= QUOTA_MID:
        return "warn"
    return "ok"


def render_card(report, now_ms=None):
    """渲染 card JSON dict（BUDDY_OUTPUT_CARD 通道，结构见 state.md ## 契约规约）。

    - now_ms 可选：单参形态 render_card(report) 即契约签名；测试可注入锚点固定 reset 相对时长
    - percent 产出前 clamp 到 [0,100]（双侧防御的插件侧；Swift 解码侧再 clamp）
    - title 含「gcli」字样（验收谓词 s1p3「stdout 或卡片 title 含 gcli」依赖此字样）
    - badge：is_current → 「使用中」，否则空串（字段恒序列化存在，可空）
    - 缺窗口条目不渲染该行（stdout 文本仍有 ⚠️ 兜底）
    - 字段语义通用（无 quota 专有名词），未来插件可复用
    """
    if now_ms is None:
        now_ms = int(time.time() * 1000)
    entries = []
    for r in report:
        wins = r.get("windows") or {}
        pcts = [w[0] for w in (wins.get("short"), wins.get("weekly"))
                if w is not None]
        windows = []
        for label, key in (("5h", "short"), ("周窗", "weekly")):
            win = wins.get(key)
            if win is None:
                continue
            windows.append({
                "label": label,
                "percent": int(max(0, min(100, win[0]))),
                "reset": format_reset(win[1], now_ms) or "",
            })
        entries.append({
            "name": r.get("display_name", ""),
            "level": "warn" if r.get("error") else card_level(pcts),
            "badge": "使用中" if r.get("is_current") else "",
            "windows": windows,
        })
    return {"title": "gcli 套餐限额 · %d 个" % len(report), "entries": entries}


# ---------------------------------------------------------------------------
# stdin 侧容错
# ---------------------------------------------------------------------------

def parse_stdin(raw):
    """PluginInput JSON 容错解析：任何形态失败 → 空 query（显示全部）。"""
    data = {}
    if isinstance(raw, str) and raw.strip():
        try:
            loaded = json.loads(raw)
            if isinstance(loaded, dict):
                data = loaded
        except ValueError:
            data = {}
    query = data.get("query")
    return {"query": query if isinstance(query, str) else ""}


def strip_trigger(query):
    """剥掉 query 开头的触发词（大小写不敏感）；非空剩余部分作为过滤词。

    W2 新增：query 是任一触发词的非空真前缀（如 "gc" ⊂ "gcli"）→ 返回 ""
    （半截触发词 = 用户只输了触发词无参数，纵深防御：覆盖 AI 路由 extractedQuery
    旁支与直调场景，对齐 Swift stripKeywordPrefix 同款分支）。
    """
    if not isinstance(query, str):
        return ""
    q = query.strip()
    low = q.lower()
    for word in TRIGGER_WORDS:
        w = word.lower()
        if low == w:
            return ""
        if low.startswith(w + " "):
            return q[len(w):].strip()
    # 半截触发词前缀分支（空 query 不命中：startswith("") 恒真，需显式守卫）
    if low:
        for word in TRIGGER_WORDS:
            if word.lower().startswith(low):
                return ""
    return q


# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------

def run(raw_input):
    """主流程。返回 (stdout 文本, card dict | None)——card 仅在成功渲染报告时产出；
    无匹配/DB 缺失等降级路径 card=None（让 stdout 文本走文本通道，不被卡片吞掉无匹配提示）。"""
    now_ms = int(time.time() * 1000)
    query = strip_trigger(parse_stdin(raw_input).get("query"))

    home = os.environ.get("HOME", "")
    db_path = os.path.join(home, ".cc-switch", "cc-switch.db") if home else ""
    if not db_path or not os.path.isfile(db_path):
        return ("📶 套餐限额：未找到 cc-switch 数据库（~/.cc-switch/cc-switch.db）\n"
                "装好并使用过 cc-switch（配置过任一 kimi / GLM 条目）后再来查询。\n", None)
    try:
        rows = read_provider_rows(db_path)
    except Exception:
        return ("📶 套餐限额：cc-switch 数据库暂时读不了（可能正被占用）\n"
                "稍后再试。\n", None)

    targets = collect_targets(rows)
    if not targets:
        return ("📶 套餐限额：cc-switch 里没有可查询的 kimi / GLM 套餐条目\n"
                "目前仅支持 kimi（kimi.com / moonshot）与智谱 GLM"
                "（bigmodel / z.ai）。\n", None)

    targets = filter_targets(targets, query)
    if not targets:
        return "📶 套餐限额：没有名称匹配「%s」的条目\n" % query, None

    results = []
    for target, outcome in zip(targets, fetch_all(targets)):
        results.append({
            "display_name": display_name(target),
            "names": target["names"],
            "is_current": target["is_current"],
            "kind": target["kind"],
            "windows": outcome["windows"],
            "error": outcome["error"],
        })
    return render_report(results, now_ms), render_card(results, now_ms)


def main():
    try:
        raw = "" if sys.stdin.isatty() else sys.stdin.read()
    except Exception:
        raw = ""
    card = None
    try:
        output, card = run(raw)
    except Exception:
        # 灾难兜底：恒 exit 0（exit≠0 走 pluginCrash 展示 stderr，不可控）
        output = DEGRADE_TEXT
        card = None
    # 卡片通道（W3）：BUDDY_OUTPUT_CARD env 存在且 run 产出卡片时写 JSON 文件；
    # 写失败静默忽略（框架侧 readCardOutputSafely 读不到文件 → card=nil → stdout 兜底照常）。
    card_path = os.environ.get("BUDDY_OUTPUT_CARD")
    if card is not None and card_path:
        try:
            with open(card_path, "w", encoding="utf-8") as f:
                json.dump(card, f, ensure_ascii=False)
        except Exception:
            pass
    sys.stdout.write(output)
    return 0


if __name__ == "__main__":
    sys.exit(main())
