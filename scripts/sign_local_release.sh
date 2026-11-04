#!/bin/bash
set -euo pipefail

# Certificate-backed identity is mandatory; never silently fall back to ad-hoc.
APP_PATH=${1:?Usage: sign_local_release.sh app-path signing-identity}
SIGNING_IDENTITY=${2:?A certificate-backed signing identity is required}
[[ "$SIGNING_IDENTITY" != "-" ]] || { echo 'Ad-hoc release signing is not supported.' >&2; exit 1; }
SCRIPT_ROOT=$(cd "$(dirname "$0")/.." && pwd)
ENTITLEMENTS_PATH="$SCRIPT_ROOT/DynamicIsland/DynamicIsland.entitlements"
[[ -d "$APP_PATH/Contents" ]] || exit 1
[[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP_PATH/Contents/Info.plist")" == 'com.kayhsen.NotchFlow' ]] || exit 1

for nested in \
    "$APP_PATH/Contents/MacOS/NotchFlowLowPowerHelper" \
    "$APP_PATH/Contents/Frameworks/Lottie.framework" \
    "$APP_PATH/Contents/Resources/MediaRemoteAdapter.framework" \
    "$APP_PATH/Contents/Helpers/NowPlayingTestClient"; do
    /usr/bin/codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none "$nested"
done
if [[ -d "$APP_PATH/Contents/PlugIns/OrbitWidgets.appex" ]]; then
    /usr/bin/codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none --entitlements "$SCRIPT_ROOT/OrbitWidgets/OrbitWidgets.entitlements" "$APP_PATH/Contents/PlugIns/OrbitWidgets.appex"
fi
/usr/bin/codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none --entitlements "$ENTITLEMENTS_PATH" "$APP_PATH"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_PATH"
FINAL_ENTITLEMENTS_PATH=$(mktemp /private/tmp/notchflow-entitlements.XXXXXX)
/usr/bin/codesign -d --entitlements :- "$APP_PATH" > "$FINAL_ENTITLEMENTS_PATH"
for required in com.apple.security.device.camera com.apple.security.automation.apple-events; do
    [[ "$(/usr/libexec/PlistBuddy -c "Print :$required" "$FINAL_ENTITLEMENTS_PATH")" == true ]] || exit 1
done
/usr/bin/codesign -d -r- "$APP_PATH"
