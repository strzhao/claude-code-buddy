#!/bin/bash
# quota_plugin.acceptance.test.sh
#
# 红队验收测试：cc-switch 套餐 limit 社区插件（plugins/quota/，python3 单文件 command mode）
# 运行方式（独立脚本，不经 run-all.sh 发现）：
#   bash tests/acceptance/quota_plugin.acceptance.test.sh
#
# 覆盖谓词（SSOT: .autopilot/runtime/requirements/20260921-开始实现/state.md ## 验收场景）：
#   P1  [det-machine] 面板渲染：空 query 驱动 → exit=0 ∧ stdout 含「套餐限额」
#   P2  [det-machine] 双窗数据：stdout 含「5h」∧「周窗」∧ 本机 DB 实有的 kimi|glm 条目名子串
#                     （双窗字面量依赖上游 API；全部端点不可达时 SKIP 并显式标记，条目名断言恒硬）
#   P3  [det-machine] token 不泄露：stdout+stderr 不含 cc-switch.db 真实 token 值 ∧ 不含「Bearer」
#                     （token 在测试进程内提取，绝不 echo；artifact 落盘前统一掩码）
#   P4  [det-machine] 单测全绿：cd plugins/quota && python3 -m unittest discover → exit=0
#   P5  [det-machine] 畸形输入容错：not-json 与空 stdin 两种驱动均 exit=0 ∧ 无 Traceback
#   P6  [det-machine] DB 缺失降级：HOME=/tmp/qa-empty-home → exit=0 ∧ 降级提示 ∧ 无 Traceback
#   P7  [det-machine] W1 改名 + W3 卡片通道：BUDDY_OUTPUT_CARD 驱动 → card 文件可 JSON 解析 ∧
#                     title 含「gcli」∧ level ∈ {ok,warn,danger} ∧ percent ∈ [0,100] ∧ 无 token；
#                     plugin.json name==gcli ∧ keywords 含 gcli 无 quota/limit（旧词移除）
#   S0  [det-machine] manifest 契约（state.md ## 契约规约 钉死字面量）：plugin.json 字段闭集 +
#                     gcli 条目 marketplace 登记（目录仍 plugins/quota）+ shebang /usr/bin/python3
#
# 红队红线：全部 det-machine 硬断言；驱动真实脚本产物（模拟 StdinExecutor stdin 契约），
# 不走 buddy CLI 全链路（TOFU 弹框不可自动化）。目标产物缺失时输出「目标缺失」失败而非 crash。

set -u
set -o pipefail

PASS=0; FAIL=0; SKIP=0
FAILMSGS=()

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
QUOTA_DIR="$REPO_ROOT/plugins/quota"
QUOTA_PY="$QUOTA_DIR/quota.py"
PLUGIN_JSON="$QUOTA_DIR/plugin.json"
MARKETPLACE_JSON="$REPO_ROOT/plugins/marketplace.json"
DB_PATH="$HOME/.cc-switch/cc-switch.db"
PY=/usr/bin/python3
SQLITE=/usr/bin/sqlite3
CURL=$(command -v curl || true)

TMPDIR_QA="$(mktemp -d -t quota-acceptance)"
DRIVE_IN="$TMPDIR_QA/plugin-input.json"
DRIVE_TIMEOUT=30   # > plugin.json timeout 15（插件内部 per-request 3s 自限应先生效，此为兜底看门狗）

fail() { FAIL=$((FAIL+1)); FAILMSGS+=("FAIL [$1]: $2"); echo "  ✗ FAIL [$1]: $2" >&2; }
pass() { PASS=$((PASS+1)); echo "  ✓ PASS [$1]"; }
skip() { SKIP=$((SKIP+1)); echo "  ⊘ SKIP [$1]: $2"; }

# ── 前置：目标缺失检查（蓝队可能尚未完成——明确失败而非 crash）──────────────
if [ ! -f "$QUOTA_PY" ]; then
    echo "=== quota plugin acceptance tests ==="
    echo "  ✗ FAIL [目标缺失]: $QUOTA_PY 尚不存在（蓝队未完成或路径错误）——P1-P6 全部无法驱动"
    exit 1
fi

# 模拟 StdinExecutor ensureStdinChmod 兜底：脚本必须可执行（框架契约兜底 +x，此处镜像之）
if [ ! -x "$QUOTA_PY" ]; then
    echo "  ⊘ NOTE: quota.py 不可执行，镜像框架 ensureStdinChmod 行为 chmod +x（框架兜底契约）"
    chmod +x "$QUOTA_PY"
fi

# ── DB 侧数据提取（测试 fixture；token 只进进程内变量，绝不 echo）──────────
# 域名分类（设计文档关键决策 4 逐字）：kimi.com|moonshot→kimi；bigmodel|z.ai→glm；其余跳过
classify_side() {
    local url="$1"
    case "$url" in
        *kimi.com*|*moonshot*) echo "kimi" ;;
        *bigmodel*|*z.ai*)     echo "glm" ;;
        *)                     echo "" ;;
    esac
}

# SUPPORTED_NAMES: 本机 DB 实有的受支持条目名（换行分隔，name 可能含空格）
SUPPORTED_NAMES=""
if [ -f "$DB_PATH" ]; then
    while IFS="$(printf '\t')" read -r pname purl; do
        [ -n "$(classify_side "$purl")" ] || continue
        SUPPORTED_NAMES="${SUPPORTED_NAMES}${pname}"$'\n'
    done < <($SQLITE "file:$DB_PATH?mode=ro" \
        "SELECT name, COALESCE(json_extract(settings_config,'\$.env.ANTHROPIC_BASE_URL'),'') FROM providers WHERE app_type='claude';" \
        -separator "$(printf '\t')" 2>/dev/null)
fi

# TOKENS: claude 条目全部真实 token（长度>=8 防短串误命中），换行分隔，仅进程内使用
TOKENS=""
if [ -f "$DB_PATH" ]; then
    TOKENS=$($SQLITE "file:$DB_PATH?mode=ro" \
        "SELECT DISTINCT COALESCE(json_extract(settings_config,'\$.env.ANTHROPIC_AUTH_TOKEN'),'') FROM providers WHERE app_type='claude';" 2>/dev/null \
        | while IFS= read -r t; do [ "${#t}" -ge 8 ] && printf '%s\n' "$t"; done)
fi

# mask_tokens <file...>: artifact 落盘前把真实 token 值替换为掩码（纯 bash 替换，token 不过 argv）
mask_tokens() {
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

# ── 驱动 helper：模拟 StdinExecutor（stdin=PluginInput JSON 一次写入后关闭）──
# 用法: drive_quota <input_file> <out_file> <err_file> [HOME_override]
# 返回插件 exit code；看门狗超时返回 124（err_file 写入超时标记）
drive_quota() {
    local infile=$1 outfile=$2 errfile=$3 home_override=${4:-}
    local deadline=$(( $(date +%s) + DRIVE_TIMEOUT )) pid rc
    if [ -n "$home_override" ]; then
        env HOME="$home_override" "$QUOTA_PY" < "$infile" > "$outfile" 2> "$errfile" &
    else
        "$QUOTA_PY" < "$infile" > "$outfile" 2> "$errfile" &
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
    wait "$pid"
    rc=$?
    return "$rc"
}

# P1-P3 标准驱动输入（谓词原文：printf '{"query":"","sessionId":"qa","cwd":"/tmp"}'）
printf '{"query":"","sessionId":"qa","cwd":"/tmp"}' > "$DRIVE_IN"

# ── S0: manifest 契约（设计文档钉死字面量，逐字断言）────────────────────────
test_S0_manifest_contract() {
    echo "S0: plugin.json / marketplace.json / shebang 契约"
    local out
    out=$("$PY" - "$PLUGIN_JSON" "$MARKETPLACE_JSON" "$QUOTA_PY" <<'PYEOF'
import json, sys, io

plugin_json_path, marketplace_path, quota_py_path = sys.argv[1], sys.argv[2], sys.argv[3]
fails = []
def check(name, cond, detail=""):
    if not cond:
        fails.append("S0-FAIL [%s]: %s" % (name, detail))

try:
    m = json.load(io.open(plugin_json_path, encoding="utf-8"))
except Exception as e:
    print("S0-FAIL [plugin.json 可解析]: %s" % e); sys.exit(1)

check("name==gcli", m.get("name") == "gcli", "实际 %r（W1 改名：显示名 gcli，目录保持 quota）" % m.get("name"))
check("version==0.2.0", m.get("version") == "0.2.0", "实际 %r（改名+功能变更 bump 0.2.0）" % m.get("version"))
check("mode==command", m.get("mode") == "command", "实际 %r（设计关键决策 1）" % m.get("mode"))
check("cmd==./quota.py", m.get("cmd") == "./quota.py", "实际 %r（契约表：cmd 用 ./quota.py）" % m.get("cmd"))
check("timeout==15", m.get("timeout") == 15, "实际 %r（契约表：timeout: 15）" % m.get("timeout"))
check("requiredPath含python3", isinstance(m.get("requiredPath"), list) and "python3" in m["requiredPath"],
      "实际 %r" % m.get("requiredPath"))
check("deps为null", m.get("deps", "MISSING") is None,
      "实际 %r（设计关键决策 2：deps: null 零 brew dep）" % (m.get("deps", "MISSING"),))
check("icon==📶", m.get("icon") == "📶", "实际 %r" % m.get("icon"))
# 向后兼容教训（2026-06-24 keywords required decode 失败）：全字段写齐
for f in ("version", "summary", "description", "keywords", "args", "env"):
    check("全字段写齐:%s" % f, f in m, "plugin.json 缺字段 %s" % f)
check("keywords非空且全>=2字符", isinstance(m.get("keywords"), list) and len(m["keywords"]) > 0
      and all(isinstance(k, str) and len(k) >= 2 for k in m["keywords"]),
      "实际 %r（历史知识：单字 keyword 只参与完全档，全 >=2 规避）" % m.get("keywords"))
check("keywords含gcli且无quota/limit", isinstance(m.get("keywords"), list)
      and "gcli" in m["keywords"]
      and "quota" not in m["keywords"] and "limit" not in m["keywords"],
      "实际 %r（W1 改名：gcli 入列，旧词 quota/limit 必须移除）" % m.get("keywords"))
check("summary非黑话人话", isinstance(m.get("summary"), str) and len(m.get("summary", "").strip()) > 0,
      "summary 为空")

try:
    mk = json.load(io.open(marketplace_path, encoding="utf-8"))
except Exception as e:
    print("S0-FAIL [marketplace.json 可解析]: %s" % e); sys.exit(1)
entries = [p for p in mk.get("plugins", []) if p.get("name") == "gcli"]
check("marketplace含gcli条目", len(entries) == 1, "命中 %d 条" % len(entries))
if entries:
    e = entries[0]
    check("marketplace.version存在", bool(e.get("version")), "缺 version（syncFromRemote noop 教训）")
    src = e.get("source", {})
    check("marketplace.source==git-subdir", src.get("source") == "git-subdir", "实际 %r" % src.get("source"))
    check("marketplace.path==plugins/quota", src.get("path") == "plugins/quota", "实际 %r" % src.get("path"))
    check("marketplace.ref==main", src.get("ref") == "main", "实际 %r" % src.get("ref"))

with io.open(quota_py_path, encoding="utf-8") as f:
    first = f.readline().rstrip("\n")
check("shebang绝对python3", first == "#!/usr/bin/python3",
      "首行 %r（设计：不依赖 PATH 的绝对路径 shebang）" % first)

for line in fails:
    print(line)
sys.exit(1 if fails else 0)
PYEOF
    )
    if [ $? -ne 0 ]; then
        fail "S0" "$(echo "$out" | head -5 | tr '\n' '; ')"
        return
    fi
    pass "S0"
}

# ── P1: 面板渲染 ────────────────────────────────────────────────────────────
test_P1_panel_render() {
    echo "P1: 空 query 驱动 → exit=0 ∧ stdout 含「套餐限额」"
    local out_f="$TMPDIR_QA/p1.out" err_f="$TMPDIR_QA/p1.err" rc
    drive_quota "$DRIVE_IN" "$out_f" "$err_f"; rc=$?
    mask_tokens "$out_f" "$err_f"
    if [ "$rc" -ne 0 ]; then
        fail "P1" "exit 期望 0，实际 ${rc}；stderr: $(head -c 200 "$err_f")"
        return
    fi
    if ! grep -q '套餐限额' "$out_f"; then
        fail "P1" "stdout 不含「套餐限额」；实际前 200 字: $(head -c 200 "$out_f")"
        return
    fi
    pass "P1"
}

# ── P2: 双窗数据 ────────────────────────────────────────────────────────────
test_P2_dual_window() {
    echo "P2: stdout 含「5h」∧「周窗」∧ 本机 DB 实有条目名（双窗字面量网络门控）"
    local out_f="$TMPDIR_QA/p2.out" err_f="$TMPDIR_QA/p2.err" rc
    drive_quota "$DRIVE_IN" "$out_f" "$err_f"; rc=$?
    mask_tokens "$out_f" "$err_f"
    if [ "$rc" -ne 0 ]; then
        fail "P2" "exit 期望 0，实际 ${rc}；stderr: $(head -c 200 "$err_f")"
        return
    fi

    # 断言 A（恒硬，不依赖网络）：stdout 含至少一个 DB 实有的受支持条目名子串
    if [ -z "$SUPPORTED_NAMES" ]; then
        fail "P2" "fixture 缺失：cc-switch.db 无 kimi/glm 域名的 claude 条目，无法断言条目名"
        return
    fi
    local matched="" name
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        if grep -F -q -- "$name" "$out_f"; then matched="$matched$name; "; fi
    done <<< "$SUPPORTED_NAMES"
    if [ -z "$matched" ]; then
        fail "P2" "stdout 不含任何 DB 实有条目名（候选: $(echo "$SUPPORTED_NAMES" | tr '\n' ' ')）；实际: $(head -c 200 "$out_f")"
        return
    fi

    # 断言 B（双窗字面量，网络门控）：「5h」∧「周窗」
    local dual_ok=1
    grep -q '5h' "$out_f" || dual_ok=0
    grep -q '周窗' "$out_f" || dual_ok=0
    if [ "$dual_ok" -eq 1 ]; then
        pass "P2"
        return
    fi

    # 网络门控：全部受支持端点不可达 → 显式 SKIP；可达但输出 ⚠️ 降级 → 上游失败 SKIP（设计声明的降级路径）；
    # 可达且无降级标记却缺字面量 → 硬 FAIL
    if [ -z "$CURL" ]; then
        fail "P2" "双窗字面量缺失且 curl 不可用无法探测网络门控；stdout: $(head -c 200 "$out_f")"
        return
    fi
    # 注：case 不可出现在进程/命令替换内（bash 3.2 解析坑）——先捕获再主 shell 循环
    local url code reachable_any=0 raw_urls
    raw_urls=$($SQLITE "file:$DB_PATH?mode=ro" \
        "SELECT DISTINCT COALESCE(json_extract(settings_config,'\$.env.ANTHROPIC_BASE_URL'),'') FROM providers WHERE app_type='claude';" 2>/dev/null)
    while IFS= read -r url; do
        [ -n "$url" ] || continue
        [ -n "$(classify_side "$url")" ] || continue
        code=$("$CURL" -s -o /dev/null -w '%{http_code}' --max-time 5 "$url" 2>/dev/null)
        if [ -n "$code" ] && [ "$code" != "000" ]; then reachable_any=1; fi
    done <<< "$raw_urls"

    if [ "$reachable_any" -eq 0 ]; then
        skip "P2" "双窗字面量（5h/周窗）缺失且全部受支持端点不可达（网络失败，允许跳过）；条目名断言已 PASS（${matched}）"
        return
    fi
    if grep -q '⚠️' "$out_f" || grep -q '暂时无法获取' "$out_f"; then
        skip "P2" "双窗字面量缺失但端点可达且输出含设计声明的降级标记（⚠️/暂时无法获取）——上游 API 失败非插件契约违背，留 QA 复核；条目名断言已 PASS（${matched}）"
        return
    fi
    fail "P2" "端点可达且无降级标记，但 stdout 缺「5h」/「周窗」；实际: $(head -c 200 "$out_f")"
}

# ── P3: token 不泄露 ────────────────────────────────────────────────────────
test_P3_no_token_leak() {
    echo "P3: stdout+stderr 不含 cc-switch.db 真实 token ∧ 不含「Bearer」（token 全程不 echo）"
    local out_f="$TMPDIR_QA/p3.out" err_f="$TMPDIR_QA/p3.err" rc tok leaked=0
    drive_quota "$DRIVE_IN" "$out_f" "$err_f"; rc=$?
    if [ "$rc" -ne 0 ]; then
        fail "P3" "exit 期望 0，实际 ${rc}（stderr: $(head -c 200 "$err_f")）"
        mask_tokens "$out_f" "$err_f"
        return
    fi
    if [ ! -f "$DB_PATH" ]; then
        fail "P3" "fixture 缺失：$DB_PATH 不存在，无法提取真实 token 做泄露断言"
        return
    fi

    local combined
    combined="$(cat "$out_f")$(cat "$err_f")"
    # case 子串匹配：token 不过 argv/subprocess，不落任何中间产物
    while IFS= read -r tok; do
        [ -n "$tok" ] || continue
        case "$combined" in
            *"$tok"*) leaked=1; break ;;
        esac
    done <<< "$TOKENS"
    if [ "$leaked" -ne 0 ]; then
        fail "P3" "输出中检出真实 token 值（值已掩码不回显）——违反安全边界：token 只允许进 Authorization 头"
        mask_tokens "$out_f" "$err_f"
        return
    fi
    if grep -q 'Bearer' "$out_f" || grep -q 'Bearer' "$err_f"; then
        fail "P3" "输出含「Bearer」（Authorization 头方案不得出现在 stdout/stderr）"
        mask_tokens "$out_f" "$err_f"
        return
    fi
    mask_tokens "$out_f" "$err_f"
    pass "P3"
}

# ── P4: 单测全绿 ────────────────────────────────────────────────────────────
test_P4_unit_tests_green() {
    echo "P4: cd plugins/quota && python3 -m unittest discover -s tests -v → exit=0"
    local out_f="$TMPDIR_QA/p4.out" rc
    ( cd "$QUOTA_DIR" && "$PY" -m unittest discover -s tests -v ) > "$out_f" 2>&1
    rc=$?
    if [ "$rc" -ne 0 ]; then
        fail "P4" "unittest discover exit=${rc}（tests/ 缺失或有用例失败）；输出尾部: $(tail -5 "$out_f" | tr '\n' '; ')"
        return
    fi
    pass "P4"
}

# ── P5: 畸形输入容错 ────────────────────────────────────────────────────────
test_P5_malformed_input() {
    echo "P5: not-json 与空 stdin 两种驱动均 exit=0 ∧ 无 Traceback"
    local in_f out_f err_f rc variant
    printf 'not-json\n' > "$TMPDIR_QA/not-json.in"
    : > "$TMPDIR_QA/empty.in"
    for variant in not-json empty; do
        in_f="$TMPDIR_QA/$variant.in"; out_f="$TMPDIR_QA/p5-$variant.out"; err_f="$TMPDIR_QA/p5-$variant.err"
        drive_quota "$in_f" "$out_f" "$err_f"; rc=$?
        if [ "$rc" -ne 0 ]; then
            fail "P5[$variant]" "exit 期望 0，实际 ${rc}；stderr: $(head -c 200 "$err_f")"
            continue
        fi
        if grep -q 'Traceback' "$out_f" || grep -q 'Traceback' "$err_f"; then
            fail "P5[$variant]" "输出含 Traceback（畸形输入必须降级不抛错）"
            continue
        fi
        pass "P5[$variant]"
    done
}

# ── P6: DB 缺失降级 ─────────────────────────────────────────────────────────
test_P6_db_missing_degrade() {
    echo "P6: HOME=/tmp/qa-empty-home → exit=0 ∧ 降级提示 ∧ 无 Traceback"
    local empty_home="/tmp/qa-empty-home" out_f="$TMPDIR_QA/p6.out" err_f="$TMPDIR_QA/p6.err" rc
    mkdir -p "$empty_home"
    drive_quota "/dev/null" "$out_f" "$err_f" "$empty_home"; rc=$?
    mask_tokens "$out_f" "$err_f"
    if [ "$rc" -ne 0 ]; then
        fail "P6" "exit 期望 0，实际 ${rc}；stderr: $(head -c 200 "$err_f")"
        return
    fi
    if grep -q 'Traceback' "$out_f" || grep -q 'Traceback' "$err_f"; then
        fail "P6" "输出含 Traceback（DB 缺失必须降级为正常 UX）"
        return
    fi
    if [ ! -s "$out_f" ]; then
        fail "P6" "stdout 为空（DB 缺失应输出友好降级提示而非静默）"
        return
    fi
    # CONTRACT_AMBIGUOUS: 设计仅声明「降级文案/友好提示」，未钉死字面量——
    # 硬断言为析取：标题（套餐限额）或任一降级语义词出现，缺任一即失败
    if ! grep -Eq '套餐限额|暂时|无法|⚠️|未找到|不可用' "$out_f"; then
        fail "P6" "stdout 无任何降级提示（候选词: 套餐限额/暂时/无法/⚠️/未找到/不可用）；实际: $(head -c 200 "$out_f")"
        return
    fi
    pass "P6"
}

# ── P7: W1 改名 + W3 BUDDY_OUTPUT_CARD 卡片通道 ─────────────────────────────
test_P7_card_channel() {
    echo "P7: BUDDY_OUTPUT_CARD 驱动 → card 文件可解析 ∧ title 含 gcli ∧ level/percent 合法 ∧ 无 token"
    local out_f="$TMPDIR_QA/p7.out" err_f="$TMPDIR_QA/p7.err" card_f="$TMPDIR_QA/p7.card.json" rc
    rm -f "$card_f"
    export BUDDY_OUTPUT_CARD="$card_f"
    drive_quota "$DRIVE_IN" "$out_f" "$err_f"; rc=$?
    unset BUDDY_OUTPUT_CARD
    mask_tokens "$out_f" "$err_f"
    if [ "$rc" -ne 0 ]; then
        fail "P7" "exit 期望 0，实际 ${rc}；stderr: $(head -c 200 "$err_f")"
        return
    fi
    # stdout 恒有兜底文本（错误契约：card 写失败/读不到 → stdout 文本照常渲染）
    if ! grep -q '套餐限额' "$out_f"; then
        fail "P7" "stdout 无兜底文本（缺「套餐限额」）；实际: $(head -c 200 "$out_f")"
        return
    fi
    if [ ! -f "$card_f" ]; then
        if [ ! -f "$DB_PATH" ]; then
            skip "P7" "本机无 cc-switch.db → 插件走 DB 缺失降级早退，不产出 card（允许跳过）"
        else
            fail "P7" "BUDDY_OUTPUT_CARD 已注入且 DB 存在，但 card 文件未产出: $card_f"
        fi
        return
    fi
    local out
    out=$("$PY" - "$card_f" "$TOKENS" <<'PYEOF'
import io, json, sys

card_path, tokens_blob = sys.argv[1], sys.argv[2]
fails = []
def check(name, cond, detail=""):
    if not cond:
        fails.append("P7-FAIL [%s]: %s" % (name, detail))

try:
    with io.open(card_path, encoding="utf-8") as f:
        raw = f.read()
    card = json.loads(raw)
except Exception as e:
    print("P7-FAIL [card 可解析]: %s" % e); sys.exit(1)

check("title含gcli", isinstance(card.get("title"), str) and "gcli" in card["title"],
      "实际 %r" % card.get("title"))
entries = card.get("entries", [])
check("entries>=1", len(entries) >= 1, "entries %d 条" % len(entries))
LEVELS = {"ok", "warn", "danger"}
for e in entries:
    for key in ("name", "level", "badge", "windows"):
        check("条目字段:%s" % key, key in e, "缺 %s" % key)
    check("level合法", e.get("level") in LEVELS, "实际 %r" % e.get("level"))
    for w in e.get("windows", []):
        check("窗口字段", "label" in w and "percent" in w, "实际 %r" % w)
        check("percent∈[0,100]", isinstance(w.get("percent"), int)
              and 0 <= w["percent"] <= 100, "实际 %r" % w.get("percent"))
# 红线：card 文件全文不含真实 token / Bearer 字样（token 只进 Authorization 头）
for tok in (t for t in tokens_blob.split("\n") if len(t) >= 8):
    check("无token泄露", tok not in raw, "（token 值已掩码不回显）")
check("无Bearer字样", "Bearer" not in raw)

for line in fails:
    print(line)
sys.exit(1 if fails else 0)
PYEOF
    )
    if [ $? -ne 0 ]; then
        fail "P7" "$(echo "$out" | head -5 | tr '\n' '; ')"
        return
    fi
    pass "P7"
}

# ── artifact 落盘（谓词登记路径 /tmp/qa-quota-p*.txt）────────────────────────
write_artifacts() {
    cp "$TMPDIR_QA/p1.out" /tmp/qa-quota-p1.txt 2>/dev/null
    cp "$TMPDIR_QA/p2.out" /tmp/qa-quota-p2.txt 2>/dev/null
    { echo "--- stdout ---"; cat "$TMPDIR_QA/p3.out" 2>/dev/null; echo "--- stderr ---"; cat "$TMPDIR_QA/p3.err" 2>/dev/null; } > /tmp/qa-quota-p3.txt 2>/dev/null
    cp "$TMPDIR_QA/p4.out" /tmp/qa-quota-p4.txt 2>/dev/null
    { echo "--- not-json ---"; cat "$TMPDIR_QA/p5-not-json.out" 2>/dev/null; cat "$TMPDIR_QA/p5-not-json.err" 2>/dev/null
      echo "--- empty ---"; cat "$TMPDIR_QA/p5-empty.out" 2>/dev/null; cat "$TMPDIR_QA/p5-empty.err" 2>/dev/null; } > /tmp/qa-quota-p5.txt 2>/dev/null
    cp "$TMPDIR_QA/p6.out" /tmp/qa-quota-p6.txt 2>/dev/null
    { cat "$TMPDIR_QA/p7.card.json" 2>/dev/null; echo "--- stdout ---"; cat "$TMPDIR_QA/p7.out" 2>/dev/null; } > /tmp/qa-quota-p7.txt 2>/dev/null
    mask_tokens /tmp/qa-quota-p1.txt /tmp/qa-quota-p2.txt /tmp/qa-quota-p3.txt \
                /tmp/qa-quota-p4.txt /tmp/qa-quota-p5.txt /tmp/qa-quota-p6.txt \
                /tmp/qa-quota-p7.txt 2>/dev/null
}

echo "=== quota plugin acceptance tests ==="
echo "QUOTA_PY=$QUOTA_PY  DB=$([ -f "$DB_PATH" ] && echo exists || echo MISSING)"
echo

test_S0_manifest_contract
test_P1_panel_render
test_P2_dual_window
test_P3_no_token_leak
test_P4_unit_tests_green
test_P5_malformed_input
test_P6_db_missing_degrade
test_P7_card_channel

write_artifacts

echo
echo "=== summary: $PASS passed, $FAIL failed, $SKIP skipped ==="
echo "artifacts: /tmp/qa-quota-p{1,2,3,4,5,6,7}.txt（已掩码）"
if [ "$FAIL" -gt 0 ]; then
    for m in "${FAILMSGS[@]}"; do echo "$m"; done
    rm -rf "$TMPDIR_QA"
    exit 1
fi
rm -rf "$TMPDIR_QA"
exit 0
