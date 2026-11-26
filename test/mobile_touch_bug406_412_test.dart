import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:irondash_message_channel/irondash_message_channel.dart';
// ignore: implementation_imports
import 'package:super_native_extensions/src/native/context.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/media/media_service.dart';
import 'package:voyager/core/media/widgets/media_gallery_strip.dart';
import 'package:voyager/core/media/widgets/media_image.dart';
import 'package:voyager/core/media/widgets/media_lightbox.dart';
import 'package:voyager/core/media/widgets/media_paste_scope.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/vim/vim_enabled_scope.dart';
import 'package:voyager/core/vim/vim_session.dart';
import 'package:voyager/core/vim/vim_text_overlay.dart';
import 'package:voyager/core/widgets/contextual_popover.dart';
import 'package:voyager/core/widgets/date_selector_popover.dart';
import 'package:voyager/core/widgets/labeled_text_field.dart';
import 'package:voyager/core/widgets/tag_highlighted_text_field.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/data/services/media_file_store.dart';
import 'package:voyager/domain/models/media_models.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/features/settings/dictionary_dialog.dart';
import 'package:voyager/features/shell/shell_page_transition.dart';

Uint8List _png() {
  final image = img.Image(width: 8, height: 8, numChannels: 3);
  img.fill(image, color: img.ColorRgb8(200, 30, 60));
  return img.encodePng(image);
}

/// A file store that never reports low disk, so an attach finishes without
/// shelling out for the free-space query.
class _RoomyFileStore extends MediaFileStore {
  _RoomyFileStore({required super.root});

  @override
  Future<bool> isDiskLow() async => false;
}

class _FakeImage implements LightboxImage {
  @override
  String get id => 'a';
  @override
  ImageProvider? get precache => null;
  @override
  Widget build(BuildContext context) => const SizedBox(width: 100, height: 100);
  @override
  Future<({Uint8List bytes, MediaImageFormat? format})?> read() async => null;
  @override
  String get saveName => 'a';
}

/// Fixes from the mobile audit's M3 and the 2026-11-26 fix pass, on the test
/// binding's default platform, Android, at the OnePlus 12R's 361×794 dp.
void main() {
  void phoneSize(WidgetTester tester, {Size size = const Size(361, 794)}) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  group('BUG-406: the Dictionary dialog on a phone', () {
    late AppDatabase db;
    setUp(() => db = AppDatabase.inMemory());
    tearDown(() => db.close());

    Future<void> open(
      WidgetTester tester, {
      Size size = const Size(361, 794),
      double keyboard = 0,
    }) async {
      phoneSize(tester, size: size);
      final repo = DriftSettingsRepository(db);
      await repo.flagWord('selfie', replacement: 'selfies');
      await repo.flagWord('thew', replacement: 'chew');
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            dictionaryProvider.overrideWith(
              (ref) async => {'selfie', 'selfies', 'thew', 'chew'},
            ),
          ],
          child: MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(viewInsets: EdgeInsets.only(bottom: keyboard)),
              child: child!,
            ),
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => showDictionaryDialog(context),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('a flagged word and its replacement are shown in full', (
      tester,
    ) async {
      await open(tester);
      expect(tester.takeException(), isNull);
      for (final rule in ['selfie → selfies', 'thew → chew']) {
        final paragraph = tester.renderObject<RenderParagraph>(find.text(rule));
        expect(paragraph.didExceedMaxLines, isFalse, reason: rule);
      }
    });

    testWidgets('with the keyboard up at 360×640, the row being edited '
        'scrolls into view and nothing overflows', (tester) async {
      await open(tester, size: const Size(360, 640), keyboard: 300);
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('selfie → selfies'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('selfie → selfies'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final editor = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(EditableText),
      );
      // The search field and the replacement field.
      expect(editor, findsNWidgets(2));
      final rect = tester.getRect(editor.last);
      expect(rect.top, greaterThanOrEqualTo(0));
      expect(rect.bottom, lessThanOrEqualTo(640 - 300));
    });
  });

  group('BUG-407 / BUG-408: images on a touch screen', () {
    late Directory tempDir;
    late AppDatabase db;
    late MediaService service;

    // The gallery strip is a drop target, which registers its formats with a
    // native channel a widget test doesn't have.
    setUpAll(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('dev.irondash.engine_context'),
            (_) async => 1,
          );
      (superNativeExtensionsContext as MockMessageChannelContext)
        ..registerMockMethodCallHandler('DropManager', (_) async => null)
        ..registerMockMethodCallHandler('DragManager', (_) async => null);
    });

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('voyager_touch_media');
      db = AppDatabase.inMemory();
      service = MediaService(
        repository: DriftMediaRepository(db),
        fileStore: MediaFileStore(root: Directory('${tempDir.path}/media')),
        readSettings: () async => const AppSettings(),
      );
    });

    tearDown(() async {
      await db.close();
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    Widget app(Widget body) => ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        mediaServiceProvider.overrideWith((ref) => service),
        mediaFileStoreProvider.overrideWithValue(
          _RoomyFileStore(root: Directory('${tempDir.path}/media')),
        ),
      ],
      child: MaterialApp(home: Scaffold(body: body)),
    );

    Future<int> references() async => (await service.referencesFor(
      FirestoreCollections.journalEntries,
      'entry-1',
    )).length;

    Future<void> waitFor(
      WidgetTester tester,
      Future<bool> Function() until,
    ) async {
      final deadline = DateTime.now().add(const Duration(seconds: 15));
      while (!await until()) {
        if (!DateTime.now().isBefore(deadline)) fail('never happened');
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
    }

    Widget body({required bool fieldTakesBoth}) => MediaPasteScope(
      collection: FirestoreCollections.journalEntries,
      documentId: 'entry-1',
      fieldTakesBoth: fieldTakesBoth,
      child: TagHighlightedTextField(
        controller: TextEditingController(),
        focusNode: FocusNode(),
        maxLines: 5,
      ),
    );

    ContentInsertionConfiguration? insertion(WidgetTester tester) => tester
        .widget<EditableText>(find.byType(EditableText))
        .contentInsertionConfiguration;

    testWidgets('BUG-407: the journal body takes an image from the keyboard', (
      tester,
    ) async {
      await tester.pumpWidget(app(body(fieldTakesBoth: true)));
      final config = insertion(tester)!;
      expect(config.allowedMimeTypes, contains('image/png'));
      // No GIF (MEDIA.md, non-goals).
      expect(config.allowedMimeTypes, isNot(contains('image/gif')));

      await tester.runAsync(() async {
        config.onContentInserted(
          KeyboardInsertedContent(
            mimeType: 'image/png',
            uri: 'content://sticker/1',
            data: _png(),
          ),
        );
      });
      await waitFor(tester, () async => await references() == 1);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('BUG-407: a field beside a gallery offers no image insert', (
      tester,
    ) async {
      await tester.pumpWidget(app(body(fieldTakesBoth: false)));
      expect(insertion(tester), isNull);
    });

    testWidgets('BUG-408: the lightbox removes a strip image, asking first', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final asset = await service.ingestBytes(_png());
        await service.addReference(
          mediaId: asset.id,
          collection: FirestoreCollections.journalEntries,
          documentId: 'entry-1',
        );
      });
      await tester.pumpWidget(
        app(
          const MediaGalleryStrip(
            collection: FirestoreCollections.journalEntries,
            documentId: 'entry-1',
          ),
        ),
      );
      await waitFor(
        tester,
        () async => find.byType(MediaImage).evaluate().isNotEmpty,
      );

      // A finger never hovers, so the thumbnail's own ✕ never shows.
      expect(find.byTooltip('Remove image'), findsNothing);
      await tester.tap(find.byType(MediaImage).first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byTooltip('Remove image'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Remove'), findsOneWidget);
      await tester.tap(find.text('Remove'));
      await tester.pump();
      await waitFor(tester, () async => await references() == 0);
      await tester.pump(const Duration(seconds: 5));
    });
  });

  testWidgets('BUG-409: the lightbox toolbar sits below the status bar', (
    tester,
  ) async {
    phoneSize(tester);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(padding: const EdgeInsets.only(top: 40)),
          child: child!,
        ),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showLightbox(context, images: [_FakeImage()]),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    for (final action in ['Zoom in', 'Close']) {
      expect(
        tester.getRect(find.byTooltip(action)).top,
        greaterThanOrEqualTo(40),
        reason: action,
      );
    }
  });

  testWidgets('BUG-410: an edit from the soft keyboard in Normal mode drops '
      'Vim to Insert, and Vim\'s own edits do not', (tester) async {
    final controller = TextEditingController(text: 'abc');
    final db = AppDatabase.inMemory();
    addTearDown(db.close);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: MaterialApp(
          home: VimEnabledScope(
            enabled: true,
            child: Scaffold(
              body: LabeledTextField(
                label: 'Body',
                controller: controller,
                maxLines: 5,
              ),
            ),
          ),
        ),
      ),
    );
    VimMode? mode() => tester
        .widget<VimTextOverlay>(find.byType(VimTextOverlay))
        .session
        ?.mode;
    await tester.tap(find.byType(TextField));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(mode(), VimMode.normal);

    // Vim's own edit: `x` deletes under the caret and stays in Normal.
    await tester.sendKeyEvent(LogicalKeyboardKey.keyX);
    await tester.pump();
    expect(controller.text, 'ab');
    expect(mode(), VimMode.normal);

    // What Gboard sends: text, with no key event.
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'abq',
        selection: TextSelection.collapsed(offset: 3),
      ),
    );
    await tester.pump();
    expect(controller.text, 'abq');
    expect(mode(), VimMode.insert);
  });

  testWidgets('BUG-410: on desktop an edit in Normal mode (a paste, a menu '
      'action) leaves the mode alone', (tester) async {
    final controller = TextEditingController(text: 'abc');
    final db = AppDatabase.inMemory();
    addTearDown(db.close);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: MaterialApp(
          home: VimEnabledScope(
            enabled: true,
            child: Scaffold(
              body: LabeledTextField(
                label: 'Body',
                controller: controller,
                maxLines: 5,
              ),
            ),
          ),
        ),
      ),
    );
    VimMode? mode() => tester
        .widget<VimTextOverlay>(find.byType(VimTextOverlay))
        .session
        ?.mode;
    await tester.tap(find.byType(TextField));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(mode(), VimMode.normal);

    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'abcq',
        selection: TextSelection.collapsed(offset: 4),
      ),
    );
    await tester.pump();
    expect(controller.text, 'abcq');
    expect(mode(), VimMode.normal);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('BUG-411: closing a dialog does not hand focus back to a field '
      'on a page left since', (tester) async {
    final field = FocusNode();
    addTearDown(field.dispose);
    var index = 0;
    late StateSetter setIndex;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            setIndex = setState;
            return ShellBranchContainer(
              currentIndex: index,
              children: [
                Scaffold(body: TextField(focusNode: field)),
                const Scaffold(body: Text('finance')),
              ],
            );
          },
        ),
      ),
    );
    await tester.tap(find.byType(TextField));
    await tester.pump();
    expect(field.hasFocus, isTrue);

    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    navigator.push(
      DialogRoute<void>(
        context: navigator.context,
        builder: (_) => const Dialog(child: Text('sheet')),
      ),
    );
    await tester.pumpAndSettle();
    expect(field.hasFocus, isFalse);

    // Leaving the page with the dialog still open, as More → Finance does.
    setIndex(() => index = 1);
    await tester.pumpAndSettle();
    navigator.pop();
    await tester.pumpAndSettle();
    expect(field.hasFocus, isFalse);
  });

  testWidgets('BUG-412: Android Back is left to the route, which closes the '
      'date popover', (tester) async {
    final db = AppDatabase.inMemory();
    addTearDown(db.close);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Builder(
                builder: (button) => TextButton(
                  onPressed: () => showContextualPopover<DateTimeRange>(
                    context: context,
                    buttonContext: button,
                    width: kDateSelectorPopoverSize.width,
                    height: kDateSelectorPopoverSize.height,
                    builder: (_) => DateSelectorPopover(
                      initialStartDate: DateTime(2026, 11, 26),
                      initialEndDate: DateTime(2026, 11, 26),
                      singleDateMode: true,
                    ),
                  ),
                  child: const Text('Today'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Today'));
    await tester.pumpAndSettle();
    expect(find.byType(DateSelectorPopover), findsOneWidget);

    // The popover's own key handler must leave Back alone (it claimed every
    // key, so the embedder never turned Back into a route pop).
    final popoverFocus = tester.widget<Focus>(
      find
          .descendant(
            of: find.byType(DateSelectorPopover),
            matching: find.byWidgetPredicate(
              (w) => w is Focus && w.onKeyEvent != null,
            ),
          )
          .first,
    );
    expect(
      popoverFocus.onKeyEvent!(
        FocusNode(),
        const KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.browserBack,
          logicalKey: LogicalKeyboardKey.goBack,
          timeStamp: Duration.zero,
        ),
      ),
      KeyEventResult.ignored,
    );
    // What the embedder does with a Back no key handler claimed.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(DateSelectorPopover), findsNothing);
  });
}
