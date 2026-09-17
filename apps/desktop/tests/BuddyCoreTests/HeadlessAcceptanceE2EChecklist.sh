#!/bin/bash
# E2E 验收清单 —— 猫上限去除与后台任务展示（real-process / 真机端到端）
#
# 用途：in-process XCTest 无法覆盖的谓词（真实 claude -p 冒烟、真实 app 重启、真实终端 tab
# 激活、产物新鲜度），需真跑 buddy CLI binary + 真 app 进程 + 真实终端。
# 由 QA 在真机驱动（参照 ToolsRunE2EChecklist.sh 先例），非 CI 单测。
# 所有断言硬退出码；证据落 /tmp/autopilot-artifacts/。
#
# 前置：
#   cd apps/desktop && SKIP_FETCH_PLUGINS=1 make bundle
#   pkill -f ClaudeCodeBuddy; sleep 1; open apps/desktop/ClaudeCodeBuddy.app
#   sleep 3  # 等 app 起 socket
#
# 谓词覆盖（design SSOT：.autopilot/runtime/requirements/20260917-开始实现/state.md）：
#   S1-P3 real-process  buddy session start + emit 真实驱动 → exit == 0 && stdout 含 <session-id>
#   S2-P3 real-process  真实 claude -p 冒烟：claude_exit == 0 && app 登记 is_headless && 不上屏
#   S4-P4 det-machine   后台会话存续期间全部终端 tab title 与基线逐项相等（●label 污染症状回归）
#   S5-P2 real-process  buddy click A → jump_terminal_id == tid_A（app 日志 jump 事件）
#   S5-P3 real-process  随后 click B → 激活切为 B 且 != A（交叉不串扰）
#   S5-P4 det-machine   真实 terminal_id 已上报后 fallback_override_count == 0（app 日志）
#   S6-P3 real-process  真实重启 app：status exit == 0 && pid 焕新
#   S6-P4 det-machine   被测 app 产物比 desktop 全部源文件新（freshness_check == FRESH）
#   S9-P2 det-machine   debug 猫 is_debug == true && tab_name == debug-<id>（真 app inspect）
#
# CONTRACT_AMBIGUOUS（QA 判读时注意）：
#   - buddy status 行 headless 标记的精确格式（C-INSPECT-FIELD 写「如 headless=yes」），脚本按
#     大小写不敏感 grep "headless" 兜底；
#   - app 日志 jump/activate 事件的 msg 关键词未在契约冻结，脚本按 terminal_id 值 + jump/activate
#     关键词组合匹配；若全空需人工核对 buddy log show --json。

set -uo pipefail

BUDDY="${BUDDY:-/usr/local/bin/buddy}"
APP_BUNDLE="${APP_BUNDLE:-/Applications/ClaudeCodeBuddy.app}"
[ -d "$APP_BUNDLE" ] || APP_BUNDLE="$(pwd)/ClaudeCodeBuddy.app"
ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp/autopilot-artifacts}"
DESKTOP_SRC_DIR="${DESKTOP_SRC_DIR:-$(cd "$(dirname "$0")/../../Sources" && pwd)}"
mkdir -p "$ARTIFACT_DIR"

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; E2E_FAILS=$((E2E_FAILS+1)); }
E2E_FAILS=0

preflight() {
    if ! "$BUDDY" ping >/dev/null 2>&1; then
        fail "preflight: app 未运行（buddy ping 失败）——先执行前置步骤"
        exit 1
    fi
}

# 终端 tab title 快照（AX 只读；优先 Ghostty，退化 Terminal.app）
tab_titles() {
    local app="${1:-Ghostty}"
    osascript -e "tell application \"System Events\" to tell process \"$app\" to get value of static text 1 of every tab of window 1" 2>/dev/null \
      || osascript -e "tell application \"System Events\" to tell process \"Terminal\" to get name of every tab of window 1" 2>/dev/null \
      || echo "__AX_UNAVAILABLE__"
}

echo "=== S1-P3: buddy session start + emit 真实驱动 ==="
S1SID="redteam-e2e-$(date +%s)"
"$BUDDY" session start --id "$S1SID" --cwd /tmp > "$ARTIFACT_DIR/s1p3.out" 2>&1
S1EXIT=$?
"$BUDDY" emit thinking --id "$S1SID" >> "$ARTIFACT_DIR/s1p3.out" 2>&1
S1EMIT=$?
if [ "$S1EXIT" -eq 0 ] && [ "$S1EMIT" -eq 0 ] && grep -q "$S1SID" "$ARTIFACT_DIR/s1p3.out"; then
    pass "S1-P3: session start/emit exit==0 且 stdout 含 <session-id>"
else
    fail "S1-P3: start_exit=$S1EXIT emit_exit=$S1EMIT stdout含id=$(grep -c "$S1SID" "$ARTIFACT_DIR/s1p3.out" 2>/dev/null || echo 0)（若 CLI 不回显 id 属 CONTRACT_AMBIGUOUS，需人工核对 s1p3.out）"
fi
"$BUDDY" session end --id "$S1SID" >/dev/null 2>&1

echo "=== S2-P3: 真实 claude -p 冒烟 ==="
if ! command -v claude >/dev/null 2>&1; then
    fail "S2-P3: claude CLI 不存在，无法冒烟（QA 机需安装 claude）"
else
    TAB_BASELINE_S2="$(tab_titles)"
    claude -p "Reply with exactly: ok" --output-format text > "$ARTIFACT_DIR/s2p3-claude.out" 2>&1 &
    CLAUDE_PID=$!
    SEEN_HEADLESS=no
    for _ in $(seq 1 60); do
        kill -0 "$CLAUDE_PID" 2>/dev/null || break
        if "$BUDDY" status 2>/dev/null | grep -qi "headless"; then SEEN_HEADLESS=yes; break; fi
        sleep 1
    done
    wait "$CLAUDE_PID"
    CLAUDE_EXIT=$?
    "$BUDDY" status > "$ARTIFACT_DIR/s2p3-status-during.out" 2>&1 || true
    if [ "$CLAUDE_EXIT" -eq 0 ] && [ "$SEEN_HEADLESS" = "yes" ]; then
        pass "S2-P3: claude exit==0 且 app 登记期间 status 出现 headless 标记"
    else
        fail "S2-P3: claude_exit=$CLAUDE_EXIT seen_headless=${SEEN_HEADLESS}（登记窗口判定见 $ARTIFACT_DIR/s2p3-status-during.out）"
    fi
    # S4-P4 联动：claude -p（后台会话）存续前后，全部终端 tab title 逐项相等（无 ●label 污染）
    TAB_AFTER_S2="$(tab_titles)"
    if [ "$TAB_BASELINE_S2" = "__AX_UNAVAILABLE__" ]; then
        fail "S4-P4: 终端 AX 读取不可用，无法做 tab title 基线比对（需 Ghostty/Terminal 前台窗口）"
    elif [ "$TAB_BASELINE_S2" = "$TAB_AFTER_S2" ]; then
        pass "S4-P4: 后台会话存续前后全部终端 tab title 逐项相等（titles_after == titles_before）"
    else
        fail "S4-P4: tab title 漂移——before=[$TAB_BASELINE_S2] after=[$TAB_AFTER_S2]"
    fi
fi

echo "=== S5-P2/P3/P4: 交互会话点击跳转正确 tab（需 ≥2 个已绑定 terminal_id 的交互会话）==="
# 依赖 QA 环境存在两个真实终端 tab 中运行的交互会话（hook 已上报真实 terminal_id）。
"$BUDDY" status > "$ARTIFACT_DIR/s5-status.out" 2>&1 || true
# 自动发现已绑定的交互会话：从 status 行提取候选 id，逐个 inspect 直到拿到两个非空 terminal_id
declare -a BOUND_IDS=()
declare -a BOUND_TIDS=()
for cand in $(cat "$ARTIFACT_DIR/s5-status.out" | tr ' ' '\n' | grep -E '^[A-Za-z0-9_-]{6,}$' | head -20); do
    INS="$("$BUDDY" inspect --id "$cand" 2>/dev/null || true)"
    TID="$(echo "$INS" | jq -r '.data.session.terminal_id // empty' 2>/dev/null || true)"
    if [ -n "$TID" ]; then
        BOUND_IDS+=("$cand"); BOUND_TIDS+=("$TID")
        [ "${#BOUND_IDS[@]}" -ge 2 ] && break
    fi
done
if [ "${#BOUND_IDS[@]}" -lt 2 ]; then
    fail "S5-P2/P3: 环境中未发现 2 个已绑定 terminal_id 的交互会话（需在两个真实终端 tab 各跑一个 claude 会话后重跑）"
else
    ID_A="${BOUND_IDS[0]}"; TID_A="${BOUND_TIDS[0]}"
    ID_B="${BOUND_IDS[1]}"; TID_B="${BOUND_TIDS[1]}"
    "$BUDDY" log clear --yes >/dev/null 2>&1 || true

    "$BUDDY" click --id "$ID_A" > "$ARTIFACT_DIR/s5p2-click.out" 2>&1
    sleep 2
    "$BUDDY" log show --json > "$ARTIFACT_DIR/s5p2-log.jsonl" 2>/dev/null || true
    if grep -qi "$TID_A" "$ARTIFACT_DIR/s5p2-log.jsonl" && grep -qiE 'jump|activate|tab' "$ARTIFACT_DIR/s5p2-log.jsonl"; then
        pass "S5-P2: click A 后日志出现引用 tid_A($TID_A) 的 jump/activate 事件"
    else
        fail "S5-P2: 未在 app 日志发现 jump_terminal_id == tid_A($TID_A) 的事件（CONTRACT_AMBIGUOUS：日志关键词未冻结，请人工核对 $ARTIFACT_DIR/s5p2-log.jsonl）"
    fi

    "$BUDDY" click --id "$ID_B" > "$ARTIFACT_DIR/s5p3-click.out" 2>&1
    sleep 2
    "$BUDDY" log show --json > "$ARTIFACT_DIR/s5p3-log.jsonl" 2>/dev/null || true
    LAST_JUMP_B="$(grep -i "$TID_B" "$ARTIFACT_DIR/s5p3-log.jsonl" | tail -1 || true)"
    if [ -n "$LAST_JUMP_B" ] && ! grep -qi "$TID_A" <(tail -5 "$ARTIFACT_DIR/s5p3-log.jsonl" | grep -iE 'jump|activate|tab' | grep -v "$TID_B"); then
        pass "S5-P3: click B 后激活切为 B（最近 jump 引用 tid_B 且 != tid_A）"
    else
        fail "S5-P3: 最近激活未指向 B（last=[$LAST_JUMP_B]，见 $ARTIFACT_DIR/s5p3-log.jsonl）"
    fi

    # S5-P4：日志中无 fallback 覆盖类事件（真实 terminal_id 上报后不被兜底覆盖）
    FALLBACK_HITS="$(grep -icE 'fallback.*(override|覆盖|clobber)' "$ARTIFACT_DIR/s5p3-log.jsonl" 2>/dev/null || echo 0)"
    if [ "$FALLBACK_HITS" -eq 0 ]; then
        pass "S5-P4: fallback_override_count == 0"
    else
        fail "S5-P4: 发现 $FALLBACK_HITS 条 fallback 覆盖类日志"
    fi
fi

echo "=== S6-P3: 真实重启 app → IPC 恢复可服务 + pid 焕新 ==="
PID_BEFORE="$(pgrep -f 'ClaudeCodeBuddy.app/Contents/MacOS/ClaudeCodeBuddy' | head -1)"
pkill -f 'ClaudeCodeBuddy.app/Contents/MacOS/ClaudeCodeBuddy' 2>/dev/null || true
sleep 2
open "$APP_BUNDLE"
PID_AFTER=""
for _ in $(seq 1 30); do
    sleep 1
    if "$BUDDY" ping >/dev/null 2>&1; then
        PID_AFTER="$(pgrep -f 'ClaudeCodeBuddy.app/Contents/MacOS/ClaudeCodeBuddy' | head -1)"
        break
    fi
done
"$BUDDY" status > "$ARTIFACT_DIR/s6p3-status.out" 2>&1
S6EXIT=$?
if [ "$S6EXIT" -eq 0 ] && [ -n "$PID_AFTER" ] && [ "$PID_AFTER" != "$PID_BEFORE" ]; then
    pass "S6-P3: 重启后 status exit==0 且 pid 焕新（$PID_BEFORE → $PID_AFTER）"
else
    fail "S6-P3: status_exit=$S6EXIT pid_before=$PID_BEFORE pid_after=$PID_AFTER"
fi

echo "=== S6-P4: 产物新鲜度（app 产物比 desktop 全部源文件新）==="
APP_BIN="$APP_BUNDLE/Contents/MacOS/ClaudeCodeBuddy"
if [ ! -x "$APP_BIN" ]; then
    fail "S6-P4: 找不到 app 可执行文件 $APP_BIN"
else
    NEWEST_SRC="$(find "$DESKTOP_SRC_DIR" -name '*.swift' -newer "$APP_BIN" | head -3)"
    if [ -z "$NEWEST_SRC" ]; then
        echo "FRESH"
        pass "S6-P4: freshness_check == FRESH（无比产物更新的源文件）"
    else
        echo "STALE"
        fail "S6-P4: 产物过期，以下源文件比 app 产物新：$NEWEST_SRC（先重新 make bundle）"
    fi
fi

echo "=== S9-P2: debug 猫标签语义不变（真 app inspect）==="
DBGID="debug-redteam-$(date +%s)"
"$BUDDY" session start --id "$DBGID" --cwd /tmp > "$ARTIFACT_DIR/s9p2-start.out" 2>&1
sleep 2   # debug 路径 fail-open 判型窗口
"$BUDDY" inspect --id "$DBGID" > "$ARTIFACT_DIR/s9p2-inspect.out" 2>&1
IS_DEBUG="$(jq -r '.data.cat.is_debug // empty' "$ARTIFACT_DIR/s9p2-inspect.out" 2>/dev/null || true)"
TAB_NAME="$(jq -r '.data.cat.tab_name // empty' "$ARTIFACT_DIR/s9p2-inspect.out" 2>/dev/null || true)"
if [ "$IS_DEBUG" = "true" ] && [ "$TAB_NAME" = "$DBGID" ]; then
    pass "S9-P2: debug 猫 is_debug == true && tab_name == $DBGID（常显标签语义保持）"
else
    fail "S9-P2: is_debug=$IS_DEBUG tab_name=$TAB_NAME（期望 is_debug==true && tab_name==$DBGID）"
fi
"$BUDDY" session end --id "$DBGID" >/dev/null 2>&1

echo ""
if [ "$E2E_FAILS" -eq 0 ]; then
    echo "ALL E2E CHECKS PASSED"
    exit 0
else
    echo "$E2E_FAILS E2E CHECK(S) FAILED"
    exit 1
fi
