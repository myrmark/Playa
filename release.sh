#!/bin/bash
# Builds a signed, notarised Playa.app and zips it for download.
#
# Needs a "Developer ID Application" certificate and a notarytool keychain profile:
#   xcrun notarytool store-credentials playa-notary
set -euo pipefail
cd "$(dirname "$0")"

PROFILE="${PLAYA_NOTARY_PROFILE:-playa-notary}"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Support/Info.plist)
ZIP="Playa-$VERSION.zip"

PLAYA_RELEASE=1 ./build-app.sh
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
