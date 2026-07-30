#!/bin/bash
# buddy_hook_timeout.acceptance.test.sh
#
# 红队验收测试：buddy-hook.sh 2s 超时修复（osascript 0.5s 守护 + best-effort terminal_id）
#
# 黑盒契约断言（不读实现细节）：基于设计文档契约规约 + 验收场景谓词 P1-P7。
# 期望值字面量逐字取自 ## 验收场景 assert 列。
#
# 覆盖谓词：
#   P1 [det-machine]  bash -n plugin/scripts/buddy-hook.sh 退出码 0
#   P2 [det-machine]  diff plugin/scripts/buddy-hook.sh hooks/buddy-hook.sh 无输出
#   P3 [det-machine]  grep -c '$_BUDDY_TIMEOUT osascript' == 2（两个 osascript 前有守护）
#   P4 [det-machine]  _BUDDY_TIMEOUT 检测块含 command -v timeout 与 command -v gtimeout 双回退
#   P5 [det-machine]  grep -c '"timeout": 2' plugin/hooks/hooks.json == 8（8 事件未误改）
#   P6 [det-machine]  SessionStart 段 tab title osascript 仍是 subprocess.Popen 异步（未误改）
#   P7 [freshness]    留 QA 真机判定（需覆盖 cache 跑真 session 扫 transcript）—— 见文末标注
#
# 补充契约守护（契约规约不变量）：
#   C-SOCKET-ABSENT   socket 不存在 → 静默 exit 0（不变）
#   C-TERMINAL-ID     terminal_id 字段处理存在（可选字段，缺失不影响 socket 消息）
#   C-CACHE           /tmp/claude-buddy-terminals/$SESSION_ID 缓存路径存在
#
# 红队红线：
#   - 强断言 [ ... ] / test，失败必挂测试；禁 warn/skip/try-catch 吞异常
#   - 仅静态契约断言（bash -n / grep / diff）+ 黑盒行为断言（mock socket 不存在）
#   - 不读 buddy-hook.sh 实现细节照抄（基于契约，非基于实现）
#
# 测试 WILL NOT pass 直到蓝队合并实现 —— 这是预期的 TDD 红灯（当前 P3/P4 为红）。

set -euo pipefail

PASS=0
FAIL=0
FAILMSGS=()

# ---------- helpers ----------

pass() {
    PASS=$((PASS + 1))
    echo "  ✓ PASS [$1]"
}

fail() {
    FAIL=$((FAIL + 1))
    FAILMSGS+=("FAIL [$1]: $2")
    echo "  ✗ FAIL [$1]: $2" >&2
}

# grep 计数（set -e 安全；无匹配或文件缺失返回 0）
grep_count() {
    local file="$1" pattern="$2"
    local n
    n=$(grep -c -- "$pattern" "$file" 2>/dev/null || true)
    echo "${n:-0}"
}

# 探测 repo root：从脚本目录向上找 plugin/scripts/buddy-hook.sh
detect_repo_root() {
    local d
    d="$(cd "$(dirname "$0")" && pwd)"
    while [ "$d" != "/" ]; do
        if [ -f "$d/plugin/scripts/buddy-hook.sh" ] && [ -f "$d/plugin/hooks/hooks.json" ]; then
            echo "$d"
            return 0
        fi
        d="$(dirname "$d")"
    done
    return 1
}

# ---------- 路径定位 ----------

if [ -z "${PROJECT_ROOT:-}" ]; then
    PROJECT_ROOT="$(detect_repo_root)" || {
        echo "FATAL: 无法定位 repo root（未找到 plugin/scripts/buddy-hook.sh）" >&2
        exit 1
    }
fi

PLUGIN_HOOK="$PROJECT_ROOT/plugin/scripts/buddy-hook.sh"
HOOKS_HOOK="$PROJECT_ROOT/hooks/buddy-hook.sh"
HOOKS_JSON="$PROJECT_ROOT/plugin/hooks/hooks.json"

echo "=== Acceptance Test: buddy-hook.sh 2s 超时修复 ==="
echo "repo root: $PROJECT_ROOT"
echo "plugin hook: $PLUGIN_HOOK"
echo ""

# 前置：测试对象存在（否则所有断言无意义）
if [ ! -f "$PLUGIN_HOOK" ]; then
    echo "FATAL: $PLUGIN_HOOK 不存在" >&2
    exit 1
fi
if [ ! -f "$HOOKS_JSON" ]; then
    echo "FATAL: $HOOKS_JSON 不存在" >&2
    exit 1
fi

# =====================================================================
# P1 [det-machine]: bash -n plugin/scripts/buddy-hook.sh 退出码 0
# observe: 退出码；assert: ==0
# =====================================================================
echo "[P1] bash -n 语法合法..."
if bash -n "$PLUGIN_HOOK" 2>/dev/null; then
    pass "P1: bash -n 退出码 0（语法合法）"
else
    fail "P1: bash -n 退出码非 0（语法错误）"
fi

# =====================================================================
# P2 [det-machine]: diff plugin/scripts/buddy-hook.sh hooks/buddy-hook.sh 无输出
# observe: diff stdout；assert: 为空（两镜像同步）
# =====================================================================
echo "[P2] 两镜像同步（plugin ↔ hooks）..."
if [ ! -f "$HOOKS_HOOK" ]; then
    fail "P2: hooks/buddy-hook.sh 不存在，无法 diff"
else
    diff_out=$(diff "$PLUGIN_HOOK" "$HOOKS_HOOK" 2>&1 || true)
    if [ -z "$diff_out" ]; then
        pass "P2: diff 无输出（两镜像同步）"
    else
        fail "P2: 镜像不同步: $diff_out"
    fi
fi

# =====================================================================
# P3 [det-machine]: 两个 osascript 调用前均含 $_BUDDY_TIMEOUT
# observe: grep -c '$_BUDDY_TIMEOUT osascript'；assert: ==2
# =====================================================================
echo "[P3] 两个 osascript 前有 \$_BUDDY_TIMEOUT 守护..."
p3=$(grep_count "$PLUGIN_HOOK" '$_BUDDY_TIMEOUT osascript')
if [ "$p3" -eq 2 ]; then
    pass "P3: \$_BUDDY_TIMEOUT osascript 计数 == 2（count=${p3}）"
else
    fail "P3: \$_BUDDY_TIMEOUT osascript 计数期望 2, 实际 $p3"
fi

# =====================================================================
# P4 [det-machine]: _BUDDY_TIMEOUT 检测块含 timeout/gtimeout 双回退
# observe: grep 检测块；assert: 同时含 command -v timeout 与 command -v gtimeout
# =====================================================================
echo "[P4] _BUDDY_TIMEOUT 检测块含 timeout/gtimeout 双回退..."
p4_timeout=0
p4_gtimeout=0
if grep -q -- 'command -v timeout' "$PLUGIN_HOOK" 2>/dev/null; then
    p4_timeout=1
fi
if grep -q -- 'command -v gtimeout' "$PLUGIN_HOOK" 2>/dev/null; then
    p4_gtimeout=1
fi
if [ "$p4_timeout" -eq 1 ] && [ "$p4_gtimeout" -eq 1 ]; then
    pass "P4: 检测块同时含 'command -v timeout' 与 'command -v gtimeout'"
else
    fail "P4: 检测块双回退缺失（timeout=$p4_timeout, gtimeout=${p4_gtimeout}）"
fi

# =====================================================================
# P5 [det-machine]: hooks.json timeout 仍为 2（未误改）
# observe: grep -c '"timeout": 2' plugin/hooks/hooks.json；assert: ==8
# =====================================================================
echo "[P5] hooks.json 8 事件 timeout 仍为 2..."
p5=$(grep_count "$HOOKS_JSON" '"timeout": 2')
if [ "$p5" -eq 8 ]; then
    pass "P5: \"timeout\": 2 计数 == 8（8 事件未误改）"
else
    fail "P5: \"timeout\": 2 计数期望 8, 实际 $p5"
fi

# =====================================================================
# P6 [det-machine]: SessionStart 段 tab title osascript 仍是 subprocess.Popen 异步
# observe: grep subprocess.Popen；assert: 存在且在 tab title 段（未误改为同步阻塞）
# =====================================================================
echo "[P6] SessionStart tab title osascript 仍是 subprocess.Popen 异步..."
p6=$(grep_count "$PLUGIN_HOOK" 'subprocess.Popen')
if [ "$p6" -ge 1 ]; then
    pass "P6: subprocess.Popen 存在（count=${p6}，tab title 异步注入未误改）"
else
    fail "P6: subprocess.Popen 未找到（tab title 可能被误改为同步阻塞）"
fi

# 辅助：确认 tab title 相关 osascript 仍存在（SessionStart 副作用未删）
# 设计契约：SessionStart 异步注入 Ghostty tab title（subprocess.Popen，不阻塞）
p6b=$(grep_count "$PLUGIN_HOOK" 'osascript')
if [ "$p6b" -ge 3 ]; then
    pass "P6b: osascript 计数 >= 3（count=${p6b}，含 2 个 terminal ID 查询 + tab title 注入）"
else
    fail "P6b: osascript 计数期望 >= 3, 实际 ${p6b}（tab title 段可能被误删）"
fi

# =====================================================================
# P7 [freshness]: 改后源码覆盖 cache 后，新 session 首事件 buddy-hook.sh 超时数归零
# FRESHNESS: 留 QA 真机判定（需覆盖 cache 跑真 session 扫 transcript）
# 不自动化：需真实 Ghostty + 真实 Claude Code session + transcript 扫描
# =====================================================================
echo "[P7] FRESHNESS: 留 QA 真机判定（需覆盖 cache 跑真 session 扫 transcript，本机有 timeout 期望 0）"
echo "     → QA 流程：rm -rf /tmp/claude-buddy-terminals/* 触发首事件 → 跑 50 session → jq 扫 transcript 超时计数 → assert 大幅下降（期望 0）"
# 不做自动化断言（freshness 谓词，非 det-machine）

# =====================================================================
# 补充契约守护 C-SOCKET-ABSENT: socket 不存在 → 静默 exit 0
# 契约规约：[ -S "$SOCKET_PATH" ] || exit 0（不变）
# 黑盒行为断言：指向不存在的 socket，验证退出码 0 + 无 stdout
# =====================================================================
echo "[C-SOCKET-ABSENT] socket 不存在 → 静默 exit 0..."
NONEXISTENT_SOCK="/tmp/nonexistent-buddy-sock-red-team-$$"
rm -f "$NONEXISTENT_SOCK" 2>/dev/null || true
# 双保险确认 socket 不存在
if [ -S "$NONEXISTENT_SOCK" ]; then
    fail "C-SOCKET-ABSENT: 测试 socket 意外存在，无法验证"
else
    set +e
    sock_out=$(BUDDY_SOCKET_PATH="$NONEXISTENT_SOCK" bash "$PLUGIN_HOOK" \
        <<< '{"hook_event_name":"Notification","session_id":"red-team-silent"}' 2>&1)
    sock_ec=$?
    set -e
    if [ "$sock_ec" -eq 0 ] && [ -z "$sock_out" ]; then
        pass "C-SOCKET-ABSENT: socket 不存在时 exit 0 且无输出（ec=${sock_ec}）"
    elif [ "$sock_ec" -eq 0 ]; then
        fail "C-SOCKET-ABSENT: 退出码 0 但有输出（非静默）: $sock_out"
    else
        fail "C-SOCKET-ABSENT: 期望 exit 0, 实际 ec=$sock_ec, out=$sock_out"
    fi
fi

# =====================================================================
# 补充契约守护 C-TERMINAL-ID: terminal_id 字段处理存在
# 契约规约：terminal_id 是可选字段；Python 段 if terminal_id: 才填
# =====================================================================
echo "[C-TERMINAL-ID] terminal_id 字段处理存在..."
c_tid=$(grep_count "$PLUGIN_HOOK" 'terminal_id')
if [ "$c_tid" -ge 1 ]; then
    pass "C-TERMINAL-ID: terminal_id 字段处理存在（count=${c_tid}）"
else
    fail "C-TERMINAL-ID: terminal_id 字段处理未找到（可选字段逻辑可能被误删）"
fi

# =====================================================================
# 补充契约守护 C-CACHE: 缓存路径 /tmp/claude-buddy-terminals/$SESSION_ID 存在
# 契约规约：首事件捕获后写 /tmp/claude-buddy-terminals/${SESSION_ID}（1440min 过期）
# =====================================================================
echo "[C-CACHE] terminal ID 缓存路径存在..."
c_cache=$(grep_count "$PLUGIN_HOOK" 'claude-buddy-terminals')
if [ "$c_cache" -ge 1 ]; then
    pass "C-CACHE: 缓存路径 claude-buddy-terminals 存在（count=${c_cache}）"
else
    fail "C-CACHE: 缓存路径 claude-buddy-terminals 未找到（缓存逻辑可能被误删）"
fi

# =====================================================================
# 补充契约守护 C-EVENT-MAP: 事件映射关键字存在（防止误删映射逻辑）
# 契约规约：SessionStart→session_start, PreToolUse→tool_start,
#   PostToolUse→tool_end, Stop→task_complete, SessionEnd→session_end,
#   Notification/UserPromptSubmit→thinking, PermissionRequest→permission_request, 其他→idle
# =====================================================================
echo "[C-EVENT-MAP] 事件映射关键字存在..."
c_es=$(grep_count "$PLUGIN_HOOK" 'session_start')
c_ts=$(grep_count "$PLUGIN_HOOK" 'tool_start')
c_te=$(grep_count "$PLUGIN_HOOK" 'tool_end')
c_tc=$(grep_count "$PLUGIN_HOOK" 'task_complete')
c_ee=$(grep_count "$PLUGIN_HOOK" 'session_end')
if [ "$c_es" -ge 1 ] && [ "$c_ts" -ge 1 ] && [ "$c_te" -ge 1 ] \
   && [ "$c_tc" -ge 1 ] && [ "$c_ee" -ge 1 ]; then
    pass "C-EVENT-MAP: 事件映射关键字齐全（session_start/tool_start/tool_end/task_complete/session_end）"
else
    fail "C-EVENT-MAP: 事件映射缺失（session_start=$c_es, tool_start=$c_ts, tool_end=$c_te, task_complete=$c_tc, session_end=${c_ee}）"
fi

# =====================================================================
# Summary
# =====================================================================
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
    echo "--- 失败用例 ---" >&2
    for m in "${FAILMSGS[@]}"; do
        echo "  $m" >&2
    done
fi

# 强断言：任何失败 → 非 0 退出
[ "$FAIL" -eq 0 ]
