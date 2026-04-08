# PII Navigation App - Architettura e Flusso di Processo (BPMN)

Questo documento presenta:
1. Il **Diagramma a Blocchi** (Architettura del Sistema) che mostra come interagiscono i vari componenti, servizi e widget.
2. Il processo **BPMN** (rappresentato tramite flowchart) che illustra la logica di funzionamento passo dopo passo, dalla ricerca della destinazione fino alla navigazione e arrivo.

---

## 1. Diagramma a Blocchi (Architettura del Sistema)

La nostra applicazione è basata su Flutter. Il `NavigationScreen` funge da punto di coordinamento principale, collegando i Widget visivi della UI con i Servizi logici che chiamano le API esterne e il dispositivo (GPS / Bussola).

```mermaid
flowchart TD
    subgraph UI["User Interface (Widgets)"]
        NS["NavigationScreen<br>State Coordinator"]
        MW["MapWidget<br>Google Maps UI"]
        SI["SearchInput<br>Google Places Search"]
        DL["DirectionsList<br>Turn-by-turn UI"]
        NO["NavigationOverlay<br>Alerts & Status"]
    end

    subgraph Logic["Business Logic (Services)"]
        NM["NavigationMonitor<br>GPS & Routing State"]
        NHS["NavigationHistoryService<br>Back-Stack Manager"]
        SHS["SearchHistoryService<br>Recent Searches"]
        GU["GeoUtils<br>Math & Geometry"]
    end

    subgraph API["External Services APIs"]
        DS["DirectionsService<br>Google Routes API"]
        PS["PlacesService<br>Google Places API"]
        RS["RoadsService<br>Google Roads API"]
    end

    subgraph Hardware["Device Sensors"]
        GPS["GPS Stream<br>Geolocator"]
        Compass["Magnetometer<br>FlutterCompass"]
    end

    %% Relazioni UI
    NS -->|Controls UI State| MW
    NS -->|Controls UI State| SI
    NS -->|Controls UI State| DL
    NS -->|Controls UI State| NO

    %% Relazioni NavigationScreen con Logic e Sensori
    GPS -.->|Location Updates| NS
    Compass -.->|Heading Updates| NS
    NS -->|Feeds Location/Heading| NM
    NS -->|Manages States| NHS

    %% Relazioni Logic
    SI <-->|Search Queries| PS
    SI <-->|History| SHS
    NM <-->|Rerouting| DS
    NM <-->|Lateral Detection| RS
    NM -.->|Uses| GU

    %% Navigation Monitor notifica la UI
    NM -.->|"State Notifiers<br>Overlay, Route, Step"| NS
```

---

## 2. Diagramma BPMN (Logica di Navigazione e Processi)

Il diagramma sottostante modella l'interazione utente e la logica interna del `NavigationMonitor` (il ciclo di navigazione) utilizzando le convenzioni visive del BPMN (Cerchi per Inizio/Fine, Rettangoli per Attività, Rombi per i Decision Gateways).


```mermaid

flowchart LR

%% ===== STILI =====
classDef startEvent fill:#8f8,stroke:#333,stroke-width:2px
classDef endEvent fill:#f88,stroke:#333,stroke-width:3px
classDef userTask fill:#dae8fc,stroke:#6c8ebf
classDef serviceTask fill:#d5e8d4,stroke:#82b366
classDef gateway fill:#ffe599,stroke:#333,stroke-width:2px

%% ===== LANE UTENTE =====
subgraph U [Utente]
    Start(("Start")):::startEvent
    
    U_Search["Inserisce destinazione"]:::userTask
    U_Select["Seleziona luogo"]:::userTask
    U_RequestDir["Richiede indicazioni"]:::userTask
    U_StartNav["Preme 'Avvia Navigazione'"]:::userTask
    
    U_Search --> U_Select --> U_RequestDir
end

%% ===== LANE SISTEMA =====
subgraph S [Sistema]
    S_CalcRoute["Calcolo percorso<br>(Directions API)"]:::serviceTask
    S_ShowPreview["Mostra anteprima percorso"]:::serviceTask
    
    G_StartNav{"Avviare<br>navigazione?"}:::gateway
    
    S_InitNav["Inizializza monitor GPS<br>+ camera"]:::serviceTask
    
    %% LOOP NAVIGAZIONE
    G_Arrival{"Arrivato?"}:::gateway
    G_OffRoute{"Fuori percorso?"}:::gateway
    G_Speed{"Velocità = 0?"}:::gateway
    
    S_Reroute["Ricalcolo percorso"]:::serviceTask
    S_Lateral["Analisi strade laterali"]:::serviceTask
    
    S_Update["Aggiornamento GPS"]:::serviceTask
    
    S_Arrived["Mostra 'Sei arrivato'"]:::serviceTask
    End(("End")):::endEvent
end

%% ===== FLOW CROSS-LANE =====
U_RequestDir --> S_CalcRoute
S_CalcRoute --> S_ShowPreview

S_ShowPreview --> G_StartNav
U_StartNav --> G_StartNav

G_StartNav -->|Sì| S_InitNav

%% ===== LOOP =====
S_InitNav --> S_Update
S_Update --> G_Arrival

G_Arrival -->|Sì| S_Arrived
S_Arrived --> End

G_Arrival -->|No| G_OffRoute

G_OffRoute -->|Sì| S_Reroute --> G_Speed
G_OffRoute -->|No| G_Speed

G_Speed -->|Sì| S_Lateral --> S_Update
G_Speed -->|No| S_Update

```


### Spiegazione dei Flussi

1. **Ricerca e Selezione (Search App State):**
   L'utente avvia l'app in modalità mappa libera e usa la barra in alto (`SearchInput`) per cercare un indirizzo. I risultati sono forniti dal `PlacesService`.

2. **Anteprima (Route Preview App State):**
   Una volta scelto il luogo si carica l'anteprima (`DirectionsService`). La mappa inquadra percorso e utente.

3. **Ciclo di Navigazione / Business Logic (`NavigationMonitor`):**
   - Viene intercettato lo stream `Geolocator`. Per ogni posizione si elabora la logica:
   - **Arrivo**: Se la distanza fino al target finale è infinitesimale, scatta la transizione di arrivo.
   - **Ricalcolo**: Il modulo valuta i punti correnti. Se la deviazione supera i margini tollerati, parte il ricalcolo (`DirectionsService`), e compare l'UI di "Ricalcolo in corso".
   - **Sorveglianza Strade Laterali**: Se l'utente è fermo (velocità 0 per un po' di tempo) e lontano dai bivi principali, interviene il `RoadsService` per identificare possibili strade parallele e ricalcolare gli avvisi (overlay arancione per incertezze del GPS).
