/// NavigationScreen - Schermata principale dell'app di navigazione
///
/// Questa schermata combina tutti i widget (mappa, input ricerca, lista indicazioni,
/// overlay di navigazione) e gestisce lo state dell'applicazione.
///
/// RESPONSABILITÀ:
/// - Gestisce il ciclo di vita dei controller e dei servizi
/// - Riceve gli aggiornamenti GPS e li inoltra al NavigationMonitor
/// - Reagisce agli eventi del NavigationMonitor mostrando/nascondendo l'overlay
/// - Coordina l'interazione tra la UI e la logica di business
///
/// THREAD SAFETY:
/// Tutti gli aggiornamenti GPS arrivano tramite Stream che Flutter gestisce
/// sul main isolate. Quindi tutte le operazioni qui sono thread-safe per design:
/// non ci sono accessi concorrenti alle variabili di stato.
library;

import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:flutter_compass/flutter_compass.dart';
import '../models/search_history_item.dart';
import '../services/directions_service.dart';
import '../services/navigation_monitor.dart';
import '../services/search_history_service.dart';
import '../services/geo_utils.dart';
import '../services/places_service.dart';
import '../services/navigation_history_service.dart';
import 'dart:io' show Platform;
import 'package:flutter/services.dart';
import '../widgets/map_widget.dart';
import '../widgets/search_input.dart';
import '../widgets/directions_list.dart';
import '../widgets/navigation_overlay.dart';

/// Stati dell'interfaccia utente (UI)
enum NavigationAppState {
  search, // Barra di ricerca visibile, mappa vuota
  placeSelected, // Luogo selezionato: mostriamo il bottom sheet con Indicationi/Avvia
  routePreview, // "Indicazioni" cliccato: mostriamo sheet scorrevole e tracciamo il percorso
  navigating, // "Avvia" cliccato: navigazione attiva, UI minimale con banner superiore
}

/// Schermata principale per la navigazione
class NavigationScreen extends StatefulWidget {
  const NavigationScreen({super.key});

  @override
  State<NavigationScreen> createState() => _NavigationScreenState();
}

class _NavigationScreenState extends State<NavigationScreen> {
  // ===========================================================================
  // CONTROLLER E SERVIZI
  // ===========================================================================

  /// Controller per il campo di testo della destinazione.
  /// Viene passato al SearchInput e usato per mostrare/leggere l'indirizzo.
  final TextEditingController _destinationController = TextEditingController();

  /// GlobalKey per accedere ai metodi del MapWidget (followUser, moveToLocation).
  final GlobalKey<MapWidgetState> _mapKey = GlobalKey<MapWidgetState>();

  /// Servizio per le direzioni (Directions API)
  final DirectionsService _directionsService = DirectionsService();

  /// Servizio per la memoria delle ultime ricerche.
  final SearchHistoryService _searchHistoryService = SearchHistoryService();

  /// Servizio Places API per reverse geocoding (nome del posto da coordinate).
  final PlacesService _placesService = PlacesService();

  final FlutterTts _tts = FlutterTts();
  bool _ttsEnabled = true;

  // ===========================================================================
  // FIX BUG 3 — TTS QUEUE CON DEDUP, PRIORITÀ E AWAIT-COMPLETION
  // ===========================================================================
  //
  // Il vecchio _speak() chiamava `stop()` e poi `speak()` in sequenza ad ogni
  // richiesta. Su iOS questo causa una race condition documentata di
  // flutter_tts: stop()→speak() troppo ravvicinati possono ingoiare la
  // seconda chiamata, lasciando l'utente senza voce. Inoltre, con tre
  // sorgenti TTS indipendenti (overlay, step, reroute) le frasi si
  // troncavano/sovrapponevano.
  //
  // NUOVO MECCANISMO: tutte le richieste passano per _enqueueSpeech, che:
  //  1. Deduplica le richieste identiche emesse entro 5s (chiave dedupKey).
  //  2. Permette interruzioni SOLO se la nuova richiesta ha priorità
  //     strettamente superiore (criticality ladder).
  //  3. Usa awaitSpeakCompletion(true) + completionHandler per processare
  //     una sola pending alla volta — niente più troncamenti casuali.

  /// Ultimo messaggio effettivamente parlato (usato come dedup key).
  String? _lastSpokenText;

  /// Timestamp dell'ultima emissione effettiva (per dedup temporale).
  DateTime? _lastSpokenAt;

  /// Flag: vero finché TTS sta pronunciando una frase.
  /// Impostato in _speakNow, resettato dal completion/cancel handler.
  bool _isSpeaking = false;

  /// Richiesta in attesa: viene eseguita appena la corrente termina.
  /// Sostituita se ne arriva una di pari o maggior priorità.
  _SpeechRequest? _pendingSpeech;

  /// FIX BUG 3 (B3.3): ultimo indice di step già annunciato vocalmente.
  /// Permette di rilevare i "multi-skip" (avanzamento di > 1 step in un
  /// solo GPS tick) e annunciare l'istruzione che sarebbe stata saltata.
  /// -1 = nessuna istruzione ancora annunciata in questa sessione.
  int _lastAnnouncedStep = -1;

  /// FIX BUG 4 (B4.5): timestamp dell'ultimo avanzamento step. Usato dal
  /// banner per mostrare la "fase di rinforzo post-svolta" per N secondi
  /// (vedi `_kPostTurnReinforcementWindow`): subito dopo aver svoltato,
  /// invece di mostrare la prossima manovra (che spesso è a 100m+ di
  /// distanza), mostriamo "Bravo! <istruzione step corrente>" — coerente
  /// con la prosa positiva di kTurnEncouragementPrefixes.
  DateTime? _lastStepAdvanceAt;

  /// Durata della finestra di rinforzo post-svolta. Valore scelto come
  /// compromesso tra: dare all'utente conferma che ha svoltato bene
  /// (4s sono sufficienti per leggere e elaborare) e tornare in tempo
  /// utile a mostrare la prossima manovra (i passi pedonali sono spesso
  /// 50-200m, percorsi in 30s-2min — 4s di "delay" sull'istruzione
  /// successiva sono trascurabili).
  static const Duration _kPostTurnReinforcementWindow = Duration(seconds: 4);

  /// Timer che forza un rebuild quando termina la finestra di rinforzo.
  /// Senza questo, il banner mostrerebbe "Bravo!" per sempre finché un
  /// altro evento non triggerasse setState.
  Timer? _postTurnRebuildTimer;

  Future<void> _initTts() async {
    await _tts.setLanguage('it-IT');
    // FIX BUG 3: speech rate abbassato da 0.85 → 0.5 per rendere le
    // istruzioni vocali più comprensibili ad utenti con disabilità cognitive.
    // 0.5 è un ritmo lento-naturale, intorno a 150-180 parole/minuto.
    await _tts.setSpeechRate(0.5);
    await _tts.setVolume(1.0);
    await _tts.setPitch(1.0);
    // FIX BUG 3 (B3.5): senza awaitSpeakCompletion il completion handler non
    // scatta su iOS → la coda non avanza. Con true, _tts.speak ritorna solo
    // quando la frase è completata oppure cancellata.
    await _tts.awaitSpeakCompletion(true);
    _tts.setCompletionHandler(_onTtsCompleted);
    _tts.setCancelHandler(_onTtsCancelled);
    _tts.setErrorHandler((_) => _onTtsCancelled());
  }

  void _onTtsCompleted() {
    _isSpeaking = false;
    _processPendingSpeech();
  }

  void _onTtsCancelled() {
    _isSpeaking = false;
    // Non processiamo la pending: l'interruzione è stata voluta.
  }

  /// API pubblica per richiedere una frase vocale. Tutti i siti che prima
  /// chiamavano _speak() ora usano questa.
  ///
  /// - [text]: il testo da pronunciare.
  /// - [priority]: serve per decidere se interrompere una frase in corso.
  /// - [dedupKey]: chiave logica per il dedup (default = text). Permette di
  ///   marcare frasi semanticamente identiche con prefissi random come
  ///   "una sola istruzione" (es. dedupKey="step-3").
  void _enqueueSpeech(
    String text, {
    SpeechPriority priority = SpeechPriority.normal,
    String? dedupKey,
  }) {
    if (!_ttsEnabled) return;
    final String key = dedupKey ?? text;

    // Dedup temporale: se abbiamo già detto questa cosa < 5s fa, skip.
    // Eccezione: critical bypassa SEMPRE il dedup (es. arrivo).
    final bool withinDedupWindow = _lastSpokenText == key &&
        _lastSpokenAt != null &&
        DateTime.now().difference(_lastSpokenAt!) <
            const Duration(seconds: 5);
    if (withinDedupWindow && priority != SpeechPriority.critical) {
      return;
    }

    final request = _SpeechRequest(text: text, priority: priority, dedupKey: key);

    if (!_isSpeaking) {
      _speakNow(request);
      return;
    }

    // C'è una frase in corso. Decidiamo se interrompere.
    final SpeechPriority currentPriority =
        _pendingSpeech?.priority ?? SpeechPriority.normal;
    if (priority.index > currentPriority.index) {
      // Più importante della corrente → interrompiamo (cancel handler
      // resetta _isSpeaking) e parliamo subito.
      _pendingSpeech = null;
      _tts.stop();
      _speakNow(request);
    } else {
      // Pari o minore importanza → aspetta che la corrente finisca.
      // Sostituiamo la pending solo se la nuova è più importante della
      // pending precedente (le richieste di priorità superiore prevalgono).
      if (_pendingSpeech == null ||
          priority.index >= _pendingSpeech!.priority.index) {
        _pendingSpeech = request;
      }
    }
  }

  Future<void> _speakNow(_SpeechRequest req) async {
    _isSpeaking = true;
    _lastSpokenText = req.dedupKey;
    _lastSpokenAt = DateTime.now();
    await _tts.speak(req.text);
  }

  void _processPendingSpeech() {
    final pending = _pendingSpeech;
    _pendingSpeech = null;
    if (pending == null) return;
    if (!_ttsEnabled) return;
    _speakNow(pending);
  }

  /// Reset completo dello stato TTS — chiamato in transizioni di stato
  /// (start/stop navigation, dispose). Vedi B3.6.
  ///
  /// FIX BUG 4 (B4.5): resetta anche la finestra di rinforzo post-svolta
  /// così il banner non mostra "Bravo!" all'avvio di una nuova navigazione
  /// se l'ultima sessione si era chiusa durante la finestra di rinforzo.
  Future<void> _resetTtsState() async {
    _pendingSpeech = null;
    _lastSpokenText = null;
    _lastSpokenAt = null;
    _lastAnnouncedStep = -1;
    _lastStepAdvanceAt = null;
    _postTurnRebuildTimer?.cancel();
    _postTurnRebuildTimer = null;
    await _tts.stop();
    _isSpeaking = false;
  }

  /// Nodo di focus per il campo di testo della destinazione.
  /// Controllato qui per poter chiudere la testiera da _handleBack o _onMapTapped.
  final FocusNode _searchFocusNode = FocusNode();

  /// Monitor di navigazione — gestisce tutta la logica di business:
  /// bearing affidabile, trigger velocità zero, analisi strade laterali.
  /// Viene inizializzato in initState() e distrutto in dispose().
  late final NavigationMonitor _navigationMonitor;

  /// Servizio per la gestione della cronologia di navigazione (Back Stack).
  late final NavigationHistoryService<NavigationAppState> _historyService;

  // ===========================================================================
  // STATO DELL'APP
  // ===========================================================================

  /// Risultato del calcolo percorso dalla Directions API.
  /// Mantenuto per compatibilità con i widget che usano DirectionsResult
  /// (MapWidget, DirectionsList).
  DirectionsResult? _directionsResult;

  /// Risultato completo con tutti i percorsi alternativi (TASK 1).
  /// Usato per passare i percorsi al NavigationMonitor.
  AllRoutesResult? _allRoutesResult;

  /// Indirizzo / Testo della destinazione selezionata.
  String? _selectedDestinationAddress;

  /// Stato attuale della UI
  NavigationAppState _appState = NavigationAppState.search;

  /// Flag di caricamento per il calcolo del percorso
  bool _isLoading = false;

  /// Messaggio di errore (null se nessun errore)
  String? _errorMessage;

  /// Durata di visibilità del banner errore.
  static const Duration _errorBannerDuration = Duration(seconds: 2);

  /// Timer per nascondere automaticamente il banner errore.
  Timer? _errorBannerTimer;

  // ===========================================================================
  // STATO GPS — VARIABILI IN TEMPO REALE
  // ===========================================================================

  /// Subscription allo stream di posizione GPS.
  /// Viene cancellata in dispose() per evitare memory leak.
  StreamSubscription<Position>? _positionStream;

  /// Timer di "silenzio GPS": si avvia ad ogni aggiornamento GPS e viene
  /// cancellato e riavviato al successivo. Se scade (nessun nuovo update
  /// arriva entro N secondi, perché distanceFilter:2 sopprime le notifiche
  /// da fermo), azzera _currentSpeed a 0.0 e notifica il NavigationMonitor.
  ///
  /// PERCHÉ QUESTO RISOLVE IL BUG:
  /// Con distanceFilter=2, il chip GPS smette di emettere eventi quando
  /// l'utente è fermo. Senza questo timer, _currentSpeed rimane "congelata"
  /// all'ultima velocità di marcia (es. 3.5 km/h), impedendo al monitor
  /// di avviare il countdown dell'overlay arancione.
  Timer? _gpsTimeoutTimer;

  /// Secondi di silenzio GPS dopo i quali la velocità viene azzerata.
  static const int _gpsTimeoutSeconds = 3;

  /// Velocità corrente dell'utente in km/h (filtrata con EMA).
  ///
  /// Calcolata con approccio CHIP-FIRST:
  /// 1. Se il chip GPS riporta position.speed > 0 → usa quello (più preciso)
  /// 2. Se position.speed == 0 → l'utente è fermo. Usa il calcolo manuale
  ///    SOLO come fallback se mostra velocità > 5 km/h (chip non supporta speed)
  /// 3. In tutti i casi il valore viene poi smorzato con un filtro EMA
  double _currentSpeed = 0.0;

  /// Fattore di smoothing per il filtro EMA (Exponential Moving Average).
  ///
  /// Formula: filteredSpeed = α × rawSpeed + (1 - α) × filteredSpeed_precedente
  ///
  /// α = 0.4 → buon compromesso: reagisce in 2-3 frame (~1-2 secondi con
  /// distanceFilter=2), ma smorza abbastanza i picchi di drift da fermo.
  static const double _speedEmaAlpha = 0.4;

  /// Soglia minima di intervallo temporale (secondi) tra due aggiornamenti
  /// GPS per il calcolo manuale della velocità.
  ///
  /// Se due aggiornamenti arrivano troppo ravvicinati (es. < 0.5s),
  /// la distanza tra le due posizioni è dominata dall'errore GPS e il
  /// rapporto distanza/tempo produce velocità assurde (es. 50 km/h per
  /// un drift di 3 metri in 0.2 secondi). Scartiamo questi campioni.
  static const double _minTimeDeltaSec = 0.5;

  /// Posizione corrente dell'utente (latitudine).
  double? _currentLat;

  /// Posizione corrente dell'utente (longitudine).
  double? _currentLng;

  /// Posizione GPS PRECEDENTE — per calcolo velocità manuale.
  /// Salvata alla fine di ogni aggiornamento GPS. Al prossimo aggiornamento,
  /// calcoliamo la distanza tra la posizione precedente e quella nuova
  /// e dividiamo per il tempo trascorso.
  double? _prevLat;
  double? _prevLng;

  /// Timestamp dell'aggiornamento GPS precedente (epoch).
  /// Usiamo position.timestamp (quando il chip ha preso la lettura)
  /// e non DateTime.now() (quando Flutter l'ha ricevuta), perché il
  /// secondo include latenza variabile di delivery dall'OS.
  DateTime? _prevTimestamp;

  /// Bearing raw del GPS (gradi 0-360).
  /// Questo è il bearing grezzo fornito dal sensore GPS. È INAFFIDABILE
  /// a basse velocità (< 4 km/h) perché il GPS non riesce a calcolare
  /// un vettore di spostamento significativo quando il dispositivo è fermo.
  ///
  /// Il NavigationMonitor si occupa di filtrare questo valore e di
  /// aggiornare la propria variabile `direction` solo quando il bearing
  /// è affidabile (velocità sopra soglia).
  double _rawBearing = 0.0;

  // ===========================================================================
  // STATO BUSSOLA — ORIENTAMENTO FISICO DEL TELEFONO
  // ===========================================================================

  /// Subscription allo stream della bussola (magnetometro).
  /// Fornisce l'orientamento fisico del telefono rispetto al nord magnetico.
  /// A differenza del bearing GPS (che indica la DIREZIONE DI MARCIA),
  /// la bussola indica DOVE IL TELEFONO È GIRATO — anche da fermo.
  ///
  /// Viene cancellata in dispose() per evitare memory leak.
  StreamSubscription<CompassEvent>? _compassStream;

  /// Heading della bussola in gradi (0-360, 0=Nord magnetico).
  ///
  /// Questo valore viene passato al MapWidget come `userBearing` per
  /// ruotare la freccia arancione nella direzione in cui l'utente tiene
  /// il telefono. Così l'utente vede:
  /// - La freccia punta dove sta guardando (bussola)
  /// - Il corridoio verde mostra dove deve andare (percorso)
  /// - Se i due non coincidono → deve girarsi
  double _compassHeading = 0.0;

  // ===========================================================================
  // STATO OVERLAY DI NAVIGAZIONE
  // ===========================================================================

  /// Stato corrente dell'overlay di navigazione.
  /// null = nessun overlay da mostrare.
  /// Non-null = mostra l'overlay con il messaggio specificato.
  NavigationOverlayState? _overlayState;

  /// FIX BUG 1 + BUG 2 — Progresso in tempo reale del percorso.
  ///
  /// Aggiornato dal listener su `_navigationMonitor.progressNotifier`.
  /// Contiene:
  /// - distanza residua stimata (per il bottom sheet "tempo + km")
  /// - tempo residuo stimato (idem)
  /// - distanza dinamica alla prossima svolta (per il banner verde)
  ///
  /// È null all'avvio e durante gli stati non-navigazione.
  RouteProgress? _progress;

  // ===========================================================================
  // STATO RICALCOLO PERCORSO — Bottom Sheet animato
  // ===========================================================================

  /// Fase corrente del processo di ricalcolo (none/offRoute/rerouting/routeChanged).
  /// Guida la visualizzazione del bottom sheet di ricalcolo.
  ReroutePhase _reroutePhase = ReroutePhase.none;

  /// Step dell'animazione progressiva "Va tutto bene" (0, 1, 2).
  /// - 0: solo mascotte + "Va tutto bene."
  /// - 1: + "Sembra che il percorso sia cambiato."
  /// - 2: + pulsanti "Mostra il nuovo percorso" / "Controllo la mappa"
  int _routeChangedAnimStep = 0;

  /// Timer per l'animazione progressiva del bottom sheet "Va tutto bene".
  /// Ogni step appare dopo un delay per non sovraccaricare il ragazzo
  /// con troppe informazioni contemporaneamente.
  Timer? _routeChangedAnimTimer;

  // ===========================================================================
  // STATO ARRIVO A DESTINAZIONE — Bottom Sheet animato
  // ===========================================================================

  /// Flag: true quando l'utente ha raggiunto la destinazione.
  /// Quando è true, la UI mostra il bottom sheet di arrivo al posto
  /// del banner di navigazione e del bottom sheet navigazione.
  bool _isArrived = false;

  /// Step dell'animazione progressiva arrivo (0, 1, 2).
  /// - 0: solo checkmark + "Sei arrivato."
  /// - 1: + "Hai seguito il percorso con attenzione."
  /// - 2: + "Vuoi rivedere il percorso?" (link cliccabile)
  int _arrivalAnimStep = 0;

  /// Timer per l'animazione progressiva del bottom sheet arrivo.
  Timer? _arrivalAnimTimer;

  // ===========================================================================
  // TRACKING PERCORSO EFFETTUATO — GPS breadcrumb
  // ===========================================================================

  /// Lista di coordinate GPS registrate durante la navigazione.
  /// Ogni posizione viene aggiunta ad ogni aggiornamento GPS (~500ms)
  /// quando la navigazione è attiva. Usata per mostrare il percorso
  /// effettivamente camminato nella review post-arrivo.
  ///
  /// FILTRAGGIO: salviamo un punto solo se distante almeno 5 metri
  /// dal precedente per evitare di accumulare migliaia di punti
  /// quando l'utente è fermo (il GPS jitter genera punti ravvicinatissimi).
  List<LatLng> _walkedPath = [];

  /// Flag: true quando l'utente sta rivedendo il percorso effettuato.
  /// In questo stato la mappa mostra sia il percorso pianificato (blu)
  /// sia il percorso camminato (verde), con vista panoramica.
  bool _isReviewingWalkedPath = false;

  /// Flag "follow-mode": quando true, la camera insegue automaticamente
  /// la posizione GPS dell'utente ad ogni aggiornamento, orientata nella
  /// direzione di marcia (bearing).
  bool _isFollowingUser = false;

  /// Ultimo bearing applicato alla camera (gradi 0-360).
  /// Aggiornato ogni volta che si chiama followUser() o snapToRoute(),
  /// così _applyGradualBearing() può calcolare la differenza di rotazione
  /// rispetto alla posizione REALE della camera (non rispetto al GPS bearing).
  double _cameraBearing = 0.0;

  /// FIX BUG 1: ultima posizione (lat/lng) effettivamente inviata alla camera
  /// con followUser(). Usata da _followCameraThrottled() per evitare di
  /// chiamare animateCamera quando né bearing né posizione sono cambiati
  /// abbastanza da giustificare una nuova animazione (le animazioni
  /// sovrapposte di Google Maps si annullano a vicenda → effetto "scatti").
  double? _lastAppliedLat;
  double? _lastAppliedLng;

  /// FIX BUG 2 (B2.3): timer cancellabile per il completamento della
  /// rotazione graduale (>90°). Prima usavamo Future.delayed che non si
  /// può cancellare: se durante i 500ms intermedi arrivava una nuova
  /// chiamata a _applyGradualBearing (es. tap multiplo su IO o GPS update
  /// con bearing molto diverso), il vecchio Future.delayed atterrava
  /// comunque su un target ormai obsoleto, facendo oscillare la camera.
  Timer? _gradualRotationCompletionTimer;

  /// Flag per il primo fix GPS. Al primo aggiornamento GPS valido,
  /// spostiamo la camera sulla posizione reale dell'utente.
  bool _hasInitialFix = false;

  // ===========================================================================
  // CRONOLOGIA RICERCHE
  // ===========================================================================

  /// Ultime 3 ricerche recenti caricate da SearchHistoryService.
  /// Vengono mostrate nel SearchInput quando il campo di testo è vuoto.
  List<SearchHistoryItem> _recentSearches = [];

  // ===========================================================================
  // CICLO DI VITA
  // ===========================================================================

  @override
  void initState() {
    super.initState();

    // Crea il NavigationMonitor che gestisce tutta la logica di business
    _navigationMonitor = NavigationMonitor();

    // Inizializza il servizio di cronologia e imposta lo stato radice
    _historyService = NavigationHistoryService<NavigationAppState>();
    _historyService.clearToRoot(NavigationAppState.search);

    // Ascolta gli eventi del NavigationMonitor per mostrare/nascondere l'overlay.
    // Quando il monitor emette un nuovo stato (es. "Continua dritto!"),
    // aggiorniamo la UI per mostrare l'overlay corrispondente.
    _navigationMonitor.overlayNotifier.addListener(_onOverlayChanged);

    // Ascolta i cambiamenti del percorso attivo (TASK 2).
    // Quando il monitor cambia percorso (Task 2b: switch ad alternativo,
    // Task 2c: ricalcolo API), questo listener aggiorna la UI.
    _navigationMonitor.activeRouteNotifier.addListener(_onActiveRouteChanged);

    // Ascolta le fasi del ricalcolo percorso per mostrare il bottom sheet
    // animato ("Ricalcolo in corso..." → "Va tutto bene").
    _navigationMonitor.reroutePhaseNotifier.addListener(_onReroutePhaseChanged);

    // Ascolta il cambio di step corrente per aggiornare le polyline segmentate.
    // Quando il monitor avanza allo step successivo (es. l'utente ha completato
    // una svolta), il MapWidget deve spostare il "corridoio verde" al nuovo
    // segmento del percorso.
    _navigationMonitor.currentStepNotifier.addListener(_onStepChanged);

    // FIX BUG 1 + BUG 2 — Ascolta il progresso in tempo reale del percorso.
    // Il monitor pubblica ad ogni GPS tick:
    //  - distanza/tempo residui totali → bottom sheet di navigazione
    //  - distanza dinamica alla prossima svolta → banner verde in alto
    _navigationMonitor.progressNotifier.addListener(_onProgressChanged);

    // Avvia il monitoraggio della posizione GPS
    _initLocationMonitoring();

    // Avvia il monitoraggio della bussola (magnetometro)
    _initCompass();

    // Carica le ultime 3 ricerche recenti dalla cronologia persistente
    _loadRecentSearches();
    _initTts();
  }

  // ===========================================================================
  // CRONOLOGIA RICERCHE
  // ===========================================================================

  /// Carica le ultime 3 ricerche dalla cronologia e aggiorna lo stato.
  /// Viene chiamato in initState() e dopo ogni selezione destinazione,
  /// così la lista è sempre aggiornata.
  Future<void> _loadRecentSearches() async {
    try {
      final history = await _searchHistoryService.loadHistory();
      if (!mounted) return;
      setState(() {
        // Prendiamo solo le prime 3 (loadHistory già ordina per timestamp desc)
        _recentSearches = history.take(3).toList();
      });
    } catch (e) {
      print('⚠️ Errore caricamento ricerche recenti: $e');
      if (mounted) {
        setState(() {
          _recentSearches = [];
        });
      }
    }
  }

  // ===========================================================================
  // BUSSOLA — ORIENTAMENTO FISICO DEL TELEFONO
  // ===========================================================================

  /// Inizializza lo stream della bussola (magnetometro).
  ///
  /// La bussola fornisce l'orientamento del telefono rispetto al nord
  /// magnetico. Questo è diverso dal bearing GPS:
  /// - Bearing GPS = direzione di MARCIA (serve velocità > 0)
  /// - Bussola = dove il telefono PUNTA (funziona anche da fermo)
  ///
  /// Per utenti con disabilità cognitive, la bussola è fondamentale:
  /// il ragazzo tiene il telefono davanti a sé, e la freccia arancione
  /// sulla mappa punta esattamente dove sta guardando. Se la freccia
  /// non è allineata col corridoio verde → deve girarsi.
  ///
  /// FALLBACK: Se il dispositivo non ha un magnetometro (raro ma possibile),
  /// FlutterCompass.events è null e _compassHeading resta a 0.
  /// In quel caso la freccia punta sempre a nord — non ideale ma non
  /// catastrofico, perché l'utente ha comunque il banner direzionale.
  void _initCompass() {
    _compassStream = FlutterCompass.events?.listen((CompassEvent event) {
      if (event.heading != null && mounted) {
        setState(() {
          // FIX: Normalizza a 0-360. Alcuni dispositivi restituiscono
          // heading da -180 a 180 invece di 0-360, causando rotazione
          // errata della freccia sulla mappa.
          _compassHeading = (event.heading! + 360) % 360;
        });
      }
    });

    if (_compassStream == null) {
      print('⚠️ Bussola non disponibile su questo dispositivo. '
          'La freccia userà il bearing GPS come fallback.');
    }
  }

  /// Callback chiamato quando il NavigationMonitor emette un nuovo stato overlay.
  ///
  /// Questo listener è il PONTE tra la logica di business (NavigationMonitor)
  /// e la UI (widget overlay). Il monitor decide QUANDO e COSA mostrare,
  /// questo callback si limita a propagare la decisione alla UI.
  ///
  /// FIX: Ora controlla che la navigazione sia effettivamente attiva prima
  /// di propagare l'overlay. Prima, se il timer di 10s nel monitor scadeva
  /// DOPO che l'utente aveva premuto "Termina", l'overlay appariva comunque
  /// sullo schermo di ricerca perché questo callback non filtrava lo stato.
  void _onOverlayChanged() {
    // Se la navigazione non è attiva, ignoriamo l'evento.
    // Questo gestisce il caso in cui un timer interno del monitor
    // (es. _zeroSpeedTimer) scade DOPO lo stop della navigazione.
    if (_appState != NavigationAppState.navigating) {
      return;
    }

    final newState = _navigationMonitor.overlayNotifier.value;

    // =====================================================================
    // INTERCETTA ARRIVO A DESTINAZIONE
    // =====================================================================
    // Se il monitor ha emesso un arrivalCelebration, NON mostriamo il
    // solito overlay banner ma passiamo allo stato "arrivato" con
    // il bottom sheet animato progressivo (come per il ricalcolo).
    //
    // FIX: Controlliamo _isArrived per evitare di riavviare l'animazione.
    // Prima, ogni aggiornamento GPS entro la soglia riemetteva l'evento,
    // resettando il timer e impedendo a step 2 ("Rivedi percorso") di
    // apparire. Ora il monitor emette una sola volta (flag _hasArrived),
    // ma per sicurezza aggiungiamo anche un guard qui nella UI.
    if (newState?.type == OverlayType.arrivalCelebration) {
      if (_isArrived) return; // Già in stato arrivo, non resettare l'animazione
      setState(() {
        _isArrived = true;
        _overlayState = null; // Non mostrare il banner overlay vecchio
      });
      // FIX BUG 3: arrivo è critico — bypassa dedup, interrompe altre frasi.
      _enqueueSpeech(
        newState!.message,
        priority: SpeechPriority.critical,
        dedupKey: 'arrival',
      );
      _startArrivalAnimation();
      return;
    }

    setState(() {
      _overlayState = newState;
    });
    if (newState != null) {
      // FIX BUG 3: priorità per tipo di overlay.
      //  - turnInstruction: important (guida la marcia)
      //  - returnToRoute: important (utente sta tornando sul percorso)
      //  - lateralRoadDetected: background (informativo, non urgente)
      // dedupKey usa solo type + tipo di azione per evitare ripetizioni
      // anche quando il prefisso random cambia il messaggio.
      final SpeechPriority priority;
      switch (newState.type) {
        case OverlayType.turnInstruction:
        case OverlayType.returnToRoute:
          priority = SpeechPriority.important;
          break;
        case OverlayType.lateralRoadDetected:
          priority = SpeechPriority.background;
          break;
        case OverlayType.arrivalCelebration:
          priority = SpeechPriority.critical;
          break;
      }
      // dedupKey: type + maneuver garantisce che la stessa svolta non venga
      // ridetta entro la finestra anche se il prefisso random cambia.
      final String dedupKey =
          '${newState.type.name}:${newState.maneuver ?? newState.message}';
      _enqueueSpeech(newState.message, priority: priority, dedupKey: dedupKey);
    }
  }

  /// Callback chiamato quando la fase di ricalcolo cambia nel monitor.
  ///
  /// Gestisce la transizione tra le fasi del bottom sheet:
  /// - offRoute/rerouting → mostra "Ricalcolo in corso..."
  /// - routeChanged → avvia animazione progressiva "Va tutto bene"
  /// - none → nasconde il bottom sheet
  void _onReroutePhaseChanged() {
    if (_appState != NavigationAppState.navigating) return;

    final phase = _navigationMonitor.reroutePhaseNotifier.value;

    setState(() {
      _reroutePhase = phase;
    });

    switch (phase) {
      case ReroutePhase.offRoute:
      case ReroutePhase.rerouting:
        // FIX BUG 3: dedupKey condiviso tra offRoute e rerouting così non
        // ridiciamo la stessa frase quando si transita tra le due fasi.
        _enqueueSpeech(
          'Sto cercando una strada migliore',
          priority: SpeechPriority.normal,
          dedupKey: 'rerouting',
        );
        break;
      case ReroutePhase.routeChanged:
        _enqueueSpeech(
          'Va tutto bene. Il percorso è cambiato.',
          priority: SpeechPriority.important,
          dedupKey: 'routeChanged',
        );
        break;
      case ReroutePhase.none:
        break;
    }

    // Se il percorso è cambiato, avvia l'animazione progressiva a 3 step
    if (phase == ReroutePhase.routeChanged) {
      _startRouteChangedAnimation();
    } else {
      // Cancella l'animazione se torniamo a un'altra fase
      _routeChangedAnimTimer?.cancel();
      _routeChangedAnimStep = 0;
    }
  }

  /// Avvia l'animazione progressiva "Va tutto bene" a 3 step.
  ///
  /// FLUSSO VISIVO (come da screenshot):
  /// - Subito (0s): mascotte + "Va tutto bene."
  /// - Dopo 1.5s: + "Sembra che il percorso sia cambiato."
  /// - Dopo 3.0s: + pulsanti "Mostra il nuovo percorso" / "Controllo la mappa"
  void _startRouteChangedAnimation() {
    _routeChangedAnimTimer?.cancel();
    _routeChangedAnimStep = 0;

    _routeChangedAnimTimer = Timer(const Duration(milliseconds: 1500), () {
      if (!mounted || _reroutePhase != ReroutePhase.routeChanged) return;
      setState(() => _routeChangedAnimStep = 1);

      _routeChangedAnimTimer = Timer(const Duration(milliseconds: 1500), () {
        if (!mounted || _reroutePhase != ReroutePhase.routeChanged) return;
        setState(() => _routeChangedAnimStep = 2);
      });
    });
  }



  /// L'utente ha scelto "Continua col nuovo percorso".
  ///
  /// Il nuovo percorso è già attivo sulla mappa (applicato dal monitor
  /// al momento del ricalcolo). Qui confermiamo la scelta:
  /// 1. Chiudiamo il bottom sheet
  /// 2. Il monitor cancella il backup del vecchio percorso
  /// 3. La navigazione prosegue normalmente col nuovo percorso
  void _confirmNewRoute() {
    _routeChangedAnimTimer?.cancel();
    _navigationMonitor.confirmNewRoute();
    setState(() {
      _reroutePhase = ReroutePhase.none;
      _routeChangedAnimStep = 0;
    });
  }

  /// L'utente ha scelto "Torna al vecchio percorso".
  ///
  /// Il monitor ripristina il percorso precedente come attivo e notifica
  /// la UI tramite activeRouteNotifier. La mappa torna a mostrare il
  /// vecchio percorso con le vecchie indicazioni.
  ///
  /// NOTA: l'utente potrebbe non essere fisicamente sul vecchio percorso.
  /// Il monitor continuerà a controllare la posizione e, se necessario,
  /// scatterà un nuovo ricalcolo in futuro.
  void _restorePreviousRoute() {
    _routeChangedAnimTimer?.cancel();
    _navigationMonitor.restorePreviousRoute();
    setState(() {
      _reroutePhase = ReroutePhase.none;
      _routeChangedAnimStep = 0;
    });
  }

  // ===========================================================================
  // ANIMAZIONE ARRIVO A DESTINAZIONE
  // ===========================================================================

  /// Avvia l'animazione progressiva "Sei arrivato" a 3 step.
  ///
  /// FLUSSO VISIVO (come da screenshot):
  /// - Subito (0s): checkmark verde + "Sei arrivato."
  /// - Dopo 1.5s: + "Hai seguito il percorso con attenzione."
  /// - Dopo 3.0s: + "Vuoi rivedere il percorso?" (link blu cliccabile)
  ///
  /// Il pattern è identico a _startRouteChangedAnimation() per coerenza UX.
  void _startArrivalAnimation() {
    _arrivalAnimTimer?.cancel();
    _arrivalAnimStep = 0;

    _arrivalAnimTimer = Timer(const Duration(milliseconds: 1500), () {
      if (!mounted || !_isArrived) return;
      setState(() => _arrivalAnimStep = 1);

      _arrivalAnimTimer = Timer(const Duration(milliseconds: 1500), () {
        if (!mounted || !_isArrived) return;
        setState(() => _arrivalAnimStep = 2);
      });
    });
  }

  /// Chiude il bottom sheet di arrivo e torna alla schermata di ricerca.
  void _dismissArrivalSheet() {
    _arrivalAnimTimer?.cancel();
    _resetNavigation();
  }

  /// Passa alla modalità "rivedi percorso": mostra il percorso pianificato (blu)
  /// e il percorso effettivamente camminato (verde) in vista panoramica.
  void _showWalkedPathReview() {
    _arrivalAnimTimer?.cancel();
    _navigationMonitor.stopNavigation();

    setState(() {
      _isArrived = false;
      _arrivalAnimStep = 0;
      _isReviewingWalkedPath = true;
      // Manteniamo _appState = navigating per tenere la mappa e
      // il percorso visibile, ma la UI cambia per mostrare la review.
    });

    // Dopo il rebuild, adatta la camera per mostrare tutto il percorso
    Future.delayed(const Duration(milliseconds: 300), () {
      if (mounted) {
        _mapKey.currentState?.fitAllPoints();
      }
    });
  }

  /// Callback: lo step corrente è cambiato → aggiorna la mappa per
  /// spostare il "corridoio verde" al nuovo segmento.
  ///
  /// Viene invocato dal currentStepNotifier quando il NavigationMonitor
  /// rileva che l'utente ha superato un waypoint e avanza allo step
  /// successivo. Il rebuild passa il nuovo currentStepIndex al MapWidget,
  /// che ricostruisce le polyline segmentate (verde=nuovo step, grigio=dopo).
  void _onStepChanged() {
    if (_appState == NavigationAppState.navigating) {
      // FIX BUG 4 (B4.5): apre la finestra di rinforzo post-svolta.
      // Il banner userà _lastStepAdvanceAt per decidere se mostrare la
      // versione "Bravo! <step corrente>" o la versione classica
      // (prossima manovra). Programmiamo un rebuild a fine finestra così
      // il banner torna a mostrare la prossima manovra senza dover
      // attendere un altro evento (GPS update, overlay change, ...).
      _lastStepAdvanceAt = DateTime.now();
      _postTurnRebuildTimer?.cancel();
      _postTurnRebuildTimer = Timer(_kPostTurnReinforcementWindow, () {
        if (mounted) setState(() {});
      });

      // FIX BUG 4 (B4.7): se c'è un overlay turnInstruction attivo per la
      // svolta appena consumata, lo dismissiamo. Senza questo, l'utente
      // vede contemporaneamente l'overlay grande della svolta passata e
      // il banner della prossima — confusione massima per disabilità
      // cognitive. returnToRoute / lateralRoadDetected / arrivalCelebration
      // restano (sono indipendenti dallo step corrente).
      if (_overlayState?.type == OverlayType.turnInstruction) {
        _overlayState = null;
      }

      setState(() {
        // Il rebuild causa MapWidget.didUpdateWidget() che ricalcola
        // le polyline con il nuovo currentStepIndex.
      });
      final steps = _directionsResult?.steps;
      if (steps == null || steps.isEmpty) return;

      final int idx = _navigationMonitor.currentStepNotifier.value;
      final int safeIdx = idx < steps.length ? idx : steps.length - 1;

      // FIX BUG 3 (B3.3) — Multi-skip detection.
      //
      // Il monitor può avanzare di > 1 step in un solo GPS tick (while loop
      // su deviazioni o waypoint molto vicini). In quel caso un'istruzione
      // intermedia (es. "Vai a sinistra") rischierebbe di essere saltata
      // dall'annuncio vocale, lasciando l'utente confuso. Quando rileviamo
      // un salto di > 1, premettiamo "Hai svoltato" e aggiungiamo
      // l'istruzione intermedia che era stata saltata.
      final bool isLastStep = safeIdx + 1 >= steps.length;
      final String nextInstruction =
          isLastStep ? 'Stai arrivando' : steps[safeIdx + 1].instruction;

      String text = nextInstruction;
      if (_lastAnnouncedStep >= 0 && safeIdx - _lastAnnouncedStep > 1) {
        // Multi-skip: l'utente ha attraversato più waypoint senza che
        // l'avessimo annunciato. Diciamo cosa è appena successo + cosa
        // fare ora, in una frase sola.
        final int missedIdx = _lastAnnouncedStep + 1;
        if (missedIdx < steps.length) {
          final String missed = steps[missedIdx].instruction;
          text = 'Hai svoltato. $missed. Ora $nextInstruction';
        }
      }

      // FIX BUG 3 (B3.1): priorità "important" per le istruzioni di marcia.
      // dedupKey legato all'indice dello step così la stessa transizione
      // non viene riannunciata se lo stato si ricostruisce.
      _enqueueSpeech(
        text,
        priority: SpeechPriority.important,
        dedupKey: 'step-$safeIdx',
      );
      _lastAnnouncedStep = safeIdx;
    }
  }

  /// FIX BUG 1 + BUG 2 — Callback sul progresso aggiornato.
  ///
  /// Viene invocato ad ogni GPS tick dal NavigationMonitor (durante la
  /// navigazione). Aggiorna il campo locale `_progress` e forza il
  /// rebuild della UI, così il bottom sheet (tempo + distanza totali
  /// residui) e il banner verde (distanza alla prossima svolta) si
  /// aggiornano in tempo reale.
  ///
  /// Ottimizzazione: skippiamo il setState se siamo in uno stato non
  /// navigazione (il progress notifier può pubblicare valori di coda
  /// in brevi finestre temporali durante le transizioni).
  void _onProgressChanged() {
    if (!mounted) return;
    if (_appState != NavigationAppState.navigating) return;
    setState(() {
      _progress = _navigationMonitor.progressNotifier.value;
    });
  }

  /// Callback chiamato quando il NavigationMonitor cambia il percorso attivo (TASK 2).
  ///
  /// Questo listener viene invocato in tre scenari:
  /// 1. startNavigation(): imposta il percorso iniziale (best route)
  /// 2. Task 2b: l'utente ha deviato su un percorso alternativo
  /// 3. Task 2c: il percorso è stato ricalcolato via API
  ///
  /// In tutti e tre i casi, aggiorniamo la UI con i dati del nuovo percorso:
  /// - Polyline sulla mappa (tramite encodedPolyline)
  /// - Lista delle indicazioni (tramite steps)
  /// - Durata e distanza totale (tramite totalDuration/totalDistance)
  void _onActiveRouteChanged() {
    // Legge il nuovo percorso attivo dal notifier del monitor
    final RouteData? newRoute = _navigationMonitor.activeRouteNotifier.value;

    // Se il nuovo percorso è null (navigazione fermata), non facciamo nulla.
    // La UI manterrà l'ultimo stato visualizzato.
    if (newRoute == null) return;

    // Aggiorna lo stato della UI con i dati del nuovo percorso.
    // Creiamo un nuovo DirectionsResult per compatibilità con i widget
    // esistenti (MapWidget e DirectionsList) che si aspettano questo formato.
    setState(() {
      _directionsResult = DirectionsResult(
        steps: newRoute.steps,
        totalDistance: newRoute.totalDistance,
        totalDuration: newRoute.totalDuration,
        // FIX BUG 1: propago anche i totali numerici del nuovo percorso
        totalDistanceMeters: newRoute.totalDistanceMeters,
        totalDurationSeconds: newRoute.totalDurationSeconds,
        encodedPolyline: newRoute.encodedPolyline,
        // Le coordinate di origine e destinazione vengono prese dal
        // risultato completo se disponibile, altrimenti manteniamo
        // le coordinate attuali (la destinazione non cambia mai)
        originLat:
        _allRoutesResult?.originLat ?? _directionsResult?.originLat ?? 0,
        originLng:
        _allRoutesResult?.originLng ?? _directionsResult?.originLng ?? 0,
        destLat: _allRoutesResult?.destLat ?? _directionsResult?.destLat ?? 0,
        destLng: _allRoutesResult?.destLng ?? _directionsResult?.destLng ?? 0,
      );
    });

    // Log per debugging: segnala alla console che la UI è stata aggiornata
    print(
      'UI aggiornata con nuovo percorso: ${newRoute.totalDuration} '
          '(${newRoute.totalDistance})',
    );
  }

  /// Inizializza il monitoraggio della posizione GPS per aggiornare
  /// velocità, posizione e bearing in tempo reale.
  ///
  /// FLUSSO:
  /// 1. Verifica che il GPS sia abilitato
  /// 2. Richiede i permessi di localizzazione
  /// 3. Si sottoscrive allo stream di posizioni
  /// 4. Ad ogni aggiornamento, salva i valori e li inoltra al NavigationMonitor
  ///
  /// SIDE EFFECTS:
  /// - Può mostrare un dialog di richiesta permessi del sistema operativo
  /// - Avvia un listener persistente che consuma batteria
  Future<void> _initLocationMonitoring() async {
    bool serviceEnabled;
    LocationPermission permission;

    // Verifica che il servizio GPS sia abilitato sul dispositivo
    serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return;

    // Controlla i permessi di localizzazione
    permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      // Se i permessi non sono stati ancora concessi, li richiediamo
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return; // Permessi rifiutati, impossibile procedere
      }
    }

    // Inizia ad ascoltare lo stream di posizioni GPS.
    //
    // PARAMETRI DI CONFIGURAZIONE:
    // - accuracy: high → usa GPS + WiFi + celle telefoniche per la massima
    //   precisione (3-10 m). Consuma più batteria ma è necessario per
    //   il calcolo dei punti laterali a 10 m.
    // - distanceFilter: 2 → emette un aggiornamento solo quando l'utente
    //   si sposta di almeno 2 metri. Questo riduce il numero di aggiornamenti
    //   inutili quando l'utente è fermo (il GPS ha un drift di ~1-2 m).
    _positionStream =
        Geolocator.getPositionStream(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            distanceFilter: 2, // Aggiorna ogni 2 metri
          ),
        ).listen((Position position) {
          setState(() {
            // =============================================================
            // VELOCITÀ — CALCOLO IBRIDO (chip GPS + fallback manuale)
            // =============================================================
            //
            // STRATEGIA:
            // 1. Se il chip GPS riporta speed > 0 → usiamo quello.
            //    È il dato più preciso perché il chip usa il Doppler shift
            //    del segnale satellitare, che è accurato anche a basse
            //    velocità (errore tipico: ±0.1 m/s).
            //
            // 2. Se speed == 0 (chip non lo supporta, comune su molti
            //    Android economici) → calcoliamo manualmente dalla
            //    distanza geodetica tra la posizione precedente e quella
            //    attuale, diviso il tempo trascorso.
            //
            // 3. In entrambi i casi applichiamo un filtro EMA per smorzare
            //    i picchi di drift da fermo.

            double rawSpeedKmH;

            // Caso 1: il chip GPS riporta velocità > 0 → usiamo quello.
            //   È il dato più preciso perché usa il Doppler shift del
            //   segnale satellitare (errore tipico: ±0.1 m/s).
            if (position.speed > 0) {
              rawSpeedKmH = position.speed * 3.6; // m/s → km/h
            }
            // Caso 2: il chip riporta speed == 0.
            //
            //   FIX BUG OVERLAY CHE NON PARTE:
            //   Prima, quando speed == 0 si ricadeva nel calcolo manuale
            //   (distanza / tempo). Problema: con distanceFilter=2, il GPS
            //   emette eventi solo quando il drift supera 2m. Questo produce
            //   velocità manuali di 2–4 km/h anche da completamente fermi
            //   (2m / 0.5s × 3.6 = 14 km/h, tipicamente ~3.5 km/h con EMA).
            //   La velocità filtrata restava SOPRA la soglia di 2.5 km/h,
            //   impedendo al timer di 10 secondi di partire → l'overlay
            //   non appariva MAI.
            //
            //   FIX: quando il chip dice speed=0, fidiamoci: l'utente è fermo.
            //   Il calcolo manuale serve SOLO come fallback quando il chip
            //   non supporta affatto la velocità (rarissimo su smartphone
            //   moderni). Lo usiamo solo se il calcolo manuale mostra una
            //   velocità significativa (> 5 km/h), che indicherebbe che il
            //   chip non riporta speed ma l'utente sta chiaramente camminando.
            else if (_prevLat != null &&
                _prevLng != null &&
                _prevTimestamp != null) {
              final DateTime currentTimestamp = position.timestamp;
              final double deltaSec =
                  currentTimestamp.difference(_prevTimestamp!).inMilliseconds /
                      1000.0;

              if (deltaSec >= _minTimeDeltaSec) {
                final double distanceMeters = haversineDistance(
                  _prevLat!,
                  _prevLng!,
                  position.latitude,
                  position.longitude,
                );
                final double manualSpeedKmH = (distanceMeters / deltaSec) * 3.6;

                // Usa il calcolo manuale SOLO se mostra velocità significativa
                // (> 5 km/h = camminata veloce). Sotto questa soglia, il chip
                // dice speed=0 e i 2–4 km/h "manuali" sono puro GPS drift.
                if (manualSpeedKmH > 5.0) {
                  rawSpeedKmH = manualSpeedKmH;
                } else {
                  rawSpeedKmH = 0.0; // Fidiamoci del chip: utente fermo
                }
              } else {
                rawSpeedKmH = _currentSpeed;
              }
            }
            // Caso 3: primo aggiornamento GPS, nessun dato precedente
            else {
              rawSpeedKmH = 0.0;
            }

            // Sanitizza: se negativo (errore sensore) azzeriamo
            if (rawSpeedKmH < 0) rawSpeedKmH = 0.0;

            // Clamp anti-teleportazione: una persona a piedi non supera
            // i 15 km/h (corsa veloce). Valori superiori sono certamente
            // un salto del fix GPS (il chip perde il segnale per 2s e al
            // ritorno si ritrova a 20m di distanza → 20m/2s = 36 km/h).
            // Li scartiamo per evitare che l'EMA impieghi molti frame
            // a smaltire un picco assurdo.
            if (rawSpeedKmH > 15.0) {
              rawSpeedKmH = _currentSpeed; // Mantieni il valore filtrato attuale
            }

            // Filtro EMA — smorza i picchi di drift da fermo
            _currentSpeed = _speedEmaAlpha * rawSpeedKmH +
                (1 - _speedEmaAlpha) * _currentSpeed;

            // Dead zone: sotto 0.3 km/h forziamo a zero.
            // Questo elimina il micro-drift residuo dopo l'EMA che
            // manterrebbe il contavelocità a "0.2" anche da perfettamente
            // fermi, impedendo al timer di 10s di partire.
            if (_currentSpeed < 0.3) {
              _currentSpeed = 0.0;
            }

            // Salva posizione e timestamp correnti come "precedenti"
            // per il prossimo calcolo manuale
            _prevLat = position.latitude;
            _prevLng = position.longitude;
            _prevTimestamp = position.timestamp;

            // DEBUG: mostra sorgente e valori per diagnostica
            final String source = position.speed > 0
                ? 'CHIP'
                : (rawSpeedKmH > 0 ? 'MANUAL-FALLBACK' : 'CHIP-ZERO');
            print('🚶 SPEED DEBUG [$source]: '
                'raw=${rawSpeedKmH.toStringAsFixed(2)} '
                '→ EMA=${_currentSpeed.toStringAsFixed(2)} km/h '
                '(chip=${(position.speed * 3.6).toStringAsFixed(2)} km/h, '
                'acc=${position.accuracy.toStringAsFixed(1)}m)');

            // --- TIMER SILENZIO GPS ---
            // Ad ogni aggiornamento GPS valido, resettiamo il timer.
            // Il timer è un one-shot: se non arriva nessun update entro
            // _gpsTimeoutSeconds, l'utente è fermo e azzeriamo la velocità.
            _gpsTimeoutTimer?.cancel();
            _gpsTimeoutTimer = Timer(
              Duration(seconds: _gpsTimeoutSeconds),
              () {
                // Nessun update GPS da N secondi → l'utente è fermo.
                // Azzeriamo la velocità a schermo e notifichiamo il monitor.
                if (mounted && _currentSpeed > 0.0) {
                  setState(() {
                    _currentSpeed = 0.0;
                  });
                  if (_currentLat != null && _currentLng != null) {
                    _navigationMonitor.updatePosition(
                      _currentLat!,
                      _currentLng!,
                      0.0,
                      _rawBearing,
                    );
                  }
                  print('⏱️ GPS TIMEOUT: nessun update da $_gpsTimeoutSeconds s — '
                      'velocità azzerata a 0.0 km/h');
                }
              },
            );

            // --- Posizione ---
            _currentLat = position.latitude;
            _currentLng = position.longitude;

            // --- Bearing ---
            _rawBearing = position.heading.isFinite && position.heading >= 0
                ? position.heading
                : 0.0;
          });

          // --- TRACKING PERCORSO EFFETTUATO ---
          // Registra la posizione GPS nella lista _walkedPath solo quando
          // la navigazione è attiva. Filtra punti troppo vicini (<5m) per
          // evitare accumulo da GPS jitter quando l'utente è fermo.
          if (_appState == NavigationAppState.navigating && !_isArrived) {
            final newPoint = LatLng(position.latitude, position.longitude);

            if (_walkedPath.isEmpty) {
              _walkedPath.add(newPoint);
            } else {
              final lastPoint = _walkedPath.last;
              final double dist = distanceBetween(
                lastPoint.latitude,
                lastPoint.longitude,
                newPoint.latitude,
                newPoint.longitude,
              );
              // Salva solo se distante almeno 5 metri dal punto precedente
              if (dist >= 5.0) {
                _walkedPath.add(newPoint);
              }
            }
          }

          // Inoltra TUTTI i dati aggiornati al NavigationMonitor.
          _navigationMonitor.updatePosition(
            _currentLat!,
            _currentLng!,
            _currentSpeed,
            _rawBearing,
            position.accuracy, // TASK 5: Inviato confidence level
          );

          // --- PRIMO FIX GPS: centra la mappa sulla posizione reale ---
          if (!_hasInitialFix) {
            _hasInitialFix = true;
            // FIX: Impostiamo _isFollowingUser = true perché la mappa è
            // centrata sulla posizione dell'utente. Il tasto "Io" apparirà
            // solo DOPO che l'utente avrà fatto pan manuale (allontanandosi).
            _isFollowingUser = true;
            _mapKey.currentState?.moveToLocation(
              _currentLat!,
              _currentLng!,
            );
          }

          // --- FOLLOW-MODE: insegui la posizione GPS sulla mappa ---
          // FIX BUG 1:
          // - Esteso a routePreview così la mappa ruota anche prima di "Avvia"
          //   se l'utente sta camminando lungo il percorso.
          // - Escluso durante il review della walked path (vista panoramica).
          // - Usa _getMapBearing(): combina segmento percorso (in marcia) e
          //   bussola (da fermo) in modo coerente con la freccia direzionale.
          // - Usa _followCameraThrottled(): rotazione graduale al cambio
          //   step (>90°) e throttle delle animazioni sovrapposte.
          final bool isFollowEligible = !_isReviewingWalkedPath &&
              (_appState == NavigationAppState.navigating ||
                  _appState == NavigationAppState.routePreview);
          if (isFollowEligible && _isFollowingUser) {
            final double navBearing = _getMapBearing();
            _followCameraThrottled(
              _currentLat!,
              _currentLng!,
              navBearing,
            );
          }
        });
  }

  @override
  void dispose() {
    // Cancella lo stream GPS per evitare memory leak e consumo batteria
    _positionStream?.cancel();

    // Cancella il timer di silenzio GPS
    _gpsTimeoutTimer?.cancel();

    // Cancella lo stream della bussola
    _compassStream?.cancel();

    // Cancella il timer del banner errore.
    _errorBannerTimer?.cancel();

    // Rimuove i listener prima di distruggere il monitor
    _navigationMonitor.overlayNotifier.removeListener(_onOverlayChanged);

    // Rimuove il listener del percorso attivo (TASK 2)
    _navigationMonitor.activeRouteNotifier.removeListener(
      _onActiveRouteChanged,
    );

    // Rimuove il listener dello step corrente (polyline segmentate)
    _navigationMonitor.currentStepNotifier.removeListener(_onStepChanged);

    // Rimuove il listener della fase di ricalcolo
    _navigationMonitor.reroutePhaseNotifier.removeListener(
      _onReroutePhaseChanged,
    );

    // FIX BUG 1 + BUG 2: rimuove il listener del progress
    _navigationMonitor.progressNotifier.removeListener(_onProgressChanged);

    // Cancella il timer dell'animazione ricalcolo
    _routeChangedAnimTimer?.cancel();

    // Cancella il timer dell'animazione arrivo
    _arrivalAnimTimer?.cancel();

    // FIX BUG 4 (B4.5): cancella il timer della finestra di rinforzo
    // post-svolta.
    _postTurnRebuildTimer?.cancel();

    // FIX BUG 2 (B2.3): cancella il timer della rotazione graduale.
    _gradualRotationCompletionTimer?.cancel();

    // Distrugge il NavigationMonitor (cancella tutti i timer interni)
    _navigationMonitor.dispose();

    // Distrugge il controller e il nodo di focus del campo di testo
    _destinationController.dispose();
    _searchFocusNode.dispose();
    _tts.stop();

    super.dispose();
  }

  // ===========================================================================
  // HELPER: BEARING LUNGO IL PERCORSO
  // ===========================================================================
  // HELPER POSIZIONAMENTO PULSANTE "IO" — FIX BUG 6b
  // ===========================================================================

  /// Calcola il valore di `bottom` del pulsante "Io" in modo che appoggi
  /// sempre SOPRA il bottom sheet dello stato corrente, senza lasciare
  /// spazi morti né sovrapporsi.
  ///
  /// Il valore è dato da:
  ///   altezza_bottom_sheet_stato_corrente + margine_respiro_16px
  ///
  /// L'altezza del bottom sheet include SafeArea.bottom perché i sheet
  /// usano `MediaQuery.padding.bottom + 24` come padding inferiore.
  ///
  /// NOTA: i valori di CONTENT_HEIGHT sono stime del contenuto interno
  /// del sheet (Row con icone+testo+pulsanti). Se in futuro il layout
  /// del sheet cambia, aggiornare la costante corrispondente.
  double _computeRecenterButtonBottom(BuildContext context) {
    final double safeBottom = MediaQuery.of(context).padding.bottom;
    const double margin = 16.0;

    switch (_appState) {
      case NavigationAppState.navigating:
        // _buildNavigatingUI bottom sheet:
        //   top padding 24 + Row (~60) + bottom padding (safeBottom + 24)
        //   ≈ 24 + 60 + 24 + safeBottom = 108 + safeBottom
        const double contentHeight = 108.0;
        return contentHeight + safeBottom + margin;

      case NavigationAppState.placeSelected:
        // _buildPlaceSelectedSheet è più alto: Column con titolo +
        // indirizzo + pulsante "Vai" grande. Stima ≈ 180.
        const double placeSheetHeight = 180.0;
        return placeSheetHeight + safeBottom + margin;

      case NavigationAppState.routePreview:
        // Il preview sheet occupa ~35% dell'altezza dello schermo.
        // Ancoriamo il pulsante appena sopra.
        final double screenH = MediaQuery.of(context).size.height;
        return screenH * 0.35 + margin;

      case NavigationAppState.search:
        // Stato home: solo safe area + margine minimo.
        return safeBottom + 24.0;
    }
  }

  /// FIX BUG 2 — Formatta una distanza in metri per il banner verde.
  ///
  /// Usa la stessa convenzione del monitor (`_formatDistance` in
  /// navigation_monitor.dart): "450 m", "1,2 km", "12 km". Duplicato
  /// qui lato UI perché ci serve applicare la formattazione anche nel
  /// caso in cui il progress non sia ancora disponibile e stiamo
  /// formattando direttamente un valore numerico.
  ///
  /// NOTA: se la distanza scende sotto i 10m, mostriamo "Ci sei quasi"
  /// invece di un numero basso che può sembrare allarmante. Soglia
  /// pensata per il target d'uso (pedonale con disabilità cognitive).
  String _formatBannerDistance(double meters) {
    if (meters < 10) return 'Ci sei quasi';
    if (meters < 1000) return '${meters.round()} m';
    if (meters < 10000) {
      return '${(meters / 1000.0).toStringAsFixed(1).replaceAll('.', ',')} km';
    }
    return '${(meters / 1000.0).round()} km';
  }

  // ===========================================================================

  /// Calcola il bearing della direzione in cui orientare la mappa durante
  /// la navigazione.
  ///
  /// FIX BUG 7: strategia migliorata. Usiamo il bearing del SEGMENTO attivo
  /// (start → end dello step corrente), non più il bearing dalla posizione
  /// dell'utente verso la fine dello step.
  ///
  /// MOTIVAZIONE:
  /// Il bearing "utente → endLocation" è intrinsecamente INSTABILE vicino
  /// al waypoint: quando l'utente arriva a < 10m dalla fine dello step,
  /// piccoli sbalzi GPS producono variazioni di bearing di 20-40° tra un
  /// frame e l'altro (atan2 molto sensibile quando la distanza tende a 0).
  /// Il bearing del SEGMENTO è invece una costante geometrica per ogni
  /// step: sempre stabile, indipendente dalla posizione istantanea.
  ///
  /// FALLBACK a cascata se il bearing del segmento non è disponibile:
  ///   1) bearing del segmento attivo (start → end)
  ///   2) bearing verso l'endLocation dello step
  ///   3) bearing affidabile memorizzato nel monitor (GPS sopra soglia)
  ///   4) compass/magnetometro (funziona da fermo — FIX BUG 2)
  ///   5) raw GPS bearing se non zero, altrimenti _cameraBearing precedente
  ///      (FIX BUG 1: evita snap silenzioso a 0°/Nord quando il GPS bearing
  ///      non è ancora stato acquisito)
  double _getRouteBearing() {
    final steps = _directionsResult?.steps;
    if (steps == null || steps.isEmpty) {
      // Nessun percorso attivo: cascata monitor → compass → raw GPS → camera
      if (_navigationMonitor.direction != null) return _navigationMonitor.direction!;
      if (_compassHeading != 0.0) return _compassHeading;
      if (_rawBearing != 0.0) return _rawBearing;
      return _cameraBearing;
    }

    final int idx = _navigationMonitor.currentStepNotifier.value;
    final int safeIdx = idx < steps.length ? idx : steps.length - 1;
    final step = steps[safeIdx];

    // --- STRATEGIA 1: bearing del segmento attivo (PRINCIPALE) ---
    // Il bearing dallo startLocation allo endLocation dello step è una
    // proprietà geometrica costante del tratto di strada: stabile e
    // sempre definita.
    final double segmentBearing = _bearingBetween(
      step.startLat,
      step.startLng,
      step.endLat,
      step.endLng,
    );

    // Sanity check: se startLocation e endLocation coincidono (step degenere),
    // cadiamo sul fallback verso l'endLocation dalla posizione utente.
    final double segLength = haversineDistance(
      step.startLat,
      step.startLng,
      step.endLat,
      step.endLng,
    );
    if (segLength >= 2.0) {
      // Segmento non degenere → usiamo il suo bearing
      return segmentBearing;
    }

    // --- STRATEGIA 2: bearing dall'utente verso la fine dello step ---
    if (_currentLat != null && _currentLng != null) {
      final double userDistToEnd = haversineDistance(
        _currentLat!,
        _currentLng!,
        step.endLat,
        step.endLng,
      );
      // Solo se l'utente non è praticamente sopra il waypoint (evita atan2
      // erratico a distanze sub-metriche).
      if (userDistToEnd >= 3.0) {
        return _bearingBetween(
          _currentLat!,
          _currentLng!,
          step.endLat,
          step.endLng,
        );
      }
    }

    // --- STRATEGIA 3: bearing affidabile del monitor (GPS sopra soglia) ---
    if (_navigationMonitor.direction != null) return _navigationMonitor.direction!;

    // --- STRATEGIA 4 (FIX BUG 2): compass/magnetometro ---
    // Il magnetometro funziona da fermo, a differenza del GPS bearing.
    // Usato quando l'utente non si è ancora mosso abbastanza per avere
    // un _navigationMonitor.direction valido. Evita il fallback a 0° (Nord).
    if (_compassHeading != 0.0) return _compassHeading;

    // --- STRATEGIA 5: raw GPS se non è zero (FIX BUG 1) ---
    if (_rawBearing != 0.0) return _rawBearing;

    // --- STRATEGIA 6 (FIX BUG 1): mantieni l'ultimo bearing applicato ---
    // Mai snappare a 0°/Nord come ultimo ricorso: una rotazione "silenziosa"
    // verso Nord è più disorientante che lasciare la camera ferma.
    return _cameraBearing;
  }

  /// Helper: calcola il bearing in gradi (0-360, convenzione compass
  /// bearing: 0°=nord, 90°=est) dalla coppia (lat1,lng1) alla (lat2,lng2).
  ///
  /// Usa la formula di Vincenty inverse solution semplificata, identica
  /// a quella usata in precedenza in _getRouteBearing, estratta qui per
  /// riuso sia sul segmento attivo che sul fallback.
  double _bearingBetween(
    double lat1Deg,
    double lng1Deg,
    double lat2Deg,
    double lng2Deg,
  ) {
    const double degToRad = 3.141592653589793 / 180.0;
    const double radToDeg = 180.0 / 3.141592653589793;

    final double lat1 = lat1Deg * degToRad;
    final double lat2 = lat2Deg * degToRad;
    final double dLng = (lng2Deg - lng1Deg) * degToRad;

    final double x = math.sin(dLng) * math.cos(lat2);
    final double y = math.cos(lat1) * math.sin(lat2) -
        math.sin(lat1) * math.cos(lat2) * math.cos(dLng);
    final double bearing = math.atan2(x, y) * radToDeg;

    return (bearing + 360) % 360;
  }

  /// FIX BUG 1: bearing per la rotazione della MAPPA (non della freccia).
  ///
  /// Combina segmento del percorso e bussola in modo coerente con la
  /// freccia direzionale (che usa sempre `_compassHeading`):
  ///
  /// - Se l'utente cammina (velocità ≥ 3.5 km/h) e abbiamo un bearing
  ///   GPS affidabile, ritorna il bearing del segmento attivo. È stabile
  ///   geometricamente e non oscilla per il jitter del magnetometro.
  /// - Altrimenti (utente fermo o lento) usa la bussola: la mappa segue
  ///   la testa dell'utente in tempo reale, *coerente* con la freccia.
  /// - Se la bussola non è disponibile, fallback su `_getRouteBearing()`.
  ///
  /// MOTIVAZIONE: quando la freccia (bussola) e la mappa (segmento) usano
  /// fonti diverse, l'utente con disabilità cognitive vede la freccia girare
  /// senza che la mappa la segua. Da fermo usiamo la stessa fonte; in marcia
  /// la mappa si stabilizza sul segmento (no jitter), e la freccia comunque
  /// punta dove guarda l'utente.
  double _getMapBearing() {
    const double kWalkingSpeedKmH = 3.5;
    final bool hasReliableGpsBearing = _navigationMonitor.direction != null;
    final bool isMoving = _currentSpeed >= kWalkingSpeedKmH;

    if (isMoving && hasReliableGpsBearing) {
      return _getRouteBearing();
    }
    if (_compassHeading != 0.0) {
      return _compassHeading;
    }
    return _getRouteBearing();
  }

  /// FIX BUG 2 (B2.2) — Bearing per il tasto "Io" (recenter).
  ///
  /// Sorgente unica della verità: in qualsiasi stato dell'app, dato lo
  /// stato corrente decide il bearing più sensato per orientare la mappa
  /// quando l'utente preme "Io". Sostituisce le code-path multiple che
  /// prima usavano _getRouteBearing() (con risultati incoerenti) o
  /// moveToLocation senza bearing (snap a Nord).
  ///
  /// STRATEGIA:
  ///   1. Navigating → delega a _getMapBearing() (segmento se in marcia,
  ///      bussola se fermo). Coerente col follow-mode (Bug 1).
  ///   2. routePreview / placeSelected con percorso → trova il primo step
  ///      ancora "davanti" all'utente (proiezione t < 1.0):
  ///      - Se l'utente è ≤ 5m dalla startLoc → bearing del segmento.
  ///      - Altrimenti → bearing utente → endLoc dello step (più
  ///        intuitivo: "guarda dove devi andare ORA").
  ///   3. Search / fallback → bussola se disponibile, altrimenti
  ///      _cameraBearing precedente (mai snap silenzioso a Nord).
  double _getRecenterBearing() {
    final double? lat = _currentLat;
    final double? lng = _currentLng;

    // 1. Navigating: usa la stessa fonte del follow-mode (coerenza col Bug 1).
    if (_appState == NavigationAppState.navigating) {
      return _getMapBearing();
    }

    // 2. Preview / placeSelected con percorso pronto: cerca lo step
    //    rilevante per la posizione corrente.
    if ((_appState == NavigationAppState.routePreview ||
            _appState == NavigationAppState.placeSelected) &&
        lat != null &&
        lng != null) {
      final steps = _directionsResult?.steps;
      if (steps != null && steps.isNotEmpty) {
        for (final step in steps) {
          // Salta step degeneri (start ≈ end) per evitare proiezioni instabili.
          final double segLen = haversineDistance(
            step.startLat,
            step.startLng,
            step.endLat,
            step.endLng,
          );
          if (segLen < 2.0) continue;

          final SegmentProjection proj = projectPointOnSegment(
            lat,
            lng,
            step.startLat,
            step.startLng,
            step.endLat,
            step.endLng,
          );
          if (proj.t >= 1.0) continue; // Step già superato

          // Trovato lo step più rilevante.
          final double distToStart = haversineDistance(
            lat,
            lng,
            step.startLat,
            step.startLng,
          );
          if (distToStart > 5.0) {
            // Utente non è sopra startLoc → bearing user → endLoc.
            return _bearingBetween(lat, lng, step.endLat, step.endLng);
          }
          return _bearingBetween(
            step.startLat,
            step.startLng,
            step.endLat,
            step.endLng,
          );
        }
        // Tutti gli step sono dietro l'utente: cade in fallback bussola.
      }
    }

    // 3. Fallback: bussola → _cameraBearing.
    if (_compassHeading != 0.0) return _compassHeading;
    return _cameraBearing;
  }

  /// FIX BUG 2 (B2.4) — Handler unificato del tasto "Io" (recenter).
  ///
  /// Sostituisce il vecchio if/elseif con tre code-path divergenti
  /// (navigating / preview&placeSelected / search). Ora la decisione
  /// è scomposta in:
  ///   - **Bearing**: deciso da _getRecenterBearing() — uniforme.
  ///   - **Camera mode**:
  ///     - navigating + routePreview → vista guidata (followUser:
  ///       tilt 40, zoom 18, rotazione graduale se diff > 90°).
  ///     - placeSelected + search → vista panoramica (moveToLocation
  ///       con bearing, tilt 0, zoom default). Prima usava moveToLocation
  ///       senza bearing → mappa snappava a Nord.
  ///   - **Follow-mode**: setState(_isFollowingUser=true) DOPO
  ///     l'animazione, evitando race tra rebuild e camera move.
  void _onRecenterPressed() {
    final double? lat = _currentLat;
    final double? lng = _currentLng;
    if (lat == null || lng == null) return;

    final double bearing = _getRecenterBearing();
    final bool useNavView =
        _appState == NavigationAppState.navigating ||
            _appState == NavigationAppState.routePreview;

    if (useNavView) {
      _applyGradualBearing(lat, lng, bearing);
    } else {
      // FIX B2.1: passiamo il bearing così la camera non snappa a Nord.
      _mapKey.currentState?.moveToLocation(lat, lng, bearing: bearing);
      _cameraBearing = bearing;
      _lastAppliedLat = lat;
      _lastAppliedLng = lng;
    }

    setState(() {
      _isFollowingUser = true;
    });
  }

  // ===========================================================================
  // FIX BUG 2 — GRADUAL BEARING ROTATION FOR IO BUTTON
  // ===========================================================================

  /// Applica la rotazione della mappa con gradualità se la differenza
  /// di bearing è troppo ampia (> 90°).
  ///
  /// PROBLEMA: quando l'utente preme "IO" e il bearing del percorso è
  /// opposto alla direzione in cui l'utente sta guardando (es. 180° di
  /// differenza), una rotazione istantanea di 180° disorienta completamente.
  ///
  /// SOLUZIONE: se la differenza è > 90°, ruotiamo prima di 90° verso
  /// la direzione corretta, poi dopo 500ms completiamo la rotazione.
  /// Questo dà all'utente tempo di orientarsi durante la transizione.
  void _applyGradualBearing(double lat, double lng, double targetBearing) {
    // FIX BUG 2 (B2.3): cancella eventuale completion pendente prima di
    // iniziare una nuova rotazione. Senza questa cancellazione, due chiamate
    // ravvicinate (tap doppio IO, GPS update durante i 500ms intermedi)
    // facevano atterrare il vecchio Future.delayed su un target obsoleto
    // → la camera oscillava avanti e indietro per ~1 secondo.
    _gradualRotationCompletionTimer?.cancel();
    _gradualRotationCompletionTimer = null;

    // FIX BUG 2: usa _cameraBearing (bearing reale della camera) invece di
    // _rawBearing (bearing GPS). _rawBearing è inaffidabile da fermo e non
    // riflette la rotazione attuale della camera se l'utente ha fatto pan.
    final double currentBearing = _cameraBearing;

    // Calcola la differenza tra i due bearing (in range -180 a +180)
    double diff = (targetBearing - currentBearing + 360) % 360;
    if (diff > 180) diff -= 360;
    final double absDiff = diff.abs();

    if (absDiff > 90) {
      // Rotazione troppo ampia → graduale in due step
      final double intermediateBearing = (currentBearing + (diff > 0 ? 90 : -90)) % 360;
      _cameraBearing = intermediateBearing;
      _lastAppliedLat = lat;
      _lastAppliedLng = lng;
      _mapKey.currentState?.followUser(lat, lng, intermediateBearing);

      // Completa la rotazione dopo 500ms con un Timer cancellabile.
      _gradualRotationCompletionTimer = Timer(
        const Duration(milliseconds: 500),
        () {
          _gradualRotationCompletionTimer = null;
          if (!mounted) return;
          _cameraBearing = targetBearing;
          _lastAppliedLat = lat;
          _lastAppliedLng = lng;
          _mapKey.currentState?.followUser(lat, lng, targetBearing);
        },
      );
    } else {
      // Rotazione accettabile (< 90°) → diretta
      _cameraBearing = targetBearing;
      _lastAppliedLat = lat;
      _lastAppliedLng = lng;
      _mapKey.currentState?.followUser(lat, lng, targetBearing);
    }
  }

  /// FIX BUG 1: variante "follow-mode" con throttle e gradual rotation.
  ///
  /// Chiamata ad ogni aggiornamento GPS (~500ms) durante la navigazione.
  /// A differenza di [_applyGradualBearing] (usata dal tasto IO), questa:
  ///
  /// 1. Applica la **rotazione graduale** se il bearing salta di > 90°
  ///    (tipicamente al cambio di step su una svolta secca) — riusa la
  ///    logica di _applyGradualBearing.
  /// 2. Applica un **throttle** se la variazione è piccola: salta la
  ///    chiamata `animateCamera` se sia il bearing (< 2°) sia la posizione
  ///    (< 1.5m) sono praticamente invariate. Evita le animazioni
  ///    sovrapposte di Google Maps che si annullano a vicenda producendo
  ///    l'effetto "scatti".
  ///
  /// Le soglie 2°/1.5m sono sotto la soglia di percezione su uno schermo
  /// di smartphone con zoom 18.
  void _followCameraThrottled(double lat, double lng, double targetBearing) {
    const double kMinBearingDeltaDeg = 2.0;
    const double kMinPosDeltaM = 1.5;

    // Diff in [-180, +180]
    double diff = (targetBearing - _cameraBearing + 360) % 360;
    if (diff > 180) diff -= 360;
    final double absDiff = diff.abs();

    // Big jump (es. cambio step su svolta) → rotazione graduale.
    if (absDiff > 90) {
      _applyGradualBearing(lat, lng, targetBearing);
      return;
    }

    // Throttle: skip se né bearing né posizione cambiano abbastanza.
    final double posDelta = (_lastAppliedLat == null || _lastAppliedLng == null)
        ? double.infinity
        : haversineDistance(_lastAppliedLat!, _lastAppliedLng!, lat, lng);
    if (absDiff < kMinBearingDeltaDeg && posDelta < kMinPosDeltaM) {
      return;
    }

    _cameraBearing = targetBearing;
    _lastAppliedLat = lat;
    _lastAppliedLng = lng;
    _mapKey.currentState?.followUser(lat, lng, targetBearing);
  }

  // ===========================================================================

  /// Mostra un dialog di conferma per terminare la navigazione.
  ///
  /// Design accessibile per utenti con disabilità cognitive:
  /// - Testi grandi e chiari
  /// - Due pulsanti grandi "Sì" / "No" con colori distinti
  /// - Nessun gesto nascosto, nessuna ambiguità
  Future<void> _showStopNavigationDialog() async {
    final bool? conferma = await showDialog<bool>(
      context: context,
      barrierDismissible: false, // Impedisce chiusura toccando fuori
      builder: (BuildContext ctx) {
        return AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          contentPadding: const EdgeInsets.fromLTRB(24, 28, 24, 12),
          actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
          content: const Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.help_outline, size: 48, color: Colors.orange),
              SizedBox(height: 16),
              Text(
                'Vuoi fermarti?',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  height: 1.3,
                ),
              ),
              SizedBox(height: 8),
              Text(
                'La navigazione verrà fermata',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 16,
                  color: Colors.grey,
                ),
              ),
            ],
          ),
          actionsAlignment: MainAxisAlignment.spaceEvenly,
          actions: [
            // Pulsante "No" — grande, bordo grigio, rassicurante
            SizedBox(
              width: 120,
              height: 56,
              child: OutlinedButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                style: OutlinedButton.styleFrom(
                  side: BorderSide(color: Colors.grey.shade400, width: 2),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                child: const Text(
                  'No',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: Colors.black87,
                  ),
                ),
              ),
            ),
            // Pulsante "Sì" — grande, rosso, azione distruttiva evidente
            SizedBox(
              width: 120,
              height: 56,
              child: ElevatedButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red.shade600,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                child: const Text(
                  'Sì',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );

    // Se l'utente ha confermato, resetta la navigazione
    if (conferma == true) {
      _resetNavigation();
    }
  }

  // ===========================================================================
  // GESTORE NAVIGAZIONE: STORICO E PULSANTE INDIETRO
  // ===========================================================================

  /// Salva lo stato corrente nella cronologia prima di passare a uno nuovo.
  void _saveCurrentStateToHistory() {
    _historyService.pushState(
      _appState,
      data: {
        'address': _selectedDestinationAddress,
        'directions': _directionsResult,
        'allRoutes': _allRoutesResult,
      },
    );
  }

  /// Gestisce il tasto back (fisico Android, swipe iOS, pulsante UI).
  /// Restituisce true se l'app deve chiudersi, false se l'azione è assorbita internamente.
  Future<bool> _handleBack() async {
    // 1. Se la BARRA DI RICERCA ha il focus (tastiera aperta, suggerimenti visibili):
    if (_searchFocusNode.hasFocus) {
      _searchFocusNode.unfocus();
      _destinationController.clear();

      // Se siamo nella home (search), consumiamo il back qui — l'utente
      // voleva solo chiudere la tastiera e i suggerimenti.
      // Se siamo in un altro stato (placeSelected, routePreview),
      // NON facciamo return: lasciamo che il codice sotto esegua
      // il goBack() così l'utente torna indietro con UN SOLO tap.
      if (_appState == NavigationAppState.search) {
        return false;
      }
      // Altrimenti: cade nel goBack sotto ↓
    }

    if (!_historyService.canGoBack) {
      // 2. Controllo testuale: se siamo nella home ma la barra ha del testo scritto,
      // puliamola invece di uscire bruscamente.
      if (_appState == NavigationAppState.search && _destinationController.text.isNotEmpty) {
         _destinationController.clear();
         return false;
      }

      // Siamo alla root (search). Mostriamo popup conferma uscita.
      final bool? exit = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Uscire dall\'app?'),
          content: const Text('Sei sicuro di voler chiudere l\'applicazione?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Annulla'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red.shade600,
                foregroundColor: Colors.white,
              ),
              child: const Text('Esci'),
            ),
          ],
        ),
      );
      return exit ?? false;
    }

    final previousEntry = _historyService.goBack();
    if (previousEntry != null) {
      // Se eravamo in navigazione, fermiamola e resetta TUTTO lo stato
      // di navigazione. Senza questo cleanup l'overlay, il follow-mode,
      // il banner di reroute e lo stato arrivo restano "fantasma" e la
      // UI sembra non reagire al back.
      if (_appState == NavigationAppState.navigating) {
        _navigationMonitor.stopNavigation();
        _routeChangedAnimTimer?.cancel();
        _arrivalAnimTimer?.cancel();
        // FIX BUG 3 (B3.6): cleanup TTS sull'uscita dalla navigazione via back.
        _resetTtsState();
      }

      setState(() {
        _appState = previousEntry.state;

        // --- Cleanup navigazione (allineato a _resetNavigation) ---
        _overlayState = null;
        _isFollowingUser = false;
        _reroutePhase = ReroutePhase.none;
        _routeChangedAnimStep = 0;
        _isArrived = false;
        _arrivalAnimStep = 0;
        _walkedPath = [];
        _isReviewingWalkedPath = false;
        _progress = null; // FIX BUG 1+2: reset progress

        // --- Se torniamo alla ricerca, puliamo TUTTO ---
        // L'entry root "search" non ha dati salvati, quindi senza questo
        // blocco la destinazione e il percorso resterebbero fantasma.
        if (previousEntry.state == NavigationAppState.search) {
          _selectedDestinationAddress = null;
          _destinationController.clear();
          _directionsResult = null;
          _allRoutesResult = null;
        }

        // --- Ripristino dati dallo stack ---
        if (previousEntry.data != null) {
          if (previousEntry.data!.containsKey('address')) {
            _selectedDestinationAddress = previousEntry.data!['address'] as String?;
            _destinationController.text = _selectedDestinationAddress ?? '';
          }
          if (previousEntry.data!.containsKey('directions')) {
            _directionsResult = previousEntry.data!['directions'] as DirectionsResult?;
          }
          if (previousEntry.data!.containsKey('allRoutes')) {
            _allRoutesResult = previousEntry.data!['allRoutes'] as AllRoutesResult?;
          }
        }
      });
    }
    return false;
  }

  // ===========================================================================
  // RESET NAVIGAZIONE
  // ===========================================================================

  /// Resetta completamente lo stato della navigazione.
  ///
  /// Chiamato quando l'utente chiude la navigazione attiva o il route preview.
  /// Pulisce TUTTI i dati del percorso precedente per evitare che rimangano
  /// indicazioni, polyline e marker fantasma sulla mappa.
  ///
  /// SIDE EFFECTS:
  /// - Ferma il NavigationMonitor (timer, notifier)
  /// - Azzera DirectionsResult e AllRoutesResult
  /// - Pulisce il campo di testo della destinazione
  /// - Riporta lo stato UI a [search]
  void _resetNavigation() {
    _navigationMonitor.stopNavigation();
    _routeChangedAnimTimer?.cancel();
    _arrivalAnimTimer?.cancel();
    // FIX BUG 3 (B3.6): cleanup TTS al reset così non parla mentre si
    // torna alla schermata di ricerca.
    _resetTtsState();
    setState(() {
      _appState = NavigationAppState.search;
      _directionsResult = null;
      _allRoutesResult = null;
      _selectedDestinationAddress = null;
      _overlayState = null;
      _isFollowingUser = false;
      _reroutePhase = ReroutePhase.none;
      _routeChangedAnimStep = 0;
      _isArrived = false;
      _arrivalAnimStep = 0;
      _walkedPath = [];
      _isReviewingWalkedPath = false;
      _progress = null; // FIX BUG 1+2: pulizia progress a fine navigazione
      _destinationController.clear();
    });
    // Ripulisce lo stack e riparte dalla home
    _historyService.clearToRoot(NavigationAppState.search);
  }

  void _showTemporaryError(String message) {
    _errorBannerTimer?.cancel();

    if (!mounted) return;
    setState(() {
      _errorMessage = message;
    });

    _errorBannerTimer = Timer(_errorBannerDuration, () {
      if (!mounted) return;
      setState(() {
        _errorMessage = null;
      });
    });
  }

  // ===========================================================================
  // LOGICA CALCOLO E TRANSIZIONE STATI
  // ===========================================================================

  /// Inizia il calcolo del percorso quando l'utente sceglie "Indicazioni".
  /// Prima di questo metodo, siamo nello stato [placeSelected].
  Future<void> _calculateRouteForSelectedPlace() async {
    final lat = _allRoutesResult?.destLat ?? _directionsResult?.destLat;
    final lng = _allRoutesResult?.destLng ?? _directionsResult?.destLng;
    if (lat == null || lng == null) return;

    await _calculateRouteFromCoordinates(
      lat,
      lng,
      _selectedDestinationAddress ?? '',
    );

    // Se ha calcolato correttamente
    if (_directionsResult != null) {
      // Aggiorna i dati dell'entry corrente (placeSelected) con il percorso
      // appena calcolato, così il back restaura dati coerenti.
      _historyService.updateTopData({
        'address': _selectedDestinationAddress,
        'directions': _directionsResult,
        'allRoutes': _allRoutesResult,
      });

      // Pusha il nuovo stato routePreview
      _historyService.pushState(
        NavigationAppState.routePreview,
        data: {
          'address': _selectedDestinationAddress,
          'directions': _directionsResult,
          'allRoutes': _allRoutesResult,
        },
      );

      setState(() {
        _appState = NavigationAppState.routePreview;
      });
    }
  }

  /// Avvia la navigazione reale (sia dal route preview sia diretti dal placeSelected)
  Future<void> _startActiveNavigation() async {
    // Se non abbiamo ancora un percorso (es. ha cliccato Avvia subito da placeSelected),
    // calcoliamo il percorso prima di avviare.
    if (_allRoutesResult == null || _directionsResult?.steps.isEmpty == true) {
      final lat = _allRoutesResult?.destLat ?? _directionsResult?.destLat;
      final lng = _allRoutesResult?.destLng ?? _directionsResult?.destLng;
      if (lat != null && lng != null) {
        await _calculateRouteFromCoordinates(
          lat,
          lng,
          _selectedDestinationAddress ?? '',
        );
      }
    }

    if (_allRoutesResult != null) {
      // PRIMA di pushare "navigating", aggiorna i dati dell'entry corrente
      // (placeSelected o routePreview) con i dati FRESCHI post-calcolo.
      // Senza questo, il goBack() restaurerebbe il placeholder vuoto
      // che era stato salvato quando l'entry fu pushata la prima volta.
      _historyService.updateTopData({
        'address': _selectedDestinationAddress,
        'directions': _directionsResult,
        'allRoutes': _allRoutesResult,
      });

      // Ora pusha il nuovo stato "navigating"
      _historyService.pushState(
        NavigationAppState.navigating,
        data: {
          'address': _selectedDestinationAddress,
          'directions': _directionsResult,
          'allRoutes': _allRoutesResult,
        },
      );

      setState(() {
        _appState = NavigationAppState.navigating;
        _isFollowingUser = true;
        // Reset stato arrivo/review per una nuova navigazione
        _walkedPath = [];
        _isArrived = false;
        _arrivalAnimStep = 0;
        _isReviewingWalkedPath = false;
      });

      // FIX BUG 3 (B3.6): cleanup TTS prima di iniziare una nuova navigazione,
      // così eventuali frasi residue ("Sto cercando una strada migliore",
      // pending non ancora pronunciate) non si accavallano sulle istruzioni
      // della nuova sessione.
      _resetTtsState();

      // FIX: Passa le COORDINATE della destinazione (formato "lat,lng"),
      // NON l'indirizzo testuale. Il monitor usa _originalDestination per
      // i ricalcoli (Task 2c): se passiamo il testo, ogni ricalcolo
      // ri-geocodifica l'indirizzo ottenendo coordinate leggermente diverse
      // → polyline diversa → falsi ricalcoli a catena.
      final String destCoords =
          '${_allRoutesResult!.destLat},${_allRoutesResult!.destLng}';
      _navigationMonitor.startNavigation(_allRoutesResult!, destCoords);

      // Posiziona ISTANTANEAMENTE la camera sulla posizione utente,
      // ORIENTATA verso la direzione del percorso. Usa snapToRoute
      // (moveCamera) invece di followUser (animateCamera) per evitare
      // il lag — la mappa si sposta subito senza transizione animata.
      final double startLat = _currentLat ?? _allRoutesResult!.originLat;
      final double startLng = _currentLng ?? _allRoutesResult!.originLng;

      final double routeBearing = _getRouteBearing();
      _cameraBearing = routeBearing;
      _mapKey.currentState?.snapToRoute(
        startLat,
        startLng,
        routeBearing,
      );
    }
  }

  /// Calcola il percorso da coordinate GPS (TASK 4).
  ///
  /// Questo metodo è il punto d'ingresso unificato per il calcolo del percorso,
  /// chiamato sia dalla ricerca testuale (TASK 2) che dalla selezione mappa (TASK 3).
  ///
  /// FLUSSO:
  /// 1. Usa la posizione GPS corrente come ORIGINE
  /// 2. Usa le coordinate passate come DESTINAZIONE
  /// 3. Chiama Directions API con alternatives=true
  /// 4. Seleziona il percorso più veloce
  /// 5. Salva tutti i percorsi per il monitoraggio (TASK 5)
  /// 6. Avvia il timer di monitoraggio ogni 2 secondi
  ///
  /// PARAMETRI:
  /// - [destLat]: latitudine della destinazione
  /// - [destLng]: longitudine della destinazione
  /// - [destAddress]: indirizzo leggibile della destinazione (per display e ricalcolo)
  Future<void> _calculateRouteFromCoordinates(
      double destLat,
      double destLng,
      String destAddress,
      ) async {
    // Verifica che la posizione GPS sia disponibile.
    // Senza la posizione dell'utente, non possiamo calcolare un percorso
    // perché non sappiamo da dove partire.
    if (_currentLat == null || _currentLng == null) {
      _showTemporaryError(
        'Non riesco a trovarti sulla mappa. Aspetta un momento e riprova!',
      );
      return;
    }

    _errorBannerTimer?.cancel();
    // Imposta lo stato di caricamento
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      // Costruisce la stringa di origine come coordinate GPS.
      // Il formato "lat,lng" è accettato dalla Directions API.
      final String origin = '$_currentLat,$_currentLng';

      // Costruisce la stringa di destinazione come coordinate GPS.
      // Usiamo le coordinate esatte anziché l'indirizzo testuale perché:
      // 1. È più preciso (nessuna ambiguità di geocoding)
      // 2. Funziona anche per punti sulla mappa senza indirizzo
      final String destination = '$destLat,$destLng';

      // Registra la ricerca prima della request API.
      // Vale per qualsiasi sorgente (barra ricerca o tap mappa)
      // indipendentemente dal successo della chiamata.
      await _searchHistoryService.recordSearch(
        SearchHistoryItem(
          address: destAddress,
          lat: destLat,
          lng: destLng,
          timestamp: DateTime.now().millisecondsSinceEpoch,
        ),
      );

      // Chiama l'API con percorsi alternativi (TASK 4).
      // Questo metodo:
      // 1. Invia la richiesta con alternatives=true
      // 2. Parsifica TUTTI i percorsi dalla risposta
      // 3. Ordina per durata e seleziona il migliore
      // 4. Restituisce AllRoutesResult con bestRoute + allRoutes
      final result = await _directionsService.getDirectionsWithAlternatives(
        origin: origin,
        destination: destination,
      );

      // Aggiorna lo stato con il risultato
      if (result != null) {
        setState(() {
          _isLoading = false;

          // Salva il risultato completo con tutti i percorsi (TASK 4)
          _allRoutesResult = result;

          // Crea un DirectionsResult dal percorso migliore per compatibilità
          // con i widget esistenti (MapWidget, DirectionsList)
          _directionsResult = DirectionsResult(
            steps: result.bestRoute.steps,
            totalDistance: result.bestRoute.totalDistance,
            totalDuration: result.bestRoute.totalDuration,
            // FIX BUG 1: popolo anche i campi numerici
            totalDistanceMeters: result.bestRoute.totalDistanceMeters,
            totalDurationSeconds: result.bestRoute.totalDurationSeconds,
            encodedPolyline: result.bestRoute.encodedPolyline,
            originLat: result.originLat,
            originLng: result.originLng,
            destLat: result.destLat,
            destLng: result.destLng,
          );
          _errorMessage = null;
        });

        // NOTA: NON avviamo la navigazione qui. _calculateRouteFromCoordinates
        // è usato sia da "Indicazioni" (preview) sia da "Avvia" (navigazione).
        // Solo _startActiveNavigation() deve chiamare startNavigation(),
        // altrimenti:
        // 1. "Indicazioni" avvierebbe i timer di monitoraggio prematuramente
        // 2. "Avvia" chiamerebbe startNavigation() DUE VOLTE (qui + in
        //    _startActiveNavigation), creando timer duplicati
      } else {
        setState(() {
          _isLoading = false;
        });
        _showTemporaryError('Non riesco a trovare la strada. Riprova!');
      }
    } catch (e) {
      // Gestisce eventuali errori
      setState(() {
        _isLoading = false;
      });
      _showTemporaryError('Qualcosa non ha funzionato. Riprova!');
    }
  }

  // ===========================================================================
  // HANDLERS SELEZIONE DESTINAZIONE
  // ===========================================================================

  /// Callback chiamato quando l'utente seleziona un indirizzo dall'autocomplete (TASK 2).
  ///
  /// Questo è il punto finale del flusso TASK 2:
  /// digitazione → debounce → autocomplete → selezione → details → QUI
  ///
  /// PARAMETRI:
  /// - [lat]: latitudine del luogo selezionato (da Places Details API)
  /// - [lng]: longitudine del luogo selezionato
  /// - [address]: indirizzo formattato del luogo
  void _onDestinationSelected(double lat, double lng, String address) {
    // Log per debugging
    print('Destinazione selezionata da ricerca: $address ($lat, $lng)');

    // Salva subito in cronologia (fire-and-forget, dedup gestito dal service)
    // Poi ricarica la cronologia aggiornata per riflettere la nuova ricerca.
    _searchHistoryService
        .recordSearch(
      SearchHistoryItem(
        address: address,
        lat: lat,
        lng: lng,
        timestamp: DateTime.now().millisecondsSinceEpoch,
      ),
    )
        .then((_) => _loadRecentSearches())
        .catchError((e) => print('Errore salvataggio cronologia: $e'));

    _saveCurrentStateToHistory();
    setState(() {
      _selectedDestinationAddress = address;
      _appState = NavigationAppState.placeSelected;

      // Imposta le coordinate della destinazione per posizionare il pin sulla mappa,
      // ma senza calcolare ancora il percorso (lo calcoliamo quando clicca 'Indicazioni').
      _directionsResult = DirectionsResult(
        steps: [],
        totalDistance: '',
        totalDuration: '',
        // Placeholder senza percorso → totali a zero
        totalDistanceMeters: 0,
        totalDurationSeconds: 0,
        encodedPolyline: '', // Nessun percorso
        originLat: _currentLat ?? 0,
        originLng: _currentLng ?? 0,
        destLat: lat,
        destLng: lng,
      );
      _allRoutesResult = null; // Resetta i percorsi vecchi se presenti
    });

    // Pusha placeSelected con i dati appena impostati.
    // Il push precedente salva lo stato da cui veniamo (search),
    // questo salva il nuovo stato placeSelected.
    _historyService.pushState(
      NavigationAppState.placeSelected,
      data: {
        'address': _selectedDestinationAddress,
        'directions': _directionsResult,
        'allRoutes': _allRoutesResult,
      },
    );
  }

  /// Callback chiamato quando l'utente tocca un punto sulla mappa (TASK 3).
  ///
  /// FLUSSO:
  /// 1. Mostra SUBITO il bottom sheet con "Caricamento..." (UI reattiva)
  /// 2. Chiama reverseGeocode() in background per ottenere il nome del posto
  /// 3. Aggiorna il nome quando la risposta arriva
  /// 4. Se la geocodifica fallisce, usa le coordinate come fallback
  ///
  /// PARAMETRI:
  /// - [position]: coordinate del punto toccato sulla mappa
  void _onMapTapped(LatLng position) {
    // Se la tastiera è aperta, la chiudiamo MA procediamo comunque
    // con la selezione del posto. Prima il tap veniva "consumato"
    // solo per chiudere la tastiera, costringendo l'utente a tappare
    // DUE volte — troppo confuso per ragazzi con disabilità cognitive.
    if (FocusManager.instance.primaryFocus?.hasFocus ?? false) {
      FocusManager.instance.primaryFocus?.unfocus();
    }

    // Se eravamo in routePreview, puliamo il percorso precedente
    // prima di selezionare il nuovo posto.
    if (_appState == NavigationAppState.routePreview) {
      _navigationMonitor.stopNavigation();
    }

    // Placeholder temporaneo mentre la geocodifica è in corso
    const String loadingText = 'Cerco il nome del posto...';

    // Log per debugging
    print('Punto mappa selezionato: ${position.latitude}, ${position.longitude}');

    // STEP 1: Mostra SUBITO il bottom sheet con placeholder.
    // L'utente vede una risposta immediata al tocco — non deve aspettare
    // la risposta di rete per capire che il tap è stato registrato.
    _destinationController.text = loadingText;
    setState(() {
      _selectedDestinationAddress = loadingText;
      _appState = NavigationAppState.placeSelected;

      _directionsResult = DirectionsResult(
        steps: [],
        totalDistance: '',
        totalDuration: '',
        // Placeholder senza percorso → totali a zero
        totalDistanceMeters: 0,
        totalDurationSeconds: 0,
        encodedPolyline: '',
        originLat: _currentLat ?? 0,
        originLng: _currentLng ?? 0,
        destLat: position.latitude,
        destLng: position.longitude,
      );
      _allRoutesResult = null;
    });

    // Se arriviamo da routePreview, il vecchio percorso non serve più.
    // Ripuliamo lo stack e ripartiamo da search → placeSelected.
    // Senza questo, il back tornerebbe alla routePreview del VECCHIO posto.
    _historyService.clearToRoot(NavigationAppState.search);
    _historyService.pushState(
      NavigationAppState.placeSelected,
      data: {
        'address': loadingText,
        'directions': _directionsResult,
        'allRoutes': _allRoutesResult,
      },
    );

    // STEP 2: Chiama reverse geocoding in background.
    // Non usiamo await perché non vogliamo bloccare la UI.
    _placesService.reverseGeocode(
      position.latitude,
      position.longitude,
    ).then((String? address) {
      // Verifica che il widget sia ancora montato e che l'utente non abbia
      // già selezionato un'altra destinazione nel frattempo.
      if (!mounted) return;
      if (_appState != NavigationAppState.placeSelected) return;

      // STEP 3: Aggiorna il nome del posto.
      // Se reverseGeocode ha restituito un indirizzo, lo usiamo.
      // Altrimenti usiamo le coordinate come fallback leggibile.
      final String displayName = address ??
          '${position.latitude.toStringAsFixed(5)}, '
              '${position.longitude.toStringAsFixed(5)}';

      setState(() {
        _selectedDestinationAddress = displayName;
      });
      _destinationController.text = displayName;

      print('Reverse geocoding risultato: $displayName');
    });
  }

  // ===========================================================================
  // BUILD UI
  // ===========================================================================

  @override
  Widget build(BuildContext context) {
    try {
      // Determina se siamo su un dispositivo mobile (schermo stretto)
      final isMobile = MediaQuery.of(context).size.width < 800;

      return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final bool shouldExit = await _handleBack();
        if (shouldExit && mounted) {
          SystemNavigator.pop();
        }
      },
      child: Scaffold(
        // App Bar
        appBar: AppBar(
          leading: _historyService.canGoBack
              ? IconButton(
                  icon: Icon(
                    Platform.isIOS ? Icons.arrow_back_ios_new : Icons.arrow_back,
                  ),
                  onPressed: () async {
                    final bool shouldExit = await _handleBack();
                    if (shouldExit && mounted) {
                      SystemNavigator.pop();
                    }
                  },
                )
              : null,
          title: const Text(
            'La mia mappa',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
          ),
          backgroundColor: Colors.blue,
          foregroundColor: Colors.white,
          elevation: 0,
        ),
        // Corpo principale
        body: isMobile
            ? _buildMobileLayout() // Layout verticale per mobile
            : _buildDesktopLayout(), // Layout orizzontale per desktop
      ),
    );
    } catch (e, stackTrace) {
      print('❌ ERRORE NEL BUILD DI NAVIGATIONSCREEN:');
      print('$e');
      print('Stack trace: $stackTrace');
      return Scaffold(
        appBar: AppBar(title: const Text('Errore')),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.red),
              const SizedBox(height: 16),
              const Text('Errore nel caricamento dell\'app'),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text('$e',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 12)),
              ),
            ],
          ),
        ),
      );
    }
  }

  /// Layout per dispositivi mobili (stack verticale)
  Widget _buildMobileLayout() {
    return Stack(
      fit: StackFit.expand,
      children: [
        // --- LAYER 1: Mappa Google ---
        MapWidget(
          key: _mapKey,
          originLat: _directionsResult?.originLat,
          originLng: _directionsResult?.originLng,
          destLat: _directionsResult?.destLat,
          destLng: _directionsResult?.destLng,
          encodedPolyline: _directionsResult?.encodedPolyline,
          // NAVIGAZIONE ACCESSIBILE: passa stato navigazione, step corrente
          // e lista step con polyline individuali per la visualizzazione
          // a segmenti (verde=corrente, grigio=successivo, nascosto=resto).
          // In modalità review (post-arrivo), disattiviamo la segmentazione
          // per mostrare la overview polyline completa + la walked path.
          isNavigating: _appState == NavigationAppState.navigating &&
              !_isArrived &&
              !_isReviewingWalkedPath,
          currentStepIndex: _navigationMonitor.currentStepNotifier.value,
          steps: _directionsResult?.steps,
          // FRECCIA DIREZIONALE: posizione e heading della bussola.
          // La freccia punta dove il TELEFONO è girato (bussola/magnetometro),
          // NON nella direzione di marcia GPS. Così l'utente vede:
          // - Freccia = dove sto guardando (bussola)
          // - Corridoio verde = dove devo andare (percorso)
          // - Se non coincidono → mi devo girare
          // Fallback: se la bussola non è disponibile, usa il bearing GPS.
          userLat: _currentLat,
          userLng: _currentLng,
          userBearing: _compassStream != null
              ? _compassHeading
              : (_navigationMonitor.direction ?? _rawBearing),
          // PERCORSO EFFETTUATO: lista coordinate GPS registrate durante
          // la navigazione. Mostrate come polyline verde nella review.
          walkedPath: _isReviewingWalkedPath ? _walkedPath : null,
          // TASK 3: callback per tap sulla mappa.
          // Attivo in search, placeSelected e routePreview — così l'utente
          // può selezionare un nuovo posto anche mentre vede le indicazioni.
          onMapTap:
          _appState == NavigationAppState.search ||
              _appState == NavigationAppState.placeSelected ||
              _appState == NavigationAppState.routePreview
              ? _onMapTapped
              : null,
          // Callback pan manuale: disattiva il follow-mode
          onUserInteraction: () {
            if (_isFollowingUser) {
              setState(() {
                _isFollowingUser = false;
              });
            }
          },
        ),

        // --- LAYER 2: Pannello Ricerca (NASCOSTO IN NAVIGAZIONE) ---
        if (_appState != NavigationAppState.navigating)
          Positioned(
            top: 8,
            left: 8,
            right: 8,
            child: SafeArea(
              child: SearchInput(
                destinationController: _destinationController,
                focusNode: _searchFocusNode,
                onDestinationSelected: _onDestinationSelected,
                isLoading: _isLoading,
                recentSearches: _recentSearches,
              ),
            ),
          ),

        // Messaggio di errore
        if (_errorMessage != null)
          Positioned(
            top: 90,
            left: 8,
            right: 8,
            child: SafeArea(child: _buildErrorMessage()),
          ),

        // --- LAYER 3: Overlay Velocità ---
        // Modifichiamo la pozione in base allo stato in modo che non si sovrapponga ai bottom sheet
        _buildSpeedOverlay(),

        // --- LAYER 5: BOTTOM SHEETS & TOP BANNER ---
        if (_appState == NavigationAppState.placeSelected)
          _buildPlaceSelectedSheet(),

        if (_appState == NavigationAppState.navigating)
          _isArrived
              ? _buildArrivalUI()
              : _isReviewingWalkedPath
              ? _buildWalkedPathReviewUI()
              : _buildNavigatingUI(),

        if (_appState == NavigationAppState.routePreview &&
            _directionsResult != null)
          _buildRoutePreviewSheet(),

        // --- LAYER 7: TASTO "IO" (RECENTER) ---
        // Visibile in TUTTI gli stati dell'app quando il GPS è disponibile.
        // "Io" è più intuitivo di un'icona astratta (mirino GPS) per
        // ragazzi con disabilità cognitive: capiscono subito che il tasto
        // li riporta alla PROPRIA posizione sulla mappa.
        //
        // In navigazione: riattiva il follow-mode (camera insegue GPS).
        // Negli altri stati: centra la mappa sulla posizione corrente.
        //
        // FIX BUG 6a: Nascosto durante il ricalcolo del percorso
        // (offRoute / rerouting / routeChanged). Il bottom sheet arancione
        // occupa gran parte dello schermo e il pulsante "Io" creerebbe
        // sovrapposizione visiva, inoltre non ha senso permettere il
        // recenter mentre l'app sta cambiando rotta.
        //
        // FIX BUG 6a: Nascosto anche durante l'arrivo a destinazione
        // (_isArrived). Il bottom sheet di arrivo ha i suoi controlli.
        if (_currentLat != null &&
            !_isFollowingUser &&
            _reroutePhase == ReroutePhase.none &&
            !_isArrived)
          Positioned(
            // FIX BUG 6b: bottom calcolato dinamicamente per appoggiarsi
            // SEMPRE appena sopra il bottom sheet dello stato corrente,
            // indipendentemente dalla safe area del device.
            // Prima era un valore fisso (210 in navigazione) che su device
            // senza safe area (Android) lasciava spazio morto in basso,
            // mentre su iPhone con safe area ampia rischiava
            // sovrapposizione.
            bottom: _computeRecenterButtonBottom(context),
            right: 16,
            child: GestureDetector(
              onTap: _onRecenterPressed,
              child: Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: Colors.blue.shade600,
                  shape: BoxShape.circle,
                  boxShadow: const [
                    BoxShadow(
                      color: Colors.black26,
                      blurRadius: 8,
                      offset: Offset(0, 4),
                    ),
                  ],
                ),
                child: const Center(
                  child: Text(
                    'Io',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
              ),
            ),
          ),

        // --- LAYER 8: Overlay Navigazione ---
        // DEVE stare sopra il banner di navigazione (LAYER 5) per essere visibile.
        // L'overlay arancione di incertezza deve coprire il riquadro verde delle istruzioni.
        NavigationOverlay(
          state: _overlayState,
          onDismiss: () {
            // Resettiamo SOLO lo stato locale della UI.
            // NON tocchiamo overlayNotifier.value: farlo causerebbe un
            // loop circolare (onDismiss → notifier=null → _onOverlayChanged
            // → setState) e potrebbe interrompere l'animazione di fade-out
            // in corso perché il widget verrebbe ricostruito con state=null
            // prima che reverse() sia completato.
            setState(() {
              _overlayState = null;
            });
          },
        ),
      ],
    );
  }


  /// Layout per desktop (pannello laterale)
  Widget _buildDesktopLayout() {
    return Row(
      children: [
        // Pannello laterale sinistro (ricerca + indicazioni)
        SizedBox(
          width: 380,
          child: Column(
            children: [
              // Input ricerca
              Padding(
                padding: const EdgeInsets.all(12.0),
                child: SearchInput(
                  destinationController: _destinationController,
                  focusNode: _searchFocusNode,
                  onDestinationSelected: _onDestinationSelected,
                  isLoading: _isLoading,
                  recentSearches: _recentSearches,
                ),
              ),

              // Messaggio di errore
              if (_errorMessage != null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12.0),
                  child: _buildErrorMessage(),
                ),

              // Lista indicazioni (se disponibile)
              if (_directionsResult != null)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(12.0),
                    child: DirectionsList(
                      steps: _directionsResult!.steps,
                      totalDistance: _directionsResult!.totalDistance,
                      totalDuration: _directionsResult!.totalDuration,
                    ),
                  ),
                ),
            ],
          ),
        ),

        // Mappa (occupa il resto dello spazio)
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(12.0),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // --- LAYER 1: Mappa Google ---
                  SizedBox.expand(
                    child: MapWidget(
                      key: _mapKey,
                      originLat: _directionsResult?.originLat,
                      originLng: _directionsResult?.originLng,
                      destLat: _directionsResult?.destLat,
                      destLng: _directionsResult?.destLng,
                      encodedPolyline: _directionsResult?.encodedPolyline,
                      // NAVIGAZIONE ACCESSIBILE (stessi parametri del mobile)
                      isNavigating: _appState == NavigationAppState.navigating &&
                          !_isArrived &&
                          !_isReviewingWalkedPath,
                      currentStepIndex: _navigationMonitor.currentStepNotifier.value,
                      steps: _directionsResult?.steps,
                      // FRECCIA DIREZIONALE (stessi parametri del mobile)
                      userLat: _currentLat,
                      userLng: _currentLng,
                      userBearing: _compassStream != null
                          ? _compassHeading
                          : (_navigationMonitor.direction ?? _rawBearing),
                      // PERCORSO EFFETTUATO (review post-arrivo)
                      walkedPath: _isReviewingWalkedPath ? _walkedPath : null,
                      // TASK 3: callback per tap sulla mappa
                      onMapTap: _onMapTapped,
                      // Callback pan manuale: disattiva il follow-mode
                      onUserInteraction: () {
                        if (_isFollowingUser) {
                          setState(() {
                            _isFollowingUser = false;
                          });
                        }
                      },
                    ),
                  ),

                  // --- LAYER 2: Overlay velocità ---
                  _buildSpeedOverlay(),

                  // --- LAYER 3: Overlay navigazione ---
                  NavigationOverlay(
                    state: _overlayState,
                    onDismiss: () {
                      setState(() {
                        _overlayState = null;
                      });
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ===========================================================================
  // WIDGET HELPER (Bottom Sheets)
  // ===========================================================================

  /// Scheda minimale che compare in fondo quando selezioniamo una destinazione.
  /// Design accessibile: pulsanti grandi, testo chiaro, colori evidenti.
  Widget _buildPlaceSelectedSheet() {
    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 10)],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Etichetta sopra l'indirizzo
            Text(
              'Vuoi andare qui?',
              style: TextStyle(
                fontSize: 16,
                color: Colors.grey.shade600,
              ),
            ),
            const SizedBox(height: 4),
            // Indirizzo della destinazione — grande e chiaro
            Text(
              _selectedDestinationAddress ?? 'Destinazione',
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 20),
            // Pulsanti — grandi, con icone evidenti
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _calculateRouteForSelectedPlace,
                    icon: const Icon(Icons.directions, size: 24),
                    label: const Text(
                      'Vedi percorso',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(30),
                      ),
                      side: BorderSide(color: Colors.blue.shade400, width: 2),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _startActiveNavigation,
                    icon: const Icon(Icons.navigation, size: 24),
                    label: const Text(
                      'Andiamo!',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green.shade600,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(30),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// DraggableScrollableSheet per mostrare in overlay i dettagli del percorso e gli step
  Widget _buildRoutePreviewSheet() {
    return DraggableScrollableSheet(
      initialChildSize: 0.35,
      minChildSize: 0.2,
      maxChildSize: 0.8,
      builder: (context, scrollController) {
        return Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
            boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 10)],
          ),
          child: SingleChildScrollView(
            controller: scrollController,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Maniglia di scorrimento (dragger)
                Center(
                  child: Container(
                    margin: const EdgeInsets.all(8),
                    height: 4,
                    width: 40,
                    decoration: BoxDecoration(
                      color: Colors.grey.shade400,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                DirectionsList(
                  steps: _directionsResult!.steps,
                  totalDistance: _directionsResult!.totalDistance,
                  totalDuration: _directionsResult!.totalDuration,
                  shrinkWrap:
                  true, // Impedisce all'interno di estendersi all'infinito spezzando lo scroll
                  onStartPressed: _startActiveNavigation,
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Interfaccia attiva in Navigazione (Top Banner e Bottom Info Sheet minimale senza pulsanti)
  Widget _buildNavigatingUI() {
    return Stack(
      children: [
        // TOP BANNER — CARD DIREZIONALE ACCESSIBILE
        //
        // Design pensato per utenti con disabilità cognitive:
        // - Freccia direzionale GIGANTE (80px) come elemento primario
        // - Colore sfondo cambia in base alla direzione (verde=dritto, arancione=sinistra...)
        // - Testo grande e semplice (solo istruzione corrente, nessun "Poi:")
        // - Card arrotonata con ombra per distinguerla dalla mappa
        //
        // FIX SOVRAPPOSIZIONE: il banner viene nascosto con AnimatedOpacity
        // quando un NavigationOverlay è attivo (_overlayState != null).
        // L'overlay (svolta, strada laterale) occupa la stessa posizione
        // in alto; senza questo fade-out i due widget si accavallano
        // rendendo illeggibili entrambi.
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: IgnorePointer(
            ignoring: _overlayState != null,
            child: AnimatedOpacity(
              opacity: _overlayState != null ? 0.0 : 1.0,
              duration: const Duration(milliseconds: 250),
              // FIX: Rimosso ValueListenableBuilder.
              // PROBLEMA: quando il percorso veniva ricalcolato (reroute),
              // il monitor resettava currentStepNotifier.value a 0. Se era
              // GIÀ 0 (primo step), il ValueListenableBuilder non si ricostruiva
              // perché il valore non era cambiato → banner bloccato sulle
              // vecchie istruzioni.
              //
              // SOLUZIONE: leggiamo currentStepNotifier.value direttamente.
              // Qualsiasi setState (da _onActiveRouteChanged, _onStepChanged,
              // o qualsiasi altra fonte) ricostruisce il banner con i dati
              // aggiornati (nuovi step + indice corretto).
              //
              // FIX BUG 3 (B3.4): usiamo ValueListenableBuilder così il
              // banner si aggiorna ANCHE se per qualche motivo nessun
              // setState del parent gira (robustezza). Prima dipendevamo
              // dal fatto che _onStepChanged() chiamasse setState.
              child: ValueListenableBuilder<int>(
                valueListenable: _navigationMonitor.currentStepNotifier,
                builder: (context, currentStepIndex, _) {
                  final steps = _directionsResult?.steps ?? [];

              if (steps.isEmpty) {
                return _buildFallbackBanner();
              }

              // FIX BUG 2 — Banner mostra la PROSSIMA SVOLTA, non l'azione
              // iniziale dello step corrente.
              //
              // Google Directions definisce step[i].instruction come
              // "azione da compiere all'INIZIO dello step i" (es. "Svolta
              // a destra" all'imbocco di Via Verdi). Con la vecchia
              // semantica, dopo che l'utente aveva svoltato continuava a
              // vedere "Svolta a destra" per tutto il segmento, fino al
              // waypoint successivo.
              //
              // NUOVA SEMANTICA:
              //   - currentStepIndex = step che l'utente sta percorrendo
              //     ORA (aggiornato con la logica approach-then-leave del
              //     monitor, vedi BUG 2 in navigation_monitor.dart).
              //   - Banner mostra steps[currentStepIndex + 1]: la prossima
              //     azione da effettuare (tipicamente una svolta).
              //   - Distanza = distanza dinamica dall'utente alla fine
              //     dello step corrente (= inizio del prossimo step).
              //     Questo valore CALA mentre l'utente cammina, dando un
              //     preavviso utile per ragazzi con disabilità cognitive.
              //   - Se non c'è un prossimo step (utente nell'ULTIMO tratto),
              //     mostriamo un messaggio di arrivo imminente invece di
              //     lasciare il banner vuoto o statico.
              final int currentSafeIdx = currentStepIndex < steps.length
                  ? currentStepIndex
                  : steps.length - 1;

              final bool isLastStep = currentSafeIdx + 1 >= steps.length;

              // FIX BUG 4 (B4.5): finestra di rinforzo post-svolta.
              // Per ~4s dopo l'avanzamento, mostriamo l'istruzione dello
              // step CORRENTE con un prefisso positivo ("Bravo! Continua
              // su Via Roma"), invece della prossima manovra. Questo
              // evita la sensazione di "indicazione cambia troppo presto"
              // — l'utente ha appena svoltato e vuole conferma, non già
              // la prossima istruzione.
              final bool inReinforcementWindow = !isLastStep &&
                  _lastStepAdvanceAt != null &&
                  DateTime.now().difference(_lastStepAdvanceAt!) <
                      _kPostTurnReinforcementWindow;

              // Lo step da MOSTRARE nel banner è quello successivo al
              // corrente (la prossima svolta), oppure quello corrente
              // durante la finestra di rinforzo.
              final DirectionStep bannerStep;
              if (isLastStep) {
                bannerStep = steps[currentSafeIdx];
              } else if (inReinforcementWindow) {
                bannerStep = steps[currentSafeIdx];
              } else {
                bannerStep = steps[currentSafeIdx + 1];
              }

              // Distanza dinamica alla prossima svolta (valore aggiornato
              // in tempo reale dal progressNotifier). Fallback al valore
              // statico dello step se il progress non è ancora disponibile.
              final String distanceText = _progress != null
                  ? _formatBannerDistance(_progress!.distanceToNextTurn)
                  : bannerStep.distance;

              // Nell'ultimo step non c'è una prossima svolta: il banner
              // ospita un messaggio di arrivo imminente. Durante la
              // finestra di rinforzo, prefissiamo "Bravo!" per dare
              // conferma positiva all'utente.
              final String instructionText;
              if (isLastStep) {
                instructionText = 'Stai arrivando';
              } else if (inReinforcementWindow) {
                instructionText = 'Bravo! ${bannerStep.instruction}';
              } else {
                instructionText = bannerStep.instruction;
              }

              // Determina icona e colore in base al tipo di manovra del
              // banner (prossima svolta). Nell'ultimo step usiamo
              // un'icona di destinazione.
              final IconData directionIcon = isLastStep
                  ? Icons.place
                  : _getManeuverIcon(bannerStep.maneuver);
              final Color bannerColor = isLastStep
                  ? Colors.green.shade700
                  : _getManeuverColor(bannerStep.maneuver);

              return Container(
                margin: EdgeInsets.only(
                  top: MediaQuery.of(context).padding.top + 8,
                  left: 12,
                  right: 12,
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 20,
                ),
                decoration: BoxDecoration(
                  color: bannerColor,
                  borderRadius: BorderRadius.circular(24),
                  boxShadow: const [
                    BoxShadow(
                      color: Colors.black38,
                      blurRadius: 12,
                      offset: Offset(0, 4),
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    // FRECCIA DIREZIONALE — elemento primario (80px)
                    // L'utente vede PRIMA la freccia e capisce subito dove andare,
                    // poi legge il testo per conferma.
                    Container(
                      width: 80,
                      height: 80,
                      decoration: BoxDecoration(
                        color: Colors.white.withAlpha(50),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Icon(
                        directionIcon,
                        color: Colors.white,
                        size: 56,
                      ),
                    ),
                    const SizedBox(width: 16),
                    // TESTO — istruzione + distanza, grande e leggibile
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Istruzione semplificata (es. "Vai a destra")
                          Text(
                            instructionText,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 26,
                              fontWeight: FontWeight.bold,
                              height: 1.2,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 8),
                          // Distanza dinamica alla prossima svolta (FIX BUG 2)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.white.withAlpha(40),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(
                              distanceText,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              );
                },
              ),
            ),
          ),
        ),
        // BOTTOM SHEET (Info navigazione minimale, pedone, tempo, km - senza pulsanti)
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          child: Container(
            padding: EdgeInsets.only(
              top: 24,
              bottom: MediaQuery.of(context).padding.bottom + 24,
              left: 16,
              right: 16,
            ), // SafeArea bottom padding
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
              boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 10)],
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Icon(
                  Icons.directions_walk,
                  size: 36,
                  color: Colors.green.shade700,
                ),
                const SizedBox(width: 16),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // FIX BUG 1 — Tempo residuo aggiornato in tempo reale.
                    // Prima mostrava `_directionsResult.totalDuration`, che
                    // è il valore iniziale restituito dalla Directions API
                    // e non cambiava mai mentre l'utente camminava.
                    // Ora leggiamo dal `_progress` emesso dal monitor ad
                    // ogni GPS tick: il tempo DECRESCE man mano che
                    // l'utente avanza. Fallback al valore totale iniziale
                    // se il progress non è ancora stato calcolato (primo
                    // secondo post-avvio navigazione).
                    Text(
                      _progress?.remainingDurationText ??
                          _directionsResult?.totalDuration ??
                          '',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                        color: Colors.green.shade900,
                      ),
                    ),
                    // FIX BUG 1 — Distanza residua aggiornata in tempo reale.
                    // Stessa logica: valore dinamico dal progress con
                    // fallback al testo iniziale totale.
                    Text(
                      _progress?.remainingDistanceText ??
                          _directionsResult?.totalDistance ??
                          '',
                      style: TextStyle(
                        fontSize: 16,
                        color: Colors.grey.shade600,
                      ),
                    ),
                  ],
                ),

                IconButton(
                  icon: Icon(
                    _ttsEnabled ? Icons.volume_up : Icons.volume_off,
                    color: _ttsEnabled ? Colors.green.shade700 : Colors.grey,
                    size: 30,
                  ),
                  onPressed: () {
                    setState(() { _ttsEnabled = !_ttsEnabled; });
                    if (!_ttsEnabled) _tts.stop();
                  },
                  tooltip: _ttsEnabled ? 'Silenzia voce' : 'Attiva voce',
                ),
                const Spacer(),
                // Pulsante "Termina" — sempre visibile, grande, con icona
                // Design accessibile: colore rosso evidente, testo esplicito,
                // nessun gesto nascosto da ricordare.
                ElevatedButton.icon(
                  onPressed: _showStopNavigationDialog,
                  icon: const Icon(Icons.stop_circle, size: 28),
                  label: const Text(
                    'Termina',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red.shade600,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 14,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    elevation: 2,
                  ),
                ),
              ],
            ),
          ),
        ),

        // --- BOTTOM SHEET RICALCOLO: "Sto cercando una strada migliore..." ---
        // Appare quando l'utente devia dal percorso (fase offRoute o rerouting).
        if (_reroutePhase == ReroutePhase.offRoute ||
            _reroutePhase == ReroutePhase.rerouting)
          _buildReroutingSheet(),

        // --- BOTTOM SHEET RICALCOLO COMPLETATO: "Va tutto bene" ---
        // Appare dopo che il percorso è stato ricalcolato con successo.
        if (_reroutePhase == ReroutePhase.routeChanged)
          _buildRouteChangedSheet(),
      ],
    );
  }

  // ===========================================================================
  // HELPER: BOTTOM SHEET RICALCOLO PERCORSO (Design da screenshot)
  // ===========================================================================

  /// Bottom sheet ARANCIONE che appare quando l'utente devia dal percorso.
  ///
  /// DESIGN (da Immagine 1):
  /// - Banner arancione in basso con icona warning
  /// - "Ricalcolo in corso..." con spinner
  /// - "Torna al percorso" come sottotitolo
  /// - Pulsanti "Passi" e "Riprendi"
  ///
  /// ACCESSIBILITÀ:
  /// Tono rassicurante, nessun allarme. Il ragazzo deve capire che
  /// qualcosa è cambiato ma che va tutto bene, non deve agitarsi.
  Widget _buildReroutingSheet() {
    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          boxShadow: [
            BoxShadow(color: Colors.black26, blurRadius: 12, offset: Offset(0, -2)),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Maniglia di scorrimento
            Center(
              child: Container(
                margin: const EdgeInsets.only(top: 12, bottom: 8),
                height: 4,
                width: 40,
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            // Banner arancione "Ricalcolo in corso..."
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 16),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.orange.shade600,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  const Icon(Icons.warning_amber_rounded, color: Colors.white, size: 24),
                  const SizedBox(width: 10),
                  Text(
                    'Ricalcolo in corso...',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            // Titolo rassicurante
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                'Sto cercando una strada migliore',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: Colors.black87,
                ),
              ),
            ),
            const SizedBox(height: 8),
            // Info percorso attuale
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                _directionsResult?.totalDuration != null
                    ? '${_directionsResult!.totalDuration} • ${_directionsResult!.totalDistance}'
                    : '',
                style: TextStyle(
                  fontSize: 14,
                  color: Colors.grey.shade600,
                ),
              ),
            ),
            const SizedBox(height: 20),
            // Spinner al centro
            SizedBox(
              width: 36,
              height: 36,
              child: CircularProgressIndicator(
                strokeWidth: 3,
                color: Colors.blue.shade600,
              ),
            ),
            SizedBox(height: MediaQuery.of(context).padding.bottom + 24),
          ],
        ),
      ),
    );
  }

  /// Bottom sheet BIANCO con animazione progressiva e SCELTA UTENTE.
  ///
  /// DESIGN — 3 fasi progressive:
  /// 1. Mascotte mappa + "Va tutto bene." (subito)
  /// 2. + "Il percorso è cambiato. Cosa vuoi fare?" (dopo 1.5s)
  /// 3. + Pulsanti "Continua col nuovo" / "Torna al vecchio" (dopo 3s)
  ///
  /// IMPORTANTE: il bottom sheet NON ha maniglia e NON è dismissabile
  /// con swipe/tap esterno. L'utente DEVE fare una scelta esplicita.
  /// Questo è fondamentale per utenti con disabilità cognitive: nessuna
  /// azione ambigua, nessun dismiss accidentale.
  Widget _buildRouteChangedSheet() {
    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          boxShadow: [
            BoxShadow(color: Colors.black26, blurRadius: 12, offset: Offset(0, -2)),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 24),

            // --- MASCOTTE MAPPA ---
            Container(
              width: 100,
              height: 100,
              decoration: BoxDecoration(
                color: Colors.blue.shade50,
                borderRadius: BorderRadius.circular(24),
              ),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Icon(
                    Icons.map_rounded,
                    size: 56,
                    color: Colors.blue.shade400,
                  ),
                  Positioned(
                    top: 14,
                    right: 18,
                    child: Icon(
                      Icons.location_on,
                      size: 24,
                      color: Colors.red.shade400,
                    ),
                  ),
                  Positioned(
                    bottom: 12,
                    right: 12,
                    child: Icon(
                      Icons.refresh,
                      size: 20,
                      color: Colors.blue.shade300,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),

            // --- TESTO 1: "Va tutto bene." (sempre visibile) ---
            const Text(
              'Va tutto bene.',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: Colors.black87,
              ),
            ),
            const SizedBox(height: 8),

            // --- TESTO 2: "Il percorso è cambiato. Cosa vuoi fare?" (step >= 1) ---
            AnimatedOpacity(
              opacity: _routeChangedAnimStep >= 1 ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 500),
              child: AnimatedSlide(
                offset: _routeChangedAnimStep >= 1
                    ? Offset.zero
                    : const Offset(0, 0.3),
                duration: const Duration(milliseconds: 500),
                curve: Curves.easeOut,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Text(
                    'Il percorso è cambiato.\nCosa vuoi fare?',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 16,
                      color: Colors.grey.shade600,
                      height: 1.4,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 24),

            // --- PULSANTI DI SCELTA (step >= 2) ---
            AnimatedOpacity(
              opacity: _routeChangedAnimStep >= 2 ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 500),
              child: AnimatedSlide(
                offset: _routeChangedAnimStep >= 2
                    ? Offset.zero
                    : const Offset(0, 0.3),
                duration: const Duration(milliseconds: 500),
                curve: Curves.easeOut,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Column(
                    children: [
                      // Pulsante principale — "Continua col nuovo percorso"
                      // VERDE: azione positiva, proseguire è la scelta più naturale
                      SizedBox(
                        width: double.infinity,
                        height: 56,
                        child: ElevatedButton.icon(
                          onPressed: _confirmNewRoute,
                          icon: const Icon(Icons.navigation, size: 24),
                          label: const Text(
                            'Continua col nuovo percorso',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.green.shade600,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(28),
                            ),
                            elevation: 0,
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      // Pulsante secondario — "Torna al vecchio percorso"
                      // OUTLINED ARANCIONE: azione di ritorno, meno prominente
                      SizedBox(
                        width: double.infinity,
                        height: 56,
                        child: OutlinedButton.icon(
                          onPressed: _restorePreviousRoute,
                          icon: Icon(Icons.undo, size: 24, color: Colors.orange.shade800),
                          label: Text(
                            'Torna al vecchio percorso',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: Colors.orange.shade800,
                            ),
                          ),
                          style: OutlinedButton.styleFrom(
                            side: BorderSide(
                              color: Colors.orange.shade400,
                              width: 2,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(28),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            SizedBox(height: MediaQuery.of(context).padding.bottom + 16),
          ],
        ),
      ),
    );
  }

  // ===========================================================================
  // HELPER: BOTTOM SHEET ARRIVO A DESTINAZIONE (Design da screenshot)
  // ===========================================================================

  /// UI completa per lo stato "arrivato": banner verde in alto + bottom sheet.
  ///
  /// Sostituisce _buildNavigatingUI() quando _isArrived è true.
  /// Il banner di navigazione diventa verde "Sei arrivato" e il bottom
  /// sheet mostra un'animazione progressiva di congratulazioni.
  Widget _buildArrivalUI() {
    return Stack(
      children: [
        // --- TOP BANNER VERDE "Sei arrivato" ---
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: Container(
            margin: EdgeInsets.only(
              top: MediaQuery.of(context).padding.top + 8,
              left: 12,
              right: 12,
            ),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
            decoration: BoxDecoration(
              color: Colors.green.shade600,
              borderRadius: BorderRadius.circular(24),
              boxShadow: const [
                BoxShadow(
                  color: Colors.black38,
                  blurRadius: 12,
                  offset: Offset(0, 4),
                ),
              ],
            ),
            child: Row(
              children: [
                // Icona checkmark grande
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    color: Colors.white.withAlpha(50),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: const Icon(
                    Icons.check_circle,
                    color: Colors.white,
                    size: 40,
                  ),
                ),
                const SizedBox(width: 16),
                const Expanded(
                  child: Text(
                    'Sei arrivato',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 26,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),

        // --- BOTTOM SHEET ARRIVO CON ANIMAZIONE PROGRESSIVA ---
        _buildArrivalSheet(),
      ],
    );
  }

  /// Bottom sheet "Sei arrivato" con animazione progressiva a 3 step.
  ///
  /// DESIGN (da screenshot — 3 fasi):
  /// 1. Checkmark verde + "Sei arrivato." (subito)
  /// 2. + "Hai seguito il percorso con attenzione." (dopo 1.5s)
  /// 3. + "Vuoi rivedere il percorso?" link blu (dopo 3s)
  ///
  /// I pulsanti "Chiudi" e "Nuova meta" sono sempre visibili in basso.
  Widget _buildArrivalSheet() {
    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          boxShadow: [
            BoxShadow(
              color: Colors.black26,
              blurRadius: 12,
              offset: Offset(0, -2),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Maniglia di scorrimento + pulsante X
            Padding(
              padding: const EdgeInsets.only(top: 8, right: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const SizedBox(width: 40), // Bilancia il pulsante X
                  // Maniglia
                  Container(
                    margin: const EdgeInsets.only(top: 4),
                    height: 4,
                    width: 40,
                    decoration: BoxDecoration(
                      color: Colors.grey.shade300,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  // Pulsante X
                  IconButton(
                    onPressed: _dismissArrivalSheet,
                    icon: Icon(
                      Icons.close,
                      color: Colors.grey.shade500,
                      size: 24,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),

            // --- CHECKMARK GRANDE VERDE ---
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: Colors.green.shade50,
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.check_circle,
                size: 52,
                color: Colors.green.shade600,
              ),
            ),
            const SizedBox(height: 20),

            // --- TESTO 1: "Sei arrivato." (sempre visibile) ---
            const Text(
              'Sei arrivato.',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: Colors.black87,
              ),
            ),
            const SizedBox(height: 8),

            // --- TESTO 2: "Hai seguito il percorso con attenzione." (step >= 1) ---
            AnimatedOpacity(
              opacity: _arrivalAnimStep >= 1 ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 500),
              child: AnimatedSlide(
                offset: _arrivalAnimStep >= 1
                    ? Offset.zero
                    : const Offset(0, 0.3),
                duration: const Duration(milliseconds: 500),
                curve: Curves.easeOut,
                child: Text(
                  'Hai seguito il percorso con attenzione.',
                  style: TextStyle(
                    fontSize: 16,
                    color: Colors.grey.shade600,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),

            // --- PULSANTE "Rivedi il percorso" (step >= 2) ---
            // Trasformato da link sottile a PULSANTE GRANDE per accessibilità.
            // Per ragazzi con disabilità cognitive, un link di testo sottolineato
            // è troppo facile da ignorare. Un pulsante con icona, colore e
            // dimensione generosa è molto più chiaro e invitante.
            AnimatedOpacity(
              opacity: _arrivalAnimStep >= 2 ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 500),
              child: AnimatedSlide(
                offset: _arrivalAnimStep >= 2
                    ? Offset.zero
                    : const Offset(0, 0.3),
                duration: const Duration(milliseconds: 500),
                curve: Curves.easeOut,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: SizedBox(
                    width: double.infinity,
                    height: 56,
                    child: ElevatedButton.icon(
                      onPressed: _showWalkedPathReview,
                      icon: const Icon(Icons.route, size: 24),
                      label: const Text(
                        'Rivedi il mio percorso',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blue.shade600,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(28),
                        ),
                        elevation: 0,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 24),

            // --- PULSANTI SEMPRE VISIBILI ---
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Row(
                children: [
                  // Pulsante "Chiudi" — secondario
                  Expanded(
                    child: SizedBox(
                      height: 52,
                      child: OutlinedButton(
                        onPressed: _dismissArrivalSheet,
                        style: OutlinedButton.styleFrom(
                          side: BorderSide(
                            color: Colors.grey.shade400,
                            width: 2,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(26),
                          ),
                        ),
                        child: const Text(
                          'Chiudi',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: Colors.black87,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  // Pulsante "Nuova meta" — principale
                  Expanded(
                    child: SizedBox(
                      height: 52,
                      child: ElevatedButton(
                        onPressed: _dismissArrivalSheet,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.blue.shade600,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(26),
                          ),
                          elevation: 0,
                        ),
                        child: const Text(
                          'Nuova meta',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(height: MediaQuery.of(context).padding.bottom + 16),
          ],
        ),
      ),
    );
  }

  // ===========================================================================
  // HELPER: REVIEW PERCORSO EFFETTUATO (Post-Arrivo)
  // ===========================================================================

  /// UI per la review del percorso camminato.
  ///
  /// Mostra la mappa con:
  /// - Polyline BLU: percorso pianificato (dalla Directions API)
  /// - Polyline VERDE: percorso effettivamente camminato (da GPS tracking)
  /// - Bottom sheet con legenda colori e pulsante "Chiudi"
  ///
  /// La camera si posiziona automaticamente per mostrare entrambi i percorsi
  /// in vista panoramica (tilt=0, bearing=0) tramite fitAllPoints().
  Widget _buildWalkedPathReviewUI() {
    return Stack(
      children: [
        // --- BOTTOM SHEET REVIEW ---
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          child: Container(
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black26,
                  blurRadius: 12,
                  offset: Offset(0, -2),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Maniglia
                Center(
                  child: Container(
                    margin: const EdgeInsets.only(top: 12, bottom: 16),
                    height: 4,
                    width: 40,
                    decoration: BoxDecoration(
                      color: Colors.grey.shade300,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),

                // --- TITOLO ---
                const Text(
                  'Il tuo percorso',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color: Colors.black87,
                  ),
                ),
                const SizedBox(height: 16),

                // --- LEGENDA COLORI ---
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Column(
                    children: [
                      // Linea BLU = percorso pianificato
                      Row(
                        children: [
                          Container(
                            width: 32,
                            height: 6,
                            decoration: BoxDecoration(
                              color: Colors.blue,
                              borderRadius: BorderRadius.circular(3),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Text(
                            'Percorso consigliato',
                            style: TextStyle(
                              fontSize: 16,
                              color: Colors.grey.shade700,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      // Linea VERDE = percorso effettuato
                      Row(
                        children: [
                          Container(
                            width: 32,
                            height: 6,
                            decoration: BoxDecoration(
                              color: const Color(0xFF34A853),
                              borderRadius: BorderRadius.circular(3),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Text(
                            'La strada che hai fatto',
                            style: TextStyle(
                              fontSize: 16,
                              color: Colors.grey.shade700,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),

                // --- INFO PERCORSO ---
                if (_directionsResult != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.directions_walk,
                          size: 24,
                          color: Colors.green.shade700,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '${_directionsResult!.totalDuration} • ${_directionsResult!.totalDistance}',
                          style: TextStyle(
                            fontSize: 16,
                            color: Colors.grey.shade600,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 20),

                // --- PULSANTE CHIUDI ---
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: ElevatedButton.icon(
                      onPressed: _dismissArrivalSheet,
                      icon: const Icon(Icons.check, size: 24),
                      label: const Text(
                        'Fatto',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blue.shade600,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(26),
                        ),
                        elevation: 0,
                      ),
                    ),
                  ),
                ),
                SizedBox(height: MediaQuery.of(context).padding.bottom + 16),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ===========================================================================
  // HELPER: ICONE E COLORI PER MANOVRE (Design Accessibile)
  // ===========================================================================

  /// Restituisce l'icona direzionale appropriata per il tipo di manovra.
  ///
  /// Le icone sono scelte per essere immediatamente riconoscibili:
  /// - Frecce grandi e chiare
  /// - Ogni direzione ha un'icona diversa
  /// - Il fallback (dritto) è la situazione più comune
  IconData _getManeuverIcon(String? maneuver) {
    switch (maneuver) {
    // Svolte
      case 'turn-left':
        return Icons.turn_left;
      case 'turn-right':
        return Icons.turn_right;
      case 'turn-slight-left':
        return Icons.turn_slight_left;
      case 'turn-slight-right':
        return Icons.turn_slight_right;
      case 'turn-sharp-left':
        return Icons.turn_sharp_left;
      case 'turn-sharp-right':
        return Icons.turn_sharp_right;

    // Inversione
      case 'uturn-left':
      case 'uturn-right':
        return Icons.u_turn_left;

    // Tieni sinistra/destra
      case 'keep-left':
      case 'ramp-left':
      case 'fork-left':
        return Icons.turn_slight_left;
      case 'keep-right':
      case 'ramp-right':
      case 'fork-right':
        return Icons.turn_slight_right;

    // Rotonde
      case 'roundabout-left':
      case 'roundabout-right':
        return Icons.roundabout_left;

    // Dritto / merge / sconosciuto
      case 'straight':
      case 'merge':
      default:
        return Icons.arrow_upward;
    }
  }

  /// Restituisce il colore di sfondo del banner di indicazione.
  ///
  /// DESIGN SEMPLIFICATO: tutte le indicazioni usano lo stesso colore
  /// VERDE per ridurre il carico cognitivo. L'utente si orienta con
  /// l'ICONA della freccia (che cambia per ogni manovra), non col colore.
  /// Un solo colore = meno cose da processare = meno confusione.
  Color _getManeuverColor(String? maneuver) {
    return Colors.green.shade800;
  }

  /// Metodo Helper per estrarre la grafica di "Fallback" quando non c'è una rotta
  /// (usato se il _navigationMonitor non ha ancora sincronizzato i percorsi).
  Widget _buildFallbackBanner() {
    return Container(
      margin: EdgeInsets.only(
        top: MediaQuery.of(context).padding.top + 8,
        left: 12,
        right: 12,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
      decoration: BoxDecoration(
        color: Colors.green.shade800,
        borderRadius: BorderRadius.circular(24),
        boxShadow: const [
          BoxShadow(
            color: Colors.black38,
            blurRadius: 12,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              color: Colors.white.withAlpha(50),
              borderRadius: BorderRadius.circular(20),
            ),
            child: const Icon(
              Icons.arrow_upward,
              color: Colors.white,
              size: 56,
            ),
          ),
          const SizedBox(width: 16),
          const Expanded(
            child: Text(
              'Vai dritto, stai andando bene!',
              style: TextStyle(
                color: Colors.white,
                fontSize: 24,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Widget per mostrare errori — tono rassicurante, non allarmante
  Widget _buildErrorMessage() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.orange.shade50,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.orange.shade200),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline, color: Colors.orange.shade700, size: 28),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              _errorMessage!,
              style: TextStyle(
                color: Colors.orange.shade900,
                fontSize: 16,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Crea il widget overlay per la velocità
  Widget _buildSpeedOverlay() {
    double bottomPadding = 24.0;

    // Spostiamo il widget speed più in alto a seconda di che bottom sheet è attivo
    if (_appState == NavigationAppState.placeSelected) {
      bottomPadding = 180.0;
    } else if (_appState == NavigationAppState.navigating) {
      bottomPadding = 120.0;
    } else if (_appState == NavigationAppState.routePreview) {
      bottomPadding = MediaQuery.of(context).size.height * 0.35 + 16;
    }

    return Positioned(
      bottom: bottomPadding,
      left: 16,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(30),
          boxShadow: const [
            BoxShadow(
              color: Colors.black26,
              blurRadius: 8,
              offset: Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.speed, color: Colors.blue, size: 28),
            const SizedBox(width: 8),
            Text(
              '${_currentSpeed.toStringAsFixed(1)} km/h',
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: Colors.black87,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// FIX BUG 3 — Tipi di supporto per il TTS queue
// =============================================================================

/// Livello di priorità di una richiesta vocale. Una richiesta può
/// interrompere una in corso solo se ha priorità STRETTAMENTE superiore.
///
/// - background: messaggi informativi non urgenti (es. strada laterale)
/// - normal: stato della navigazione (es. "Sto cercando una strada migliore")
/// - important: istruzioni di marcia (svolte, cambi step)
/// - critical: arrivo a destinazione, eventi che richiedono attenzione
///   immediata. Bypassa anche il dedup temporale.
enum SpeechPriority { background, normal, important, critical }

/// Richiesta di pronuncia vocale tracciata dal queue.
class _SpeechRequest {
  final String text;
  final SpeechPriority priority;
  final String dedupKey;
  _SpeechRequest({
    required this.text,
    required this.priority,
    required this.dedupKey,
  });
}