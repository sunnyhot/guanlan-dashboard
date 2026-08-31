#!/usr/bin/env bash
set -euo pipefail

# 生成自签名代码签名证书 + 本地专用钥匙串，给 App 一个稳定的签名身份。
#
# 为什么需要它：ad-hoc 签名（codesign -s -）每次构建的代码身份都不同，
# macOS 钥匙串 ACL 只认「当初创建该项的 App 签名」，于是 App 每次自动更新
# 后读取 Keychain 里的 API Key/同步密码都会弹授权窗。用固定的自签名证书后，
# 所有构建满足同一 designated requirement，旧数据迁移最多弹一次，之后永不弹。
#
# 产物（全部在 build/signing/，.gitignore 已排除 build/，勿提交）：
#   qieman-codesign.key/.crt      私钥与证书（自签，10 年）
#   qieman-codesign.p12           PKCS#12 导出（CI secret 用）
#   qieman-codesign.p12.b64       base64 文本（gh secret set 直接读取）
#   qieman-signing.keychain-db    专用钥匙串（本地构建脚本自动挂载签名）
#   env                           钥匙串/P12 密码（build_macos_app.sh 读取）
#
# 一次性运行即可；已存在时跳过。CI 侧把 p12 与密码存为 GitHub Secrets：
#   MACOS_CODESIGN_P12_BASE64 / MACOS_CODESIGN_PASSWORD
# （脚本结尾会打印具体命令。）

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIGNING_DIR="$ROOT_DIR/build/signing"
KEY_FILE="$SIGNING_DIR/qieman-codesign.key"
CRT_FILE="$SIGNING_DIR/qieman-codesign.crt"
P12_FILE="$SIGNING_DIR/qieman-codesign.p12"
P12_B64_FILE="$SIGNING_DIR/qieman-codesign.p12.b64"
KEYCHAIN_FILE="$SIGNING_DIR/qieman-signing.keychain-db"
ENV_FILE="$SIGNING_DIR/env"
IDENTITY_NAME="Qieman Dashboard Self-Signing"

mkdir -p "$SIGNING_DIR"
chmod 700 "$SIGNING_DIR"

if [ -f "$ENV_FILE" ] && [ -f "$KEYCHAIN_FILE" ] \
  && security dump-trust-settings 2>/dev/null | grep -q "$IDENTITY_NAME"; then
  echo "签名身份已存在，跳过生成: $IDENTITY_NAME"
  exit 0
fi

echo "[1/4] 生成自签名代码签名证书（10 年）"
KEYCHAIN_PASS="$(openssl rand -hex 24)"
P12_PASS="$(openssl rand -hex 24)"
umask 077
CNF_FILE="$SIGNING_DIR/req.cnf"
cat > "$CNF_FILE" <<'CNF'
[req]
distinguished_name = subject
x509_extensions = v3_sign
prompt = no
[subject]
CN = Qieman Dashboard Self-Signing
O = Qieman Dashboard
[v3_sign]
basicConstraints = critical, CA:TRUE
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
CNF
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$KEY_FILE" -out "$CRT_FILE" -days 3650 \
  -config "$CNF_FILE"
rm -f "$CNF_FILE"

echo "[2/4] 导出 P12"
# macOS security import 不接受 OpenSSL 3 默认的 AES-256-CBC/SHA-256 MAC，
# 显式回退传统算法（SHA-1 MAC + 3DES），OpenSSL 3 与 LibreSSL 均支持。
openssl pkcs12 -export \
  -inkey "$KEY_FILE" -in "$CRT_FILE" -out "$P12_FILE" \
  -passout pass:"$P12_PASS" -name "$IDENTITY_NAME" \
  -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1

echo "[3/4] 写入密码文件（仅本地，build/ 已 gitignore）"
cat > "$ENV_FILE" <<EOF
QIEMAN_SIGNING_KEYCHAIN_PASS=$KEYCHAIN_PASS
QIEMAN_SIGNING_P12_PASS=$P12_PASS
EOF
chmod 600 "$ENV_FILE"

echo "[4/5] 创建本地专用钥匙串并导入身份"
rm -f "$KEYCHAIN_FILE"
security create-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN_FILE"
security unlock-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN_FILE"
security set-keychain-settings "$KEYCHAIN_FILE"
security import "$P12_FILE" -k "$KEYCHAIN_FILE" -P "$P12_PASS" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASS" "$KEYCHAIN_FILE" >/dev/null

echo "[5/5] 写入 per-user 信任设置（Code Signing 策略 trustRoot）"
# 自签名证书默认不受信，codesign 会报 no identity found；
# per-user 域设置无需 sudo（个别系统会弹一次登录密码确认）。
security add-trusted-cert -r trustRoot -p codeSign "$CRT_FILE"

# 临时把专用钥匙串挂进搜索列表做最终校验（find-identity 只认搜索列表内的钥匙串）。
BACKUP_KCS=()
while IFS= read -r kc; do
  # list-keychains 输出每行带前导空格，不 trim 会把损坏路径写回列表
  kc="${kc//\"/}"
  kc="${kc#"${kc%%[![:space:]]*}"}"
  [ -n "$kc" ] && BACKUP_KCS+=("$kc")
done < <(security list-keychains -d user)
security list-keychains -d user -s "${BACKUP_KCS[@]}" "$KEYCHAIN_FILE"
security find-identity -v -p codesigning 2>/dev/null | grep "$IDENTITY_NAME" || {
  security list-keychains -d user -s "${BACKUP_KCS[@]}"
  echo "❌ 校验失败：身份在搜索列表中不可见，请检查上面的输出"
  exit 1
}
security list-keychains -d user -s "${BACKUP_KCS[@]}"

base64 -i "$P12_FILE" -o "$P12_B64_FILE"
chmod 600 "$P12_B64_FILE" "$P12_FILE" "$KEY_FILE"

echo
echo "✅ 完成。本地构建（scripts/build_macos_app.sh）会自动使用该身份签名。"
echo
echo "CI 侧配置（GitHub Secrets，只需执行一次）："
echo "  gh secret set MACOS_CODESIGN_P12_BASE64 < $P12_B64_FILE"
echo "  gh secret set MACOS_CODESIGN_PASSWORD < <(grep QIEMAN_SIGNING_P12_PASS $ENV_FILE | cut -d= -f2)"
echo
echo "注意：证书有效期 10 年，到期后需重新生成并同步 CI secret；"
echo "旧 App 更新到新签名版本后，已存的 Keychain 项首次读取可能弹一次授权窗，"
echo "点「始终允许」即可（或在设置里重存一次密钥）。"
