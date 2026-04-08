import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:pii2/models/navigation_session.dart';
import 'package:pii2/services/navigation_history_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late NavigationHistoryService service;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    service = NavigationHistoryService();
  });

  // Helper per creare sessioni di test
  NavigationSession makeSession({
    String id = '1000',
    String destination = 'Piazza Duomo',
    String startTime = '2026-03-24T10:00:00.000Z',
    String? endTime = '2026-03-24T10:30:00.000Z',
    int rerouteCount = 0,
    List<OverlayRecord> overlays = const [],
  }) {
    return NavigationSession(
      sessionId: id,
      destination: destination,
      startTime: startTime,
      endTime: endTime,
      rerouteCount: rerouteCount,
      overlays: overlays,
    );
  }

  test('getHistory su storage vuoto restituisce lista vuota (no crash)', () async {
    final history = await service.getHistory();
    expect(history, isEmpty);
  });

  test('saveSession + getHistory: sessione presente con dati corretti', () async {
    final session = makeSession(
      id: 'sess-1',
      destination: 'Colosseo',
      rerouteCount: 3,
      overlays: [
        const OverlayRecord(
          type: 'lateralRoadDetected',
          message: 'vai diritto stronzo',
          timestamp: '2026-03-24T10:10:00.000Z',
        ),
      ],
    );

    await service.saveSession(session);
    final history = await service.getHistory();

    expect(history.length, 1);
    expect(history.first.sessionId, 'sess-1');
    expect(history.first.destination, 'Colosseo');
    expect(history.first.rerouteCount, 3);
    expect(history.first.overlays.length, 1);
    expect(history.first.overlays.first.type, 'lateralRoadDetected');
  });

  test('saveSession multipli: la cronologia cresce (no deduplica)', () async {
    await service.saveSession(makeSession(
      id: '1', startTime: '2026-03-24T08:00:00.000Z',
    ));
    await service.saveSession(makeSession(
      id: '2', startTime: '2026-03-24T09:00:00.000Z',
    ));
    await service.saveSession(makeSession(
      id: '3', startTime: '2026-03-24T10:00:00.000Z',
    ));

    final history = await service.getHistory();
    expect(history.length, 3);
  });

  test('getHistory ordina per startTime decrescente', () async {
    await service.saveSession(makeSession(
      id: 'A', startTime: '2026-03-24T08:00:00.000Z',
    ));
    await service.saveSession(makeSession(
      id: 'B', startTime: '2026-03-24T10:00:00.000Z',
    ));
    await service.saveSession(makeSession(
      id: 'C', startTime: '2026-03-24T09:00:00.000Z',
    ));

    final history = await service.getHistory();
    final ids = history.map((s) => s.sessionId).toList();
    expect(ids, ['B', 'C', 'A']);
  });

  test('rispetto del limite maxStoredSessions: le sessioni più vecchie vengono scartate', () async {
    // Salva maxStoredSessions + 5 sessioni
    for (int i = 0; i < NavigationHistoryService.maxStoredSessions + 5; i++) {
      await service.saveSession(makeSession(
        id: 'sess-$i',
        // startTime crescente: le ultime sono le più recenti
        startTime: '2026-03-24T${i.toString().padLeft(2, '0')}:00:00.000Z',
      ));
    }

    final history = await service.getHistory();
    expect(history.length, NavigationHistoryService.maxStoredSessions);
    // La più recente deve essere il top della lista
    expect(
      history.first.sessionId,
      'sess-${NavigationHistoryService.maxStoredSessions + 4}',
    );
  });

  test('clearHistory svuota lo storage', () async {
    await service.saveSession(makeSession(id: 'to-delete'));
    await service.clearHistory();
    final history = await service.getHistory();
    expect(history, isEmpty);
  });

  test('sessione con endTime null (zombie) viene salvata e caricata correttamente', () async {
    final session = NavigationSession(
      sessionId: 'zombie-session',
      destination: 'Stazione Termini',
      startTime: '2026-03-24T10:00:00.000Z',
      endTime: null,
    );

    await service.saveSession(session);
    final history = await service.getHistory();

    expect(history.length, 1);
    expect(history.first.sessionId, 'zombie-session');
    expect(history.first.endTime, isNull);
  });

  test('getHistory con JSON corrotto in storage restituisce lista vuota (no crash)', () async {
    SharedPreferences.setMockInitialValues({
      'navigation_history_v1': 'JSON_CORROTTO_{{{',
    });
    final service2 = NavigationHistoryService();
    final history = await service2.getHistory();
    expect(history, isEmpty);
  });

  test('sessione vuota (zero overlay, zero reroute) viene salvata correttamente', () async {
    await service.saveSession(makeSession(rerouteCount: 0, overlays: []));
    final history = await service.getHistory();
    expect(history.first.rerouteCount, 0);
    expect(history.first.overlays, isEmpty);
  });
}
