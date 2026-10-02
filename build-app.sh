#!/bin/bash
# Builds LaPlaya and wraps it in LaPlaya.app. Pass "run" to launch it afterwards.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="LaPlaya.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/LaPlaya" "$APP/Contents/MacOS/LaPlaya"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"

echo "Built $APP"
if [ "${1:-}" = "run" ]; then
    open "$APP"
fi
