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

# Copy SPM resource bundle if it exists
RESOURCE_BUNDLE="$PROJECT_DIR/.build/debug/ClaudeCodeBuddy_BuddyCore.bundle"
if [ -d "$RESOURCE_BUNDLE" ]; then
    cp -R "$RESOURCE_BUNDLE" "$DEV_BUNDLE_DIR/Contents/Resources/"
fi

# Copy app icon if it exists
ICON="$PROJECT_DIR/Sources/ClaudeCodeBuddy/Resources/AppIcon.icns"
if [ -f "$ICON" ]; then
    cp "$ICON" "$DEV_BUNDLE_DIR/Contents/Resources/AppIcon.icns"
fi

# Ad-hoc sign so macOS can associate TCC permissions with this bundle
codesign --force --deep --sign - "$DEV_BUNDLE_DIR"

echo "==> Dev bundle signed and ready"
echo "==> Launching: open '$DEV_BUNDLE_DIR'"
open "$DEV_BUNDLE_DIR"
