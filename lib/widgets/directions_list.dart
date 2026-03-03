/// DirectionsList - Widget per visualizzare le indicazioni passo-passo
///
/// Mostra una lista scrollabile delle indicazioni con icone,
/// distanza e durata per ogni step.
library;

import 'package:flutter/material.dart';
import '../services/directions_service.dart';

/// Widget che visualizza la lista delle indicazioni stradali
class DirectionsList extends StatelessWidget {
  // Lista degli step da visualizzare
  final List<DirectionStep> steps;
  // Distanza totale del percorso
  final String totalDistance;
  // Durata totale del percorso
  final String totalDuration;

  const DirectionsList({
    super.key,
    required this.steps,
    required this.totalDistance,
    required this.totalDuration,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      // Stile del contenitore
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header con riepilogo totale
          _buildHeader(),

          // Lista degli step
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: steps.length,
              // Separatore tra gli step
              separatorBuilder: (context, index) => const Divider(height: 1),
              itemBuilder: (context, index) => _buildStepTile(index),
            ),
          ),
        ],
      ),
    );
  }

  /// Costruisce l'header con il riepilogo del percorso
  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.blue.shade50,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
      ),
      child: Row(
        children: [
          // Icona auto
          Icon(Icons.directions_car, color: Colors.blue.shade700, size: 32),
          const SizedBox(width: 12),
          // Informazioni percorso
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                totalDuration,
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: Colors.blue.shade900,
                ),
              ),
              Text(
                totalDistance,
                style: TextStyle(fontSize: 14, color: Colors.blue.shade700),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Costruisce un singolo tile per uno step
  Widget _buildStepTile(int index) {
    final step = steps[index];

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Numero dello step
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: Colors.blue,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Center(
              child: Text(
                '${index + 1}',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          // Istruzione e dettagli
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Istruzione testuale
                Text(
                  step.instruction,
                  style: const TextStyle(fontSize: 14, height: 1.4),
                ),
                const SizedBox(height: 4),
                // Distanza e durata
                Row(
                  children: [
                    _buildInfoChip(Icons.straighten, step.distance),
                    const SizedBox(width: 8),
                    _buildInfoChip(Icons.access_time, step.duration),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Costruisce un chip informativo con icona e testo
  Widget _buildInfoChip(IconData icon, String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.grey.shade100,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: Colors.grey.shade600),
          const SizedBox(width: 4),
          Text(
            text,
            style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
          ),
        ],
      ),
    );
  }
}
