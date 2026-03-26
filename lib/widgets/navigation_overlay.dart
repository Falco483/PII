/// navigation_overlay.dart — Widget Overlay per le Istruzioni di Navigazione
///
/// Questo widget mostra un banner animato sulla mappa con due tipi di messaggio:
/// 1. Istruzione di svolta (quando l'utente è fermo su un waypoint del percorso)
/// 2. Messaggio "vai dritto" incoraggiante (quando vengono rilevate strade laterali)
///
/// DESIGN PER ACCESSIBILITÀ:
/// L'app è destinata a persone con disabilità cognitive, quindi l'overlay:
/// - Usa un font grande e leggibile
/// - Ha un contrasto elevato (sfondo colorato, testo bianco)
/// - Si auto-dismiss dopo N secondi (non richiede azione dell'utente)
/// - Può anche essere chiuso con un tap (per utenti che hanno già capito)
/// - Usa animazioni fade-in/fade-out dolci (non improvvise)
///
/// RESPONSABILITÀ:
/// Questo widget è SOLO responsabile della visualizzazione. La logica
/// che decide QUANDO e COSA mostrare è in navigation_monitor.dart.
library;

import 'dart:async';
import 'package:flutter/material.dart';
import '../services/navigation_monitor.dart';
import '../services/geo_utils.dart';

/// Widget che mostra l'overlay di navigazione sulla mappa.
///
/// UTILIZZO:
/// Va posizionato come figlio di uno Stack sopra la mappa:
/// ```dart
/// Stack(
///   children: [
///     GoogleMap(...),          // La mappa sotto
///     NavigationOverlay(       // L'overlay sopra
///       state: overlayState,
///       onDismiss: () { /* resetta lo stato */ },
///     ),
///   ],
/// )
/// ```
///
/// PARAMETRI:
/// - [state]: lo stato dell'overlay (tipo + messaggio). Se null, non mostra nulla.
/// - [onDismiss]: callback chiamato quando l'overlay viene chiuso (tap o timeout).
///   Il chiamante dovrebbe resettare lo stato a null.
class NavigationOverlay extends StatefulWidget {
  final NavigationOverlayState? state;
  final VoidCallback onDismiss;

  const NavigationOverlay({
    super.key,
    required this.state,
    required this.onDismiss,
  });

  @override
  State<NavigationOverlay> createState() => _NavigationOverlayState();
}

class _NavigationOverlayState extends State<NavigationOverlay>
    with SingleTickerProviderStateMixin {
  /// Controller per l'animazione fade-in/fade-out.
  ///
  /// Usiamo un AnimationController invece di un semplice AnimatedOpacity
  /// perché abbiamo bisogno di:
  /// 1. Controllare la durata dell'animazione separatamente
  /// 2. Avviare il fade-out prima del dismiss
  /// 3. Attendere che il fade-out sia completato prima di notificare onDismiss
  late AnimationController _animController;
  late Animation<double> _fadeAnimation;

  /// Timer CANCELLABILE per l'auto-dismiss.
  /// Dopo [kOverlayAutoDismissSeconds] secondi, l'overlay si chiude da solo.
  ///
  /// PERCHÉ Timer E NON Future.delayed:
  /// Future.delayed non è cancellabile. Se il monitor emette un nuovo overlay
  /// mentre il vecchio Future.delayed è ancora in coda, il vecchio callback
  /// scatta comunque e chiude prematuramente il nuovo overlay.
  /// Con Timer possiamo cancellare il countdown precedente ogni volta che
  /// arriva un nuovo overlay, resettando il conteggio da zero.
  Timer? _autoDismissTimer;
  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );
    _fadeAnimation = CurvedAnimation(
      parent: _animController,
      curve: Curves.easeInOut,
    );
  }

  @override
  void didUpdateWidget(NavigationOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);

    // Quando lo stato passa da null a non-null, avvia il fade-in
    if (widget.state != null && oldWidget.state == null) {
      _animController.forward();
      _startAutoDismissTimer();
    }
    // FIX: Quando lo stato passa da non-null a un ALTRO non-null
    // (il monitor ha emesso un nuovo overlay mentre il precedente era ancora
    // visibile), resettiamo il timer di auto-dismiss e assicuriamoci che
    // l'animazione sia in forward. Senza questo ramo, il vecchio timer
    // (non cancellabile con Future.delayed) poteva chiudere prematuramente
    // il nuovo overlay, e l'animazione restava nel suo stato corrente
    // senza mai fare forward sul nuovo messaggio.
    else if (widget.state != null && oldWidget.state != null) {
      _animController.forward();
      _startAutoDismissTimer();
    }
    // Quando lo stato passa da non-null a null, avvia il fade-out
    else if (widget.state == null && oldWidget.state != null) {
      _animController.reverse();
    }
  }

  /// Avvia il timer di auto-dismiss (CANCELLABILE).
  ///
  /// L'overlay si chiude automaticamente dopo kOverlayAutoDismissSeconds
  /// secondi. Questo è importante per:
  /// - Non richiedere un'azione esplicita all'utente
  /// - Evitare che l'overlay copra la mappa indefinitamente
  /// - Gestire il caso in cui l'utente non tocchi lo schermo
  ///
  /// Se un timer precedente è ancora attivo (es. il monitor ha emesso un
  /// nuovo overlay prima che il vecchio scadesse), viene cancellato e
  /// ricreato con il countdown pieno. Così il nuovo overlay ha sempre
  /// i suoi N secondi completi di visibilità.
  void _startAutoDismissTimer() {
    // Cancella un eventuale timer precedente ancora in corso
    _autoDismissTimer?.cancel();

    // L'overlay di arrivo resta visibile più a lungo (15 secondi)
    // perché è il momento di celebrazione: il ragazzo ha completato
    // il percorso e merita di godersi il messaggio di congratulazioni.
    // Gli altri overlay usano il timer standard (8 secondi).
    final int dismissSeconds =
        widget.state?.type == OverlayType.arrivalCelebration
            ? 15
            : kOverlayAutoDismissSeconds;

    _autoDismissTimer = Timer(
      Duration(seconds: dismissSeconds),
      () {
        // Verifica che il widget sia ancora montato (l'utente potrebbe
        // aver cambiato schermata durante il countdown)
        if (mounted && widget.state != null) {
          _dismiss();
        }
      },
    );
  }

  /// Chiude l'overlay con animazione fade-out e notifica il chiamante.
  ///
  /// Chiamato sia dal tap dell'utente che dal timer di auto-dismiss.
  void _dismiss() {
    // Cancella il timer di auto-dismiss per evitare un secondo _dismiss()
    // se l'utente chiude manualmente l'overlay prima dello scadere.
    _autoDismissTimer?.cancel();
    _autoDismissTimer = null;

    _animController.reverse().then((_) {
      // Notifica il chiamante SOLO dopo che il fade-out è completato.
      // Se chiamassimo onDismiss subito, lo stato verrebbe resettato
      // e l'overlay sparirebbe bruscamente senza animazione.
      if (mounted) {
        widget.onDismiss();
      }
    });
  }

  @override
  void dispose() {
    _autoDismissTimer?.cancel();
    _animController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Se non c'è nessuno stato, non mostra nulla.
    // Usiamo un SizedBox.shrink() invece di un Container vuoto
    // per non occupare spazio nel layout.
    if (widget.state == null) {
      return const SizedBox.shrink();
    }

    final overlayState = widget.state!;

    return Positioned(
      // Posizionato in cima alla mappa, centrato orizzontalmente
      top: 24,
      left: 16,
      right: 16,
      child: FadeTransition(
        opacity: _fadeAnimation,
        child: GestureDetector(
          // Tap to dismiss: l'utente può chiudere l'overlay toccandolo
          onTap: _dismiss,
          child: _buildOverlayCard(overlayState),
        ),
      ),
    );
  }

  /// Costruisce il widget card dell'overlay.
  ///
  /// Lo stile varia in base al tipo di overlay:
  /// - Istruzione di svolta: sfondo blu, icona della manovra
  /// - Strada laterale: sfondo arancione/rosso, icona freccia dritta
  /// - Arrivo a destinazione: sfondo verde brillante, icona stella
  Widget _buildOverlayCard(NavigationOverlayState overlayState) {
    // Determina colori e icona in base al tipo di overlay
    final Color backgroundColor;
    final IconData icon;

    switch (overlayState.type) {
      case OverlayType.turnInstruction:
        backgroundColor = Colors.blue.shade700;
        icon = _getManeuverIcon(overlayState.maneuver);
        break;
      case OverlayType.lateralRoadDetected:
        backgroundColor = Colors.orange.shade800;
        icon = Icons.arrow_upward;
        break;
      case OverlayType.arrivalCelebration:
        backgroundColor = Colors.green.shade700;
        icon = Icons.emoji_events;
        break;
    }

    return Container(
      padding: EdgeInsets.all(
        overlayState.type == OverlayType.arrivalCelebration ? 24 : 20,
      ),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.3),
            blurRadius: 12,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Row(
        children: [
          // Icona — più grande per l'arrivo
          Icon(
            icon,
            color: Colors.white,
            size: overlayState.type == OverlayType.arrivalCelebration ? 56 : 40,
          ),
          const SizedBox(width: 16),
          // Testo del messaggio — più grande per l'arrivo
          Expanded(
            child: Text(
              overlayState.message,
              style: TextStyle(
                color: Colors.white,
                fontSize: overlayState.type == OverlayType.arrivalCelebration
                    ? 26
                    : 22,
                fontWeight: FontWeight.bold,
                height: 1.3,
              ),
            ),
          ),
          // Pulsante close (X)
          IconButton(
            icon: const Icon(Icons.close, color: Colors.white70, size: 24),
            onPressed: _dismiss,
          ),
        ],
      ),
    );
  }

  /// Restituisce l'icona Material appropriata per il codice maneuver.
  ///
  /// Mappa i codici maneuver della Directions API a icone Material Design.
  /// Se il codice non è riconosciuto o è null, restituisce un'icona generica.
  ///
  /// PARAMETRI:
  /// - [maneuver]: codice della manovra (es. "turn-left", "roundabout-right")
  ///
  /// RETURN: IconData appropriato per la manovra
  IconData _getManeuverIcon(String? maneuver) {
    if (maneuver == null) return Icons.navigation;

    // Mappa i codici maneuver alle icone Material.
    // Usiamo contains per raggruppare varianti simili.
    if (maneuver.contains('left')) {
      return Icons.turn_left;
    } else if (maneuver.contains('right')) {
      return Icons.turn_right;
    } else if (maneuver.contains('uturn')) {
      return Icons.u_turn_left;
    } else if (maneuver.contains('roundabout')) {
      return Icons.roundabout_left;
    } else if (maneuver == 'straight') {
      return Icons.arrow_upward;
    } else if (maneuver.contains('merge')) {
      return Icons.merge;
    } else if (maneuver.contains('fork')) {
      return Icons.fork_right;
    } else if (maneuver.contains('ramp')) {
      return Icons.ramp_right;
    }

    // Icona di default per manovre non riconosciute
    return Icons.navigation;
  }
}
