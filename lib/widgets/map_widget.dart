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
  /// Usato dal parent per sapere che il follow-mode è stato interrotto
  /// dall'interazione dell'utente e mostrare il tasto Recenter.
  final VoidCallback? onUserInteraction;

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
  });

  @override
  State<MapWidget> createState() => MapWidgetState();
}

class MapWidgetState extends State<MapWidget> {
  // Controller per la mappa Google
  GoogleMapController? _mapController;

  // Set di marker sulla mappa
  Set<Marker> _markers = {};

  // Set di polyline sulla mappa
  Set<Polyline> _polylines = {};

  /// Flag per distinguere i movimenti di camera programmatici (animateCamera)
  /// da quelli causati dal gesto dell'utente (pan/pinch).
  ///
  /// MECCANISMO:
  /// - Prima di ogni animateCamera(), settiamo _isProgrammaticMove = true
  /// - In onCameraMoveStarted, se _isProgrammaticMove è false → è un gesto utente
  /// - Il flag viene resettato in onCameraIdle
  bool _isProgrammaticMove = false;

  // Posizione iniziale: centro Italia
  static const LatLng _initialPosition = LatLng(45.4836315, 9.2249375);
  static const double _initialZoom = 15;

  @override
  void didUpdateWidget(MapWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Aggiorna la mappa quando cambiano i parametri
    if (widget.encodedPolyline != oldWidget.encodedPolyline ||
        widget.originLat != oldWidget.originLat ||
        widget.destLat != oldWidget.destLat) {
      _updateRoute();
    }
  }

  /// Callback quando la mappa è creata
  void _onMapCreated(GoogleMapController controller) {
    _mapController = controller;
    print('=== GOOGLE MAP CREATED SUCCESSFULLY ===');

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
  /// Chiamato dal parent:
  /// 1. Ad ogni aggiornamento GPS quando il follow-mode è attivo
  /// 2. Quando l'utente preme il tasto Recenter
  ///
  /// PARAMETRI:
  /// - [lat], [lng]: coordinate GPS correnti dell'utente
  /// - [bearing]: direzione di marcia in gradi (0-360, 0=Nord)
  void followUser(double lat, double lng, double bearing) {
    _isProgrammaticMove = true;
    _mapController?.animateCamera(
      CameraUpdate.newCameraPosition(
        CameraPosition(
          target: LatLng(lat, lng),
          zoom: 17.5, // Zoom ravvicinato per navigazione pedonale
          bearing: bearing, // Ruota la mappa nella direzione di marcia
          tilt: 45, // Prospettiva 3D inclinata
        ),
      ),
    );
  }

  /// Aggiorna marker e polyline sulla mappa
  void _updateRoute() {
    // TASK 5: State Synchronization e Memory Leaks
    // Ripuliamo esplicitamente le vecchie risorse per forzare lo smaltimento
    // dei renderer sul layer nativo di Google Maps prima di ricalcolare.
    _markers.clear();
    _polylines.clear();

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

    // Decodifica la polyline
    final List<LatLng> polylinePoints = _decodePolyline(
      widget.encodedPolyline!,
    );

    // Crea la polyline
    final Set<Polyline> polylines = {
      Polyline(
        polylineId: const PolylineId('route'),
        points: polylinePoints,
        color: Colors.blue,
        width: 6,
        geodesic: true,
        jointType: JointType.round,
        startCap: Cap.roundCap,
        endCap: Cap.roundCap,
      ),
    };

    // Aggiorna lo stato
    setState(() {
      _markers = markers;
      _polylines = polylines;
    });

    // Adatta la camera per mostrare tutto il percorso
    _fitBounds();
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
    return GoogleMap(
      // ID della mappa creata su Google Cloud Console.
      // Collega questa mappa allo stile cloud-based "mappa_di_prova".
      cloudMapId: '15a5f409195f86af602a6c32',
      // Callback quando la mappa è pronta
      onMapCreated: _onMapCreated,
      // Posizione iniziale della camera
      initialCameraPosition: const CameraPosition(
        target: _initialPosition,
        zoom: _initialZoom,
      ),
      // Marker sulla mappa
      markers: _markers,
      // Polyline sulla mappa
      polylines: _polylines,
      // Abilita zoom e rotazione
      zoomControlsEnabled: true,
      myLocationEnabled: true,
      myLocationButtonEnabled: false, // Disabilitato: usiamo il tasto Recenter custom
      // Tipo di mappa
      mapType: MapType.normal,

      // --- RILEVAMENTO PAN MANUALE ---
      // Quando l'utente inizia a spostare la mappa con il dito,
      // notifichiamo il parent per disattivare il follow-mode.
      onCameraMoveStarted: () {
        if (!_isProgrammaticMove) {
          // L'utente ha spostato la mappa manualmente → notifica il parent
          widget.onUserInteraction?.call();
        }
      },

      // Quando il movimento della camera si ferma, resettiamo il flag.
      onCameraIdle: () {
        _isProgrammaticMove = false;
      },

      // --- TASK 3: GESTIONE TAP SULLA MAPPA ---

      // onTap: chiamato quando l'utente tocca un punto GENERICO sulla mappa
      // (non un POI). Restituisce le coordinate lat/lng del punto toccato.
      // Se il callback è null (non fornito dal parent), il tap viene ignorato.
      onTap: widget.onMapTap,
    );
  }
}
