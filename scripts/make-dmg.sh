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
ORMEGGIO

INSTALLARE
1. Trascina Ormeggio sulla cartella Applicazioni qui accanto.
2. Apri Ormeggio dalla cartella Applicazioni con un doppio clic.

LA PRIMA VOLTA macOS LO BLOCCA
Compare "Ormeggio non è stata aperta". È normale: Ormeggio non è ancora
certificato da Apple. Lo sblocchi una volta sola.
3. Premi Fine. Non premere "Sposta nel Cestino".
4. Apri Impostazioni di Sistema > Privacy e sicurezza e scorri fino in fondo.
   Accanto al messaggio su Ormeggio premi "Apri comunque" e metti la password del Mac.
5. Nella finestra che compare premi di nuovo "Apri comunque".

SE "APRI COMUNQUE" NON C'È, O IL BLOCCO RICOMPARE
Succede su alcuni Mac gestiti da un'azienda. C'è un altro modo, spiegato passo per passo qui:
https://github.com/mauro-amara/ormeggio#se-macos-non-apre-ormeggio

PRIMO AVVIO
6. Nel benvenuto premi "Continua".
7. Si apre Impostazioni di Sistema su Accessibilità: accendi l'interruttore accanto a Ormeggio.
   Se Ormeggio non è nell'elenco: premi + in fondo, scegli Ormeggio in Applicazioni, premi Apri.
8. Quando il permesso è attivo, Ormeggio lo dice in un riquadro in basso.

USARE
L'icona di Ormeggio è nella barra in alto, vicino all'orologio.
Sistema le finestre come ti servono e scegli "Salva scena…".
Per tornarci: "Richiama scena".

DISINSTALLARE
Icona di Ormeggio > Impostazioni > Disinstalla Ormeggio.

Istruzioni complete e problemi comuni:
https://github.com/mauro-amara/ormeggio#installare
TXT
hdiutil create -volname "Ormeggio $VERSION" -srcfolder "$STAGE" -ov -format UDZO "dist/Ormeggio-$VERSION.dmg"
rm -rf "$STAGE"
echo "Creato dist/Ormeggio-$VERSION.dmg"
