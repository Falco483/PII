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
  // Se true, non usa Expanded e disabilita lo scroll interno
  final bool shrinkWrap;
  // Gestisce lo scroll (es. dentro DraggableScrollableSheet - obsoleto se shrinkWrap=true, ma lo teniamo)
  final ScrollController? scrollController;
  // Azione al click del tasto "Avvia"
  final VoidCallback? onStartPressed;

  const DirectionsList({
    super.key,
    required this.steps,
    required this.totalDistance,
    required this.totalDuration,
    this.shrinkWrap = false,
    this.scrollController,
    this.onStartPressed,
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
            color: Colors.black.withValues(alpha: 0.1),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: shrinkWrap ? MainAxisSize.min : MainAxisSize.max,
        children: [
          // Header con riepilogo totale
          _buildHeader(),

          // Lista degli step
          if (shrinkWrap) _buildList() else Expanded(child: _buildList()),
        ],
      ),
    );
  }

  Widget _buildList() {
    return ListView.separated(
      controller: scrollController,
      shrinkWrap: shrinkWrap,
      physics: shrinkWrap ? const NeverScrollableScrollPhysics() : null,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      itemCount: steps.length,
      // Separatore tra gli step
      separatorBuilder: (context, index) => const Divider(height: 1),
      itemBuilder: (context, index) => _buildStepTile(index),
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
          // Icona pedone — grande e colorata
          const Icon(Icons.directions_walk, color: Colors.blue, size: 40),
          const SizedBox(width: 12),
          // Informazioni percorso — font grandi per accessibilità
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  totalDuration,
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: Colors.blue.shade900,
                  ),
                ),
                Text(
                  totalDistance,
                  style: TextStyle(fontSize: 16, color: Colors.blue.shade700),
                ),
              ],
            ),
          ),
          // Pulsante Avvia — grande e chiaro
          if (onStartPressed != null)
            ElevatedButton.icon(
              onPressed: onStartPressed,
              icon: const Icon(Icons.navigation, size: 24),
              label: const Text(
                'Avvia',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blue.shade600,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                ),
              ),
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
          // Numero dello step — più grande per accessibilità
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: Colors.blue,
              borderRadius: BorderRadius.circular(18),
            ),
            child: Center(
              child: Text(
                '${index + 1}',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
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
                // Istruzione testuale — GRANDE per accessibilità cognitiva
                Text(
                  step.instruction,
                  style: const TextStyle(fontSize: 18, height: 1.4),
                ),
                const SizedBox(height: 6),
                // Distanza e durata — dimensioni leggibili
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
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.grey.shade100,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: Colors.grey.shade600),
          const SizedBox(width: 4),
          Text(
            text,
            style: TextStyle(fontSize: 14, color: Colors.grey.shade700),
          ),
        ],
      ),
    );
  }
}
