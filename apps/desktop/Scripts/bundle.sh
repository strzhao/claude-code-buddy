#!/usr/bin/env bash
# bundle.sh — Builds a release .app bundle for Claude Code Buddy.
# Usage: bash Scripts/bundle.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
APP_NAME="ClaudeCodeBuddy"
BUNDLE_DIR="$PROJECT_DIR/$APP_NAME.app"

echo "==> Building release binary..."
cd "$PROJECT_DIR"
swift build -c release

# Also build the CLI tool
echo "==> Building buddy CLI..."
swift build -c release --target buddy-cli

EXEC_PATH="$PROJECT_DIR/.build/release/$APP_NAME"

echo "==> Creating .app bundle at $BUNDLE_DIR ..."

# Clean previous bundle
rm -rf "$BUNDLE_DIR"

# Create bundle structure
mkdir -p "$BUNDLE_DIR/Contents/MacOS"
mkdir -p "$BUNDLE_DIR/Contents/Resources"

# Copy executable
cp "$EXEC_PATH" "$BUNDLE_DIR/Contents/MacOS/$APP_NAME"
chmod +x "$BUNDLE_DIR/Contents/MacOS/$APP_NAME"

# Copy Info.plist
cp "$PROJECT_DIR/Sources/ClaudeCodeBuddy/Resources/Info.plist" \
   "$BUNDLE_DIR/Contents/Info.plist"

# Copy app icon (bare cp — fail loudly if missing, matching release.yml)
cp "$PROJECT_DIR/Sources/ClaudeCodeBuddy/Resources/AppIcon.icns" \
   "$BUNDLE_DIR/Contents/Resources/AppIcon.icns"

# Compile Asset Catalog → Assets.car（app 级 AccentColor = sage）
# 让 NSSwitch 开态等所有 controlAccentColor 控件统一品牌绿（与 SettingsTheme.accent / BuddyPalette.sage 同值）
echo "==> Compiling Asset Catalog (AccentColor = sage)..."
mkdir -p "$PROJECT_DIR/.build/assetcatalog"
xcrun actool --compile "$PROJECT_DIR/.build/assetcatalog" \
  --platform macosx --minimum-deployment-target 11.0 \
  "$PROJECT_DIR/Sources/ClaudeCodeBuddy/Resources/Assets.xcassets" 2>&1 | grep -v "^$" || true
cp "$PROJECT_DIR/.build/assetcatalog/Assets.car" \
   "$BUNDLE_DIR/Contents/Resources/Assets.car"

# Copy SPM resource bundles (contains Assets/Sprites/ textures and KeyboardShortcuts localizations)
cp -R "$PROJECT_DIR/.build/release/ClaudeCodeBuddy_BuddyCore.bundle" \
      "$BUNDLE_DIR/Contents/Resources/"
cp -R "$PROJECT_DIR/.build/release/KeyboardShortcuts_KeyboardShortcuts.bundle" \
      "$BUNDLE_DIR/Contents/Resources/"

# Copy buddy CLI tool
CLI_EXEC_PATH="$PROJECT_DIR/.build/release/buddy-cli"
if [ -f "$CLI_EXEC_PATH" ]; then
    cp "$CLI_EXEC_PATH" "$BUNDLE_DIR/Contents/MacOS/buddy"
    chmod +x "$BUNDLE_DIR/Contents/MacOS/buddy"
    echo "==> CLI tool bundled: Contents/MacOS/buddy"
fi

# Ad-hoc sign so macOS preserves automation permissions across rebuilds
codesign --force --deep -s - "$BUNDLE_DIR"
echo "==> Ad-hoc signed"

echo "==> Bundle created: $BUNDLE_DIR"
echo ""
echo "To launch: open '$BUNDLE_DIR'"
echo "Or:        '$BUNDLE_DIR/Contents/MacOS/$APP_NAME'"
