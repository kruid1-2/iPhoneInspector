#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
PRODUCT_NAME="iPhoneInspector"
PROCESS_NAME="iPhoneInspector"
LEGACY_PROCESS_NAME="iPhoneMonitor"
BUNDLE_NAME="iPhone Inspector"
DISPLAY_NAME="iPhone 诊断助手"
BUNDLE_ID="com.local.iPhoneInspector"
MIN_SYSTEM_VERSION="13.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build/app-run"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$BUNDLE_NAME.app"
LEGACY_APP_BUNDLE="$DIST_DIR/iPhoneMonitor.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$PROCESS_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
ICON_SOURCE="$ROOT_DIR/Assets/AppIcon.icns"

cd "$ROOT_DIR"
pkill -x "$PROCESS_NAME" >/dev/null 2>&1 || true
pkill -x "$LEGACY_PROCESS_NAME" >/dev/null 2>&1 || true
if [[ -d "$LEGACY_APP_BUNDLE" ]]; then
  /bin/rm -rf "$LEGACY_APP_BUNDLE"
fi

swift build --scratch-path "$BUILD_DIR" --product "$PRODUCT_NAME"
BUILD_BINARY="$(
  swift build --scratch-path "$BUILD_DIR" --show-bin-path
)/$PRODUCT_NAME"

/bin/rm -rf "$APP_BUNDLE"
/bin/mkdir -p "$APP_MACOS" "$APP_RESOURCES"
/bin/cp "$BUILD_BINARY" "$APP_BINARY"
/bin/chmod +x "$APP_BINARY"

if [[ -f "$ICON_SOURCE" ]]; then
  /bin/cp "$ICON_SOURCE" "$APP_RESOURCES/AppIcon.icns"
fi

/bin/cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>zh_CN</string>
  <key>CFBundleExecutable</key>
  <string>$PROCESS_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$DISPLAY_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$DISPLAY_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.utilities</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

/usr/bin/plutil -lint "$INFO_PLIST" >/dev/null

# Documents may be managed by File Provider and immediately reattach FinderInfo.
# Sign in a clean temporary directory, then copy the already-signed bundle back.
SIGNING_DIR="$(mktemp -d /tmp/iphone-inspector-sign.XXXXXX)"
STAGED_BUNDLE="$SIGNING_DIR/$BUNDLE_NAME.app"
cleanup_signing_dir() {
  /bin/rm -rf "$SIGNING_DIR"
}
trap cleanup_signing_dir EXIT

/usr/bin/ditto --norsrc "$APP_BUNDLE" "$STAGED_BUNDLE"
/usr/bin/xattr -cr "$STAGED_BUNDLE"
/usr/bin/codesign --force --deep --sign - "$STAGED_BUNDLE" >/dev/null
/usr/bin/codesign --verify --deep --strict "$STAGED_BUNDLE"
/bin/rm -rf "$APP_BUNDLE"
/usr/bin/ditto --norsrc "$STAGED_BUNDLE" "$APP_BUNDLE"
# Documents may attach FinderInfo again when the bundle is copied back.
# Remove only bundle metadata and retry the exact-artifact verification because
# File Provider can reattach FinderInfo during the first verification attempt.
final_bundle_verified=false
for attempt in 1 2 3 4 5; do
  /usr/bin/xattr -cr "$APP_BUNDLE"
  if /usr/bin/codesign --verify --deep --strict "$APP_BUNDLE" 2>/dev/null; then
    final_bundle_verified=true
    break
  fi
  /bin/sleep 0.2
done
if [[ "$final_bundle_verified" != true ]]; then
  echo "最终 App Bundle 签名验证失败：$APP_BUNDLE" >&2
  exit 1
fi
cleanup_signing_dir
trap - EXIT

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

verify_process() {
  local attempt
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    if /usr/bin/pgrep -x "$PROCESS_NAME" >/dev/null; then
      echo "$DISPLAY_NAME 已启动：$APP_BUNDLE"
      return 0
    fi
    /bin/sleep 0.5
  done
  echo "$DISPLAY_NAME 未能保持运行，请使用 --logs 或 --debug 检查。" >&2
  return 1
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    /usr/bin/lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    verify_process
    /usr/bin/log stream --info --style compact --predicate "process == \"$PROCESS_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    verify_process
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    verify_process
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
