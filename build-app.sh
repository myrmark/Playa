#!/bin/bash
# Builds the Mac app into ./Playa.app. Pass "run" to launch it afterwards.
#
# With a Local.xcconfig naming your Apple team (DEVELOPMENT_TEAM = XXXXXXXXXX) the app is signed
# for development and gets iCloud sync. Without one it is signed ad-hoc and simply doesn't sync.
set -euo pipefail
cd "$(dirname "$0")"

command -v xcodegen >/dev/null || { echo "xcodegen is needed: brew install xcodegen" >&2; exit 1; }
xcodegen generate --quiet

ARGS=(-project Playa.xcodeproj -scheme PlayaMac -configuration Release -derivedDataPath .build/xcode)
if [ -f Local.xcconfig ]; then
    ARGS+=(-allowProvisioningUpdates -allowProvisioningDeviceRegistration)
    # With an App Store Connect API key (see appstore.sh) signing doesn't depend on Xcode's own sign-in.
    if [ -f Local.env ]; then
        source Local.env
        ARGS+=(-authenticationKeyPath "$HOME/.appstoreconnect/private_keys/AuthKey_$PLAYA_ASC_KEY_ID.p8"
               -authenticationKeyID "$PLAYA_ASC_KEY_ID" -authenticationKeyIssuerID "$PLAYA_ASC_ISSUER_ID")
    fi
else
    ARGS+=(CODE_SIGN_IDENTITY=- CODE_SIGN_ENTITLEMENTS= CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=)
fi
xcodebuild "${ARGS[@]}" build | grep -E "error:|warning: unable|BUILD" || true

PRODUCT=.build/xcode/Build/Products/Release/Playa.app
[ -d "$PRODUCT" ] || { echo "Build failed" >&2; exit 1; }
rm -rf Playa.app
cp -R "$PRODUCT" Playa.app
echo "Built Playa.app"

if [ "${1:-}" = "run" ]; then
    open Playa.app
fi
