#!/bin/bash
#
# QRScanner 打包脚本
#
# 用法：
#   ./build_ipa.sh adhoc        # Ad Hoc 分发（目标设备 UDID 需已注册，有效期 1 年）
#   ./build_ipa.sh development  # Development（装到自己/团队设备，免费账号 7 天）
#   ./build_ipa.sh unsigned     # 不签名，产出可交给 Sideloadly / AltStore 自签的 IPA
#
# 前置条件：已安装 Xcode（App Store），且 sudo xcode-select -s /Applications/Xcode.app
#
set -euo pipefail
cd "$(dirname "$0")"

MODE="${1:-adhoc}"
PROJECT="QRScanner.xcodeproj"
SCHEME="QRScanner"
ARCHIVE="build/QRScanner.xcarchive"
OUT="build/ipa-$MODE"

if ! xcodebuild -version >/dev/null 2>&1; then
  echo "❌ 未检测到 Xcode。"
  echo "   1) 从 App Store 安装 Xcode"
  echo "   2) sudo xcode-select -s /Applications/Xcode.app"
  exit 1
fi

echo "==> Xcode: $(xcodebuild -version | head -1)"
rm -rf "$ARCHIVE" "$OUT"
mkdir -p "$OUT"

if [ "$MODE" = "unsigned" ]; then
  echo "==> 构建未签名 .app"
  xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
    -sdk iphoneos -derivedDataPath build/dd \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
    build

  APP="build/dd/Build/Products/Release-iphoneos/$SCHEME.app"
  rm -rf build/Payload && mkdir -p build/Payload
  cp -R "$APP" build/Payload/
  (cd build && zip -qr "ipa-unsigned/$SCHEME-unsigned.ipa" Payload)
  rm -rf build/Payload
  echo "✅ 未签名 IPA: $OUT/$SCHEME-unsigned.ipa"
  echo "   下一步：用 Sideloadly / AltStore 以 Apple ID 自签后安装"
  exit 0
fi

if [ ! -f "ExportOptions-$MODE.plist" ]; then
  echo "❌ 找不到 ExportOptions-$MODE.plist"
  exit 1
fi

echo "==> Archive（Release，真机 SDK）"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
  -sdk iphoneos -archivePath "$ARCHIVE" archive

echo "==> 导出 IPA（$MODE）"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$OUT" \
  -exportOptionsPlist "ExportOptions-$MODE.plist"

echo "✅ 输出目录: $OUT"
ls -lh "$OUT"
