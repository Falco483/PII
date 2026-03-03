/// DirectionsService - Servizio per interagire con Google Directions API
///
/// Questo servizio gestisce le chiamate HTTP a Google Directions API e
/// parsifica la risposta JSON per estrarre il percorso e le indicazioni.
library;

import 'dart:convert';
import 'package:http/http.dart' as http;

/// Modello per un singolo step delle indicazioni
///
/// Ogni step rappresenta un segmento del percorso con una singola istruzione
/// di navigazione (es. "Svolta a destra su Via Roma").
///
/// CAMPI IMPORTANTI:
/// - [instruction]: testo leggibile dall'utente, estratto da `html_instructions`
///   del JSON della Directions API. Questo è il testo che viene mostrato
///   sull'overlay quando l'utente è fermo su un waypoint di svolta.
/// - [maneuver]: identificatore programmatico della manovra (es. "turn-left",
///   "roundabout-right"). NON usare per il testo visivo (è un codice, non
///   una frase). Usare invece per la logica dell'app (es. decidere quale
///   icona mostrare). Può essere null perché non tutti gli step hanno una
///   manovra (es. il primo step "Procedi verso nord" spesso non ha maneuver).
class DirectionStep {
  final String
  instruction; // Testo da html_instructions (es. "Svolta a destra")
  final String distance; // Distanza (es. "500 m")
  final String duration; // Durata (es. "2 min")
  final double startLat; // Latitudine punto di partenza step
  final double startLng; // Longitudine punto di partenza step
  final double endLat; // Latitudine punto di arrivo step
  final double endLng; // Longitudine punto di arrivo step

  /// Codice della manovra, stabile e indipendente dalla lingua.
  /// Valori possibili: "turn-left", "turn-right", "turn-slight-left",
  /// "turn-sharp-right", "uturn-left", "roundabout-right", "merge",
  /// "ramp-left", "fork-right", "straight", "keep-left", "keep-right", ecc.
  /// Può essere null se lo step non ha una manovra specifica.
  final String? maneuver;

  DirectionStep({
    required this.instruction,
    required this.distance,
    required this.duration,
    required this.startLat,
    required this.startLng,
    required this.endLat,
    required this.endLng,
    this.maneuver,
  });

  /// Crea un DirectionStep dal JSON della risposta API
  ///
  /// Struttura JSON di uno step dalla Directions API:
  /// {
  ///   "html_instructions": "Svolta a <b>destra</b> su <b>Via Roma</b>",
  ///   "maneuver": "turn-right",           ← può essere assente
  ///   "distance": { "text": "500 m", "value": 500 },
  ///   "duration": { "text": "2 min", "value": 120 },
  ///   "start_location": { "lat": 45.123, "lng": 9.456 },
  ///   "end_location": { "lat": 45.124, "lng": 9.457 }
  /// }
  factory DirectionStep.fromJson(Map<String, dynamic> json) {
    return DirectionStep(
      // Rimuove i tag HTML dalle istruzioni (la API restituisce HTML)
      // Il testo pulito è quello che verrà mostrato sull'overlay
      instruction: _removeHtmlTags(json['html_instructions'] ?? ''),
      distance: json['distance']['text'] ?? '',
      duration: json['duration']['text'] ?? '',
      startLat: json['start_location']['lat'].toDouble(),
      startLng: json['start_location']['lng'].toDouble(),
      endLat: json['end_location']['lat'].toDouble(),
      endLng: json['end_location']['lng'].toDouble(),
      // Il campo maneuver è opzionale nel JSON: se assente, resta null
      maneuver: json['maneuver'] as String?,
    );
  }

  /// Rimuove i tag HTML da una stringa
  static String _removeHtmlTags(String html) {
    // Regex per rimuovere tutti i tag HTML
    return html.replaceAll(RegExp(r'<[^>]*>'), '');
  }
}

/// Modello per il risultato completo delle indicazioni
class DirectionsResult {
  final List<DirectionStep> steps; // Lista degli step
  final String totalDistance; // Distanza totale
  final String totalDuration; // Durata totale
  final String encodedPolyline; // Polyline codificata per disegno mappa
  final double originLat; // Latitudine origine
  final double originLng; // Longitudine origine
  final double destLat; // Latitudine destinazione
  final double destLng; // Longitudine destinazione

  DirectionsResult({
    required this.steps,
    required this.totalDistance,
    required this.totalDuration,
    required this.encodedPolyline,
    required this.originLat,
    required this.originLng,
    required this.destLat,
    required this.destLng,
  });
}

/// Servizio principale per le Directions
class DirectionsService {
  // Placeholder per la API Key - va sostituita con la chiave reale
  static const String apiKey = 'YOUR_API_KEY_HERE';

  // URL base delle Google Directions API
  static const String baseUrl =
      'https://maps.googleapis.com/maps/api/directions/json';

  /// Calcola il percorso tra origine e destinazione
  ///
  /// [origin] - Indirizzo o coordinate di partenza (es. "Roma, Italia")
  /// [destination] - Indirizzo o coordinate di arrivo (es. "Milano, Italia")
  ///
  /// Restituisce un DirectionsResult con tutti i dati del percorso,
  /// oppure null se si verifica un errore.
  Future<DirectionsResult?> getDirections({
    required String origin,
    required String destination,
  }) async {
    try {
      // Costruisce l'URL con i parametri della richiesta
      final uri = Uri.parse(baseUrl).replace(
        queryParameters: {
          'origin': origin,
          'destination': destination,
          'key': apiKey,
          'language': 'it', // Risposte in italiano
          'mode': 'driving', // Modalità di viaggio: auto
        },
      );

      // Esegue la chiamata HTTP GET
      final response = await http.get(uri);

      // Verifica che la risposta sia OK (status 200)
      if (response.statusCode != 200) {
        print('Errore HTTP: ${response.statusCode}');
        return null;
      }

      // Parsifica il JSON della risposta
      final data = json.decode(response.body);

      // Verifica lo status della risposta API
      if (data['status'] != 'OK') {
        print('Errore API: ${data['status']}');
        return null;
      }

      // Estrae la prima route (percorso) dalla risposta
      final route = data['routes'][0];
      final leg = route['legs'][0]; // Prima "gamba" del viaggio

      // Estrae tutti gli step dalle indicazioni
      final List<DirectionStep> steps = [];
      for (var step in leg['steps']) {
        steps.add(DirectionStep.fromJson(step));
      }

      // Crea e restituisce il risultato completo
      return DirectionsResult(
        steps: steps,
        totalDistance: leg['distance']['text'],
        totalDuration: leg['duration']['text'],
        // La polyline è codificata nel formato di Google
        encodedPolyline: route['overview_polyline']['points'],
        originLat: leg['start_location']['lat'].toDouble(),
        originLng: leg['start_location']['lng'].toDouble(),
        destLat: leg['end_location']['lat'].toDouble(),
        destLng: leg['end_location']['lng'].toDouble(),
      );
    } catch (e) {
      // Gestisce eventuali errori
      print('Eccezione in getDirections: $e');
      return null;
    }
  }
}

/// Decodifica una polyline codificata nel formato di Google
///
/// La polyline è una stringa compatta che rappresenta una serie di coordinate.
/// Questo algoritmo la decodifica in una lista di punti lat/lng.
///
/// Riferimento: https://developers.google.com/maps/documentation/utilities/polylinealgorithm
List<List<double>> decodePolyline(String encoded) {
  List<List<double>> points = [];
  int index = 0;
  int lat = 0;
  int lng = 0;

  while (index < encoded.length) {
    // Decodifica latitudine
    int shift = 0;
    int result = 0;
    int byte;
    do {
      byte = encoded.codeUnitAt(index++) - 63;
      result |= (byte & 0x1F) << shift;
      shift += 5;
    } while (byte >= 0x20);
    int deltaLat = ((result & 1) != 0 ? ~(result >> 1) : (result >> 1));
    lat += deltaLat;

    // Decodifica longitudine
    shift = 0;
    result = 0;
    do {
      byte = encoded.codeUnitAt(index++) - 63;
      result |= (byte & 0x1F) << shift;
      shift += 5;
    } while (byte >= 0x20);
    int deltaLng = ((result & 1) != 0 ? ~(result >> 1) : (result >> 1));
    lng += deltaLng;

    // Aggiunge il punto alla lista (dividendo per 1E5 per ottenere gradi)
    points.add([lat / 1E5, lng / 1E5]);
  }

  return points;
}
