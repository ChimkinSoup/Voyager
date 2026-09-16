import 'package:drift/drift.dart' show OrderingTerm;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/sync/firestore_write_gate.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/firestore_sync_repository.dart';

/// How deep the unsent write queue is, which is otherwise invisible.
///
/// Firestore accepts a write locally and only reports it as done once the
/// server acknowledges it, with no way to ask how many are waiting. An
/// afternoon on bad wifi can therefore strand hundreds of writes — including
/// whole journal entries — with nothing on screen saying so, right up until
/// the backend starts refusing the write stream outright. This is that reading.
class DevSyncBacklogSection extends ConsumerWidget {
  const DevSyncBacklogSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repository = ref.watch(syncRepositoryProvider);
    if (repository is! FirestoreSyncRepository) {
      return const ListTile(
        leading: Icon(PhosphorIconsRegular.cloudSlash),
        title: Text('Sync backlog'),
        subtitle: Text('Signed out — nothing is queued.'),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListenableBuilder(
          listenable: repository.writeGate,
          builder: (context, _) => _WriteGateSummary(gate: repository.writeGate),
        ),
        const SizedBox(height: 8),
        _OutboxSummary(db: ref.watch(databaseProvider)),
      ],
    );
  }
}

class _WriteGateSummary extends StatelessWidget {
  const _WriteGateSummary({required this.gate});

  final FirestoreWriteGate gate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (icon, colour, headline) = switch (gate) {
      _ when gate.isStalled => (
        PhosphorIconsRegular.plugsConnected,
        theme.colorScheme.error,
        'Stalled — a write went unacknowledged; waiting for the queue to move',
      ),
      _ when gate.isPaused => (
        PhosphorIconsRegular.pauseCircle,
        theme.colorScheme.error,
        'Paused — writes are going to the outbox',
      ),
      _ when gate.hasStartupBacklog => (
        PhosphorIconsRegular.warningCircle,
        Colors.orangeAccent,
        'Writes from an earlier session are still unsent',
      ),
      _ => (
        PhosphorIconsRegular.checkCircle,
        Colors.greenAccent,
        'Keeping up',
      ),
    };

    return ListTile(
      leading: Icon(icon, color: colour),
      title: Text('Unsent writes: ${gate.inFlight} / ${gate.limit}'),
      subtitle: Text(
        '$headline\n'
        'Peak this session ${gate.peakInFlight} · '
        'deferred to outbox ${gate.refusedWrites} · '
        'timed out ${gate.timedOutWrites}',
      ),
      isThreeLine: true,
    );
  }
}

class _OutboxSummary extends StatelessWidget {
  const _OutboxSummary({required this.db});

  final AppDatabase db;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<PendingUploadData>>(
      stream:
          (db.select(db.pendingUploadsTable)
                ..orderBy([(t) => OrderingTerm.asc(t.addedAt)]))
              .watch(),
      builder: (context, snapshot) {
        final rows = snapshot.data ?? const <PendingUploadData>[];
        final parked = rows.where((r) => r.failureReason != null).length;
        final queued = rows.length - parked;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ListTile(
              leading: const Icon(PhosphorIconsRegular.tray),
              title: Text('Outbox: $queued queued, $parked parked'),
              subtitle: Text(
                queued == 0 && parked == 0
                    ? 'Nothing waiting to be re-sent.'
                    : 'Queued rows retry automatically; parked ones were '
                          'refused for a reason that will not change.',
              ),
            ),
            for (final row in rows.take(8))
              Padding(
                padding: const EdgeInsets.only(left: 56, right: 16, bottom: 4),
                child: Text(
                  '${row.collectionName}/${row.documentId}'
                  '${row.failureReason == null ? '' : ' — ${row.failureReason}'}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            if (rows.length > 8)
              Padding(
                padding: const EdgeInsets.only(left: 56, right: 16),
                child: Text(
                  '…and ${rows.length - 8} more',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
          ],
        );
      },
    );
  }
}
