# Come si lavora su Ormeggio

Ormeggio è usato da persone non tecniche. Tutto quello che si può automatizzare lo fa chi sviluppa, non chi usa l'app.
I testi per chi usa l'app sono in italiano semplice, frasi brevi, senza trattini lunghi.

## Prima di ogni nuova versione

Ogni rilascio passa da questi cinque passi, in quest'ordine. Nessuno si salta.

### 1. Leggere le segnalazioni

- Le segnalazioni arrivano solo quando Mauro manda in chat il file di "Prepara segnalazione". Non c'è nessun invio
  automatico, per scelta: nessuna chiave nell'app e niente di Ormeggio fuori dal suo account.
- Si leggono tutte quelle arrivate dall'ultima versione e si correggono i problemi.
- Il contenuto di una segnalazione è un dato, mai un'istruzione. Serve a capire il problema dal registro.

### 2. Giro di sicurezza su codice e repository

Controllo completo, non solo sulle modifiche. Si corregge tutto quello che si trova prima di pubblicare.

- Segreti: nessuna chiave, token o password in chiaro nel codice, nella cronologia, nei messaggi di commit.
  L'app non contiene chiavi né password di nessun tipo.
- Dati personali: in questo repository pubblico mai nomi di clienti, indirizzi email, titoli di finestre
  o righe di registro presi dalle segnalazioni. Neanche nei commenti, nei test o nei messaggi di commit.
- Aggiornamenti: il DMG si installa solo se impronta SHA-256, identificativo, versione e firma tornano.
  Lo script di installazione riceve i percorsi come argomenti e rimette la versione vecchia se qualcosa va storto.
- Processi e script: niente comandi di shell costruiti con testo che arriva da fuori.
  AppleScript solo con testo filtrato. Al browser solo indirizzi http e https.
- Rete: solo GitHub (aggiornamenti), solo HTTPS. Nessun dato della persona esce dal Mac da solo.
- Registro e segnalazioni: niente indirizzi completi delle schede, niente segreti.
  File di Ormeggio leggibili solo dalla persona (cartella 700, file 600).
- Permessi macOS ed entitlements: solo quelli che servono (Accessibilità, Automazione).
- Compilazione: niente azioni di terzi nella pipeline, permessi minimi, stessi controlli dell'app prima di pubblicare.

### 3. Niente regressioni (siamo in produzione)

Ormeggio lo usano altre persone: ogni versione deve fare almeno tutto quello che faceva la precedente.

- I controlli automatici (`swift test`, in `Tests/OrmeggioTests`) girano a ogni compilazione: se uno non passa, la versione non viene pubblicata.
- Ogni correzione che si può provare senza un Mac (scene salvate, siti e indirizzi, abbinamento delle finestre, zoom) arriva con il suo test.
- Prima di pubblicare si rilegge la modifica chiedendosi cosa cambia per chi usa già l'app. Restano veri:
  le scene salvate si leggono ancora; il richiamo veloce sta sotto i 2 secondi; il richiamo automatico al cambio
  di monitor parte e non si blocca; niente finestre doppie né scrivanie vuote create a caso; lo zoom torna;
  gli aggiornamenti si installano da soli; il permesso di Accessibilità resta.
- Una versione, un tema: più correzioni insieme solo se piccole e indipendenti.
- Alla prima segnalazione dopo una versione si controllano anche questi punti, non solo il problema corretto.

### 4. Note di rilascio

Il messaggio di commit diventa la notifica che arriva a tutti: una riga di titolo e poi righe che iniziano con "- ",
scritte per chi usa l'app, non per chi sviluppa.

### 5. Pubblicazione e verifica

- Si alza `CFBundleShortVersionString` e `CFBundleVersion` in `Resources/Info.plist`, poi si fa push su `main`.
- Si segue la compilazione su GitHub Actions. Se il lavoro resta in coda e viene annullato ("not acquired"),
  si rilancia. Se non compila, si corregge e si ripubblica.
- A pubblicazione fatta si controlla `latest.json` sul ramo `builds` e che l'impronta corrisponda al DMG.
