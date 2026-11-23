#!/bin/bash
# Crea dist/Ormeggio-<versione>.dmg da build/Ormeggio.app.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
STAGE="dist/stage"
rm -rf dist
mkdir -p "$STAGE"
cp -R build/Ormeggio.app "$STAGE/"
ln -s /Applications "$STAGE/Applicazioni"
cat > "$STAGE/Leggimi.txt" <<'TXT'
Ormeggio

Installare: trascina Ormeggio sulla cartella Applicazioni, poi aprilo da lì.
La prima volta macOS chiede di confermare l'apertura e di attivare Ormeggio in Accessibilità.

Usare: l'icona di Ormeggio è nella barra in alto, vicino all'orologio.
Sistema il Mac come ti serve e scegli "Salva scena…". Per tornarci, clic sul nome della scena.

Disinstallare: icona di Ormeggio > Impostazioni > Disinstalla Ormeggio.
TXT
hdiutil create -volname "Ormeggio $VERSION" -srcfolder "$STAGE" -ov -format UDZO "dist/Ormeggio-$VERSION.dmg"
rm -rf "$STAGE"
echo "Creato dist/Ormeggio-$VERSION.dmg"
