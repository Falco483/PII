/// navigation_monitor.dart — Logica di Business per la Navigazione Assistita
///
/// Questa classe gestisce tutta la logica "intelligente" dell'app:
/// 1. Mantiene la variabile `direction` (bearing affidabile)
/// 2. Rileva quando l'utente è fermo (zero-speed trigger)
/// 3. Controlla se l'utente è su un waypoint di svolta del percorso
/// 4. Calcola i punti laterali e interroga la Roads API
/// 5. Emette eventi per l'overlay visivo
/// 6. [TASK 2] Monitora la posizione rispetto al percorso attivo ogni 2 secondi
/// 7. [TASK 2] Gestisce il cambio automatico a percorsi alternativi
/// 8. [TASK 2] Ricalcola il percorso via API se nessun alternativo è compatibile
///
/// SEPARAZIONE DELLE RESPONSABILITÀ:
/// Questo file contiene SOLO la logica di business. Non contiene:
/// - Rendering UI (→ navigation_overlay.dart)
/// - Chiamate GPS (→ navigation_screen.dart)
/// - Calcoli geodetici (→ geo_utils.dart)
/// - Chiamate Roads API (→ roads_service.dart)
///
/// Questo design permette di testare la logica in isolamento e di sostituire
/// facilmente qualsiasi componente senza toccare gli altri.
///
/// THREAD SAFETY:
/// Gli aggiornamenti GPS arrivano in background (stream asincrono).
/// Per evitare race condition:
/// - Lo snapshot della posizione e del bearing viene catturato atomicamente
///   al momento dello scadere del timer (Step 2.2)
/// - I timer vengono cancellati in modo sicuro controllando sempre se sono
///   ancora attivi prima di operare
/// - Le variabili critiche (direction, _zeroSpeedTimer) sono modificate
///   solo dal thread principale (main isolate di Flutter)
library;

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'geo_utils.dart';
import 'roads_service.dart';
import 'directions_service.dart';

// =============================================================================
// MODELLO PER LO STATO DELL'OVERLAY
// =============================================================================

/// Tipo di overlay da mostrare sulla mappa.
///
/// - [turnInstruction]: l'utente è fermo su un waypoint di svolta.
///   Mostra l'istruzione di navigazione (testo da html_instructions).
/// - [lateralRoadDetected]: la Roads API ha trovato strade laterali.
///   Mostra "vai diritto stronzo".
enum OverlayType { turnInstruction, lateralRoadDetected }

/// Stato dell'overlay da mostrare sulla mappa.
///
/// Contiene il tipo di overlay e il messaggio da visualizzare.
/// Viene emesso dal NavigationMonitor tramite un ValueNotifier
/// per essere osservato dalla UI.
class NavigationOverlayState {
  final OverlayType type;
  final String message;

  /// L'istruzione di manovra dallo step, se disponibile (es. "turn-right").
  /// Usato dalla UI per mostrare un'icona appropriata.
  final String? maneuver;

  NavigationOverlayState({
    required this.type,
    required this.message,
    this.maneuver,
  });
}

// =============================================================================
// CLASSE PRINCIPALE — NAVIGATION MONITOR
// =============================================================================

/// NavigationMonitor — Cuore della logica di navigazione assistita.
///
/// CICLO DI VITA:
/// 1. Viene creato in NavigationScreen.initState()
/// 2. Riceve aggiornamenti continui di posizione, velocità e bearing
/// 3. Emette eventi di overlay tramite [overlayNotifier]
/// 4. Viene distrutto in NavigationScreen.dispose() tramite [dispose()]
///
/// UTILIZZO:
/// ```dart
/// final monitor = NavigationMonitor();
/// monitor.overlayNotifier.addListener(() {
///   final state = monitor.overlayNotifier.value;
///   if (state != null) { /* mostra overlay */ }
/// });
/// // Ad ogni aggiornamento GPS:
/// monitor.updatePosition(lat, lng, speedKmH, rawBearing);
/// // Quando il percorso viene calcolato:
/// monitor.updateRouteSteps(result.steps);
/// // In dispose:
/// monitor.dispose();
/// ```
class NavigationMonitor {
  // ===========================================================================
  // STATO INTERNO
  // ===========================================================================

  /// Ultimo bearing affidabile dell'utente (gradi 0-360, o null se mai acquisito).
  ///
  /// PERCHÉ PUÒ ESSERE NULL:
  /// Al primo avvio dell'app, prima che l'utente si muova a velocità sufficiente,
  /// non abbiamo nessun bearing affidabile. In questo stato, tutte le funzionalità
  /// che dipendono dalla direzione (calcolo punti laterali) restano in standby.
  /// Questo è preferibile a usare un bearing casuale che porterebbe a risultati
  /// errati.
  double? _direction;

  /// Posizione corrente dell'utente (latitudine).
  double? _currentLat;

  /// Posizione corrente dell'utente (longitudine).
  double? _currentLng;

  /// Velocità corrente dell'utente in km/h.
  double _currentSpeed = 0.0;

  /// Accuratezza GPS in metri (Confidence level).
  double _currentAccuracy = 0.0;

  /// Counter dei tick per il polling dinamico (Adaptive Polling).
  int _routeCheckTicks = 0;

  /// Counter delle deviazioni consecutive (Strikes).
  int _consecutiveOffRouteDetects = 0;

  /// Bearing raw corrente dal GPS (può essere inaffidabile a basse velocità).
  double _rawBearing = 0.0;

  /// Lista degli step del percorso calcolato dalla Directions API.
  /// Viene aggiornata ogni volta che l'utente calcola un nuovo percorso.
  List<DirectionStep> _routeSteps = [];

  // ===========================================================================
  // STATO PROGRESSIONE PERCORSO — DYNAMIC INSTRUCTIONS
  // ===========================================================================

  /// Indice dello step attualmente attivo (cioè quello in cui l'utente si
  /// trova fisicamente). Al calcolo del percorso (o al ricalcolo) parte
  /// sempre da 0 (il primo step del percorso).
  ///
  /// Questo indice viene aumentato man mano che l'utente raggiunge il
  /// punto finale (`endLocation`) dello step corrente.
  int _currentStepIndex = 0;

  /// Contatore degli aggiornamenti GPS consecutivi in cui l'utente risulta
  /// vicino (< 15 metri) all'incrocio di destinazione dello step corrente.
  /// 
  /// PERCHÉ SERVE QUESTO CONTATORE:
  /// Il GPS non è perfetto. Un singolo sbalzo temporaneo del segnale (es. 
  /// riflesso su un palazzo) potrebbe porre falsamente l'utente a 5m 
  /// dall'incrocio per un solo istante. Per evitare che l'interfaccia 
  /// avanzi prematuramente d'istruzione, richiediamo che la vicinanza sia
  /// "confermata" per almeno N aggiornamenti GPS consecutivi (noi usiamo 2).
  int _consecutiveCloseUpdates = 0;

  // ===========================================================================
  // STATO PERCORSI — TASK 2
  // ===========================================================================

  /// Percorso attualmente attivo (quello mostrato all'utente sulla mappa).
  /// Quando l'utente devia, questo campo viene sostituito con un percorso
  /// alternativo (Task 2b) o con il risultato di un ricalcolo API (Task 2c).
  /// È null se la navigazione non è ancora stata avviata.
  RouteData? _activeRoute;

  /// Lista di TUTTI i percorsi alternativi ricevuti dall'ultima chiamata API.
  /// Include anche il percorso attivo. Quando l'utente devia, iteriamo su
  /// questa lista per cercare un percorso alternativo compatibile (Task 2b)
  /// prima di fare una nuova chiamata API.
  List<RouteData> _alternativeRoutes = [];

  /// Destinazione originale dell'utente (testo dell'indirizzo o coordinate).
  /// Salvata al momento del calcolo iniziale del percorso e usata per il
  /// ricalcolo API nel Task 2c: la destinazione non cambia mai, solo la
  /// posizione di partenza (che diventa la posizione GPS corrente).
  String? _originalDestination;

  /// Flag che indica se la navigazione è attiva.
  /// La navigazione è attiva dopo che startNavigation() è stato chiamato
  /// e fino a quando stopNavigation() o dispose() viene chiamato.
  /// Il timer di controllo percorso (ogni 2s) gira solo quando questo è true.
  bool _isNavigating = false;

  /// Flag che indica se un ricalcolo del percorso via API è in corso (Task 2c).
  /// Evita di lanciare ricalcoli concorrenti mentre il precedente è ancora
  /// in attesa di risposta dalla API.
  bool _isRerouting = false;

  // ===========================================================================
  // TIMER
  // ===========================================================================

  /// Timer periodico per il campionamento del bearing ogni 5 secondi.
  ///
  /// PERCHÉ UN TIMER PERIODICO:
  /// Vedi commento dettagliato in geo_utils.dart su kBearingUpdateIntervalSec.
  /// In breve: aggiornare direction ad ogni frame GPS causerebbe oscillazioni
  /// rapide. Un campionamento ogni 5 secondi lascia il tempo al bearing di
  /// stabilizzarsi.
  Timer? _bearingTimer;

  /// Timer del countdown di 10 secondi quando la velocità scende a zero.
  ///
  /// GESTIONE SICURA DEL TIMER:
  /// Questo timer viene:
  /// - Avviato solo se non è già attivo (evita countdown multipli)
  /// - Cancellato se la velocità torna sopra soglia (l'utente si è mosso)
  /// - Cancellato in dispose() (l'utente chiude l'app)
  ///
  /// Per evitare race condition, controlliamo sempre _zeroSpeedTimer != null
  /// prima di interagire con esso, e lo settiamo a null dopo la cancellazione.
  Timer? _zeroSpeedTimer;

  /// Timer periodico per il controllo della posizione rispetto al percorso
  /// attivo ogni kRouteCheckIntervalSec secondi (TASK 2).
  ///
  /// Questo timer è SEPARATO dal bearingTimer perché ha una frequenza diversa:
  /// - bearingTimer: ogni 5 secondi (campionamento bearing)
  /// - routeCheckTimer: ogni 2 secondi (controllo deviazione)
  ///
  /// CICLO DI VITA:
  /// - Avviato in startNavigation() quando l'utente inizia a navigare
  /// - Cancellato in stopNavigation() o dispose()
  Timer? _routeCheckTimer;

  /// Flag che indica se il blocco di analisi (steps 2.2→2.6) è in esecuzione.
  /// Evita che un secondo timer scada e lanci un'analisi concorrente mentre
  /// la prima è ancora in corso (la chiamata alla Roads API è asincrona).
  bool _isAnalysisRunning = false;

  // ===========================================================================
  // OUTPUT — NOTIFIER PER L'OVERLAY
  // ===========================================================================

  /// Notifier che emette lo stato dell'overlay da mostrare sulla mappa.
  ///
  /// La UI (NavigationScreen) ascolta questo notifier e mostra/nasconde
  /// l'overlay di conseguenza.
  ///
  /// - value = null → nessun overlay da mostrare
  /// - value = NavigationOverlayState → mostra l'overlay con il messaggio
  ///
  /// Dopo che l'overlay viene mostrato, la UI è responsabile di resettare
  /// il valore a null dopo il timeout (kOverlayAutoDismissSeconds).
  final ValueNotifier<NavigationOverlayState?> overlayNotifier =
      ValueNotifier<NavigationOverlayState?>(null);

  /// Notifier che emette il percorso attivo corrente (TASK 2).
  ///
  /// Questo notifier viene aggiornato ogni volta che il percorso attivo cambia:
  /// - Quando startNavigation() imposta il percorso iniziale (best route)
  /// - Quando Task 2b sostituisce il percorso con un alternativo
  /// - Quando Task 2c ricalcola il percorso via API
  ///
  /// La UI (NavigationScreen) ascolta questo notifier per aggiornare:
  /// - La polyline visualizzata sulla mappa
  /// - Le indicazioni passo-passo
  /// - Distanza e durata totale
  ///
  /// - value = null → nessun percorso attivo (navigazione non avviata)
  /// - value = RouteData → percorso attivo con tutti i dati
  final ValueNotifier<RouteData?> activeRouteNotifier =
      ValueNotifier<RouteData?>(null);

  /// Notifier che comunica in tempo reale alla UI l'indice dello step corrente.
  ///
  /// Questo notifier emette solo un numero intero (`int`), che rappresenta 
  /// quale passo (step) l'utente sta percorrendo. Viene usato dal NavigationScreen
  /// per cambiare l'istruzione in alto (es. "Svolta a destra tra 50m") 
  /// man mano che l'utente si sposta fisicamente.
  ///
  /// Usiamo un notifier separato (anziché forzare un setState enorme di tutto 
  /// lo schermo) per migliorare le performance. Solo il banner in alto 
  /// ascolterà questo valore per aggiornarsi fluidamente.
  final ValueNotifier<int> currentStepNotifier = ValueNotifier<int>(0);

  // ===========================================================================
  // SERVIZI
  // ===========================================================================

  /// Client per la Roads API. Iniettato nel costruttore per facilitare il testing.
  final RoadsService _roadsService;

  /// Client per la Directions API. Usato nel Task 2c per ricalcolare il percorso
  /// quando l'utente devia e nessun percorso alternativo è compatibile.
  final DirectionsService _directionsService;

  // ===========================================================================
  // COSTRUTTORE
  // ===========================================================================

  /// Crea un nuovo NavigationMonitor e avvia il timer di campionamento del bearing.
  ///
  /// PARAMETRI:
  /// - [roadsService]: (opzionale) istanza di RoadsService. Se non fornita,
  ///   ne crea una nuova. Utile per il testing (si può iniettare un mock).
  /// - [directionsService]: (opzionale) istanza di DirectionsService. Se non
  ///   fornita, ne crea una nuova. Usata per il ricalcolo percorso (Task 2c).
  NavigationMonitor({
    RoadsService? roadsService,
    DirectionsService? directionsService,
  }) : _roadsService = roadsService ?? RoadsService(),
       _directionsService = directionsService ?? DirectionsService() {
    // Avvia subito il timer periodico per il campionamento del bearing
    _startBearingTimer();
  }

  // ===========================================================================
  // METODI PUBBLICI
  // ===========================================================================

  /// Aggiorna la posizione, la velocità e il bearing raw dell'utente.
  ///
  /// Questo metodo viene chiamato ad ogni aggiornamento GPS dal listener
  /// in NavigationScreen. Gestisce:
  /// 1. Salvataggio dei valori correnti
  /// 2. Logica del trigger velocità-zero (avvio/cancellazione del timer 10s)
  ///
  /// PARAMETRI:
  /// - [lat]: latitudine corrente
  /// - [lng]: longitudine corrente
  /// - [speedKmH]: velocità corrente in km/h (già convertita da m/s)
  /// - [rawBearing]: bearing GPS raw in gradi (0-360)
  ///
  /// SIDE EFFECTS:
  /// - Aggiorna le variabili interne
  /// - Può avviare o cancellare il timer di 10 secondi
  void updatePosition(
    double lat,
    double lng,
    double speedKmH,
    double rawBearing, [
    double accuracy = 0.0,
  ]) {
    // Salva i valori correnti. Queste variabili sono usate dal timer del
    // bearing (ogni 5s) e dallo snapshot (quando il timer 10s scade).
    _currentLat = lat;
    _currentLng = lng;
    _currentSpeed = speedKmH;
    _rawBearing = rawBearing;
    _currentAccuracy = accuracy;

    // --- LOGICA TRIGGER VELOCITÀ ZERO (Step 2.1) ---
    //
    // Quando la velocità scende sotto 1 km/h, l'utente è considerato "fermo".
    // Avvia un countdown di 10 secondi. Se la velocità torna sopra soglia
    // prima dello scadere, il timer viene cancellato.
    //
    // PERCHÉ QUESTO DELAY:
    // Senza il delay, ogni breve fermata (semaforo rosso, ingorgo, precedenza)
    // attiverebbe l'analisi delle strade laterali, causando:
    // 1. Falsi positivi visivi (l'overlay appare quando non serve)
    // 2. Chiamate API inutili (ogni analisi chiama la Roads API)
    // 3. Distrazione per l'utente, che è un problema critico per un'app
    //    destinata a persone con disabilità cognitive

    if (speedKmH < kZeroSpeedThresholdKmH) {
      if (_zeroSpeedTimer == null && !_isAnalysisRunning) {
        print('⏱️ OVERLAY DEBUG: Velocità ${speedKmH.toStringAsFixed(1)} km/h < soglia. '
              'Avvio countdown ${kZeroSpeedDelayMs}ms...');
        _startZeroSpeedCountdown();
      }
    } else {
      if (_zeroSpeedTimer != null) {
        print('🏃 OVERLAY DEBUG: Velocità ${speedKmH.toStringAsFixed(1)} km/h — '
              'utente in moto, ANNULLO countdown.');
      }
      _cancelZeroSpeedCountdown();
    }

    // --- LOGICA AVANZAMENTO STEP DINAMICO ---
    //
    // Questa procedura controlla se l'utente sta raggiungendo la fine 
    // della via in cui si trova, per dirgli di compiere la svolta successiva.
    // Viene eseguita ad ogni singolo aggiornamento GPS, fintanto che
    // ci sono step validi ed è attiva una rotta.
    if (_activeRoute != null && _routeSteps.isNotEmpty) {
      // 1. Prendi lo step attuale
      // Leggiamo fisicamente dalla lista lo step in base all'indice.
      // Se _currentStepIndex è 0, stiamo guardando la primissima mossa.
      final currentStep = _routeSteps[_currentStepIndex];

      // 2. Calcola la distanza
      // Usiamo la funzione geodetica (che legge la forma del pianeta curvo)
      // per capire quanti metri passano tra la macchina (lat, lng)
      // e le coordinate di fine via (endLat e endLng di currentStep).
      final double distanceToIntersection = distanceBetween(
        lat,
        lng,
        currentStep.endLat,
        currentStep.endLng,
      );

      // 3. Controllo Prossimità (15 metri)
      // Perché 15 metri? Perché non vogliamo aspettare che tocchi 0m
      // perfetto centrale dell'incrocio, ma vogliamo che ci ronzii
      // sufficientemente vicino.
      if (distanceToIntersection < 25.0) {
        // L'utente è nei 25 metri. Incrementiamo gli "Strikes" (conferme)
        _consecutiveCloseUpdates++;

        // Richiediamo che l'utente venga letto DENTRO questo raggio
        // per almeno 1 frame GPS (era 2, ma a velocità alte si rischia di "saltarlo").
        if (_consecutiveCloseUpdates >= 1) {
          // CONFERMATO: L'utente sta svoltando all'incrocio.
          // Azzeriamo le conferme per prepararci al prossimo incrocio.
          _consecutiveCloseUpdates = 0;

          // Assicuriamoci di non sfondare il limite massimo degli array
          // (per evitare crash "Index out of range"). Se l'indice + 1 è
          // minore del totoale... 
          if (_currentStepIndex + 1 < _routeSteps.length) {
            // Avanziamo l'indice logico di uno
            _currentStepIndex++;

            // E lanciamo un segnale (Notify) ai Widget ascoltatori (il Top Banner)
            // dicendogli: "Ehi UI, il nuovo numero step è questo, disegnati con la nuova istruzione!"
            currentStepNotifier.value = _currentStepIndex;
          } else {
            // Se sono entrato qui, non ho più step successivi. 
            // Significa che questo era esplicitamente l'ultimo incrocio 
            // prima dell'arrivo a destinazione finale!
            print("🎉 Navigazione ultimata, l'utente è arrivato!");
            // Volendo qui potremmo fare trigger per mostrare "Arrivati" sull'UI.
          }
        }
      } else {
        // L'utente è a >15m di distanza. 
        // Lontano per natura, o allontanato/spostato irregolarmente.
        // Resettiamo sempre a zero le false percezioni consecutive.
        _consecutiveCloseUpdates = 0;
      }
    }
  }

  /// Aggiorna la lista degli step del percorso.
  ///
  /// Chiamato quando l'utente calcola un nuovo percorso tramite la
  /// Directions API. Gli step vengono usati nel Step 2.3 per verificare
  /// se l'utente è vicino a un waypoint di svolta.
  ///
  /// PARAMETRI:
  /// - [steps]: lista di DirectionStep dal risultato della Directions API
  void updateRouteSteps(List<DirectionStep> steps) {
    _routeSteps = steps;
  }

  /// Getter pubblico per il bearing affidabile corrente.
  /// Restituisce null se nessun bearing affidabile è stato ancora acquisito.
  double? get direction => _direction;

  /// Avvia la navigazione con i percorsi ricevuti dalla Directions API (TASK 2).
  ///
  /// Questo metodo inizializza tutto il sistema di monitoraggio del percorso:
  /// 1. Salva il percorso migliore come "attivo" (quello visualizzato sulla mappa)
  /// 2. Salva tutti i percorsi alternativi per il confronto rapido (Task 2b)
  /// 3. Salva la destinazione originale per i ricalcoli futuri (Task 2c)
  /// 4. Aggiorna gli step del percorso per il check dei waypoint di svolta
  /// 5. Avvia il timer periodico a 2 secondi per il monitoraggio
  ///
  /// PARAMETRI:
  /// - [routesResult]: risultato dalla API con tutti i percorsi
  /// - [destination]: testo della destinazione (indirizzo o coordinate)
  ///
  /// SIDE EFFECTS:
  /// - Setta _isNavigating = true
  /// - Avvia il timer _routeCheckTimer
  /// - Notifica la UI tramite activeRouteNotifier
  void startNavigation(AllRoutesResult routesResult, String destination) {
    // Salva il percorso migliore (quello con durata minore) come attivo
    _activeRoute = routesResult.bestRoute;

    // Salva TUTTI i percorsi (compreso quello attivo) per il check Task 2b.
    // Quando l'utente devia, itereremo su questa lista per cercare un
    // percorso alternativo a cui "agganciare" la posizione dell'utente.
    _alternativeRoutes = List<RouteData>.from(routesResult.allRoutes);

    // Salva la destinazione originale per il ricalcolo API (Task 2c).
    // La destinazione non cambia MAI durante la navigazione: se l'utente
    // devia, ricalcoliamo da "posizione attuale" a "stessa destinazione".
    _originalDestination = destination;

    // Aggiorna gli step per la logica di check waypoint di svolta (Step 2.3)
    _routeSteps = routesResult.bestRoute.steps;

    // Imposta il flag di navigazione attiva
    _isNavigating = true;

    // Notifica la UI che il percorso attivo è stato impostato.
    // La UI aggiornerà la polyline sulla mappa e le indicazioni.
    activeRouteNotifier.value = _activeRoute;

    // Avvia il timer periodico che ogni 2 secondi controlla se l'utente
    // è ancora sul percorso attivo (Task 2a → 2b → 2c)
    _startRouteCheckTimer();

    // Log per debugging
    print(
      'Navigazione avviata. Percorsi disponibili: '
      '${_alternativeRoutes.length}. '
      'Percorso attivo: ${_activeRoute!.totalDuration}',
    );
  }

  /// Ferma la navigazione e cancella il timer di controllo percorso.
  ///
  /// Chiamato quando l'utente vuole interrompere la navigazione
  /// o quando la navigazione raggiunge la destinazione.
  void stopNavigation() {
    // Imposta il flag a false per fermare la logica di controllo
    _isNavigating = false;

    // Cancella il timer di controllo percorso se attivo
    _routeCheckTimer?.cancel();
    _routeCheckTimer = null;

    // Resetta lo stato dei percorsi
    _activeRoute = null;
    _alternativeRoutes = [];
    _originalDestination = null;
    _consecutiveOffRouteDetects = 0;
    _routeCheckTicks = 0;
    
    // Resetta lo stato di tracciamento degli Step
    _currentStepIndex = 0;
    _consecutiveCloseUpdates = 0;
    currentStepNotifier.value = 0;

    // Notifica la UI che non c'è più un percorso attivo
    activeRouteNotifier.value = null;

    // Log per debugging
    print('Navigazione fermata.');
  }

  /// Rilascia tutte le risorse (timer, listener).
  ///
  /// DEVE essere chiamato in NavigationScreen.dispose() per evitare
  /// memory leak e timer orfani che continuano a girare dopo la
  /// distruzione del widget.
  void dispose() {
    // Cancella il timer di campionamento del bearing
    _bearingTimer?.cancel();
    _bearingTimer = null;

    // Cancella il timer di controllo percorso (TASK 2)
    _routeCheckTimer?.cancel();
    _routeCheckTimer = null;

    // Cancella il countdown velocità zero
    _cancelZeroSpeedCountdown();

    // Distrugge i notifier per evitare memory leak
    overlayNotifier.dispose();
    activeRouteNotifier.dispose();
  }

  // ===========================================================================
  // METODI PRIVATI — BEARING TIMER
  // ===========================================================================

  /// Avvia il timer periodico per il campionamento del bearing.
  ///
  /// Ogni [kBearingUpdateIntervalSec] secondi:
  /// 1. Controlla se la velocità è sopra [kSpeedThresholdKmH]
  /// 2. Se sì, aggiorna [_direction] con il bearing GPS corrente
  /// 3. Se no, non fa nulla (mantiene l'ultimo valore valido)
  ///
  /// PERCHÉ LA SOGLIA DI VELOCITÀ È NECESSARIA:
  /// Il bearing GPS è calcolato dal chip del dispositivo come la direzione
  /// del vettore di spostamento tra due punti GPS consecutivi.
  /// Quando il dispositivo è fermo o si muove molto lentamente:
  /// - Lo spostamento tra due letture è minore dell'errore GPS (~3-10m)
  /// - Il vettore di spostamento risultante è dominato dal rumore
  /// - Il bearing calcolato è essenzialmente casuale (può saltare da
  ///   0° a 180° a 270° tra letture consecutive)
  ///
  /// Richiedendo una velocità minima di 4 km/h (~1.1 m/s):
  /// - In 1 secondo l'utente si sposta di ~1.1 m
  /// - Su 5 secondi (intervallo del timer) si sposta di ~5.5 m
  /// - 5.5 m è abbastanza più grande dell'errore GPS per produrre un
  ///   bearing significativo e stabile
  void _startBearingTimer() {
    _bearingTimer = Timer.periodic(
      Duration(seconds: kBearingUpdateIntervalSec),
      (timer) {
        if (_currentSpeed >= kSpeedThresholdKmH) {
          final bool wasNull = _direction == null;
          _direction = _rawBearing;
          if (wasNull) {
            print('🧭 OVERLAY DEBUG: PRIMO bearing acquisito! '
                  'direction=$_direction° (speed=$_currentSpeed km/h). '
                  'L\'analisi overlay è ora ABILITATA.');
          }
        }
      },
    );
  }

  // ===========================================================================
  // METODI PRIVATI — ZERO SPEED COUNTDOWN
  // ===========================================================================

  /// Avvia il countdown di 10 secondi quando l'utente è fermo (Step 2.1).
  ///
  /// Quando il timer scade, esegue il blocco di analisi (Steps 2.2→2.6).
  ///
  /// GESTIONE RACE CONDITION:
  /// Il timer è un one-shot (Timer, non Timer.periodic). Quando scade:
  /// 1. _zeroSpeedTimer viene settato a null
  /// 2. Si controlla che la velocità sia ancora sotto soglia
  /// 3. Si controlla che _isAnalysisRunning sia false
  /// Solo se tutte le condizioni sono soddisfatte si procede con l'analisi.
  void _startZeroSpeedCountdown() {
    _zeroSpeedTimer = Timer(
      const Duration(milliseconds: kZeroSpeedDelayMs),
      () {
        _zeroSpeedTimer = null;

        if (_currentSpeed < kZeroSpeedThresholdKmH) {
          print('⏱️ OVERLAY DEBUG: Countdown ${kZeroSpeedDelayMs}ms SCADUTO — '
                'velocità ancora ${_currentSpeed.toStringAsFixed(1)} km/h. '
                'Lancio _executeAnalysis()...');
          _executeAnalysis();
        } else {
          print('⏱️ OVERLAY DEBUG: Countdown scaduto MA velocità è salita a '
                '${_currentSpeed.toStringAsFixed(1)} km/h — analisi SALTATA.');
        }
      },
    );
  }

  /// Cancella il countdown di 10 secondi in modo sicuro.
  ///
  /// Chiamato quando:
  /// - La velocità torna sopra soglia (l'utente si è mosso)
  /// - dispose() viene chiamato (l'app si chiude)
  ///
  /// Settare _zeroSpeedTimer = null dopo il cancel è importante per
  /// il check in updatePosition: se il timer è null, sappiamo che
  /// non c'è un countdown attivo e possiamo avviarne uno nuovo.
  void _cancelZeroSpeedCountdown() {
    _zeroSpeedTimer?.cancel();
    _zeroSpeedTimer = null;
  }

  // ===========================================================================
  // METODI PRIVATI — BLOCCO DI ANALISI (Steps 2.2 → 2.6)
  // ===========================================================================

  /// Esegue il blocco completo di analisi quando l'utente è fermo da 10 secondi.
  ///
  /// FLUSSO:
  /// Step 2.2 → Snapshot della posizione e del bearing
  /// Step 2.3 → Verifica vicinanza a waypoint di svolta
  /// Step 2.4 → Calcolo punti laterali (se non su waypoint)
  /// Step 2.5 → Chiamata Roads API
  /// Step 2.6 → Analisi risposta e emissione overlay
  ///
  /// SIDE EFFECTS:
  /// - Setta _isAnalysisRunning a true durante l'esecuzione
  /// - Può emettere un evento su overlayNotifier
  /// - Effettua una chiamata HTTP asincrona (Roads API)
  Future<void> _executeAnalysis() async {
    // Evita analisi concorrenti. Se un'analisi è già in corso (es. la
    // chiamata Roads API è lenta), non ne lanciamo una seconda.
    if (_isAnalysisRunning) {
      print('🔒 OVERLAY DEBUG: _executeAnalysis bloccata — analisi già in corso');
      return;
    }
    _isAnalysisRunning = true;
    print('🟢 OVERLAY DEBUG: _executeAnalysis AVVIATA');

    try {
      // =====================================================================
      // STEP 2.2 — ACQUISIZIONE SNAPSHOT
      // =====================================================================
      //
      // Salviamo una copia dei valori correnti IN QUESTO ESATTO ISTANTE.
      // Questo è critico perché i passi successivi sono asincroni (la chiamata
      // alla Roads API può richiedere 1-3 secondi). Durante quel tempo,
      // gli aggiornamenti GPS continuano ad arrivare e modificano _currentLat,
      // _currentLng, _direction. Se usassimo le variabili "live", potremmo
      // calcolare i punti laterali con una posizione e analizzare la risposta
      // con un'altra posizione, causando inconsistenze logiche.

      final double? snapshotLat = _currentLat;
      final double? snapshotLng = _currentLng;
      final double? snapshotDirection = _direction;

      if (snapshotLat == null || snapshotLng == null) {
        print('❌ OVERLAY DEBUG: ABORT — posizione GPS non disponibile (lat=$snapshotLat, lng=$snapshotLng)');
        return;
      }

      // =====================================================================
      // STEP 2.3 — VERIFICA VICINANZA A WAYPOINT DI SVOLTA
      // =====================================================================
      //
      // PRIMA del check bearing! Questo step ha bisogno SOLO di lat/lng,
      // non della direzione. Così l'overlay di svolta funziona anche
      // quando l'utente è fermo alla partenza e non ha mai camminato
      // (bearing ancora null).
      //
      // Controlliamo se l'utente è fermo su un punto di svolta del
      // percorso calcolato. Se sì, l'overlay mostra l'istruzione di
      // navigazione (dal campo html_instructions dello step) e usciamo.

      final turnResult = _checkNearTurnWaypoint(snapshotLat, snapshotLng);

      if (turnResult != null) {
        print('🔵 OVERLAY DEBUG: WAYPOINT DI SVOLTA RILEVATO! '
              'Messaggio: "${turnResult.message}", maneuver: ${turnResult.maneuver}');
        overlayNotifier.value = turnResult;
        return;
      }

      print('⬜ OVERLAY DEBUG: Nessun waypoint di svolta vicino '
            '(${_routeSteps.length} step controllati, raggio=${kTurnWaypointRadiusMeters}m). '
            'Procedo con analisi laterale...');

      // =====================================================================
      // CHECK BEARING — necessario SOLO per i punti laterali (step 2.4+)
      // =====================================================================
      //
      // Se direction è null, nessun bearing affidabile è stato ancora acquisito.
      // Non possiamo calcolare i punti laterali (non sappiamo dove è "destra"
      // e dove è "sinistra"). L'overlay di svolta (sopra) funziona comunque.
      // Solo la parte laterale (Roads API) resta in standby.
      if (snapshotDirection == null) {
        print('❌ OVERLAY DEBUG: ABORT analisi laterale — direction è NULL '
              '(bearing mai acquisito). Il check waypoint sopra è già passato. '
              'Cammina a ≥${kSpeedThresholdKmH} km/h per ≥${kBearingUpdateIntervalSec}s '
              'per abilitare anche il rilevamento strade laterali.');
        return;
      }

      print('📍 OVERLAY DEBUG: Snapshot acquisito — '
            'pos=($snapshotLat, $snapshotLng), bearing=$snapshotDirection°, '
            'speed=$_currentSpeed km/h');

      // L'utente NON è su un incrocio di svolta del percorso.
      // Procediamo con il rilevamento delle strade laterali.

      // =====================================================================
      // STEP 2.4 — CALCOLO DEI PUNTI LATERALI
      // =====================================================================
      //
      // Calcoliamo 10 punti attorno alla posizione dell'utente usando
      // la direction come riferimento. Vedi computeAllLateralPoints()
      // in geo_utils.dart per i dettagli sulla disposizione dei punti.

      final lateralPoints = computeAllLateralPoints(
        snapshotLat,
        snapshotLng,
        snapshotDirection,
      );

      print('📐 OVERLAY DEBUG: ${lateralPoints.length} punti laterali calcolati. '
            'Chiamo Roads API...');

      // =====================================================================
      // STEP 2.5 — CHIAMATA ROADS API
      // =====================================================================
      //
      // Inviamo tutti i 10 punti in una SINGOLA chiamata alla Roads API.
      // Questo è ottimale perché:
      // 1. Riduce la latenza (una chiamata invece di 10)
      // 2. Riduce il consumo di quota API
      // 3. La Roads API supporta fino a 100 punti per chiamata

      final snappedPoints = await _roadsService.findNearestRoads(lateralPoints);

      // =====================================================================
      // STEP 2.6 — ANALISI DELLA RISPOSTA E OUTPUT VISIVO
      // =====================================================================
      //
      // INTERPRETAZIONE DELLA RISPOSTA:
      // La Roads API restituisce `snappedPoints`: un array dei punti per cui
      // ha trovato una strada nelle vicinanze.
      //
      // - Se snappedPoints è null → la chiamata è fallita (errore di rete/API).
      //   Non facciamo nulla per non disturbare l'utente con errori.
      //
      // - Se snappedPoints è vuoto → nessuna strada laterale trovata.
      //   Questo è un CASO LEGITTIMO, non un errore. Significa che l'utente
      //   è fermo in una zona senza strade laterali (es. autostrada,
      //   campagna, zona pedonale). Non mostriamo nulla.
      //
      // - Se snappedPoints contiene almeno un elemento → c'è una strada
      //   laterale! Mostriamo l'overlay "vai diritto stronzo".
      //
      // NOTA: controlliamo la PRESENZA di elementi (isNotEmpty), non il NUMERO.
      // Anche un singolo punto snappato è sufficiente per concludere che
      // c'è una strada laterale nelle vicinanze.

      if (snappedPoints == null) {
        // Chiamata fallita — fallback silenzioso.
        print('❌ OVERLAY DEBUG: Roads API FALLITA (null). Nessun overlay mostrato.');
        return;
      }

      if (snappedPoints.isNotEmpty) {
        // Strada laterale rilevata! Mostra l'overlay.
        print('🟠 OVERLAY DEBUG: STRADA LATERALE RILEVATA! '
              '${snappedPoints.length} punti snappati. Mostro overlay arancione.');
        overlayNotifier.value = NavigationOverlayState(
          type: OverlayType.lateralRoadDetected,
          message: 'vai diritto stronzo',
        );
      } else {
        print('⬜ OVERLAY DEBUG: Roads API OK ma 0 strade trovate. Nessun overlay.');
      }
    } finally {
      // Assicuriamoci di resettare il flag anche in caso di eccezioni
      // non gestite. Il blocco finally viene eseguito SEMPRE, sia che
      // il try sia terminato normalmente, sia che sia uscito con return,
      // sia che sia stata lanciata un'eccezione.
      _isAnalysisRunning = false;
    }
  }

  /// Controlla se l'utente è vicino a un waypoint di svolta del percorso (Step 2.3).
  ///
  /// Per ogni step del percorso, calcola la distanza tra la posizione dell'utente
  /// e la end_location dello step (che è il punto di svolta). Se la distanza
  /// è inferiore a [kTurnWaypointRadiusMeters], l'utente è considerato
  /// "sull'incrocio" e viene restituita l'istruzione di navigazione.
  ///
  /// PARAMETRI:
  /// - [lat], [lng]: posizione snapshot dell'utente
  ///
  /// RETURN:
  /// - NavigationOverlayState con l'istruzione, se l'utente è vicino a un waypoint
  /// - null se l'utente non è vicino a nessun waypoint
  NavigationOverlayState? _checkNearTurnWaypoint(double lat, double lng) {
    if (_routeSteps.isEmpty) {
      print('🔍 OVERLAY DEBUG: _checkNearTurnWaypoint — 0 step nel percorso, skip.');
      return null;
    }

    double closestDistance = double.infinity;
    String closestInstruction = '';

    for (final step in _routeSteps) {
      final double distance = haversineDistance(
        lat,
        lng,
        step.endLat,
        step.endLng,
      );

      if (distance < closestDistance) {
        closestDistance = distance;
        closestInstruction = step.instruction;
      }

      if (distance <= kTurnWaypointRadiusMeters) {
        return NavigationOverlayState(
          type: OverlayType.turnInstruction,
          message: step.instruction,
          maneuver: step.maneuver,
        );
      }
    }

    print('🔍 OVERLAY DEBUG: Waypoint più vicino a ${closestDistance.toStringAsFixed(1)}m '
          '(soglia=${kTurnWaypointRadiusMeters}m) — "$closestInstruction"');

    // Nessun waypoint di svolta è abbastanza vicino
    return null;
  }

  // ===========================================================================
  // METODI PRIVATI — MONITORAGGIO PERCORSO (TASK 2)
  // ===========================================================================

  /// Avvia il timer periodico che ogni 2 secondi verifica se l'utente
  /// è ancora sul percorso attivo (TASK 2).
  ///
  /// Questo è il cuore del sistema di monitoraggio:
  /// ogni tick del timer esegue la catena di controllo Task 2a → 2b → 2c.
  ///
  /// SICUREZZA:
  /// Se il timer precedente è ancora attivo (es. startNavigation() viene
  /// chiamato due volte), lo cancelliamo prima di crearne uno nuovo
  /// per evitare timer duplicati.
  void _startRouteCheckTimer() {
    // Cancella un eventuale timer precedente per evitare duplicati
    _routeCheckTimer?.cancel();

    // Crea un nuovo timer periodico che scatta ogni kRouteCheckIntervalSec secondi
    _routeCheckTimer = Timer.periodic(Duration(seconds: kRouteCheckIntervalSec), (
      timer,
    ) {
      // Esegue il controllo solo se la navigazione è attiva.
      // Questo check è ridondante (il timer viene cancellato in stopNavigation),
      // ma aggiunge un livello di sicurezza extra.
      if (_isNavigating) {
        _onRouteCheckTick();
      }
    });
  }

  /// Callback eseguito ogni 2 secondi dal timer di controllo percorso.
  ///
  /// Implementa la logica a cascata descritta nelle specifiche:
  ///
  /// OGNI 2 SECONDI:
  /// │
  /// ├─ Posizione utente entro 40m dalla polyline attiva?
  /// │   ├─ SÌ → nessuna azione
  /// │   └─ NO → utente ha deviato
  /// │           │
  /// │           ├─ È entro 40m da un percorso alternativo?
  /// │           │   ├─ SÌ → cambia percorso attivo con quell'alternativo
  /// │           │   └─ NO → chiama API Google
  /// │           │               → salva tutti i nuovi percorsi
  /// │           │               → imposta come attivo quello con durata minore
  ///
  /// SIDE EFFECTS:
  /// - Può cambiare il percorso attivo (Task 2b)
  /// - Può effettuare una chiamata HTTP asincrona (Task 2c)
  /// - Notifica la UI tramite activeRouteNotifier se il percorso cambia
  void _onRouteCheckTick() {
    // --- PREREQUISITI ---
    // Verifica che abbiamo tutti i dati necessari prima di procedere.
    // Senza posizione o percorso attivo, non possiamo fare nessun confronto.

    // Se la posizione GPS non è ancora disponibile, saltiamo questo tick.
    // All'avvio dell'app il GPS potrebbe impiegare qualche secondo per
    // ottenere un fix.
    if (_currentLat == null || _currentLng == null) return;

    // Se non c'è un percorso attivo, non c'è nulla da controllare.
    // Questo non dovrebbe accadere se _isNavigating è true, ma è un
    // controllo di sicurezza.
    if (_activeRoute == null) return;

    // Se è già in corso un ricalcolo API (Task 2c), non lanciamo un
    // secondo controllo. Il ricalcolo è asincrono e potrebbe richiedere
    // diversi secondi.
    if (_isRerouting) return;

    // Cattura uno snapshot delle coordinate ATTUALI.
    // Questo è importante per coerenza: durante il controllo (che potrebbe
    // essere asincrono se si arriva al Task 2c), la posizione GPS continua
    // ad aggiornarsi. Usiamo lo snapshot per tutti i calcoli.
    final double lat = _currentLat!;
    final double lng = _currentLng!;

    // TASK 5 - Filtro Signal Drift basato sull'accuratezza GPS
    if (_currentAccuracy > 30.0) {
      print('⚠️ Segnale GPS debole (accuracy: ${_currentAccuracy}m). Ignoro controllo percorso.');
      return;
    }

    // TASK 5 - Adaptive Polling basato sulla velocità
    _routeCheckTicks++;
    int requiredTicks = 1; // >60km/h: ogni 2 secondi (1 tick)
    if (_currentSpeed <= 15.0) {
      requiredTicks = 3; // <=15km/h o fermo: ogni 6 secondi (3 tick)
    } else if (_currentSpeed <= 60.0) {
      requiredTicks = 2; // 15-60km/h: ogni 4 secondi (2 tick)
    }

    if (_routeCheckTicks < requiredTicks) return;
    _routeCheckTicks = 0; // Resetta i tick e procedi al controllo

    // =========================================================================
    // TASK 2a — CONFRONTO POSIZIONE CON PERCORSO ATTIVO
    // =========================================================================
    //
    // Verifica se la posizione dell'utente è entro 40 metri dalla polyline
    // del percorso attivo. Se sì, l'utente sta seguendo il percorso
    // correttamente → non facciamo nulla e aspettiamo il prossimo tick.

    // Chiama isOnRoute() che internamente:
    // 1. Calcola la distanza tra (lat, lng) e ogni punto della polyline
    // 2. Trova la distanza minima
    // 3. Confronta con la soglia di 40 metri
    final bool onActiveRoute = isOnRoute(
      lat,
      lng,
      _activeRoute!.decodedPolyline,
    );

    // Se l'utente è sul percorso, tutto OK. Nessuna azione necessaria.
    if (onActiveRoute) {
      _consecutiveOffRouteDetects = 0; // Azzera strike di deviazione
      return; // ← L'utente segue il percorso, aspettiamo il prossimo tick
    }

    // =========================================================================
    // L'UTENTE HA DEVIATO DAL PERCORSO ATTIVO!
    // =========================================================================
    //
    // La distanza minima dalla polyline attiva è > 40 metri.
    
    // TASK 5 - Strikes System (Verifica su più letture)
    _consecutiveOffRouteDetects++;
    if (_consecutiveOffRouteDetects < 2) {
      print('⚠️ Deviazione rilevata (Strike $_consecutiveOffRouteDetects). Attendo conferma...');
      return;
    }
    _consecutiveOffRouteDetects = 0; // Azzera prima del varo ricalcolo

    // Ora controlliamo se è finito su uno dei percorsi alternativi.

    // Log per debugging: segnala la deviazione confermata
    print('⚠️ Deviazione confermata! L\'utente è fuori dal percorso attivo.');

    // =========================================================================
    // TASK 2b — CONTROLLO PERCORSI ALTERNATIVI
    // =========================================================================
    //
    // Iteriamo su tutti i percorsi alternativi salvati al TASK 1.
    // Per ciascuno, verifichiamo se la posizione dell'utente è entro 40 metri
    // dalla polyline di quel percorso.
    //
    // VANTAGGI DI QUESTO APPROCCIO:
    // - Nessuna chiamata API necessaria → risparmio tempo e quota
    // - Risposta istantanea → l'utente vede subito il nuovo percorso
    // - Zero latenza di rete → funziona anche offline (con percorsi in memoria)

    for (final alternativeRoute in _alternativeRoutes) {
      // Salta il percorso attivo: lo abbiamo già controllato sopra
      // e sappiamo che l'utente NON è su di esso.
      if (alternativeRoute == _activeRoute) continue;

      // Verifica se l'utente è entro 40m dalla polyline di questo alternativo
      final bool onAlternative = isOnRoute(
        lat,
        lng,
        alternativeRoute.decodedPolyline,
      );

      if (onAlternative) {
        // =====================================================================
        // TROVATO! L'utente è su un percorso alternativo.
        // =====================================================================
        //
        // Sostituiamo il percorso attivo con questo alternativo.
        // Non effettuiamo nessuna nuova chiamata API: abbiamo già tutti
        // i dati necessari in memoria (polyline, steps, durata).

        // Log per debugging
        print(
          '✅ Percorso alternativo trovato! '
          'Durata: ${alternativeRoute.totalDuration}. '
          'Cambio percorso attivo.',
        );

        // Sostituisce il percorso attivo con l'alternativo
        _activeRoute = alternativeRoute;

        // Aggiorna gli step del percorso per il check dei waypoint di svolta
        _routeSteps = alternativeRoute.steps;

        // Siccome ci siamo agganciati magicamente al percorso di scorta, 
        // azzeriamo tutti i conteggi per fargli ricalcolare dal rigo 0 le sue istruzioni
        _currentStepIndex = 0;
        _consecutiveCloseUpdates = 0;
        currentStepNotifier.value = 0;

        // Notifica la UI che il percorso attivo è cambiato.
        // La NavigationScreen si occuperà di aggiornare:
        // - La polyline disegnata sulla mappa
        // - Le indicazioni passo-passo
        // - Distanza e durata totale nell'header
        activeRouteNotifier.value = _activeRoute;

        // Usciamo dalla funzione: abbiamo trovato un percorso compatibile,
        // non serve controllare gli altri né fare chiamate API.
        return;
      }
    }

    // =========================================================================
    // TASK 2c — RICALCOLO PERCORSO VIA API GOOGLE
    // =========================================================================
    //
    // Se siamo arrivati qui, significa che:
    // 1. L'utente NON è sul percorso attivo (Task 2a fallito)
    // 2. L'utente NON è su nessun percorso alternativo (Task 2b fallito)
    //
    // L'unica opzione rimasta è ricalcolare il percorso:
    // - Partenza: posizione GPS ATTUALE dell'utente
    // - Destinazione: la STESSA destinazione originale (non cambia mai)
    // - alternatives: true (per ricevere di nuovo percorsi alternativi)

    // Log per debugging
    print(
      '❌ Nessun percorso alternativo compatibile. '
      'Ricalcolo via API Google...',
    );

    // Lancia il ricalcolo asincrono. Non usiamo await perché siamo in un
    // callback del timer (non è async). _executeReroute() gestisce
    // internamente il flag _isRerouting per evitare ricalcoli concorrenti.
    _executeReroute(lat, lng);
  }

  /// Esegue il ricalcolo del percorso via API Google (Task 2c).
  ///
  /// Questo metodo è asincrono perché effettua una chiamata HTTP alla
  /// Directions API di Google.
  ///
  /// PARAMETRI:
  /// - [lat], [lng]: coordinate GPS dell'utente al momento della richiesta.
  ///   Queste diventano la nuova "partenza" del percorso.
  ///
  /// FLUSSO:
  /// 1. Setta _isRerouting = true per bloccare tick concorrenti
  /// 2. Chiama getDirectionsWithAlternatives() con posizione corrente
  /// 3. Se successo: aggiorna tutti i percorsi e il percorso attivo
  /// 4. Se fallimento: log dell'errore, nessuna azione (fallback silenzioso)
  /// 5. Setta _isRerouting = false
  ///
  /// SIDE EFFECTS:
  /// - Effettua una chiamata HTTP
  /// - Può aggiornare _activeRoute, _alternativeRoutes, _routeSteps
  /// - Può notificare la UI tramite activeRouteNotifier
  Future<void> _executeReroute(double lat, double lng) async {
    // Evita ricalcoli concorrenti: se un ricalcolo è già in corso,
    // non ne lanciamo un altro.
    if (_isRerouting) return;

    // Setta il flag di ricalcolo in corso
    _isRerouting = true;

    try {
      // Verifica che abbiamo la destinazione originale.
      // Senza destinazione non possiamo ricalcolare il percorso.
      if (_originalDestination == null) {
        print('Ricalcolo impossibile: destinazione originale mancante');
        return;
      }

      // Costruisce la stringa di partenza come coordinate GPS.
      // Il formato "lat,lng" è accettato dalla Directions API come
      // alternativa a un indirizzo testuale.
      final String currentOrigin = '$lat,$lng';

      // Chiama la Directions API con:
      // - origin: posizione GPS ATTUALE (dove si trova l'utente ORA)
      // - destination: la destinazione ORIGINALE (invariata)
      // - alternatives: true (incluso nel metodo)
      //
      // Questa è la STESSA logica del TASK 1: la API restituisce più
      // percorsi, li ordiniamo per durata, e selezioniamo il migliore.
      final AllRoutesResult? newResult = await _directionsService
          .getDirectionsWithAlternatives(
            origin: currentOrigin,
            destination: _originalDestination!,
          );

      // --- GESTIONE RISULTATO ---

      // Se la chiamata è fallita (errore di rete, API, ecc.),
      // non facciamo nulla. L'utente continuerà a navigare con il
      // vecchio percorso (anche se fuori rotta). Al prossimo tick
      // il sistema riproverà.
      if (newResult == null) {
        print('⚠️ Ricalcolo fallito. Riproverò al prossimo ciclo.');
        return;
      }

      // --- AGGIORNAMENTO PERCORSI (stessa logica del TASK 1) ---

      // Il percorso migliore (durata minore) diventa il nuovo attivo
      _activeRoute = newResult.bestRoute;

      // Salva tutti i nuovi percorsi per futuri check (Task 2b)
      _alternativeRoutes = List<RouteData>.from(newResult.allRoutes);

      // Aggiorna gli step per il check dei waypoint di svolta
      _routeSteps = newResult.bestRoute.steps;

      // Notifica la UI che il percorso è cambiato.
      // La NavigationScreen aggiornerà mappa, indicazioni, ecc.
      activeRouteNotifier.value = _activeRoute;

      // Log per debugging
      print(
        '✅ Ricalcolo completato! '
        'Nuovi percorsi: ${_alternativeRoutes.length}. '
        'Percorso attivo: ${_activeRoute!.totalDuration}',
      );
    } catch (e) {
      // Gestisce eccezioni non previste (parsing, rete, ecc.)
      print('❌ Eccezione durante il ricalcolo: $e');
    } finally {
      // Resetta SEMPRE il flag, anche in caso di errore.
      // Senza questo reset, il sistema resterebbe bloccato per sempre
      // (nessun nuovo ricalcolo verrebbe mai avviato).
      _isRerouting = false;
    }
  }
}
