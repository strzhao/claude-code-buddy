#!/bin/bash
# gcli_quota_real_process.acceptance.test.sh
#
# 红队验收测试：quota→gcli 改名 + card 通道 + 前缀触发词修复（真实插件进程，[real-process] 谓词）
# 运行方式（独立脚本，不经 run-all.sh 发现）：
#   bash tests/acceptance/gcli_quota_real_process.acceptance.test.sh
#
# 覆盖谓词（SSOT: state.md ## 验收场景）：
#   s1p2 [det-machine] 交付后 plugins/quota 存在 且 不存在 plugins/gcli 目录/主文件
#                      （附 W1 登记契约硬断言：plugin.json name/keywords/version + 双 marketplace）
#                      ｜ artifact: /tmp/autopilot-artifacts/s1p2.out
#   s1p3 [real-process] 真跑插件 stdin query="gcli" → stdout 含「gcli 套餐限额」标题 或 卡片 title 含 gcli
#                      ｜ artifact: s1p3.out
#   s2p4 [real-process] 真跑插件 stdin query="gc" → exit==0 且 stdout 非空 且 不含「没有名称匹配」
#                      且 含正向锚点「套餐限额」 ｜ artifact: s2p4.out
#   s3p1 [real-process] 真跑插件（fixture ≥2 条目，env BUDDY_OUTPUT_CARD 指向可写路径）→ card 文件
#                      可 JSON 解析，entries ≥2，每条目含 name/level/windows[]，level ∈
#                      {ok,warn,danger}，percent ∈ [0,100]，badge 字段存在，全文不含 token
#                      ｜ observe: card 文件内容 ｜ artifact: s3p1.out
#   s5p1 [real-process] 真跑插件 stdin query="xy" → stdout 含「没有名称匹配」且 不含限额数值
#                      ｜ artifact: s5p1.out
#   s6p1 [real-process] db 不可读（坏库文件）/ 端点失败（无效 token→非200，或超时）→ exit==0
#                      且 stdout 友好降级文案非空 且 无 Traceback ｜ artifact: s6p1.out
#   s2p6 [real-process] python unittest strip_trigger 六例（GcliStripTriggerAcceptance）
#   s7p2 [real-process] render_card clamp percent=120/-5 → 100/0（GcliRenderCardClampAcceptance）
#
# 红队红线：全部硬断言；真实子进程驱动（模拟 StdinExecutor stdin 契约 + BUDDY_OUTPUT_CARD 通道）；
# token 提取只进进程内变量，artifact 落盘前统一掩码。目标产物缺失时显式 FAIL 而非 crash。
# 网络门控仅用于 s3p1 的「窗口数据在场」补集断言（设计声明的上游降级路径），结构断言恒硬。

set -u
set -o pipefail

PASS=0; FAIL=0
FAILMSGS=()

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
if [ ! -d "$REPO_ROOT/plugins/quota" ]; then
    # staging 布局兜底：从脚本目录向上找含 plugins/quota 的祖先目录（target 布局 ../.. 即命中）
    _d="$(cd "$(dirname "$0")" && pwd)"
    while [ "$_d" != "/" ]; do
        if [ -d "$_d/plugins/quota" ]; then REPO_ROOT="$_d"; break; fi
        _d="$(dirname "$_d")"
    done
fi
QUOTA_DIR="$REPO_ROOT/plugins/quota"
QUOTA_PY="$QUOTA_DIR/quota.py"
PLUGIN_JSON="$QUOTA_DIR/plugin.json"
MARKETPLACE_JSON="$REPO_ROOT/plugins/marketplace.json"
BUNDLE_MARKETPLACE_JSON="$REPO_ROOT/apps/desktop/Sources/ClaudeCodeBuddy/Marketplace/marketplace.json"
QUOTA_README="$QUOTA_DIR/README.md"
DB_PATH="$HOME/.cc-switch/cc-switch.db"
PY=/usr/bin/python3
SQLITE=/usr/bin/sqlite3
CURL=$(command -v curl || true)
ART_DIR=/tmp/autopilot-artifacts

TMPDIR_QA="$(mktemp -d -t gcli-acceptance)"
DRIVE_TIMEOUT=30   # > plugin.json timeout 15（插件内部 per-request 3s 自限应先生效，此为兜底看门狗）

mkdir -p "$ART_DIR"

fail() { FAIL=$((FAIL+1)); FAILMSGS+=("FAIL [$1]: $2"); echo "  ✗ FAIL [$1]: $2" >&2; }
pass() { PASS=$((PASS+1)); echo "  ✓ PASS [$1]"; }

write_artifact() { # <name.out> <content on stdin>
    cat > "$ART_DIR/$1"
}

# ── 前置：目标缺失检查（蓝队未完成 → 显式 FAIL，不 crash）──────────────────
if [ ! -f "$QUOTA_PY" ]; then
    echo "=== gcli quota real-process acceptance tests ==="
    echo "  ✗ FAIL [目标缺失]: $QUOTA_PY 尚不存在（蓝队未完成或路径错误）"
    exit 1
fi
if [ ! -x "$QUOTA_PY" ]; then
    chmod +x "$QUOTA_PY"   # 镜像框架 ensureStdinChmod 兜底契约
fi

# ── token 提取（fixture；只进进程内变量，绝不 echo）────────────────────────
TOKENS=""
if [ -f "$DB_PATH" ]; then
    TOKENS=$($SQLITE "file:$DB_PATH?mode=ro" \
        "SELECT DISTINCT COALESCE(json_extract(settings_config,'\$.env.ANTHROPIC_AUTH_TOKEN'),'') FROM providers WHERE app_type='claude';" 2>/dev/null \
        | while IFS= read -r t; do [ "${#t}" -ge 8 ] && printf '%s\n' "$t"; done)
fi

mask_tokens() { # <file...> 落盘前掩码
    local f content tok
    for f in "$@"; do
        [ -f "$f" ] || continue
        content=$(cat "$f")
        while IFS= read -r tok; do
            [ -n "$tok" ] || continue
            content=${content//"$tok"/«REDACTED-TOKEN»}
        done <<< "$TOKENS"
        printf '%s' "$content" > "$f"
    done
}

# ── 驱动 helper：模拟 StdinExecutor（stdin JSON 一次写入后关闭 + 可选 BUDDY_OUTPUT_CARD）──
# 用法: drive_gcli <input_file> <out_file> <err_file> [HOME_override] [card_path]
drive_gcli() {
    local infile=$1 outfile=$2 errfile=$3 home_override=${4:-} card_path=${5:-}
    local deadline=$(( $(date +%s) + DRIVE_TIMEOUT )) pid rc
    # bash 3.2 兼容：禁空数组展开（set -u 下 ${ENVV[@]} 空数组会 unbound）
    if [ -n "$card_path" ]; then
        if [ -n "$home_override" ]; then
            env HOME="$home_override" "BUDDY_OUTPUT_CARD=$card_path" "$QUOTA_PY" < "$infile" > "$outfile" 2> "$errfile" &
        else
            env "BUDDY_OUTPUT_CARD=$card_path" "$QUOTA_PY" < "$infile" > "$outfile" 2> "$errfile" &
        fi
    else
        if [ -n "$home_override" ]; then
            env HOME="$home_override" "$QUOTA_PY" < "$infile" > "$outfile" 2> "$errfile" &
        else
            "$QUOTA_PY" < "$infile" > "$outfile" 2> "$errfile" &
        fi
    fi
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        if [ "$(date +%s)" -ge "$deadline" ]; then
            kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
            echo "drive watchdog fired after ${DRIVE_TIMEOUT}s" > "$errfile"
            return 124
        fi
        sleep 0.2
    done
    wait "$pid"; rc=$?
    return "$rc"
}

make_input() { # <file> <query>
    printf '{"query":"%s","sessionId":"qa","cwd":"/tmp"}' "$2" > "$1"
}

# ===========================================================================
# s1p2: 目录保持 quota + 无 gcli 目录/主文件 + W1 登记契约（plugin.json / marketplace 逐字）
# ===========================================================================
test_s1p2() {
    echo "s1p2: plugins/quota 存在 ∧ 无 plugins/gcli 目录/主文件 ∧ W1 登记契约"
    local ev="$TMPDIR_QA/s1p2.out"
    local ok=1

    [ -d "$QUOTA_DIR" ] || { fail "s1p2" "$QUOTA_DIR 目录不存在"; ok=0; }
    if [ -e "$REPO_ROOT/plugins/gcli" ]; then
        fail "s1p2" "存在 plugins/gcli 目录（W1 明确目录/文件名不改）"; ok=0
    fi
    if [ -f "$REPO_ROOT/plugins/gcli/gcli.py" ] || [ -f "$REPO_ROOT/plugins/gcli/quota.py" ]; then
        fail "s1p2" "存在 plugins/gcli 主文件"; ok=0
    fi
    if [ "$ok" -eq 0 ]; then : > "$ev"; echo "FAIL（目录层）" > "$ev"; mask_tokens "$ev"; write_artifact s1p2.out < "$ev"; return; fi

    # W1 plugin.json 契约（name/keywords/version 逐字；summary/description 触发词示例同步）
    "$PY" - "$PLUGIN_JSON" "$MARKETPLACE_JSON" "$BUNDLE_MARKETPLACE_JSON" "$QUOTA_README" > "$ev" 2>&1 <<'PYEOF'
import json, sys, io
plugin_json_path, mk_root, mk_bundle, readme_path = sys.argv[1:5]
fails = []
def check(name, cond, detail=""):
    if not cond:
        fails.append("s1p2-FAIL [%s]: %s" % (name, detail))

m = json.load(io.open(plugin_json_path, encoding="utf-8"))
check("plugin.json.name==gcli", m.get("name") == "gcli", "实际 %r" % m.get("name"))
check("plugin.json.keywords==[gcli,限额,套餐,用量]",
      m.get("keywords") == ["gcli", "限额", "套餐", "用量"],
      "实际 %r（W1：移除 quota/limit，保留中文功能词）" % m.get("keywords"))
check("plugin.json.version==0.2.0", m.get("version") == "0.2.0",
      "实际 %r（改名+功能变更须 bump，否则 syncFromRemote 判 noop）" % m.get("version"))
summary_desc = (m.get("summary") or "") + (m.get("description") or "")
# W1 语义 = 「同步既有触发词示例」，非「必须新增 gcli 字样」：负向断言旧词示例残留；
# 正向 gcli 示例由 README 触发词文档断言覆盖（gcli kimi）。
check("summary/description 无旧触发词示例残留（quota kimi/limit kimi）",
      "quota kimi" not in summary_desc and "limit kimi" not in summary_desc,
      "仍存在旧名触发词示例")

for mk_path, label in ((mk_root, "plugins/marketplace.json"), (mk_bundle, "bundle marketplace.json")):
    import os
    if not os.path.exists(mk_path):
        # bundle marketplace.json 是 build-time fetch 产物（gitignore），缺失仅注记非 FAIL
        print("NOTE: %s 不存在（build 产物，make fetch-plugins 时自 plugins/marketplace.json 再生）" % label)
        continue
    mk = json.load(io.open(mk_path, encoding="utf-8"))
    plugins = mk.get("plugins", [])
    entries = [p for p in plugins if isinstance(p, dict) and p.get("name") in ("gcli", "quota")]
    hit = [p for p in entries if p.get("name") == "gcli"]
    check(label + " 含 name==gcli 条目", len(hit) == 1,
          "命中 %r" % [p.get("name") for p in entries if isinstance(p, dict)])
    if hit:
        # source 双形态：root registry = git-subdir dict；bundle（fetch-plugins 改写）= 本地路径串
        src = hit[0].get("source")
        if isinstance(src, dict):
            check(label + ".source.path==plugins/quota", src.get("path") == "plugins/quota",
                  "实际 %r（目录不改，仅 name 字段同步）" % src.get("path"))
            check(label + ".source.ref==main", src.get("ref") == "main", "实际 %r" % src.get("ref"))
        elif isinstance(src, str):
            check(label + ".source 串形态指向 plugins/quota",
                  src.replace("./", "") == "plugins/quota", "实际 %r" % src)
        else:
            check(label + ".source 存在", False, "实际 %r" % (src,))
        check(label + ".version==0.2.0", hit[0].get("version") == "0.2.0",
              "实际 %r" % hit[0].get("version"))
    check(label + " 不再含 name==quota 旧条目",
          not any(isinstance(p, dict) and p.get("name") == "quota" for p in plugins),
          "仍存在旧名条目")

readme = io.open(readme_path, encoding="utf-8").read()
check("README 触发词文档含 gcli kimi", "gcli kimi" in readme,
      "W1：触发词文档 quota kimi→gcli kimi 未同步")

for line in fails:
    print(line)
sys.exit(1 if fails else 0)
PYEOF
    local rc=$?
    mask_tokens "$ev"
    if [ "$rc" -ne 0 ]; then
        fail "s1p2" "plugin.json/marketplace 契约未满足（详见 $ART_DIR/s1p2.out）"
        write_artifact s1p2.out < "$ev"
        return
    fi
    { echo "s1p2: plugins/quota 在场；无 plugins/gcli 目录/主文件"
      echo "plugin.json name=gcli keywords=[gcli,限额,套餐,用量] version=0.2.0"
      echo "双 marketplace：name==gcli + path==plugins/quota + version==0.2.0；README 触发词含 gcli kimi"
      echo "PASS"; } > "$ev"
    write_artifact s1p2.out < "$ev"
    pass "s1p2"
}

# ===========================================================================
# s1p3: 真跑插件 query="gcli" → stdout 含「gcli 套餐限额」标题 或 card title 含 gcli
# ===========================================================================
test_s1p3() {
    echo "s1p3: query=gcli → stdout 标题含 gcli 套餐限额 或 card title 含 gcli"
    local in_f="$TMPDIR_QA/s1p3.in" out_f="$TMPDIR_QA/s1p3.out.raw" err_f="$TMPDIR_QA/s1p3.err" card_f="$TMPDIR_QA/s1p3.card.json" rc
    make_input "$in_f" "gcli"
    drive_gcli "$in_f" "$out_f" "$err_f" "" "$card_f"; rc=$?

    local ev="$TMPDIR_QA/s1p3.ev"
    {
        echo "query=gcli exit=$rc"
        echo "--- stdout ---"; cat "$out_f" 2>/dev/null
        echo "--- card title ---"
        "$PY" - "$card_f" <<'PYEOF' 2>/dev/null
import json, sys
try:
    print(json.load(open(sys.argv[1], encoding="utf-8")).get("title", "<no-title>"))
except Exception as e:
    print("<card-unavailable: %s>" % e)
PYEOF
    } > "$ev" 2>/dev/null
    mask_tokens "$ev" "$out_f" "$err_f"

    if [ "$rc" -ne 0 ]; then
        fail "s1p3" "exit 期望 0，实际 ${rc}；stderr: $(head -c 200 "$err_f")"
        write_artifact s1p3.out < "$ev"; return
    fi
    # 正向锚点取「gcli 套餐限额」标题字样（W1 render_report/card title 契约字面），
    # 而非裸 "gcli"——防「没有名称匹配：gcli」错误文案子串假红/假绿。
    if grep -q 'gcli 套餐限额' "$out_f" || grep -q 'gcli 套餐限额' "$ev"; then
        cp "$ev" "$ev.in"; { echo "PASS: gcli 标题字样在场"; cat "$ev.in"; } > "$ev"; rm -f "$ev.in"
        write_artifact s1p3.out < "$ev"
        pass "s1p3"
        return
    fi
    fail "s1p3" "stdout 与 card title 均无「gcli 套餐限额」标题字样（W1 输出字样未同步？）；证据: $(head -c 200 "$ev")"
    write_artifact s1p3.out < "$ev"
}

# ===========================================================================
# s2p4: 真跑插件 query="gc" → exit==0 ∧ stdout 非空 ∧ 不含「没有名称匹配」∧ 含「套餐限额」
# ===========================================================================
test_s2p4() {
    echo "s2p4: query=gc → exit 0 ∧ 非空 ∧ 无「没有名称匹配」（W2 真插件层）"
    local in_f="$TMPDIR_QA/s2p4.in" out_f="$TMPDIR_QA/s2p4.out.raw" err_f="$TMPDIR_QA/s2p4.err" rc
    make_input "$in_f" "gc"
    drive_gcli "$in_f" "$out_f" "$err_f"; rc=$?
    mask_tokens "$out_f" "$err_f"

    local ev="$TMPDIR_QA/s2p4.ev"
    { echo "query=gc exit=$rc bytes=$(wc -c < "$out_f" | tr -d ' ')"
      echo "--- stdout ---"; cat "$out_f" 2>/dev/null; } > "$ev"

    if [ "$rc" -ne 0 ]; then
        fail "s2p4" "exit 期望 0，实际 ${rc}；stderr: $(head -c 200 "$err_f")"
        write_artifact s2p4.out < "$ev"; return
    fi
    if [ ! -s "$out_f" ]; then
        fail "s2p4" "stdout 为空（gc 应剥离为空参显示全部条目）"
        write_artifact s2p4.out < "$ev"; return
    fi
    if grep -q '没有名称匹配' "$out_f"; then
        fail "s2p4" "stdout 含「没有名称匹配」——W2 前缀剥离未生效（gc 被当条目名过滤）"
        write_artifact s2p4.out < "$ev"; return
    fi
    if ! grep -q '套餐限额' "$out_f"; then
        fail "s2p4" "stdout 缺正向锚点「套餐限额」"
        write_artifact s2p4.out < "$ev"; return
    fi
    cp "$ev" "$ev.in"; { echo "PASS: exit=0 非空 无没有名称匹配 含套餐限额"; cat "$ev.in"; } > "$ev"; rm -f "$ev.in"
    write_artifact s2p4.out < "$ev"
    pass "s2p4"
}

# ===========================================================================
# s3p1: card 文件结构 + token 不泄露（fixture = 本机真实 db，≥2 个 (kind,token) 分组）
# ===========================================================================
test_s3p1() {
    echo "s3p1: BUDDY_OUTPUT_CARD 通道 → card 文件结构/枚举/区间/token 不泄露"
    if [ ! -f "$DB_PATH" ]; then
        fail "s3p1" "fixture 缺失：$DB_PATH 不存在，无法驱动 ≥2 条目"
        : > "$ART_DIR/s3p1.out"; echo "FAIL fixture-missing" > "$ART_DIR/s3p1.out"; return
    fi

    # 分组计数（collect_targets 按 (kind,token) 去重；域名分类与插件契约对齐）
    local groups
    groups=$($SQLITE "file:$DB_PATH?mode=ro" \
        "SELECT COALESCE(json_extract(settings_config,'\$.env.ANTHROPIC_BASE_URL'),''), COALESCE(json_extract(settings_config,'\$.env.ANTHROPIC_AUTH_TOKEN'),'') FROM providers WHERE app_type='claude';" 2>/dev/null \
    | awk -F'|' '
        { url=$1; tok=$2; kind=""
          if (url ~ /kimi\.com|moonshot/) kind="kimi"
          else if (url ~ /bigmodel|z\.ai/) kind="glm"
          if (kind != "" && tok != "" && !seen[kind "|" tok]++) n++ }
        END { print n+0 }')
    if [ "${groups:-0}" -lt 2 ]; then
        fail "s3p1" "fixture 缺失：db 仅 ${groups} 个受支持 (kind,token) 分组，需 ≥2"
        : > "$ART_DIR/s3p1.out"; echo "FAIL fixture-groups=$groups" > "$ART_DIR/s3p1.out"; return
    fi

    local in_f="$TMPDIR_QA/s3p1.in" out_f="$TMPDIR_QA/s3p1.stdout" err_f="$TMPDIR_QA/s3p1.err" card_f="$TMPDIR_QA/s3p1.card.json" rc
    make_input "$in_f" ""
    drive_gcli "$in_f" "$out_f" "$err_f" "" "$card_f"; rc=$?
    mask_tokens "$out_f" "$err_f"

    # 结构断言（python 一次性硬断言：entries≥2 / 字段 / 枚举 / 区间 / token 不入卡）
    "$PY" - "$card_f" "$DB_PATH" > "$TMPDIR_QA/s3p1.ev" <<'PYEOF'
import json, sqlite3, sys
card_path, db_path = sys.argv[1], sys.argv[2]
fails, lines = [], []
def check(name, cond, detail=""):
    lines.append("%s: %s %s" % ("OK  " if cond else "FAIL", name, detail if not cond else ""))
    if not cond:
        fails.append(name)

try:
    card = json.load(open(card_path, encoding="utf-8"))
    lines.append("card file: parseable, %d bytes" % __import__("os").path.getsize(card_path))
except Exception as e:
    print("FAIL: card 文件不可 JSON 解析（BUDDY_OUTPUT_CARD 通道未产出？）: %s" % e)
    print("SUMMARY FAIL")
    sys.exit(1)

entries = card.get("entries")
check("entries 为数组且 >=2", isinstance(entries, list) and len(entries) >= 2,
      "实际 %r" % (type(entries).__name__,))
if isinstance(entries, list):
    for i, e in enumerate(entries):
        check("entry[%d].name 非空" % i, isinstance(e.get("name"), str) and e["name"] != "")
        check("entry[%d].level ∈ ok|warn|danger" % i, e.get("level") in ("ok", "warn", "danger"),
              "实际 %r" % e.get("level"))
        check("entry[%d].badge 字段存在" % i, "badge" in e)
        wins = e.get("windows")
        check("entry[%d].windows 为数组" % i, isinstance(wins, list), "实际 %r" % type(wins).__name__)
        for j, w in enumerate(wins or []):
            check("entry[%d].windows[%d].label 非空" % (i, j),
                  isinstance(w.get("label"), str) and w["label"] != "")
            pct = w.get("percent")
            check("entry[%d].windows[%d].percent ∈ [0,100]" % (i, j),
                  isinstance(pct, (int, float)) and not isinstance(pct, bool)
                  and 0 <= pct <= 100, "实际 %r" % pct)
            check("entry[%d].windows[%d].reset 键存在" % (i, j), "reset" in w)

# token 不泄露：db 全部 token（≥8 字符）不得出现在 card 全文
raw = open(card_path, encoding="utf-8", errors="replace").read()
con = sqlite3.connect("file:%s?mode=ro" % db_path, uri=True)
toks = [r[0] for r in con.execute(
    "SELECT DISTINCT json_extract(settings_config,'$.env.ANTHROPIC_AUTH_TOKEN') FROM providers WHERE app_type='claude'")]
leaked = [t[:6] + "…" for t in toks if isinstance(t, str) and len(t) >= 8 and t in raw]
check("card 全文不含任何 db token", not leaked, "泄漏(掩码) %r" % leaked)
check("card 全文不含 Bearer 字样", "Bearer" not in raw)

for l in lines:
    print(l)
print("SUMMARY %s" % ("FAIL" if fails else "PASS"))
sys.exit(1 if fails else 0)
PYEOF
    local src_rc=$?

    # 网络门控补集（设计声明的上游降级路径之外，窗口数据应在场）：任一受支持端点可达
    # → 至少一个窗口带 percent（硬）；全不可达 → 显式记录网络 SKIP 行（结构断言已恒硬）
    local net_note="network-gate: curl 不可用，跳过窗口在场补集断言"
    if [ -n "$CURL" ]; then
        local url code reachable=0
        while IFS= read -r url; do
            [ -n "$url" ] || continue
            case "$url" in
                *kimi.com*|*moonshot*|*bigmodel*|*z.ai*)
                    code=$("$CURL" -s -o /dev/null -w '%{http_code}' --max-time 5 "$url" 2>/dev/null)
                    if [ -n "$code" ] && [ "$code" != "000" ]; then reachable=1; break; fi ;;
            esac
        done < <($SQLITE "file:$DB_PATH?mode=ro" \
            "SELECT DISTINCT COALESCE(json_extract(settings_config,'\$.env.ANTHROPIC_BASE_URL'),'') FROM providers WHERE app_type='claude';" 2>/dev/null)
        if [ "$reachable" -eq 1 ]; then
            if "$PY" -c 'import json,sys; c=json.load(open(sys.argv[1],encoding="utf-8")); sys.exit(0 if any(w.get("percent") is not None for e in c.get("entries",[]) for w in (e.get("windows") or [])) else 1)' "$card_f" 2>/dev/null; then
                net_note="network-gate: 端点可达 ∧ 窗口 percent 在场（补集断言 PASS）"
            else
                net_note="network-gate: 端点可达但无任何窗口 percent（上游或解析故障）→ FAIL"
                src_rc=1
            fi
        else
            net_note="network-gate: 全部受支持端点不可达（设计降级路径），窗口在场补集显式跳过"
        fi
    fi

    if [ "$src_rc" -ne 0 ] || [ "$rc" -ne 0 ]; then
        fail "s3p1" "card 结构/枚举/区间/token 断言未全过（详见 $ART_DIR/s3p1.out）"
    fi
    # artifact：结构断言行 + 网络门控注记 + 掩码后的 card 全文（QA 证据）
    mask_tokens "$card_f" 2>/dev/null
    { cat "$TMPDIR_QA/s3p1.ev" 2>/dev/null; echo "$net_note"; echo "exit=$rc"
      echo "--- card (masked) ---"; cat "$card_f" 2>/dev/null; } > "$TMPDIR_QA/s3p1.final"
    mask_tokens "$TMPDIR_QA/s3p1.final"
    write_artifact s3p1.out < "$TMPDIR_QA/s3p1.final"

    if [ "$src_rc" -ne 0 ] || [ "$rc" -ne 0 ]; then
        return
    fi
    pass "s3p1"
}

# ===========================================================================
# s5p1: 真跑插件 query="xy" → 含「没有名称匹配」∧ 不含限额数值（防过度放宽）
# ===========================================================================
test_s5p1() {
    echo "s5p1: query=xy → 含「没有名称匹配」∧ 无限额数值"
    local in_f="$TMPDIR_QA/s5p1.in" out_f="$TMPDIR_QA/s5p1.out.raw" err_f="$TMPDIR_QA/s5p1.err" rc
    make_input "$in_f" "xy"
    drive_gcli "$in_f" "$out_f" "$err_f"; rc=$?
    mask_tokens "$out_f" "$err_f"

    local ev="$TMPDIR_QA/s5p1.ev"
    { echo "query=xy exit=$rc"; echo "--- stdout ---"; cat "$out_f" 2>/dev/null; } > "$ev"

    if [ "$rc" -ne 0 ]; then
        fail "s5p1" "exit 期望 0，实际 ${rc}"
        write_artifact s5p1.out < "$ev"; return
    fi
    if ! grep -q '没有名称匹配' "$out_f"; then
        fail "s5p1" "stdout 不含「没有名称匹配」（真无匹配必须仍提示）"
        write_artifact s5p1.out < "$ev"; return
    fi
    # 限额数值 = 百分比数字（<n>%）；标题计数（N 个）不属于限额数值
    if grep -Eq '[0-9]+(\.[0-9]+)?%' "$out_f"; then
        fail "s5p1" "无匹配提示却含限额数值（<n>%）"
        write_artifact s5p1.out < "$ev"; return
    fi
    cp "$ev" "$ev.in"; { echo "PASS: 含没有名称匹配 无限额数值"; cat "$ev.in"; } > "$ev"; rm -f "$ev.in"
    write_artifact s5p1.out < "$ev"
    pass "s5p1"
}

# ===========================================================================
# s6p1: db 不可读 / 端点失败 → exit 0 ∧ 友好降级文案非空 ∧ 无 Traceback
# ===========================================================================
test_s6p1() {
    echo "s6p1: 故障注入（坏库 / 无效 token 端点）→ 恒 exit 0 ∧ 降级文案 ∧ 无 Traceback"
    local ev="$TMPDIR_QA/s6p1.ev" ok=1

    # 变体 A：db 不可读（垃圾字节文件）
    local bad_home="$TMPDIR_QA/badhome"
    mkdir -p "$bad_home/.cc-switch"
    printf 'this is not a sqlite database %s' "$(head -c 64 /dev/urandom | base64)" > "$bad_home/.cc-switch/cc-switch.db"
    local in_f="$TMPDIR_QA/s6p1a.in" out_f="$TMPDIR_QA/s6p1a.out" err_f="$TMPDIR_QA/s6p1a.err" rc
    make_input "$in_f" ""
    drive_gcli "$in_f" "$out_f" "$err_f" "$bad_home"; rc=$?
    mask_tokens "$out_f" "$err_f"
    { echo "=== variant A: db-unreadable exit=$rc ==="; cat "$out_f" 2>/dev/null; cat "$err_f" 2>/dev/null; } >> "$ev"
    if [ "$rc" -ne 0 ]; then fail "s6p1[A]" "db 不可读须恒 exit 0，实际 ${rc}"; ok=0; fi
    if ! grep -q 'Traceback' "$out_f" && ! grep -q 'Traceback' "$err_f"; then :; else
        fail "s6p1[A]" "输出含 Traceback（必须降级为正常 UX）"; ok=0
    fi
    if [ ! -s "$out_f" ]; then fail "s6p1[A]" "stdout 为空（应友好降级非静默）"; ok=0; fi

    # 变体 B：端点失败（kimi 域名 + 无效 token → 非 200；断网时为超时——同属谓词故障域）
    local fix_home="$TMPDIR_QA/fixhome"
    mkdir -p "$fix_home/.cc-switch"
    $SQLITE "$fix_home/.cc-switch/cc-switch.db" \
        "CREATE TABLE providers(name TEXT, app_type TEXT, settings_config TEXT);
         INSERT INTO providers VALUES('redteam-kimi','claude','{\"env\":{\"ANTHROPIC_BASE_URL\":\"https://api.kimi.com/coding/\",\"ANTHROPIC_AUTH_TOKEN\":\"sk-redteam-invalid-token-000000\"}}');" \
        >/dev/null 2>&1
    local out_b="$TMPDIR_QA/s6p1b.out" err_b="$TMPDIR_QA/s6p1b.err"
    drive_gcli "$in_f" "$out_b" "$err_b" "$fix_home"; rc=$?
    mask_tokens "$out_b" "$err_b"
    { echo "=== variant B: endpoint-fail exit=$rc ==="; cat "$out_b" 2>/dev/null; cat "$err_b" 2>/dev/null; } >> "$ev"
    if [ "$rc" -ne 0 ]; then fail "s6p1[B]" "端点失败须恒 exit 0，实际 ${rc}"; ok=0; fi
    if grep -q 'Traceback' "$out_b" || grep -q 'Traceback' "$err_b"; then
        fail "s6p1[B]" "输出含 Traceback"; ok=0
    fi
    if [ ! -s "$out_b" ]; then fail "s6p1[B]" "stdout 为空"; ok=0; fi
    if ! grep -Eq '⚠️|暂时|无法|不可用|失败' "$out_b"; then
        fail "s6p1[B]" "stdout 无任何降级语义词（⚠️/暂时/无法/不可用/失败）"
        ok=0
    fi

    if [ "$ok" -eq 1 ]; then
        cp "$ev" "$ev.in"; { echo "PASS: 两变体恒 exit 0 ∧ 降级文案在场 ∧ 无 Traceback"; cat "$ev.in"; } > "$ev"; rm -f "$ev.in"
        write_artifact s6p1.out < "$ev"
        pass "s6p1"
    else
        write_artifact s6p1.out < "$ev"
    fi
}

# ===========================================================================
# s2p6 / s7p2: python 验收类运行器（GcliStripTriggerAcceptance / GcliRenderCardClampAcceptance）
# ===========================================================================
locate_py_acceptance() {
    local here="$(cd "$(dirname "$0")" && pwd)"
    for cand in "$QUOTA_DIR/tests/strip_trigger_render_card.acceptance.test.py" "$here/strip_trigger_render_card.acceptance.test.py"; do
        [ -f "$cand" ] && { printf '%s' "$cand"; return 0; }
    done
    return 1
}

test_py_class() { # <class> <artifact> <label>
    local cls=$1 art=$2 label=$3 pyfile rc
    pyfile=$(locate_py_acceptance) || { fail "$label" "strip_trigger_render_card.acceptance.test.py 不存在（staging/target 均未找到）"; return; }
    local run_out="$TMPDIR_QA/$label.run"
    QUOTA_DIR="$QUOTA_DIR" "$PY" "$pyfile" "$cls" > "$run_out" 2>&1
    rc=$?
    mask_tokens "$run_out"
    if [ "$rc" -ne 0 ]; then
        fail "$label" "$cls exit=${rc}（详见 $ART_DIR/$art）；尾部: $(tail -4 "$run_out" | tr '\n' '; ')"
        write_artifact "$art" < "$run_out"
        return
    fi
    if ! grep -q '^PASS$' "$ART_DIR/$art" 2>/dev/null; then
        fail "$label" "$cls 通过但未产出含 PASS 的 artifact $ART_DIR/$art"
        return
    fi
    pass "$label"
}

# ── main ──────────────────────────────────────────────────────────────────
echo "=== gcli quota real-process acceptance tests ==="
echo "QUOTA_PY=$QUOTA_PY  DB=$([ -f "$DB_PATH" ] && echo exists || echo MISSING)  ART=$ART_DIR"
echo

test_s1p2
test_s1p3
test_s2p4
test_s3p1
test_s5p1
test_s6p1
test_py_class GcliStripTriggerAcceptance    s2p6.out "s2p6"
test_py_class GcliRenderCardClampAcceptance s7p2.out "s7p2"

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
    for m in "${FAILMSGS[@]}"; do echo "$m"; done
    rm -rf "$TMPDIR_QA"
    exit 1
fi
rm -rf "$TMPDIR_QA"
exit 0
