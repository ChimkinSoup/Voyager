// The card editor attaches images the moment they are picked, but writes the
// card itself only on Save. These pin the two rules that fall out of that
// (STUDY_IMAGES.md): a side is complete with text *or* images, and a new card
// abandoned after its pictures were attached must not leave references behind
// — a live reference keeps its blob off the retention clock forever.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/media/media_service.dart';
import 'package:voyager/core/media/widgets/media_paste_scope.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/sync/remote_sync_service.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/data/services/media_file_store.dart';
import 'package:voyager/domain/models/media_models.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/models/study_models.dart';
import 'package:voyager/domain/repositories/repositories.dart';
import 'package:voyager/features/study/study_card_editor_modal.dart';

Uint8List _png(int seed) {
  final image = img.Image(width: 8, height: 8, numChannels: 3);
  img.fill(image, color: img.ColorRgb8(seed * 30 % 255, 30, 60));
  return img.encodePng(image);
}

class _RecordingStudyRepository implements StudyRepository {
  _RecordingStudyRepository(this.cards);

  final List<StudyCard> cards;
  final saved = <StudyCard>[];

  @override
  Future<List<StudyCard>> listCards(
    String deckId, {
    bool includeDeleted = false,
  }) async => cards;

  @override
  Future<List<StudyCard>> getAllCards({bool includeDeleted = false}) async =>
      cards;

  @override
  Future<StudyCard?> getCard(String id) async {
    for (final card in cards) {
      if (card.id == id) return card;
    }
    return null;
  }

  @override
  Future<void> upsertCard(
    StudyCard card, {
    bool recordLocalActivity = true,
  }) async => saved.add(card);

  @override
  noSuchMethod(Invocation invocation) => null;
}

class _NoopRemoteSync implements RemoteSyncService {
  @override
  noSuchMethod(Invocation invocation) => null;
}

class _StubSettingsRepository implements SettingsRepository {
  @override
  Future<AppSettings> getSettings() async => const AppSettings();

  @override
  Future<Map<String, int>> getTagColors() async => const {};

  @override
  noSuchMethod(Invocation invocation) => null;
}

StudyCard _card({required String front, required String back}) {
  final now = DateTime.now().toUtc();
  return StudyCard(
    id: 'card-1',
    createdAt: now,
    updatedAt: now,
    deckId: 'deck-1',
    frontText: front,
    backText: back,
    dueAt: now,
  );
}

void main() {
  late Directory tempDir;
  late AppDatabase db;
  late DriftMediaRepository mediaRepository;
  late MediaFileStore fileStore;
  late MediaService media;
  late _RecordingStudyRepository studyRepository;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('voyager_card_editor');
    db = AppDatabase.inMemory();
    mediaRepository = DriftMediaRepository(db);
    fileStore = MediaFileStore(root: Directory('${tempDir.path}/media'));
    media = MediaService(
      repository: mediaRepository,
      fileStore: fileStore,
      readSettings: () async => const AppSettings(),
    );
    studyRepository = _RecordingStudyRepository([]);
  });

  tearDown(() async {
    await db.close();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  /// Bounded pumps rather than `pumpAndSettle`: a [MediaImage] still resolving
  /// paints a progress indicator, which never settles.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> openEditor(WidgetTester tester, {StudyCard? existing}) async {
    // A tall window: the sheet grows with the preview and the gallery, and the
    // Save button at the bottom of it has to be reachable.
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          studyRepositoryProvider.overrideWithValue(studyRepository),
          remoteSyncServiceProvider.overrideWithValue(_NoopRemoteSync()),
          mediaServiceProvider.overrideWith((ref) => media),
          mediaFileStoreProvider.overrideWithValue(fileStore),
          settingsRepositoryProvider.overrideWithValue(
            _StubSettingsRepository(),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) {
                // Warmed the way the real shell warms it.
                ref.watch(settingsProvider);
                return TextButton(
                  onPressed: () => showStudyCardEditorModal(
                    context,
                    ref,
                    deckId: 'deck-1',
                    existing: existing,
                  ),
                  child: const Text('open'),
                );
              },
            ),
          ),
        ),
      ),
    );
    await settle(tester);
    await tester.tap(find.text('open'));
    await settle(tester);
  }

  bool saveEnabled(WidgetTester tester) =>
      tester
          .widget<GlassButton>(
            find.ancestor(
              of: find.text('Save'),
              matching: find.byType(GlassButton),
            ),
          )
          .onPressed !=
      null;

  /// The card id the editor allocated, read off the paste scope each side is
  /// wrapped in. A new card's id exists before its row does, so the galleries
  /// have an owner to attach to — hence non-null here, where a journal body
  /// opened before its entry exists would carry none.
  String editorCardId(WidgetTester tester) => tester
      .widget<MediaPasteScope>(find.byType(MediaPasteScope).first)
      .documentId!;

  Future<void> attach(
    WidgetTester tester,
    String cardId,
    MediaFacet facet,
  ) async {
    // `runAsync` because an ingest hands the decode to `compute`, and an
    // isolate's answer never arrives inside a widget test's fake async zone.
    await tester.runAsync(() async {
      await media.attachBytes(
        bytes: _png(facet.index + 1),
        collection: FirestoreCollections.studyCards,
        documentId: cardId,
        facet: facet,
      );
    });
    await settle(tester);
  }

  Future<List<MediaReference>> referencesFor(String cardId) =>
      media.referencesFor(FirestoreCollections.studyCards, cardId);

  testWidgets('a side with neither text nor images cannot be saved', (
    tester,
  ) async {
    await openEditor(
      tester,
      existing: _card(front: '', back: 'answer'),
    );
    expect(saveEnabled(tester), isFalse);
  });

  testWidgets('an image-only front is a complete side', (tester) async {
    final card = _card(front: '', back: 'answer');
    studyRepository = _RecordingStudyRepository([card]);
    await openEditor(tester, existing: card);
    expect(saveEnabled(tester), isFalse);

    await attach(tester, card.id, MediaFacet.front);

    expect(
      saveEnabled(tester),
      isTrue,
      reason: 'the front has a picture even though it has no words',
    );
  });

  testWidgets('closing a new card without saving takes its images back', (
    tester,
  ) async {
    await openEditor(tester);
    final cardId = editorCardId(tester);
    await attach(tester, cardId, MediaFacet.front);
    expect(await referencesFor(cardId), hasLength(1));

    await tester.tap(find.byTooltip('Close'));
    await settle(tester);

    expect(
      await referencesFor(cardId),
      isEmpty,
      reason: 'a card that never existed must not pin a blob forever',
    );
    // And the blob is back on the retention clock rather than stranded live.
    final asset = (await mediaRepository.listAssets()).single;
    expect(asset.unreferencedAt, isNotNull);
  });

  testWidgets('saving a new card keeps the images it was built with', (
    tester,
  ) async {
    await openEditor(tester);
    final cardId = editorCardId(tester);
    await attach(tester, cardId, MediaFacet.front);

    await tester.enterText(find.byType(TextField).last, 'answer');
    await settle(tester);
    expect(saveEnabled(tester), isTrue, reason: 'image front, text back');

    await tester.tap(find.text('Save'));
    await settle(tester);

    expect(studyRepository.saved.single.id, cardId);
    expect(await referencesFor(cardId), hasLength(1));
  });
}
