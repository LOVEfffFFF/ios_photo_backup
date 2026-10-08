#!/bin/bash
# 编译 iOS App 并产出 build/ios/iphoneos/Runner.app
#
# ## 为什么不直接用 `flutter build ios --no-codesign`
#
# Xcode 26 起，即使带了 --no-codesign，flutter 仍会在编译之后校验
# DEVELOPMENT TEAM，没设置就抛「Building a deployable iOS app requires a
# selected Development Team」并以退出码 1 结束，而且**不会产出 .app**。
# CI 上没有 Apple 开发者账号，无法提供 Team。
#
# 因此拆成两步：
#   1. flutter build ios --config-only  只生成配置（Generated.xcconfig 等），
#      不触发 Team 校验
#   2. xcodebuild 直接编译，显式传 CODE_SIGNING_ALLOWED=NO 等参数。
#      编译 Dart 的 Flutter build phase 由 xcodebuild 自动触发。
#
# 用法：bash .github/scripts/build_ios.sh Debug|Release

set -euo pipefail

CONFIG="${1:-Release}"
case "$CONFIG" in
  Debug|debug)     CONFIG=Debug ;;
  Release|release) CONFIG=Release ;;
  *) echo "::error::未知构建配置: ${CONFIG}（只支持 Debug / Release）"; exit 1 ;;
esac

echo "=== 步骤 1/3：生成 Flutter 配置（${CONFIG}）==="
# --config-only 只生成 iOS 工程配置，不编译、不校验 Team
flutter build ios --config-only --no-codesign

echo "=== 步骤 2/3：xcodebuild 编译（显式关闭签名）==="
# 删掉 Podfile 后项目走 Swift Package Manager，可能只有 .xcodeproj；
# 若 flutter 生成了 .xcworkspace 则优先使用它。
if [ -d "ios/Runner.xcworkspace" ]; then
  PROJECT_ARGS=(-workspace ios/Runner.xcworkspace)
  echo "使用 workspace: ios/Runner.xcworkspace"
else
  PROJECT_ARGS=(-project ios/Runner.xcodeproj)
  echo "使用 project: ios/Runner.xcodeproj"
fi

xcodebuild \
  "${PROJECT_ARGS[@]}" \
  -scheme Runner \
  -configuration "$CONFIG" \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build/ios_dd \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  DEVELOPMENT_TEAM="" \
  build

echo "=== 步骤 3/3：收集产物 ===="
APP_PATH="$(find build/ios_dd/Build/Products -maxdepth 2 -name 'Runner.app' -type d 2>/dev/null | head -n 1)"
if [ -z "$APP_PATH" ]; then
  APP_PATH="$(find build -maxdepth 4 -name 'Runner.app' -type d 2>/dev/null | head -n 1)"
fi

if [ -z "$APP_PATH" ]; then
  echo "::error::编译失败：未找到 Runner.app"
  exit 1
fi

mkdir -p build/ios/iphoneos
rm -rf build/ios/iphoneos/Runner.app
cp -r "$APP_PATH" build/ios/iphoneos/Runner.app

# 关键校验：主二进制与 App.framework 必须存在，否则打出来的 IPA 装不上
if [ ! -f "build/ios/iphoneos/Runner.app/Runner" ]; then
  echo "::error::产物不完整：缺少 Runner 可执行文件"
  exit 1
fi
if [ ! -d "build/ios/iphoneos/Runner.app/Frameworks/App.framework" ]; then
  echo "::error::产物不完整：缺少 App.framework（Dart 代码未编译进去）"
  exit 1
fi

echo "产物就绪: build/ios/iphoneos/Runner.app"
ls -la build/ios/iphoneos/Runner.app/Runner
du -sh build/ios/iphoneos/Runner.app