#!/bin/bash
# Builds "Robo Tribute.app" (arm64, release) into ./build.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Robo Tribute.app"
VERSION="${VERSION:-1.0.0}"

"$ROOT/scripts/build-deps.sh"
cd "$ROOT"
xcrun swift build -c release --arch arm64
BIN="$(xcrun swift build -c release --arch arm64 --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/RoboTribute" "$APP/Contents/MacOS/Robo Tribute"
cp -R "$BIN/RoboTribute_RoboTribute.bundle" "$APP/Contents/Resources/"
sed "s/__VERSION__/$VERSION/g" "$ROOT/packaging/Info.plist" > "$APP/Contents/Info.plist"

LICENSES="$APP/Contents/Resources/Licenses"
mkdir -p "$LICENSES"
cp "$ROOT/LICENSE" "$LICENSES/RoboTribute-GPLv3.txt"
cp "$ROOT/THIRD_PARTY_NOTICES.md" "$LICENSES/"
cp "$ROOT/.deps/install/share/mongo-c-driver/"*/COPYING "$LICENSES/mongo-c-driver-LICENSE.txt"
cp "$ROOT/.deps/install/share/mongo-c-driver/"*/THIRD_PARTY_NOTICES "$LICENSES/mongo-c-driver-THIRD_PARTY_NOTICES.txt"
cp "$ROOT/.deps/openssl/LICENSE.txt" "$LICENSES/OpenSSL-LICENSE.txt"

# Icon Composer icon: Assets.car for macOS 26, which otherwise boxes legacy icons onto a gray plate, plus an .icns fallback.
xcrun actool "$ROOT/packaging/AppIcon.icon" --compile "$APP/Contents/Resources" --platform macosx \
    --minimum-deployment-target 14.0 --app-icon AppIcon --output-partial-info-plist "$ROOT/build/AppIcon-partial.plist" >/dev/null

# A stable identity keeps the Keychain's access grant across rebuilds; ad hoc signatures change with every build.
IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development|Developer ID Application/ { print $2; exit }')}"
codesign --force --options runtime --entitlements "$ROOT/packaging/RoboTribute.entitlements" --sign "${IDENTITY:--}" "$APP"
echo "Built $APP"
