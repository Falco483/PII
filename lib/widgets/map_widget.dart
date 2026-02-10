/// MapWidget - Widget per visualizzare la mappa Google Maps
///
/// Questo widget mostra una mappa Google Maps con marker per
/// origine/destinazione e una polyline per il percorso.
/// Compatibile con Android, iOS e Web.

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

  const MapWidget({
    super.key,
    this.originLat,
    this.originLng,
    this.destLat,
    this.destLng,
    this.encodedPolyline,
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
  static const LatLng _initialPosition = LatLng(42.5, 12.5);
  static const double _initialZoom = 6.0;

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
      myLocationEnabled: false,
      myLocationButtonEnabled: false,
      // Tipo di mappa
      mapType: MapType.normal,
    );
  }
}
