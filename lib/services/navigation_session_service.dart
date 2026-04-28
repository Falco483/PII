import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/navigation_session.dart';

/// Servizio per la persistenza delle sessioni di navigazione su SharedPreferences.
///
/// Mantiene uno storico delle sessioni completate, limitato a 50 sessioni.
/// Tutte le operazioni falliscono silenziosamente (no exception thrown).
class NavigationSessionService {
  static const String _storageKey = 'navigation_sessions';
  static const int _maxSessions = 50;

  /// Salva una sessione completata in SharedPreferences.
  ///
  /// Le sessioni più recenti vengono inserite in cima alla lista.
  /// Se il limite di 50 sessioni è raggiunto, le sessioni più vecchie
  /// vengono eliminate.
  Future<void> saveSession(NavigationSession session) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final sessions = await getHistory();
      sessions.insert(0, session); // Più recente prima
      if (sessions.length > _maxSessions) {
        sessions.removeRange(_maxSessions, sessions.length);
      }
      final encoded = sessions.map((s) => jsonEncode(s.toJson())).toList();
      await prefs.setStringList(_storageKey, encoded);
      print('✅ NavigationSessionService: Sessione salvata - ID: ${session.sessionId}, Overlay: ${session.overlays.length}, Ricalcoli: ${session.rerouteCount}');
    } catch (e) {
      // Fail silently - non disturbiamo l'utente se lo storage fallisce
      print('❌ NavigationSessionService: Errore nel salvataggio - $e');
    }
  }

  /// Recupera la lista di tutte le sessioni salvate.
  ///
  /// Restituisce una lista ordinata con le sessioni più recenti in cima.
  /// Ritorna una lista vuota se c'è un errore di deserializzazione.
  Future<List<NavigationSession>> getHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getStringList(_storageKey) ?? [];
      final sessions = raw
          .map((s) => NavigationSession.fromJson(
                jsonDecode(s) as Map<String, dynamic>,
              ))
          .toList();
      sessions.sort((a, b) => b.startTime.compareTo(a.startTime));
      print('✅ NavigationSessionService: Caricate ${sessions.length} sessioni');
      for (var s in sessions) {
        print('   → ID: ${s.sessionId}, Overlay: ${s.overlays.length}, Ricalcoli: ${s.rerouteCount}');
      }
      return sessions;
    } catch (e) {
      print('❌ NavigationSessionService: Errore nel caricamento - $e');
      return [];
    }
  }

  /// Cancella tutta la cronologia delle sessioni.
  Future<void> clearHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_storageKey);
    } catch (_) {}
  }
}
