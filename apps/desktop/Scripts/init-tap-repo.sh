#!/bin/bash
set -euo pipefail

# Initialize the Homebrew tap repository for claude-code-buddy.
# Prerequisites: gh CLI authenticated with repo permissions.

REPO_OWNER="strzhao"
TAP_REPO="homebrew-claude-code-buddy"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CASK_SRC="$PROJECT_DIR/homebrew/Casks/claude-code-buddy.rb"
WORK_DIR=$(mktemp -d)

trap 'rm -rf "$WORK_DIR"' EXIT

echo "==> Checking gh CLI..."
if ! command -v gh &>/dev/null; then
  echo "Error: gh CLI not found. Install via: brew install gh"
  exit 1
fi

echo "==> Creating GitHub repo $REPO_OWNER/$TAP_REPO..."
if gh repo view "$REPO_OWNER/$TAP_REPO" &>/dev/null; then
  echo "    Repo already exists, skipping creation."
else
  gh repo create "$REPO_OWNER/$TAP_REPO" --public \
    --description "Homebrew tap for Claude Code Buddy"
fi

echo "==> Cloning tap repo..."
gh repo clone "$REPO_OWNER/$TAP_REPO" "$WORK_DIR/tap"
cd "$WORK_DIR/tap"

echo "==> Copying Cask formula..."
mkdir -p Casks
cp "$CASK_SRC" Casks/claude-code-buddy.rb

echo "==> Committing and pushing..."
git add Casks/claude-code-buddy.rb
git commit -m "Add claude-code-buddy cask formula"
git push origin main

echo ""
echo "Done! Users can now install with:"
echo "  brew tap $REPO_OWNER/claude-code-buddy"
echo "  brew install claude-code-buddy"
