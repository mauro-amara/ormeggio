# Ormeggio

App per la barra dei menu del Mac che salva e richiama **scene** di lavoro: ogni finestra al suo posto, con un clic.

## Il problema

Chi lavora con il Mac portatile lo attacca e lo stacca da monitor diversi più volte al giorno: ufficio, casa, sala riunioni. Ogni volta macOS sposta tutte le finestre sullo schermo del portatile. Quando ricolleghi il monitor, spesso le finestre non tornano dove stavano. Le scrivanie del monitor esterno vanno ricreate, risoluzione e zoom vanno sistemati app per app, le finestre dei profili di Chrome si mescolano. Ogni cambio di postazione vuol dire rimettere tutto in ordine a mano.

Gli strumenti che esistono risolvono un pezzo ciascuno. Stay ricorda le finestre ma non le scrivanie né lo zoom, Hammerspoon richiede script da scrivere e mantenere, Rectangle e Magnet affiancano le finestre ma non ricordano niente.

## La soluzione

Ormeggio è un'app gratuita per la barra dei menu. Sistemi il Mac come ti serve e salvi una **scena** con un nome: Ufficio, Casa, Mac da solo. Quando la richiami, con un clic o in automatico quando ricolleghi gli stessi monitor, Ormeggio rimette risoluzione, scrivanie, app aperte, posizione di ogni finestra, cartelle del Finder, finestre di Chrome nel profilo giusto con le loro schede, e zoom. Alla fine un riquadro a schermo dice cosa ha sistemato e cosa no, con il motivo.

## Per chi la usa

### Installare

1. Scarica l'ultima versione dal ramo [`builds`](https://github.com/mauro-amara/ormeggio/tree/builds) (file `Ormeggio-<versione>.dmg`), aprila e trascina **Ormeggio** su **Applicazioni**.
2. Apri Ormeggio da Applicazioni. Se macOS dice che non può verificare lo sviluppatore: Impostazioni di Sistema > Privacy e sicurezza, in fondo premi **Apri comunque**.
3. Nella finestra di benvenuto premi **Continua** e attiva Ormeggio nell'elenco **Accessibilità**.

In alternativa, questo comando nel Terminale scarica e installa l'ultima versione, senza gli avvisi di macOS:

```sh
mkdir -p /tmp/ormeggio-dmg && \
curl -fsSL https://raw.githubusercontent.com/mauro-amara/ormeggio/builds/latest.json -o /tmp/ormeggio.json && \
DMG=$(plutil -extract dmg raw -o - /tmp/ormeggio.json) && \
curl -fL "https://raw.githubusercontent.com/mauro-amara/ormeggio/builds/$DMG" -o /tmp/Ormeggio.dmg && \
echo "$(plutil -extract sha256 raw -o - /tmp/ormeggio.json)  /tmp/Ormeggio.dmg" | shasum -a 256 -c - && \
hdiutil attach /tmp/Ormeggio.dmg -nobrowse -readonly -mountpoint /tmp/ormeggio-dmg && \
(pkill -x Ormeggio || true) && sleep 1 && \
rm -rf /Applications/Ormeggio.app && \
ditto /tmp/ormeggio-dmg/Ormeggio.app /Applications/Ormeggio.app && \
hdiutil detach /tmp/ormeggio-dmg && \
xattr -dr com.apple.quarantine /Applications/Ormeggio.app && \
open /Applications/Ormeggio.app
```

L'icona di Ormeggio compare nella barra in alto, vicino all'orologio.

### Usare

Il menu ha cinque voci:

- **Vedi le scene…**: finestra con tutte le scene, per richiamarle, rinominarle, eliminarle.
- **Salva scena…**: sistema il Mac come ti serve, scegli un nome. Puoi chiedere che la scena parta da sola quando ricolleghi gli stessi monitor.
- **Richiama scena**: clic sul nome della scena. La scena in uso ha il segno di spunta.
- **Aggiornamenti**: controlla subito se c'è una versione nuova.
- **Segnalazioni**: prepara il file da mandare quando qualcosa non va.

Sotto ci sono **Impostazioni** ed **Esci**.

Il salvataggio legge le finestre di tutte le scrivanie senza farle scorrere. Quando richiami una scena, Ormeggio passa solo dalle scrivanie dove deve spostare una finestra: in quei secondi non toccare mouse e tastiera. Un riquadro in basso dice quando ha finito, cosa ha sistemato e cosa no.

La prima volta che salvi con Finder, Chrome o Safari aperti, macOS chiede se Ormeggio può controllarli: rispondi OK. Serve per sapere quali cartelle e schede sono aperte.

### Zoom

Lo zoom di Chrome Ormeggio lo salva da solo, sito per sito e profilo per profilo, e lo rimette quando richiami la scena. Chrome scrive lo zoom con qualche secondo di ritardo: Ormeggio lo rilegge 12 secondi dopo il salvataggio e aggiorna la scena. Per le altre app (per esempio Slack): Vedi le scene > menu della scena > **Zoom delle app…**, scegli l'ingrandimento di ogni app.

### Aggiornamenti

Ormeggio controlla ogni mezz'ora se c'è una versione nuova e la installa da solo: si chiude, si aggiorna e si riapre. Subito dopo arriva una notifica di macOS a ogni persona che lo usa, con le novità. La prima volta macOS chiede se Ormeggio può mandare notifiche: premi **Consenti**. Dal menu di Ormeggio: **Aggiornamenti** per averla subito. Le novità si rileggono in **Impostazioni** > **Novità dell'ultima versione**.

### Se qualcosa non va

Icona di Ormeggio > **Segnalazioni**. Ormeggio prepara un file con la diagnostica e lo mostra nel Finder: trascinalo nella chat con Claude. Il file resta sul Mac finché non lo mandi tu. Contiene il registro delle ultime operazioni e i titoli delle finestre, mai gli indirizzi delle schede.

### Disinstallare

Icona di Ormeggio > Impostazioni > **Disinstalla Ormeggio…**. Toglie l'avvio all'accensione, le scene salvate, i permessi e sposta l'app nel Cestino.

## Sicurezza e dati

- **Permessi.** Ormeggio usa l'Accessibilità per spostare le finestre e, se concessa, l'Automazione per leggere schede e cartelle. Non chiede altro: niente registrazione dello schermo, niente accesso ai file.
- **Dati.** Scene e registro stanno in `~/Library/Application Support/Ormeggio`, leggibili solo dalla persona. Non escono dal Mac. Nel registro ci sono i titoli delle finestre e i nomi dei siti, mai gli indirizzi completi delle schede.
- **Aggiornamenti.** Si scaricano solo da questo repository, in HTTPS. Prima di installare, Ormeggio controlla che il file sia identico a quello pubblicato (impronta SHA-256), che contenga proprio Ormeggio nella versione annunciata e che la firma sia intatta. Se un controllo non passa, l'aggiornamento non si installa. La compilazione usa solo git e gli strumenti di Apple, senza azioni di terzi, e fa gli stessi controlli prima di pubblicare.
- **Limite noto.** L'app è firmata localmente, non con un certificato Developer ID di Apple. La sicurezza degli aggiornamenti dipende quindi dall'account GitHub che pubblica. Il passo successivo è firmare e notarizzare con l'account sviluppatore dell'azienda.
- **Segnalazioni.** Niente parte da solo: "Segnalazioni" crea un file sul Mac, e la persona decide se e a chi mandarlo. Nell'app non c'è nessuna chiave o password.

## Cosa fa

| Cosa | Come |
| --- | --- |
| Scene con nome | Salvate in `~/Library/Application Support/Ormeggio/scene.json` |
| Richiamo automatico al cambio di monitor | Opzione della singola scena |
| Scala di ogni monitor, anche del Mac | API pubbliche di macOS |
| App chiuse | Le riapre |
| Finestre su monitor e scrivania giusti | Accessibilità; per cambiare scrivania trascina la finestra e usa ctrl + frecce |
| Numero di scrivanie | Le aggiunge e le toglie da Mission Control (non se ci sono app a tutto schermo) |
| Cartelle del Finder | Le riapre |
| Schede di Chrome e Safari | Le riapre nella finestra giusta |
| Profili di Chrome | Li riconosce dal pulsante del profilo, altrimenti li chiede al salvataggio |
| Documenti | Li riapre se l'app li dichiara |
| Impostazioni di Sistema | Riapre la pagina che era aperta |
| Finestre fuori dalla scena | Sulle scrivanie della scena le riduce nel Dock, tranne le riunioni (si spegne da Impostazioni) |
| Zoom di Chrome | Lo rimette sito per sito senza riaprire le app web (WhatsApp Web resta collegato) |

## Limiti

- **Scrivanie.** Apple non offre API pubbliche. Ormeggio legge le scrivanie con funzioni private caricate all'avvio e le cambia simulando le scorciatoie ctrl + frecce, che devono essere attive (lo sono di serie). Un aggiornamento di macOS può richiedere una correzione.
- **Movimento visibile.** Durante salvataggio e richiamo le scrivanie scorrono per qualche secondo.
- **Firma.** Senza un certificato Developer ID l'app è firmata solo localmente e macOS chiede conferma alla prima apertura.

## Per chi sviluppa

Il DMG si crea su un Mac con:

```
bash scripts/build-app.sh
bash scripts/make-dmg.sh
```

A ogni push su `main`, GitHub Actions (`.github/workflows/build.yml`) compila su un Mac in cloud, allega il DMG all'esecuzione e lo pubblica con il registro di compilazione nel ramo `builds`.

Per firmare con Developer ID imposta la variabile `SIGN_IDENTITY` prima di `build-app.sh`; la notarizzazione va aggiunta al workflow con le credenziali dell'account Apple Developer aziendale.

| File | Ruolo |
| --- | --- |
| `OrmeggioApp.swift` | Avvio |
| `AppDelegate.swift` | Icona, menu, benvenuto, salvataggio, disinstallazione |
| `ScenesWindow.swift` | Finestra "Le tue scene" |
| `Engine.swift` | Salvataggio e richiamo delle scene |
| `DisplayManager.swift` | Monitor, identità e risoluzione |
| `WindowManager.swift` | Finestre tramite Accessibilità |
| `SpacesManager.swift` | Scrivanie |
| `Input.swift` | Mouse e tastiera simulati |
| `FinderBridge.swift` | Cartelle del Finder |
| `BrowserBridge.swift` | Schede e profili di Chrome e Safari |
| `Storage.swift` | Archivio delle scene e registro |
| `Models.swift` | Strutture dati |
