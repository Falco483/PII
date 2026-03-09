/// geo_utils.dart — Utilità Geodetiche e Costanti di Configurazione
///
/// Questo file contiene:
/// 1. Tutte le costanti configurabili usate dall'app (soglie, distanze, intervalli)
/// 2. Funzioni pure per calcoli geodetici su coordinate WGS84
///
/// Le funzioni sono stateless e non hanno side effects: ricevono coordinate
/// e restituiscono risultati. Possono essere testate in isolamento.
///
/// NOTA PER JUNIOR DEVELOPER:
/// Le coordinate GPS usano il sistema WGS84 (World Geodetic System 1984).
/// La Terra non è una sfera perfetta, ma per distanze brevi (< 1 km) le formule
/// sferiche sono sufficientemente accurate. Per distanze maggiori si dovrebbe
/// usare il modello ellissoidale (Vincenty), ma qui lavoriamo con offset di
/// pochi metri, quindi la sfera è più che adeguata.
library;

import 'dart:math';

// =============================================================================
// COSTANTI CONFIGURABILI
// =============================================================================
// Ogni valore "magico" è definito qui con un nome descrittivo.
// Per modificare il comportamento dell'app, basta cambiare questi valori.
// =============================================================================

/// Soglia di velocità (km/h) sotto la quale il bearing GPS è considerato
/// inaffidabile. Quando il dispositivo è fermo o quasi fermo, il sensore GPS
/// restituisce valori di bearing casuali perché non c'è un vettore di spostamento
/// significativo da cui derivare la direzione.
///
/// Valore consigliato: 3-5 km/h. Default: 4 km/h.
/// - Sotto 3 km/h: troppi falsi negativi (si scarta bearing valido a passo d'uomo)
/// - Sopra 5 km/h: troppi falsi positivi (si accetta bearing rumoroso)
const double kSpeedThresholdKmH = 4.0;

/// Intervallo in secondi tra un campionamento e l'altro del bearing.
///
/// PERCHÉ UN TIMER PERIODICO INVECE DI AGGIORNARE AD OGNI FRAME GPS:
/// Il GPS può emettere aggiornamenti a frequenze molto variabili (1-10 Hz).
/// Aggiornare direction ad ogni frame causerebbe:
/// 1. Oscillazioni rapide del bearing (il GPS ha rumore intrinseco)
/// 2. Consumo inutile di CPU per ricalcolare i punti laterali
/// 3. Difficoltà nel debugging (troppi aggiornamenti da tracciare)
///
/// Un campionamento ogni 5 secondi è sufficiente perché:
/// - A 4 km/h (soglia minima) si percorrono ~5.5 m in 5 secondi
/// - A 50 km/h si percorrono ~69 m in 5 secondi
/// In entrambi i casi il bearing ha avuto tempo di stabilizzarsi.
const int kBearingUpdateIntervalSec = 5;

/// Soglia di velocità (km/h) sotto la quale si considera l'utente "fermo".
/// Usata per attivare il timer di 10 secondi (Step 2.1).
///
/// Si usa 1 km/h invece di 0 esatto perché il GPS raramente restituisce
/// velocità perfettamente zero anche quando il dispositivo è fermo —
/// c'è sempre un po' di rumore/drift nel segnale.
const double kZeroSpeedThresholdKmH = 1.0;

/// Durata del countdown (millisecondi) quando la velocità scende a zero.
///
/// PERCHÉ 10 SECONDI:
/// - Un semaforo rosso tipico dura 30-90 secondi, ma l'utente potrebbe
///   fermarsi brevemente anche per 2-5 secondi (ingorgo, precedenza).
/// - 10 secondi è un buon compromesso: abbastanza lungo da filtrare
///   le fermate momentanee, abbastanza corto da reagire rapidamente
///   quando l'utente è realmente fermo e confuso a un incrocio.
const int kZeroSpeedDelayMs = 10000;

/// Raggio in metri entro il quale la posizione dell'utente viene considerata
/// "coincidente" con un waypoint di svolta del percorso (Step 2.3).
///
/// PERCHÉ 5 METRI:
/// - La precisione tipica del GPS su smartphone è 3-10 m in condizioni normali
/// - 5 m è abbastanza ampio da catturare l'utente che è "sull'incrocio"
///   ma abbastanza stretto da non confondere due incroci vicini
/// - Questo valore può essere aumentato (es. 10 m) se si opera in zone
///   con GPS degradato (es. canyon urbani, gallerie)
const double kTurnWaypointRadiusMeters = 5.0;

/// Distanza in metri dal punto corrente per calcolare i punti laterali
/// principali (dx e sx) — Step 2.4.
///
/// 10 metri è circa la larghezza di una carreggiata a due corsie (3.5 m per
/// corsia × 2 + marciapiedi). I punti a 10 m a destra e sinistra hanno
/// un'alta probabilità di cadere sulla carreggiata di una strada laterale
/// se questa esiste.
const double kLateralDistanceMeters = 10.0;

/// Offset satellite a 2 metri dal punto principale — Step 2.4.
/// Serve per espandere la copertura e compensare l'imprecisione del GPS.
const double kSatelliteOffset2m = 2.0;

/// Offset satellite a 4 metri dal punto principale — Step 2.4.
/// Massima espansione laterale: il punto satellite può arrivare fino a
/// 10 + 4 = 14 m dal centro dell'utente.
const double kSatelliteOffset4m = 4.0;

/// Durata in secondi dell'overlay prima dell'auto-dismiss.
const int kOverlayAutoDismissSeconds = 8;

/// Raggio medio della Terra in metri (WGS84 approssimato a sfera).
/// Usato nelle formule geodetiche.
const double kEarthRadiusMeters = 6371000.0;

/// Soglia di deviazione dal percorso in metri (TASK 2).
///
/// Se la distanza minima tra la posizione dell'utente e la polyline del
/// percorso attivo è MAGGIORE di questa soglia, l'utente è considerato
/// "fuori percorso" (ha deviato).
///
/// PERCHÉ 40 METRI:
/// - La precisione tipica del GPS su smartphone è 3-10 m in condizioni normali
/// - In ambienti urbani (edifici alti, gallerie) può peggiorare a 15-30 m
/// - Una corsia autostradale è larga ~3.5 m, una strada urbana ~6-7 m
/// - 40 m è abbastanza ampio da coprire l'imprecisione GPS + la larghezza
///   della strada, evitando falsi ricalcoli quando l'utente è sul percorso
///   ma il GPS è leggermente impreciso
/// - Allo stesso tempo, 40 m è abbastanza stretto da rilevare una vera
///   deviazione (es. svolta su una strada laterale)
const double kRouteDeviationThresholdMeters = 40.0;

/// Intervallo in secondi tra un controllo e l'altro della posizione
/// rispetto al percorso attivo (TASK 2).
///
/// PERCHÉ 2 SECONDI:
/// - A 50 km/h (~14 m/s) l'utente percorre ~28 m in 2 secondi
/// - A 100 km/h (~28 m/s) percorre ~56 m in 2 secondi
/// - 2 secondi è un buon compromesso tra reattività (rilevare rapidamente
///   una deviazione) e consumo di risorse (non eseguire calcoli inutili)
/// - Se controllassimo ogni 100 ms sarebbe troppo frequente (spreco CPU)
/// - Se controllassimo ogni 10 s potremmo accorgerci della deviazione
///   troppo tardi (l'utente ha già percorso 280 m fuori percorso)
const int kRouteCheckIntervalSec = 2;

// =============================================================================
// FUNZIONI GEODETICHE
// =============================================================================

/// Calcola la distanza in metri tra due punti sulla superficie terrestre
/// usando la formula di Haversine.
///
/// LA FORMULA DI HAVERSINE:
/// È la formula standard per calcolare la distanza del "cerchio massimo"
/// (great-circle distance) tra due punti su una sfera.
///
/// Funziona così:
/// 1. Converte le coordinate da gradi a radianti
/// 2. Calcola le differenze di latitudine e longitudine
/// 3. Applica la formula: a = sin²(Δlat/2) + cos(lat1) × cos(lat2) × sin²(Δlng/2)
/// 4. c = 2 × atan2(√a, √(1-a))
/// 5. distanza = R × c (dove R è il raggio della Terra)
///
/// EDGE CASES GESTITI:
/// - Stesso punto → restituisce 0.0 (Δlat = Δlng = 0, sin(0) = 0)
/// - Punti antipodali → restituisce ~20015 km (metà della circonferenza)
/// - Coordinate negative (emisfero sud/ovest) → funziona correttamente
///   perché le funzioni trigonometriche gestiscono angoli negativi
///
/// PARAMETRI:
/// - [lat1], [lng1]: latitudine e longitudine del primo punto (gradi decimali)
/// - [lat2], [lng2]: latitudine e longitudine del secondo punto (gradi decimali)
///
/// RETURN: distanza in metri (double, sempre >= 0)
double haversineDistance(double lat1, double lng1, double lat2, double lng2) {
  // Converti gradi → radianti (la libreria dart:math lavora in radianti)
  final double dLat = _degreesToRadians(lat2 - lat1);
  final double dLng = _degreesToRadians(lng2 - lng1);

  final double lat1Rad = _degreesToRadians(lat1);
  final double lat2Rad = _degreesToRadians(lat2);

  // Formula di Haversine:
  // "a" rappresenta il quadrato della metà della corda tra i due punti
  final double a =
      sin(dLat / 2) * sin(dLat / 2) +
      cos(lat1Rad) * cos(lat2Rad) * sin(dLng / 2) * sin(dLng / 2);

  // "c" è la distanza angolare in radianti
  final double c = 2 * atan2(sqrt(a), sqrt(1 - a));

  // Moltiplica per il raggio della Terra per ottenere la distanza in metri
  return kEarthRadiusMeters * c;
}

/// distanceBetween — Wrapper nominale per haversineDistance (TASK 2).
///
/// Questa funzione è un alias di haversineDistance con il nome richiesto
/// dalle specifiche del progetto. Rende il codice più leggibile nei
/// contesti dove si parla di "distanza tra due punti" senza entrare
/// nei dettagli dell'algoritmo usato.
///
/// PARAMETRI:
/// - [lat1], [lon1]: latitudine e longitudine del primo punto
/// - [lat2], [lon2]: latitudine e longitudine del secondo punto
///
/// RETURN: distanza in metri (double, sempre >= 0)
double distanceBetween(double lat1, double lon1, double lat2, double lon2) {
  // Delega il calcolo effettivo alla formula di Haversine
  return haversineDistance(lat1, lon1, lat2, lon2);
}

/// minDistanceToPolyline — Calcola la distanza MINIMA tra un punto GPS e
/// una polyline (lista di coordinate) di un percorso (TASK 2).
///
/// COME FUNZIONA:
/// 1. Itera su OGNI punto della polyline decodificata
/// 2. Per ciascun punto, calcola la distanza dal punto GPS dell'utente
/// 3. Tiene traccia della distanza minima trovata
/// 4. Restituisce la distanza minima alla fine dell'iterazione
///
/// PERCHÉ CONFRONTARE CON OGNI PUNTO DELLA POLYLINE:
/// La polyline è una serie di segmenti retti che approssimano il percorso
/// stradale. Per sapere se l'utente è "sul percorso", dobbiamo trovare
/// il punto della polyline più vicino alla sua posizione GPS. Se quel
/// punto è entro la soglia (40 m), l'utente è considerato sul percorso.
///
/// NOTA SULLE PERFORMANCE:
/// Una polyline tipica ha 100-500 punti. Iterare su tutti ha costo O(n),
/// che per 500 punti richiede microsecondi — trascurabile. Non serve
/// ottimizzare con strutture dati spaziali (quadtree, R-tree) per
/// questo numero di punti.
///
/// PARAMETRI:
/// - [lat], [lng]: posizione GPS corrente dell'utente
/// - [polyline]: lista di punti del percorso, ogni punto come [lat, lng]
///
/// RETURN: distanza minima in metri. Se la polyline è vuota, restituisce
///   double.infinity (infinito) per indicare "nessun punto trovato".
double minDistanceToPolyline(
  double lat,
  double lng,
  List<List<double>> polyline,
) {
  // Se la polyline è vuota, non c'è nessun punto con cui confrontare.
  // Restituiamo infinito per indicare che la distanza è "indefinita".
  if (polyline.isEmpty) return double.infinity;

  // Inizializziamo la distanza minima al valore più grande possibile.
  // Qualsiasi distanza reale sarà minore di infinity.
  double minDist = double.infinity;

  // Iteriamo su ogni punto della polyline
  for (final point in polyline) {
    // Calcola la distanza tra la posizione dell'utente e questo
    // punto della polyline usando la funzione distanceBetween
    final double dist = distanceBetween(lat, lng, point[0], point[1]);

    // Se questa distanza è minore della minima trovata finora,
    // aggiorna il valore minimo
    if (dist < minDist) {
      minDist = dist;
    }
  }

  // Restituisce la distanza minima trovata tra tutti i punti
  return minDist;
}

/// isOnRoute — Verifica se l'utente è "sul percorso" (TASK 2a/2b).
///
/// Questa funzione combina minDistanceToPolyline con un confronto
/// a soglia per restituire un semplice booleano: true/false.
///
/// PARAMETRI:
/// - [lat], [lng]: posizione GPS corrente dell'utente
/// - [polyline]: polyline decodificata del percorso da controllare
/// - [thresholdMeters]: soglia in metri (default: kRouteDeviationThresholdMeters)
///
/// RETURN:
/// - true se la distanza minima dalla polyline è ≤ thresholdMeters
///   (l'utente è SUL percorso)
/// - false se la distanza è > thresholdMeters
///   (l'utente ha DEVIATO dal percorso)
bool isOnRoute(
  double lat,
  double lng,
  List<List<double>> polyline, {
  double thresholdMeters = kRouteDeviationThresholdMeters,
}) {
  // Calcola la distanza minima tra la posizione e la polyline
  final double minDist = minDistanceToPolyline(lat, lng, polyline);

  // Confronta con la soglia: se la distanza è ≤ soglia, l'utente è sul percorso
  return minDist <= thresholdMeters;
}

/// Calcola le coordinate di un punto di destinazione dato:
/// - un punto di partenza (lat, lng)
/// - un bearing (direzione in gradi, 0° = Nord, 90° = Est, 180° = Sud, 270° = Ovest)
/// - una distanza in metri
///
/// FORMULA DI DESTINAZIONE GEODETICA (Spherical Law of Cosines / Vincenty):
/// Questa è la formula inversa di Haversine: dato un punto, una direzione e
/// una distanza, calcola dove si "atterra".
///
/// lat2 = asin(sin(lat1) × cos(d/R) + cos(lat1) × sin(d/R) × cos(bearing))
/// lng2 = lng1 + atan2(sin(bearing) × sin(d/R) × cos(lat1),
///                      cos(d/R) - sin(lat1) × sin(lat2))
///
/// PERCHÉ SERVE QUESTA FORMULA:
/// Nella logica dell'app, dobbiamo calcolare punti a N metri a destra/sinistra
/// dell'utente. Non possiamo semplicemente sommare metri alle coordinate perché
/// la conversione gradi→metri dipende dalla latitudine (un grado di longitudine
/// vale ~111 km all'equatore ma ~0 km ai poli).
///
/// EDGE CASES GESTITI:
/// - distanceMeters = 0 → restituisce il punto di partenza
/// - bearing > 360 o < 0 → funziona correttamente (le funzioni trigonometriche
///   sono periodiche con periodo 2π)
/// - Punto vicino ai poli → la formula è meno precisa ma per distanze di
///   pochi metri l'errore è trascurabile
///
/// PARAMETRI:
/// - [lat], [lng]: coordinate del punto di partenza (gradi decimali)
/// - [bearingDeg]: direzione di marcia in gradi (0-360)
/// - [distanceMeters]: distanza dal punto di partenza in metri
///
/// RETURN: lista [latitudine, longitudine] del punto di destinazione (gradi decimali)
List<double> destinationPoint(
  double lat,
  double lng,
  double bearingDeg,
  double distanceMeters,
) {
  // Converti tutto in radianti
  final double latRad = _degreesToRadians(lat);
  final double lngRad = _degreesToRadians(lng);
  final double bearingRad = _degreesToRadians(bearingDeg);

  // Rapporto distanza / raggio terrestre (distanza angolare)
  final double angularDist = distanceMeters / kEarthRadiusMeters;

  // Calcola la latitudine del punto di destinazione
  final double destLatRad = asin(
    sin(latRad) * cos(angularDist) +
        cos(latRad) * sin(angularDist) * cos(bearingRad),
  );

  // Calcola la longitudine del punto di destinazione
  final double destLngRad =
      lngRad +
      atan2(
        sin(bearingRad) * sin(angularDist) * cos(latRad),
        cos(angularDist) - sin(latRad) * sin(destLatRad),
      );

  // Converti da radianti a gradi e restituisci
  return [_radiansToDegrees(destLatRad), _radiansToDegrees(destLngRad)];
}

/// Calcola un punto laterale (destra o sinistra) rispetto alla direzione di marcia.
///
/// Questa funzione è un wrapper di [destinationPoint] che aggiunge automaticamente
/// l'offset angolare di ±90° al bearing per calcolare il lato richiesto.
///
/// COME FUNZIONA IL CALCOLO LATERALE:
/// Se l'utente sta andando verso Nord (bearing = 0°):
/// - Destra = Est = bearing + 90° = 90°
/// - Sinistra = Ovest = bearing - 90° = 270° (o equivalentemente -90°)
///
/// Questa relazione vale per qualsiasi bearing:
/// bearing = 45° (Nord-Est) → destra = 135° (Sud-Est), sinistra = 315° (Nord-Ovest)
///
/// PARAMETRI:
/// - [lat], [lng]: coordinate del punto di partenza
/// - [bearingDeg]: bearing attuale (direzione di marcia) in gradi
/// - [distanceMeters]: distanza laterale in metri
/// - [side]: 'right' per destra (+90°), 'left' per sinistra (-90°)
///
/// RETURN: lista [latitudine, longitudine] del punto laterale
List<double> computeLateralPoint(
  double lat,
  double lng,
  double bearingDeg,
  double distanceMeters,
  String side,
) {
  // Calcola il bearing laterale aggiungendo o sottraendo 90°
  // "right" = +90° (ruota in senso orario)
  // "left"  = -90° (ruota in senso antiorario)
  final double lateralBearing = side == 'right'
      ? bearingDeg + 90.0
      : bearingDeg - 90.0;

  // Usa la formula di destinazione geodetica con il bearing ruotato
  return destinationPoint(lat, lng, lateralBearing, distanceMeters);
}

/// Calcola i 10 punti di campionamento laterale per la Roads API (Step 2.4).
///
/// Genera:
/// - dx: punto principale a 10m a destra
/// - sx: punto principale a 10m a sinistra
/// - dx_R2, dx_R4: satellite di dx espansi verso destra (+2m, +4m)
/// - dx_L2, dx_L4: satellite di dx espansi verso sinistra (-2m, -4m)
/// - sx_L2, sx_L4: satellite di sx espansi verso sinistra (+2m, +4m)
/// - sx_R2, sx_R4: satellite di sx espansi verso destra (-2m, -4m)
///
/// PERCHÉ SI MOLTIPLICANO I PUNTI DI CAMPIONAMENTO:
/// Un singolo punto a destra e uno a sinistra potrebbero non intersecare
/// la carreggiata di una strada laterale perché:
/// 1. Il GPS ha un'imprecisione di 3-10 m → il punto calcolato potrebbe
///    cadere sul marciapiede o in mezzo alle case
/// 2. Le strade hanno larghezze variabili (3-14 m) → un punto potrebbe
///    passare "tra" due corsie
/// 3. Le strade laterali non sono sempre perfettamente perpendicolari
///
/// PERCHÉ L'ESPANSIONE BILATERALE (sia destra che sinistra da ogni punto):
/// L'espansione solo in una direzione coprirebbe un arco di 0-14 m su un lato,
/// ma mancherebbe la zona 6-10 m sull'altro lato. Espandendo in entrambe le
/// direzioni si copre l'arco 6-14 m, garantendo copertura anche per strade
/// leggermente sfalsate o non perpendicolari.
///
/// PARAMETRI:
/// - [lat], [lng]: posizione corrente dell'utente
/// - [bearingDeg]: bearing di marcia attuale (direction)
///
/// RETURN: lista di 10 punti, ciascuno come [latitudine, longitudine]
List<List<double>> computeAllLateralPoints(
  double lat,
  double lng,
  double bearingDeg,
) {
  // --- Punti principali ---
  // dx: 10 metri a DESTRA della direzione di marcia
  final dx = computeLateralPoint(
    lat,
    lng,
    bearingDeg,
    kLateralDistanceMeters,
    'right',
  );
  // sx: 10 metri a SINISTRA della direzione di marcia
  final sx = computeLateralPoint(
    lat,
    lng,
    bearingDeg,
    kLateralDistanceMeters,
    'left',
  );

  // --- Satellite di dx (punto principale destro) ---
  // Espandi da dx verso destra lungo lo stesso asse laterale
  final dxR2 = computeLateralPoint(
    dx[0],
    dx[1],
    bearingDeg,
    kSatelliteOffset2m,
    'right',
  );
  final dxR4 = computeLateralPoint(
    dx[0],
    dx[1],
    bearingDeg,
    kSatelliteOffset4m,
    'right',
  );
  // Espandi da dx verso sinistra lungo lo stesso asse laterale
  final dxL2 = computeLateralPoint(
    dx[0],
    dx[1],
    bearingDeg,
    kSatelliteOffset2m,
    'left',
  );
  final dxL4 = computeLateralPoint(
    dx[0],
    dx[1],
    bearingDeg,
    kSatelliteOffset4m,
    'left',
  );

  // --- Satellite di sx (punto principale sinistro) ---
  // Espandi da sx verso sinistra lungo lo stesso asse laterale
  final sxL2 = computeLateralPoint(
    sx[0],
    sx[1],
    bearingDeg,
    kSatelliteOffset2m,
    'left',
  );
  final sxL4 = computeLateralPoint(
    sx[0],
    sx[1],
    bearingDeg,
    kSatelliteOffset4m,
    'left',
  );
  // Espandi da sx verso destra lungo lo stesso asse laterale
  final sxR2 = computeLateralPoint(
    sx[0],
    sx[1],
    bearingDeg,
    kSatelliteOffset2m,
    'right',
  );
  final sxR4 = computeLateralPoint(
    sx[0],
    sx[1],
    bearingDeg,
    kSatelliteOffset4m,
    'right',
  );

  // Restituisce tutti i 10 punti nell'ordine:
  // dx, sx, dxR2, dxR4, dxL2, dxL4, sxL2, sxL4, sxR2, sxR4
  return [dx, sx, dxR2, dxR4, dxL2, dxL4, sxL2, sxL4, sxR2, sxR4];
}

// =============================================================================
// FUNZIONI HELPER PRIVATE
// =============================================================================

/// Converte gradi in radianti.
/// Formula: radianti = gradi × π / 180
double _degreesToRadians(double degrees) => degrees * pi / 180.0;

/// Converte radianti in gradi.
/// Formula: gradi = radianti × 180 / π
double _radiansToDegrees(double radians) => radians * 180.0 / pi;
