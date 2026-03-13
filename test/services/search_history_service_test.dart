import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:pii2/models/search_history_item.dart';
import 'package:pii2/services/search_history_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SearchHistoryService service;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    service = SearchHistoryService();
  });

  test('serializzazione/deserializzazione SearchHistoryItem', () {
    const item = SearchHistoryItem(
      address: 'Via Roma 1',
      lat: 45.0,
      lng: 9.0,
      timestamp: 123456,
    );

    final json = item.toJson();
    final restored = SearchHistoryItem.fromJson(json);

    expect(restored.address, item.address);
    expect(restored.lat, item.lat);
    expect(restored.lng, item.lng);
    expect(restored.timestamp, item.timestamp);
  });

  test(
    'deduplica su stessi campi tranne timestamp con aggiornamento timestamp',
    () async {
      await service.recordSearch(
        const SearchHistoryItem(
          address: 'Duomo Milano',
          lat: 45.4642,
          lng: 9.19,
          timestamp: 1000,
        ),
      );

      await service.recordSearch(
        const SearchHistoryItem(
          address: 'Duomo Milano',
          lat: 45.4642,
          lng: 9.19,
          timestamp: 2000,
        ),
      );

      final history = await service.loadHistory();

      expect(history.length, 1);
      expect(history.first.timestamp, 2000);
    },
  );

  test('ordinamento per timestamp decrescente', () async {
    await service.recordSearch(
      const SearchHistoryItem(address: 'A', lat: 1, lng: 1, timestamp: 1000),
    );
    await service.recordSearch(
      const SearchHistoryItem(address: 'B', lat: 2, lng: 2, timestamp: 3000),
    );
    await service.recordSearch(
      const SearchHistoryItem(address: 'C', lat: 3, lng: 3, timestamp: 2000),
    );

    final history = await service.loadHistory();
    final timestamps = history.map((e) => e.timestamp).toList();

    expect(timestamps, [3000, 2000, 1000]);
  });

  test('rispetto del limite MAX_MEMORY_ITEMS', () async {
    for (int i = 0; i < SearchHistoryService.MAX_MEMORY_ITEMS + 3; i++) {
      await service.recordSearch(
        SearchHistoryItem(
          address: 'Address $i',
          lat: i.toDouble(),
          lng: i.toDouble(),
          timestamp: i,
        ),
      );
    }

    final history = await service.loadHistory();

    expect(history.length, SearchHistoryService.MAX_MEMORY_ITEMS);
    expect(history.first.timestamp, SearchHistoryService.MAX_MEMORY_ITEMS + 2);
  });

  test('clearHistory svuota la memoria', () async {
    await service.recordSearch(
      const SearchHistoryItem(
        address: 'Via Torino',
        lat: 45.1,
        lng: 9.1,
        timestamp: 999,
      ),
    );

    await service.clearHistory();

    final history = await service.loadHistory();
    expect(history, isEmpty);
  });
}
