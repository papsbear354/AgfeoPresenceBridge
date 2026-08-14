#!/bin/bash
#
# Baut eine auslieferbare App und packt sie in ein DMG.
#
#   Scripts/build-release.sh [Version]
#
# Ohne Version wird die aus project.yml genommen. Signiert und notarisiert
# wird nur, wenn die nötigen Angaben da sind — sonst entsteht ein unsigniertes
# Bündel, das lokal läuft, auf fremden Rechnern aber von Gatekeeper
# angehalten wird.
#
# Erwartete Umgebung für die Auslieferung:
#   SIGN_IDENTITY     "Developer ID Application: … (TEAMID)"
#   NOTARY_PROFILE    Name eines mit `notarytool store-credentials` angelegten Profils
#
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${1:-$(grep MARKETING_VERSION project.yml | head -1 | tr -d ' "' | cut -d: -f2)}"
BUILD_DIR="build"
APP_NAME="AGFEOPresenceBridge"
DMG="$BUILD_DIR/$APP_NAME-$VERSION.dmg"

echo "▸ Version $VERSION"

command -v xcodegen >/dev/null || { echo "xcodegen fehlt: brew install xcodegen"; exit 1; }
xcodegen generate

echo "▸ Tests"
xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" \
    -configuration Debug test 2>&1 | grep -E "Test run|TEST (SUCCEEDED|FAILED)" || true

echo "▸ Release-Build"
rm -rf "$BUILD_DIR"
xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" \
    -configuration Release -derivedDataPath "$BUILD_DIR" \
    MARKETING_VERSION="$VERSION" \
    build >/dev/null

APP="$BUILD_DIR/Build/Products/Release/$APP_NAME.app"
[ -d "$APP" ] || { echo "Build fehlgeschlagen"; exit 1; }

if [ -n "${SIGN_IDENTITY:-}" ]; then
    echo "▸ Signieren"
    # Tiefe Signatur mit Hardened Runtime — beides Voraussetzung für die
    # Notarisierung.
    codesign --force --deep --options runtime --timestamp \
        --sign "$SIGN_IDENTITY" "$APP"
    codesign --verify --strict --verbose=2 "$APP"
else
    echo "▸ Signieren übersprungen (SIGN_IDENTITY nicht gesetzt)"
fi

if [ -n "${NOTARY_PROFILE:-}" ] && [ -n "${SIGN_IDENTITY:-}" ]; then
    echo "▸ Notarisieren (kann einige Minuten dauern)"
    ZIP="$BUILD_DIR/notarize.zip"
    ditto -c -k --keepParent "$APP" "$ZIP"
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    # Das Ergebnis an die App heften, damit sie auch ohne Netz als geprüft gilt.
    xcrun stapler staple "$APP"
    rm -f "$ZIP"
else
    echo "▸ Notarisieren übersprungen"
fi

echo "▸ DMG"
STAGE="$BUILD_DIR/dmg"
rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Programme"
hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$STAGE" \
    -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

echo
echo "Fertig: $DMG"
