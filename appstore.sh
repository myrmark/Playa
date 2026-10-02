#!/bin/bash
# Builds the Mac and Apple TV apps for the App Store.
#
#   ./appstore.sh          archive both and export the packages into .build/appstore
#   ./appstore.sh upload   archive both and upload them to App Store Connect
#
# Needs Local.xcconfig (DEVELOPMENT_TEAM = XXXXXXXXXX) and Local.env with an App Store Connect
# API key (PLAYA_ASC_KEY_ID, PLAYA_ASC_ISSUER_ID); the key file itself belongs in
# ~/.appstoreconnect/private_keys/AuthKey_<key id>.p8.
set -euo pipefail
cd "$(dirname "$0")"

source Local.env
TEAM=$(sed -n 's/^DEVELOPMENT_TEAM *= *//p' Local.xcconfig)
AUTH=(-allowProvisioningUpdates
      -authenticationKeyPath "$HOME/.appstoreconnect/private_keys/AuthKey_$PLAYA_ASC_KEY_ID.p8"
      -authenticationKeyID "$PLAYA_ASC_KEY_ID" -authenticationKeyIssuerID "$PLAYA_ASC_ISSUER_ID")
DESTINATION=$([ "${1:-}" = "upload" ] && echo upload || echo export)
# App Store Connect wants a build number that only ever goes up.
BUILD=$(date +%Y%m%d%H%M)
WORK=.build/appstore
rm -rf "$WORK" && mkdir -p "$WORK"

cat > "$WORK/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store-connect</string>
    <key>destination</key>
    <string>$DESTINATION</string>
    <key>teamID</key>
    <string>$TEAM</string>
    <key>signingStyle</key>
    <string>automatic</string>
</dict>
</plist>
PLIST

xcodegen generate --quiet
for SCHEME in PlayaMac PlayaTV; do
    PLATFORM=$([ "$SCHEME" = "PlayaTV" ] && echo "generic/platform=tvOS" || echo "generic/platform=macOS")
    echo "== $SCHEME: archive"
    xcodebuild -project Playa.xcodeproj -scheme "$SCHEME" -configuration Release -destination "$PLATFORM" \
        -derivedDataPath .build/xcode -archivePath "$WORK/$SCHEME.xcarchive" CURRENT_PROJECT_VERSION="$BUILD" \
        "${AUTH[@]}" archive | grep -E "error:|ARCHIVE" || true
    [ -d "$WORK/$SCHEME.xcarchive" ] || { echo "Archive failed for $SCHEME" >&2; exit 1; }
    echo "== $SCHEME: $DESTINATION"
    xcodebuild -exportArchive -archivePath "$WORK/$SCHEME.xcarchive" -exportPath "$WORK/$SCHEME" \
        -exportOptionsPlist "$WORK/ExportOptions.plist" "${AUTH[@]}" | grep -E "error:|EXPORT|Upload|upload" || true
done
echo "Done ($DESTINATION), build $BUILD"
