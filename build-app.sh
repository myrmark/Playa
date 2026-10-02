#!/bin/bash
# Builds Playa and wraps it in Playa.app. Pass "run" to launch it afterwards.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="Playa.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/Playa" "$APP/Contents/MacOS/Playa"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"

echo "Built $APP"
if [ "${1:-}" = "run" ]; then
    open "$APP"
fi
