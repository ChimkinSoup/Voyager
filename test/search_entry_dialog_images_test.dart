// The corner fan on the Search result's entry dialog.
//
// The same entry opened from Journal and from Search must carry the same
// pictures, so what is guarded here is parity with media_fan_stack_test.dart —
// the cap of three drawn cards, the `+N` badge for the rest, and the whole
// stack opening the lightbox on every image — rather than the fan's own
// drawing, which that file already covers.

import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/media/media_service.dart';
import 'package:voyager/core/media/widgets/media_drop_target.dart';
import 'package:voyager/core/media/widgets/media_fan_stack.dart';
import 'package:voyager/core/media/widgets/media_image.dart';
import 'package:voyager/core/media/widgets/media_paste_scope.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/data/services/media_file_store.dart';
import 'package:voyager/domain/models/journal_models.dart';
import 'package:voyager/domain/models/settings_models.dart';

import 'support/search_page_harness.dart';

const _entryId = 'search-entry';

List<JournalEntry> _seed(DateTime now) => [
  JournalEntry(
    id: _entryId,
    journalId: searchHarnessJournalId,
    title: 'Entry with pictures',
    body: 'Untouched body',
    entryDate: now,
    timestamp: now,
    createdAt: now,
    updatedAt: now,
    version: 3,
  ),
];

/// A distinct image per call, so each attach is its own asset rather than the
/// same one deduplicated by content hash.
Uint8List _pngOf(int seed) {
  final image = img.Image(width: 8, height: 8, numChannels: 3);
  img.fill(image, color: img.ColorRgb8(seed * 20 % 255, 30, 60));
  return img.encodePng(image);
}

void main() {
  // Two AppDatabases on purpose — the page's and the media module's.
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  late Directory tempDir;
  late AppDatabase mediaDb;
  late MediaFileStore fileStore;
  late MediaService service;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('voyager_search_fan');
    // A database of its own: the harness builds the page's one, and the media
    // module only needs somewhere to keep asset and reference rows.
    mediaDb = AppDatabase.inMemory();
    fileStore = MediaFileStore(root: Directory('${tempDir.path}/media'));
    service = MediaService(
      repository: DriftMediaRepository(mediaDb),
      fileStore: fileStore,
      readSettings: () async => const AppSettings(),
    );
  });

  tearDown(() async {
    await mediaDb.close();
    if (await tempDir.exists()) {
      // Tolerated: a read this test started may still hold the file open on
      // Windows, and a leftover temp directory is not a failure.
      try {
        await tempDir.delete(recursive: true);
      } on FileSystemException {
        // ignored
      }
    }
  });

  /// [WidgetTester.runAsync] because an ingest hands the decode to `compute`,
  /// and an isolate's answer never arrives inside a widget test's fake async
  /// zone.
  Future<void> attach(WidgetTester tester, int count) async {
    await tester.runAsync(() async {
      for (var i = 0; i < count; i++) {
        await service.attachBytes(
          bytes: _pngOf(i + 1),
          collection: FirestoreCollections.journalEntries,
          documentId: _entryId,
        );
      }
    });
  }

  Future<void> openDialog(WidgetTester tester) async {
    // The harness sets a tall MediaQuery but not the surface behind it, and
    // the fan lives at the bottom of a 480px field — off the default 800x600
    // render view, where a tap would hit nothing.
    tester.view.physicalSize = const Size(1200, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await pumpSearchPage(
      tester,
      entries: _seed,
      extraOverrides: [
        mediaServiceProvider.overrideWith((ref) => service),
        mediaFileStoreProvider.overrideWithValue(fileStore),
      ],
    );
    await tester.tap(find.text('Entry with pictures'));
    await settle(tester);
    expect(find.text('Journal entry'), findsOneWidget);
  }

  testWidgets('an entry without images shows no fan', (tester) async {
    await openDialog(tester);

    expect(find.byType(MediaImage), findsNothing);
    expect(
      tester.getSize(find.byType(MediaFanStack)),
      Size.zero,
      reason: 'an entry without images must not reserve corner space',
    );

    await disposeSearchPage(tester);
  });

  testWidgets('the dialog fans the entry images, capped at three', (
    tester,
  ) async {
    await attach(tester, 5);
    await openDialog(tester);

    expect(find.byType(MediaImage), findsNWidgets(3));
    expect(find.text('+2'), findsOneWidget);

    await disposeSearchPage(tester);
  });

  testWidgets('the fan sits in the bottom-right of the writing area', (
    tester,
  ) async {
    await attach(tester, 1);
    await openDialog(tester);

    final fan = tester.getRect(find.byType(MediaFanStack));
    // The writing area itself — the drop target wraps exactly the box the fan
    // is positioned in, where the field's own EditableText is inset by the
    // decoration's padding.
    final area = tester.getRect(find.byType(MediaDropTarget));
    expect(fan.right, lessThanOrEqualTo(area.right));
    expect(fan.bottom, lessThanOrEqualTo(area.bottom));
    expect(
      fan.center.dx,
      greaterThan(area.center.dx),
      reason: 'the fan belongs in the corner, not over the writing',
    );
    expect(fan.center.dy, greaterThan(area.center.dy));

    await disposeSearchPage(tester);
  });

  testWidgets('tapping the fan opens the lightbox on every image', (
    tester,
  ) async {
    await attach(tester, 5);
    await openDialog(tester);

    await tester.tap(find.byType(MediaFanStack));
    await settle(tester);

    expect(find.byType(InteractiveViewer), findsWidgets);
    expect(
      find.text('1 / 5'),
      findsOneWidget,
      reason: 'the viewer swipes the whole set, however few cards are drawn',
    );

    await disposeSearchPage(tester);
  });

  testWidgets('the writing area takes pasted and dropped images', (
    tester,
  ) async {
    await attach(tester, 1);
    await openDialog(tester);

    // Both halves of the journal's integration are present and aimed at this
    // entry, so a screenshot pasted or dropped here attaches exactly as it
    // does on the Journal page.
    final paste = tester.widget<MediaPasteScope>(find.byType(MediaPasteScope));
    expect(paste.collection, FirestoreCollections.journalEntries);
    expect(paste.documentId, _entryId);
    expect(
      paste.fieldTakesBoth,
      isTrue,
      reason: 'the body is image-capable, so text+image pastes both',
    );

    final drop = tester.widget<MediaDropTarget>(find.byType(MediaDropTarget));
    expect(drop.collection, FirestoreCollections.journalEntries);
    expect(drop.documentId, _entryId);

    await disposeSearchPage(tester);
  });
}
