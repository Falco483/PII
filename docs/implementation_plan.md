# GPS Navigation Features — Implementation Plan

Implementazione di: bearing affidabile (`direction`), trigger velocità-zero con analisi strade laterali (Roads API), overlay visivo su mappa.

## User Review Required

> [!IMPORTANT]
> **API Key** — Il progetto usa `'YOUR_API_KEY_HERE'` in `DirectionsService`. La stessa chiave sarà usata anche per la Roads API. L'utente deve assicurarsi che la chiave Google Cloud abbia abilitati sia **Directions API** sia **Roads API**.

> [!WARNING]
> **Roads API Costo** — La Roads API ha un costo per chiamata. Ogni volta che l'utente è fermo per 10 secondi (e non si trova su un waypoint di svolta) viene effettuata una chiamata con 10 punti. L'implementazione è progettata per evitare falsi positivi, ma l'utente dovrebbe monitorare l'uso in produzione.

---

## Proposed Changes

### Utilities — Modulo Geodetico

#### [NEW] [geo_utils.dart](file:///c:/Users/Antonio/Desktop/pii2/lib/services/geo_utils.dart)

Funzioni pure, senza dipendenze, riutilizzabili:

- `haversineDistance(lat1, lng1, lat2, lng2)` → distanza in metri tra due coordinate
- `destinationPoint(lat, lng, bearingDeg, distanceMeters)` → coordinate del punto a N metri nella direzione data (formula geodetica WGS84)
- `computeLateralPoint(lat, lng, bearingDeg, distanceMeters, side)` → wrapper che aggiunge ±90° al bearing per calcolare punti a destra/sinistra
- Tutte le costanti: `kSpeedThresholdKmH = 4.0`, `kBearingUpdateIntervalSec = 5`, `kZeroSpeedDelayMs = 10000`, `kTurnWaypointRadiusMeters = 5.0`, `kLateralDistanceMeters = 10.0`, `kSatelliteOffset2m = 2.0`, `kSatelliteOffset4m = 4.0`, `kZeroSpeedThresholdKmH = 1.0`

Ogni funzione avrà commenti esaustivi (formula, motivazione, edge case).

---

### Roads API Client

#### [NEW] [roads_service.dart](file:///c:/Users/Antonio/Desktop/pii2/lib/services/roads_service.dart)

- Classe `RoadsService` con metodo `findNearestRoads(List<LatLngPoint> points)` → chiama `GET https://roads.googleapis.com/v1/nearestRoads?points=...|...&key=API_KEY`
- Parsing della risposta: estrae `snappedPoints` array
- Gestione errori HTTP (timeout, 4xx, 5xx) con retry (1 tentativo) o fallback silenzioso
- Commenti: perché `nearestRoads` e non `snapToRoads`, formato pipe-separated, natura asincrona

---

### Model Update — DirectionStep + maneuver

#### [MODIFY] [directions_service.dart](file:///c:/Users/Antonio/Desktop/pii2/lib/services/directions_service.dart)

- Aggiungere campo `String? maneuver` al modello `DirectionStep`
- Nel `fromJson`, estrarre `json['maneuver']` (campo opzionale della Directions API)
- Necessario per mostrare l'istruzione corretta se l'utente è fermo su un waypoint di svolta (Step 2.3)

---

### Core Business Logic — Navigation Monitor

#### [NEW] [navigation_monitor.dart](file:///c:/Users/Antonio/Desktop/pii2/lib/services/navigation_monitor.dart)

Classe `NavigationMonitor` che gestisce tutta la logica di business separata dall'UI:

1. **`direction` (bearing affidabile)** — variabile nullable `double? direction`, aggiornata ogni 5 secondi via `Timer.periodic` se la velocità è sopra soglia. Timer avviato/fermato dal chiamante.

2. **Zero-speed trigger** — metodo `onSpeedUpdate(double speedKmH)` che:
   - Se `speedKmH < 1.0` → avvia countdown 10s (se non già attivo)
   - Se velocità torna sopra → cancella il countdown
   - Se countdown scade → esegue l'analisi (steps 2.2→2.6)

3. **Step 2.2** — Salva snapshot di `currentLocation` e `direction` al momento esatto

4. **Step 2.3** — `checkNearTurnWaypoint(snapshot, steps)` → controlla se la posizione è entro 5m da un `endLocation` di uno step. Se sì, ritorna l'istruzione/maneuver. Se no, procede.

5. **Step 2.4** — `computeLateralPoints(snapshot)` → calcola i 10 punti (dx, sx, 4 satellite per lato) usando le funzioni di `geo_utils.dart`

6. **Step 2.5** — Chiama `RoadsService.findNearestRoads(points)` con i 10 punti

7. **Step 2.6** — Analizza risposta: se `snappedPoints.isNotEmpty` → emette evento "vai diritto stronzo"; altrimenti nulla

Output della logica: un callback / `ValueNotifier<NavigationOverlayState?>` che la UI osserva.

---

### UI Integration — NavigationScreen

#### [MODIFY] [navigation_screen.dart](file:///c:/Users/Antonio/Desktop/pii2/lib/screens/navigation_screen.dart)

- Salvare `currentLocation` (lat/lng) e `rawBearing` nel listener GPS (già esiste il listener, manca il salvataggio di lat/lng e heading)
- Istanziare `NavigationMonitor` in `initState`, passare `currentSpeed`, `currentLocation`, `rawBearing`, e gli `steps` del percorso calcolato
- Avviare/fermare il timer del bearing tramite `NavigationMonitor`
- Osservare l'output di `NavigationMonitor` per mostrare/nascondere l'overlay
- Dispose corretto di tutti i timer

---

### Visual Overlay

#### [NEW] [navigation_overlay.dart](file:///c:/Users/Antonio/Desktop/pii2/lib/widgets/navigation_overlay.dart)

Widget `NavigationOverlay` che mostra:
- **Caso waypoint di svolta**: banner con istruzione di navigazione (testo dallo step, icona maneuver)
- **Caso strada laterale rilevata**: banner "vai diritto stronzo"
- Auto-dismiss dopo 8 secondi, oppure tap to dismiss
- Animazione fade-in / fade-out
- Stile chiaro e leggibile (pensato per utenti con disabilità cognitive)

---

## Verification Plan

### Static Analysis
```bash
cd c:\Users\Antonio\Desktop\pii2
flutter analyze
```
Deve passare senza errori (warnings accettabili).

### Build Check
```bash
cd c:\Users\Antonio\Desktop\pii2
flutter build apk --debug
```
Deve compilare senza errori.

### Manual Testing
L'app richiede GPS reale e API key valida. L'utente dovrà:
1. Inserire una API key valida al posto di `YOUR_API_KEY_HERE`
2. Lanciare l'app su un dispositivo fisico o emulatore con GPS simulato
3. Calcolare un percorso con svolte
4. Verificare che il bearing si aggiorni quando si muove a > 4 km/h
5. Fermarsi per > 10 secondi e verificare che l'analisi laterale si attivi
6. L'utente dovrà confermare manualmente il comportamento corretto degli overlay
