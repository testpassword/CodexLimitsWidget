#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/Codex Limits.app"
APP_CONTENTS="$APP/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_PLUGINS="$APP_CONTENTS/PlugIns"
EXT="$APP_PLUGINS/CodexLimitsWidgetExtension.appex"
EXT_CONTENTS="$EXT/Contents"
EXT_MACOS="$EXT_CONTENTS/MacOS"
EXT_RESOURCES="$EXT_CONTENTS/Resources"
rm -rf "$APP"
mkdir -p "$APP_MACOS" "$APP_RESOURCES" "$APP_PLUGINS" "$EXT_MACOS" "$EXT_RESOURCES"
cp "$ROOT/Resources/AppInfo.plist" "$APP_CONTENTS/Info.plist"
cp "$ROOT/Resources/WidgetInfo.plist" "$EXT_CONTENTS/Info.plist"
cp "$ROOT/Resources/CodexLimits.icns" "$APP_RESOURCES/CodexLimits.icns"
cp "$ROOT/Resources/CodexLimits.icns" "$EXT_RESOURCES/CodexLimits.icns"
printf "APPL????" > "$APP_CONTENTS/PkgInfo"
swiftc \
  -target arm64-apple-macosx14.0 \
  -parse-as-library \
  -O \
  -framework SwiftUI \
  -framework WidgetKit \
  "$ROOT/Sources/CodexLimitsHost.swift" \
  -o "$APP_MACOS/CodexLimits"
swiftc \
  -target arm64-apple-macosx14.0 \
  -application-extension \
  -parse-as-library \
  -O \
  -framework SwiftUI \
  -framework WidgetKit \
  -Xlinker -e \
  -Xlinker _NSExtensionMain \
  "$ROOT/Sources/CodexLimitsWidget.swift" \
  -o "$EXT_MACOS/CodexLimitsWidgetExtension"
codesign --force --sign - --entitlements "$ROOT/Resources/Widget.entitlements" "$EXT"
codesign --force --sign - --entitlements "$ROOT/Resources/App.entitlements" "$APP"
echo "$APP"
