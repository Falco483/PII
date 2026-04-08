# Navigation History Feature Implementation Plan

Questa funzionalità aggiungerà un sistema di navigazione a ritroso (Back Stack) all'interfaccia a singolo schermo dell'app, permettendo all'utente di tornare indietro negli stati tramite un pulsante UI dedicato o il tasto/gesto "Indietro" nativo di Android/iOS.

## Analisi del Sistema Attuale
L'app utilizza un'architettura **Single-Page Application** all'interno di [NavigationScreen](file:///c:/Users/Antonio/Desktop/pii2/lib/screens/navigation_screen.dart#44-50). La navigazione non avviene tramite il `Navigator` classico di Flutter (che spinge nuovi [Route](file:///c:/Users/Antonio/Desktop/pii2/lib/widgets/map_widget.dart#473-492)), ma cambiando la variabile di stato `_appState` (di tipo `NavigationAppState`).
Gli stati esplorati dall'utente sono:
1. `search`
2. `placeSelected`
3. `routePreview`
4. `navigating`

## Proposed Changes

### 1. `lib/services/navigation_history_service.dart` [NEW]
Verrà creato un nuovo servizio dedicato alla gestione dello stack di navigazione.
- **Classe `NavigationHistoryService`** (estenderà `ChangeNotifier` per notificare la UI dei cambiamenti nello stack).
- Manterrà una `List<NavigationHistoryEntry> _stack`. Ogni entry conterrà il `NavigationAppState` e gli eventuali dati associati necessari a ricostruire quello stato (es. l'`indirizzo selezionato`, i `directionsResult`).
- Esporrà metodi: `pushState(...)`, `goBack()`, `canGoBack`, e un metodo per svuotare lo stack.

### 2. [lib/screens/navigation_screen.dart](file:///c:/Users/Antonio/Desktop/pii2/lib/screens/navigation_screen.dart) [MODIFY]
Integrazione del servizio di cronologia:
- **Inizializzazione**: si istanzierà `NavigationHistoryService` in [initState](file:///c:/Users/Antonio/Desktop/pii2/lib/widgets/map_widget.dart#165-171).
- **Intercettazione del Back (Android & Swipe iOS)**:
  L'intero corpo del widget verrà avvolto con un `PopScope` (supportato nelle versioni recenti di Flutter). 
  - `canPop`: sarà `true` solo se lo stack è vuoto (cioè siamo alla root, `search`).
  - `onPopInvoked`: se `canPop` è false, chiamerà la nostra funzione interna `_handleBack()`.
- **Implementazione di `_handleBack()`**:
  Chiamerà `navigationHistory.goBack()` e, in base allo stato restituito, applicherà un `setState()` per rimettere i dati vecchi e cambiare `_appState`. Gestirà logicamente lo spegnimento della navigazione se si torna indietro da `navigating`. In caso di stack vuoto e pressione del tasto back di Android, mostrerà l'AlertDialog per confermare l'uscita.
- **Pulsante Back nella UI**:
  Aggiungeremo un pulsante (freccia indietro) in un widget `Positioned` in alto a sinistra (o gestito nei vari bottom sheet / search bar header).
  - Icona: `Platform.isIOS ? Icons.arrow_back_ios_new : Icons.arrow_back`.
  - Visibilità: invisibile se `canGoBack` è `false`.

### 3. Modifica alla logica di avanzamento in [NavigationScreen](file:///c:/Users/Antonio/Desktop/pii2/lib/screens/navigation_screen.dart#44-50)
Ovunque l'app faccia un `setState(() { _appState = nuovoStato; })`, aggiungeremo preventivamente un `_historyService.pushState(statoAttuale, datiAttuali)` per salvare un "checkpoint".

## Verification Plan

### Manual Verification
L'utente potrà testare manualmente questo flusso:
1. Lanciare l'app usando il simulatore iOS o Android. Verrà mostrato lo stato `search`. L'icona "Back" UI non deve essere visibile.
2. Cercare un luogo e selezionarlo. Lo stato passa a `placeSelected`. L'icona "Back" appare. 
3. Premere l'icona "Back" UI -> l'app deve tornare a `search` (svuotando il widget di destinazione).
4. Procedere fino a `navigating`. 
5. Su **Android**: premere il tasto hardware/gestures indietro del telefono. L'app interrompe la navigazione e torna a `routePreview`. Premere di nuovo, torna a `placeSelected`. Premere di nuovo, torna a `search`. Premere un'ultima volta, appare il pop-up "Vuoi uscire?".
6. Su **iOS**: eseguire lo swipe dal bordo sinistro e verificare lo stesso comportamento di rientro progressivo (assicurandosi di non uscire bruscamente dall'app).

### Automated Tests
Non ci sono test E2E esistenti necessari o infrastrutture di golden test configurate, la verifica manuale copre l'interazione ibrida UI/hardware.
