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
import '../models/search_history_item.dart';
import '../services/directions_service.dart';
import '../services/navigation_monitor.dart';
import '../services/search_history_service.dart';
import '../widgets/map_widget.dart';
import '../widgets/search_input.dart';
import '../widgets/directions_list.dart';
import '../widgets/navigation_overlay.dart';

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

  /// Servizio per la memoria delle ultime ricerche.
  final SearchHistoryService _searchHistoryService = SearchHistoryService();

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
  // LOGICA CALCOLO PERCORSO
  // ===========================================================================

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

          // TASK 5: Avvia la navigazione nel monitor.
          // Usa destAddress per il ricalcolo futuro (Task 2c del monitor)
          // perché se l'utente devia, la destinazione deve restare la stessa.
          _navigationMonitor.startNavigation(result, destAddress);
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

    // Avvia il calcolo del percorso con le coordinate ricevute.
    // L'origine sarà la posizione GPS corrente (gestita internamente).
    _calculateRouteFromCoordinates(lat, lng, address);
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
    // Costruisce una stringa descrittiva con le coordinate
    final String coordsText =
        '${position.latitude.toStringAsFixed(5)}, '
        '${position.longitude.toStringAsFixed(5)}';

    // Aggiorna il campo di testo con le coordinate per feedback visivo.
    // L'utente vede cosa ha selezionato.
    _destinationController.text = coordsText;

    // Log per debugging
    print('Punto mappa selezionato: $coordsText');

    // Avvia il calcolo del percorso direttamente con le coordinate.
    // Nessuna chiamata a Places Details API necessaria.
    _calculateRouteFromCoordinates(
      position.latitude,
      position.longitude,
      coordsText, // Usa le coordinate come "indirizzo" per il ricalcolo
    );
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
    return Column(
      children: [
        // Pannello ricerca sempre visibile
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: SearchInput(
            destinationController: _destinationController,
            onDestinationSelected: _onDestinationSelected,
            isLoading: _isLoading,
          ),
        ),

        // Messaggio di errore
        if (_errorMessage != null) _buildErrorMessage(),

        // Mappa con overlay
        Expanded(
          flex: 2,
          child: Padding(
            padding: const EdgeInsets.all(8.0),
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

                  // --- LAYER 3: Overlay navigazione (istruzione svolta / "vai diritto") ---
                  // Questo overlay viene mostrato dal NavigationMonitor quando:
                  // a) L'utente è fermo su un waypoint di svolta → mostra html_instructions
                  // b) La Roads API trova strade laterali → mostra "vai diritto stronzo"
                  NavigationOverlay(
                    state: _overlayState,
                    onDismiss: () {
                      // Quando l'overlay viene chiuso (tap o timeout),
                      // resettiamo lo stato a null per nasconderlo.
                      setState(() {
                        _overlayState = null;
                      });
                      // Resettiamo anche il notifier del monitor per evitare
                      // che lo stesso evento venga ri-emesso.
                      _navigationMonitor.overlayNotifier.value = null;
                    },
                  ),
                ],
              ),
            ),
          ),
        ),

        // Lista indicazioni (se disponibile)
        if (_directionsResult != null)
          Expanded(
            flex: 1,
            child: Padding(
              padding: const EdgeInsets.all(8.0),
              child: DirectionsList(
                steps: _directionsResult!.steps,
                totalDistance: _directionsResult!.totalDistance,
                totalDuration: _directionsResult!.totalDuration,
              ),
            ),
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
  // WIDGET HELPER
  // ===========================================================================

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
    return Positioned(
      bottom: 24,
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
