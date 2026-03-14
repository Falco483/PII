import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:pii2/widgets/search_input.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({
      'search_history_v1': jsonEncode([
        {'address': 'Via Roma 1', 'lat': 45.0, 'lng': 9.0, 'timestamp': 1000},
        {
          'address': 'Via Torino 10',
          'lat': 45.1,
          'lng': 9.1,
          'timestamp': 3000,
        },
        {
          'address': 'Duomo Milano',
          'lat': 45.4642,
          'lng': 9.19,
          'timestamp': 2000,
        },
      ]),
    });
  });

  testWidgets('focus sul campo mostra cronologia ordinata per timestamp', (
    tester,
  ) async {
    final controller = TextEditingController();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SearchInput(
            destinationController: controller,
            onDestinationSelected: (_, __, ___) {},
          ),
        ),
      ),
    );

    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();

    final tiles = tester.widgetList<ListTile>(find.byType(ListTile)).toList();

    expect(tiles.length, 3);
    expect((tiles[0].title as Text).data, 'Via Torino 10');
    expect((tiles[1].title as Text).data, 'Duomo Milano');
    expect((tiles[2].title as Text).data, 'Via Roma 1');
  });

  testWidgets(
    'input con meno di 3 caratteri filtra la cronologia per contenuto',
    (tester) async {
      final controller = TextEditingController();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SearchInput(
              destinationController: controller,
              onDestinationSelected: (_, __, ___) {},
            ),
          ),
        ),
      );

      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'to');
      await tester.pumpAndSettle();

      expect(find.text('Via Torino 10'), findsOneWidget);
      expect(find.text('Duomo Milano'), findsNothing);
      expect(find.text('Via Roma 1'), findsNothing);
    },
  );

  testWidgets('tap su suggerimento cronologia invoca callback destinazione', (
    tester,
  ) async {
    final controller = TextEditingController();
    double? selectedLat;
    double? selectedLng;
    String? selectedAddress;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SearchInput(
            destinationController: controller,
            onDestinationSelected: (lat, lng, address) {
              selectedLat = lat;
              selectedLng = lng;
              selectedAddress = address;
            },
          ),
        ),
      ),
    );

    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Via Torino 10'));
    await tester.pumpAndSettle();

    expect(selectedLat, 45.1);
    expect(selectedLng, 9.1);
    expect(selectedAddress, 'Via Torino 10');
    expect(controller.text, 'Via Torino 10');
  });

  testWidgets('pulsante Cancella cronologia svuota suggerimenti history', (
    tester,
  ) async {
    final controller = TextEditingController();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SearchInput(
            destinationController: controller,
            onDestinationSelected: (_, __, ___) {},
          ),
        ),
      ),
    );

    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();

    expect(find.text('Via Torino 10'), findsOneWidget);
    expect(find.text('Cancella cronologia'), findsOneWidget);

    await tester.tap(find.text('Cancella cronologia'));
    await tester.pumpAndSettle();

    expect(find.text('Via Torino 10'), findsNothing);
    expect(find.text('Duomo Milano'), findsNothing);
    expect(find.text('Via Roma 1'), findsNothing);
  });
}
