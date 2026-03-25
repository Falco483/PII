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
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import '../services/directions_service.dart';
import '../services/navigation_monitor.dart';
import '../widgets/map_widget.dart';
import '../widgets/search_input.dart';
import '../widgets/directions_list.dart';
import '../widgets/navigation_overlay.dart';
import '../services/places_service.dart';

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

  /// Servizio per le direzioni (Directions API)
  final DirectionsService _directionsService = DirectionsService();

  /// Monitor di navigazione — gestisce tutta la logica di business:
  /// bearing affidabile, trigger velocità zero, analisi strade laterali.
  /// Viene inizializzato in initState() e distrutto in dispose().
  late final NavigationMonitor _navigationMonitor;

  /// Chiave globale per accedere allo stato di MapWidget e chiamare
  /// moveToLocation() quando l'utente preme il pulsante di re-center.
  final GlobalKey<MapWidgetState> _mapKey = GlobalKey<MapWidgetState>();

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

  // ===========================================================================
  // STATO GPS — VARIABILI IN TEMPO REALE
  // ===========================================================================

  /// Subscription allo stream di posizione GPS.
  /// Viene cancellata in dispose() per evitare memory leak.
  StreamSubscription<Position>? _positionStream;

  /// Velocità corrente dell'utente in km/h.
  /// Aggiornata ad ogni frame GPS. Usata per:
  /// 1. Mostrare la velocità nell'overlay sulla mappa
  /// 2. Alimentare il NavigationMonitor per il trigger velocità-zero
  double _currentSpeed = 0.0;

  /// Posizione corrente dell'utente (latitudine).
  /// Aggiornata ad ogni frame GPS. Usata come input per il NavigationMonitor.
  double? _currentLat;

  /// Posizione corrente dell'utente (longitudine).
  /// Aggiornata ad ogni frame GPS. Usata come input per il NavigationMonitor.
  double? _currentLng;

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
  // STATO OVERLAY DI NAVIGAZIONE
  // ===========================================================================

  /// Stato corrente dell'overlay di navigazione.
  /// null = nessun overlay da mostrare.
  /// Non-null = mostra l'overlay con il messaggio specificato.
  NavigationOverlayState? _overlayState;

  // ===========================================================================
  // CICLO DI VITA
  // ===========================================================================

  @override
  void initState() {
    super.initState();

    // Crea il NavigationMonitor che gestisce tutta la logica di business
    _navigationMonitor = NavigationMonitor();

    // Ascolta gli eventi del NavigationMonitor per mostrare/nascondere l'overlay.
    // Quando il monitor emette un nuovo stato (es. "vai diritto stronzo"),
    // aggiorniamo la UI per mostrare l'overlay corrispondente.
    _navigationMonitor.overlayNotifier.addListener(_onOverlayChanged);

    // Ascolta i cambiamenti del percorso attivo (TASK 2).
    // Quando il monitor cambia percorso (Task 2b: switch ad alternativo,
    // Task 2c: ricalcolo API), questo listener aggiorna la UI.
    _navigationMonitor.activeRouteNotifier.addListener(_onActiveRouteChanged);

    // Avvia il monitoraggio della posizione GPS
    _initLocationMonitoring();
  }

  /// Callback chiamato quando il NavigationMonitor emette un nuovo stato overlay.
  ///
  /// Questo listener è il PONTE tra la logica di business (NavigationMonitor)
  /// e la UI (widget overlay). Il monitor decide QUANDO e COSA mostrare,
  /// questo callback si limita a propagare la decisione alla UI.
  void _onOverlayChanged() {
    print('🔵 Listener overlay triggered: ${_navigationMonitor.overlayNotifier.value?.type}');
    setState(() {
      _overlayState = _navigationMonitor.overlayNotifier.value;
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
            // --- Velocità ---
            // La velocità in Position è in m/s. Convertiamo in km/h (* 3.6).
            // Se il valore è negativo (errore del sensore), lo azzeriamo.
            double speedKmH = position.speed * 3.6;
            _currentSpeed = speedKmH > 0 ? speedKmH : 0.0;

            // --- Posizione ---
            // Salviamo latitudine e longitudine correnti.
            // Questi valori vengono usati dal NavigationMonitor per:
            // 1. Lo snapshot al momento del trigger (Step 2.2)
            // 2. Il calcolo della distanza dai waypoint (Step 2.3)
            // 3. Il calcolo dei punti laterali (Step 2.4)
            _currentLat = position.latitude;
            _currentLng = position.longitude;

            // --- Bearing ---
            // Il bearing (heading) del GPS indica la direzione in cui il
            // dispositivo si sta muovendo, espressa in gradi (0° = Nord,
            // 90° = Est, 180° = Sud, 270° = Ovest).
            //
            // position.heading può essere NaN o negativo in alcuni dispositivi
            // quando non è disponibile. Lo sanitizziamo a 0.0 in quei casi.
            _rawBearing = position.heading.isFinite && position.heading >= 0
                ? position.heading
                : 0.0;
          });

          // Inoltra TUTTI i dati aggiornati al NavigationMonitor.
          // Il monitor si occupa di:
          // - Decidere se aggiornare il bearing affidabile (direction)
          // - Gestire il trigger velocità-zero
          // - Lanciare l'analisi delle strade laterali se necessario
          _navigationMonitor.updatePosition(
            _currentLat!,
            _currentLng!,
            _currentSpeed,
            _rawBearing,
            position.accuracy, // TASK 5: Inviato confidence level
          );
        });
  }

  @override
  void dispose() {
    // Cancella lo stream GPS per evitare memory leak e consumo batteria
    _positionStream?.cancel();

    // Rimuove i listener prima di distruggere il monitor
    _navigationMonitor.overlayNotifier.removeListener(_onOverlayChanged);

    // Rimuove il listener del percorso attivo (TASK 2)
    _navigationMonitor.activeRouteNotifier.removeListener(
      _onActiveRouteChanged,
    );

    // Distrugge il NavigationMonitor (cancella tutti i timer interni)
    _navigationMonitor.dispose();

    // Distrugge il controller del campo di testo
    _destinationController.dispose();

    super.dispose();
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
      });

      // FIX 1+2: Passiamo le COORDINATE della destinazione ("lat,lng"),
      // non il testo dell'indirizzo, per evitare ri-geocodifiche nei ricalcoli.
      // La chiamata a startNavigation() avviene SOLO qui (non più dentro
      // _calculateRouteFromCoordinates), così il monitoring parte solo
      // quando l'utente preme effettivamente "Avvia".
      final destLat = _allRoutesResult!.destLat;
      final destLng = _allRoutesResult!.destLng;
      _navigationMonitor.startNavigation(
        _allRoutesResult!,
        '$destLat,$destLng',
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
      setState(() {
        _errorMessage =
            'Posizione GPS non disponibile. '
            'Attendi il fix GPS e riprova.';
      });
      return;
    }

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
      setState(() {
        _isLoading = false;
        if (result != null) {
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

          // NOTA: startNavigation() NON viene più chiamato qui (FIX 2).
          // Il monitoring del percorso si avvia solo quando l'utente
          // preme "Avvia" (in _startActiveNavigation), non durante
          // l'anteprima del percorso ("Indicazioni").
        } else {
          _errorMessage = 'Impossibile calcolare il percorso. Riprova.';
        }
      });
    } catch (e) {
      // Gestisce eventuali errori
      setState(() {
        _isLoading = false;
        _errorMessage = 'Errore: $e';
      });
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
  /// Gestisce il TASK 3 Caso 2 (punto generico):
  /// L'utente tocca un punto qualsiasi della mappa → usiamo le coordinate
  /// direttamente come destinazione, senza chiamare Places Details API.
  ///
  /// PERCHÉ NON CHIAMIAMO PLACES DETAILS:
  /// Per un punto generico non c'è un place_id disponibile. Le coordinate
  /// lat/lng sono sufficienti per la Directions API (TASK 4).
  ///
  /// PARAMETRI:
  /// - [position]: coordinate del punto toccato sulla mappa
  void _onMapTapped(LatLng position) {
    // Costruisce una stringa descrittiva con le coordinate come fallback
    final String coordsText =
        '${position.latitude.toStringAsFixed(5)}, '
        '${position.longitude.toStringAsFixed(5)}';

    // Feedback visivo immediato: mostra le coordinate nella barra.
    // Verranno sostituite dall'indirizzo reale appena la API risponde.
    _destinationController.text = coordsText;

    // Log per debugging
    print('Punto mappa selezionato: $coordsText');

    setState(() {
      _selectedDestinationAddress = coordsText;
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

    // Reverse geocoding asincrono: converte le coordinate in un
    // indirizzo leggibile (es. "Via Roma 15, Milano") e aggiorna
    // la barra di ricerca e il nome della destinazione.
    PlacesService()
        .reverseGeocode(position.latitude, position.longitude)
        .then((address) {
      if (address != null && mounted) {
        setState(() {
          _destinationController.text = address;
          _selectedDestinationAddress = address;
        });
      }
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
        title: const Text('Navigation App'),
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
    print('🟡 Build mobile: overlayState = $_overlayState');
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
          // Zoom iniziale sulla posizione GPS corrente
          initialLat: _currentLat,
          initialLng: _currentLng,
          // TASK 3: callback per tap sulla mappa
          onMapTap:
              _appState == NavigationAppState.search ||
                  _appState == NavigationAppState.placeSelected
              ? _onMapTapped
              : null,
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

        // --- LAYER 3: Overlay Navigazione Originale ---
        // Mostra le istruzioni turn-by-turn vecchie o "vai dritto"
        NavigationOverlay(
          state: _overlayState,
          onDismiss: () {
            setState(() {
              _overlayState = null;
            });
            _navigationMonitor.overlayNotifier.value = null;
          },
        ),

        // --- LAYER 4: Overlay Velocità ---
        // Modifichiamo la pozione in base allo stato in modo che non si sovrapponga ai bottom sheet
        _buildSpeedOverlay(),

        // --- LAYER 5: Pulsante Re-center GPS ---
        // Mostrato solo quando non siamo in navigazione attiva
        if (_appState != NavigationAppState.navigating)
          Positioned(
            bottom: _appState == NavigationAppState.placeSelected ? 160 : 24,
            right: 16,
            child: FloatingActionButton(
              mini: true,
              backgroundColor: Colors.white,
              foregroundColor: Colors.black87,
              tooltip: 'Torna alla posizione attuale',
              onPressed: () {
                if (_currentLat != null && _currentLng != null) {
                  _mapKey.currentState?.moveToLocation(_currentLat!, _currentLng!);
                }
              },
              child: const Icon(Icons.my_location),
            ),
          ),

        // --- LAYER 6: BOTTOM SHEETS & TOP BANNER ---
        if (_appState == NavigationAppState.placeSelected)
          _buildPlaceSelectedSheet(),

        if (_appState == NavigationAppState.navigating) _buildNavigatingUI(),

        if (_appState == NavigationAppState.routePreview &&
            _directionsResult != null)
          _buildRoutePreviewSheet(),
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
                      originLat: _directionsResult?.originLat,
                      originLng: _directionsResult?.originLng,
                      destLat: _directionsResult?.destLat,
                      destLng: _directionsResult?.destLng,
                      encodedPolyline: _directionsResult?.encodedPolyline,
                      // TASK 3: callback per tap sulla mappa
                      onMapTap: _onMapTapped,
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
                      _navigationMonitor.overlayNotifier.value = null;
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

  /// Scheda minimale che compare in fondo quando selezioniamo una destinazione (Niente percorso ancora calcolato se si clicca mappa).
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
            Text(
              _selectedDestinationAddress ?? 'Destinazione Sconosciuta',
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _calculateRouteForSelectedPlace,
                    icon: const Icon(Icons.directions),
                    label: const Text('Indicazioni'),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(30),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _startActiveNavigation,
                    icon: const Icon(Icons.navigation),
                    label: const Text('Avvia'),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
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
        // TOP BANNER (Indicazione percorso corrente)
        // Usiamo un costrutto ValueListenableBuilder: questo widget "ascolta"
        // in tempo reale il numero emesso da currentStepNotifier (dal NavigationMonitor).
        // Ogni volta che l'utente si avvicina a <15m dall'incrocio, il notifier
        // emette un nuovo numero e SOLO questo widget si ridisegna,
        // garantendo performance altissime.
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: ValueListenableBuilder<int>(
            valueListenable: _navigationMonitor.currentStepNotifier,
            builder: (context, currentStepIndex, child) {
              // 1. Prendi la lista di tutti gli step calcolati attualmente
              final steps = _directionsResult?.steps ?? [];
              
              // Se per qualche motivo gli step sono vuoti, mostra un layout di fallback
              if (steps.isEmpty) {
                return _buildFallbackBanner();
              }

              // 2. Sicurezza: Evita crash se l'indice impazzisce oltre la lunghezza dell'array
              final safeIndex = currentStepIndex < steps.length ? currentStepIndex : steps.length - 1;

              // 3. Estrai lo step CORRENTE (quello da mostrare in grande)
              final currentStep = steps[safeIndex];

              // 4. Estrai lo step SUCCESSIVO (se esiste) per darne un'anteprima,
              // esattamente come fa Google Maps ("poi svolta a...")
              final nextStep = (safeIndex + 1 < steps.length) ? steps[safeIndex + 1] : null;

              return Container(
                color: Colors.green.shade800,
                padding: EdgeInsets.only(
                  top: MediaQuery.of(context).padding.top + 16,
                  bottom: 16,
                  left: 16,
                  right: 16,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start, // Allinea gli elementi in alto
                  children: [
                    // Icona della Manovra Corrente
                    // Qui al posto di freccia_su mettiamo un placeholder dinamico pronto
                    // per essere integrato con icone mappate su "maneuver" (es. Icons.turn_right).
                    const Padding(
                      padding: EdgeInsets.only(top: 4.0),
                      child: Icon(Icons.directions, color: Colors.white, size: 40),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // TESTO PRINCIPALE (Istruzione Corrente)
                          Text(
                            currentStep.instruction, // "Svolta a destra su Via Roma"
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 22,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 4),
                          
                          // DISTANZA (Istruzione Corrente)
                          Text(
                            currentStep.distance, // "1.2 km"
                            style: TextStyle(
                              color: Colors.white.withAlpha(220), // deprecated warning fix for withOpacity
                              fontSize: 16,
                              fontWeight: FontWeight.w500,
                            ),
                          ),

                          // ANTEPRIMA STEP SUCCESSIVO (se esiste)
                          if (nextStep != null) ...[
                            const SizedBox(height: 12),
                            Container(
                              padding: const EdgeInsets.only(top: 12),
                              decoration: BoxDecoration(
                                border: Border(
                                  top: BorderSide(color: Colors.white.withAlpha(50)),
                                ),
                              ),
                              child: Row(
                                children: [
                                  Icon(Icons.subdirectory_arrow_right, color: Colors.white.withAlpha(150), size: 16),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      "Poi: ${nextStep.instruction}",
                                      style: TextStyle(
                                        color: Colors.white.withAlpha(200),
                                        fontSize: 14,
                                        fontStyle: FontStyle.italic,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ]
                        ],
                      ),
                    ),
                    // Pulsante "Chiudi Navigazione"
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white),
                      onPressed: () {
                        // Ferma navigazione
                        _navigationMonitor.stopNavigation();
                        setState(() {
                          _appState = NavigationAppState.routePreview; // o ricerca
                        });
                      },
                    ),
                  ],
                ),
              );
            },
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
                // Eventuali Info extra (es arriovo previsto)
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// Metodo Helper per estrarre la grafica di "Fallback" quando non c'è una rotta 
  /// (usato se il _navigationMonitor non ha ancora sincronizzato i percorsi).
  Widget _buildFallbackBanner() {
    return Container(
      color: Colors.green.shade800,
      padding: EdgeInsets.only(
        top: MediaQuery.of(context).padding.top + 16,
        bottom: 16,
        left: 16,
        right: 16,
      ),
      child: Row(
        children: [
          const Icon(Icons.arrow_upward, color: Colors.white, size: 40),
          const SizedBox(width: 16),
          const Expanded(
            child: Text(
              'Procedi lungo il percorso',
              style: TextStyle(
                color: Colors.white,
                fontSize: 24,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, color: Colors.white),
            onPressed: () {
              _navigationMonitor.stopNavigation();
              setState(() {
                _appState = NavigationAppState.routePreview;
              });
            },
          ),
        ],
      ),
    );
  }

  /// Widget per mostrare errori
  Widget _buildErrorMessage() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.red.shade50,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.red.shade200),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, color: Colors.red.shade700),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _errorMessage!,
              style: TextStyle(color: Colors.red.shade700),
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
