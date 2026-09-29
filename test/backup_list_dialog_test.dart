import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/sync/pending_flush_registry.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/features/settings/backup_list_dialog.dart';
import 'package:voyager/features/settings/services/auto_backup_service.dart';
import 'package:voyager/features/settings/services/data_export_service.dart';
import 'package:voyager/features/settings/services/data_import_service.dart';

import 'import_export_test.dart' show collectionsFor, seedOneOfEverything;

/// Lists one snapshot, and holds its restore open until [gate] completes.
class _SlowRestoreService extends AutoBackupService {
  _SlowRestoreService(this.entry)
    : super(
        directory: () async => Directory.systemTemp,
        exporter: () => throw UnimplementedError(),
        importer: () => throw UnimplementedError(),
        freeBytes: (_) async => null,
      );

  final BackupFileEntry entry;
  final gate = Completer<void>();

  /// What happened, in order: 'flush' from the registry, 'restore' here.
  final events = <String>[];

  @override
  Future<List<BackupFileEntry>> listBackups() async => [entry];

  @override
  Future<BackupImportSummary> restore(File backup) async {
    events.add('restore');
    await gate.future;
    return const BackupImportSummary(
      restoredByCollection: {'journal_entries': 3},
      skipped: 10,
      settingsRestored: false,
    );
  }
}

void main() {
  testWidgets('an undo flushes the editors first, holds everything still '
      'while it runs, then remounts the pages', (tester) async {
    late File file;
    await tester.runAsync(() async {
      final db = AppDatabase.inMemory();
      await seedOneOfEverything(db);
      final dir = await Directory.systemTemp.createTemp('voyager_list_dialog');
      addTearDown(() => dir.delete(recursive: true));
      file = File(
        p.join(dir.path, 'voyager_prerestore_2026-09-24_10-00-00-0400.zip'),
      );
      await DataExportService(
        db: db,
        collections: collectionsFor(db),
        settingsRepository: DriftSettingsRepository(db),
      ).exportDataToZip(file);
      await db.close();
    });
    final service = _SlowRestoreService(
      BackupFileEntry(
        file: file,
        capturedAt: DateTime.utc(2026, 9, 24, 14),
        isSnapshot: true,
        bytes: file.lengthSync(),
      ),
    );
    // An open editor's flush.
    Future<void> flush() async => service.events.add('flush');
    PendingFlushRegistry.instance.register(flush);
    addTearDown(() => PendingFlushRegistry.instance.unregister(flush));
    final generation = restoreGeneration.value;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [autoBackupServiceProvider.overrideWith((ref) => service)],
        child: MaterialApp(
          theme: VoyagerTheme.dark(),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showBackupListDialog(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    // The manifests are read on another isolate.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 500)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Show menu').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Restore…'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 500)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Restore'));
    await tester.pump(const Duration(milliseconds: 300));

    // The snapshot is taken after the editors have saved.
    expect(service.events, ['flush', 'restore']);
    // Meanwhile nothing on screen can be typed into or flushed.
    expect(find.text('Saving a snapshot, then restoring…'), findsOneWidget);
    expect(PendingFlushRegistry.instance.restoring, isTrue);
    await PendingFlushRegistry.instance.flushAll();
    expect(service.events, ['flush', 'restore']);
    expect(restoreGeneration.value, generation);

    service.gate.complete();

    final shown = <String?>{};
    // Long enough for the queued snackbar to follow the one showing now.
    for (var i = 0; i < 100; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      shown.addAll([
        for (final text in tester.widgetList<Text>(
          find.descendant(
            of: find.byType(SnackBar),
            matching: find.byType(Text),
          ),
        ))
          text.data,
      ]);
    }
    expect(shown, contains(startsWith('Backup restored: 3 record(s)')));
    expect(shown, isNot(contains(startsWith('Restore failed'))));
    expect(find.text('Saving a snapshot, then restoring…'), findsNothing);
    expect(PendingFlushRegistry.instance.restoring, isFalse);
    expect(restoreGeneration.value, generation + 1, reason: 'pages remount');
  });
}
