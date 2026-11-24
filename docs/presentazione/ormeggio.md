---
progetto: Ormeggio
evento: Presentazione interna
luogo: SparkFabrik
data: Novembre 2026
autore: Mauro
ruolo: PMO & Delivery Manager
sito: github.com/mauro-amara/ormeggio
durata: 10
lang: it
tipo: tecnico
---

<!-- slide: talk -->

# Ormeggio

Ogni finestra al suo posto, con un clic.

logo: ormeggio-icona.png

???
Ormeggio è un'app per la barra dei menu del Mac. L'ho fatta per un problema che ho tutti i giorni, e credo di non essere l'unico.

<!-- slide: statement -->

# Ogni volta che stacchi il Mac **la scrivania va rifatta.**

Finestre, scrivanie e zoom tornano a posto solo a mano, una cosa alla volta.

???
La mia giornata: in ufficio il Mac è attaccato a un monitor Dell, a casa a un altro monitor, in riunione resta da solo. A ogni cambio rimetto in ordine tutto.

<!-- slide: rows -->

## Il problema

## Cambiare monitor vuol dire risistemare tutto, più volte al giorno.

- **Stacchi il Mac**: tutte le finestre finiscono ammucchiate sullo schermo del portatile.
- **Lo riattacchi**: spesso le finestre non tornano sul monitor e sulla scrivania dove stavano.
- **Scrivanie**: quelle del monitor esterno vanno ricreate e riempite di nuovo.
- **Risoluzione e zoom**: il testo è troppo piccolo o troppo grande, e si sistema app per app.
- **Browser**: profili di Chrome, finestre e schede si mescolano.

???
Ogni passaggio da solo è semplice, ma li ripeto tutti a ogni cambio di postazione, anche più volte al giorno.

<!-- slide: figures -->

## Una postazione vera

## Tre configurazioni da ricordare.

- 3 | configurazioni: ufficio con monitor esterno, monitor di casa, Mac da solo | requisiti iniziali del progetto
- 7 | scrivanie in ufficio: 5 sul monitor esterno e 2 sul Mac | diagnostica di Ormeggio
- 5 | profili di Chrome, ognuno con le sue finestre e il suo zoom | diagnostica di Ormeggio

???
Sulla mia postazione ogni configurazione ha una disposizione diversa, quindi a ogni cambio ricostruisco scrivanie, finestre e zoom.

<!-- slide: rows -->

## Le alternative

## Gli strumenti che esistono fanno un pezzo ciascuno.

- **Stay**: ricorda le finestre per monitor, ma non ricrea le scrivanie e non tocca lo zoom.
- **Hammerspoon**: può fare quasi tutto, con script in Lua da scrivere e mantenere.
- **Rectangle, Magnet**: affiancano le finestre con una scorciatoia, senza ricordare niente.
- **Mission Control**: gestisce le scrivanie, ma non sa quali app ci vanno.

???
Ho provato Stay: dopo aver tolto una scrivania, non l'ha ricreata. Hammerspoon funziona, ma chiede un file di configurazione da programmare, e non è uno strumento per tutti.

<!-- slide: process -->

## Come funziona

## Ti sistemi una volta, poi richiami con un clic.

### Sistema il Mac | una volta

Apri le app, mettile su monitor e scrivanie e regola lo zoom.

### Salva la scena | un clic

Le dai un nome: Ufficio, Casa, Mac da solo.

### Richiamala | quando vuoi

Dall'ancora nella barra dei menu, o da sola quando ricolleghi gli stessi monitor.

???
L'idea è la scena, una fotografia del Mac come lo voglio, salvata con un nome senza file di configurazione da scrivere.

<!-- slide: boxes -->

## Cosa ricorda una scena

## Tutto quello che rifaresti a mano.

### Finestre

glifo: design

Monitor, scrivania, posizione e dimensione, anche se ridotte nel Dock o a tutto schermo.

### Scrivanie e monitor

glifo: layers

Quante scrivanie ha ogni monitor e con quale risoluzione: Ormeggio le ricrea da Mission Control.

### App e browser

glifo: code

Apre le app chiuse, riapre le cartelle del Finder e le finestre di Chrome con le loro schede.

### Zoom

glifo: lens

Lo zoom di Chrome sito per sito, nel profilo giusto, e lo zoom delle altre app.

<!-- slide: flow -->

## Il richiamo

## Ormeggio rimette le cose in ordine, un livello alla volta.

### Monitor | risoluzione

### Scrivanie | numero

### App | apertura

### Finestre | posizione

### Zoom | per sito

???
Prima la risoluzione, perché cambia lo spazio disponibile. Poi le scrivanie, poi le app chiuse. Solo a quel punto sposta le finestre. Lo zoom per ultimo, perché richiede di mettere in primo piano la scheda giusta.

<!-- slide: content -->

## Il riepilogo

## Alla fine dice cosa ha fatto e cosa no.

- **Fatto**: finestre al loro posto, scrivanie aggiunte o tolte monitor per monitor, zoom rimessi.
- **Da sapere**: cosa non è tornato e perché, per esempio una riunione finita che non riapre.
- **Diagnostica**: un file con il registro di ogni passo, da mandare a chi mantiene l'app.

???
Il riepilogo compare in basso al centro dello schermo e sparisce da solo. Se qualcosa non torna, la diagnostica dice esattamente dove si è fermato.

<!-- slide: columns -->

## Installazione

## Si installa da un DMG e si aggiorna da sola.

### Installa

glifo: rocket

Un DMG da trascinare in Applicazioni. Alla prima apertura chiede il permesso di Accessibilità.

### Aggiorna

glifo: ci-cd-steps

Quando esce una versione nuova l'ancora mostra un punto: un clic e l'app si aggiorna, le scene restano.

### Disinstalla

glifo: managed

Dal menu dell'app: toglie anche scene, preferenze e permessi.

???
Ogni modifica al codice passa da GitHub Actions su un Mac, che compila l'app e pubblica il DMG, e l'app controlla ogni sei ore se c'è una versione nuova.

<!-- slide: rows -->

## Limiti noti

## Cosa manca per usarla in tutto il team.

- **Firma**: senza un certificato Apple Developer, macOS avvisa alla prima apertura e può chiedere di riattivare i permessi.
- **Mission Control**: per aggiungere o togliere scrivanie Ormeggio usa mouse e tastiera per qualche secondo.
- **Funzioni private**: un aggiornamento di macOS può cambiarne alcune.
- **Zoom delle app**: funziona dove l'app ha i comandi di zoom nel menu.
- **Prove**: finora su un Mac solo, con macOS Tahoe 26.

???
Sono limiti dichiarati: preferisco dirli prima che qualcuno li scopra.

<!-- slide: columns -->

## Prossimi passi

## Tre decisioni per portarla al team.

### Firma

glifo: security

Un account Apple Developer di SparkFabrik per firmare e notarizzare l'app, senza avvisi di macOS.

### Repository

glifo: code

Il codice nell'organizzazione SparkFabrik, con una persona che lo mantiene.

### Prova

glifo: team

Qualche collega con postazioni diverse la usa e manda la diagnostica.

<!-- slide: resources -->

## Risorse

## Codice, installazione e istruzioni.

- **Il codice**: github.com/mauro-amara/ormeggio
- **Il README**: installazione, uso, aggiornamenti e limiti
- **L'ultima versione**: dal menu dell'app, alla voce Cerca aggiornamenti

<!-- slide: closing -->

# Grazie.

github.com/mauro-amara/ormeggio
