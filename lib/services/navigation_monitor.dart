/// navigation_monitor.dart — Logica di Business per la Navigazione Assistita
///
/// Questa classe gestisce tutta la logica "intelligente" dell'app:
/// 1. Mantiene la variabile `direction` (bearing affidabile)
/// 2. Rileva quando l'utente è fermo (zero-speed trigger)
/// 3. Controlla se l'utente è su un waypoint di svolta del percorso
/// 4. Calcola i punti laterali e interroga la Roads API
/// 5. Emette eventi per l'overlay visivo
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

  /// Bearing raw corrente dal GPS (può essere inaffidabile a basse velocità).
  double _rawBearing = 0.0;

  /// Lista degli step del percorso calcolato dalla Directions API.
  /// Viene aggiornata ogni volta che l'utente calcola un nuovo percorso.
  List<DirectionStep> _routeSteps = [];

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

  // ===========================================================================
  // SERVIZI
  // ===========================================================================

  /// Client per la Roads API. Iniettato nel costruttore per facilitare il testing.
  final RoadsService _roadsService;

  // ===========================================================================
  // COSTRUTTORE
  // ===========================================================================

  /// Crea un nuovo NavigationMonitor e avvia il timer di campionamento del bearing.
  ///
  /// PARAMETRI:
  /// - [roadsService]: (opzionale) istanza di RoadsService. Se non fornita,
  ///   ne crea una nuova. Utile per il testing (si può iniettare un mock).
  NavigationMonitor({RoadsService? roadsService})
    : _roadsService = roadsService ?? RoadsService() {
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
    double rawBearing,
  ) {
    // Salva i valori correnti. Queste variabili sono usate dal timer del
    // bearing (ogni 5s) e dallo snapshot (quando il timer 10s scade).
    _currentLat = lat;
    _currentLng = lng;
    _currentSpeed = speedKmH;
    _rawBearing = rawBearing;

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
      // L'utente è fermo. Avvia il countdown SOLO se non è già attivo.
      // Controllare _zeroSpeedTimer != null evita di creare timer multipli
      // che causerebbero analisi duplicate.
      if (_zeroSpeedTimer == null && !_isAnalysisRunning) {
        _startZeroSpeedCountdown();
      }
    } else {
      // L'utente si è rimesso in moto. Cancella il countdown se era attivo.
      // Questo gestisce il caso classico: l'utente si ferma al semaforo,
      // il semaforo diventa verde dopo 5 secondi, l'utente riparte.
      // Senza questa cancellazione, il timer continuerebbe a contare e
      // l'analisi partirebbe anche se l'utente è in movimento.
      _cancelZeroSpeedCountdown();
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

  /// Rilascia tutte le risorse (timer, listener).
  ///
  /// DEVE essere chiamato in NavigationScreen.dispose() per evitare
  /// memory leak e timer orfani che continuano a girare dopo la
  /// distruzione del widget.
  void dispose() {
    _bearingTimer?.cancel();
    _bearingTimer = null;
    _cancelZeroSpeedCountdown();
    overlayNotifier.dispose();
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
        // Solo se la velocità è sopra la soglia configurabile il bearing
        // è considerato affidabile. Sotto soglia, direction mantiene
        // il suo ultimo valore valido (o resta null se mai impostato).
        if (_currentSpeed >= kSpeedThresholdKmH) {
          _direction = _rawBearing;
        }
        // Se la velocità è sotto soglia, NON aggiorniamo _direction.
        // Questo è intenzionale: preferiamo un bearing "vecchio ma buono"
        // a un bearing "nuovo ma casuale".
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
        // Il timer è scaduto. Resettiamo il riferimento al timer perché
        // non è più cancellabile (è già scaduto).
        _zeroSpeedTimer = null;

        // Doppia verifica: anche se abbiamo avviato il timer quando la
        // velocità era sotto soglia, controlliamo di nuovo. Potrebbe essere
        // cambiata nel frattempo a causa di un aggiornamento GPS arrivato
        // tra l'ultimo check e lo scadere del timer.
        if (_currentSpeed < kZeroSpeedThresholdKmH) {
          _executeAnalysis();
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
    if (_isAnalysisRunning) return;
    _isAnalysisRunning = true;

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

      // Se la posizione non è disponibile, non possiamo fare nulla.
      if (snapshotLat == null || snapshotLng == null) {
        return;
      }

      // Se direction è null, nessun bearing affidabile è stato ancora acquisito.
      // Non possiamo calcolare i punti laterali (non sappiamo dove è "destra"
      // e dove è "sinistra"). Interrompiamo l'elaborazione.
      // Le funzionalità che dipendono da direction restano in standby
      // fino a quando l'utente non si muove a velocità sufficiente.
      if (snapshotDirection == null) {
        return;
      }

      // =====================================================================
      // STEP 2.3 — VERIFICA VICINANZA A WAYPOINT DI SVOLTA
      // =====================================================================
      //
      // Controlliamo se l'utente è fermo ESATTAMENTE su un punto di svolta
      // del percorso calcolato. Se sì, l'overlay mostra l'istruzione di
      // navigazione (dal campo html_instructions dello step) e usciamo.
      //
      // COME SI NAVIGANO GLI STEP DEL JSON DELLA DIRECTIONS API:
      // La risposta della Directions API ha questa struttura:
      //   routes[0].legs[0].steps[] — array di step
      // Ogni step ha:
      //   - start_location {lat, lng} — inizio del segmento
      //   - end_location {lat, lng} — fine del segmento (= punto di svolta)
      //   - html_instructions — testo dell'istruzione (es. "Svolta a destra")
      //   - maneuver — codice della manovra (es. "turn-right")
      //
      // I PUNTI DI SVOLTA sono le end_location di ogni step: rappresentano
      // i punti dove l'utente deve cambiare direzione.

      final turnResult = _checkNearTurnWaypoint(snapshotLat, snapshotLng);

      if (turnResult != null) {
        // L'utente è vicino a un waypoint di svolta!
        // Mostra l'istruzione di navigazione e interrompi.
        overlayNotifier.value = turnResult;
        return;
      }

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
        // L'utente non viene disturbato. Meglio non mostrare nulla
        // che mostrare un'informazione potenzialmente sbagliata.
        return;
      }

      if (snappedPoints.isNotEmpty) {
        // Strada laterale rilevata! Mostra l'overlay.
        overlayNotifier.value = NavigationOverlayState(
          type: OverlayType.lateralRoadDetected,
          message: 'vai diritto stronzo',
        );
      }
      // Se snappedPoints è vuoto, non facciamo nulla. Nessun overlay.
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
    // Se non c'è un percorso calcolato, non possiamo controllare nulla
    if (_routeSteps.isEmpty) return null;

    for (final step in _routeSteps) {
      // Calcola la distanza tra la posizione dell'utente e la end_location
      // dello step. La end_location è il punto dove termina il segmento
      // corrente e inizia il segmento successivo — ovvero il punto dove
      // l'utente deve cambiare direzione.
      final double distance = haversineDistance(
        lat,
        lng,
        step.endLat,
        step.endLng,
      );

      // Se la distanza è inferiore al raggio configurabile (default 5m),
      // l'utente è considerato "sul" waypoint di svolta.
      if (distance <= kTurnWaypointRadiusMeters) {
        // L'utente è fermo esattamente su un punto di svolta del percorso!
        // Mostra l'istruzione di navigazione testuale presa da html_instructions.
        //
        // Usiamo step.instruction (che è il campo html_instructions ripulito
        // dai tag HTML) come testo dell'overlay, così l'utente legge
        // esattamente l'istruzione che la Directions API ha fornito per
        // questo specifico punto del percorso.
        return NavigationOverlayState(
          type: OverlayType.turnInstruction,
          message: step.instruction,
          maneuver: step.maneuver,
        );
      }
    }

    // Nessun waypoint di svolta è abbastanza vicino
    return null;
  }
}
