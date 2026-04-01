/// navigation_history_debug_screen.dart - Schermata debug per la cronologia navigazione.
///
/// Mostra tutte le sessioni di navigazione salvate in SharedPreferences,
/// Accessibile solo via debug button.
library;

import 'package:flutter/material.dart';
import '../../models/navigation_session.dart';
import '../../services/navigation_session_service.dart';

class NavigationHistoryDebugScreen extends StatefulWidget {
  const NavigationHistoryDebugScreen({super.key});

  @override
  State<NavigationHistoryDebugScreen> createState() =>
      _NavigationHistoryDebugScreenState();
}

class _NavigationHistoryDebugScreenState
    extends State<NavigationHistoryDebugScreen> {
  List<NavigationSession> _sessions = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  Future<void> _loadHistory() async {
    final service = NavigationSessionService();
    final sessions = await service.getHistory();
    print('🔍 NavigationHistoryDebugScreen: Loaded ${sessions.length} sessions');
    for (var s in sessions) {
      print('   → ID: ${s.sessionId}, Overlay: ${s.overlays.length}, Ricalcoli: ${s.rerouteCount}');
    }
    if (mounted) {
      setState(() {
        _sessions = sessions;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Cronologia Navigazione'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Ricarica',
            onPressed: () {
              setState(() => _loading = true);
              _loadHistory();
            },
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_sessions.isEmpty) {
      return const _EmptyState();
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: _sessions.length,
      itemBuilder: (context, index) => _SessionCard(session: _sessions[index]),
    );
  }
}

// ── Session Card ──────────────────────────────────────────────────────────────

class _SessionCard extends StatelessWidget {
  final NavigationSession session;

  const _SessionCard({required this.session});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Destinazione + stato
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    session.destination.isNotEmpty
                        ? session.destination
                        : '(destinazione sconosciuta)',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                _StatusChip(reached: session.destinationReached),
              ],
            ),
            const SizedBox(height: 10),

            // Orari
            _InfoRow(
              icon: Icons.schedule,
              label: 'Inizio',
              value: _formatTime(session.startTime),
            ),
            if (session.endTime != null) ...[
              _InfoRow(
                icon: Icons.flag,
                label: 'Fine',
                value: _formatTime(session.endTime!),
              ),
              _InfoRow(
                icon: Icons.timer,
                label: 'Durata',
                value: _formatDuration(session.startTime, session.endTime!),
              ),
            ],
            const SizedBox(height: 8),

            // Statistiche
            Row(
              children: [
                _StatBadge(
                  icon: Icons.route,
                  value: '${session.rerouteCount}',
                  label: 'ricalcoli',
                ),
                const SizedBox(width: 8),
                _StatBadge(
                  icon: Icons.layers,
                  value: '${session.overlays.length}',
                  label: 'overlay',
                ),
              ],
            ),

            // Lista overlay espandibile
            if (session.overlays.isNotEmpty) ...[
              const SizedBox(height: 4),
              _OverlaysList(overlays: session.overlays),
            ],

            // Session ID
            const SizedBox(height: 8),
            Text(
              'ID: ${session.sessionId}',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Status Chip ───────────────────────────────────────────────────────────────

class _StatusChip extends StatelessWidget {
  final bool reached;

  const _StatusChip({required this.reached});

  @override
  Widget build(BuildContext context) {
    final bg = reached ? Colors.green.shade100 : Colors.red.shade100;
    final fg = reached ? Colors.green.shade800 : Colors.red.shade800;
    final label = reached ? 'Raggiunta' : 'Interrotta';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: fg,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

// ── Info Row ──────────────────────────────────────────────────────────────────

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _InfoRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Row(
        children: [
          Icon(
            icon,
            size: 14,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 6),
          Text(
            '$label: ',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Stat Badge ────────────────────────────────────────────────────────────────

class _StatBadge extends StatelessWidget {
  final IconData icon;
  final String value;
  final String label;

  const _StatBadge({
    required this.icon,
    required this.value,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: theme.colorScheme.outlineVariant,
          width: 1,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: theme.colorScheme.primary),
          const SizedBox(width: 4),
          Text(
            value,
            style: theme.textTheme.labelMedium?.copyWith(
              fontWeight: FontWeight.bold,
              color: theme.colorScheme.primary,
            ),
          ),
          const SizedBox(width: 3),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Overlays List ─────────────────────────────────────────────────────────────

class _OverlaysList extends StatelessWidget {
  final List<OverlayRecord> overlays;

  const _OverlaysList({required this.overlays});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Theme(
      data: theme.copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        title: Text(
          '${overlays.length} overlay registrat${overlays.length == 1 ? 'o' : 'i'}',
          style: theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        children: [
          ListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: overlays.length,
            itemBuilder: (context, index) =>
                _OverlayTile(record: overlays[index]),
          ),
        ],
      ),
    );
  }
}

// ── Overlay Tile ──────────────────────────────────────────────────────────────

class _OverlayTile extends StatelessWidget {
  final OverlayRecord record;

  const _OverlayTile({required this.record});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isTurn = record.type == 'turnInstruction';
    final icon = isTurn ? Icons.turn_right : Icons.warning_amber;
    final iconColor = isTurn
        ? theme.colorScheme.primary
        : Colors.orange.shade700;

    return ListTile(
      visualDensity: VisualDensity.compact,
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      leading: Icon(icon, size: 20, color: iconColor),
      title: Text(
        record.message,
        style: theme.textTheme.bodySmall,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        _formatTime(record.timestamp),
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

// ── Empty State ───────────────────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.history,
              size: 64,
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
            ),
            const SizedBox(height: 16),
            Text(
              'Nessuna sessione registrata',
              style: theme.textTheme.titleMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Avvia una navigazione per iniziare\na registrare la cronologia.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Formatting helpers ────────────────────────────────────────────────────────

String _formatTime(String iso) {
  if (iso.isEmpty) return '—';
  try {
    final dt = DateTime.parse(iso).toLocal();
    final d = dt.day.toString().padLeft(2, '0');
    final mo = dt.month.toString().padLeft(2, '0');
    final h = dt.hour.toString().padLeft(2, '0');
    final mi = dt.minute.toString().padLeft(2, '0');
    final s = dt.second.toString().padLeft(2, '0');
    return '$d/$mo/${dt.year} $h:$mi:$s';
  } catch (_) {
    return iso;
  }
}

String _formatDuration(String startIso, String endIso) {
  try {
    final start = DateTime.parse(startIso);
    final end = DateTime.parse(endIso);
    final diff = end.difference(start);
    if (diff.isNegative) return '—';

    final h = diff.inHours;
    final m = diff.inMinutes.remainder(60);
    final s = diff.inSeconds.remainder(60);

    if (h > 0) return '${h}h ${m}m';
    if (m > 0) return '${m}m ${s}s';
    return '${s}s';
  } catch (_) {
    return '—';
  }
}
