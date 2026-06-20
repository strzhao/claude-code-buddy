#!/usr/bin/env bash
# dev-bundle.sh — Creates a signed debug .app bundle for local testing with full TCC permissions.
# Usage: make run-bundle
#
# Why: `make run` launches the raw binary from .build/debug/, which has no .app bundle context.
# macOS launch services don't parse Info.plist for raw binaries, so TCC never prompts for
# Apple Events permission (NSAppleEventsUsageDescription in Info.plist is ignored).
# This script wraps the debug binary in a proper .app bundle so TCC works during development.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
APP_NAME="ClaudeCodeBuddy"
DEV_BUNDLE_DIR="$PROJECT_DIR/.build/${APP_NAME}-dev.app"
EXEC_PATH="$PROJECT_DIR/.build/debug/$APP_NAME"

echo "==> Creating dev bundle at $DEV_BUNDLE_DIR ..."

rm -rf "$DEV_BUNDLE_DIR"
mkdir -p "$DEV_BUNDLE_DIR/Contents/MacOS"
mkdir -p "$DEV_BUNDLE_DIR/Contents/Resources"

cp "$EXEC_PATH" "$DEV_BUNDLE_DIR/Contents/MacOS/$APP_NAME"
chmod +x "$DEV_BUNDLE_DIR/Contents/MacOS/$APP_NAME"

cp "$PROJECT_DIR/Sources/ClaudeCodeBuddy/Resources/Info.plist" \
   "$DEV_BUNDLE_DIR/Contents/Info.plist"

# Copy SPM resource bundles if they exist
RESOURCE_BUNDLE="$PROJECT_DIR/.build/debug/ClaudeCodeBuddy_BuddyCore.bundle"
if [ -d "$RESOURCE_BUNDLE" ]; then
    cp -R "$RESOURCE_BUNDLE" "$DEV_BUNDLE_DIR/Contents/Resources/"
fi

KEYBOARD_SHORTCUTS_BUNDLE="$PROJECT_DIR/.build/debug/KeyboardShortcuts_KeyboardShortcuts.bundle"
if [ -d "$KEYBOARD_SHORTCUTS_BUNDLE" ]; then
    cp -R "$KEYBOARD_SHORTCUTS_BUNDLE" "$DEV_BUNDLE_DIR/Contents/Resources/"
fi

# Copy app icon if it exists
ICON="$PROJECT_DIR/Sources/ClaudeCodeBuddy/Resources/AppIcon.icns"
if [ -f "$ICON" ]; then
    cp "$ICON" "$DEV_BUNDLE_DIR/Contents/Resources/AppIcon.icns"
fi

# Ad-hoc sign so macOS can associate TCC permissions with this bundle
codesign --force --deep --sign - "$DEV_BUNDLE_DIR"

echo "==> Dev bundle signed and ready"

# 杀掉所有已在运行的 ClaudeCodeBuddy 实例（含主仓库旧 build / 上一次 dev build）。
# 它们都是 .accessory(LSUIElement) app 且注册同一个全局热键 ⌘⇧Space；多实例并存会争抢
# 热键，表现为「按一次只切焦点不弹窗、按第二次才弹」。launch 前清场保证只有本次 build 持有热键。
# 仅匹配真正的 app 可执行路径，不会误伤本脚本或 make 进程。
# 匹配可执行后缀 Contents/MacOS/ClaudeCodeBuddy —— 同时覆盖主仓库 ClaudeCodeBuddy.app
# 与本脚本产出的 ClaudeCodeBuddy-dev.app 两种 bundle；不会误伤 make / bash / 本脚本自身。
echo "==> Terminating any running ClaudeCodeBuddy instances ..."
pkill -f "Contents/MacOS/ClaudeCodeBuddy" 2>/dev/null || true
# 等 LaunchServices 注销旧实例，避免 open 误判「已在运行」而只聚焦不重启
sleep 0.5

echo "==> Launching: open '$DEV_BUNDLE_DIR'"
open "$DEV_BUNDLE_DIR"
