/// main.dart - Entry point dell'applicazione Navigation App
///
/// Questo file configura il tema dell'app e avvia la NavigationScreen.
library;

import 'package:flutter/material.dart';
import 'package:google_maps_flutter_android/google_maps_flutter_android.dart';
import 'package:google_maps_flutter_platform_interface/google_maps_flutter_platform_interface.dart';
import 'screens/navigation_screen.dart';

/// Entry point dell'applicazione
void main() async {
  // Necessario per inizializzare i binding prima di usare plugin
  WidgetsFlutterBinding.ensureInitialized();

  // Inizializza il renderer Google Maps su Android.
  final GoogleMapsFlutterPlatform platform = GoogleMapsFlutterPlatform.instance;
  if (platform is GoogleMapsFlutterAndroid) {
    // Forza Hybrid Composition per compatibilità con Impeller (Vulkan).
    // Senza questo, la PlatformView nativa di Google Maps non si inizializza
    // su dispositivi che usano Impeller come rendering backend.
    platform.useAndroidViewSurface = true;

    // Usa il renderer LATEST (vettoriale), compatibile con Impeller.
    // Il renderer LEGACY è deprecato e viene ignorato dall'SDK.
    final AndroidMapRenderer renderer = await platform.initializeWithRenderer(
      AndroidMapRenderer.latest,
    );
    print('=== Google Maps renderer inizializzato: $renderer ===');
  }

  runApp(const NavigationApp());
}

/// Widget root dell'applicazione
class NavigationApp extends StatelessWidget {
  const NavigationApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      // Titolo dell'app (visibile nella tab del browser)
      title: 'Navigation App',

      // Nasconde il banner di debug
      debugShowCheckedModeBanner: false,

      // Tema dell'applicazione
      theme: ThemeData(
        // Schema colori basato su blu
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blue,
          brightness: Brightness.light,
        ),

        // Abilita Material Design 3
        useMaterial3: true,

        // Font dell'app
        fontFamily: 'Roboto',

        // Stile AppBar
        appBarTheme: const AppBarTheme(centerTitle: true, elevation: 0),

        // Stile pulsanti
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            elevation: 2,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        ),

        // Stile input
        inputDecorationTheme: InputDecorationTheme(
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 14,
          ),
        ),
      ),

      // Schermata iniziale
      home: const NavigationScreen(),
    );
  }
}
