#!/bin/bash
# 只需跑一次：创建固定的本地代码签名身份。
# 好处：屏幕录制 / 辅助功能 授权在重新构建后依然有效（不会每次都被当成新 App）。
set -euo pipefail

IDENTITY="PinBox Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    echo "✅ 已存在签名身份「$IDENTITY」，无需重复创建"
    exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $IDENTITY
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

echo "▶ 生成自签名证书…"
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf" 2>/dev/null
openssl pkcs12 -export -out "$TMP/id.p12" -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -name "$IDENTITY" -passout pass:pinbox \
    -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 2>/dev/null

echo "▶ 导入登录钥匙串（可能会弹一次密码框，选「始终允许」）…"
security import "$TMP/id.p12" -k "$KEYCHAIN" -P pinbox -T /usr/bin/codesign -T /usr/bin/security

echo "▶ 让 codesign 无需每次确认…"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" "$KEYCHAIN" >/dev/null 2>&1 || \
    echo "  （跳过 key-partition-list；签名时若弹窗请点「始终允许」）"

echo "✅ 完成。现在跑 ./build.sh 就会用它签名。"
security find-identity -v -p codesigning | grep "$IDENTITY" || true
