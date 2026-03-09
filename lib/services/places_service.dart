/// places_service.dart — Servizio per Google Places API (Autocomplete + Details)
///
/// Questo servizio gestisce due API di Google Places:
/// 1. Places Autocomplete API — restituisce suggerimenti di completamento
///    automatico mentre l'utente digita nella barra di ricerca
/// 2. Places Details API — dato un place_id, restituisce le coordinate
///    (latitudine/longitudine) e altri dettagli del luogo selezionato
///
/// SESSION TOKEN:
/// Un session token è un identificatore univoco (UUID v4) che raggruppa
/// una serie di richieste Autocomplete + la successiva richiesta Details
/// in un'unica "sessione di fatturazione" di Google.
///
/// SENZA il session token, Google fattura:
///   - Ogni singola richiesta Autocomplete come chiamata individuale
///   - La richiesta Details come chiamata separata
///   - Esempio: 10 battiture + 1 Details = 11 chiamate fatturate
///
/// CON il session token, Google fattura:
///   - Tutte le Autocomplete + la Details come UNA sola sessione
///   - Esempio: 10 battiture + 1 Details = 1 sessione fatturata
///
/// CICLO DI VITA DEL TOKEN:
/// 1. L'utente inizia a digitare → genera un nuovo token
/// 2. Tutte le chiamate Autocomplete usano lo STESSO token
/// 3. L'utente seleziona un suggerimento → Places Details USA LO STESSO token
/// 4. Dopo la selezione → il token viene INVALIDATO e ne viene generato
///    uno nuovo, pronto per la prossima sessione di ricerca
///
/// SEPARAZIONE DELLE RESPONSABILITÀ:
/// Questo file contiene SOLO le chiamate API. Non contiene:
/// - Logica di debounce (→ search_input.dart)
/// - Logica di filtro minimo caratteri (→ search_input.dart)
/// - Rendering dei suggerimenti (→ search_input.dart)
/// - Calcolo percorsi (→ directions_service.dart)
library;

import 'dart:convert';
import 'dart:math';
import 'package:http/http.dart' as http;

// =============================================================================
// MODELLI DATI
// =============================================================================

/// PlaceSuggestion — Rappresenta un singolo suggerimento di autocomplete.
///
/// Ogni suggerimento restituito dalla Places Autocomplete API contiene:
/// - description: testo leggibile del luogo (es. "Via Roma 1, Milano, Italia")
/// - placeId: identificatore univoco del luogo nel database di Google Places
///
/// Il placeId è cruciale: servirà per chiamare la Places Details API
/// e ottenere le coordinate esatte (lat/lng) del luogo selezionato.
class PlaceSuggestion {
  /// Descrizione completa del luogo (indirizzo leggibile).
  /// Viene mostrata all'utente nella lista dei suggerimenti.
  /// Esempio: "Via Roma 1, Milano, MI, Italia"
  final String description;

  /// Identificatore univoco di Google per questo luogo.
  /// Formato: stringa alfanumerica (es. "ChIJrTLr-GyuEmsRBfy61i59si0")
  /// Usato per chiamare Places Details API e ottenere le coordinate.
  final String placeId;

  /// Costruttore — entrambi i campi sono obbligatori.
  PlaceSuggestion({required this.description, required this.placeId});

  /// Factory constructor che crea un PlaceSuggestion da un oggetto JSON.
  ///
  /// La risposta dell'Autocomplete API ha questa struttura:
  /// {
  ///   "predictions": [
  ///     {
  ///       "description": "Via Roma 1, Milano, Italia",
  ///       "place_id": "ChIJrTLr-GyuEmsRBfy61i59si0",
  ///       ...
  ///     }
  ///   ]
  /// }
  ///
  /// Questo factory prende un singolo elemento dell'array "predictions".
  factory PlaceSuggestion.fromJson(Map<String, dynamic> json) {
    return PlaceSuggestion(
      // 'description' è il testo leggibile del suggerimento
      description: json['description'] ?? '',
      // 'place_id' è l'identificatore univoco del luogo
      placeId: json['place_id'] ?? '',
    );
  }
}

/// PlaceDetails — Contiene le coordinate e i dettagli di un luogo specifico.
///
/// Questo oggetto viene restituito dalla Places Details API dopo che
/// l'utente seleziona un suggerimento dall'autocomplete.
/// Le coordinate (lat, lng) sono il dato più importante: servono per
/// chiamare la Directions API e calcolare il percorso.
class PlaceDetails {
  /// Latitudine del luogo (gradi decimali, es. 45.4642)
  final double lat;

  /// Longitudine del luogo (gradi decimali, es. 9.1900)
  final double lng;

  /// Nome del luogo (es. "Duomo di Milano"), può essere vuoto.
  final String name;

  /// Indirizzo formattato (es. "Piazza del Duomo, 20122 Milano MI")
  final String formattedAddress;

  /// Costruttore — lat e lng sono obbligatori, name e address opzionali.
  PlaceDetails({
    required this.lat,
    required this.lng,
    this.name = '',
    this.formattedAddress = '',
  });
}

// =============================================================================
// UTILITÀ — GENERATORE SESSION TOKEN
// =============================================================================

/// Genera un session token in formato UUID v4.
///
/// UUID v4 è un identificatore universalmente unico generato casualmente.
/// Formato: "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
/// dove x = cifra esadecimale casuale, 4 = versione, y = 8/9/a/b
///
/// PERCHÉ UUID v4:
/// Google richiede un token univoco per ogni sessione di ricerca.
/// UUID v4 garantisce unicità senza bisogno di un server o database:
/// la probabilità di una collisione è astronomicamente bassa
/// (~2^122 combinazioni possibili).
///
/// RETURN: stringa UUID v4 (es. "a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d")
String generateSessionToken() {
  // Crea un generatore di numeri casuali sicuro
  final random = Random.secure();

  // Genera 16 byte casuali (128 bit), la base dell'UUID v4
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));

  // Imposta il bit di versione (versione 4 = 0100xxxx nel 7° byte)
  // Il 7° byte (indice 6) deve avere i 4 bit più significativi = 0100
  bytes[6] = (bytes[6] & 0x0F) | 0x40;

  // Imposta il bit di variante (variante 1 = 10xxxxxx nel 9° byte)
  // Il 9° byte (indice 8) deve avere i 2 bit più significativi = 10
  bytes[8] = (bytes[8] & 0x3F) | 0x80;

  // Converte i byte in stringa esadecimale con i trattini nel formato UUID
  // Formato: 8-4-4-4-12 caratteri esadecimali
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  // Inserisce i trattini nelle posizioni corrette del formato UUID
  return '${hex.substring(0, 8)}-' // primi 8 caratteri
      '${hex.substring(8, 12)}-' // caratteri 9-12
      '${hex.substring(12, 16)}-' // caratteri 13-16 (contiene il "4")
      '${hex.substring(16, 20)}-' // caratteri 17-20
      '${hex.substring(20, 32)}'; // ultimi 12 caratteri
}

// =============================================================================
// SERVIZIO PRINCIPALE — PLACES SERVICE
// =============================================================================

/// PlacesService — Servizio per le API Google Places (Autocomplete + Details).
///
/// UTILIZZO:
/// ```dart
/// final service = PlacesService();
/// String token = generateSessionToken(); // genera token una volta
///
/// // L'utente digita "Duom" → autocomplete con lo STESSO token
/// final suggestions = await service.getAutocompleteSuggestions('Duom', token);
///
/// // L'utente seleziona "Duomo di Milano" → details con lo STESSO token
/// final details = await service.getPlaceDetails(suggestions[0].placeId, token);
///
/// // Coordinate pronte: details.lat, details.lng
/// // Genera un NUOVO token per la prossima ricerca
/// token = generateSessionToken();
/// ```
class PlacesService {
  // Stessa API Key usata in DirectionsService e RoadsService.
  // Deve essere sostituita con una chiave reale valida.
  static const String apiKey = 'YOUR_API_KEY_HERE';

  // URL base per la Places Autocomplete API
  static const String _autocompleteUrl =
      'https://maps.googleapis.com/maps/api/place/autocomplete/json';

  // URL base per la Places Details API
  static const String _detailsUrl =
      'https://maps.googleapis.com/maps/api/place/details/json';

  /// Ottiene i suggerimenti di autocomplete dalla Places API.
  ///
  /// Questa funzione viene chiamata ogni volta che l'utente digita
  /// (dopo il debounce di 300ms e solo se input >= 3 caratteri).
  ///
  /// PARAMETRI:
  /// - [input]: testo digitato dall'utente (minimo 3 caratteri)
  /// - [sessionToken]: token della sessione corrente di ricerca.
  ///   DEVE essere lo stesso per tutta la sessione (tutte le battiture
  ///   + la successiva chiamata Details)
  ///
  /// RETURN:
  /// - Lista di PlaceSuggestion con description e placeId
  /// - Lista vuota se non ci sono risultati o se si verifica un errore
  ///
  /// NOTA: la API restituisce al massimo 5 suggerimenti per default.
  Future<List<PlaceSuggestion>> getAutocompleteSuggestions(
    String input,
    String sessionToken,
  ) async {
    try {
      // Costruisce l'URL della richiesta con i parametri necessari
      final uri = Uri.parse(_autocompleteUrl).replace(
        queryParameters: {
          // Il testo digitato dall'utente (la query di ricerca)
          'input': input,
          // La API Key per l'autenticazione
          'key': apiKey,
          // Lingua dei risultati: italiano
          'language': 'it',
          // Session token per raggruppare le richieste nella stessa sessione
          // di fatturazione (autocomplete + details = 1 sessione)
          'sessiontoken': sessionToken,
        },
      );

      // Esegue la chiamata HTTP GET alla Places Autocomplete API
      final response = await http.get(uri);

      // Verifica che la risposta HTTP sia OK (status code 200)
      if (response.statusCode != 200) {
        // Log dell'errore per debugging
        print('Errore HTTP Autocomplete: ${response.statusCode}');
        // Restituisce lista vuota: l'utente non vedrà suggerimenti
        return [];
      }

      // Parsifica il corpo della risposta da stringa JSON a Map Dart
      final data = json.decode(response.body);

      // Verifica lo status della risposta dell'API Google.
      // Possibili valori: 'OK', 'ZERO_RESULTS', 'INVALID_REQUEST',
      // 'OVER_QUERY_LIMIT', 'REQUEST_DENIED', 'UNKNOWN_ERROR'
      if (data['status'] != 'OK') {
        // 'ZERO_RESULTS' non è un errore: semplicemente non ci sono risultati
        // per la query inserita. Restituiamo lista vuota senza log di errore.
        if (data['status'] == 'ZERO_RESULTS') {
          return [];
        }
        // Per tutti gli altri status diversi da 'OK', logghiamo l'errore
        print('Errore API Autocomplete: ${data["status"]}');
        return [];
      }

      // Estrae l'array 'predictions' dalla risposta JSON.
      // Ogni elemento contiene un suggerimento con description e place_id.
      final predictions = data['predictions'] as List<dynamic>;

      // Converte ogni oggetto JSON in un PlaceSuggestion Dart
      // usando il factory constructor PlaceSuggestion.fromJson()
      return predictions
          .map((prediction) => PlaceSuggestion.fromJson(prediction))
          .toList();
    } catch (e) {
      // Gestisce qualsiasi eccezione non prevista (parsing, rete, ecc.)
      print('Eccezione in getAutocompleteSuggestions: $e');
      // Restituisce lista vuota come fallback silenzioso
      return [];
    }
  }

  /// Ottiene i dettagli di un luogo dalla Places Details API.
  ///
  /// Questa funzione viene chiamata DOPO che l'utente seleziona un
  /// suggerimento dall'autocomplete. Usa il place_id del suggerimento
  /// per ottenere le coordinate esatte (lat/lng) del luogo.
  ///
  /// PARAMETRI:
  /// - [placeId]: identificatore univoco del luogo (da PlaceSuggestion.placeId)
  /// - [sessionToken]: lo STESSO token usato nelle chiamate Autocomplete
  ///   precedenti. Questo è FONDAMENTALE per la fatturazione: Google
  ///   raggruppa autocomplete + details come una sola sessione solo se
  ///   il token è lo stesso.
  ///
  /// RETURN:
  /// - PlaceDetails con lat, lng, name e address
  /// - null se si verifica un errore
  ///
  /// NOTA: usiamo 'fields=geometry,name,formatted_address' per limitare
  /// la risposta ai soli dati necessari. Richiedere meno campi riduce
  /// il costo della chiamata (Google fattura per campo richiesto).
  Future<PlaceDetails?> getPlaceDetails(
    String placeId,
    String sessionToken,
  ) async {
    try {
      // Costruisce l'URL della richiesta con i parametri
      final uri = Uri.parse(_detailsUrl).replace(
        queryParameters: {
          // L'identificatore univoco del luogo di cui vogliamo i dettagli
          'place_id': placeId,
          // La API Key per l'autenticazione
          'key': apiKey,
          // Lingua dei risultati: italiano
          'language': 'it',
          // Campi richiesti — MOLTO IMPORTANTE per i costi:
          // 'geometry' → coordinate lat/lng (campo Basic, costo basso)
          // 'name' → nome del luogo (campo Basic)
          // 'formatted_address' → indirizzo formattato (campo Basic)
          // Richiedere SOLO i campi necessari riduce il costo della chiamata.
          // Campi "Contact" e "Atmosphere" costerebbero di più.
          'fields': 'geometry,name,formatted_address',
          // Stesso session token usato nell'autocomplete!
          // Questo è il momento in cui Google "chiude" la sessione
          // e fattura tutte le chiamate come una sola unità.
          'sessiontoken': sessionToken,
        },
      );

      // Esegue la chiamata HTTP GET alla Places Details API
      final response = await http.get(uri);

      // Verifica che la risposta HTTP sia OK
      if (response.statusCode != 200) {
        print('Errore HTTP Details: ${response.statusCode}');
        return null;
      }

      // Parsifica la risposta JSON
      final data = json.decode(response.body);

      // Verifica lo status della risposta API
      if (data['status'] != 'OK') {
        print('Errore API Details: ${data["status"]}');
        return null;
      }

      // Estrae l'oggetto 'result' dalla risposta.
      // La struttura della risposta è:
      // {
      //   "result": {
      //     "geometry": {
      //       "location": { "lat": 45.4642, "lng": 9.1900 }
      //     },
      //     "name": "Duomo di Milano",
      //     "formatted_address": "Piazza del Duomo, 20122 Milano MI"
      //   },
      //   "status": "OK"
      // }
      final result = data['result'];

      // Estrae le coordinate dall'oggetto geometry.location
      final location = result['geometry']['location'];

      // Costruisce e restituisce l'oggetto PlaceDetails
      return PlaceDetails(
        // Latitudine del luogo (valore double)
        lat: location['lat'].toDouble(),
        // Longitudine del luogo (valore double)
        lng: location['lng'].toDouble(),
        // Nome del luogo (può essere assente, usiamo '' come default)
        name: result['name'] ?? '',
        // Indirizzo formattato (può essere assente)
        formattedAddress: result['formatted_address'] ?? '',
      );
    } catch (e) {
      // Gestisce qualsiasi eccezione non prevista
      print('Eccezione in getPlaceDetails: $e');
      return null;
    }
  }
}
