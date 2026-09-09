import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/media/media_clipboard.dart';
import 'package:voyager/core/media/media_service.dart';
import 'package:voyager/core/media/widgets/media_paste_scope.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/data/services/media_file_store.dart';
import 'package:voyager/domain/models/settings_models.dart';

Uint8List pngOf(int width, int height) {
  final image = img.Image(width: width, height: height, numChannels: 3);
  img.fill(image, color: img.ColorRgb8(200, 30, 60));
  return img.encodePng(image);
}

/// Stands in for the platform clipboard, which a widget test has no access to.
class _FakeClipboard extends MediaClipboard {
  const _FakeClipboard({this.text, this.image});

  final String? text;
  final Uint8List? image;

  @override
  Future<({bool hasText, bool hasImage})> peek() async =>
      (hasText: text != null, hasImage: image != null);

  @override
  Future<MediaClipboardContents> read() async =>
      MediaClipboardContents(text: text, imageBytes: image);
}

void main() {
  group('routeMediaPaste', () {
    test('an image with nothing focused is attached', () {
      expect(
        routeMediaPaste(hasImage: true, hasText: false, intoTextField: false),
        MediaPasteRoute.attach,
      );
    });

    test('an image with no text is attached even from inside a field', () {
      expect(
        routeMediaPaste(hasImage: true, hasText: false, intoTextField: true),
        MediaPasteRoute.attach,
      );
    });

    test('an image alongside text is attached when no field is focused', () {
      expect(
        routeMediaPaste(hasImage: true, hasText: true, intoTextField: false),
        MediaPasteRoute.attach,
      );
    });

    test('an image alongside text yields to the caret', () {
      expect(
        routeMediaPaste(hasImage: true, hasText: true, intoTextField: true),
        MediaPasteRoute.text,
      );
    });

    test('an image-capable field takes both halves of the clipboard', () {
      expect(
        routeMediaPaste(
          hasImage: true,
          hasText: true,
          intoTextField: true,
          fieldTakesBoth: true,
        ),
        MediaPasteRoute.both,
      );
    });

    test('an image-capable field with no text on the clipboard attaches', () {
      expect(
        routeMediaPaste(
          hasImage: true,
          hasText: false,
          intoTextField: true,
          fieldTakesBoth: true,
        ),
        MediaPasteRoute.attach,
      );
    });

    test('a study side takes both halves into the focused face', () {
      expect(
        routeMediaPaste(
          hasImage: true,
          hasText: true,
          intoTextField: true,
          fieldTakesBoth: true,
          requireFocusedField: true,
        ),
        MediaPasteRoute.both,
      );
      expect(
        routeMediaPaste(
          hasImage: true,
          hasText: false,
          intoTextField: true,
          fieldTakesBoth: true,
          requireFocusedField: true,
        ),
        MediaPasteRoute.attach,
      );
    });

    test('a surface with a gallery per side ignores an unaimed image', () {
      // Front or back? With no caret there is no answer, so the picture is
      // left on the clipboard rather than guessed onto one of them.
      expect(
        routeMediaPaste(
          hasImage: true,
          hasText: false,
          intoTextField: false,
          requireFocusedField: true,
        ),
        MediaPasteRoute.ignore,
      );
      expect(
        routeMediaPaste(
          hasImage: true,
          hasText: true,
          intoTextField: false,
          fieldTakesBoth: true,
          requireFocusedField: true,
        ),
        MediaPasteRoute.ignore,
      );
    });

    test('text pastes as text, and goes nowhere with no caret', () {
      expect(
        routeMediaPaste(hasImage: false, hasText: true, intoTextField: true),
        MediaPasteRoute.text,
      );
      expect(
        routeMediaPaste(hasImage: false, hasText: true, intoTextField: false),
        MediaPasteRoute.ignore,
      );
    });
  });

  group('MediaPasteScope', () {
    late Directory tempDir;
    late AppDatabase db;
    late DriftMediaRepository repository;
    late MediaService service;
    late TextEditingController controller;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('voyager_paste_test');
      db = AppDatabase.inMemory();
      repository = DriftMediaRepository(db);
      service = MediaService(
        repository: repository,
        fileStore: MediaFileStore(root: Directory('${tempDir.path}/media')),
        readSettings: () async => const AppSettings(),
      );
      controller = TextEditingController();
    });

    tearDown(() async {
      controller.dispose();
      await db.close();
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    /// The text half of a paste goes through Flutter's own clipboard, which a
    /// test has to answer for.
    void mockSystemClipboard(String text) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.getData') return {'text': text};
            return null;
          });
    }

    Future<void> pumpScope(
      WidgetTester tester,
      MediaClipboard clipboard,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            mediaServiceProvider.overrideWith((ref) => service),
            mediaFileStoreProvider.overrideWithValue(
              MediaFileStore(root: Directory('${tempDir.path}/media')),
            ),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: MediaPasteScope(
                collection: FirestoreCollections.todoTasks,
                documentId: 'task-1',
                clipboard: clipboard,
                child: TextField(controller: controller),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    /// Ctrl+V, then real time for the paste to finish.
    ///
    /// [WidgetTester.runAsync] because an ingest hands the decode to
    /// `compute`, and an isolate's answer never arrives inside the fake async
    /// zone a widget test otherwise runs in.
    ///
    /// [until] is *polled* rather than waited out. A fixed delay picked to
    /// cover an ingest on an idle machine is not long enough for the same
    /// ingest on one running the whole suite in parallel, which is why these
    /// tests only ever failed in a full `flutter test` run. Everything polled
    /// here — a repository row, the controller's text — is written directly by
    /// the paste, so it needs no pump to become visible from inside
    /// [WidgetTester.runAsync].
    ///
    /// Pass null only where the assertion is that *nothing* happened. There is
    /// no condition to wait for, and no race to lose either: those are the
    /// pastes `routeMediaPaste` declines outright, so no ingest is ever
    /// started and a short wait can only ever be more than long enough.
    Future<void> pressPaste(
      WidgetTester tester, {
      Future<bool> Function()? until,
    }) async {
      await tester.runAsync(() async {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        if (until == null) {
          await Future<void>.delayed(const Duration(milliseconds: 200));
          return;
        }
        final deadline = DateTime.now().add(const Duration(seconds: 15));
        while (!await until()) {
          if (!DateTime.now().isBefore(deadline)) {
            fail('the paste never reached the state `until` waits for');
          }
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await tester.pumpAndSettle();
    }

    /// The production predicate for "the keystroke landed in a text field".
    bool textFieldHasFocus() =>
        FocusManager.instance.primaryFocus?.context
            ?.findAncestorWidgetOfExactType<EditableText>() !=
        null;

    Future<int> referenceCount() async {
      final references = await service.referencesFor(
        FirestoreCollections.todoTasks,
        'task-1',
      );
      return references.length;
    }

    testWidgets('attaches an image pasted with nothing focused', (
      tester,
    ) async {
      await pumpScope(tester, _FakeClipboard(image: pngOf(8, 8)));
      expect(textFieldHasFocus(), isFalse);

      await pressPaste(tester, until: () async => await referenceCount() == 1);

      expect(await referenceCount(), 1);
    });

    testWidgets('attaches an image-only paste made from inside a field', (
      tester,
    ) async {
      await pumpScope(tester, _FakeClipboard(image: pngOf(8, 8)));
      await tester.tap(find.byType(TextField));
      await tester.pump();
      expect(textFieldHasFocus(), isTrue);

      await pressPaste(tester, until: () async => await referenceCount() == 1);

      expect(await referenceCount(), 1);
      expect(controller.text, isEmpty);
    });

    testWidgets('a text paste still reaches the field it was aimed at', (
      tester,
    ) async {
      mockSystemClipboard('hello');
      await pumpScope(tester, const _FakeClipboard(text: 'hello'));
      await tester.tap(find.byType(TextField));
      await tester.pump();
      expect(textFieldHasFocus(), isTrue);

      await pressPaste(tester, until: () async => controller.text == 'hello');

      expect(controller.text, 'hello');
      expect(await referenceCount(), 0);
    });

    testWidgets('a text paste with nothing focused does nothing', (
      tester,
    ) async {
      await pumpScope(tester, const _FakeClipboard(text: 'hello'));

      await pressPaste(tester);

      expect(controller.text, isEmpty);
      expect(await referenceCount(), 0);
    });

    testWidgets('an attached image is confirmed by a toast', (tester) async {
      await pumpScope(tester, _FakeClipboard(image: pngOf(8, 8)));

      await pressPaste(tester, until: () async => await referenceCount() == 1);

      // The spinner half of this is asserted in voyager_toast_test.dart: a
      // paste finishes far too fast here to be caught mid-ingest, and the
      // decode it would have to be stalled inside runs on another isolate.
      expect(find.text('Image added'), findsOneWidget);
      expect(find.text('Adding image…'), findsNothing);

      // Let the toast's own dwell run out rather than leaving it up for
      // whatever the next test pumps.
      await tester.pump(const Duration(milliseconds: 1700));
      await tester.pumpAndSettle();
      expect(find.text('Image added'), findsNothing);
    });

    testWidgets('a refused image takes its spinner down with it', (
      tester,
    ) async {
      // Not any image format ingest knows, so it is refused before the decode
      // — the toast has to give way to the reason rather than spin forever.
      await pumpScope(
        tester,
        _FakeClipboard(image: Uint8List.fromList(List.filled(32, 7))),
      );

      await pressPaste(tester);

      expect(await referenceCount(), 0);
      expect(find.text('Adding image…'), findsNothing);
      expect(
        find.text('That does not look like a PNG, JPEG, WebP or HEIC image.'),
        findsOneWidget,
      );
    });
  });
}
