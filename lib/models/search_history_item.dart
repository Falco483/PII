library;

/// Modello dati per una ricerca memorizzata in cronologia.
///
/// Il campo timestamp (epoch ms) rappresenta l'istante dell'ultima ricerca
/// effettuata per quell'indirizzo/coordinate.
class SearchHistoryItem {
  final String address;
  final double lat;
  final double lng;
  final int timestamp;

  const SearchHistoryItem({
    required this.address,
    required this.lat,
    required this.lng,
    required this.timestamp,
  });

  Map<String, dynamic> toJson() {
    return {'address': address, 'lat': lat, 'lng': lng, 'timestamp': timestamp};
  }

  factory SearchHistoryItem.fromJson(Map<String, dynamic> json) {
    return SearchHistoryItem(
      address: (json['address'] ?? '').toString(),
      lat: (json['lat'] as num?)?.toDouble() ?? 0,
      lng: (json['lng'] as num?)?.toDouble() ?? 0,
      timestamp: (json['timestamp'] as num?)?.toInt() ?? 0,
    );
  }

  /// Chiave canonica usata per la deduplica.
  /// Esclude il timestamp per permettere il suo aggiornamento su ricerche ripetute.
  String dedupKey() {
    return '${address.trim().toLowerCase()}|$lat|$lng';
  }

  SearchHistoryItem copyWith({
    String? address,
    double? lat,
    double? lng,
    int? timestamp,
  }) {
    return SearchHistoryItem(
      address: address ?? this.address,
      lat: lat ?? this.lat,
      lng: lng ?? this.lng,
      timestamp: timestamp ?? this.timestamp,
    );
  }
}
