#!/usr/bin/env bash
# verifier-settings/driver.sh — 驱动 Claude Code Buddy 设置窗口，捕获帧 + 截图证据。
#
# 这是 verifier-settings skill 的 harness（agent 主路径）。LSUIElement accessory app 下
# osascript click/AXPress/keystroke 对设置窗口不路由（patterns/2026-06-23），唯一可靠的
# 自动化打开/切换路径是经 socket 让 app 进程直驱 in-process API（buddy launcher debug）。
#
# 用法：
#   driver.sh build            仅构建（SKIP_FETCH_PLUGINS=1 make bundle）
#   driver.sh launch           关旧 app + 启新 app（等待 socket 就绪）
#   driver.sh drive <panel>    驱动到指定面板并截图 + dump get-state
#       panel ∈ general | about | hotkey | skins | plugins | snip
#   driver.sh sweep            遍历全部面板，各截一张图
#   driver.sh state            dump 当前设置窗口几何 + 选中态（JSON）
#   driver.sh cleanup          pkill app
#   driver.sh all              build → launch → sweep → cleanup（一键全流程）
#
# 证据产物落在 $EVIDENCE_DIR（默认 /tmp/verifier-settings-evidence）。
# 依赖：本仓库已 bundle 出 apps/desktop/ClaudeCodeBuddy.app（内含新 buddy CLI）。

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
APP="$REPO_ROOT/apps/desktop/ClaudeCodeBuddy.app"
BUDDY="$APP/Contents/MacOS/buddy"
EVIDENCE_DIR="${VERIFIER_EVIDENCE_DIR:-/tmp/verifier-settings-evidence}"
mkdir -p "$EVIDENCE_DIR"

# 面板 → 驱动命令
drive_panel() {
    local panel="$1"
    case "$panel" in
        general|about|hotkey|skins|plugins)
            "$BUDDY" launcher debug select-section "$panel" >/dev/null 2>&1 || true
            ;;
        snip)
            "$BUDDY" launcher debug select-section plugins >/dev/null 2>&1 || true
            sleep 0.4
            "$BUDDY" launcher debug select-plugin snip >/dev/null 2>&1 || true
            ;;
        *)
            echo "unknown panel: $panel (general|about|hotkey|skins|plugins|snip)" >&2
            return 2
            ;;
    esac
    sleep 0.6   # 等 detail child VC 过渡 + layout 稳定
}

# 等 socket 就绪（app 启动后 buddy health 成功）
wait_ready() {
    for _ in $(seq 1 20); do
        if timeout 2 "$BUDDY" health >/dev/null 2>&1; then return 0; fi
        sleep 0.5
    done
    echo "ERROR: app did not become ready (buddy health failed)" >&2
    return 1
}

cmd_build() {
    SKIP_FETCH_PLUGINS=1 make -C "$REPO_ROOT/apps/desktop" bundle
}

cmd_launch() {
    pkill -f ClaudeCodeBuddy 2>/dev/null || true
    sleep 1
    open "$APP"
    wait_ready
    echo "app ready: $("$BUDDY" health)"
}

cmd_drive() {
    local panel="$1"
    wait_ready
    # 首次打开设置窗口（若未开）
    if ! "$BUDDY" launcher debug get-state 2>/dev/null | grep -q '"window_open" : true\|"window_open":true'; then
        "$BUDDY" launcher debug open-settings >/dev/null 2>&1
        sleep 1
    fi
    drive_panel "$panel"
    local shot="$EVIDENCE_DIR/$(date +%H%M%S)-$panel.png"
    screencapture -x "$shot"
    echo "captured: $shot"
    "$BUDDY" launcher debug get-state
}

cmd_sweep() {
    wait_ready
    "$BUDDY" launcher debug open-settings general >/dev/null 2>&1
    sleep 1
    for panel in general about hotkey plugins snip; do
        drive_panel "$panel"
        screencapture -x "$EVIDENCE_DIR/$(date +%H%M%S)-$panel.png"
        echo "captured: $panel"
    done
    echo "=== final state ==="
    "$BUDDY" launcher debug get-state
}

cmd_state() { wait_ready; "$BUDDY" launcher debug get-state; }
cmd_cleanup() { pkill -f ClaudeCodeBuddy 2>/dev/null || true; echo "cleaned up"; }

cmd_all() {
    cmd_build
    cmd_launch
    cmd_sweep
    cmd_cleanup
}

case "${1:-}" in
    build)   cmd_build ;;
    launch)  cmd_launch ;;
    drive)   shift; cmd_drive "${1:?panel required}" ;;
    sweep)   cmd_sweep ;;
    state)   cmd_state ;;
    cleanup) cmd_cleanup ;;
    all)     cmd_all ;;
    *) echo "usage: driver.sh <build|launch|drive <panel>|sweep|state|cleanup|all>" >&2; exit 2 ;;
esac
