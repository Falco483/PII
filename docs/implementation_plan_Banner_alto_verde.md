# Implementation Plan: Dynamic Navigation Instructions

*L'obiettivo è rendere il banner verde in alto dinamico durante la navigazione, aggiornando le istruzioni turn-by-turn basandosi sulla vicinanza reale (GPS) al punto di svolta, protetto da filtri anti-falso.*

## User Review Required

Nessuna nota bloccante. Ho recepito esattamente il layout e le specifiche indicate dal tuo messaggio (soglia 15m, doppio strike, istruzioni corrente/prossima).

## Proposed Changes

---

### Navigation Monitor (Logica Core)
Istruiremo il [NavigationMonitor](file:///c:/Users/Antonio/Desktop/pii2/lib/services/navigation_monitor.dart#98-1081) (che già riceve agilmente gli aggiornamenti GPS ad ogni singolo frame/tick in [updatePosition](file:///c:/Users/Antonio/Desktop/pii2/lib/services/navigation_monitor.dart#282-343)) a gestire lo stato di avanzamento e a notificare la UI in tempo reale.

#### [MODIFY] [lib/services/navigation_monitor.dart](file:///c:/Users/Antonio/Desktop/pii2/lib/services/navigation_monitor.dart)
1. **Nuove Variabili di Stato (TASK 1 e 6):**
   - Aggiungere `int _currentStepIndex = 0;`
   - Aggiungere `int _consecutiveCloseUpdates = 0;`
   - Aggiungere un nuovo notifier per la UI: `final ValueNotifier<int> currentStepNotifier = ValueNotifier<int>(0);`. Servirà  per far reagire istantaneamente e unicamente il banner top senza sprecare `setState` globali sulla mappa.
2. **Reset:** In azzeramento (es. avvio nuovo percorso o deviazione confermata ricalcolata), reimpostare `_currentStepIndex = 0` e `_consecutiveCloseUpdates = 0`.
3. **Logica in [updatePosition](file:///c:/Users/Antonio/Desktop/pii2/lib/services/navigation_monitor.dart#282-343) (TASK 2, 3, 4, 6):**
   - Ad ogni ingresso GPS controllare `if (_activeRoute == null || _routeSteps.isEmpty) return;`
   - Calcolare [distanceBetween](file:///c:/Users/Antonio/Desktop/pii2/lib/services/geo_utils.dart#186-202) la posizione corrente e `_routeSteps[_currentStepIndex].endLocation`.
   - Implementare la logica: se `< 15.0` => counter++ => se `>= 2` => aumenta indice, notifica UI, riparti da 0.
   - Gestire la fine array (arrivo a destinazione).

---

### Navigation Screen (Interfaccia Utente)
Il [NavigationScreen](file:///c:/Users/Antonio/Desktop/pii2/lib/screens/navigation_screen.dart#38-44) riceverà il nuovo indice e leggerà il parametro dall'`_activeRoute` per popolare grafica.

#### [MODIFY] [lib/screens/navigation_screen.dart](file:///c:/Users/Antonio/Desktop/pii2/lib/screens/navigation_screen.dart)
1. **Riconnettitura UI (TASK 5):**
   - In [_buildNavigatingUI()](file:///c:/Users/Antonio/Desktop/pii2/lib/screens/navigation_screen.dart#849-952), avvolgeremo il "TOP BANNER" con un `ValueListenableBuilder` in ascolto sul nuovo `_navigationMonitor.currentStepNotifier`.
   - Recupereremo lo step corrente e il next step (se esistente).
   - Costruiremo il widget mostrando l'istruzione in HTML (in chiaro), i metri e l'ingombro visivo.
2. **Commenti Didattici:** Entrambe le zone (Business e Design) godranno del commento per-riga per Jr Dev.

## Verification Plan

### Manual Verification
L'utente verrà invitato a verificare su dispositivo fisico in auto (o camminando in esterna, anche se la demo pedonale funziona diversamente) che il banner commuti da `Step[0]` a `Step[1]` quando si transita a ~15m dal punto dell'incrocio, e solo se ci rimane per almeno 2 letture fisse per inibire i salti involontari.
