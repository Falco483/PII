// Test base per NavigationApp
//
// Verifica che l'app si avvii correttamente.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pii/main.dart';

void main() {
  testWidgets('App si avvia correttamente', (WidgetTester tester) async {
    // Costruisce l'app
    await tester.pumpWidget(NavigationApp(navigatorKey: GlobalKey<NavigatorState>()));

    // Verifica che il titolo sia visibile
    expect(find.text('La mia mappa'), findsOneWidget);
  });
}
