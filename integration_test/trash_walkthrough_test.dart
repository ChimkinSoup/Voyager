// Drives the real app through the trash (TRASH_HLD.md): delete a journal
// from its manage sheet, restore it from "Recently deleted", delete it again
// and erase it, checking the local database and Firestore after each step.
//
// Runs against THIS machine's database and the signed-in account. It only
// touches the journal it creates — named "ZZ Trash test <time>" — and ends by
// erasing it, which leaves an emptied tombstone behind for good.
//
//   flutter test integration_test/trash_walkthrough_test.dart -d windows
//
// Close any running Voyager first: two instances share one SQLite file.
// Screenshots land in build/trash_walkthrough/.

import 'dart:io';
import 'dart:ui' as ui;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:go_router/go_router.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/soft_delete/erasure.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/domain/models/journal_models.dart';
import 'package:voyager/features/settings/settings_page.dart';
import 'package:voyager/features/shell/app_shell.dart';
import 'package:voyager/main.dart' as app;
import 'package:voyager/routing/app_router.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('delete, restore and erase a journal through the trash', (
    tester,
  ) async {
    // Taken before launch: the app wraps it in its error logger, and the
    // binding checks for its own handler when the test ends.
    final reportToTest = FlutterError.onError;
    await app.main();
    // The shell reports a couple of framework assertions of its own under the
    // test binding (rail scroll fades, semantics geometry). They are collected
    // rather than failing the walkthrough, and checked at the end for anything
    // raised by the trash or the sync layer.
    final errors = <FlutterErrorDetails>[];
    FlutterError.onError = errors.add;
    // The app keeps rendering until the test is torn down, so on success the
    // collector stays until then. On a failure it goes at once: the binding
    // refuses a failure reported while its handler is swapped out, and hides
    // the real one behind that complaint.
    addTearDown(() => FlutterError.onError = reportToTest);
    try {
      await _pumpUntil(tester, find.byType(AppShell), 'the signed-in shell');
      await _shot(tester, '0_launched');
      final container = ProviderScope.containerOf(
        tester.element(find.byType(app.VoyagerBootstrap)),
      );
      _router = container.read(routerProvider);
      _router.go('/journal');
      await _pumpUntil(tester, _manageJournals, 'the journal page');
      final uid = container.read(authRepositoryProvider).currentUserId;
      expect(uid, isNotNull, reason: 'sign in to Voyager before running this');

      // --- Erase what an interrupted earlier run left behind.
      await _eraseLeftovers(container);

      // --- Seed a journal with two entries, the way the app writes them.
      final name = 'ZZ Trash test ${DateTime.now().millisecondsSinceEpoch}';
      final journalId = newId();
      final entryIds = [newId(), newId()];
      final journals = container.read(journalRepositoryProvider);
      final sync = container.read(remoteSyncServiceProvider);
      final now = utcNow();
      final journal = Journal(
        id: journalId,
        name: name,
        createdAt: now,
        updatedAt: now,
      );
      await journals.upsertJournal(journal);
      sync.pushJournal(journal);
      for (final (i, id) in entryIds.indexed) {
        final entry = JournalEntry(
          id: id,
          journalId: journalId,
          title: 'Trash test entry $i',
          body: 'Private text $i',
          entryDate: now,
          createdAt: now,
          updatedAt: now,
        );
        await journals.upsertEntry(entry);
        sync.pushJournalEntryNow(entry);
      }
      await _eventually(
        () async =>
            (await _remoteEntry(uid!, entryIds.last))?['body'] ==
            'Private text 1',
        'the seeded entries to reach Firestore',
      );
      container.invalidate(journalsProvider);

      // --- Delete it from the manage sheet, taking the entries with it.
      await _deleteFromManageSheet(tester, name);
      final deleted = (await journals.getJournal(journalId))!;
      expect(deleted.deletedAt, isNotNull);
      for (final id in entryIds) {
        expect(
          (await journals.getEntry(id))!.deletedAt,
          deleted.deletedAt,
          reason: 'one stamp for the journal and what it took with it',
        );
      }

      // --- Restore it from "Recently deleted".
      await _openRecentlyDeleted(tester);
      final row = _trashRow('Journal "$name"');
      await _pumpUntil(tester, row, 'the journal in the trash');
      expect(
        find.descendant(of: row, matching: find.textContaining('2 entries')),
        findsOneWidget,
      );
      await _shot(tester, '1_trash_filtered_to_journal');
      await tester.tap(
        find.descendant(of: row, matching: find.text('Restore')),
      );
      await _pumpUntil(
        tester,
        find.textContaining('Restored Journal "$name"'),
        'the restore toast',
      );
      await _shot(tester, '2_restored');
      expect((await journals.getJournal(journalId))!.deletedAt, isNull);
      for (final id in entryIds) {
        expect((await journals.getEntry(id))!.deletedAt, isNull);
      }
      await _eventually(
        () async =>
            (await _remoteEntry(uid!, entryIds.first))?['deletedAt'] == null,
        'the restore to reach Firestore',
      );
      await _closeDialog(tester); // Trash
      await _closeDialog(tester); // Manage journals

      // --- Delete it again, then erase it for good.
      await _deleteFromManageSheet(tester, name);
      await _openRecentlyDeleted(tester);
      await _pumpUntil(tester, row, 'the journal back in the trash');
      await tester.tap(find.descendant(of: row, matching: _tooltip('More')));
      await _pump(tester);
      await tester.tap(find.text('Delete forever…'));
      await _pumpUntil(tester, find.text('Delete forever?'), 'the confirm');
      await _shot(tester, '3_delete_forever_confirm');
      await tester.tap(find.text('Delete forever'));
      await _pumpUntil(tester, row, 'the row to leave the trash', gone: true);
      await _shot(tester, '4_erased');

      final erased = (await journals.getJournal(journalId))!;
      expect(isErasedAt(erased.deletedAt), isTrue);
      expect(erased.name, isEmpty);
      for (final id in entryIds) {
        final entry = (await journals.getEntry(id))!;
        expect(isErasedAt(entry.deletedAt), isTrue);
        expect(entry.title, isEmpty);
        expect(entry.body, isEmpty);
      }

      // Every device resolves an entry's text from its operation log, so the
      // erase has only happened once that log is gone too.
      for (final id in entryIds) {
        await _eventually(() async {
          final doc = await _remoteEntry(uid!, id);
          return doc != null &&
              doc['body'] == '' &&
              isErasedPayload(doc) &&
              (await _remoteOperations(uid, id)).isEmpty;
        }, 'entry $id to be erased in Firestore');
      }
      await _closeDialog(tester); // Trash
      await _closeDialog(tester); // Manage journals

      // --- Settings → Trash opens the unfiltered list.
      _router.go('/settings');
      await _pump(tester, frames: 10);
      final trashRow = find.widgetWithText(ListTile, 'Trash');
      // The list builds lazily, so the row only exists once scrolled to.
      await tester.scrollUntilVisible(
        trashRow,
        300,
        scrollable: find
            .descendant(
              of: find.byType(SettingsPage),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await _pump(tester);
      await tester.tap(trashRow);
      await _pumpUntil(tester, find.text('All'), 'the trash from Settings');
      await _shot(tester, '5_trash_from_settings');
      await _closeDialog(tester);
    } catch (_) {
      FlutterError.onError = reportToTest;
      rethrow;
    }

    final ours = [
      for (final error in errors)
        if (RegExp(
          r'features[/\\]trash|core[/\\](sync|soft_delete)',
        ).hasMatch('${error.stack}'))
          error,
    ];
    for (final error in errors) {
      debugPrint('Collected: ${error.exceptionAsString().split('\n').first}');
    }
    if (ours.isNotEmpty) {
      FlutterError.onError = reportToTest;
      fail('errors raised by the trash or sync code: ${ours.first}');
    }
  });
}

late GoRouter _router;

final _manageJournals = _tooltip('Manage journals');

/// `find.byTooltip` goes by the tooltip's semantics, which this app's tooltips
/// don't carry; the widget's own message is what is certain to be there.
Finder _tooltip(String message) => find.byWidgetPredicate(
  (widget) => widget is Tooltip && widget.message == message,
);

/// Deletes and erases every live journal an earlier, interrupted run of this
/// test created, with its entries.
Future<void> _eraseLeftovers(ProviderContainer container) async {
  final journals = container.read(journalRepositoryProvider);
  final trash = container.read(trashServiceProvider);
  for (final journal in await journals.listJournals()) {
    if (!journal.name.startsWith('ZZ Trash test ')) continue;
    final at = utcNow();
    await journals.softDeleteEntriesInJournal(journal.id, at: at);
    await journals.softDeleteJournal(journal.id, at: at);
    final item = (await trash.list()).firstWhere((i) => i.id == journal.id);
    await trash.erase([item]);
  }
}

Finder _trashRow(String label) =>
    find.ancestor(of: find.text(label), matching: find.byType(ListTile));

Future<void> _deleteFromManageSheet(WidgetTester tester, String name) async {
  _router.go('/journal');
  await _pump(tester, frames: 10);
  await tester.tap(_manageJournals);
  final row = find.ancestor(
    of: find.text(name),
    matching: find.byType(ListTile),
  );
  await _pumpUntil(tester, row, 'the journal in Manage journals');
  await tester.tap(
    find.descendant(
      of: row,
      matching: find.byWidgetPredicate((widget) => widget is PopupMenuButton),
    ),
  );
  await _pump(tester);
  await tester.tap(find.text('Delete').last);
  await _pumpUntil(
    tester,
    find.text('Yes (delete all entries)'),
    'the delete dialog',
  );
  await tester.tap(find.text('Yes (delete all entries)'));
  await _pumpUntil(tester, row, 'the journal to leave the sheet', gone: true);
}

Future<void> _openRecentlyDeleted(WidgetTester tester) async {
  await tester.tap(find.text('Recently deleted'));
  await _pumpUntil(tester, find.text('Trash'), 'the trash dialog');
}

/// The topmost dialog's Close.
Future<void> _closeDialog(WidgetTester tester) async {
  await tester.tap(find.text('Close').last);
  await _pump(tester, frames: 10);
}

/// The shell animates continuously, so it never settles; frames are pumped
/// by hand instead.
Future<void> _pump(WidgetTester tester, {int frames = 5}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _pumpUntil(
  WidgetTester tester,
  Finder finder,
  String what, {
  bool gone = false,
  Duration timeout = const Duration(seconds: 60),
}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 100));
    if (finder.evaluate().isEmpty == gone) return;
  }
  final hidden = find.byWidgetPredicate((_) => true, skipOffstage: false);
  debugPrint(
    'Timed out on $what: ${finder.evaluate().length} onstage, '
    '${hidden.evaluate().length} widgets in the tree',
  );
  fail('Timed out waiting for $what');
}

Future<void> _eventually(
  Future<bool> Function() check,
  String what, {
  Duration timeout = const Duration(seconds: 60),
}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    if (await check()) return;
    await Future<void>.delayed(const Duration(seconds: 1));
  }
  fail('Timed out waiting for $what');
}

Future<Map<String, dynamic>?> _remoteEntry(String uid, String id) async {
  final snap = await FirebaseFirestore.instance
      .doc('users/$uid/${FirestoreCollections.journalEntries}/$id')
      .get(const GetOptions(source: Source.server));
  return snap.data();
}

Future<List<Object>> _remoteOperations(String uid, String id) async {
  final query = await FirebaseFirestore.instance
      .collection('users/$uid/${FirestoreCollections.syncOperations}')
      .where('documentId', isEqualTo: id)
      .get(const GetOptions(source: Source.server));
  return query.docs;
}

Future<void> _shot(WidgetTester tester, String name) async {
  await _pump(tester, frames: 3);
  final view = tester.binding.renderViews.first;
  final layer = view.debugLayer! as OffsetLayer;
  // The root layer is in physical pixels: it scales the logical tree up.
  final image = await layer.toImage(
    Offset.zero & view.flutterView.physicalSize,
  );
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  final file = File('build/trash_walkthrough/$name.png');
  await file.parent.create(recursive: true);
  await file.writeAsBytes(bytes!.buffer.asUint8List());
}
