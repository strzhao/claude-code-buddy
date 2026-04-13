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

# Copy SPM resource bundle (contains Assets/Sprites/ textures)
cp -R "$PROJECT_DIR/.build/release/ClaudeCodeBuddy_BuddyCore.bundle" \
      "$BUNDLE_DIR/Contents/Resources/"

echo "==> Bundle created: $BUNDLE_DIR"
echo ""
echo "To launch: open '$BUNDLE_DIR'"
echo "Or:        '$BUNDLE_DIR/Contents/MacOS/$APP_NAME'"
