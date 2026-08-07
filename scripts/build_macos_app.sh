#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="${APP_NAME:-QiemanDashboard}"
APP_DISPLAY_NAME="${APP_DISPLAY_NAME:-且慢主理人}"
APP_VERSION="${APP_VERSION:-3.3.1}"
APP_BUILD="${APP_BUILD:-$(date +%Y%m%d%H%M)}"
BUNDLE_ID="${BUNDLE_ID:-com.sunnyhot.qieman.manager.dashboard}"
MIN_MACOS_VERSION="${MIN_MACOS_VERSION:-14.0}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
TARGET_ARCH="${TARGET_ARCH:-$(uname -m)}"
UPDATE_REPOSITORY="${UPDATE_REPOSITORY:-sunnyhot/qieman-manager-dashboard}"
UPDATE_FEED_URL="${UPDATE_FEED_URL:-https://github.com/${UPDATE_REPOSITORY}/releases/latest/download/latest.json}"
DIST_DIR="$ROOT_DIR/dist/macos-app"
APP_DIR="$DIST_DIR/${APP_NAME}.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
PAYLOAD_DIR="$RESOURCES_DIR/project"
ICONSET_DIR="$DIST_DIR/${APP_NAME}.iconset"
ICON_FILE="$RESOURCES_DIR/${APP_NAME}.icns"
ICON_MASTER="$ROOT_DIR/macos-app/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-iOS-1024.png"
ZIP_FILE="/tmp/${APP_NAME}-${APP_VERSION}.zip"
SWIFT_SOURCES=()

while IFS= read -r file; do
  SWIFT_SOURCES+=("$file")
done < <(find "$ROOT_DIR/macos-app" -name '*.swift' ! -name 'Package.swift' ! -path "$ROOT_DIR/macos-app/Tests/*" ! -path "$ROOT_DIR/macos-app/CLI/*" ! -path "$ROOT_DIR/macos-app/Views_iOS/*" ! -path "$ROOT_DIR/macos-app/.build/*" | sort)

echo "[1/8] 清理旧产物"
rm -rf "$APP_DIR"
rm -rf "$ICONSET_DIR"
rm -f "$ZIP_FILE"
mkdir -p "$MACOS_DIR" "$PAYLOAD_DIR" "$PAYLOAD_DIR/output" "$RESOURCES_DIR"

echo "[2/8] 生成 App 图标"
swift "$ROOT_DIR/scripts/render_macos_icon.swift" "$ICON_MASTER" "$ICONSET_DIR"
iconutil -c icns "$ICONSET_DIR" -o "$ICON_FILE"

echo "[3/8] 编译原生 macOS 应用"
# BUILD_CONFIG=debug 时跳过 -O 优化，大幅加速编译（开发调试用）
BUILD_CONFIG="${BUILD_CONFIG:-release}"
if [ "$BUILD_CONFIG" = "debug" ]; then
  SWIFTC_OPT_FLAGS=""
  echo "  (debug 构建，跳过 -O 优化以加速编译)"
else
  SWIFTC_OPT_FLAGS="-O -whole-module-optimization"
fi
swiftc \
  "${SWIFT_SOURCES[@]}" \
  $SWIFTC_OPT_FLAGS \
  -target "${TARGET_ARCH}-apple-macos${MIN_MACOS_VERSION}" \
  -framework SwiftUI \
  -framework Charts \
  -framework WebKit \
  -framework AppKit \
  -o "$MACOS_DIR/$APP_NAME"

QIEMAN_CLI_OUTPUT="$MACOS_DIR/qieman-cli" \
  TARGET_ARCH="$TARGET_ARCH" \
  MIN_MACOS_VERSION="$MIN_MACOS_VERSION" \
  bash "$ROOT_DIR/scripts/build_qieman_cli.sh" >/dev/null

echo "[4/8] 写入 Bundle 元数据"
cat > "$CONTENTS_DIR/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>__APP_NAME__</string>
  <key>CFBundleDisplayName</key>
  <string>__APP_DISPLAY_NAME__</string>
  <key>CFBundleIconFile</key>
  <string>__APP_NAME__</string>
  <key>CFBundleIdentifier</key>
  <string>__BUNDLE_ID__</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>__APP_DISPLAY_NAME__</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>__APP_VERSION__</string>
  <key>CFBundleVersion</key>
  <string>__APP_BUILD__</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.finance</string>
  <key>LSMinimumSystemVersion</key>
  <string>__MIN_MACOS_VERSION__</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>NSHumanReadableCopyright</key>
  <string>Copyright © 2026 sunnyhot. All rights reserved.</string>
  <key>QiemanUpdateRepository</key>
  <string>__UPDATE_REPOSITORY__</string>
  <key>QiemanUpdateFeedURL</key>
  <string>__UPDATE_FEED_URL__</string>
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsArbitraryLoads</key>
    <true/>
  </dict>
</dict>
</plist>
PLIST
perl -0pi -e 's#__APP_NAME__#'"$APP_NAME"'#g; s#__APP_DISPLAY_NAME__#'"$APP_DISPLAY_NAME"'#g; s#__APP_VERSION__#'"$APP_VERSION"'#g; s#__APP_BUILD__#'"$APP_BUILD"'#g; s#__BUNDLE_ID__#'"$BUNDLE_ID"'#g; s#__MIN_MACOS_VERSION__#'"$MIN_MACOS_VERSION"'#g; s#__UPDATE_REPOSITORY__#'"$UPDATE_REPOSITORY"'#g; s#__UPDATE_FEED_URL__#'"$UPDATE_FEED_URL"'#g' "$CONTENTS_DIR/Info.plist"
printf 'APPL????' > "$CONTENTS_DIR/PkgInfo"

echo "[5/8] 拷贝说明文档"
cp "$ROOT_DIR/README.md" "$PAYLOAD_DIR/"

cat > "$PAYLOAD_DIR/APP_BUNDLE_README.txt" <<'TXT'
Runtime data location:
~/Library/Application Support/QiemanDashboard

Put your Qieman login cookie here if needed:
~/Library/Application Support/QiemanDashboard/qieman.cookie
TXT

echo "[6/8] 进行 Bundle 签名"
xattr -cr "$APP_DIR" 2>/dev/null || true
codesign --force --deep --sign "$SIGN_IDENTITY" --timestamp=none "$APP_DIR"

echo "[7/8] 验证签名与可执行性"
codesign --verify --deep --strict "$APP_DIR"
if spctl_output="$(spctl --assess --type execute "$APP_DIR" 2>&1)"; then
  echo "Gatekeeper 校验通过"
else
  echo "Gatekeeper 结果: ${spctl_output}"
  echo "提示: 当前产物是本地 ad-hoc 签名，适合自用与测试；若要对外分发并消除系统警告，还需要 Apple Developer 证书与 notarization。"
fi

echo "[8/8] 生成分发压缩包"
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ZIP_FILE"

echo "[9/9] 验证构建产物"
# --- 产物完整性检查（防止空包/损坏包发布到用户端）---

# 1. App bundle 必须存在
if [ ! -d "$APP_DIR" ]; then
  echo "❌ 验证失败: App bundle 不存在 ($APP_DIR)"
  exit 1
fi

# 2. 可执行文件必须存在且有执行权限
EXECUTABLE="$MACOS_DIR/$APP_NAME"
if [ ! -x "$EXECUTABLE" ]; then
  echo "❌ 验证失败: 可执行文件不存在或无执行权限 ($EXECUTABLE)"
  exit 1
fi

# 3. Zip 文件必须存在且 >= 1MB（防止空包）
if [ ! -f "$ZIP_FILE" ]; then
  echo "❌ 验证失败: Zip 文件不存在 ($ZIP_FILE)"
  exit 1
fi
ZIP_SIZE=$(stat -f%z "$ZIP_FILE" 2>/dev/null || stat -c%s "$ZIP_FILE" 2>/dev/null)
MIN_ZIP_SIZE=$((1 * 1024 * 1024))  # 1MB
if [ "$ZIP_SIZE" -lt "$MIN_ZIP_SIZE" ]; then
  echo "❌ 验证失败: Zip 文件过小 ($ZIP_SIZE bytes < $MIN_ZIP_SIZE bytes)，构建可能失败"
  exit 1
fi

# 4. Zip 必须能通过完整性校验
if ! unzip -t "$ZIP_FILE" > /dev/null 2>&1; then
  echo "❌ 验证失败: Zip 完整性校验失败 (unzip -t)"
  exit 1
fi

# 5. Zip 内必须包含 App bundle
if ! zipinfo -1 "$ZIP_FILE" | awk -v app="${APP_NAME}.app/" '$0 == app || index($0, app) == 1 { found = 1 } END { exit found ? 0 : 1 }'; then
  echo "❌ 验证失败: Zip 内未找到 ${APP_NAME}.app"
  exit 1
fi

echo "✅ 构建产物验证通过 (zip: $ZIP_SIZE bytes)"
echo "完成"
echo "App 已生成: $APP_DIR"
echo "压缩包: $ZIP_FILE"
echo "运行方式: open \"$APP_DIR\""
