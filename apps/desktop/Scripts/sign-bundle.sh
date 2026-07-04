#!/usr/bin/env bash
# sign-bundle.sh — 用稳定 dev cert 签名 bundle；无 cert 退回 ad-hoc。
# 用法：sign-bundle.sh <bundle-dir>
#
# 稳定 cert（claude-code-buddy-dev）让 TCC 绑 cert 身份（designated requirement = cert CN），
# 跨重打包持久 → grant 一次即可（屏幕录制 / 辅助功能 等）。ad-hoc（--sign -）TCC 绑 cdhash，
# 每次重打包失效。cert 用 Scripts/setup-dev-signing.sh 创建（一次性，~2 分钟）。
set -euo pipefail

BUNDLE_DIR="$1"
CERT_NAME="claude-code-buddy-dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$CERT_NAME"; then
    echo "==> Signing with stable cert '$CERT_NAME' (TCC persists across rebuilds)"
    codesign --force --deep --sign "$CERT_NAME" "$BUNDLE_DIR"
    echo "==> Stable-cert signed"
else
    echo "==> Ad-hoc signing (no dev cert — TCC will reset each rebuild)"
    echo "    Tip: bash Scripts/setup-dev-signing.sh  creates a stable cert (grant TCC once, persists)."
    codesign --force --deep --sign - "$BUNDLE_DIR"
    echo "==> Ad-hoc signed"
fi
