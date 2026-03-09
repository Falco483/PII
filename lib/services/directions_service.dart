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

// =============================================================================
// MODELLI PER PERCORSI ALTERNATIVI (TASK 1)
// =============================================================================

/// RouteData — Rappresenta un singolo percorso con tutti i suoi dati.
///
/// Ogni percorso restituito dalla Directions API viene convertito in un
/// oggetto RouteData. La differenza rispetto a DirectionsResult è che
/// RouteData include anche la polyline DECODIFICATA (lista di coordinate)
/// e la durata in SECONDI (per confronto numerico tra percorsi).
///
/// PERCHÉ SERVE QUESTO MODELLO SEPARATO:
/// DirectionsResult era pensato per un singolo percorso. Ora che gestiamo
/// percorsi alternativi, abbiamo bisogno di:
/// 1. Polyline decodificata → per il confronto posizione-vs-percorso (Task 2)
/// 2. Durata in secondi → per confrontare numericamente i percorsi
/// 3. Tutti i dati in un unico oggetto → per scambiare facilmente il percorso attivo
class RouteData {
  /// Lista di punti [latitudine, longitudine] della polyline decodificata.
  /// Usata nel Task 2 per calcolare la distanza tra l'utente e il percorso.
  final List<List<double>> decodedPolyline;

  /// Durata stimata del percorso in SECONDI (valore numerico).
  /// Estratta da `legs[0].duration.value` nel JSON della Directions API.
  /// Usata per confrontare i percorsi e scegliere il più veloce.
  final int durationSeconds;

  /// Durata totale leggibile (es. "1 ora 23 min").
  /// Estratta da `legs[0].duration.text` nel JSON.
  final String totalDuration;

  /// Distanza totale leggibile (es. "120 km").
  /// Estratta da `legs[0].distance.text` nel JSON.
  final String totalDistance;

  /// Polyline codificata originale (stringa compressa di Google).
  /// Serve per passarla al MapWidget che la decodifica internamente
  /// per disegnarla sulla mappa.
  final String encodedPolyline;

  /// Lista degli step di navigazione (indicazioni passo-passo).
  /// Ogni step contiene istruzione, distanza, durata, coordinate, manovra.
  final List<DirectionStep> steps;

  /// Costruttore — tutti i campi sono obbligatori perché un percorso
  /// senza uno qualsiasi di questi dati è inutilizzabile.
  RouteData({
    required this.decodedPolyline,
    required this.durationSeconds,
    required this.totalDuration,
    required this.totalDistance,
    required this.encodedPolyline,
    required this.steps,
  });
}

/// AllRoutesResult — Wrapper che contiene il percorso migliore e tutti
/// i percorsi alternativi restituiti dalla Directions API.
///
/// STRUTTURA:
/// - bestRoute: il percorso con la durata minore (selezionato automaticamente)
/// - allRoutes: TUTTI i percorsi (compreso il bestRoute), salvati per poter
///   "switchare" a un alternativo se l'utente devia (Task 2b)
/// - originLat/Lng, destLat/Lng: coordinate di partenza e arrivo
///
/// PERCHÉ SALVARE TUTTI I PERCORSI:
/// Quando l'utente devia dal percorso attivo, prima di fare una nuova
/// chiamata API (costosa e lenta), controlliamo se è finito su uno dei
/// percorsi alternativi già in memoria. Questo risparmia tempo e quota API.
class AllRoutesResult {
  /// Il percorso con la durata più breve tra tutti quelli restituiti.
  final RouteData bestRoute;

  /// Tutti i percorsi restituiti dall'API (incluso il bestRoute).
  /// Ordinati per durata crescente (il primo è il più veloce).
  final List<RouteData> allRoutes;

  /// Latitudine del punto di partenza (uguale per tutti i percorsi).
  final double originLat;

  /// Longitudine del punto di partenza.
  final double originLng;

  /// Latitudine della destinazione (uguale per tutti i percorsi).
  final double destLat;

  /// Longitudine della destinazione.
  final double destLng;

  /// Costruttore — richiede tutti i campi.
  AllRoutesResult({
    required this.bestRoute,
    required this.allRoutes,
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

  /// Calcola il percorso con PERCORSI ALTERNATIVI (TASK 1).
  ///
  /// Questa è la versione evoluta di getDirections() che:
  /// 1. Richiede esplicitamente percorsi alternativi (alternatives=true)
  /// 2. Parsifica TUTTI i percorsi dalla risposta (non solo il primo)
  /// 3. Confronta la durata di ciascun percorso
  /// 4. Seleziona come "best" quello con durata minore
  /// 5. Salva tutti i percorsi con le polyline decodificate
  ///
  /// PARAMETRI:
  /// - [origin]: indirizzo o coordinate di partenza (es. "Roma, Italia"
  ///   oppure "41.9028,12.4964" per coordinate)
  /// - [destination]: indirizzo o coordinate di arrivo
  ///
  /// RETURN:
  /// - AllRoutesResult con il percorso migliore + tutti gli alternativi
  /// - null se si verifica un errore (rete, API, nessun percorso trovato)
  ///
  /// NOTA: la Directions API restituisce tipicamente 1-3 percorsi
  /// alternativi, ma il numero non è garantito. A volte può restituire
  /// solo il percorso principale se non esistono alternative ragionevoli.
  Future<AllRoutesResult?> getDirectionsWithAlternatives({
    required String origin,
    required String destination,
  }) async {
    try {
      // Costruisce l'URL con i parametri della richiesta.
      // Il parametro 'alternatives': 'true' dice alla API di restituire
      // più percorsi possibili oltre a quello principale.
      final uri = Uri.parse(baseUrl).replace(
        queryParameters: {
          'origin': origin,
          'destination': destination,
          'key': apiKey,
          'language': 'it', // Risposte in italiano
          'mode': 'driving', // Modalità di viaggio: auto
          'alternatives': 'true', // TASK 1: richiedi percorsi alternativi
        },
      );

      // Esegue la chiamata HTTP GET alla Directions API
      final response = await http.get(uri);

      // Verifica che la risposta HTTP sia OK (status code 200)
      if (response.statusCode != 200) {
        // Log dell'errore HTTP per debugging
        print('Errore HTTP: ${response.statusCode}');
        return null;
      }

      // Parsifica il corpo della risposta da stringa JSON a Map Dart
      final data = json.decode(response.body);

      // Verifica lo status della risposta dell'API Google.
      // Possibili valori: 'OK', 'NOT_FOUND', 'ZERO_RESULTS',
      // 'MAX_WAYPOINTS_EXCEEDED', 'INVALID_REQUEST', ecc.
      if (data['status'] != 'OK') {
        // Log dell'errore API per debugging
        print('Errore API: ${data["status"]}');
        return null;
      }

      // Estrae l'array 'routes' dalla risposta JSON.
      // Quando alternatives=true, questo array può contenere più elementi.
      // Esempio: routes[0] = percorso principale, routes[1] = primo alternativo, ecc.
      final List<dynamic> routes = data['routes'];

      // Se l'API non ha restituito nessun percorso, usciamo.
      // Questo è raro (di solito c'è almeno un percorso se status='OK'),
      // ma è buona pratica verificare.
      if (routes.isEmpty) {
        print('Nessun percorso trovato nella risposta API');
        return null;
      }

      // Log del numero di percorsi ricevuti (utile per debugging)
      print('Percorsi ricevuti dalla API: ${routes.length}');

      // Lista che conterrà tutti i RouteData parsificati
      final List<RouteData> allRouteData = [];

      // --- ITERAZIONE SU TUTTI I PERCORSI ---
      // A differenza del vecchio getDirections() che prendeva solo routes[0],
      // qui iteriamo su OGNI percorso restituito dall'API.
      for (final route in routes) {
        // Estrae la prima (e solitamente unica) "leg" del percorso.
        // Una leg corrisponde a un segmento senza waypoint intermedi.
        // Siccome non usiamo waypoint, c'è sempre una sola leg.
        final leg = route['legs'][0];

        // Estrae tutti gli step (istruzioni) di questa leg
        final List<DirectionStep> steps = [];
        for (var step in leg['steps']) {
          // Converte ogni step JSON in un oggetto DirectionStep
          steps.add(DirectionStep.fromJson(step));
        }

        // Estrae la polyline codificata dal campo overview_polyline.
        // La overview_polyline è una versione semplificata della polyline
        // che copre l'intero percorso (non i singoli step).
        final String encodedPoly = route['overview_polyline']['points'];

        // Decodifica la polyline in una lista di punti [lat, lng].
        // Questo serve per il confronto posizione-vs-percorso nel Task 2:
        // confronteremo la posizione GPS dell'utente con ciascun punto
        // della polyline decodificata per verificare se è sul percorso.
        final List<List<double>> decodedPoly = decodePolyline(encodedPoly);

        // Estrae la durata in SECONDI dal campo 'value' della duration.
        // La API restituisce sia 'text' ("1 ora 23 min") sia 'value' (4980 secondi).
        // Usiamo 'value' per il confronto numerico tra percorsi.
        final int durationSec = leg['duration']['value'] as int;

        // Crea l'oggetto RouteData con tutti i dati di questo percorso
        final routeData = RouteData(
          decodedPolyline: decodedPoly,
          durationSeconds: durationSec,
          totalDuration: leg['duration']['text'] ?? '',
          totalDistance: leg['distance']['text'] ?? '',
          encodedPolyline: encodedPoly,
          steps: steps,
        );

        // Aggiunge il percorso alla lista di tutti i percorsi
        allRouteData.add(routeData);
      }

      // --- SELEZIONE DEL PERCORSO MIGLIORE (Task 1) ---
      // Ordina tutti i percorsi per durata crescente (il più veloce prima).
      // Il metodo sort() modifica la lista in-place.
      allRouteData.sort(
        (a, b) => a.durationSeconds.compareTo(b.durationSeconds),
      );

      // Il primo elemento dopo l'ordinamento è il percorso con durata minore.
      // Questo diventerà il percorso "attivo" mostrato all'utente.
      final RouteData bestRoute = allRouteData.first;

      // Log per debugging: mostra la durata di ogni percorso
      for (int i = 0; i < allRouteData.length; i++) {
        print(
          'Percorso ${i + 1}: durata ${allRouteData[i].durationSeconds}s '
          '(${allRouteData[i].totalDuration})',
        );
      }
      // Indica quale percorso è stato selezionato come migliore
      print(
        'Percorso migliore: ${bestRoute.totalDuration} '
        '(${bestRoute.durationSeconds}s)',
      );

      // Estrae le coordinate di partenza e arrivo dalla prima leg.
      // Sono uguali per tutti i percorsi (stessa origine e destinazione).
      final firstLeg = routes[0]['legs'][0];

      // Costruisce e restituisce il risultato finale con tutti i percorsi
      return AllRoutesResult(
        bestRoute: bestRoute,
        allRoutes: allRouteData,
        originLat: firstLeg['start_location']['lat'].toDouble(),
        originLng: firstLeg['start_location']['lng'].toDouble(),
        destLat: firstLeg['end_location']['lat'].toDouble(),
        destLng: firstLeg['end_location']['lng'].toDouble(),
      );
    } catch (e) {
      // Gestisce qualsiasi eccezione non prevista (parsing JSON, rete, ecc.)
      print('Eccezione in getDirectionsWithAlternatives: $e');
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
