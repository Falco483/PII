library;

/// Modello dati per un singolo overlay mostrato durante una sessione di navigazione.
///
/// Viene registrato ogni volta che il NavigationMonitor emette un overlay
/// (sia [OverlayType.turnInstruction] che [OverlayType.lateralRoadDetected]).
class OverlayRecord {
  /// Tipo di overlay: 'turnInstruction' o 'lateralRoadDetected'.
  final String type;

  /// Messaggio testuale mostrato all'utente nell'overlay.
  final String message;

  /// Istante in cui l'overlay è stato mostrato (formato ISO 8601).
  final String timestamp;

  const OverlayRecord({
    required this.type,
    required this.message,
    required this.timestamp,
  });

  Map<String, dynamic> toJson() => {
    'type': type,
    'message': message,
    'timestamp': timestamp,
  };

  factory OverlayRecord.fromJson(Map<String, dynamic> json) {
    return OverlayRecord(
      type: (json['type'] ?? '').toString(),
      message: (json['message'] ?? '').toString(),
      timestamp: (json['timestamp'] ?? '').toString(),
    );
  }
}

/// Modello dati per una sessione di navigazione completa.
///
/// Una sessione inizia quando l'utente avvia la navigazione ([startNavigation])
/// e termina quando la ferma ([stopNavigation]) o l'app viene chiusa ([dispose]).
///
/// ESTENSIBILITÀ:
/// Il campo [extraData] permette di aggiungere nuovi parametri in futuro
/// senza modificare la struttura base del modello.
class NavigationSession {
  /// Identificatore univoco della sessione (generato al momento della creazione).
  final String sessionId;

  /// Destinazione verso cui l'utente stava navigando.
  final String destination;

  /// Istante di avvio della navigazione (formato ISO 8601).
  final String startTime;

  /// Istante di fine navigazione (formato ISO 8601).
  /// È null se la sessione non è ancora terminata (es. sessione zombie da crash).
  String? endTime;

  /// Lista degli overlay mostrati durante la sessione.
  final List<OverlayRecord> overlays;

  /// Numero di ricalcoli del percorso effettuati (Task 2b + Task 2c).
  int rerouteCount;

  /// Mappa per dati aggiuntivi futuri (es. distanza totale, velocità media, ecc.).
  final Map<String, dynamic> extraData;

  NavigationSession({
    required this.sessionId,
    required this.destination,
    required this.startTime,
    this.endTime,
    List<OverlayRecord>? overlays,
    this.rerouteCount = 0,
    Map<String, dynamic>? extraData,
  }) : overlays = overlays ?? [],
       extraData = extraData ?? {};

  Map<String, dynamic> toJson() => {
    'sessionId': sessionId,
    'destination': destination,
    'startTime': startTime,
    'endTime': endTime,
    'overlays': overlays.map((o) => o.toJson()).toList(),
    'rerouteCount': rerouteCount,
    'extraData': extraData,
  };

  factory NavigationSession.fromJson(Map<String, dynamic> json) {
    // Deserializza la lista di overlay in modo difensivo:
    // se il campo manca o non è una lista, usa lista vuota.
    final List<OverlayRecord> overlayList;
    final rawOverlays = json['overlays'];
    if (rawOverlays is List) {
      overlayList = rawOverlays
          .whereType<Map<String, dynamic>>()
          .map(OverlayRecord.fromJson)
          .toList();
    } else {
      overlayList = [];
    }

    // Deserializza extraData in modo difensivo.
    final Map<String, dynamic> extra;
    final rawExtra = json['extraData'];
    if (rawExtra is Map<String, dynamic>) {
      extra = rawExtra;
    } else {
      extra = {};
    }

    return NavigationSession(
      sessionId: (json['sessionId'] ?? '').toString(),
      destination: (json['destination'] ?? '').toString(),
      startTime: (json['startTime'] ?? '').toString(),
      endTime: json['endTime'] as String?,
      overlays: overlayList,
      rerouteCount: (json['rerouteCount'] as num?)?.toInt() ?? 0,
      extraData: extra,
    );
  }
}
