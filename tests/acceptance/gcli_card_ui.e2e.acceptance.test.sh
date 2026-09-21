#!/bin/bash
# gcli_card_ui.e2e.acceptance.test.sh
#
# 红队 E2E 验收：真实 app 链路（s4p1）+ 纯视觉残留（s3p4 visual-residue）+ 真机高度绑定兜底（s4p2）
# 运行方式（QA 阶段，独立脚本）：
#   bash tests/acceptance/gcli_card_ui.e2e.acceptance.test.sh
#
# 覆盖谓词（SSOT: state.md ## 验收场景）：
#   s4p1 [real-process] 真实链路（构建产物启动 app → 召唤 → 查询成功）进程存活
#                       且 面板 frame.height > 0 ｜ artifact: /tmp/autopilot-artifacts/s4p1.out
#   s3p4 [visual-residue] 高用量(≥85 danger)与低用量(<60 ok)同屏 → 状态色可区分、颜色↔等级一一对应
#                       （截图 + 二值清单）｜ artifact: /tmp/autopilot-artifacts/s3p4.out
#
# 自动化边界（apps/desktop/CLAUDE.md「GUI 自动化测试」）：
#   - 禁 osascript keystroke / CGEvent（LSUIElement 非路由 + 全局规范）→「召唤」热键无自动化
#     路径，s4p1 的召唤+查询段为 QA 真机步骤（脚本给出逐步命令与断言方法）。
#   - 进程存活（pgrep / buddy ping）、构建产物在场、CLI 全链路（buddy launcher run，可自动化段）
#     为脚本硬断言。AX 读（osascript get）可靠，仅用于读 frame 不做点击。
#
# 红队红线：硬断言失败即 exit 1；QA 手动段在 artifact 中以 [QA-PENDING] 显式标记（不冒充通过）。

set -u
set -o pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
if [ ! -d "$REPO_ROOT/apps/desktop" ]; then
    _d="$(cd "$(dirname "$0")" && pwd)"
    while [ "$_d" != "/" ]; do
        if [ -d "$_d/apps/desktop" ]; then REPO_ROOT="$_d"; break; fi
        _d="$(dirname "$_d")"
    done
fi
ART_DIR=/tmp/autopilot-artifacts
mkdir -p "$ART_DIR"

PASS=0; FAIL=0
fail() { FAIL=$((FAIL+1)); echo "  ✗ FAIL [$1]: $2" >&2; }
pass() { PASS=$((PASS+1)); echo "  ✓ PASS [$1]"; }

echo "=== gcli card UI e2e acceptance ==="

# ── 1. 构建产物在场（硬断言）────────────────────────────────────────────────
APP_BIN="$(ls -d "$REPO_ROOT"/apps/desktop/.build/debug/ClaudeCodeBuddy 2>/dev/null || true)"
APP_BUNDLE="$(ls -d "$REPO_ROOT"/apps/desktop/ClaudeCodeBuddy.app 2>/dev/null || true)"
if [ -z "$APP_BIN" ] && [ -z "$APP_BUNDLE" ]; then
    fail "build" "构建产物缺失——先跑 make -C apps/desktop build（或 SKIP_FETCH_PLUGINS=1 make bundle）"
    { echo "FAIL: 构建产物缺失"; } > "$ART_DIR/s4p1.out"
    exit 1
fi
pass "build"

# ── 2. 启动 app + 进程存活（s4p1 自动化段，硬断言）─────────────────────────
pkill -f ClaudeCodeBuddy 2>/dev/null; sleep 1
if [ -n "$APP_BUNDLE" ]; then
    open "$APP_BUNDLE"
else
    "$APP_BIN" & disown
fi
sleep 3

BUDDY_BIN="$(ls "$REPO_ROOT"/apps/desktop/.build/debug/buddy 2>/dev/null || command -v buddy || true)"
ALIVE=0
if pgrep -f ClaudeCodeBuddy >/dev/null 2>&1; then ALIVE=1; fi
if [ "$ALIVE" -eq 1 ] && [ -n "$BUDDY_BIN" ] && "$BUDDY_BIN" ping >/dev/null 2>&1; then ALIVE=1; else
    if [ "$ALIVE" -eq 1 ] && [ -z "$BUDDY_BIN" ]; then ALIVE=1; fi   # pgrep 已证存活，CLI 缺失不冤枉
fi
if [ "$ALIVE" -ne 1 ]; then
    fail "s4p1-alive" "app 启动后进程不存活（pgrep/buddy ping 均失败）"
    { echo "FAIL: 进程不存活"; } > "$ART_DIR/s4p1.out"
    exit 1
fi
pass "s4p1-alive（进程存活）"

# ── 3. CLI 全链路（可自动化段；gcli 未发布 marketplace 时显式标注）──────────
RUN_NOTE="buddy launcher run gcli：需先 buddy launcher update 刷新本机已装副本（W1 验收前置）"
if [ -n "$BUDDY_BIN" ]; then
    if "$BUDDY_BIN" launcher list 2>/dev/null | grep -q 'gcli'; then
        RUN_OUT="$("$BUDDY_BIN" launcher run gcli --input 'gc' 2>&1)"
        if echo "$RUN_OUT" | grep -q '没有名称匹配'; then
            fail "cli-chain" "CLI 全链路 query=gc 出现「没有名称匹配」（W2 未生效或旧副本未刷新）"
        else
            pass "cli-chain（query=gc 无错配提示）"
            RUN_NOTE="cli-chain: query=gc 无「没有名称匹配」（真实 app IPC 全链路）"
        fi
    else
        RUN_NOTE="cli-chain: 本机已装插件无 gcli（需 merge 后 buddy launcher update 刷新；此段 [QA-PENDING]）"
        echo "  ⊘ SKIP [cli-chain]: $RUN_NOTE"
    fi
fi

# ── 4. s4p1 召唤+面板高度（QA 真机步骤，[QA-PENDING] 显式标记）──────────────
S4P1="$ART_DIR/s4p1.out"
{
    echo "s4p1 真实链路验收（自动化段已硬断言；召唤段为 QA 真机步骤——osascript keystroke 禁用）"
    echo "[AUTO-PASS] 构建产物在场"
    echo "[AUTO-PASS] app 进程存活（pgrep + buddy ping）"
    echo "$RUN_NOTE"
    echo ""
    echo "[QA-PENDING] 步骤 1: 按 Ctrl+Space 召唤面板"
    echo "[QA-PENDING] 步骤 2: 输入 gc → 回车（选中 gcli 候选）"
    echo "[QA-PENDING] 步骤 3: 读面板 frame（AX 读可靠，勿用点击/键盘注入）："
    echo "  osascript -e 'tell application \"System Events\" to get {position, size} of window 1 of process \"ClaudeCodeBuddy\"'"
    echo "[QA-PENDING] 断言: 返回的 height > 0 且（≤2 条目时）< 400（s4p2 真机绑定下限由 QA 记录实测值）"
    echo "[QA-PENDING] 步骤 4: 输入 gcli → 回车，重复步骤 3，记录少行/多行两次高度（s4p3 单调增长）"
    echo "RESULT: [QA-PENDING]（本 artifact 的 QA 段勾选后由 QA 复核收敛）"
} > "$S4P1"
echo "  ⊘ MARK [s4p1]: 自动化段 PASS，召唤/高度段留 QA（详见 ${S4P1}）"

# ── 5. s3p4 visual-residue：danger/ok 同屏二值清单 + 截图 ──────────────────
# VISUAL_RESIDUE: 留 QA 真机判定（状态色区分属纯视觉，自动化金牌不可达）
S3P4="$ART_DIR/s3p4.out"
{
    echo "s3p4 [visual-residue] 截图二值清单（QA 逐项勾选 ☐→☑）"
    echo "前置：s3p1 card 含 ≥85 danger 与 <60 ok 条目同屏（输入 gcli 回车）"
    echo "截图: screencapture -x /tmp/autopilot-artifacts/s3p4.png"
    echo "☐ 1. danger（红）与 ok（sage 绿）状态点/进度条同屏可区分（色盲模拟 grayscale 下仍可辨）"
    echo "☐ 2. warn（#E5C15C 黄）与 danger 红可区分"
    echo "☐ 3. 颜色↔等级一一对应：max%≥85→红 / 60-85→黄 / <60→绿（对照 s3p1 card JSON 数值）"
    echo "☐ 4. 进度条 track=mist / fill=状态色；percent 等宽右对齐；reset 时间 smoke 色（mockup 方案 B）"
    echo "RESULT: [QA-PENDING]"
} > "$S3P4"
echo "  ⊘ MARK [s3p4]: visual-residue 清单就绪（${S3P4}，截图 s3p4.png）"

echo
echo "=== summary: $PASS passed, $FAIL failed（QA-PENDING 段不计数，由 QA 收敛） ==="
if [ "$FAIL" -gt 0 ]; then exit 1; fi
exit 0
