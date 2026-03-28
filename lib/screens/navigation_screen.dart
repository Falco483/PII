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
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:flutter_compass/flutter_compass.dart';
import '../models/search_history_item.dart';
import '../services/directions_service.dart';
import '../services/navigation_monitor.dart';
import '../services/search_history_service.dart';
import '../services/geo_utils.dart';
import '../services/places_service.dart';
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

  /// Monitor di navigazione — gestisce tutta la logica di business:
  /// bearing affidabile, trigger velocità zero, analisi strade laterali.
  /// Viene inizializzato in initState() e distrutto in dispose().
  late final NavigationMonitor _navigationMonitor;

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
  /// Calcolata con approccio IBRIDO:
  /// 1. Se il chip GPS riporta position.speed > 0 → usa quello (più preciso)
  /// 2. Se position.speed == 0 (chip non lo supporta) → calcola manualmente
  ///    dalla distanza tra due posizioni GPS consecutive diviso il tempo
  ///
  /// In entrambi i casi il valore viene poi smorzato con un filtro EMA
  /// per eliminare i picchi di drift da fermo.
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

    // Avvia il monitoraggio della posizione GPS
    _initLocationMonitoring();

    // Avvia il monitoraggio della bussola (magnetometro)
    _initCompass();

    // Carica le ultime 3 ricerche recenti dalla cronologia persistente
    _loadRecentSearches();
  }

  // ===========================================================================
  // CRONOLOGIA RICERCHE
  // ===========================================================================

  /// Carica le ultime 3 ricerche dalla cronologia e aggiorna lo stato.
  /// Viene chiamato in initState() e dopo ogni selezione destinazione,
  /// così la lista è sempre aggiornata.
  Future<void> _loadRecentSearches() async {
    final history = await _searchHistoryService.loadHistory();
    if (!mounted) return;
    setState(() {
      // Prendiamo solo le prime 3 (loadHistory già ordina per timestamp desc)
      _recentSearches = history.take(3).toList();
    });
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
          _compassHeading = event.heading!;
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
      _startArrivalAnimation();
      return;
    }

    setState(() {
      _overlayState = newState;
    });
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

  /// Chiude il bottom sheet di ricalcolo e resetta lo stato.
  ///
  /// Usato INTERNAMENTE per le fasi offRoute/rerouting (se l'utente
  /// torna da solo sul percorso). Per la fase routeChanged, l'utente
  /// deve usare i pulsanti dedicati (conferma o ripristino).
  void _dismissRerouteSheet() {
    _routeChangedAnimTimer?.cancel();
    setState(() {
      _reroutePhase = ReroutePhase.none;
      _routeChangedAnimStep = 0;
    });
    _navigationMonitor.reroutePhaseNotifier.value = ReroutePhase.none;
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
      setState(() {
        // Il rebuild causa MapWidget.didUpdateWidget() che ricalcola
        // le polyline con il nuovo currentStepIndex.
      });
    }
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

            // Caso 1: il chip GPS riporta la velocità
            if (position.speed > 0) {
              rawSpeedKmH = position.speed * 3.6; // m/s → km/h
            }
            // Caso 2: calcolo manuale dalla distanza/tempo
            else if (_prevLat != null &&
                _prevLng != null &&
                _prevTimestamp != null) {
              // Calcola il tempo trascorso dall'ultimo aggiornamento.
              // Usiamo position.timestamp (momento della lettura GPS)
              // invece di DateTime.now() per evitare latenza di delivery.
              final DateTime currentTimestamp = position.timestamp;
              final double deltaSec =
                  currentTimestamp.difference(_prevTimestamp!).inMilliseconds /
                      1000.0;

              // Scarta campioni troppo ravvicinati: con Δt < 0.5s
              // la distanza è dominata dall'errore GPS (3-10m) e il
              // rapporto d/t esplode (es. 3m / 0.2s = 54 km/h da fermo).
              if (deltaSec >= _minTimeDeltaSec) {
                // Distanza geodetica tra la posizione precedente e attuale
                final double distanceMeters = haversineDistance(
                  _prevLat!,
                  _prevLng!,
                  position.latitude,
                  position.longitude,
                );

                // velocità = distanza / tempo, convertita in km/h
                // distanceMeters / deltaSec = m/s, × 3.6 = km/h
                rawSpeedKmH = (distanceMeters / deltaSec) * 3.6;
              } else {
                // Intervallo troppo breve, manteniamo il valore precedente
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
            final String source = position.speed > 0 ? 'CHIP' : 'MANUAL';
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
            _mapKey.currentState?.moveToLocation(
              _currentLat!,
              _currentLng!,
            );
          }

          // --- FOLLOW-MODE: insegui la posizione GPS sulla mappa ---
          // FIX: usiamo _getRouteBearing() che calcola il bearing geometrico
          // dalla posizione corrente verso lo step corrente del percorso.
          // Prima usavamo _navigationMonitor.direction ?? _rawBearing, che
          // all'avvio è 0° (nord) perché il monitor non ha ancora acquisito
          // un bearing affidabile → la camera ruotava verso nord annullando
          // l'orientamento impostato da snapToRoute().
          // _getRouteBearing() ha già il fallback interno a
          // _navigationMonitor.direction ?? _rawBearing se non ci sono steps.
          if (_appState == NavigationAppState.navigating && _isFollowingUser) {
            final double navBearing = _getRouteBearing();
            _mapKey.currentState?.followUser(
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

    // Cancella il timer dell'animazione ricalcolo
    _routeChangedAnimTimer?.cancel();

    // Cancella il timer dell'animazione arrivo
    _arrivalAnimTimer?.cancel();

    // Distrugge il NavigationMonitor (cancella tutti i timer interni)
    _navigationMonitor.dispose();

    // Distrugge il controller del campo di testo
    _destinationController.dispose();

    super.dispose();
  }

  // ===========================================================================
  // HELPER: BEARING LUNGO IL PERCORSO
  // ===========================================================================

  /// Calcola il bearing dalla posizione corrente verso lo step corrente
  /// del percorso attivo (direzione in cui l'utente DEVE andare).
  double _getRouteBearing() {
    final double fallback = _navigationMonitor.direction ?? _rawBearing;

    if (_currentLat == null || _currentLng == null) return fallback;
    final steps = _directionsResult?.steps;
    if (steps == null || steps.isEmpty) return fallback;

    final int idx = _navigationMonitor.currentStepNotifier.value;
    final int safeIdx = idx < steps.length ? idx : steps.length - 1;
    final step = steps[safeIdx];

    final double targetLat = step.endLat;
    final double targetLng = step.endLng;

    final double lat1 = _currentLat! * (3.141592653589793 / 180.0);
    final double lat2 = targetLat * (3.141592653589793 / 180.0);
    final double dLng = (targetLng - _currentLng!) * (3.141592653589793 / 180.0);

    final double x = math.sin(dLng) * math.cos(lat2);
    final double y = math.cos(lat1) * math.sin(lat2) - math.sin(lat1) * math.cos(lat2) * math.cos(dLng);
    double bearing = math.atan2(x, y) * (180.0 / 3.141592653589793);

    return (bearing + 360) % 360;
  }

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
      _destinationController.clear();
    });
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
      setState(() {
        _appState = NavigationAppState.navigating;
        _isFollowingUser = true;
        // Reset stato arrivo/review per una nuova navigazione
        _walkedPath = [];
        _isArrived = false;
        _arrivalAnimStep = 0;
        _isReviewingWalkedPath = false;
      });

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

      _mapKey.currentState?.snapToRoute(
        startLat,
        startLng,
        _getRouteBearing(),
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

    setState(() {
      _selectedDestinationAddress = address;
      _appState = NavigationAppState.placeSelected;

      // Imposta le coordinate della destinazione per posizionare il pin sulla mappa,
      // ma senza calcolare ancora il percorso (lo calcoliamo quando clicca 'Indicazioni').
      _directionsResult = DirectionsResult(
        steps: [],
        totalDistance: '',
        totalDuration: '',
        encodedPolyline: '', // Nessun percorso
        originLat: _currentLat ?? 0,
        originLng: _currentLng ?? 0,
        destLat: lat,
        destLng: lng,
      );
      _allRoutesResult = null; // Resetta i percorsi vecchi se presenti
    });
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
        encodedPolyline: '',
        originLat: _currentLat ?? 0,
        originLng: _currentLng ?? 0,
        destLat: position.latitude,
        destLng: position.longitude,
      );
      _allRoutesResult = null;
    });

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
    // Determina se siamo su un dispositivo mobile (schermo stretto)
    final isMobile = MediaQuery.of(context).size.width < 800;

    return Scaffold(
      // App Bar
      appBar: AppBar(
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
    );
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
          // TASK 3: callback per tap sulla mappa
          onMapTap:
          _appState == NavigationAppState.search ||
              _appState == NavigationAppState.placeSelected
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

        // --- LAYER 6: Overlay Navigazione ---
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
              child: ValueListenableBuilder<int>(
            valueListenable: _navigationMonitor.currentStepNotifier,
            builder: (context, currentStepIndex, child) {
              final steps = _directionsResult?.steps ?? [];

              if (steps.isEmpty) {
                return _buildFallbackBanner();
              }

              final safeIndex = currentStepIndex < steps.length
                  ? currentStepIndex
                  : steps.length - 1;

              final currentStep = steps[safeIndex];

              // Determina icona e colore in base al tipo di manovra
              final IconData directionIcon = _getManeuverIcon(currentStep.maneuver);
              final Color bannerColor = _getManeuverColor(currentStep.maneuver);

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
                            currentStep.instruction,
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
                          // Distanza rimanente allo step (es. "120 m")
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
                              currentStep.distance,
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
        // --- TASTO RECENTER ---
        // Visibile SOLO quando il follow-mode è disattivato (pan manuale).
        if (!_isFollowingUser)
          Positioned(
            bottom: 140,
            right: 16,
            child: FloatingActionButton(
              heroTag: 'recenter_btn',
              onPressed: () {
                setState(() {
                  _isFollowingUser = true;
                });
                if (_currentLat != null && _currentLng != null) {
                  _mapKey.currentState?.followUser(
                    _currentLat!,
                    _currentLng!,
                    _getRouteBearing(),
                  );
                }
              },
              backgroundColor: Colors.white,
              elevation: 4,
              child: Icon(
                Icons.my_location,
                color: Colors.blue.shade700,
                size: 28,
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
                    Text(
                      _directionsResult?.totalDuration ?? '',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                        color: Colors.green.shade900,
                      ),
                    ),
                    Text(
                      _directionsResult?.totalDistance ?? '',
                      style: TextStyle(
                        fontSize: 16,
                        color: Colors.grey.shade600,
                      ),
                    ),
                  ],
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

  /// Restituisce il colore di sfondo del banner in base alla manovra.
  ///
  /// CODIFICA COLORE per comprensione immediata:
  /// - VERDE     → vai dritto (tutto ok, nessuna azione)
  /// - BLU       → vai a destra
  /// - ARANCIONE → vai a sinistra
  /// - ROSSO     → torna indietro (attenzione!)
  /// - VIOLA     → rotonda (situazione speciale)
  Color _getManeuverColor(String? maneuver) {
    switch (maneuver) {
    // Destra → blu
      case 'turn-right':
      case 'turn-slight-right':
      case 'turn-sharp-right':
      case 'keep-right':
      case 'ramp-right':
      case 'fork-right':
        return Colors.blue.shade700;

    // Sinistra → arancione
      case 'turn-left':
      case 'turn-slight-left':
      case 'turn-sharp-left':
      case 'keep-left':
      case 'ramp-left':
      case 'fork-left':
        return Colors.orange.shade800;

    // Inversione → rosso
      case 'uturn-left':
      case 'uturn-right':
        return Colors.red.shade700;

    // Rotonda → viola
      case 'roundabout-left':
      case 'roundabout-right':
        return Colors.purple.shade700;

    // Dritto / merge / sconosciuto → verde
      case 'straight':
      case 'merge':
      default:
        return Colors.green.shade800;
    }
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