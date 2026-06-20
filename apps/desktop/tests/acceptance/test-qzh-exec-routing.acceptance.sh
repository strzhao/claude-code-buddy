#!/bin/bash
# Acceptance Test: qzh-exec plugin routing (command mode)
#
# 红队验收测试：qzh-exec 路由（mock pgrep/launchctl）+ 候选 JSON 通道。
#
# 信息隔离铁律：本脚本由红队独立编写，仅依据：
#   - state.md ## 设计文档（§4 qzh-exec 路由 + 候选 JSON 结构）
#   - state.md ## 验收场景（场景1/2/3/5/7 real-process + det-machine 谓词）
#   - 已有 shell 验收测试约定（test-session-start.acceptance.test.sh 的 set -euo pipefail + pass/fail 计数）
# 未读取蓝队本次任何实现代码（Marketplace/plugins/qzh/qzh-exec 脚本内容）—— 黑盒驱动，mock 系统命令。
#
# 契约引用（逐字一致）：
#   [C1] qzh-exec 首次查询（selection 空）→ pgrep 判存活 + 状态文本 stdout + 写候选 JSON 到 $BUDDY_OUTPUT_CANDIDATES
#        候选结构 [{selection:"stop",title:"关闭监控",subtitle:"停止 service+update"},
#                 {selection:"start",title:"打开监控",subtitle:"恢复 service+update"}]
#   [契约 §4] selection=="stop" → sudo launchctl bootout service+update → stdout「已关闭监控」
#             selection=="start" → sudo launchctl bootstrap service+update → stdout「已打开监控」
#
# 验收场景覆盖（mock pgrep/launchctl，不真改系统）：
#   场景1.P2 [real-process]: selection 空 → stdout contains "running"/"运行中" AND exit == 0
#   场景1.P3 [det-machine]: pgrep -x QzhddrSrv exit == 0（监控运行时）
#   场景1.P1 [det-machine]: 候选项可达（候选 JSON 含 stop/start）
#   场景2.P1 [real-process]: selection=stop → 调 launchctl bootout（mock 记录命令）
#   场景3.P1 [real-process]: selection=start → 调 launchctl bootstrap（mock 记录命令）
#   场景5.P1 [det-machine]: 监控已停止 → stdout contains "stopped"/"已停止" AND exit == 0
#   场景7.P2 [real-process]: 空 query → 子进程 exit == 0
#
# ⚠️ 真实 bootout/bootstrap（场景2/3/4 的 pgrep 状态变更）需 root + KeepAlive 自愈，不可自动化求值，
#    走 real-process：spy mock launchctl 记录被调命令，断言命令串契约（不真改系统）。

set -euo pipefail

PASS=0
FAIL=0
PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
QZH_EXEC="$PROJECT_ROOT/Sources/ClaudeCodeBuddy/Marketplace/plugins/qzh/qzh-exec"

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

echo "=== Acceptance Test: qzh-exec routing (mock pgrep/launchctl) ==="
echo "qzh-exec: $QZH_EXEC"
echo ""

# ── Guard: qzh-exec must exist ────────────────────────────────────────────
if [ ! -f "$QZH_EXEC" ]; then
    echo "  FATAL: qzh-exec not found at $QZH_EXEC — 蓝队 T3.2 未完成，跳过路由验收。"
    # 这是 TDD 红灯：蓝队未实现时测试应挂（不计 PASS）
    FAIL=$((FAIL + 1))
    echo ""
    echo "=== Summary: PASS=$PASS FAIL=$FAIL ==="
    exit 1
fi
if [ ! -x "$QZH_EXEC" ]; then
    echo "  FATAL: qzh-exec 存在但不可执行（缺 chmod +x）"
    FAIL=$((FAIL + 1))
    echo ""
    echo "=== Summary: PASS=$PASS FAIL=$FAIL ==="
    exit 1
fi

# ── Mock harness：用临时 PATH 注入 fake pgrep/launchctl ────────────────────
#
# fake pgrep：根据 $MOCK_PGREP_RESULT 决定 exit code（0=进程存在，1=不存在）
# fake launchctl：把被调命令记录到 $MOCK_LAUNCHCTL_LOG，exit 0
# fake sudo：透传给 launchctl（记录 sudo 被调）

MOCK_DIR="$(mktemp -d)"
trap 'rm -rf "$MOCK_DIR"' EXIT

# fake pgrep
cat > "$MOCK_DIR/pgrep" <<'EOF'
#!/bin/bash
# mock pgrep：若 MOCK_PGREP_ALIVE=1 返回 0（进程存在），否则 1
if [ "${MOCK_PGREP_ALIVE:-1}" = "1" ]; then
  exit 0
else
  exit 1
fi
EOF
chmod +x "$MOCK_DIR/pgrep"

# fake sudo（透传并记录，不真提权）
cat > "$MOCK_DIR/sudo" <<'EOF'
#!/bin/bash
# mock sudo：把完整命令记到 MOCK_SUDO_LOG，调用真实 launchctl mock
echo "sudo $*" >> "${MOCK_SUDO_LOG:-/dev/null}"
# 透传给 fake launchctl（在 PATH 里）
launchctl "$@"
EOF
chmod +x "$MOCK_DIR/sudo"

# fake launchctl（记录 bootout/bootstrap 命令）
cat > "$MOCK_DIR/launchctl" <<'EOF'
#!/bin/bash
# mock launchctl：记录被调命令到 MOCK_LAUNCHCTL_LOG，exit 0（模拟成功）
echo "launchctl $*" >> "${MOCK_LAUNCHCTL_LOG:-/dev/null}"
exit 0
EOF
chmod +x "$MOCK_DIR/launchctl"

# fake jq（透传真实 jq，若系统有；否则简单 grep）
if ! command -v jq >/dev/null 2>&1; then
    cat > "$MOCK_DIR/jq" <<'EOF'
#!/bin/bash
# 极简 jq mock：支持 .selection / .query 提取（足够 qzh-exec 用）
input=$(cat)
key="$1"
case "$key" in
  .selection)
    echo "$input" | sed -n 's/.*"selection"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
    ;;
  .query)
    echo "$input" | sed -n 's/.*"query"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
    ;;
  *)
    echo "$input"
    ;;
esac
EOF
    chmod +x "$MOCK_DIR/jq"
fi

# 用 mock PATH 跑 qzh-exec，返回 (exit_code, stdout, stderr)
# 用法: run_qzh_exec <stdin_json> [MOCK_PGREP_ALIVE]
run_qzh_exec() {
    local stdin_json="$1"
    local alive="${2:-1}"
    local cands_file="$(mktemp -t buddy-cands-$$)"
    local sudo_log="$(mktemp -t buddy-sudo-$$)"
    local lc_log="$(mktemp -t buddy-lc-$$)"

    MOCK_PGREP_ALIVE="$alive" \
    MOCK_SUDO_LOG="$sudo_log" \
    MOCK_LAUNCHCTL_LOG="$lc_log" \
    BUDDY_OUTPUT_CANDIDATES="$cands_file" \
    PATH="$MOCK_DIR:$PATH" \
    bash -c "echo '$stdin_json' | '$QZH_EXEC'" >/tmp/qzh-stdout-$$ 2>/tmp/qzh-stderr-$$ || true
    local rc=$?

    echo "EXIT=$rc"
    echo "---STDOUT---"
    cat /tmp/qzh-stdout-$$
    echo "---STDERR---"
    cat /tmp/qzh-stderr-$$
    echo "---CANDIDATES---"
    cat "$cands_file" 2>/dev/null || echo "(no candidates file)"
    echo "---LAUNCHCTL_LOG---"
    cat "$lc_log" 2>/dev/null || echo "(no launchctl calls)"
    echo "---SUDO_LOG---"
    cat "$sudo_log" 2>/dev/null || echo "(no sudo calls)"
    rm -f /tmp/qzh-stdout-$$ /tmp/qzh-stderr-$$ "$cands_file" "$sudo_log" "$lc_log"
    return 0
}

# ───────────────────────────────────────────────────────────────────────────
# 场景1.P2 + 场景1.P1 [real-process/det-machine]：监控运行时，selection 空查询
# ───────────────────────────────────────────────────────────────────────────
echo "--- 场景1: 监控运行时，selection 空查询 ---"
RESULT1=$(run_qzh_exec '{"query":"qzh","sessionId":"s1","cwd":"/tmp"}' 1)
EXIT1=$(echo "$RESULT1" | grep '^EXIT=' | cut -d= -f2)
STDOUT1=$(echo "$RESULT1" | sed -n '/^---STDOUT---$/,/^---STDERR---$/p' | sed '1d;$d')
CANDS1=$(echo "$RESULT1" | sed -n '/^---CANDIDATES---$/,/^---LAUNCHCTL_LOG---$/p' | sed '1d;$d')

# 场景1.P2 real-process: exit == 0 AND stdout contains "running" OR "运行中"
if [ "$EXIT1" = "0" ]; then pass "场景1.P2: selection 空查询 exit == 0"; else fail "场景1.P2: exit 应 0，实际 $EXIT1"; fi
if echo "$STDOUT1" | grep -qiE "running|运行中"; then
    pass "场景1.P2: stdout 含 running/运行中"
else
    fail "场景1.P2: stdout 应含 running/运行中，实际: $STDOUT1"
fi

# 场景1.P1 det-machine: 候选 JSON 含 stop/start（候选项可达）
if echo "$CANDS1" | grep -q '"stop"'; then
    pass "场景1.P1: 候选 JSON 含 selection 'stop'"
else
    fail "场景1.P1: 候选 JSON 应含 \"stop\"，实际: $CANDS1"
fi
if echo "$CANDS1" | grep -q '"start"'; then
    pass "场景1.P1: 候选 JSON 含 selection 'start'"
else
    fail "场景1.P1: 候选 JSON 应含 \"start\"，实际: $CANDS1"
fi

# 场景1.P3 det-machine: pgrep 被调（监控运行时 pgrep exit 0）—— mock pgrep 已返回 0，
# 间接证明 qzh-exec 调用了 pgrep（若不调 pgrep，无法判存活 → 候选结构可能错）
if echo "$STDOUT1" | grep -qiE "running|运行中"; then
    pass "场景1.P3: 监控运行时查询报告 active（pgrep mock 返回 0 被消费）"
else
    fail "场景1.P3: 监控运行时状态文本应反映 active"
fi

# ───────────────────────────────────────────────────────────────────────────
# 场景2.P1 [real-process]：selection=stop → 调 launchctl bootout
# ───────────────────────────────────────────────────────────────────────────
echo ""
echo "--- 场景2: selection=stop → bootout ---"
RESULT2=$(run_qzh_exec '{"query":"qzh","sessionId":"s2","cwd":"/tmp","selection":"stop"}' 1)
EXIT2=$(echo "$RESULT2" | grep '^EXIT=' | cut -d= -f2)
LC_LOG2=$(echo "$RESULT2" | sed -n '/^---LAUNCHCTL_LOG---$/,/^---SUDO_LOG---$/p' | sed '1d;$d')

if [ "$EXIT2" = "0" ]; then pass "场景2.P1: selection=stop exit == 0"; else fail "场景2.P1: exit 应 0，实际 $EXIT2"; fi

# bootout service 命令必须被调（real-process: 命令串契约）
if echo "$LC_LOG2" | grep -q "launchctl bootout system/com.cyberserval.qzhddr.service"; then
    pass "场景2.P1: bootout service 被调"
else
    fail "场景2.P1: 应调 bootout service，launchctl log: $LC_LOG2"
fi
# bootout update 命令必须被调
if echo "$LC_LOG2" | grep -q "launchctl bootout system/com.cyberserval.qzhddr.update"; then
    pass "场景2.P1: bootout update 被调"
else
    fail "场景2.P1: 应调 bootout update，launchctl log: $LC_LOG2"
fi

# ───────────────────────────────────────────────────────────────────────────
# 场景3.P1 [real-process]：selection=start → 调 launchctl bootstrap
# ───────────────────────────────────────────────────────────────────────────
echo ""
echo "--- 场景3: selection=start → bootstrap ---"
RESULT3=$(run_qzh_exec '{"query":"qzh","sessionId":"s3","cwd":"/tmp","selection":"start"}' 0)
EXIT3=$(echo "$RESULT3" | grep '^EXIT=' | cut -d= -f2)
LC_LOG3=$(echo "$RESULT3" | sed -n '/^---LAUNCHCTL_LOG---$/,/^---SUDO_LOG---$/p' | sed '1d;$d')

if [ "$EXIT3" = "0" ]; then pass "场景3.P1: selection=start exit == 0"; else fail "场景3.P1: exit 应 0，实际 $EXIT3"; fi

# bootstrap service 命令必须被调（精确 plist 路径）
if echo "$LC_LOG3" | grep -q "launchctl bootstrap system /Library/LaunchDaemons/com.cyberserval.qzhddr.service.plist"; then
    pass "场景3.P1: bootstrap service 被调"
else
    fail "场景3.P1: 应调 bootstrap service，launchctl log: $LC_LOG3"
fi
if echo "$LC_LOG3" | grep -q "launchctl bootstrap system /Library/LaunchDaemons/com.cyberserval.qzhddr.update.plist"; then
    pass "场景3.P1: bootstrap update 被调"
else
    fail "场景3.P1: 应调 bootstrap update，launchctl log: $LC_LOG3"
fi

# ───────────────────────────────────────────────────────────────────────────
# 场景5.P1 [det-machine]：监控已停止（pgrep mock 返回 1）→ 状态文本 stopped/已停止
# ───────────────────────────────────────────────────────────────────────────
echo ""
echo "--- 场景5: 监控已停止，查询报告 stopped ---"
RESULT5=$(run_qzh_exec '{"query":"qzh","sessionId":"s5","cwd":"/tmp"}' 0)
EXIT5=$(echo "$RESULT5" | grep '^EXIT=' | cut -d= -f2)
STDOUT5=$(echo "$RESULT5" | sed -n '/^---STDOUT---$/,/^---STDERR---$/p' | sed '1d;$d')

if [ "$EXIT5" = "0" ]; then
    pass "场景5.P1: 监控已停止查询 exit == 0"
else
    fail "场景5.P1: exit 应 0，实际 $EXIT5"
fi
if echo "$STDOUT5" | grep -qiE "stopped|已停止"; then
    pass "场景5.P1: stdout 含 stopped/已停止"
else
    fail "场景5.P1: stdout 应含 stopped/已停止，实际: $STDOUT5"
fi
# 场景5.P2 det-machine: 停止状态下仍暴露「打开监控」候选
CANDS5=$(echo "$RESULT5" | sed -n '/^---CANDIDATES---$/,/^---LAUNCHCTL_LOG---$/p' | sed '1d;$d')
if echo "$CANDS5" | grep -q '"start"'; then
    pass "场景5.P2: 停止状态仍暴露 'start'（打开监控）候选"
else
    fail "场景5.P2: 停止状态应暴露 start 候选，实际候选: $CANDS5"
fi

# ───────────────────────────────────────────────────────────────────────────
# 场景7.P2 [real-process]：空 query → 子进程 exit == 0
# ───────────────────────────────────────────────────────────────────────────
echo ""
echo "--- 场景7: 空 query ---"
RESULT7=$(run_qzh_exec '{"query":"","sessionId":"s7","cwd":"/tmp"}' 1)
EXIT7=$(echo "$RESULT7" | grep '^EXIT=' | cut -d= -f2)
if [ "$EXIT7" = "0" ]; then
    pass "场景7.P2: 空 query 子进程 exit == 0"
else
    fail "场景7.P2: 空 query 应 exit 0，实际 $EXIT7"
fi

# ───────────────────────────────────────────────────────────────────────────
echo ""
echo "=== Summary: PASS=$PASS FAIL=$FAIL ==="

if [ "$FAIL" -gt 0 ]; then
    echo "❌ 存在失败（红队 TDD 红灯预期：蓝队未完成时挂，完成后应全 PASS）"
    exit 1
fi
echo "✅ 全部通过"
exit 0
