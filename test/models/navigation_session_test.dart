import 'package:flutter_test/flutter_test.dart';

import 'package:pii/models/navigation_session.dart';

void main() {
  // ---------------------------------------------------------------------------
  // OverlayRecord
  // ---------------------------------------------------------------------------
  group('OverlayRecord', () {
    test('toJson/fromJson round-trip conserva tutti i campi', () {
      const record = OverlayRecord(
        type: 'lateralRoadDetected',
        message: 'vai diritto stronzo',
        timestamp: '2026-03-24T10:00:00.000Z',
      );

      final json = record.toJson();
      final restored = OverlayRecord.fromJson(json);

      expect(restored.type, record.type);
      expect(restored.message, record.message);
      expect(restored.timestamp, record.timestamp);
    });

    test('fromJson con campi mancanti usa valori vuoti (no crash)', () {
      final record = OverlayRecord.fromJson({});

      expect(record.type, '');
      expect(record.message, '');
      expect(record.timestamp, '');
    });

    test('fromJson con campi di tipo errato usa valori di default', () {
      final record = OverlayRecord.fromJson({
        'type': 42,
        'message': null,
        'timestamp': true,
      });

      expect(record.type, '42');
      expect(record.message, '');
      expect(record.timestamp, 'true');
    });
  });

  // ---------------------------------------------------------------------------
  // NavigationSession
  // ---------------------------------------------------------------------------
  group('NavigationSession', () {
    test('toJson/fromJson round-trip conserva tutti i campi', () {
      final session = NavigationSession(
        sessionId: '1711271000000',
        destination: 'Piazza del Duomo, Milano',
        startTime: '2026-03-24T10:00:00.000Z',
        endTime: '2026-03-24T10:30:00.000Z',
        overlays: [
          const OverlayRecord(
            type: 'turnInstruction',
            message: 'Svolta a destra',
            timestamp: '2026-03-24T10:10:00.000Z',
          ),
          const OverlayRecord(
            type: 'lateralRoadDetected',
            message: 'vai diritto stronzo',
            timestamp: '2026-03-24T10:20:00.000Z',
          ),
        ],
        rerouteCount: 2,
        extraData: {'speed_avg': 35.5},
      );

      final json = session.toJson();
      final restored = NavigationSession.fromJson(json);

      expect(restored.sessionId, session.sessionId);
      expect(restored.destination, session.destination);
      expect(restored.startTime, session.startTime);
      expect(restored.endTime, session.endTime);
      expect(restored.rerouteCount, session.rerouteCount);
      expect(restored.overlays.length, 2);
      expect(restored.overlays[0].type, 'turnInstruction');
      expect(restored.overlays[1].type, 'lateralRoadDetected');
      expect(restored.extraData['speed_avg'], 35.5);
    });

    test('fromJson con endTime null (sessione zombie) - no crash', () {
      final session = NavigationSession.fromJson({
        'sessionId': 'abc',
        'destination': 'Via Roma 1',
        'startTime': '2026-03-24T10:00:00.000Z',
        'endTime': null,
        'overlays': [],
        'rerouteCount': 0,
      });

      expect(session.endTime, isNull);
      expect(session.overlays, isEmpty);
    });

    test('fromJson con overlays mancanti usa lista vuota', () {
      final session = NavigationSession.fromJson({
        'sessionId': 'abc',
        'destination': 'Piazza Navona',
        'startTime': '2026-03-24T10:00:00.000Z',
      });

      expect(session.overlays, isEmpty);
    });

    test('fromJson con overlays non-lista usa lista vuota', () {
      final session = NavigationSession.fromJson({
        'sessionId': 'abc',
        'destination': 'Piazza Navona',
        'startTime': '2026-03-24T10:00:00.000Z',
        'overlays': 'not-a-list',
      });

      expect(session.overlays, isEmpty);
    });

    test('fromJson con extraData mancante usa mappa vuota', () {
      final session = NavigationSession.fromJson({
        'sessionId': 'abc',
        'destination': 'Via Torino 1',
        'startTime': '2026-03-24T10:00:00.000Z',
      });

      expect(session.extraData, isEmpty);
    });

    test('fromJson con extraData di tipo errato usa mappa vuota', () {
      final session = NavigationSession.fromJson({
        'sessionId': 'abc',
        'destination': 'Via Torino 1',
        'startTime': '2026-03-24T10:00:00.000Z',
        'extraData': 'not-a-map',
      });

      expect(session.extraData, isEmpty);
    });

    test('costruttore di default: overlays vuoto, rerouteCount zero', () {
      final session = NavigationSession(
        sessionId: '123',
        destination: 'Stazione Centrale',
        startTime: '2026-03-24T10:00:00.000Z',
      );

      expect(session.overlays, isEmpty);
      expect(session.rerouteCount, 0);
      expect(session.extraData, isEmpty);
      expect(session.endTime, isNull);
    });
  });
}
