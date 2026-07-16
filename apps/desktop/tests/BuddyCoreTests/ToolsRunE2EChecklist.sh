#!/bin/bash
# E2E 验收清单 —— buddy tools / buddy run 真机端到端（Tier 1.5）
#
# 用途：单测（det-machine in-process）无法覆盖的场景，需真跑 buddy CLI binary + 真 app 进程。
# 由 QA Tier 1.5 真机驱动，非 CI 单测。
#
# 前置：
#   SKIP_FETCH_PLUGINS=1 make bundle
#   pkill -f ClaudeCodeBuddy; sleep 1; open apps/desktop/ClaudeCodeBuddy.app
#   sleep 3  # 等 app 起 socket
#
# 谓词覆盖（全 real-process / det-machine 但需真二进制）：
#   - 场景 3.P1-P5（动态增删）：单测已覆盖 in-process（test_T09），但真机验证 buddy launcher enable/disable
#     → buddy tools 反映（端到端 socket 链路）。
#   - 场景 4.P1-P4（TOFU modal 真拒绝）：单测不可靠（checkAndPrompt 弹框），真机清 trust → 用户点拒绝。
#   - 场景 5.P1-P4（app 未运行降级）：需 socket 不可达环境。
#   - 场景 11.P1-P3（真跑端到端）：真 binary + 真 app + image base64 可解码回 PNG。
#
# 不自动断言（需用户/QA 判断）：标 # MANUAL。
# 自动可断言：用 jq + test。

set -uo pipefail

BUDDY="${BUDDY:-/usr/local/bin/buddy}"
ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp/autopilot-artifacts}"
mkdir -p "$ARTIFACT_DIR"

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; E2E_FAILS=$((E2E_FAILS+1)); }
E2E_FAILS=0

echo "=== 场景 11: 真跑端到端冒烟（real-process）==="

# 场景 11.P1: buddy tools --json 真跑返回非空数组
$BUDDY tools --json > "$ARTIFACT_DIR/s11p1.out" 2>&1
TOOLS_EXIT=$?
if [ "$TOOLS_EXIT" -eq 0 ] && jq -e 'length >= 1' "$ARTIFACT_DIR/s11p1.out" >/dev/null 2>&1; then
    pass "11.P1: tools 真跑返回非空数组 + exit==0"
else
    fail "11.P1: tools 应返回非空数组且 exit==0（实际 exit=$TOOLS_EXIT）"
fi

# 场景 11.P2 + 11.P3: buddy run --json 含 stdout+exit_code + exit==0
# 选一个已信任的 command mode 插件（qr 是默认示例）
SELECTED_PLUGIN="${SELECTED_PLUGIN:-qr}"
$BUDDY run "$SELECTED_PLUGIN" --input '{"query":"https://example.com"}' --json > "$ARTIFACT_DIR/s11p2.out" 2>&1
RUN_EXIT=$?
if [ "$RUN_EXIT" -eq 0 ] && jq -e 'has("stdout") and has("exit_code")' "$ARTIFACT_DIR/s11p2.out" >/dev/null 2>&1; then
    pass "11.P2: run 返回含 stdout+exit_code"
    # 11.P3: 整链 exit 都 0（已在上面断言）
    if [ "$TOOLS_EXIT" -eq 0 ] && [ "$RUN_EXIT" -eq 0 ]; then
        pass "11.P3: tools_exit==0 AND run_exit==0"
    fi
else
    fail "11.P2/11.P3: run 应含 stdout+exit_code 且 exit==0（实际 exit=$RUN_EXIT）"
    echo "  依赖 $SELECTED_PLUGIN 已信任；若未信任先 buddy launcher run $SELECTED_PLUGIN --input 'x' 走 TOFU 批准"
fi

# image base64 可解码回 PNG（若 image 字段存在）
if jq -e 'has("image")' "$ARTIFACT_DIR/s11p2.out" >/dev/null 2>&1; then
    jq -r '.image' "$ARTIFACT_DIR/s11p2.out" | base64 -d > "$ARTIFACT_DIR/s11_image.png" 2>/dev/null
    if [ -s "$ARTIFACT_DIR/s11_image.png" ] && file "$ARTIFACT_DIR/s11_image.png" | grep -q "PNG image"; then
        pass "image base64 可解码回合法 PNG"
    else
        fail "image base64 解码后非合法 PNG"
    fi
fi

echo ""
echo "=== 场景 5: app 未运行时 CLI 降级（det-machine，需 app 未运行环境）==="
echo "# MANUAL: 先 pkill -f ClaudeCodeBuddy; sleep 2"
echo "# 然后跑以下两段，验 <10s 退出 + 非 0 + 错误指向连接"

# 场景 5.P1-P4（ MANUAL 驱动，因需 app 未运行）
cat <<'EOF'
# 场景 5 驱动脚本（app 未运行时执行）：
START=$(date +%s)
buddy tools --json > /tmp/autopilot-artifacts/s5p1.out 2>&1
EXIT=$?
ELAPSED=$(($(date +%s) - START))
echo "exit=$EXIT elapsed=${ELAPSED}s"
# assert: elapsed < 10 (5.P1) AND exit != 0 (5.P2)
# assert: stderr/stdout 含 socket/app/运行/connect/unreachable (5.P4)

START=$(date +%s)
buddy run qr --json > /tmp/autopilot-artifacts/s5p3.out 2>&1
EXIT=$?
ELAPSED=$(($(date +%s) - START))
echo "exit=$EXIT elapsed=${ELAPSED}s"
# assert: elapsed < 10 (5.P3) AND exit != 0
EOF

echo ""
echo "=== 场景 4: 未信任插件首次 run 触发 TOFU（det-machine，需真机交互）==="
echo "# MANUAL: rm ~/.buddy/launcher-trust.json; pkill -f ClaudeCodeBuddy; open apps/desktop/ClaudeCodeBuddy.app; sleep 3"
echo "# 跑 buddy run <new-plugin> --input '{\"query\":\"x\"}' --json"
echo "# app 弹 NSAlert → 用户点「拒绝」"
echo "# assert: CLI exit != 0 (4.P1) + stdout/stderr 含 trust/not trusted/未信任 (4.P2)"
echo "# assert: AND NOT contains timeout/超时 (补强 1)"
echo "# 换 input 重跑 buddy run <new-plugin> --input '{\"query\":\"other\"}' --json"
echo "# assert: 仍 exit != 0 (4.P4)"

echo ""
echo "=== 场景 3: 动态增删（端到端 socket 链路，单测 test_T09 已覆盖 in-process）==="
echo "# MANUAL 端到端验证："
echo "#   buddy launcher disable <some-enabled-plugin>"
echo "#   buddy tools --json | jq '.[].name'  # 验该插件消失"
echo "#   buddy launcher enable <some-disabled-plugin>"
echo "#   buddy tools --json | jq '.[].name'  # 验该插件出现"

echo ""
echo "================================"
echo "E2E fails: $E2E_FAILS"
[ "$E2E_FAILS" -eq 0 ] && echo "自动部分全绿（MANUAL 部分需 QA 真机驱动）" || echo "有失败"
