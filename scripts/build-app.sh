#!/bin/bash
# Compila Ormeggio (Apple Silicon e Intel) e crea build/Ormeggio.app.
set -euo pipefail
cd "$(dirname "$0")/.."

ARCHS=(--arch arm64 --arch x86_64)
swift build -c release "${ARCHS[@]}"
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)/Ormeggio"

APP="build/Ormeggio.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Ormeggio"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/MenuIcon.png Resources/MenuIcon@2x.png "$APP/Contents/Resources/"

# Firma: Developer ID se disponibile (variabile SIGN_IDENTITY), altrimenti firma locale.
IDENTITY="${SIGN_IDENTITY:--}"
codesign --force --options runtime --timestamp=none --entitlements Resources/Ormeggio.entitlements --sign "$IDENTITY" "$APP"
codesign --verify --verbose=2 "$APP"
echo "Creata $APP"
