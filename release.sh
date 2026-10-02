#!/bin/bash
# Builds a Developer ID-signed, notarised Playa.app and zips it for download.
#
# Needs Local.xcconfig with your team (DEVELOPMENT_TEAM = XXXXXXXXXX), a "Developer ID Application"
# certificate, and a notarytool keychain profile:
#   xcrun notarytool store-credentials playa-notary
set -euo pipefail
cd "$(dirname "$0")"

PROFILE="${PLAYA_NOTARY_PROFILE:-playa-notary}"
TEAM=$(sed -n 's/^DEVELOPMENT_TEAM *= *//p' Local.xcconfig)
VERSION=$(sed -n 's/^ *MARKETING_VERSION: *"\(.*\)"/\1/p' project.yml)
ZIP="Playa-$VERSION.zip"
WORK=.build/release
rm -rf "$WORK" && mkdir -p "$WORK"

xcodegen generate --quiet
xcodebuild -project Playa.xcodeproj -scheme PlayaMac -configuration Release -derivedDataPath .build/xcode \
    -archivePath "$WORK/Playa.xcarchive" -allowProvisioningUpdates archive | grep -E "error:|ARCHIVE" || true

cat > "$WORK/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>$TEAM</string>
    <key>signingStyle</key>
    <string>automatic</string>
</dict>
</plist>
PLIST
xcodebuild -exportArchive -archivePath "$WORK/Playa.xcarchive" -exportPath "$WORK/export" \
    -exportOptionsPlist "$WORK/ExportOptions.plist" -allowProvisioningUpdates | grep -E "error:|EXPORT" || true
[ -d "$WORK/export/Playa.app" ] || { echo "Export failed" >&2; exit 1; }

rm -rf Playa.app
cp -R "$WORK/export/Playa.app" Playa.app
codesign --verify --strict --verbose=2 Playa.app

rm -f "$ZIP"
ditto -c -k --keepParent Playa.app "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple Playa.app

# Zip again so the download carries the stapled ticket.
rm -f "$ZIP"
ditto -c -k --keepParent Playa.app "$ZIP"
spctl --assess --type execute --verbose=2 Playa.app
echo "Release ready: $ZIP"
