library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/navigation_session.dart';

/// Servizio per la persistenza dello storico delle sessioni di navigazione.
///
/// Salva e recupera una lista di [NavigationSession] in `shared_preferences`
/// come stringa JSON. Le sessioni sono ordinate per `startTime` decrescente
/// (la più recente per prima).
///
/// PATTERN DI UTILIZZO:
/// ```dart
/// final service = NavigationHistoryService();
/// await service.saveSession(session);
/// final history = await service.getHistory();
/// ```
class NavigationHistoryService {
  static const String _storageKey = 'navigation_history_v1';

  /// Numero massimo di sessioni salvate in memoria.
  /// Le sessioni più vecchie vengono scartate quando si supera questo limite.
  static const int maxStoredSessions = 50;

  /// Salva una sessione di navigazione aggiungendola alla cronologia esistente.
  ///
  /// Se la cronologia supera [maxStoredSessions], le sessioni più vecchie
  /// (per `startTime`) vengono eliminate.
  ///
  /// EDGE CASE:
  /// - Se [SharedPreferences.getInstance] fallisce, l'errore viene silenziosamente
  ///   inghiottito per non crashare l'app durante lo stop della navigazione.
  /// - Se la sessione ha campi non serializzabili in [extraData], l'errore
  ///   viene catturato e loggato.
  Future<void> saveSession(NavigationSession session) async {
    try {
      final current = await getHistory();

      // Aggiunge la nuova sessione e ordina per startTime decrescente.
      final updated = [...current, session]
        ..sort((a, b) => b.startTime.compareTo(a.startTime));

      // Mantiene solo le ultime maxStoredSessions.
      final limited = updated.take(maxStoredSessions).toList(growable: false);

      final prefs = await SharedPreferences.getInstance();
      final encoded = jsonEncode(limited.map((s) => s.toJson()).toList());
      await prefs.setString(_storageKey, encoded);

      // Log di debug per verifica manuale.
      print('✅ Sessione salvata: ${session.sessionId} '
          '| overlays: ${session.overlays.length} '
          '| reroute: ${session.rerouteCount} '
          '| endTime: ${session.endTime}');
    } catch (e) {
      // Fallback silenzioso: salvare la sessione è non-critico.
      // L'app non deve crashare per un errore di persistenza.
      print('⚠️ Errore nel salvataggio della sessione di navigazione: $e');
    }
  }

  /// Recupera la cronologia completa delle sessioni di navigazione.
  ///
  /// Restituisce una lista vuota in tutti i casi di errore:
  /// - Dati mancanti in `shared_preferences`
  /// - JSON corrotto o non parsabile
  /// - Eccezioni impreviste
  Future<List<NavigationSession>> getHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_storageKey);

      if (raw == null || raw.isEmpty) return const [];

      final decoded = jsonDecode(raw) as List<dynamic>;
      return decoded
          .whereType<Map<String, dynamic>>()
          .map(NavigationSession.fromJson)
          .toList();
    } catch (_) {
      // JSON corrotto o SharedPreferences non disponibile.
      return const [];
    }
  }

  /// Cancella tutta la cronologia delle sessioni di navigazione.
  Future<void> clearHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_storageKey);
    } catch (e) {
      print('⚠️ Errore nella cancellazione della cronologia: $e');
    }
  }
}
