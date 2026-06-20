#!/bin/bash
# qzh-exec 路由 shell 测试（T3.3）
#
# 验证 qzh-exec 的查询/路由逻辑（mock pgrep，不真改系统）：
#   1. 首次查询（selection 空）→ 状态文本 + 候选 JSON 写入 BUDDY_OUTPUT_CANDIDATES
#   2. 未知 selection → 友好错误 + exit 1（不执行任何动作）
#   3. 空输入 → 降级文本 + exit 0
#   4. 候选 JSON 结构正确（id/title/selection）
#
# 契约引用：state.md ## 契约规约 C2（LauncherCandidate 字段）+ §4（qzh-exec 路由）。
# 注意：本测试 mock pgrep（注入假 pgrep 到 PATH 前缀），不真实 bootout/bootstrap（那是人工冒烟）。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
QZH_EXEC="$SCRIPT_DIR/../../Sources/ClaudeCodeBuddy/Marketplace/plugins/qzh/qzh-exec"

PASS=0
FAIL=0

assert_contains() {
    local label="$1" haystack="$2" needle="$3"
    if echo "$haystack" | grep -qF "$needle"; then
        echo "  ✓ $label"
        PASS=$((PASS + 1))
    else
        echo "  ✗ $label (未找到: '$needle')"
        echo "    实际输出: $haystack"
        FAIL=$((FAIL + 1))
    fi
}

assert_eq() {
    local label="$1" actual="$2" expected="$3"
    if [ "$actual" = "$expected" ]; then
        echo "  ✓ $label"
        PASS=$((PASS + 1))
    else
        echo "  ✗ $label (期望: '$expected', 实际: '$actual')"
        FAIL=$((FAIL + 1))
    fi
}

# 构造 mock 环境：临时 PATH 前缀，注入假 pgrep（返回「进程存在」）
make_mock_env() {
    local tmp_bin="$1"
    mkdir -p "$tmp_bin"
    # 假 pgrep：任何 -x 调用都返回 0（进程存在）
    cat > "$tmp_bin/pgrep" <<'EOF'
#!/bin/bash
# mock pgrep：总是返回 0（进程存在），让 status_text 输出「运行中」
exit 0
EOF
    chmod 755 "$tmp_bin/pgrep"
}

echo "▶ qzh-exec 路由测试"

# ========== 测试 1：首次查询 → 状态文本 + 候选 JSON ==========
echo "测试 1：首次查询（selection 空）→ 状态文本 + 候选 JSON"
TMPBIN=$(mktemp -d)
make_mock_env "$TMPBIN"
CAND_FILE=$(mktemp)
OUTPUT=$(echo '{"query":"qzh","sessionId":"s1","cwd":"/tmp"}' \
    | PATH="$TMPBIN:$PATH" BUDDY_OUTPUT_CANDIDATES="$CAND_FILE" bash "$QZH_EXEC" 2>&1)
EXIT1=$?

assert_eq "exit code = 0" "$EXIT1" "0"
assert_contains "stdout 含状态标题" "$OUTPUT" "QzhddrSrv 监控状态"
assert_contains "stdout 含主服务状态" "$OUTPUT" "主服务"
assert_contains "stdout 含运行中" "$OUTPUT" "运行中"

# 候选 JSON 结构校验
CAND_CONTENT=$(cat "$CAND_FILE")
echo "$CAND_CONTENT" | jq -e '.[0].id == "stop" and .[0].title == "关闭监控" and .[0].selection == "stop"' >/dev/null 2>&1 \
    && { echo "  ✓ 候选[0] 结构正确 (stop)"; PASS=$((PASS + 1)); } \
    || { echo "  ✗ 候选[0] 结构错误: $CAND_CONTENT"; FAIL=$((FAIL + 1)); }
echo "$CAND_CONTENT" | jq -e '.[1].id == "start" and .[1].title == "打开监控" and .[1].selection == "start"' >/dev/null 2>&1 \
    && { echo "  ✓ 候选[1] 结构正确 (start)"; PASS=$((PASS + 1)); } \
    || { echo "  ✗ 候选[1] 结构错误: $CAND_CONTENT"; FAIL=$((FAIL + 1)); }

rm -rf "$TMPBIN" "$CAND_FILE"

# ========== 测试 2：未知 selection → 错误 + exit 1 ==========
echo "测试 3：未知 selection → 友好错误 + exit 1（不执行任何动作）"
OUTPUT=$(echo '{"query":"qzh","sessionId":"s1","cwd":"/tmp","selection":"delete"}' \
    | bash "$QZH_EXEC" 2>&1)
EXIT3=$?
assert_eq "exit code = 1" "$EXIT3" "1"
assert_contains "stderr 含未知操作" "$OUTPUT" "未知操作"
assert_contains "stderr 含仅支持 stop/start" "$OUTPUT" "stop/start"

# ========== 测试 4：空输入（command route 剥关键词后）→ 查状态 + exit 0 ==========
echo "测试 4：空输入（query + selection 都空，如 command route 输入 qzh 剥后）→ 查状态 + exit 0"
OUTPUT=$(echo '{"query":"","sessionId":"s1","cwd":"/tmp"}' \
    | bash "$QZH_EXEC" 2>&1)
EXIT4=$?
assert_eq "exit code = 0" "$EXIT4" "0"
assert_contains "stdout 含状态文本" "$OUTPUT" "QzhddrSrv 监控状态"

# ========== 测试 5：jq 不可用 → 降级（requiredPath 守护前置，此处仅验脚本鲁棒）==========
# 注：requiredPath:["jq"] 在 StdinExecutor 层拦截，qzh-exec 假设 jq 可用。跳过。

echo ""
echo "▶ 结果: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
