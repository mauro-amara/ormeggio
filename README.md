# Ormeggio

App per la barra dei menu del Mac che salva e richiama **scene**. Una scena è il Mac sistemato come ti serve: app aperte, finestre su ogni monitor e su ogni scrivania, scala dei monitor, cartelle del Finder, schede del browser. La salvi con un nome (Ufficio 1, Ufficio 2, Mac da solo) e quando la richiami Ormeggio rimette tutto a posto.

Versione 0.2.3. Requisiti completi nel documento "Requisiti app layout monitor per Mac".

## Per chi la usa

### Installare

1. Apri `Ormeggio-0.2.3.dmg` e trascina **Ormeggio** su **Applicazioni**.
2. Apri Ormeggio da Applicazioni. Se macOS dice che non può verificare lo sviluppatore: Impostazioni di Sistema > Privacy e sicurezza, in fondo premi **Apri comunque**.
3. Nella finestra di benvenuto premi **Continua** e attiva Ormeggio nell'elenco **Accessibilità**.

L'icona di Ormeggio compare nella barra in alto, vicino all'orologio.

### Usare

- **Salva scena…**: sistema il Mac come ti serve, scegli un nome. Puoi chiedere che la scena parta da sola quando ricolleghi gli stessi monitor.
- **Richiama**: clic sul nome della scena nel menu.
- **Le tue scene…**: finestra con tutte le scene, per richiamarle, rinominarle, eliminarle.

Il salvataggio legge le finestre di tutte le scrivanie senza farle scorrere. Quando richiami una scena, Ormeggio passa solo dalle scrivanie dove deve spostare una finestra: in quei secondi non toccare mouse e tastiera.

La prima volta che salvi con Finder, Chrome o Safari aperti, macOS chiede se Ormeggio può controllarli: rispondi OK. Serve per sapere quali cartelle e schede sono aperte.

### Zoom

Lo zoom di Chrome Ormeggio lo salva da solo, sito per sito, e lo rimette quando richiami la scena. Per le altre app (per esempio Slack): Le tue scene > menu della scena > **Zoom delle app…**, scegli l'ingrandimento di ogni app.

### Aggiornamenti

Quando esce una nuova versione, nel menu di Ormeggio compare **Aggiorna alla versione…**. Premilo: Ormeggio scarica la nuova versione, si chiude, si aggiorna e si riapre da solo. Puoi controllare anche da Impostazioni > **Cerca aggiornamenti…**.

### Se qualcosa non va

Icona di Ormeggio > Impostazioni > **Salva diagnostica per l'assistenza…**. Crea un file di testo con la diagnostica, l'elenco delle scene e il registro delle ultime operazioni, senza gli indirizzi delle schede. Mandalo a chi ti assiste.

### Disinstallare

Icona di Ormeggio > Impostazioni > **Disinstalla Ormeggio…**. Toglie l'avvio all'accensione, le scene salvate, i permessi e sposta l'app nel Cestino.

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
