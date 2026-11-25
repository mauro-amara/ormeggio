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

INSTALLARE
1. Trascina Ormeggio sulla cartella Applicazioni.
2. Apri Ormeggio da Applicazioni con un doppio clic.

LA PRIMA VOLTA macOS lo blocca ("Ormeggio non è stata aperta"): è normale.
3. Premi Fine. Non premere "Sposta nel Cestino".
4. Apri Impostazioni di Sistema > Privacy e sicurezza, scorri in fondo
   e accanto al messaggio su Ormeggio premi "Apri comunque". Poi la password del Mac.
5. Nella finestra che compare premi di nuovo "Apri comunque".
6. Nel benvenuto di Ormeggio premi "Continua" e accendi Ormeggio in Accessibilità.
   Se Ormeggio non è nell'elenco: premi + in fondo, scegli Ormeggio in Applicazioni, premi Apri.

USARE
L'icona di Ormeggio è nella barra in alto, vicino all'orologio.
Sistema il Mac come ti serve e scegli "Salva scena…". Per tornarci: "Richiama scena".

DISINSTALLARE
Icona di Ormeggio > Impostazioni > Disinstalla Ormeggio.

Istruzioni complete: https://github.com/mauro-amara/ormeggio
TXT
hdiutil create -volname "Ormeggio $VERSION" -srcfolder "$STAGE" -ov -format UDZO "dist/Ormeggio-$VERSION.dmg"
rm -rf "$STAGE"
echo "Creato dist/Ormeggio-$VERSION.dmg"
