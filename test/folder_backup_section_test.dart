import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/features/settings/folder_backup_section.dart';
import 'package:voyager/features/settings/services/folder_backup_service.dart';

/// The Settings section and the list it opens (FOLDER_BACKUP_HLD.md §9),
/// over a real service and temp folders. Mounted on their own, not inside
/// the app shell.
void main() {
  late Directory temp;
  late FolderBackupService service;
  late Directory vault;
  var now = DateTime(2026, 10, 3, 9);

  Future<void> setUpService(WidgetTester tester) async {
    await tester.runAsync(() async {
      temp = await Directory.systemTemp.createTemp('folder_backup_ui');
      vault = Directory(p.join(temp.path, 'Vault'))..createSync();
      for (var i = 0; i < 20; i++) {
        File(p.join(vault.path, '$i.md')).writeAsStringSync('note $i');
      }
      final dest = Directory(p.join(temp.path, 'Backups'))..createSync();
      service = FolderBackupService(
        directory: () async => Directory(p.join(temp.path, 'app')),
        freeBytes: (_) async => null,
        notify: (_, _, _) async {},
        now: () => now,
      );
      await service.addSource(
        name: 'Obsidian',
        sourcePath: vault.path,
        destination: dest.path,
      );
      await service.runDue();
    });
    // The provider override disposes the service with the scope.
    addTearDown(() => tester.runAsync(() => temp.delete(recursive: true)));
  }

  /// Lets real IO and the isolates the list reads manifests on finish. Not
  /// pumpAndSettle: a spinner animates for as long as they take.
  Future<void> settle(WidgetTester tester, [int rounds = 10]) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> pumpSection(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [folderBackupServiceProvider.overrideWith((_) => service)],
        child: MaterialApp(
          theme: VoyagerTheme.dark(),
          home: const Scaffold(
            body: SingleChildScrollView(child: FolderBackupSection()),
          ),
        ),
      ),
    );
    await tester.runAsync(service.refreshStatus);
    await settle(tester);
  }

  testWidgets('a healthy source lists its backup with its file count', (
    tester,
  ) async {
    await setUpService(tester);
    await pumpSection(tester);
    expect(find.textContaining('Obsidian · 1 backup ·'), findsOneWidget);
    expect(find.text('Healthy'), findsOneWidget);
    expect(find.text('Last backup 09:00, verified'), findsOneWidget);

    await tester.tap(find.textContaining('Obsidian · 1 backup'));
    await settle(tester);
    expect(find.text('Back up now'), findsOneWidget);
    expect(find.text('Today'), findsOneWidget);
    expect(find.textContaining('20 files'), findsOneWidget);
  });

  testWidgets('a shrunken folder shows Review and its way out', (tester) async {
    await setUpService(tester);
    await tester.runAsync(() async {
      for (var i = 0; i < 10; i++) {
        File(p.join(vault.path, '$i.md')).deleteSync();
      }
      now = now.add(const Duration(days: 1));
      await service.runDue();
    });
    await pumpSection(tester);
    expect(find.text('Review'), findsOneWidget);
    expect(
      find.text('File count fell 50% since the last backup (20 → 10)'),
      findsOneWidget,
    );

    await tester.tap(find.textContaining('Obsidian · 2 backups'));
    await settle(tester);
    expect(find.text('This was intentional'), findsOneWidget);
    await tester.tap(find.text('This was intentional'));
    // Acknowledging runs a whole check — state, walk, verify, prune — and
    // under the test clock each of its IO steps needs a pump of its own.
    for (var i = 0; i < 300; i++) {
      if (find.text('This was intentional').evaluate().isEmpty) break;
      await settle(tester, 1);
    }
    expect(find.text('This was intentional'), findsNothing);
  });

  testWidgets('a removed source is listed as retired', (tester) async {
    await setUpService(tester);
    await tester.runAsync(() async {
      await service.removeSource((await service.sources()).single.id);
    });
    await pumpSection(tester);
    expect(
      find.textContaining('Obsidian (removed) · 1 backup'),
      findsOneWidget,
    );
    await tester.tap(find.textContaining('Obsidian (removed)'));
    await settle(tester);
    expect(find.text('Delete all…'), findsOneWidget);
    expect(find.text('Back up now'), findsNothing);
  });
}
