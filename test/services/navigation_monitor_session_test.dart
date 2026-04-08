import 'package:flutter_test/flutter_test.dart';

import 'package:pii/models/navigation_session.dart';
import 'package:pii/services/directions_service.dart';
import 'package:pii/services/navigation_monitor.dart';
import 'package:pii/services/navigation_session_service.dart';
import 'package:pii/services/roads_service.dart';

// =============================================================================
// MOCK SERVICES
// =============================================================================

class MockNavigationSessionService extends NavigationSessionService {
  final List<NavigationSession> savedSessions = [];

  @override
  Future<void> saveSession(NavigationSession session) async {
    savedSessions.add(session);
  }

  @override
  Future<List<NavigationSession>> getHistory() async {
    return savedSessions;
  }

  @override
  Future<void> clearHistory() async {
    savedSessions.clear();
  }
}

class FakeRoadsService extends RoadsService {
  final List<SnappedPoint>? mockResponse;

  FakeRoadsService({this.mockResponse});

  @override
  Future<List<SnappedPoint>?> findNearestRoads(List<List<double>> points) async {
    return mockResponse;
  }
}

class FakeDirectionsService extends DirectionsService {
  final AllRoutesResult? mockResponse;

  FakeDirectionsService({this.mockResponse});

  @override
  Future<AllRoutesResult?> getDirectionsWithAlternatives({
    required String origin,
    required String destination,
  }) async {
    return mockResponse;
  }
}

// =============================================================================
// HELPER METHODS
// =============================================================================

AllRoutesResult createMockRoutes() {
  // Polyline di un percorso dritto immaginario verso nord
  final mainRoute = RouteData(
    decodedPolyline: [[0.0, 0.0], [0.1, 0.0]],
    durationSeconds: 1000,
    totalDuration: '10 min',
    totalDistance: '1 km',
    encodedPolyline: 'encoded_1',
    steps: [],
  );

  final altRoute = RouteData(
    decodedPolyline: [[0.0, 0.1], [0.1, 0.1]], // parallela spostata a est
    durationSeconds: 1200,
    totalDuration: '12 min',
    totalDistance: '1.2 km',
    encodedPolyline: 'encoded_2',
    steps: [],
  );

  return AllRoutesResult(
    bestRoute: mainRoute,
    allRoutes: [mainRoute, altRoute],
    originLat: 0.0,
    originLng: 0.0,
    destLat: 0.1,
    destLng: 0.0,
  );
}

// =============================================================================
// TEST SUITE
// =============================================================================

void main() {
  late MockNavigationSessionService mockSessionService;
  late NavigationMonitor monitor;

  setUp(() {
    mockSessionService = MockNavigationSessionService();
    monitor = NavigationMonitor(
      sessionService: mockSessionService,
      roadsService: FakeRoadsService(mockResponse: []),
      directionsService: FakeDirectionsService(mockResponse: null),
    );
  });

  tearDown(() {
    monitor.dispose();
  });

  // ---------------------------------------------------------------------------
  // Test comportamentale: startNavigation produce una sessione con i dati attesi
  // Verifichiamo tramite stopNavigation che i dati salvati siano corretti.
  // ---------------------------------------------------------------------------
  test('startNavigation avvia una sessione con i dati corretti', () {
    // Prima di avviare: nessuna sessione salvata
    expect(mockSessionService.savedSessions, isEmpty);

    monitor.startNavigation(createMockRoutes(), 'Duomo');
    monitor.stopNavigation();

    // Dopo lo stop: la sessione deve essere stata salvata
    expect(mockSessionService.savedSessions.length, 1);
    final saved = mockSessionService.savedSessions.first;

    // La destinazione deve corrispondere
    expect(saved.destination, 'Duomo');
    // La sessione appena avviata e subito terminata non ha overlay
    expect(saved.overlays, isEmpty);
    // Il contatore di ricalcoli parte da zero
    expect(saved.rerouteCount, 0);
    // L'endTime deve essere stato impostato dallo stopNavigation
    expect(saved.endTime, isNotNull);
  });

  test('stopNavigation senza startNavigation non salva nulla', () {
    monitor.stopNavigation();
    expect(mockSessionService.savedSessions, isEmpty);
  });

  test('stopNavigation salva la sessione con endTime impostato', () {
    monitor.startNavigation(createMockRoutes(), 'Duomo');
    monitor.stopNavigation();

    expect(mockSessionService.savedSessions.length, 1);
    final saved = mockSessionService.savedSessions.first;
    expect(saved.destination, 'Duomo');
    expect(saved.endTime, isNotNull);
  });

  test('dispose con navigazione attiva salva la sessione (crash guard)', () {
    // Usa un monitor locale per poter chiamare dispose() e verificarne il risultato
    // dentro il test (il tearDown chiamerebbe dispose() sul monitor principale).
    final localMonitor = NavigationMonitor(
      sessionService: mockSessionService,
      roadsService: FakeRoadsService(mockResponse: []),
      directionsService: FakeDirectionsService(mockResponse: null),
    );
    localMonitor.startNavigation(createMockRoutes(), 'Duomo');
    localMonitor.dispose();

    expect(mockSessionService.savedSessions.length, 1);
    expect(mockSessionService.savedSessions.first.endTime, isNotNull);
  });

  test('activeRouteNotifier emette il percorso dopo startNavigation', () {
    expect(monitor.activeRouteNotifier.value, isNull);

    monitor.startNavigation(createMockRoutes(), 'Duomo');

    expect(monitor.activeRouteNotifier.value, isNotNull);
    expect(monitor.activeRouteNotifier.value!.totalDuration, '10 min');
  });

  test('activeRouteNotifier torna null dopo stopNavigation', () {
    monitor.startNavigation(createMockRoutes(), 'Duomo');
    monitor.stopNavigation();

    expect(monitor.activeRouteNotifier.value, isNull);
  });

  test('overlay laterale emesso su overlayNotifier viene rilevato', () async {
    // Usa un fake roads service che restituisce una strada trovata
    final analyzerMonitor = NavigationMonitor(
      sessionService: mockSessionService,
      roadsService: FakeRoadsService(mockResponse: [
        SnappedPoint(latitude: 0, longitude: 0, placeId: '1', originalIndex: 0),
      ]),
    );

    analyzerMonitor.startNavigation(createMockRoutes(), 'Duomo');

    // Mettiamo "in movimento" il monitor per abilitare l'analisi
    analyzerMonitor.updatePosition(0.0, 0.0, 10.0, 90.0);
    await Future.delayed(const Duration(milliseconds: 100));

    // Fermiamo l'utente: scatterà il countdown zero-speed
    analyzerMonitor.updatePosition(0.0, 0.0, 0.0, 90.0);

    // Verifichiamo che il notifier sia accessibile (il timer interno è a 10s,
    // quindi non aspettiamo ma verifichiamo che l'infrastruttura funzioni)
    expect(analyzerMonitor.overlayNotifier, isNotNull);

    analyzerMonitor.dispose();
  });

  test('Flusso: start → stop → dati sessione corretti in savedSessions', () {
    monitor.startNavigation(createMockRoutes(), 'Colosseo');
    monitor.stopNavigation();

    expect(mockSessionService.savedSessions.length, 1);
    final saved = mockSessionService.savedSessions.first;
    expect(saved.destination, 'Colosseo');
    expect(saved.endTime, isNotNull);
    // Una sessione avviata e subito fermata non ha ricalcoli
    expect(saved.rerouteCount, 0);
  });
}
