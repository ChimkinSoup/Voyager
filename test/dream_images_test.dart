// Images on dreams, which carry them the way journal entries do: pasted or
// dropped onto the body, fanned in its corner — here beside the sticky note
// that already owns the corner — and detached and restored with the dream.
//
// The fan's own drawing and the paste routing are covered by
// media_fan_stack_test.dart and media_paste_scope_test.dart; what is guarded
// here is that each dream surface is wired to the right owner, and the parts
// that are the dream's own: a held "New dream" being written before an image
// lands on it, and delete / undo carrying the images along.

import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/media/media_service.dart';
import 'package:voyager/core/media/widgets/media_drop_target.dart';
import 'package:voyager/core/media/widgets/media_fan_stack.dart';
import 'package:voyager/core/media/widgets/media_image.dart';
import 'package:voyager/core/media/widgets/media_paste_scope.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/data/services/media_file_store.dart';
import 'package:voyager/domain/models/dream_models.dart';
import 'package:voyager/domain/models/journal_models.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/features/dream_journal/dream_journal_page.dart';
import 'package:voyager/features/dream_journal/dream_sticky_note.dart';
import 'package:voyager/features/hotkeys/floaters/journal_floater.dart';
import 'package:voyager/features/hotkeys/quick_journal_entry.dart';

import 'fakes/fake_weather_api_client.dart';
import 'support/search_page_harness.dart';

const _dreamId = 'dream-with-pictures';

Uint8List _png() {
  final image = img.Image(width: 8, height: 8, numChannels: 3);
  img.fill(image, color: img.ColorRgb8(90, 30, 60));
  return img.encodePng(image);
}

/// The page keeps animations alive, so `pumpAndSettle` never returns.
Future<void> _settle(WidgetTester tester, [int frames = 12]) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

void main() {
  // Two AppDatabases on purpose — the page's and the media module's.
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  late Directory tempDir;
  late AppDatabase mediaDb;
  late MediaFileStore fileStore;
  late MediaService service;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('voyager_dream_images');
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
    try {
      await tempDir.delete(recursive: true);
    } on FileSystemException {
      // A read may still hold a file open on Windows.
    }
  });

  /// [WidgetTester.runAsync] because an ingest hands the decode to `compute`,
  /// whose answer never arrives inside a widget test's fake async zone.
  Future<void> attach(WidgetTester tester) async {
    await tester.runAsync(
      () => service.attachBytes(
        bytes: _png(),
        collection: FirestoreCollections.dreamEntries,
        documentId: _dreamId,
      ),
    );
  }

  Future<int> imageCount(WidgetTester tester) async {
    final refs = await tester.runAsync(
      () => service.referencesFor(FirestoreCollections.dreamEntries, _dreamId),
    );
    return refs!.length;
  }

  Future<AppDatabase> pumpDreamPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final db = AppDatabase.inMemory();
    addTearDown(db.close);
    final now = DateTime.now().toUtc();
    await DriftDreamRepository(db).upsertEntry(
      DreamEntry(
        id: _dreamId,
        title: 'Dream with pictures',
        body: 'A lighthouse',
        entryDate: now,
        createdAt: now,
        updatedAt: now,
      ),
    );

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        syncRepositoryProvider.overrideWithValue(InMemorySyncRepository()),
        weatherApiClientProvider.overrideWithValue(FakeWeatherApiClient()),
        mediaServiceProvider.overrideWith((ref) => service),
        mediaFileStoreProvider.overrideWithValue(fileStore),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: DreamJournalPage())),
      ),
    );
    await _settle(tester);
    return db;
  }

  group('Dream Journal page', () {
    testWidgets('the body takes pasted and dropped images for the dream', (
      tester,
    ) async {
      await pumpDreamPage(tester);

      final paste = tester.widget<MediaPasteScope>(
        find.byType(MediaPasteScope),
      );
      expect(paste.collection, FirestoreCollections.dreamEntries);
      expect(paste.documentId, _dreamId);
      expect(paste.fieldTakesBoth, isTrue);

      final drop = tester.widget<MediaDropTarget>(find.byType(MediaDropTarget));
      expect(drop.collection, FirestoreCollections.dreamEntries);
      expect(drop.documentId, _dreamId);
    });

    testWidgets('the fan sits just left of the collapsed sticky note', (
      tester,
    ) async {
      await attach(tester);
      await pumpDreamPage(tester);

      expect(find.byType(MediaImage), findsOneWidget);
      final fan = tester.getRect(find.byType(MediaFanStack));
      final note = tester.getRect(find.byType(DreamStickyNote));
      expect(fan.right, lessThanOrEqualTo(note.left));
      expect(
        (fan.bottom - note.bottom).abs(),
        lessThan(12),
        reason: 'the fan shares the note\'s bottom edge',
      );
    });

    testWidgets('an image writes a held "New dream" to disk first', (
      tester,
    ) async {
      final db = await pumpDreamPage(tester);
      await tester.tap(find.widgetWithText(GlassButton, 'New dream'));
      await _settle(tester);

      final paste = tester.widget<MediaPasteScope>(
        find.byType(MediaPasteScope),
      );
      final newId = paste.documentId!;
      expect(newId, isNot(_dreamId));
      final repo = DriftDreamRepository(db);
      expect(await repo.getEntry(newId), isNull);

      await paste.onBeforeAttach!();
      await _settle(tester);
      expect(await repo.getEntry(newId), isNotNull);

      final drop = tester.widget<MediaDropTarget>(find.byType(MediaDropTarget));
      expect(drop.documentId, newId);
      expect(drop.onBeforeAttach, isNotNull);
    });

    testWidgets('delete detaches the images and undo brings them back', (
      tester,
    ) async {
      await attach(tester);
      await pumpDreamPage(tester);
      expect(await imageCount(tester), 1);

      await tester.tap(find.byTooltip('Delete dream'));
      await _settle(tester);
      await tester.tap(find.widgetWithText(GlassButton, 'Delete'));
      await _settle(tester);
      expect(await imageCount(tester), 0);

      await tester.tap(find.text('Undo'));
      await _settle(tester);
      expect(await imageCount(tester), 1);
    });
  });

  testWidgets('the Search dream popup carries the same images', (tester) async {
    tester.view.physicalSize = const Size(1200, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await attach(tester);
    await pumpSearchPage(
      tester,
      entries: (_) => const <JournalEntry>[],
      dreams: (now) => [
        DreamEntry(
          id: _dreamId,
          title: 'Dream with pictures',
          body: 'A lighthouse',
          entryDate: now,
          createdAt: now,
          updatedAt: now,
        ),
      ],
      extraOverrides: [
        mediaServiceProvider.overrideWith((ref) => service),
        mediaFileStoreProvider.overrideWithValue(fileStore),
      ],
    );
    await tester.enterText(find.byType(EditableText).first, '/dream light');
    await settle(tester);
    await tester.tap(find.text('Dream with pictures'));
    await settle(tester);

    final paste = tester.widget<MediaPasteScope>(find.byType(MediaPasteScope));
    expect(paste.collection, FirestoreCollections.dreamEntries);
    expect(paste.documentId, _dreamId);
    final drop = tester.widget<MediaDropTarget>(find.byType(MediaDropTarget));
    expect(drop.documentId, _dreamId);
    expect(find.byType(MediaImage), findsOneWidget);
    final fan = tester.getRect(find.byType(MediaFanStack));
    final note = tester.getRect(find.byType(DreamStickyNote));
    expect(fan.right, lessThanOrEqualTo(note.left));

    await disposeSearchPage(tester);
  });

  // Not a dream, but the same gap: the hotkey notepad is today's Quick Journal
  // Entry, so it takes images onto that entry as the Journal page does.
  testWidgets('the quick-journal floater takes images for its entry', (
    tester,
  ) async {
    final db = AppDatabase.inMemory();
    addTearDown(db.close);
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        syncRepositoryProvider.overrideWithValue(InMemorySyncRepository()),
        weatherApiClientProvider.overrideWithValue(FakeWeatherApiClient()),
        quickJournalPointerStoreProvider.overrideWithValue(
          _MemoryPointerStore(),
        ),
        mediaServiceProvider.overrideWith((ref) => service),
        mediaFileStoreProvider.overrideWithValue(fileStore),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: JournalFloater())),
      ),
    );
    await _settle(tester);

    final entryId = quickJournalNotepadEntryId.value;
    expect(entryId, isNotNull);
    final paste = tester.widget<MediaPasteScope>(find.byType(MediaPasteScope));
    expect(paste.collection, FirestoreCollections.journalEntries);
    expect(paste.documentId, entryId);
    expect(paste.fieldTakesBoth, isTrue);
    final drop = tester.widget<MediaDropTarget>(find.byType(MediaDropTarget));
    expect(drop.collection, FirestoreCollections.journalEntries);
    expect(drop.documentId, entryId);
    final fan = tester.widget<MediaFanStack>(find.byType(MediaFanStack));
    expect(fan.documentId, entryId);

    await tester.pumpWidget(const SizedBox());
    await _settle(tester);
  });
}

class _MemoryPointerStore implements QuickJournalPointerStore {
  ({String day, String entryId})? pointer;

  @override
  Future<({String day, String entryId})?> load() async => pointer;

  @override
  Future<void> save(String day, String entryId) async =>
      pointer = (day: day, entryId: entryId);
}
