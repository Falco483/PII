/// main.dart - Entry point dell'applicazione Navigation App
///
/// Questo file configura il tema dell'app e avvia la NavigationScreen.
library;

import 'package:flutter/material.dart';
import 'screens/navigation_screen.dart';

/// Entry point dell'applicazione
void main() {
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
