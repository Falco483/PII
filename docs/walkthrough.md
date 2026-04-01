# GPS Navigation Features — Walkthrough

## Changes Made

### New Files (4)

| File | Lines | Purpose |
|---|---|---|
| [geo_utils.dart](file:///c:/Users/Antonio/Desktop/pii2/lib/services/geo_utils.dart) | 249 | Costanti configurabili + formule geodetiche (Haversine, destination point, lateral points) |
| [roads_service.dart](file:///c:/Users/Antonio/Desktop/pii2/lib/services/roads_service.dart) | 193 | Client HTTP per Roads API (nearestRoads) con retry logic |
| [navigation_monitor.dart](file:///c:/Users/Antonio/Desktop/pii2/lib/services/navigation_monitor.dart) | 375 | Logica di business: `direction`, timer bearing 5s, trigger velocità-zero 10s, analisi laterale |
| [navigation_overlay.dart](file:///c:/Users/Antonio/Desktop/pii2/lib/widgets/navigation_overlay.dart) | 243 | Widget overlay animato (fade in/out, auto-dismiss, tap-to-dismiss) |

### Modified Files (2)

| File | Change |
|---|---|
| [directions_service.dart](file:///c:/Users/Antonio/Desktop/pii2/lib/services/directions_service.dart) | Aggiunto campo `maneuver` a `DirectionStep` |
| [navigation_screen.dart](file:///c:/Users/Antonio/Desktop/pii2/lib/screens/navigation_screen.dart) | Integrazione completa: salva lat/lng/bearing, istanzia `NavigationMonitor`, mostra overlay |

### Documentation

| File | Purpose |
|---|---|
| [implementation_plan.md](file:///c:/Users/Antonio/Desktop/pii2/docs/implementation_plan.md) | Piano di implementazione salvato in `docs/` |

## Verification

### Static Analysis (`flutter analyze`)
- ✅ **0 errori** di compilazione
- ℹ️ 10 info/warning (tutti pre-esistenti: `print`, `withOpacity` deprecato, dangling doc comment in `map_widget.dart`)

### Flusso Logico
1. GPS emette posizione/velocità/bearing → `navigation_screen.dart` li salva e li inoltra a `NavigationMonitor`
2. `NavigationMonitor` aggiorna `direction` ogni 5s (solo se velocità > 4 km/h)
3. Quando velocità < 1 km/h → avvia countdown 10s
4. Se countdown scade → snapshot posizione/direction → controlla waypoint svolta → se no, calcola 10 punti laterali → chiama Roads API → mostra overlay
5. Overlay mostra `html_instructions` (se su waypoint) o "vai diritto stronzo" (se strada laterale)
