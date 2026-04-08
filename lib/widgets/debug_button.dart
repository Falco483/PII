/// debug_button.dart - Tasto di debug trascinabile, visibile solo in debug mode.
///
/// Viene inserito nell'Overlay di Flutter così rimane sempre in primo piano,
/// sopra dialogs, bottom sheets e qualsiasi altro widget.
library;

import 'package:flutter/material.dart';
import '../screens/debug/navigation_history_debug_screen.dart';

/// Inserisce il tasto di debug nell'Overlay dell'app.
/// Richiede l'OverlayState direttamente dal NavigatorState per evitare
/// problemi di contesto (il Navigator è esso stesso la radice dell'Overlay).
void insertDebugButton(
  OverlayState overlay,
  GlobalKey<NavigatorState> navigatorKey,
) {
  overlay.insert(
    OverlayEntry(
      builder: (_) => _DraggableDebugButton(navigatorKey: navigatorKey),
    ),
  );
  debugPrint('[DEBUG_BUTTON] Tasto di debug inserito nell\'overlay');
}

class _DraggableDebugButton extends StatefulWidget {
  final GlobalKey<NavigatorState> navigatorKey;

  const _DraggableDebugButton({required this.navigatorKey});

  @override
  State<_DraggableDebugButton> createState() => _DraggableDebugButtonState();
}

class _DraggableDebugButtonState extends State<_DraggableDebugButton> {
  // Posizione iniziale: angolo in basso a sinistra con margine
  double _x = 16;
  double _y = 120;

  void _onPanUpdate(DragUpdateDetails details) {
    setState(() {
      _x += details.delta.dx;
      _y += details.delta.dy;
    });
  }

  void _onTap() {
    final ctx = widget.navigatorKey.currentContext;
    if (ctx == null) return;
    showModalBottomSheet<void>(
      context: ctx,
      builder: (_) => _DebugMenuSheet(navigatorKey: widget.navigatorKey),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Positioned funziona direttamente dentro Overlay perché Overlay estende Stack
    return Positioned(
      left: _x,
      top: _y,
      child: GestureDetector(
        onPanUpdate: _onPanUpdate,
        onTap: _onTap,
        // Material evita che il tasto erediti stili inconsistenti da widget padre
        child: Material(
          color: Colors.transparent,
          child: Tooltip(
            message: 'Debug',
            child: Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.85),
                shape: BoxShape.circle,
                boxShadow: const [
                  BoxShadow(
                    color: Colors.black38,
                    blurRadius: 6,
                    offset: Offset(2, 2),
                  ),
                ],
              ),
              child: const Center(
                child: Icon(Icons.bug_report, color: Colors.white, size: 26),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DebugMenuSheet extends StatelessWidget {
  final GlobalKey<NavigatorState> navigatorKey;

  const _DebugMenuSheet({required this.navigatorKey});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              'Debug',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.history),
            title: const Text('Apri cronologia navigazione'),
            onTap: () {
              Navigator.pop(context);
              navigatorKey.currentState?.push(
                MaterialPageRoute<void>(
                  builder: (_) => const NavigationHistoryDebugScreen(),
                ),
              );
            },
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}
