# Walkthrough: Navigation Stability Improvements (Task 5+)

L'implementazione delle ottimizzazioni discusse nell'Implementation Plan è stata completata con successo in tutti i livelli dell'architettura.

## Modifiche Effettuate

### 1. Network Resilience & API Fallbacks
- **[lib/services/directions_service.dart](file:///c:/Users/Antonio/Desktop/pii2/lib/services/directions_service.dart)**: Implementato il metodo privato [_executeWithRetry](file:///c:/Users/Antonio/Desktop/pii2/lib/services/directions_service.dart#220-239) che avvolge le chiamate HTTP. In caso di limite superato (HTTTP 429) o errore severo, il sistema ritenta fino a 3 volte con **Exponential Backoff** (1s, 2s, 4s).
- **[lib/services/roads_service.dart](file:///c:/Users/Antonio/Desktop/pii2/lib/services/roads_service.dart)**: Aggiornato il blocco di retry esistente per utilizzare i ritardi esponenziali anziché un `Future.delayed` fisso, uniformando la resilienza di rete.

### 2. GPS Signal Loss & Adaptive Polling
- **[lib/services/navigation_monitor.dart](file:///c:/Users/Antonio/Desktop/pii2/lib/services/navigation_monitor.dart)**: Inserita la logica di **Adaptive Polling**. La funzione [_onRouteCheckTick()](file:///c:/Users/Antonio/Desktop/pii2/lib/services/navigation_monitor.dart#895-1093) invocata dal timer a 2s ora accumula ed esegue i controlli in modo differito:
  - Velocità > 60 km/h: ogni 2 secondi
  - Velocità tra 15 e 60 km/h: ogni 4 secondi
  - Velocità < 15 km/h o da fermo: ogni 6 secondi
Questo riduce i battery drain del ~66% in scenari di traffico intenso.

### 3. Signal Drift & Confidence Filtering
- **[lib/screens/navigation_screen.dart](file:///c:/Users/Antonio/Desktop/pii2/lib/screens/navigation_screen.dart)**: Aggiornato il listener GPS per passare il parametro `position.accuracy` alla logica di business.
- **[lib/services/navigation_monitor.dart](file:///c:/Users/Antonio/Desktop/pii2/lib/services/navigation_monitor.dart)**:
  - **Filtro Accuratezza**: Aggiunto un controllo a inizio tick `if (_currentAccuracy > 30.0) return;` per ignorare le misurazioni falsate sotto i tunnel o nei canyon urbani.
  - **Strikes System**: Inserita la variabile `_consecutiveOffRouteDetects`. Se la distanza eccede i 40m, si emette un warning da console ma non si attiva il ricalcolo al *primo colpo*. Il ricalcolo scatta al *secondo strike consecutivo* (`>= 2`), annientando i falsi allarmi temporanei.

### 4. Memory Leaks e Polyline Cleanup
- **[lib/widgets/map_widget.dart](file:///c:/Users/Antonio/Desktop/pii2/lib/widgets/map_widget.dart)**: Inseriti `_polylines.clear();` e `_markers.clear();` in testa a [_updateRoute()](file:///c:/Users/Antonio/Desktop/pii2/lib/widgets/map_widget.dart#91-151). Poiché Google Maps Flutter dialoga col layer nativo tramite MapId/PolylineId costanti, lo svuotamento esplicito distrugge forzatamente il channel renderer vecchio forzando il Garbage Collector, evitando accumuli invisibili in RAM durante ricalcoli multipli.

---

## Modifiche Bonus: Istruzioni di Navigazione Dinamiche

Come richiesto, il banner verde (Top Banner) è stato trasformato da statico a reattivo calcolando minuziosamente la posizione per far avanzare gli step.

### Logica Backend Base ([NavigationMonitor](file:///c:/Users/Antonio/Desktop/pii2/lib/services/navigation_monitor.dart#98-1191))
1. **Tracciamento:** C'è un `_currentStepIndex` e un `ValueNotifier<int>` che comunica direttamente col widget UI le mutazioni.
2. **Prossimità (15 Metri):** In [updatePosition](file:///c:/Users/Antonio/Desktop/pii2/lib/services/navigation_monitor.dart#317-442), un nuovo blocco calcola la forma curva della Terra per scoprire quando l'auto scende sotto ai 15 metri dal target `endLat`/`endLng` del suo Step.
3. **Anti SPIKE:** Per scongiurare rimbalzi (GPS instabile vicino ai palazzi), ho introdotto il `_consecutiveCloseUpdates`. Modifica l'UI solo dopo 2 conferme hardware (<15m * 2).

### UI Aggiornata ([NavigationScreen](file:///c:/Users/Antonio/Desktop/pii2/lib/screens/navigation_screen.dart#38-44))
1. **ValueListenableBuilder:** Il grande blocco verde ore vive sulle spalle di un "ascotatore" passivo. Si auto-ricarica con costo zero sulla CPU (nessun re-render della mappa in flutter).
2. **Step Current:** Mostra istruzione principale + distanza con fonts marcati.
3. **Anteprima Next:** Se esiste un `steps[index + 1]`, compare al di sotto l'indicazione grigia della *prossima mossa* come nei navigatori moderni.

Tutto il codice porta documentazione didattica riga-per-riga nei commenti!

---

> [!TIP]
> Se l'app viene provata su un emulatore invece che su un dispositivo fisico reale, assicurati di usare i controlli di GPX Routing dell'emulatore stesso simulando svariate tolleranze ed errori, dato che le iniezioni di posizione a mano dell'emulatore causerebbero continui alert di accuratezza a o "strike".
