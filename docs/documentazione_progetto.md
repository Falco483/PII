# Documentazione di Progetto: Smart Navigation App

## 1. Introduzione

**Titolo del Progetto:** Smart Navigation App
**Sviluppato da:** Antonio
**Durata del Progetto:** [Inserire durata, es. 3 mesi - Da Marzo 2026 a Maggio 2026]

**Contesto e Motivazione**
L'evoluzione dei dispositivi mobili ha trasformato radicalmente il modo in cui le persone navigano negli spazi urbani ed extraurbani. Le applicazioni di navigazione GPS (Global Positioning System) sono diventate strumenti indispensabili nella vita quotidiana. Tuttavia, nonostante la presenza di giganti tecnologici nel settore, esistono ancora margini di miglioramento significativi per quanto riguarda la reattività del software, l'ottimizzazione del carico cognitivo dell'utente durante gli spostamenti a piedi e la gestione fluida degli stati dell'interfaccia utente (UX).
La motivazione principale alla base di questo progetto è la progettazione e lo sviluppo di un'applicazione di navigazione mobile dedicata esclusivamente ai pedoni, creata da zero, che si concentri sull'efficienza computazionale dei ricalcoli e su un'interfaccia utente priva di distrazioni, implementando soluzioni architetturali moderne e performanti.

**Obiettivi del Progetto**
Gli obiettivi primari di "Smart Navigation App" sono:
1. Sviluppare un'applicazione cross-platform fluida per la navigazione passo-passo (turn-by-turn).
2. Implementare un algoritmo di ricalcolo del percorso ultra-rapido basato su criteri geometrici di deviazione.
3. Introdurre una funzionalità di consapevolezza contestuale (Lateral Road Detection) che informi l'utente dell'ambiente circostante senza sovraffollare la UI.
4. Realizzare un'architettura a singola schermata (Single-Screen) in grado di gestire in modo robusto la navigazione all'interno dell'app (back-stack) senza ricaricamenti pesanti delle viste della mappa.

**Contenuti del Documento**
Il presente elaborato è strutturato come segue: la Sezione 2 analizza lo stato dell'arte e i lavori correlati, confrontando l'app con le soluzioni commerciali esistenti; la Sezione 3 evidenzia i tratti innovativi del progetto; la Sezione 4, fulcro del documento, descrive in modo esaustivo lo sviluppo del progetto, le tecnologie, l'architettura e gli strumenti utilizzati; la Sezione 5 presenta i risultati ottenuti tramite test pratici ed elementi grafici; infine, la Sezione 6 riassume le conclusioni e i possibili sviluppi futuri.

---

## 2. Related Work (Lavori Correlati e Stato dell'Arte)

La ricerca nell'ambito dei Sistemi di Trasporto Intelligenti (ITS) e della navigazione assistita ha prodotto nel tempo algoritmi sempre più sofisticati per la ricerca del percorso minimo (es. algoritmi di Dijkstra e A* modificati per reti stradali e pedonali dinamiche). La letteratura accademica recente, consultabile tramite Google Scholar, evidenzia un interesse crescente non solo verso il "routing" puro, ma verso l'Interazione Uomo-Macchina (HCI) nel contesto della mobilità dolce: come presentare le informazioni spaziali in modo efficace, riducendo i tempi di reazione del pedone.

**Vista Comparativa con le Soluzioni di Mercato:**
Per posizionare correttamente il nostro progetto, è fondamentale confrontarlo con i leader di mercato:

*   **Google Maps:**
    *   *Punti di forza:* Database di Punti di Interesse (POI) impareggiabile, stime del traffico predittive estremamente accurate basate su big data.
    *   *Criticità:* L'applicazione è diventata nel tempo un "super-app" che include recensioni, social network e raccomandazioni. Questo appesantisce l'interfaccia, rendendola meno immediata se l'unico scopo è la navigazione pura. Inoltre, la segnalazione di strade laterali minori è spesso assente o subordinata alla visualizzazione di POI commerciali.
*   **Waze (di proprietà Google):**
    *   *Punti di forza:* Eccellente nel crowdsourcing in tempo reale (segnalazione di polizia, incidenti, pericoli). Molto aggressivo nel suggerire percorsi alternativi per far risparmiare tempo.
    *   *Criticità:* La UI risulta molto "giocattolosa" e densa di elementi grafici (pop-up, avatar degli altri utenti) che aumentano il carico cognitivo. I continui ricalcoli proposti possono generare confusione in percorsi urbani complessi.
*   **Apple Maps:**
    *   *Punti di forza:* Integrazione profonda con l'ecosistema iOS, grafica estremamente pulita e rendering vettoriale fluido.
    *   *Criticità:* Disponibilità limitata alle sole piattaforme Apple; minor flessibilità nelle opzioni di instradamento personalizzato rispetto ai concorrenti.

**Posizionamento del nostro Progetto:**
Rispetto a queste soluzioni, il nostro progetto si pone come un'applicazione "lean" (snella). Evita le distrazioni del crowdsourcing e dei POI commerciali, focalizzandosi su:
1. **Precisione reattiva:** Ricalcoli basati rigorosamente sulla distanza geometrica dal percorso previsto.
2. **Context Awareness misurata:** L'utente viene informato sui percorsi laterali solo in condizioni di sicurezza (es. pedone fermo), ottimizzando le richieste API.

---

## 3. Innovazione del Progetto

Il valore aggiunto e l'innovazione di questo progetto risiedono nell'implementazione di logiche di navigazione specifiche e nella gestione ottimizzata delle risorse del dispositivo.

1.  **Lateral Road Detection (Rilevamento Contesto Laterale) con Cooldown Logico:**
    A differenza dei navigatori tradizionali che mostrano ciecamente una mappa 2D/3D, la nostra applicazione percepisce attivamente l'ambiente circostante quando l'utente si ferma. L'innovazione sta nell'aver implementato un sistema di *cooldown* e di verifica di stato. L'app non effettua costantemente costose chiamate API per cercare vie laterali: la logica si attiva solo se la velocità scende a zero, se l'utente non si trova in prossimità di un punto di svolta critico (dove le indicazioni di rotta hanno priorità assoluta), e solo dopo un lasso di tempo stabilito per evitare lo spam di avvisi in caso di esitazioni durante il cammino.
2.  **Rilevamento di Deviazione Geometrico "Off-Route":**
    L'algoritmo di deviazione non si affida a un semplice "geofence" circolare attorno a un singolo punto, ma calcola attivamente la distanza proiettata ortogonalmente tra la coordinata GPS corrente e l'intero set di segmenti vettoriali (polyline) che compongono il percorso. Questo permette di distinguere immediatamente se l'utente sta percorrendo una strada parallela o se ha sbagliato una svolta, innescando il ricalcolo istantaneamente, ben prima che il sistema raggiunga i limiti di un'area di tolleranza generica.
3.  **UI/UX State Machine su Singola Schermata:**
    Invece di utilizzare il classico sistema di routing basato su "Pagine" (che richiederebbe di distruggere e ricreare il pesante widget della mappa Google a ogni transizione), l'app utilizza un `NavigationHistoryService` personalizzato. Questo servizio gestisce uno stack LIFO (Last-In-First-Out) degli stati dell'interfaccia (Ricerca, Anteprima, Navigazione). Il risultato è una transizione istantanea e senza sfarfallii, permettendo all'utente di annullare le azioni o tornare indietro intercettando in modo unificato i pulsanti fisici, le gesture di swipe e i bottoni dell'interfaccia.
4.  **Tracciamento delle Sessioni di Navigazione (Navigation Session History):**
    L'app integra un sistema di tracciamento persistente (`NavigationSessionService`) che registra i dati di ogni camminata (durata, distanza, percorso effettivo, deviazioni e avvisi ricevuti). Questo storico permette non solo una consultazione personale delle sessioni passate, ma funge anche da strumento di debug avanzato.

---

## 4. Sviluppo del Progetto

La fase di sviluppo ha richiesto una rigorosa pianificazione e l'adozione di un set di tecnologie moderne adatte a gestire flussi di dati asincroni (come lo stream del GPS) mantenendo a 60 frame al secondo le animazioni della mappa.

### 4.1. Metodologia e Strumenti Utilizzati

Il progetto è stato condotto seguendo principi di sviluppo Agile, procedendo per iterazioni successive (dalla visualizzazione della mappa, all'implementazione del routing, fino al raffinamento dell'UI).

**Piattaforma e Linguaggio:**
*   **Flutter (SDK di Google):** Scelto come framework UI toolkit per la sua capacità di generare applicazioni native e ad alte prestazioni per iOS e Android da un singolo codice sorgente. Il sistema di rendering di Flutter assicura che le transizioni sulla mappa e gli overlay siano renderizzati direttamente sulla GPU.
*   **Dart:** Il linguaggio di programmazione orientato agli oggetti utilizzato da Flutter. Dart è risultato fondamentale per la sua eccellente gestione della programmazione asincrona (Future e Stream), essenziale per consumare API RESTful e ascoltare i sensori del dispositivo senza bloccare il thread principale della UI.

**Integrazioni e Librerie Esterne (Dependencies):**
*   **Google Maps Platform:**
    *   *Maps SDK for Flutter (`google_maps_flutter`):* Per l'integrazione del widget mappa interattivo, la gestione della telecamera (inclinazione, zoom, bearing) e il rendering vettoriale di polilinee e marker.
    *   *Directions API:* Utilizzata tramite chiamate HTTP per calcolare il percorso ottimale, estrarre i punti di svolta (steps) e ottenere la polyline codificata.
    *   *Places API:* Per implementare l'autocompletamento della barra di ricerca, permettendo all'utente di inserire in linguaggio naturale la destinazione e ricavarne le coordinate spaziali precise.
*   **Localizzazione e Geometria:**
    *   `geolocator`: Una libreria fondamentale per gestire i permessi OS di localizzazione, accendere l'hardware GPS e ottenere uno stream continuo e configurabile di oggetti `Position` (contenenti latitudine, longitudine, velocità, accuratezza e direzione/heading).
    *   `flutter_polyline_points`: Per decodificare la stringa compressa fornita da Google Directions in un array di coordinate `LatLng` utilizzabili sulla mappa.

**Strumenti di Modellazione:**
*   **PlantUML e Diagrammi Architetturali:** Per definire la struttura del software in modo formale sono stati progettati diversi diagrammi (presenti nella cartella `documentazione finale`): un *Architecture Block Diagram* (per illustrare le interdipendenze tra i vari layer di UI, Services e Sensors), un *Entity-Relationship Diagram* (per delineare i modelli dati e le sessioni di navigazione), oltre a diagrammi di Sequenza, diagrammi di Stato (per modellare le state machine della UI) e diagrammi BPMN (per descrivere il flusso dei processi di navigazione).

### 4.2. Architettura del Sistema

L'applicazione segue un'architettura a strati che separa nettamente la logica di business dalla presentazione visiva (Layered Architecture).

**1. Data & Service Layer (Livello Dati e Servizi):**
Questo livello è responsabile delle comunicazioni esterne e del calcolo pesante.
*   `RoadsService` e `DirectionsService`: Classi incaricate di formattare ed eseguire le chiamate HTTP (REST) alle API di Google, parsare le risposte JSON e restituire oggetti di dominio fortemente tipizzati (es. `RouteData`, `SnappedPoint`).
*   `NavigationHistoryService`: Implementa lo stack degli stati visivi. Tiene traccia di dove si trova l'utente nell'applicazione (es. se è nella vista di ricerca o nella vista di navigazione attiva) permettendo un "ritorno" coerente.
*   `NavigationSessionService`: Si occupa di registrare e persistere la sessione corrente di navigazione (con metriche come posizione, velocità, e avvisi ricevuti), mantenendo uno storico delle camminate.

**2. Domain & Logic Layer (Livello della Logica Core):**
*   `NavigationMonitor`: È il motore dell'applicazione. Si sottoscrive allo stream del GPS. Ad ogni nuovo segnale (es. ogni secondo):
    *   Aggiorna la posizione del marker utente sulla mappa.
    *   Rototrasla la telecamera per farle seguire l'orientamento del pedone (bearing).
    *   Esegue la libreria matematica (`geo_utils.dart`) per verificare se la distanza dalla polyline supera la soglia consentita (Off-Route Check).
    *   Verifica la distanza dal prossimo waypoint per istruire l'interfaccia a mostrare l'istruzione di svolta corretta.
    *   Controlla la velocità per innescare eventualmente il `Lateral Road Detection`.

**3. Presentation / UI Layer (Livello di Presentazione):**
Sviluppato interamente in Flutter tramite Widget interconnessi.
*   `MapWidget`: Inizializza e gestisce il `GoogleMapController`. Ascolta i cambiamenti di stato notificati dal `NavigationMonitor` per disegnare dinamicamente le polilinee, aggiornare le istruzioni grafiche a schermo e far apparire gli overlay (come la celebrazione di arrivo o le notifiche delle strade laterali). Utilizza animazioni Flutter native (es. `AnimatedPositioned`, `FadeTransition`) per far scivolare i pannelli informativi a schermo senza scatti.

### 4.3. Sfide Tecniche Affrontate
Una delle sfide principali durante lo sviluppo è stata l'ottimizzazione del disegno della polyline direzionale. Google Maps SDK di base disegna solo linee semplici. Per emulare una navigazione professionale, è stato necessario implementare un algoritmo matematico che interpolasse lungo la polyline vettoriale decine di piccoli marker a forma di freccia ("chevron"), orientati tangenzialmente rispetto all'inclinazione del segmento in quel preciso punto geografico, migliorando enormemente la chiarezza visiva del percorso.

---

## 5. Risultati (Results)

I test funzionali, eseguiti tramite simulazione software delle posizioni GPS e successivamente sul campo, dimostrano la solidità dell'architettura e l'efficacia della User Experience implementata.

Di seguito vengono descritti gli scenari operativi principali che validano il funzionamento dell'app.

*   *[INSERIRE QUI SCREENSHOT 1: La Schermata Iniziale e Ricerca]*
    *   **Descrizione:** La schermata di avvio mostra immediatamente la mappa centrata sulla posizione corrente dell'utente. La barra di ricerca superiore, quando attivata, gestisce l'autocompletamento in tempo reale tramite Google Places. Il design pulito riduce il carico cognitivo iniziale.

*   *[INSERIRE QUI SCREENSHOT 2: Anteprima del Percorso (Preview State)]*
    *   **Descrizione:** Una volta selezionata una destinazione, il sistema transita istantaneamente nello stato di anteprima. Lo screenshot mostra la polyline intera renderizzata sulla mappa, adattando i confini della fotocamera (bounds) per includere partenza e arrivo. Un pannello inferiore mostra distanza, tempo stimato e un pulsante per avviare la navigazione.

*   *[INSERIRE QUI SCREENSHOT 3: Navigazione Attiva e Chevrons]*
    *   **Descrizione:** Cliccando "Avvia", l'app entra nel cuore delle sue funzionalità. La mappa effettua un tilt (inclinazione 3D) e uno zoom. Come si evince dallo screenshot, le istruzioni di svolta compaiono chiaramente in un overlay superiore, mentre la polyline è arricchita dai chevron direzionali calcolati dinamicamente.

*   *[INSERIRE QUI SCREENSHOT 4: Ricalcolo Off-Route]*
    *   **Descrizione:** Questo grafico dimostra la reattività dell'algoritmo geometrico. Mostrando la posizione dell'utente chiaramente fuori dalla traccia originale, l'app ha istantaneamente calcolato una nuova polyline (evidenziata con un tracciato aggiornato) senza richiedere input espliciti, dimostrando tolleranza agli errori di percorso dell'utente.

*   *[INSERIRE QUI SCREENSHOT 5: Overlay di Lateral Road Detection]*
    *   **Descrizione:** Simulando l'arresto del pedone a un incrocio, lo screenshot mostra l'apparizione di un overlay informativo discreto (es. colore arancione o indicazione testuale) che segnala all'utente l'identificazione di percorsi limitrofi, verificando il corretto funzionamento delle logiche di cooldown e delle API di snap-to-road.

---

## 6. Conclusioni

Il progetto "Smart Navigation App" rappresenta il compimento di un lavoro ingegneristico complesso, culminato nello sviluppo di un software di navigazione completo, funzionante e ottimizzato.

**Obiettivi Raggiunti:**
Il prodotto soddisfa pienamente i requisiti delineati in fase di progettazione. La transizione fluida tra gli stati tramite un'architettura single-screen garantisce un'esperienza utente all'altezza degli standard moderni. L'introduzione di features avanzate come il calcolo dinamico dell'off-route e il rilevamento ragionato delle strade laterali dimostra un'approfondita padronanza non solo del framework UI (Flutter), ma anche degli algoritmi matematico-geometrici per i sistemi informativi territoriali (GIS).

**Limitazioni e Sviluppi Futuri:**
Attualmente, l'applicazione dipende interamente dalla connettività internet per la risoluzione dei percorsi tramite Google API. In future iterazioni, sarebbe altamente strategico:
1.  Implementare il download locale delle mappe vettoriali (tramite tecnologie come Mapbox o simili) per garantire la navigazione offline.
2.  Integrare API per i dati sul traffico in tempo reale per influenzare l'euristica di routing, suggerendo attivamente percorsi per evitare ingorghi.
3.  Aggiungere il supporto vocale (Text-To-Speech) per la lettura automatica delle istruzioni di svolta, elevando ulteriormente il livello di sicurezza durante il percorso eliminando la necessità di guardare lo schermo.

---

## 7. Allegati e Link (Docs 2)

Per una valutazione pratica e per consultare i materiali di supporto al presente documento, si faccia riferimento ai seguenti link:

*   **Repository del Progetto e Link all'Esecuzione:** [Inserire Link a GitHub e/o all'applicazione web se compilata per Web, o link allo store/APK]
*   **Manuale Utente Software:** [Inserire Link alla Wiki o al file PDF del manuale operativo]
*   **Presentazione Slides:** A corredo di questa documentazione estesa, si allega il file di presentazione per esposizione pubblica:
    *   `Presentazione_Progetto_SmartNavigation.ppt` (10 slide) - Sintesi visiva per l'esposizione accademica e la discussione dei risultati.
