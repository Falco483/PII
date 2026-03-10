import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

class TestMapScreen extends StatelessWidget {
  const TestMapScreen({super.key});

  // Posizione iniziale (Milano)
  static const LatLng _initialPosition = LatLng(45.4836, 9.2249);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Test Google Map')),
      body: SizedBox(
        height: double.infinity,
        width: double.infinity,
        child: GoogleMap(
          initialCameraPosition: const CameraPosition(
            target: _initialPosition,
            zoom: 10,
          ),
          mapType: MapType.normal,
          zoomControlsEnabled: true,
          myLocationEnabled: true,
          myLocationButtonEnabled: true,
          onMapCreated: (GoogleMapController controller) {
            print('=== GOOGLE MAP CREATED SUCCESSFULLY ===');
          },
          onTap: (LatLng pos) {
            print('Tapped at: ${pos.latitude}, ${pos.longitude}');
          },
        ),
      ),
    );
  }
}
