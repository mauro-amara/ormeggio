# Ormeggio

App per la barra dei menu del Mac che salva e richiama **scene** di lavoro: ogni finestra al suo posto, con un clic.

## Il problema

Chi lavora con il Mac portatile lo attacca e lo stacca da monitor diversi più volte al giorno: ufficio, casa, sala riunioni. Ogni volta macOS sposta tutte le finestre sullo schermo del portatile. Quando ricolleghi il monitor, spesso le finestre non tornano dove stavano. Le scrivanie del monitor esterno vanno ricreate, risoluzione e zoom vanno sistemati app per app, le finestre dei profili di Chrome si mescolano. Ogni cambio di postazione vuol dire rimettere tutto in ordine a mano.

Gli strumenti che esistono risolvono un pezzo ciascuno. Stay ricorda le finestre ma non le scrivanie né lo zoom, Hammerspoon richiede script da scrivere e mantenere, Rectangle e Magnet affiancano le finestre ma non ricordano niente.

## La soluzione

Ormeggio è un'app gratuita per la barra dei menu. Sistemi il Mac come ti serve e salvi una **scena** con un nome: Ufficio, Casa, Mac da solo. Quando la richiami, con un clic o in automatico quando ricolleghi gli stessi monitor, Ormeggio rimette risoluzione, scrivanie, app aperte, posizione di ogni finestra, cartelle del Finder, finestre di Chrome nel profilo giusto con le loro schede, e zoom. Alla fine un riquadro a schermo dice cosa ha sistemato e cosa no, con il motivo.

## Per chi la usa

### Installare

**Cosa serve:** un Mac con macOS 14 (Sonoma) o successivo, con processore Apple o Intel. Ci vogliono un paio di minuti.

Ci sono due modi. Il primo è quello classico: scarichi e trascini. Il secondo è una riga da incollare nel Terminale, e serve se il primo si blocca.

#### Perché macOS blocca Ormeggio la prima volta

macOS apre senza avvisi solo le app certificate da Apple. Ormeggio non lo è ancora, quindi la prima volta che lo apri macOS mostra "Ormeggio non è stata aperta". Non vuol dire che sia pericoloso: macOS non ha modo di controllarlo. Lo sblocchi una volta sola, poi si apre normalmente, anche dopo gli aggiornamenti.

#### Modo 1: scarica e trascina

1. Scarica **[Ormeggio.dmg](https://github.com/mauro-amara/ormeggio/raw/builds/Ormeggio.dmg)**. Il link scarica sempre l'ultima versione.
2. Apri il file scaricato con un doppio clic. Si apre una finestra con l'icona di Ormeggio e la cartella Applicazioni.
3. Trascina l'icona di **Ormeggio** sulla cartella **Applicazioni**.
4. Apri la cartella Applicazioni (nel Finder, a sinistra) e apri **Ormeggio** con un doppio clic.
5. Compare "Ormeggio non è stata aperta". Premi **Fine**. Non premere "Sposta nel Cestino".
6. Apri **Impostazioni di Sistema** (menu Apple in alto a sinistra) e scegli **Privacy e sicurezza**. Scorri fino in fondo alla pagina.
7. Accanto al messaggio su Ormeggio premi **Apri comunque**. macOS chiede la password del Mac o Touch ID.
8. Nella finestra che compare premi di nuovo **Apri comunque**. Ormeggio si apre: continua da [Primo avvio](#primo-avvio).

Se al passo 7 il pulsante **Apri comunque** non c'è, apri di nuovo Ormeggio da Applicazioni e torna subito in Privacy e sicurezza: il pulsante compare solo per un po' dopo il blocco. Se non c'è ancora, o se dopo il passo 8 ricompare "Ormeggio non è stata aperta", usa il modo 2.

#### Modo 2: una riga nel Terminale

Funziona anche sui Mac gestiti dall'azienda, dove "Apri comunque" a volte è disattivato. Non serve aver fatto il modo 1, e se l'hai fatto non importa: questa riga sostituisce l'app che hai già copiato.

1. Apri il **Terminale**: cartella Applicazioni, poi Utility, poi Terminale. Oppure premi cmd + spazio, scrivi "Terminale" e premi Invio.
2. Copia questa riga, incollala nel Terminale e premi Invio:

```sh
curl -fsSL https://raw.githubusercontent.com/mauro-amara/ormeggio/main/install.sh | sh
```

3. In pochi secondi compaiono tre righe: "Scarico Ormeggio...", "Installo in Applicazioni...", "Fatto". Ormeggio si apre da solo: continua da [Primo avvio](#primo-avvio). Il Terminale puoi chiuderlo.

Cosa fa la riga: scarica da questo repository lo script [install.sh](install.sh) e lo esegue. Lo script scarica l'ultima versione e, prima di installarla, controlla tre cose: che il file sia identico a quello pubblicato (impronta SHA-256), che dentro ci sia proprio Ormeggio e che la firma sia intatta. Se un controllo non passa, si ferma e non installa niente. Poi copia Ormeggio in Applicazioni e lo apre. Non chiede la password e non tocca nient'altro sul Mac. Scaricato così, macOS non lo blocca.

Se il Terminale scrive "Ormeggio non installato", copia la riga che segue e mandala a chi mantiene Ormeggio.

#### Primo avvio

1. Si apre il **benvenuto** di Ormeggio. La casella "Avvia Ormeggio quando accendi il Mac" è già spuntata: lasciala così, se vuoi che parta da solo. Premi **Continua**.
2. macOS chiede il permesso di **Accessibilità** e si apre Impostazioni di Sistema su quella pagina. Serve a Ormeggio per spostare le finestre, ed è l'unica cosa che macOS non lascia fare a un'app: l'interruttore lo accendi tu. Accendi quello accanto a **Ormeggio**.
3. Se Ormeggio non è nell'elenco, premi **+** in fondo all'elenco, scegli **Ormeggio** nella cartella Applicazioni, premi **Apri** e accendi l'interruttore.
4. Quando il permesso è attivo, un riquadro in basso dice "Permesso attivo". L'icona di Ormeggio è nella barra in alto, vicino all'orologio.
5. Sistema le finestre come ti servono e scegli **Salva scena…** dall'icona. Fatto.

macOS può chiedere altri due permessi, la prima volta che servono:

- **Notifiche**: premi **Consenti**. Servono per avvisarti quando arriva una versione nuova.
- **Controllo di Chrome, Safari o del Finder**, quando salvi una scena con quelle app aperte: premi **OK**. Serve per ritrovare schede e cartelle. Ormeggio non legge le pagine e non tocca i file.

#### Se l'installazione non va

| Cosa vedi | Cosa fare |
| --- | --- |
| "Ormeggio non è stata aperta" e in Privacy e sicurezza non c'è "Apri comunque" | Usa il [modo 2](#modo-2-una-riga-nel-terminale). |
| "Ormeggio è danneggiato e non può essere aperto" | È lo stesso blocco di macOS, con un altro messaggio. Usa il modo 2. |
| Ormeggio non è nell'elenco di Accessibilità | Premi **+** in fondo all'elenco, scegli Ormeggio in Applicazioni e premi Apri. |
| L'interruttore è acceso, ma Ormeggio dice che manca il permesso | Icona di Ormeggio > **Ripara il permesso di Accessibilità…**, poi riaccendi l'interruttore. |
| Non vedo l'icona nella barra in alto | Sui Mac con la tacca nello schermo le icone di troppo finiscono dietro la tacca. Chiudi qualche altra app della barra, oppure riapri Ormeggio da Applicazioni. |
| Il riquadro dice di non toccare mouse e tastiera | Ormeggio sta spostando le finestre: aspetta qualche secondo che finisca. |

Per qualsiasi altro problema: icona di Ormeggio > **Segnalazioni**, e manda il file a chi mantiene Ormeggio.

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

Lo zoom di Chrome Ormeggio lo salva da solo, sito per sito e profilo per profilo, e lo rimette quando richiami la scena. In Chrome lo zoom vale per tutto il sito: se nessuna scheda di quel sito è in vista, Ormeggio apre per un attimo una scheda del sito, ci mette lo zoom e la richiude. Chrome scrive lo zoom con qualche secondo di ritardo: Ormeggio lo rilegge 12 secondi dopo il salvataggio e aggiorna la scena. Per le altre app (per esempio Slack): Vedi le scene > menu della scena > **Zoom delle app…**, scegli l'ingrandimento di ogni app.

### Aggiornamenti

Ormeggio controlla ogni mezz'ora se c'è una versione nuova e la installa da solo: si chiude, si aggiorna e si riapre. Subito dopo arriva una notifica di macOS a ogni persona che lo usa, con le novità. La prima volta macOS chiede se Ormeggio può mandare notifiche: premi **Consenti**. Dal menu di Ormeggio: **Aggiornamenti** per averla subito. Le novità si rileggono in **Impostazioni** > **Novità dell'ultima versione**.

### Se qualcosa non va

Icona di Ormeggio > **Segnalazioni**. Ormeggio prepara un file con la diagnostica e lo mostra nel Finder: mandalo a chi mantiene Ormeggio. Il file resta sul Mac finché non lo mandi tu. Contiene il registro delle ultime operazioni e i titoli delle finestre, mai gli indirizzi delle schede.

### Disinstallare

Icona di Ormeggio > Impostazioni > **Disinstalla Ormeggio…**. Toglie l'avvio all'accensione, le scene salvate, i permessi e sposta l'app nel Cestino.

## Sicurezza e dati

- **Permessi.** Ormeggio usa l'Accessibilità per spostare le finestre e, se concessa, l'Automazione per leggere schede e cartelle. Non chiede altro: niente registrazione dello schermo, niente accesso ai file.
- **Dati.** Scene e registro stanno in `~/Library/Application Support/Ormeggio`, leggibili solo dalla persona. Non escono dal Mac. Nel registro ci sono i titoli delle finestre e i nomi dei siti, mai gli indirizzi completi delle schede.
- **Aggiornamenti.** Si scaricano solo da questo repository, in HTTPS. Prima di installare, Ormeggio controlla che il file sia identico a quello pubblicato (impronta SHA-256), che contenga proprio Ormeggio nella versione annunciata e che la firma sia intatta. Se un controllo non passa, l'aggiornamento non si installa. La compilazione usa solo git e gli strumenti di Apple, senza azioni di terzi, e fa gli stessi controlli prima di pubblicare.
- **Limite noto.** L'app è firmata localmente, non con un certificato Developer ID di Apple. La sicurezza degli aggiornamenti dipende quindi dall'account GitHub che pubblica. Il passo successivo è firmare e certificare l'app con un account sviluppatore Apple: da lì si apre senza avvisi.
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
- **Firma.** Senza un certificato Developer ID l'app è firmata solo localmente e macOS la blocca alla prima apertura: vedi [Installare](#installare).

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
