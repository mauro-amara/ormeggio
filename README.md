# Ormeggio

App gratuita per Mac che salva e richiama la disposizione delle tue finestre: ogni app sul suo monitor, sulla sua scrivania, alla sua misura. Con un clic, o da sola quando ricolleghi il monitor.

**[Scarica Ormeggio](https://github.com/mauro-amara/ormeggio/releases/latest/download/Ormeggio.dmg)** · gratis · macOS 14 o successivo · Mac con processore Apple o Intel

## Il problema

Chi lavora con il Mac portatile lo attacca e lo stacca da monitor diversi più volte al giorno: ufficio, casa, sala riunioni. Ogni volta macOS sposta tutte le finestre sullo schermo del portatile. Quando ricolleghi il monitor, spesso le finestre non tornano dove stavano. Le scrivanie del monitor esterno vanno ricreate, risoluzione e zoom vanno sistemati app per app, le finestre dei profili di Chrome si mescolano. Ogni cambio di postazione vuol dire rimettere tutto in ordine a mano.

Gli strumenti che esistono risolvono un pezzo ciascuno. Stay ricorda le finestre ma non le scrivanie né lo zoom, Hammerspoon richiede script da scrivere e mantenere, Rectangle e Magnet affiancano le finestre ma non ricordano niente.

## La soluzione

Sistemi il Mac come ti serve e salvi una **scena** con un nome: Ufficio, Casa, Mac da solo. Quando la richiami, con un clic o in automatico quando ricolleghi gli stessi monitor, Ormeggio rimette risoluzione, scrivanie, app aperte, posizione di ogni finestra, cartelle del Finder, finestre di Chrome nel profilo giusto con le loro schede, e zoom. Alla fine un riquadro a schermo dice cosa ha sistemato e cosa no, con il motivo.

Tutto resta sul tuo Mac: niente account, niente dati che escono.

## Installare

Ci vogliono un paio di minuti.

1. Scarica **[Ormeggio.dmg](https://github.com/mauro-amara/ormeggio/releases/latest/download/Ormeggio.dmg)**. Il link scarica sempre l'ultima versione.
2. Apri il file scaricato con un doppio clic. Si apre una finestra con l'icona di Ormeggio e la cartella Applicazioni.
3. Trascina l'icona di **Ormeggio** sulla cartella **Applicazioni**.
4. Apri la cartella Applicazioni (nel Finder, a sinistra) e apri **Ormeggio** con un doppio clic.

### La prima volta macOS lo blocca

Compare il messaggio "Ormeggio non è stata aperta". È normale: macOS apre senza avvisi solo le app certificate da Apple, e Ormeggio non lo è ancora. Non vuol dire che sia pericoloso. Lo sblocchi una volta sola, poi si apre sempre, anche dopo gli aggiornamenti.

5. Premi **Fine**. Non premere "Sposta nel Cestino".
6. Apri **Impostazioni di Sistema** (menu Apple, in alto a sinistra) e scegli **Privacy e sicurezza**. Scorri fino in fondo alla pagina.
7. Accanto al messaggio su Ormeggio premi **Apri comunque**. macOS chiede la password del Mac o Touch ID.
8. Nella finestra che compare premi di nuovo **Apri comunque**.

Il pulsante **Apri comunque** compare solo per un po' dopo il blocco. Se non lo trovi, apri di nuovo Ormeggio da Applicazioni e torna subito in Privacy e sicurezza. Se ancora non c'è, vedi [Se macOS non apre Ormeggio](#se-macos-non-apre-ormeggio).

### Primo avvio

1. Si apre il **benvenuto** di Ormeggio. La casella "Avvia Ormeggio quando accendi il Mac" è già spuntata: lasciala così se vuoi che parta da solo. Premi **Continua**.
2. Si apre Impostazioni di Sistema su **Accessibilità**. È il permesso che serve per spostare le finestre, e macOS lo fa dare solo a te: accendi l'interruttore accanto a **Ormeggio**.
3. Se Ormeggio non è nell'elenco, premi **+** in fondo all'elenco, scegli **Ormeggio** nella cartella Applicazioni, premi **Apri** e accendi l'interruttore.
4. Quando il permesso è attivo, un riquadro in basso dice "Permesso attivo". L'icona di Ormeggio è nella barra in alto, vicino all'orologio.

macOS può chiedere altri due permessi, la prima volta che servono:

- **Notifiche**: premi **Consenti**. Servono per avvisarti quando arriva una versione nuova.
- **Controllo di Chrome, Safari o del Finder**, quando salvi una scena con quelle app aperte: premi **OK**. Serve per ritrovare schede e cartelle. Ormeggio non legge il contenuto delle pagine e non tocca i tuoi file.

## Usare

Il menu di Ormeggio, dall'icona nella barra in alto, ha cinque voci:

- **Vedi le scene…**: tutte le tue scene, per richiamarle, rinominarle, cambiare icona, eliminarle.
- **Salva scena…**: sistema le finestre come ti servono e dai un nome. Puoi chiedere che la scena parta da sola quando ricolleghi gli stessi monitor.
- **Richiama scena**: clic sul nome della scena. Quella in uso ha il segno di spunta.
- **Aggiornamenti**: controlla subito se c'è una versione nuova.
- **Segnalazioni**: prepara un file con la diagnostica, quando qualcosa non va.

Sotto ci sono **Impostazioni** ed **Esci**.

Il richiamo di solito dura un secondo o due: rimette monitor, posizioni, misure e finestre dal Dock. Se qualche finestra è su una scrivania diversa da quella della scena, il riquadro alla fine propone **Sposta ogni finestra sulla sua scrivania**: ci vuole qualche secondo e in quel tempo non bisogna toccare mouse e tastiera.

### Zoom

Lo zoom di Chrome Ormeggio lo salva da solo, sito per sito e profilo per profilo, e lo rimette quando richiami la scena. Serve soprattutto quando cambi monitor con una risoluzione diversa. In Chrome lo zoom vale per tutto il sito: se nessuna scheda di quel sito è in vista, Ormeggio apre per un attimo una scheda del sito, rimette lo zoom e la richiude. Per le altre app (per esempio Slack): **Vedi le scene…** > menu della scena > **Zoom delle app…**.

### Aggiornamenti

Ormeggio controlla ogni mezz'ora se c'è una versione nuova e la installa da solo: si chiude, si aggiorna e si riapre, e le scene restano. Subito dopo arriva una notifica con le novità. Le novità si rileggono in **Impostazioni** > **Novità dell'ultima versione**.

### Disinstallare

Icona di Ormeggio > **Impostazioni** > **Disinstalla Ormeggio…**. Toglie l'avvio all'accensione, le scene salvate e i permessi, e sposta l'app nel Cestino.

## Se qualcosa non va

| Cosa vedi | Cosa fare |
| --- | --- |
| "Ormeggio non è stata aperta" e in Privacy e sicurezza non c'è "Apri comunque" | Vedi [Se macOS non apre Ormeggio](#se-macos-non-apre-ormeggio). |
| "Ormeggio è danneggiato e non può essere aperto" | È lo stesso blocco di macOS, con un altro messaggio. Vedi [Se macOS non apre Ormeggio](#se-macos-non-apre-ormeggio). |
| Ormeggio non è nell'elenco di Accessibilità | Premi **+** in fondo all'elenco, scegli Ormeggio in Applicazioni e premi Apri. |
| L'interruttore è acceso, ma Ormeggio dice che manca il permesso | Icona di Ormeggio > **Ripara il permesso di Accessibilità…**, poi riaccendi l'interruttore. |
| Non vedo l'icona nella barra in alto | Sui Mac con la tacca nello schermo le icone di troppo finiscono dietro la tacca. Chiudi qualche altra app della barra, oppure riapri Ormeggio da Applicazioni. |
| Il riquadro dice di non toccare mouse e tastiera | Ormeggio sta spostando le finestre: aspetta qualche secondo che finisca. |
| Una finestra non torna al suo posto | Richiama di nuovo la scena. Se succede sempre, prepara una segnalazione. |

### Se macOS non apre Ormeggio

Su alcuni Mac, soprattutto quelli gestiti da un'azienda, "Apri comunque" non c'è o non funziona. In quel caso Ormeggio si installa con una riga nel Terminale, l'app del Mac per dare comandi scritti. Se non l'hai mai usato non preoccuparti: è una sola riga da copiare e incollare. Oppure chiedi a qualcuno pratico di farlo con te.

1. Apri il **Terminale**: premi cmd + spazio, scrivi "Terminale" e premi Invio. Si apre una finestra con del testo.
2. Copia questa riga (c'è il pulsante per copiarla a destra), incollala nella finestra del Terminale e premi Invio:

```sh
curl -fsSL https://raw.githubusercontent.com/mauro-amara/ormeggio/main/install.sh | sh
```

3. In pochi secondi compaiono tre righe, l'ultima dice "Fatto". Ormeggio si apre da solo: continua da [Primo avvio](#primo-avvio). Il Terminale puoi chiuderlo.

Non serve aver trascinato Ormeggio in Applicazioni: questa riga lo scarica e lo mette lì al posto tuo. Non chiede la password e non tocca nient'altro sul Mac. Prima di installare controlla che il file sia identico a quello pubblicato, che dentro ci sia proprio Ormeggio e che la firma sia intatta: se un controllo non passa, si ferma. Il programma che esegue è [install.sh](install.sh), in questo repository.

### Segnalare un problema

[Apri una segnalazione](https://github.com/mauro-amara/ormeggio/issues/new) e racconta cosa è successo: cosa hai fatto, cosa ti aspettavi, cosa hai visto. Serve un account GitHub, gratuito. La pagina è pubblica: **non allegare** il file che prepara "Segnalazioni", perché contiene i titoli delle tue finestre. Se servirà, ti verrà chiesto nella segnalazione come mandarlo.

## Privacy e sicurezza

- **Permessi.** Ormeggio usa l'Accessibilità per spostare le finestre e, se concessa, l'Automazione per leggere schede e cartelle. Non chiede altro: niente registrazione dello schermo, niente accesso ai file.
- **Dati.** Scene e registro stanno in `~/Library/Application Support/Ormeggio`, leggibili solo dalla persona. Non escono dal Mac. Nel registro ci sono i titoli delle finestre e i nomi dei siti, mai gli indirizzi completi delle schede.
- **Aggiornamenti.** Si scaricano solo da questo repository, in HTTPS. Prima di installare, Ormeggio controlla che il file sia identico a quello pubblicato (impronta SHA-256), che contenga proprio Ormeggio nella versione annunciata e che la firma sia intatta. Se un controllo non passa, l'aggiornamento non si installa. La compilazione usa solo git e gli strumenti di Apple, senza azioni di terzi, e fa gli stessi controlli prima di pubblicare.
- **Limite noto.** L'app è firmata localmente, non con un certificato Developer ID di Apple. La sicurezza degli aggiornamenti dipende quindi dall'account GitHub che pubblica. Il passo successivo è firmare e certificare l'app con un account sviluppatore Apple: da lì si apre senza avvisi.
- **Segnalazioni.** Niente parte da solo: "Segnalazioni" crea un file sul Mac, e decidi tu se e a chi mandarlo. Nell'app non c'è nessuna chiave o password, e nessun dato viene raccolto.

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
- **Firma.** Senza un certificato Developer ID l'app è firmata solo localmente e macOS la blocca alla prima apertura: vedi [Installare](#installare).

## Per chi sviluppa

Il DMG si crea su un Mac con:

```
bash scripts/build-app.sh
bash scripts/make-dmg.sh
```

A ogni push su `main`, GitHub Actions (`.github/workflows/build.yml`) compila su un Mac in cloud, allega il DMG all'esecuzione e lo pubblica con il registro di compilazione nel ramo `builds`.

Per firmare con Developer ID imposta la variabile `SIGN_IDENTITY` prima di `build-app.sh`; la notarizzazione va aggiunta al workflow con le credenziali di un account Apple Developer.

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
