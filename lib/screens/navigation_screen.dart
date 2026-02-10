/// NavigationScreen - Schermata principale dell'app di navigazione
///
/// Questa schermata combina tutti i widget (mappa, input ricerca, lista indicazioni)
/// e gestisce lo state dell'applicazione.

import 'package:flutter/material.dart';
import '../services/directions_service.dart';
import '../widgets/map_widget.dart';
import '../widgets/search_input.dart';
import '../widgets/directions_list.dart';

/// Schermata principale per la navigazione
class NavigationScreen extends StatefulWidget {
  const NavigationScreen({super.key});

  @override
  State<NavigationScreen> createState() => _NavigationScreenState();
}

class _NavigationScreenState extends State<NavigationScreen> {
  // Controller per i campi di testo
  final TextEditingController _originController = TextEditingController();
  final TextEditingController _destinationController = TextEditingController();

  // Servizio per le direzioni
  final DirectionsService _directionsService = DirectionsService();

  // Stato dell'app
  DirectionsResult? _directionsResult; // Risultato del calcolo percorso
  bool _isLoading = false; // Flag caricamento
  String? _errorMessage; // Messaggio di errore

  @override
  void dispose() {
    _originController.dispose();
    _destinationController.dispose();
    super.dispose();
  }

  /// Calcola il percorso chiamando l'API
  Future<void> _calculateRoute() async {
    // Valida gli input
    if (_originController.text.isEmpty || _destinationController.text.isEmpty) {
      setState(() {
        _errorMessage = 'Inserisci sia la partenza che la destinazione';
      });
      return;
    }

    // Imposta lo stato di caricamento
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      // Chiama l'API per ottenere le direzioni
      final result = await _directionsService.getDirections(
        origin: _originController.text,
        destination: _destinationController.text,
      );

      // Aggiorna lo stato con il risultato
      setState(() {
        _isLoading = false;
        if (result != null) {
          _directionsResult = result;
          _errorMessage = null;
        } else {
          _errorMessage =
              'Impossibile calcolare il percorso. Verifica gli indirizzi inseriti.';
        }
      });
    } catch (e) {
      // Gestisce eventuali errori
      setState(() {
        _isLoading = false;
        _errorMessage = 'Errore: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // Determina se siamo su un dispositivo mobile (schermo stretto)
    final isMobile = MediaQuery.of(context).size.width < 800;

    return Scaffold(
      // App Bar
      appBar: AppBar(
        title: const Text('Navigation App'),
        backgroundColor: Colors.blue,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      // Corpo principale
      body: isMobile
          ? _buildMobileLayout() // Layout verticale per mobile
          : _buildDesktopLayout(), // Layout orizzontale per desktop
    );
  }

  /// Layout per dispositivi mobili (stack verticale)
  Widget _buildMobileLayout() {
    return Column(
      children: [
        // Pannello ricerca sempre visibile
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: SearchInput(
            originController: _originController,
            destinationController: _destinationController,
            onSearch: _calculateRoute,
            isLoading: _isLoading,
          ),
        ),

        // Messaggio di errore
        if (_errorMessage != null) _buildErrorMessage(),

        // Mappa
        Expanded(
          flex: 2,
          child: Padding(
            padding: const EdgeInsets.all(8.0),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: MapWidget(
                originLat: _directionsResult?.originLat,
                originLng: _directionsResult?.originLng,
                destLat: _directionsResult?.destLat,
                destLng: _directionsResult?.destLng,
                encodedPolyline: _directionsResult?.encodedPolyline,
              ),
            ),
          ),
        ),

        // Lista indicazioni (se disponibile)
        if (_directionsResult != null)
          Expanded(
            flex: 1,
            child: Padding(
              padding: const EdgeInsets.all(8.0),
              child: DirectionsList(
                steps: _directionsResult!.steps,
                totalDistance: _directionsResult!.totalDistance,
                totalDuration: _directionsResult!.totalDuration,
              ),
            ),
          ),
      ],
    );
  }

  /// Layout per desktop (pannello laterale)
  Widget _buildDesktopLayout() {
    return Row(
      children: [
        // Pannello laterale sinistro (ricerca + indicazioni)
        SizedBox(
          width: 380,
          child: Column(
            children: [
              // Input ricerca
              Padding(
                padding: const EdgeInsets.all(12.0),
                child: SearchInput(
                  originController: _originController,
                  destinationController: _destinationController,
                  onSearch: _calculateRoute,
                  isLoading: _isLoading,
                ),
              ),

              // Messaggio di errore
              if (_errorMessage != null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12.0),
                  child: _buildErrorMessage(),
                ),

              // Lista indicazioni (se disponibile)
              if (_directionsResult != null)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(12.0),
                    child: DirectionsList(
                      steps: _directionsResult!.steps,
                      totalDistance: _directionsResult!.totalDistance,
                      totalDuration: _directionsResult!.totalDuration,
                    ),
                  ),
                ),
            ],
          ),
        ),

        // Mappa (occupa il resto dello spazio)
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(12.0),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: MapWidget(
                originLat: _directionsResult?.originLat,
                originLng: _directionsResult?.originLng,
                destLat: _directionsResult?.destLat,
                destLng: _directionsResult?.destLng,
                encodedPolyline: _directionsResult?.encodedPolyline,
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// Widget per mostrare errori
  Widget _buildErrorMessage() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.red.shade50,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.red.shade200),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, color: Colors.red.shade700),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _errorMessage!,
              style: TextStyle(color: Colors.red.shade700),
            ),
          ),
        ],
      ),
    );
  }
}
