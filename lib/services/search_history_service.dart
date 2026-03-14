library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/search_history_item.dart';

class SearchHistoryService {
  static const String _storageKey = 'search_history_v1';

  /// Limite massimo di elementi memorizzati.
  /// Modificare questo valore per aumentare/ridurre la memoria storica.
  static const int MAX_MEMORY_ITEMS = 10;

  Future<List<SearchHistoryItem>> loadHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_storageKey);
    if (raw == null || raw.isEmpty) {
      return const [];
    }

    try {
      final decoded = jsonDecode(raw) as List<dynamic>;
      final items = decoded
          .whereType<Map<String, dynamic>>()
          .map(SearchHistoryItem.fromJson)
          .toList();

      items.sort((a, b) => b.timestamp.compareTo(a.timestamp));
      return items.take(MAX_MEMORY_ITEMS).toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  Future<void> recordSearch(SearchHistoryItem item) async {
    final current = await loadHistory();

    // Mappa indicizzata da chiave canonica (senza timestamp) per deduplica.
    final Map<String, SearchHistoryItem> dedupMap = {
      for (final entry in current) entry.dedupKey(): entry,
    };

    // Se esiste già, viene sostituito con timestamp aggiornato.
    dedupMap[item.dedupKey()] = item;

    final updated = dedupMap.values.toList()
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));

    final limited = updated.take(MAX_MEMORY_ITEMS).toList(growable: false);

    final prefs = await SharedPreferences.getInstance();
    final encoded = jsonEncode(limited.map((e) => e.toJson()).toList());
    await prefs.setString(_storageKey, encoded);
  }

  Future<void> clearHistory() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_storageKey);
  }
}
