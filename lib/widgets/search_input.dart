/// SearchInput - Widget per l'input di partenza e destinazione
///
/// Fornisce due campi di testo per inserire l'indirizzo di partenza
/// e destinazione, più un pulsante per calcolare il percorso.
library;

import 'package:flutter/material.dart';

/// Widget per la ricerca del percorso
class SearchInput extends StatelessWidget {
  // Controller per il campo partenza
  final TextEditingController originController;
  // Controller per il campo destinazione
  final TextEditingController destinationController;
  // Callback quando si preme "Calcola Percorso"
  final VoidCallback onSearch;
  // Flag per mostrare il caricamento
  final bool isLoading;

  const SearchInput({
    super.key,
    required this.originController,
    required this.destinationController,
    required this.onSearch,
    this.isLoading = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
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
        mainAxisSize: MainAxisSize.min,
        children: [
          // Titolo
          Text(
            'Calcola Percorso',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: Colors.blue.shade800,
            ),
          ),
          const SizedBox(height: 16),

          // Campo partenza
          _buildTextField(
            controller: originController,
            label: 'Partenza',
            hint: 'es. Roma, Italia',
            icon: Icons.trip_origin,
            iconColor: Colors.green,
          ),
          const SizedBox(height: 12),

          // Campo destinazione
          _buildTextField(
            controller: destinationController,
            label: 'Destinazione',
            hint: 'es. Milano, Italia',
            icon: Icons.place,
            iconColor: Colors.red,
          ),
          const SizedBox(height: 16),

          // Pulsante calcola
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: isLoading ? null : onSearch,
              icon: isLoading
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                      ),
                    )
                  : const Icon(Icons.search),
              label: Text(
                isLoading ? 'Calcolo in corso...' : 'Calcola Percorso',
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blue,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Costruisce un TextField stilizzato
  Widget _buildTextField({
    required TextEditingController controller,
    required String label,
    required String hint,
    required IconData icon,
    required Color iconColor,
  }) {
    return TextField(
      controller: controller,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        prefixIcon: Icon(icon, color: iconColor),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: Colors.blue, width: 2),
        ),
        filled: true,
        fillColor: Colors.grey.shade50,
      ),
    );
  }
}
