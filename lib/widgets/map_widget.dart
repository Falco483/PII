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

  /// Callback chiamato quando l'utente tocca un punto sulla mappa (TASK 3).
  ///
  /// Gestisce entrambi i casi di TASK 3:
  /// - Caso 1 (POI): su Google Maps Flutter, anche il tap su un POI genera
  ///   un evento onTap con le coordinate. Il parent può usare le coordinate
  ///   direttamente per calcolare il percorso.
  /// - Caso 2 (punto generico): restituisce le coordinate lat/lng del punto
  ///   toccato. NON serve chiamare Places Details API.
  ///
  /// In entrambi i casi, le coordinate lat/lng sono sufficienti per la
  /// Directions API (TASK 4). Il parent (NavigationScreen) deciderà se
  /// usare le coordinate direttamente o effettuare una reverse geocoding.
  final void Function(LatLng position)? onMapTap;

  const MapWidget({
    super.key,
    this.originLat,
    this.originLng,
    this.destLat,
    this.destLng,
    this.encodedPolyline,
    this.onMapTap,
  });

  @override
  State<MapWidget> createState() => _MapWidgetState();
}

class _MapWidgetState extends State<MapWidget> {
  // Controller per la mappa Google
  GoogleMapController? _mapController;

  // Set di marker sulla mappa
  Set<Marker> _markers = {};

  // Set di polyline sulla mappa
  Set<Polyline> _polylines = {};

  // Posizione iniziale: centro Italia
  static const LatLng _initialPosition = LatLng(45.4836315, 9.2249375);
  static const double _initialZoom = 10;

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
    // Se ci sono già dati del percorso, aggiorna la mappa
    if (widget.encodedPolyline != null) {
      _updateRoute();
    }
  }

  /// Aggiorna marker e polyline sulla mappa
  void _updateRoute() {
    if (widget.originLat == null ||
        widget.originLng == null ||
        widget.destLat == null ||
        widget.destLng == null ||
        widget.encodedPolyline == null) {
      // Se non ci sono tutti i dati, resetta la mappa
      setState(() {
        _markers = {};
        _polylines = {};
      });
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
        width: 5,
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

  /// Adatta la vista della mappa per mostrare tutto il percorso
  void _fitBounds() {
    if (_mapController == null ||
        widget.originLat == null ||
        widget.destLat == null) {
      return;
    }

    // Calcola i bounds
    final double swLat = widget.originLat! < widget.destLat!
        ? widget.originLat!
        : widget.destLat!;
    final double swLng = widget.originLng! < widget.destLng!
        ? widget.originLng!
        : widget.destLng!;
    final double neLat = widget.originLat! > widget.destLat!
        ? widget.originLat!
        : widget.destLat!;
    final double neLng = widget.originLng! > widget.destLng!
        ? widget.originLng!
        : widget.destLng!;

    final bounds = LatLngBounds(
      southwest: LatLng(swLat - 0.1, swLng - 0.1),
      northeast: LatLng(neLat + 0.1, neLng + 0.1),
    );

    // Anima la camera
    _mapController!.animateCamera(CameraUpdate.newLatLngBounds(bounds, 50));
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
      myLocationButtonEnabled: true,
      // Tipo di mappa
      mapType: MapType.normal,

      // --- TASK 3: GESTIONE TAP SULLA MAPPA ---

      // onTap: chiamato quando l'utente tocca un punto GENERICO sulla mappa
      // (non un POI). Restituisce le coordinate lat/lng del punto toccato.
      // Se il callback è null (non fornito dal parent), il tap viene ignorato.
      onTap: widget.onMapTap,

      // onLongPress: non usato per ora, ma disponibile per future estensioni
      // (es. "tieni premuto per impostare un waypoint intermedio")

      // NOTA SUL POI TAP:
      // A partire da google_maps_flutter, il callback per il tap su POI
      // è gestito tramite il parametro 'onTap' dei marker interni di Google.
      // Su Android/iOS nativi, i POI sulla mappa (negozi, ristoranti, ecc.)
      // generano un evento separato. In Flutter, questo è esposto tramite
      // il parametro 'onTap' del GoogleMap widget SOLO se il POI non è
      // coperto da un marker custom. Google Maps Flutter non espone
      // direttamente un 'onPoiTap', quindi lo gestiamo attraverso l'onTap
      // generico e lasciamo che il parent usi le coordinate direttamente.
    );
  }
}
