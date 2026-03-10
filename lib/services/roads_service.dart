/// roads_service.dart — Client per Google Roads API (nearestRoads)
///
/// Questo servizio gestisce le chiamate HTTP alla Roads API di Google,
/// specificamente all'endpoint `nearestRoads`, per trovare le strade
/// più vicine a un set di punti geografici.
///
/// PERCHÉ nearestRoads E NON snapToRoads:
/// - `snapToRoads` è progettato per "agganciare" una sequenza di punti GPS
///   a una strada (es. per tracciare un percorso già effettuato). Richiede
///   che i punti siano ordinati cronologicamente e cerca di costruire un
///   percorso coerente.
/// - `nearestRoads` è più semplice: per ogni punto, restituisce la strada
///   più vicina (se ne trova una entro ~300m). Non assume alcun ordine
///   tra i punti e non costruisce un percorso.
///
/// Nel nostro caso usiamo `nearestRoads` perché i 10 punti laterali non
/// sono un percorso: sono punti sparsi attorno alla posizione dell'utente
/// e vogliamo solo sapere se vicino ad essi c'è una strada.
///
/// SIDE EFFECTS: Effettua chiamate HTTP alla Roads API di Google.
/// Ogni chiamata consuma quota API e potenzialmente costa.
library;

import 'dart:convert';
import 'package:http/http.dart' as http;

/// Modello per un punto snappato restituito dalla Roads API.
///
/// La Roads API restituisce per ogni punto trovato:
/// - la posizione esatta sulla strada (latitude, longitude)
/// - l'ID della strada (placeId) su Google Maps
/// - l'indice del punto originale che è stato snappato (originalIndex)
class SnappedPoint {
  final double latitude;
  final double longitude;
  final String placeId;
  final int originalIndex;

  SnappedPoint({
    required this.latitude,
    required this.longitude,
    required this.placeId,
    required this.originalIndex,
  });

  /// Crea un SnappedPoint dal JSON della risposta API.
  ///
  /// Struttura del JSON per un singolo snapped point:
  /// {
  ///   "location": { "latitude": 45.123, "longitude": 9.456 },
  ///   "originalIndex": 0,
  ///   "placeId": "ChIJ..."
  /// }
  factory SnappedPoint.fromJson(Map<String, dynamic> json) {
    return SnappedPoint(
      latitude: (json['location']['latitude'] as num).toDouble(),
      longitude: (json['location']['longitude'] as num).toDouble(),
      placeId: json['placeId'] ?? '',
      originalIndex: json['originalIndex'] ?? 0,
    );
  }
}

/// Servizio per le chiamate alla Roads API di Google.
///
/// Uso tipico:
/// ```dart
/// final service = RoadsService();
/// final points = [[45.0, 9.0], [45.1, 9.1]]; // lat, lng
/// final result = await service.findNearestRoads(points);
/// if (result != null && result.isNotEmpty) {
///   print('Trovate strade vicine!');
/// }
/// ```
class RoadsService {
  /// API Key di Google — stessa usata per le Directions API.
  /// IMPORTANTE: La Roads API deve essere abilitata nel progetto Google Cloud.
  static const String apiKey = 'AIzaSyDvmPBsr_i6UzCzl5Rt2d9Pnsg1yV4m5Ww';

  /// URL base dell'endpoint nearestRoads
  static const String _baseUrl = 'https://roads.googleapis.com/v1/nearestRoads';

  /// Numero massimo di tentativi in caso di errore HTTP.
  /// Dopo il primo fallimento si ritenta una volta sola.
  static const int _maxRetries = 1;

  /// Trova le strade più vicine ai punti forniti.
  ///
  /// PARAMETRI:
  /// - [points]: lista di punti, ciascuno come [latitudine, longitudine].
  ///   La Roads API accetta fino a 100 punti per chiamata.
  ///
  /// RETURN:
  /// - Lista di [SnappedPoint] se la chiamata ha successo e ci sono strade
  /// - Lista vuota se non ci sono strade vicine a nessuno dei punti
  /// - null se la chiamata è fallita (errore di rete, API, ecc.)
  ///
  /// SIDE EFFECTS:
  /// - Effettua una chiamata HTTP GET alla Roads API
  /// - In caso di errore, ritenta una volta prima di restituire null
  ///
  /// FORMATO DEI PARAMETRI:
  /// La Roads API richiede i punti nel formato pipe-separated:
  /// points=lat1,lng1|lat2,lng2|lat3,lng3|...
  /// Ogni coppia lat,lng è separata da virgola, e le coppie sono separate
  /// dal carattere pipe (|).
  Future<List<SnappedPoint>?> findNearestRoads(
    List<List<double>> points,
  ) async {
    // Validazione: se non ci sono punti, non c'è nulla da cercare
    if (points.isEmpty) return [];

    // Costruisce la stringa dei punti nel formato richiesto dalla API:
    // "lat1,lng1|lat2,lng2|lat3,lng3|..."
    final String pointsParam = points.map((p) => '${p[0]},${p[1]}').join('|');

    // Tentativo con retry: prova fino a _maxRetries + 1 volte
    for (int attempt = 0; attempt <= _maxRetries; attempt++) {
      try {
        // Costruisce l'URL completo con i parametri query
        final uri = Uri.parse(
          _baseUrl,
        ).replace(queryParameters: {'points': pointsParam, 'key': apiKey});

        // Effettua la chiamata HTTP GET.
        // NOTA: questa chiamata è ASINCRONA — il codice si "ferma" qui
        // finché la risposta non arriva dal server. Questo è fondamentale:
        // non dobbiamo procedere all'analisi della risposta prima di averla
        // effettivamente ricevuta.
        final response = await http
            .get(uri)
            .timeout(const Duration(seconds: 10));

        // --- Gestione errori HTTP ---
        if (response.statusCode == 200) {
          // Successo: parsing del JSON
          return _parseResponse(response.body);
        } else if (response.statusCode >= 500) {
          // Errore server (5xx): il server di Google ha un problema temporaneo.
          // Vale la pena riprovare perché potrebbe risolversi da solo.
          print(
            'Roads API errore server ${response.statusCode}'
            ' (tentativo ${attempt + 1}/${_maxRetries + 1})',
          );
          if (attempt < _maxRetries) {
            // Aspetta 1 secondo prima di riprovare per dare tempo al server
            await Future.delayed(const Duration(seconds: 1));
            continue; // Riprova
          }
          return null; // Tutti i tentativi esauriti
        } else if (response.statusCode >= 400) {
          // Errore client (4xx): la richiesta è sbagliata (es. API key invalida,
          // troppi punti, formato errato). Non ha senso riprovare perché
          // la stessa richiesta darà lo stesso errore.
          print(
            'Roads API errore client ${response.statusCode}: ${response.body}',
          );
          return null;
        }
      } on Exception catch (e) {
        // Errore di rete (timeout, DNS, connessione rifiutata, ecc.)
        // Questi errori possono essere temporanei, quindi vale la pena riprovare.
        print(
          'Roads API eccezione: $e'
          ' (tentativo ${attempt + 1}/${_maxRetries + 1})',
        );
        if (attempt < _maxRetries) {
          await Future.delayed(const Duration(seconds: 1));
          continue;
        }
        return null;
      }
    }

    // Fallback silenzioso: se siamo arrivati qui, tutti i tentativi sono falliti.
    // Restituiamo null per segnalare che non abbiamo dati, ma NON lanciamo
    // un'eccezione: l'app deve continuare a funzionare anche senza Roads API.
    return null;
  }

  /// Effettua il parsing della risposta JSON della Roads API.
  ///
  /// STRUTTURA DELLA RISPOSTA:
  /// ```json
  /// {
  ///   "snappedPoints": [
  ///     {
  ///       "location": { "latitude": 45.123, "longitude": 9.456 },
  ///       "originalIndex": 0,
  ///       "placeId": "ChIJ..."
  ///     },
  ///     ...
  ///   ]
  /// }
  /// ```
  ///
  /// INTERPRETAZIONE:
  /// - Se `snappedPoints` è presente e non vuoto → la API ha trovato almeno
  ///   una strada vicina ad almeno uno dei punti inviati.
  /// - Se `snappedPoints` è assente o vuoto → nessuna strada trovata vicino
  ///   a nessuno dei punti. Questo è un CASO LEGITTIMO, non un errore.
  ///   Significa semplicemente che l'utente si trova in una zona senza
  ///   strade laterali (es. autostrada, campagna aperta, zona pedonale).
  ///
  /// RETURN: lista di SnappedPoint (può essere vuota ma non null)
  List<SnappedPoint> _parseResponse(String responseBody) {
    final data = json.decode(responseBody);

    // La chiave 'snappedPoints' può essere assente nel JSON se non ci sono
    // strade vicine. In Dart, accedere a una chiave inesistente di una Map
    // restituisce null, quindi usiamo l'operatore ?? per gestirlo.
    final List<dynamic>? snappedPointsJson = data['snappedPoints'];

    // Se snappedPoints è null o vuoto, restituiamo una lista vuota.
    // Questo NON è un errore: significa che non ci sono strade vicine
    // ai punti campionati, il che è un'informazione valida e utile.
    if (snappedPointsJson == null || snappedPointsJson.isEmpty) {
      return [];
    }

    // Converte ogni elemento JSON in un oggetto SnappedPoint
    return snappedPointsJson
        .map((json) => SnappedPoint.fromJson(json))
        .toList();
  }
}
