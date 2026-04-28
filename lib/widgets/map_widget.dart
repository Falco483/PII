/// MapWidget - Widget per visualizzare la mappa Google Maps
///
/// Questo widget mostra una mappa Google Maps con marker per
/// origine/destinazione e una polyline per il percorso.
/// Compatibile con Android, iOS e Web.
///
/// TASK 3 — SELEZIONE PUNTO SULLA MAPPA:
/// Questo widget supporta due tipi di tap sulla mappa:
/// 1. onMapTap: l'utente tocca un punto generico (nessun POI)
///    → restituisce le coordinate lat/lng direttamente
/// 2. onPoiTap: l'utente tocca un POI (negozio, ristorante, ecc.)
///    → restituisce placeId, nome e coordinate del POI

import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'dart:ui' as ui;
import 'dart:math' as math;
import '../services/directions_service.dart';

/// Widget che visualizza la mappa Google Maps
class MapWidget extends StatefulWidget {
  // Coordinate del punto di partenza (se presente)
  final double? originLat;
  final double? originLng;
  // Coordinate della destinazione (se presente)
  final double? destLat;
  final double? destLng;
  // Polyline codificata per il percorso
  final String? encodedPolyline;

  /// Coordinate GPS iniziali: se fornite, la camera si posizionerà qui
  /// appena la mappa è pronta (al posto del centro Italia fisso).
  final double? initialLat;
  final double? initialLng;

  /// Callback chiamato quando l'utente tocca un punto sulla mappa (TASK 3).
  final void Function(LatLng position)? onMapTap;

  /// Callback chiamato quando l'utente sposta manualmente la mappa (pan/pinch).
  final VoidCallback? onUserInteraction;

  // =========================================================================
  // PARAMETRI ACCESSIBILITÀ — NAVIGAZIONE SEGMENTATA
  // =========================================================================

  /// Se true, la mappa è in modalità navigazione attiva.
  /// In questa modalità, il percorso viene visualizzato a SEGMENTI:
  /// - Segmento corrente: verde brillante, spesso 14px, bordo bianco
  /// - Segmento successivo: grigio chiaro, spesso 8px (anteprima)
  /// - Resto del percorso: nascosto
  ///
  /// Questo riduce drasticamente il sovraccarico cognitivo perché l'utente
  /// vede solo "dove deve andare ADESSO" e non l'intero percorso.
  final bool isNavigating;

  /// Indice dello step corrente (0-based).
  /// Usato per decidere quale segmento colorare in verde (corrente)
  /// e quale in grigio (successivo). Aggiornato dal NavigationMonitor.
  final int currentStepIndex;

  /// Lista degli step con le polyline individuali.
  /// Ogni step contiene `encodedStepPolyline` che descrive il tracciato
  /// esatto di quel segmento. Se null o vuota, fallback alla overview polyline.
  final List<DirectionStep>? steps;

  // =========================================================================
  // PARAMETRI POSIZIONE UTENTE — FRECCIA DIREZIONALE CUSTOM
  // =========================================================================

  /// Latitudine corrente dell'utente (da GPS).
  /// Usata per posizionare la freccia direzionale sulla mappa.
  /// Se null, la freccia non viene mostrata.
  final double? userLat;

  /// Longitudine corrente dell'utente (da GPS).
  final double? userLng;

  /// Bearing corrente dell'utente (gradi 0-360, 0=Nord).
  /// La freccia ruota per puntare in questa direzione.
  /// Se 0, la freccia punta verso nord (default).
  final double userBearing;

  // =========================================================================
  // PARAMETRO PERCORSO EFFETTUATO — REVIEW POST-ARRIVO
  // =========================================================================

  /// Lista di coordinate GPS registrate durante la navigazione.
  /// Quando non è null/vuota, viene disegnata come polyline VERDE
  /// sulla mappa per mostrare il percorso effettivamente camminato.
  /// Usata nella schermata "Rivedi il percorso" dopo l'arrivo.
  final List<LatLng>? walkedPath;

  const MapWidget({
    super.key,
    this.originLat,
    this.originLng,
    this.destLat,
    this.destLng,
    this.encodedPolyline,
    this.onMapTap,
    this.onUserInteraction,
    this.initialLat,
    this.initialLng,
    this.isNavigating = false,
    this.currentStepIndex = 0,
    this.steps,
    this.userLat,
    this.userLng,
    this.userBearing = 0,
    this.walkedPath,
  });

  @override
  State<MapWidget> createState() => MapWidgetState();
}

class MapWidgetState extends State<MapWidget> {
  // Controller per la mappa Google
  GoogleMapController? _mapController;

  // Set di marker sulla mappa (percorso: origine + destinazione)
  Set<Marker> _routeMarkers = {};

  // Marker freccia utente (separato per aggiornamento indipendente)
  Marker? _userArrowMarker;

  // Set di polyline sulla mappa
  Set<Polyline> _polylines = {};

  /// Flag per distinguere i movimenti di camera programmatici
  /// da quelli causati dal gesto dell'utente (pan/pinch).
  bool _isProgrammaticMove = false;

  // Posizione iniziale: centro Italia
  static const LatLng _initialPosition = LatLng(45.4836315, 9.2249375);
  static const double _initialZoom = 18;

  // FIX BUG 5 — LARGHEZZA POLYLINE COSTANTE
  //
  // La polyline blu del percorso attivo (segmento corrente + resto del percorso)
  // DEVE mantenere sempre la stessa larghezza in ogni stato dell'app.
  // Prima: current_step=14px, remaining_route=6px, preview=6px → se lo step
  // corrente non aveva encodedStepPolyline (es. fallback post-reroute),
  // veniva renderizzata SOLO la remaining/preview a 6px, dando l'effetto
  // di una polyline "più sottile del normale".
  // Ora: un unico valore uniforme sia per corrente che per resto/preview.
  static const double _kRoutePolylineWidth = 14.0;
  // Il bordo di ombreggiatura è proporzionalmente più largo
  static const double _kRouteBorderWidth = 18.0;

  // =========================================================================
  // FRECCIA DIREZIONALE CUSTOM — BITMAP CACHE
  // =========================================================================

  /// Bitmap della freccia direzionale, creata una volta e riutilizzata.
  ///
  /// La freccia viene disegnata con Canvas di Flutter al primo avvio e
  /// cachata come BitmapDescriptor. La rotazione è gestita dalla proprietà
  /// `Marker.rotation`, quindi il bitmap è sempre orientato verso l'alto.
  ///
  /// DESIGN (replica Google Maps Navigation):
  /// - Cerchio BLU grande (120x120 dp) con bordo bianco spesso
  /// - Freccia/chevron bianca all'interno — indica la direzione
  /// - Colore BLU (#4285F4) come la freccia di navigazione Google Maps
  /// - Ombra sottile per staccarsi dalla mappa
  BitmapDescriptor? _arrowBitmap;

  /// Bitmap per le frecce direzionali PICCOLE lungo la polyline.
  /// Sono le piccole chevron bianche che indicano la direzione di marcia
  /// sulla linea blu del percorso (come in Google Maps navigation).
  BitmapDescriptor? _directionChevronBitmap;

  /// Bitmap per le frecce GRANDI lungo la polyline.
  BitmapDescriptor? _bigArrowBitmap;

  /// Set di marker per le frecce direzionali lungo la polyline.
  /// Vengono rigenerati ogni volta che cambia lo step corrente.
  Set<Marker> _chevronMarkers = {};

  /// Set di marker per le frecce grandi lungo la polyline.
  Set<Marker> _bigArrowMarkers = {};

  @override
  void initState() {
    super.initState();
    // Crea la freccia utente e i chevron direzionali in background.
    _createArrowBitmap();
    _createChevronBitmap();
    _createBigArrowBitmap();
  }

  /// Crea il bitmap della freccia direzionale usando Canvas.
  ///
  /// La freccia è un cerchio arancione con una freccia bianca dentro.
  /// Dimensione: 120x120 pixel (scalata automaticamente dal device pixel ratio).
  ///
  /// NOTA: Usiamo dart:ui per disegnare direttamente, senza dipendere
  /// da asset esterni (immagini PNG). Questo garantisce che la freccia
  /// sia sempre disponibile e ad alta risoluzione su qualsiasi dispositivo.
  Future<void> _createArrowBitmap() async {
    const double size = 120;

    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(
      recorder,
      const Rect.fromLTWH(0, 0, size, size),
    );

    final double center = size / 2;
    final double radius = size / 2 - 3;

    // --- 1. OMBRA (cerchio grigio sotto, spostato di 3px) ---
    // Dà profondità e stacca la freccia dalla mappa
    canvas.drawCircle(
      Offset(center, center + 3),
      radius,
      Paint()..color = const Color(0x40000000), // nero al 25%
    );

    // --- 2. BORDO BIANCO ESTERNO ---
    // Contrasto con qualsiasi sfondo mappa (chiaro o scuro)
    canvas.drawCircle(
      Offset(center, center),
      radius,
      Paint()..color = const Color(0xFFFFFFFF),
    );

    // --- 3. CERCHIO BLU (sfondo freccia — come Google Maps) ---
    // Blu #4285F4: identico al pallino di navigazione Google Maps
    canvas.drawCircle(
      Offset(center, center),
      radius - 5,
      Paint()..color = const Color(0xFF4285F4),
    );

    // --- 4. FRECCIA BIANCA (punta verso l'alto) ---
    // La rotazione è gestita da Marker.rotation, NON dal disegno.
    // La freccia è un chevron/triangolo che punta chiaramente "avanti".
    final Path arrowPath = Path()
      ..moveTo(center, 22)             // Punta superiore (la direzione)
      ..lineTo(center + 28, 78)        // Angolo basso-destro
      ..lineTo(center + 6, 62)         // Rientranza destra
      ..lineTo(center, 70)             // Centro basso (tacca)
      ..lineTo(center - 6, 62)         // Rientranza sinistra
      ..lineTo(center - 28, 78)        // Angolo basso-sinistro
      ..close();

    canvas.drawPath(
      arrowPath,
      Paint()
        ..color = const Color(0xFFFFFFFF)
        ..style = PaintingStyle.fill,
    );

    // --- 5. BORDO SOTTILE SULLA FRECCIA (per definizione) ---
    canvas.drawPath(
      arrowPath,
      Paint()
        ..color = const Color(0x30000000) // bordo semi-trasparente
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );

    // Converte il disegno in immagine raster e poi in BitmapDescriptor
    final ui.Picture picture = recorder.endRecording();
    final ui.Image image = await picture.toImage(size.toInt(), size.toInt());
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);

    if (byteData != null && mounted) {
      setState(() {
        _arrowBitmap = BitmapDescriptor.bytes(
          byteData.buffer.asUint8List(),
          width: 56, // Dimensione logica su schermo (dp)
          height: 56,
        );
      });

      // Se siamo già in navigazione, aggiorna subito il marker
      if (widget.isNavigating) {
        _updateUserMarker();
      }
    }
  }

  /// Crea il bitmap del chevron direzionale (freccia bianca sulla polyline).
  ///
  /// Replica le frecce bianche grandi che Google Maps mostra dentro la
  /// linea blu del percorso. Sono frecce PIENE (non solo contorno),
  /// grandi e ben visibili — identiche a quelle nello screenshot.
  /// Dimensione: 100x100 pixel → 40dp su schermo.
  Future<void> _createChevronBitmap() async {
    const double size = 100;

    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(
      recorder,
      const Rect.fromLTWH(0, 0, size, size),
    );

    final double center = size / 2;

    // Freccia bianca PIENA (triangolo/chevron come Google Maps nav)
    // Punta verso l'alto — la rotazione è gestita dal Marker.
    // Forma più larga e audace per imitare lo stile Google Maps.
    final Path chevronPath = Path()
      ..moveTo(center, 12)               // Punta superiore
      ..lineTo(center + 26, 58)          // Angolo basso-destro
      ..lineTo(center + 6, 44)           // Rientranza destra
      ..lineTo(center, 52)               // Centro basso
      ..lineTo(center - 6, 44)           // Rientranza sinistra
      ..lineTo(center - 26, 58)          // Angolo basso-sinistro
      ..close();

    // Ombra leggera sotto la freccia per darle profondità
    final Path shadowPath = Path()
      ..moveTo(center, 14)
      ..lineTo(center + 26, 60)
      ..lineTo(center + 6, 46)
      ..lineTo(center, 54)
      ..lineTo(center - 6, 46)
      ..lineTo(center - 26, 60)
      ..close();

    canvas.drawPath(
      shadowPath,
      Paint()
        ..color = const Color(0x30000000) // Ombra nera al 19%
        ..style = PaintingStyle.fill,
    );

    canvas.drawPath(
      chevronPath,
      Paint()
        ..color = const Color(0xFFFFFFFF) // Bianco 100% opaco
        ..style = PaintingStyle.fill,
    );

    final ui.Picture picture = recorder.endRecording();
    final ui.Image image = await picture.toImage(size.toInt(), size.toInt());
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);

    if (byteData != null && mounted) {
      _directionChevronBitmap = BitmapDescriptor.bytes(
        byteData.buffer.asUint8List(),
        width: 40, // Grande come in Google Maps
        height: 40,
      );
    }
  }

  Future<void> _createBigArrowBitmap() async {
    const double size = 160;

    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(
      recorder,
      const Rect.fromLTWH(0, 0, size, size),
    );

    final double center = size / 2;

    // Freccia grande bianca con bordo blu spesso.
    final Path arrowPath = Path()
      ..moveTo(center, 10)               // Punta superiore
      ..lineTo(center + 50, 120)         // Angolo basso-destro
      ..lineTo(center, 90)               // Centro basso
      ..lineTo(center - 50, 120)         // Angolo basso-sinistro
      ..close();

    // Ombra
    canvas.drawPath(
      arrowPath.shift(const Offset(0, 4)),
      Paint()
        ..color = const Color(0x40000000)
        ..style = PaintingStyle.fill,
    );

    // Disegna bordo blu
    canvas.drawPath(
      arrowPath,
      Paint()
        ..color = const Color(0xFF1A56C4) // Blu scuro, stesso del bordo della polyline
        ..style = PaintingStyle.stroke
        ..strokeWidth = 16
        ..strokeJoin = StrokeJoin.round,
    );

    // Disegna riempimento bianco
    canvas.drawPath(
      arrowPath,
      Paint()
        ..color = const Color(0xFFFFFFFF)
        ..style = PaintingStyle.fill,
    );

    final ui.Picture picture = recorder.endRecording();
    final ui.Image image = await picture.toImage(size.toInt(), size.toInt());
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);

    if (byteData != null && mounted) {
      _bigArrowBitmap = BitmapDescriptor.bytes(
        byteData.buffer.asUint8List(),
        width: 60, // Dimensione maggiore del chevron (40)
        height: 60,
      );
    }
  }

  /// Posiziona indicatori direzionali lungo i punti della polyline.
  Set<Marker> _buildDirectionalMarkers(
    List<LatLng> points, {
    required BitmapDescriptor? bitmap,
    required String prefix,
    double intervalMeters = 30,
    int zIndex = 3,
  }) {
    if (bitmap == null || points.length < 2) return {};

    final Set<Marker> markers = {};
    double accumulatedDistance = 0;
    int markerId = 0;

    for (int i = 0; i < points.length - 1; i++) {
      final LatLng p1 = points[i];
      final LatLng p2 = points[i + 1];

      // Distanza tra i due punti (in metri, approssimazione)
      final double dLat = (p2.latitude - p1.latitude) * 111320;
      final double dLng = (p2.longitude - p1.longitude) * 111320 *
          math.cos(p1.latitude * math.pi / 180);
      final double segmentDist = math.sqrt(dLat * dLat + dLng * dLng);

      // Bearing del segmento (gradi, 0=nord)
      final double bearing = math.atan2(dLng, dLat) * 180 / math.pi;

      // Interpola i marker lungo il segmento per distribuzione uniforme
      double startOffset = intervalMeters - accumulatedDistance;

      if (startOffset <= 0) startOffset = intervalMeters;

      double offset = startOffset;
      while (offset <= segmentDist && segmentDist > 0) {
        // Calcola la posizione interpolata
        final double fraction = offset / segmentDist;
        final double interpLat = p1.latitude + (p2.latitude - p1.latitude) * fraction;
        final double interpLng = p1.longitude + (p2.longitude - p1.longitude) * fraction;

        markers.add(Marker(
          markerId: MarkerId('${prefix}_$markerId'),
          position: LatLng(interpLat, interpLng),
          icon: bitmap,
          rotation: bearing,
          flat: true,
          anchor: const Offset(0.5, 0.5),
          zIndexInt: zIndex,
        ));
        markerId++;
        offset += intervalMeters;
      }

      // Aggiorna la distanza accumulata per il prossimo segmento
      accumulatedDistance = (accumulatedDistance + segmentDist) % intervalMeters;
    }

    return markers;
  }

  @override
  void didUpdateWidget(MapWidget oldWidget) {
    super.didUpdateWidget(oldWidget);

    // Aggiorna le polyline e i marker di percorso quando cambiano i dati route
    if (widget.encodedPolyline != oldWidget.encodedPolyline ||
        widget.originLat != oldWidget.originLat ||
        widget.destLat != oldWidget.destLat ||
        widget.isNavigating != oldWidget.isNavigating ||
        widget.currentStepIndex != oldWidget.currentStepIndex ||
        widget.walkedPath != oldWidget.walkedPath) {
      _updateRoute();
    }

    // Aggiorna SOLO il marker utente quando cambia la posizione GPS.
    // Questo è separato da _updateRoute per efficienza: la posizione GPS
    // cambia ogni ~500ms, ma il percorso cambia raramente.
    if (widget.userLat != oldWidget.userLat ||
        widget.userLng != oldWidget.userLng ||
        widget.userBearing != oldWidget.userBearing ||
        widget.isNavigating != oldWidget.isNavigating) {
      _updateUserMarker();
    }
  }

  // =========================================================================
  // STILE MAPPA — BIANCA CLASSICA CON POI VISIBILI
  // =========================================================================

  /// Stile mappa pulito: sfondo bianco, scritte nere, POI visibili.
  ///
  /// PRINCIPI:
  /// 1. Mappa bianca classica — niente colori sabbia, tutto leggibile
  /// 2. POI visibili — bar, farmacie, hotel sono punti di riferimento utili
  /// 3. Scritte scure — massima leggibilità su sfondo chiaro
  /// 4. Solo le icone stradali (scudi autostrada) sono nascoste
  ///
  /// NOTA: Questo stile SOSTITUISCE il cloudMapId.
  static const String _accessibleMapStyle = '''
[
  {
    "featureType": "road",
    "elementType": "labels.icon",
    "stylers": [{"visibility": "off"}]
  }
]
''';

  /// Callback quando la mappa è creata
  void _onMapCreated(GoogleMapController controller) {
    _mapController = controller;
    debugPrint('=== GOOGLE MAP CREATED SUCCESSFULLY ===');

    // Se sono disponibili le coordinate GPS iniziali, centra la camera lì.
    if (widget.initialLat != null && widget.initialLng != null) {
      _isProgrammaticMove = true;
      _mapController!.animateCamera(
        CameraUpdate.newCameraPosition(
          CameraPosition(
            target: LatLng(widget.initialLat!, widget.initialLng!),
            zoom: _initialZoom,
          ),
        ),
      );
    }

    // Se ci sono già dati del percorso, aggiorna la mappa
    if (widget.encodedPolyline != null) {
      _updateRoute();
    }
  }

  /// Centra la camera sulla posizione fornita (chiamato dal parent per il
  /// pulsante "Torna alla mia posizione").
  void moveToLocation(double lat, double lng) {
    _isProgrammaticMove = true;
    _mapController?.animateCamera(
      CameraUpdate.newCameraPosition(
        CameraPosition(target: LatLng(lat, lng), zoom: _initialZoom),
      ),
    );
  }

  /// Centra la camera sulla posizione dell'utente con bearing e tilt
  /// (visuale "navigazione guidata" — prospettiva 3D orientata nella
  /// direzione di marcia).
  ///
  /// ACCESSIBILITÀ:
  /// - Zoom 17 (ridotto di 2 da 19)
  /// - Tilt 55°: prospettiva più immersiva, aiuta a percepire
  ///   la profondità e la direzione "avanti". Effetto "corridoio".
  void followUser(double lat, double lng, double bearing) {
    _isProgrammaticMove = true;
    _mapController?.animateCamera(
      CameraUpdate.newCameraPosition(
        CameraPosition(
          target: LatLng(lat, lng),
          zoom: 18,
          bearing: bearing,
          tilt: 40,
        ),
      ),
    );
  }

  /// Posiziona ISTANTANEAMENTE la camera orientata verso il percorso.
  ///
  /// A differenza di followUser (che usa animateCamera con transizione
  /// fluida), questo metodo usa moveCamera che è ISTANTANEO — nessun lag.
  /// Viene chiamato quando l'utente preme "Avvia" per posizionare
  /// immediatamente la vista nella direzione del percorso.
  void snapToRoute(double lat, double lng, double bearing) {
    _isProgrammaticMove = true;
    _mapController?.moveCamera(
      CameraUpdate.newCameraPosition(
        CameraPosition(
          target: LatLng(lat, lng),
          zoom: 18,
          bearing: bearing,
          tilt: 40,
        ),
      ),
    );
  }

  /// Aggiorna marker e polyline sulla mappa
  ///
  /// In modalità navigazione (isNavigating=true), usa le polyline per-step
  /// per evidenziare solo il segmento corrente e il successivo.
  /// In modalità preview (isNavigating=false), mostra la overview polyline
  /// classica con la linea blu standard.
  void _updateRoute() {
    // TASK 5: State Synchronization e Memory Leaks
    // Ripuliamo esplicitamente le vecchie risorse per forzare lo smaltimento
    // dei renderer sul layer nativo di Google Maps prima di ricalcolare.
    _routeMarkers.clear();
    _polylines.clear();
    _chevronMarkers.clear(); // Pulizia frecce direzionali a fine navigazione
    _bigArrowMarkers.clear(); // Pulizia frecce grandi

    if (widget.originLat == null ||
        widget.originLng == null ||
        widget.destLat == null ||
        widget.destLng == null ||
        widget.encodedPolyline == null) {
      // Se non ci sono tutti i dati, aggiorna la UI vuota
      setState(() {});
      return;
    }

    // Crea i marker
    final Set<Marker> markers = {
      // Marker partenza (verde)
      Marker(
        markerId: const MarkerId('origin'),
        position: LatLng(widget.originLat!, widget.originLng!),
        infoWindow: const InfoWindow(title: 'Partenza'),
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen),
      ),
      // Marker destinazione (rosso)
      Marker(
        markerId: const MarkerId('destination'),
        position: LatLng(widget.destLat!, widget.destLng!),
        infoWindow: const InfoWindow(title: 'Destinazione'),
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
      ),
    };

    // Crea le polyline — logica diversa in base alla modalità
    final Set<Polyline> polylines;

    if (widget.isNavigating && _hasStepPolylines()) {
      // =====================================================================
      // MODALITÀ NAVIGAZIONE ACCESSIBILE — SEGMENTI SEPARATI
      // =====================================================================
      // Mostra solo:
      //   1. Segmento corrente → VERDE BRILLANTE, spesso (14px + bordo bianco)
      //   2. Segmento successivo → GRIGIO CHIARO, medio (8px, anteprima)
      //   3. Tutto il resto → NASCOSTO (non disegnato)
      //
      // PERCHÉ:
      // Per un utente con disabilità cognitive, vedere 20 svolte su una mappa
      // è sovraccarico. Mostrando solo "dove vai ORA" e "dove andrai DOPO",
      // la mappa diventa immediatamente comprensibile.
      // =====================================================================
      polylines = _buildSegmentedPolylines();
    } else {
      // =====================================================================
      // MODALITÀ PREVIEW / FALLBACK — OVERVIEW POLYLINE CLASSICA
      // =====================================================================
      // Usa la overview polyline completa (linea blu, 6px) quando:
      // - Non siamo in navigazione (routePreview)
      // - Gli step non hanno polyline individuali (fallback)
      // =====================================================================
      final List<LatLng> polylinePoints = _decodePolyline(
        widget.encodedPolyline!,
      );

      polylines = {
        Polyline(
          polylineId: const PolylineId('route'),
          points: polylinePoints,
          color: Colors.blue,
          // FIX BUG 5: stessa larghezza del segmento attivo in navigazione,
          // per consistenza visiva tra preview e navigazione.
          width: _kRoutePolylineWidth.toInt(),
          geodesic: true,
          jointType: JointType.round,
          startCap: Cap.roundCap,
          endCap: Cap.roundCap,
        ),
      };
    }

    // Aggiorna lo stato
    setState(() {
      _routeMarkers = markers;
      _polylines = polylines;

      // --- PERCORSO EFFETTUATO (walked path) ---
      // Se presente, aggiunge una polyline VERDE che mostra il percorso
      // effettivamente camminato dall'utente. Usata nella review post-arrivo.
      // Ha zIndex alto per stare sopra la polyline pianificata.
      if (widget.walkedPath != null && widget.walkedPath!.length >= 2) {
        _polylines.add(Polyline(
          polylineId: const PolylineId('walked_path'),
          points: widget.walkedPath!,
          color: const Color(0xFF34A853), // Verde Google
          width: 8,
          geodesic: true,
          jointType: JointType.round,
          startCap: Cap.roundCap,
          endCap: Cap.roundCap,
          zIndex: 5, // Sopra tutto il resto
        ));
      }
    });

    // Aggiorna anche il marker utente (in caso di cambio modalità)
    _updateUserMarker();

    // Adatta la camera per mostrare il percorso.
    // In modalità navigazione NON chiamiamo _fitBounds() perché:
    // 1. snapToRoute() ha già posizionato la camera a zoom 19 + tilt 55
    //    orientata verso il percorso
    // 2. _fitBounds() resetterebbe a zoom 15 senza tilt, annullando
    //    l'orientamento impostato da snapToRoute()
    // 3. Il follow-mode si occupa di aggiornare la camera continuamente
    if (!widget.isNavigating) {
      _fitBounds();
    }
  }

  // =========================================================================
  // MARKER UTENTE — FRECCIA DIREZIONALE
  // =========================================================================

  /// Aggiorna il marker freccia dell'utente sulla mappa.
  ///
  /// Chiamato ad ogni aggiornamento GPS (~500ms) e quando cambia la modalità.
  /// - In navigazione: mostra la freccia BLU custom al posto del pallino
  /// - Fuori navigazione: nessun marker custom (usa il pallino blu di Google)
  ///
  /// PERFORMANCE: Questo metodo crea solo un oggetto Marker (leggero) e
  /// chiama setState. Non ricostruisce le polyline né gli altri marker.
  void _updateUserMarker() {
    if (!widget.isNavigating ||
        widget.userLat == null ||
        widget.userLng == null ||
        _arrowBitmap == null) {
      // Fuori navigazione o dati mancanti: nessun marker custom
      if (_userArrowMarker != null) {
        setState(() {
          _userArrowMarker = null;
        });
      }
      return;
    }

    setState(() {
      _userArrowMarker = Marker(
        markerId: const MarkerId('user_arrow'),
        position: LatLng(widget.userLat!, widget.userLng!),
        icon: _arrowBitmap!,

        // --- ROTAZIONE ---
        // La freccia ruota per puntare nella direzione di marcia.
        // Il bitmap è disegnato con la punta verso l'alto (nord/0°),
        // quindi `rotation` lo orienta direttamente sul bearing GPS.
        rotation: widget.userBearing,

        // --- FLAT = TRUE ---
        // Il marker giace piatto sulla mappa (come un adesivo sul pavimento),
        // non come un cartello verticale. Questo è fondamentale perché:
        // 1. Con tilt 55° un marker verticale apparirebbe storto e confuso
        // 2. Un marker piatto ruota naturalmente con la mappa
        // 3. L'effetto "sto camminando su questa freccia" è più intuitivo
        flat: true,

        // --- ANCHOR AL CENTRO ---
        // Il marker è ancorato al centro (0.5, 0.5) anziché al fondo.
        // Così la posizione GPS corrisponde al CENTRO della freccia,
        // non alla base — l'utente si sente "dentro" la freccia.
        anchor: const Offset(0.5, 0.5),

        // --- PRIORITÀ Z ---
        // Il marker utente deve stare SOPRA tutto: sopra i marker di
        // percorso, sopra le polyline. Non deve mai essere coperto.
        zIndexInt: 10,
      );
    });
  }

  /// Controlla se gli step hanno polyline individuali disponibili.
  bool _hasStepPolylines() {
    final steps = widget.steps;
    if (steps == null || steps.isEmpty) return false;
    // Verifica che almeno lo step corrente abbia una polyline
    final idx = widget.currentStepIndex;
    if (idx >= steps.length) return false;
    return steps[idx].encodedStepPolyline != null;
  }

  /// Costruisce le polyline segmentate per la navigazione.
  ///
  /// STILE GOOGLE MAPS NAVIGATION:
  /// 1. BORDO (ombra) dello step corrente (zIndex=1): polyline scura, 18px
  ///    → contorno che stacca il percorso dalla mappa
  /// 2. SEGMENTO CORRENTE (zIndex=2): polyline BLU #4285F4, 14px
  ///    → identico al colore della navigazione Google Maps
  /// 3. SEGMENTO SUCCESSIVO (zIndex=0): polyline GRIGIA, 8px
  ///    → anteprima del percorso futuro (come le frecce grigie in foto)
  /// 4. CHEVRON DIREZIONALI: marker freccia bianca lungo la polyline
  ///    → indicano la direzione di marcia (come le ">" in Google Maps)
  Set<Polyline> _buildSegmentedPolylines() {
    final steps = widget.steps!;
    final idx = widget.currentStepIndex;
    final Set<Polyline> polylines = {};

    // Reset chevron markers
    _chevronMarkers.clear();

    // --- 1. SEGMENTO CORRENTE (blu Google Maps con bordo scuro) ---
    if (idx < steps.length && steps[idx].encodedStepPolyline != null) {
      final currentPoints = _decodePolyline(steps[idx].encodedStepPolyline!);

      // Bordo scuro (ombra sotto, più largo)
      polylines.add(Polyline(
        polylineId: const PolylineId('current_border'),
        points: currentPoints,
        color: const Color(0xFF1A56C4), // Blu scuro (ombra)
        width: _kRouteBorderWidth.toInt(), // FIX BUG 5: costante uniforme
        geodesic: true,
        jointType: JointType.round,
        startCap: Cap.roundCap,
        endCap: Cap.roundCap,
        zIndex: 1,
      ));

      // Linea blu Google Maps (sopra, più stretta)
      polylines.add(Polyline(
        polylineId: const PolylineId('current_step'),
        points: currentPoints,
        color: const Color(0xFF4285F4), // Blu Google Maps
        width: _kRoutePolylineWidth.toInt(), // FIX BUG 5: costante uniforme
        geodesic: true,
        jointType: JointType.round,
        startCap: Cap.roundCap,
        endCap: Cap.roundCap,
        zIndex: 2,
      ));

      // Chevron direzionali bianchi lungo il segmento corrente
      // Spaziatura ravvicinata (30m) per il segmento attivo
      _chevronMarkers = _buildDirectionalMarkers(
        currentPoints,
        bitmap: _directionChevronBitmap,
        prefix: 'chev_curr',
        intervalMeters: 30,
        zIndex: 3,
      );

      // Frecce grandi per evidenziare ulteriormente la direzione
      // Spaziatura maggiore (150m) per evitare sovrapposizioni (5X rispetto ai chevron)
      _bigArrowMarkers = _buildDirectionalMarkers(
        currentPoints,
        bitmap: _bigArrowBitmap,
        prefix: 'bigarr_curr',
        intervalMeters: 150,
        zIndex: 4,
      );
    }

    // --- 2. SEGMENTO SUCCESSIVO (grigio, anteprima) ---
    final nextIdx = idx + 1;
    if (nextIdx < steps.length && steps[nextIdx].encodedStepPolyline != null) {
      final nextPoints = _decodePolyline(steps[nextIdx].encodedStepPolyline!);

      polylines.add(Polyline(
        polylineId: const PolylineId('next_step'),
        points: nextPoints,
        color: Colors.grey.shade400,
        width: 8,
        geodesic: true,
        jointType: JointType.round,
        startCap: Cap.roundCap,
        endCap: Cap.roundCap,
        zIndex: 0,
      ));
    }

    // --- 3. PERCORSO COMPLESSIVO (sfondo blu chiaro) ---
    // Disegna l'intera overview_polyline come linea di base.
    // In questo modo, indipendentemente dagli step o dal ricalcolo,
    // l'utente vedrà sempre l'intero percorso fino alla destinazione.
    // I segmenti corrente e successivo verranno disegnati SOPRA questa linea
    // (grazie a zIndex maggiore) coprendola dove serve.
    if (widget.encodedPolyline != null) {
      final List<LatLng> allPoints = _decodePolyline(widget.encodedPolyline!);
      if (allPoints.isNotEmpty) {
        polylines.add(Polyline(
          polylineId: const PolylineId('remaining_route'),
          points: allPoints,
          color: const Color(0xFF1A56C4), // Blu scuro (visibile e chiaro)
          // FIX BUG 5: larghezza uniforme a current_step. Prima era 6px,
          // quindi se lo step corrente non era visibile (encodedStepPolyline
          // null dopo un fallback/reroute), restava visibile solo questa
          // polyline sottilissima, dando l'impressione di una polyline
          // "a volte più piccola". Ora è sempre 14px come il segmento attivo.
          width: _kRoutePolylineWidth.toInt(),
          geodesic: true,
          jointType: JointType.round,
          startCap: Cap.roundCap,
          endCap: Cap.roundCap,
          zIndex: 0,
        ));

        // Chevron anche sul percorso rimanente (più distanziati)
        _chevronMarkers.addAll(_buildDirectionalMarkers(
          allPoints,
          bitmap: _directionChevronBitmap,
          prefix: 'chev_rem',
          intervalMeters: 60,
          zIndex: 1,
        ));

        // Frecce grandi per il percorso rimanente
        _bigArrowMarkers.addAll(_buildDirectionalMarkers(
          allPoints,
          bitmap: _bigArrowBitmap,
          prefix: 'bigarr_rem',
          intervalMeters: 300, // 5X rispetto ai chevron (60 * 5)
          zIndex: 2,
        ));
      }
    }

    return polylines;
  }


  /// Centra la vista della mappa sul punto di partenza (anziché allargare a tutto il percorso) con zoom a 15
  void _fitBounds() {
    if (_mapController == null || widget.originLat == null || widget.originLng == null) {
      return;
    }

    _isProgrammaticMove = true;
    _mapController!.animateCamera(
      CameraUpdate.newCameraPosition(
        CameraPosition(
          target: LatLng(widget.originLat!, widget.originLng!),
          zoom: _initialZoom,
        ),
      ),
    );
  }

  /// Adatta la camera per mostrare TUTTI i punti (percorso pianificato + camminato).
  ///
  /// Usata nella review post-arrivo: l'utente vede sia la linea blu
  /// (percorso pianificato) sia la linea verde (percorso effettuato)
  /// in un'unica vista panoramica con tilt=0 e bearing=0.
  void fitAllPoints() {
    if (_mapController == null) return;

    final List<LatLng> allPoints = [];

    // Aggiungi punti del percorso pianificato
    if (widget.encodedPolyline != null && widget.encodedPolyline!.isNotEmpty) {
      allPoints.addAll(_decodePolyline(widget.encodedPolyline!));
    }

    // Aggiungi punti del percorso effettuato
    if (widget.walkedPath != null) {
      allPoints.addAll(widget.walkedPath!);
    }

    if (allPoints.length < 2) return;

    // Calcola i bounds che contengono tutti i punti
    double minLat = allPoints.first.latitude;
    double maxLat = allPoints.first.latitude;
    double minLng = allPoints.first.longitude;
    double maxLng = allPoints.first.longitude;

    for (final point in allPoints) {
      if (point.latitude < minLat) minLat = point.latitude;
      if (point.latitude > maxLat) maxLat = point.latitude;
      if (point.longitude < minLng) minLng = point.longitude;
      if (point.longitude > maxLng) maxLng = point.longitude;
    }

    _isProgrammaticMove = true;
    _mapController!.animateCamera(
      CameraUpdate.newLatLngBounds(
        LatLngBounds(
          southwest: LatLng(minLat, minLng),
          northeast: LatLng(maxLat, maxLng),
        ),
        60, // padding in pixel
      ),
    );
  }

  /// Decodifica una polyline codificata nel formato di Google
  ///
  /// La polyline è una stringa compatta che rappresenta una serie di coordinate.
  /// Algoritmo: https://developers.google.com/maps/documentation/utilities/polylinealgorithm
  List<LatLng> _decodePolyline(String encoded) {
    List<LatLng> points = [];
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
      points.add(LatLng(lat / 1E5, lng / 1E5));
    }

    return points;
  }

  @override
  Widget build(BuildContext context) {
    // Unisce i marker del percorso, il marker freccia utente, chevron e frecce grandi.
    // In navigazione: routeMarkers + userArrowMarker + chevronMarkers + bigArrowMarkers
    // Fuori navigazione: routeMarkers + pallino blu di Google (myLocationEnabled)
    final Set<Marker> allMarkers = {
      ..._routeMarkers,
      ..._chevronMarkers,
      ..._bigArrowMarkers,
      if (_userArrowMarker != null) _userArrowMarker!,
    };

    return GoogleMap(
      // Stile mappa bianco classico con POI visibili (stile accessibile).
      style: _accessibleMapStyle,
      // Callback quando la mappa è pronta
      onMapCreated: _onMapCreated,
      // Posizione iniziale della camera
      initialCameraPosition: const CameraPosition(
        target: _initialPosition,
        zoom: _initialZoom,
      ),
      // Marker sulla mappa (percorso + freccia utente)
      markers: allMarkers,
      // Polyline sulla mappa
      polylines: Set<Polyline>.of(_polylines),
      // Abilita zoom e rotazione
      zoomControlsEnabled: false,

      // --- PALLINO BLU DI GOOGLE ---
      // In navigazione: DISABILITATO perché usiamo la freccia arancione custom
      // che è più grande, più visibile e mostra la direzione.
      // Fuori navigazione: ABILITATO (pallino blu standard, sufficiente).
      myLocationEnabled: !widget.isNavigating,
      myLocationButtonEnabled: false, // Usiamo il tasto Recenter custom
      // Tipo di mappa
      mapType: MapType.normal,

      // --- RILEVAMENTO PAN MANUALE ---
      onCameraMoveStarted: () {
        if (!_isProgrammaticMove) {
          widget.onUserInteraction?.call();
        }
      },
      onCameraIdle: () {
        _isProgrammaticMove = false;
      },

      // --- TASK 3: GESTIONE TAP SULLA MAPPA ---
      onTap: widget.onMapTap,
    );
  }
}
