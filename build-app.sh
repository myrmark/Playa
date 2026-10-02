#!/bin/bash
# Builds Playa and wraps it in Playa.app. Pass "run" to launch it afterwards.
#
# The app is signed with a "Developer ID Application" certificate when the keychain has one,
# and ad-hoc otherwise. Set PLAYA_RELEASE=1 for a timestamped signature, which notarisation needs.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="Playa.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/Playa" "$APP/Contents/MacOS/Playa"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

IDENTITY=$(security find-identity -v -p codesigning | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"' || true)
if [ -n "$IDENTITY" ]; then
    if [ "${PLAYA_RELEASE:-}" = "1" ]; then TIMESTAMP="--timestamp"; else TIMESTAMP="--timestamp=none"; fi
    codesign --force --options runtime $TIMESTAMP --sign "$IDENTITY" "$APP"
    echo "Built $APP (signed with Developer ID)"
else
    codesign --force --sign - "$APP"
    echo "Built $APP (ad-hoc signed)"
fi

if [ "${1:-}" = "run" ]; then
    open "$APP"
fi
