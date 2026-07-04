#!/usr/bin/env bash
# setup-dev-signing.sh — 一次性创建本地自签 code-signing cert 并信任，让 dev/release bundle 用稳定身份签名。
#
# 解决：ad-hoc 签名（codesign --sign -）TCC 绑 cdhash，每次 `make bundle` 重打包 cdhash 变 → TCC 失效，
# 要重新授权（屏幕录制/辅助功能等）。改用稳定 cert → TCC 绑 cert 身份（DR = CN），跨重打包持久。
#
# **必须在你自己的终端运行**（trust 步骤会弹 GUI 授权框要登录密码，非交互环境会卡）：
#   bash apps/desktop/Scripts/setup-dev-signing.sh
#
# 幂等：cert 已存在则跳过生成，仅确保 trust。删除：
#   security delete-certificate -c "claude-code-buddy-dev" ~/Library/Keychains/login.keychain-db
set -euo pipefail

CERT_NAME="claude-code-buddy-dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
# PKCS12 传输密码（一次性，导入后 key 落进 keychain 由 keychain 密码保护；非安全关键，本地 dev 用）
PW="ccb-dev-cert"
CERT_PEM="/tmp/${CERT_NAME}.pem"

# Step 1: 确保 cert 在 keychain（无则生成 + 导入）
if security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$CERT_NAME"; then
    echo "✅ cert '$CERT_NAME' 已存在，跳过生成"
else
    echo "==> 生成自签 cert '$CERT_NAME'（keyUsage=digitalSignature + EKU=codeSigning，10 年）..."
    TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
    # config-file 方式：必须显式 keyUsage=critical,digitalSignature + extendedKeyUsage=codeSigning。
    # 只加 EKU 不加 keyUsage 会被 macOS 报 "Invalid Key Usage for policy"，codesign 拒签。
    CNF="$TMP/cert.cnf"
    cat > "$CNF" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = $CERT_NAME
O = ccb
[v3]
keyUsage = critical, digitalSignature
extendedKeyUsage = codeSigning
basicConstraints = critical, CA:FALSE
EOF
    openssl req -x509 -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
        -days 3650 -nodes -config "$CNF" 2>/dev/null
    # -legacy + 非空密码：openssl 3.x 默认 PKCS12 格式 macOS security 读不了（"MAC verification failed"）
    openssl pkcs12 -export -legacy -in "$TMP/cert.pem" -inkey "$TMP/key.pem" \
        -out "$TMP/cert.p12" -name "$CERT_NAME" -passout "pass:$PW" 2>/dev/null
    echo "==> 导入 login keychain..."
    security import "$TMP/cert.p12" -k "$KEYCHAIN" -T /usr/bin/codesign -P "$PW" >/dev/null
    # 允许 codesign 无密码提示访问私钥（失败不致命，最坏每次 codesign 弹一次 keychain 密码）
    security set-partition-list -S apple-tool:,apple:,codesign: -s -k "" "$KEYCHAIN" 2>/dev/null || true
    cp "$TMP/cert.pem" "$CERT_PEM"
    echo "✅ 生成 + 导入完成"
fi

# 导出 cert PEM（trust 步骤需要文件）
security find-certificate -c "$CERT_NAME" -p "$KEYCHAIN" > "$CERT_PEM" 2>/dev/null

# Step 2: 信任 cert（**会弹 GUI 授权框**，需登录密码 —— 必须在交互终端跑）
echo ""
echo "==> 信任 cert（系统会弹授权框，输登录密码授权）..."
if security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$CERT_PEM" 2>/dev/null; then
    echo "✅ trust 成功"
else
    echo "⚠️ trust 未完成（可能授权框被取消）。重新跑此脚本，或手动："
    echo "   sudo security add-trusted-cert -d -r trustRoot -p codeSign -k /Library/Keychains/System.keychain $CERT_PEM"
    exit 1
fi

echo ""
echo "=== 验证（应为 1 valid identity）==="
security find-identity -v -p codesigning "$KEYCHAIN" | grep "$CERT_NAME" \
    && echo "" && echo "✅ 完成。dev-bundle.sh / bundle.sh 现在会用此 cert 签名（TCC 跨重打包持久）。" \
    || { echo "⚠️ 未出现在 valid 列表，检查 trust 步骤"; exit 1; }
