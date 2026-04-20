# Fix Calcolo Distanza Punto-Polyline: da Vertici a Segmenti

## Problema

La funzione `minDistanceToPolyline()` in `geo_utils.dart` calcola la distanza tra l'utente e i **singoli vertici** della polyline, ma non considera i **segmenti** (le linee rette tra due vertici consecutivi). 

Quando Google Directions API restituisce una `overview_polyline` con pochi punti su tratti rettilinei lunghi (es. un viale di 300m rappresentato da solo 2 punti), l'utente che si trova a metà del viale risulta a 150m dal vertice più vicino — ben oltre la soglia di 30m — scatenando un **falso ricalcolo del percorso**.

> [!IMPORTANT]
> La `overview_polyline` di Google è **compressa con l'algoritmo Douglas-Peucker**: i tratti rettilinei vengono drasticamente semplificati. È frequente avere solo 2 punti per un segmento rettilineo lungo centinaia di metri.

## Analisi dei Casi d'Uso

La funzione `minDistanceToPolyline` è usata **esclusivamente** da `isOnRoute()`, che a sua volta è chiamata in due punti di [navigation_monitor.dart](file:///c:/Users/Antonio/Desktop/pii2/lib/services/navigation_monitor.dart):

1. **Task 2a (riga 1582):** Controlla se l'utente è sul percorso attivo
2. **Task 2b (riga 1653):** Controlla se l'utente è su un percorso alternativo

### Scenari da Coprire

| Scenario | Vecchio Comportamento | Nuovo Comportamento |
|---|---|---|
| **Rettilineo lungo** (viale 500m, 2 punti) | ❌ Utente a metà = 250m dal vertice → falso "fuori rotta" | ✅ Proiezione ortogonale sul segmento → ~0m |
| **Curva dolce** (molti punti ravvicinati) | ✅ Funziona (punti ogni 5-10m) | ✅ Funziona ancora meglio (distanza dal segmento ≤ distanza dal vertice) |
| **Angolo retto** (svolta 90°) | ✅ Funziona (incrocio = vertice) | ✅ Funziona (il clamp impedisce proiezioni fuori segmento) |
| **Utente prima del primo punto** | ✅ Distanza dal punto 0 | ✅ Clamp a t=0 → stessa distanza dal punto 0 |
| **Utente dopo l'ultimo punto** | ✅ Distanza dall'ultimo punto | ✅ Clamp a t=1 → stessa distanza dall'ultimo punto |
| **Segmento di lunghezza 0** (due punti coincidenti) | ✅ Distanza dal punto | ✅ Fallback esplicito a distanza punto-punto |
| **Un solo punto nella polyline** | ✅ Distanza dal punto | ✅ Fallback esplicito a distanza punto-punto |

> [!NOTE]
> Il calcolo **non peggiora mai** rispetto al vecchio: la distanza punto-segmento è sempre **≤** alla distanza punto-vertice. Quindi in nessun caso un utente che prima era "on route" diventerà "off route" con la nuova logica.

## Proposed Changes

### Componente: Geo Utils

#### [MODIFY] [geo_utils.dart](file:///c:/Users/Antonio/Desktop/pii2/lib/services/geo_utils.dart)

**Modifica 1 — Nuova funzione privata `_distanceToSegment`** (dopo riga 271, prima di `isOnRoute`):

Calcola la distanza minima tra un punto P e un segmento AB usando **proiezione su piano euclideo locale**:

1. Converte le coordinate GPS in un sistema metrico 2D locale (approssimazione planare valida per distanze < 1km, che è il nostro caso)
2. Calcola il parametro `t` di proiezione tramite **dot product** (prodotto scalare)
3. Clampa `t` nell'intervallo `[0, 1]` per non proiettare fuori dal segmento
4. Riconverte le coordinate proiettate in lat/lng
5. Usa `distanceBetween()` (Haversine) per la distanza finale in metri — così il risultato finale è geodeticamente preciso

Gestione edge case:
- Se A == B (segmento di lunghezza 0) → fallback a `distanceBetween(P, A)`
- Se t = 0 → la proiezione cade su A (utente "prima" del segmento)  
- Se t = 1 → la proiezione cade su B (utente "dopo" il segmento)

**Modifica 2 — Riscrittura di `minDistanceToPolyline`** (righe 243-271):

Invece di iterare sui **punti** singoli, itera sulle **coppie consecutive** `(polyline[i], polyline[i+1])` chiamando `_distanceToSegment` per ciascuna coppia.

Edge case gestiti:
- Polyline vuota → return `double.infinity` (invariato)
- Polyline con 1 solo punto → fallback a `distanceBetween` punto-punto

> [!WARNING]
> **Nessun'altra funzione cambia.** `isOnRoute()`, `_onRouteCheckTick()`, e tutta la logica nel `NavigationMonitor` restano **identici**. Il fix è completamente trasparente: cambia solo *come* viene calcolata la distanza, non *dove* né *quando*.

## Open Questions

Nessuna domanda aperta. La modifica è chirurgica (una sola funzione privata nuova + riscrittura di una funzione esistente) e non ha impatto su nessun'altra parte del codice.

## Verification Plan

### Test Manuali Logici

Verificherò la correttezza con casi numerici controllabili:

1. **Rettilineo:** Polyline `[(0,0), (0,1)]`, utente a `(0, 0.5)` → distanza ≈ 0m (è esattamente sulla linea)
2. **Perpendicolare a metà:** Polyline `[(0,0), (0,1)]`, utente a `(0.001, 0.5)` → distanza ≈ 111m (perpendicolare, non 0)
3. **Oltre il segmento:** Polyline `[(0,0), (0,1)]`, utente a `(0, 2)` → distanza = distanza(utente, punto B) (clamp a t=1)
4. **Segmento nullo:** Polyline `[(0,0), (0,0)]` → fallback a haversine punto-punto
5. **Percorso con curve:** Polyline a L `[(0,0), (0,1), (1,1)]` → verifica che il segmento più vicino vinca

### Build

```
flutter analyze
```

Verifico che il progetto compili senza errori dopo la modifica.
