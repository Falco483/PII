# Miglioramento Robustezza Navigazione e Ottimizzazione (Task 5+)

Grazie per l'ottimo feedback! Hai evidenziato aspetti cruciali che fanno la differenza tra un prototipo e un'applicazione *production-ready*. Di seguito sono descritte le motivazioni (perché) e le strategie (cosa fare) per affrontare ogni suggerimento sul progetto.

## Analisi e Risposte ai Suggerimenti

### 1. Gestione Fallimenti API e Signal Loss (Network & GPS)
**Perché intervenire:** In movimento, l'utente passerà in zone senza copertura o tunnel (signal loss). Le API Google potrebbero fallire temporaneamente o superare i limiti di quota, restituendo errori che farebbero crashare la navigazione se non gestiti.
**Cosa fare:**
- **Network Resilience:** Avvolgere le chiamate HTTP (es. Google Directions API) in blocchi `try-catch`, implementando un **Exponential Backoff**. Se la chiamata fallisce, si ritenta dopo 1s, poi 2s, poi 4s, fino a un massimo impostato. In caso di limite superato (HTTP 429), segnalarlo visivamente all'utente.
- **GPS Signal Loss:** Utilizzare i callback/stream di posizione filtrando la precisione. Mostrare un banner UI ("Ricerca segnale GPS...") se i dati non vengono ricevuti per oltre un tot di secondi o se l'accuratezza decade eccessivamente.

### 2. Adaptive Polling (Task 5)
**Perché intervenire:** Campionare il GPS ogni 2 secondi senza condizioni prosciuga incredibilmente in fretta la batteria dello smartphone e spinge la CPU a eseguire match-logic inutili per chi è in coda nel traffico.
**Cosa fare:**
- Sfruttare la proprietà `speed` del dato GPS (oppure calcolare la distanza sul tempo). 
- **Adattamento dinamico:** Se la velocità scende sotto i 15 km/h o il veicolo si ferma, dilatiamo il campionamento (es. richiedendo aggiornamenti ogni 5-10 secondi, oppure implementando i `distanceFilter` nativi che aggiornano la posizione solo ad avvenuti spostamenti sensibili). Se si è ad alte velocità (es > 60 km/h), i 2 secondi rimangono fondamentali per non mancare uscite autostradali.

### 3. Falsi Positivi sulla Deviazione (Signal Drift)
**Perché intervenire:** Un ricalcolo (fetch APIs + UI redraw) causato da una fluttuazione temporanea del GPS (Signal Drift: estremamente frequente in contesti urbani densi) causerà "glitch" e sprechi di richieste di rete, mandando in tilt l'esperienza utente.
**Cosa fare:**
- **Confidence Level Filter:** Se l'accuratezza del punto GPS indicata dal sistema (`Position.accuracy`) è scarsa (es > 30m), ignoriamo il punto ai fini della distanza dalla Route ed evitiamo il ricalcolo a prescindere.
- **Double/Triple Sampling Verification:** Implemetiamo un sistema di conteggio ("Strikes"). La prima volta che la distanza misurata è `> 40 metri`, incrementiamo il contatore in background senza alterare il viaggio. Se al controllo GPS successivo il veicolo è _ancora_ fuori dalla rotta di `> 40 metri`, dichiariamo ufficialmente la Deviazione e attiviamo il Ricalcolo (altrimenti azzeriamo il contatore).

### 4. State Synchronization e Memory Leaks (Gestione Polylines)
**Perché intervenire:** Le collezioni di oggetti interattivi in memoria (come le `Polyline` sulla mappa) non vengono ripulite automaticamente se ne stanziamo continuamente di nuove. Ripetuti ricalcoli creeranno "layer fantasma" che assorbono risorse e finiscono presto per causare dei collassi RAM e *Memory Leaks*.
**Cosa fare:**
- Nel varare l'azione di ricalcolo nello State Manager (Provider o BLoC che sia), dichiareremo esplicitamente lo stato di ricalcolo in corso.
- Eseguiremo preventivamente una distruzione delle vecchie risorse grafiche chiamando inequivocabilmente `.clear()` sulla collezione/lista delle `Polyline` prima di aggiornare l'UI.
- Il nuovo layer per la rotta verrà iniettato subito dopo il completamento asincrono della chiamata HTTP, permettendo al Framework Flutter di effettuare un sano Garbage Collection sui vecchi oggetti scartati per evitare sovrapposizioni.

---

## User Review Required

Nessun elemento stravolge e altera radicalmente l'architettura che abbiamo stilato in precedenza, ma prima di modificare i file richiedo un tuo parere sulle seguenti condizioni che intendo adottare:
- **Polling dinamico:** Scalare ai poll di 5-10 secondi sotto la soglia di comodità impostata a 15-20 km/h?
- **Sampling Deviazione:** Procedo con il check a due campioni (cioè la conferma di fuori rotta avviene sempre alla **seconda lettura** sballata) o preferisci uno scaling sulle 3 letture prima di ritracciare?

## Proposed Changes

### Logic & API Layers
#### [MODIFY] `lib/services/location_service.dart` (o logica Location)
- Applicazione filtri di distanza o frequenza sul controller GPS basato sulla `speed` attuale per mitigazione consumi.

#### [MODIFY] `lib/services/api_service.dart` (o gestore API Maps/Roads)
- Refactoring chiamate HTTP con blocchi Try-Catch per gli errori (`SocketException`, `HttpException`), e aggiunta ritrasmissione ad iterazioni incrementali (Exponential Backoff).

### Business Logic Ricalcolo 
#### [MODIFY] [lib/screens/navigation_screen.dart](file:///c:/Users/Antonio/Desktop/pii2/lib/screens/navigation_screen.dart) (o Gestione di Stato/RouteProvider per Navigazione)
- **Signal Drift:** Aggiunta validazione `if (position.accuracy > 30) return;` nella callback di deviazione.
- **Strikes:** Introduzione contatore consecutivo `int _consecutiveOffRouteDetects = 0;`. Se esso supera un limite imposto (es. `>= 2`), scatta il Ricalcolo e la chiamata alla API Google Directions.

### UI & Polylines Sync
#### [MODIFY] [lib/widgets/map_widget.dart](file:///c:/Users/Antonio/Desktop/pii2/lib/widgets/map_widget.dart) e relativo Provider
- Sincronizzazione dell'evento Ricalcolo con `polylines.clear(); notifyListeners();` preventivi su avvio task. 

## Verification Plan
1. Eseguire test di Profiling App/Memoria (via Flutter DevTools) per confermare l'effettivo smaltimento (GC) degli oggetti Polyline eliminati ad ogni richiesta successiva alla seconda iterazione.
2. Controllare attraverso Logging via console che l'evento switch del timer di ricezione (Adaptive Polling) operi fedelmente abbassandosi sulle soglie definite sotto i limiti dei classici spostamenti pedonali/incolonnati.
3. Simulatori attivati per convalidare perdite del segnale internet o disconnessioni fisiche per testare il fallback a schermo dei Retry.
