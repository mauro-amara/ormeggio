#!/bin/sh
# Installa o aggiorna Ormeggio: scarica l'ultima versione da GitHub, controlla che sia quella giusta,
# la copia in Applicazioni e la apre. Scaricata così, macOS non la blocca.
# Non chiede password e non tocca nient'altro sul Mac.
set -eu

BASE="https://raw.githubusercontent.com/mauro-amara/ormeggio/builds"
WORK="$(mktemp -d /tmp/ormeggio.XXXXXX)"
cleanup() {
    hdiutil detach "$WORK/mnt" -quiet 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT

fail() {
    echo "Ormeggio non installato: $1"
    exit 1
}

echo "Scarico Ormeggio..."
curl -fsSL --proto '=https' "$BASE/latest.json" -o "$WORK/latest.json" || fail "non riesco a scaricare le informazioni sulla versione"
DMG="$(plutil -extract dmg raw -o - "$WORK/latest.json")" || fail "informazioni sulla versione non valide"
SHA="$(plutil -extract sha256 raw -o - "$WORK/latest.json")" || fail "informazioni sulla versione non valide"

# Solo nomi e impronte nel formato atteso: niente altro finisce nei comandi.
case "$DMG" in
    Ormeggio-[0-9]*.[0-9]*.[0-9]*.dmg) ;;
    *) fail "nome del file non valido" ;;
esac
case "$DMG" in
    *[!A-Za-z0-9.-]*) fail "nome del file non valido" ;;
esac
case "$SHA" in
    ""|*[!0-9a-f]*) fail "impronta non valida" ;;
esac
[ "${#SHA}" -eq 64 ] || fail "impronta non valida"

curl -fsSL --proto '=https' "$BASE/$DMG" -o "$WORK/Ormeggio.dmg" || fail "non riesco a scaricare l'app"
echo "$SHA  $WORK/Ormeggio.dmg" | shasum -a 256 -c - >/dev/null 2>&1 || fail "il file scaricato non corrisponde all'impronta"

mkdir "$WORK/mnt"
hdiutil attach "$WORK/Ormeggio.dmg" -nobrowse -readonly -mountpoint "$WORK/mnt" -quiet || fail "non riesco ad aprire il file scaricato"
APP="$WORK/mnt/Ormeggio.app"
[ "$(plutil -extract CFBundleIdentifier raw -o - "$APP/Contents/Info.plist")" = "com.sparkfabrik.ormeggio" ] || fail "app non riconosciuta"
codesign --verify --deep --strict "$APP" 2>/dev/null || fail "firma dell'app non valida"

echo "Installo in Applicazioni..."
pkill -x Ormeggio 2>/dev/null || true
sleep 1
rm -rf "/Applications/Ormeggio.app"
ditto "$APP" "/Applications/Ormeggio.app" || fail "non riesco a copiarla in Applicazioni"
xattr -dr com.apple.quarantine "/Applications/Ormeggio.app" 2>/dev/null || true

echo "Fatto. Apro Ormeggio: segui la finestra di benvenuto."
open "/Applications/Ormeggio.app"
