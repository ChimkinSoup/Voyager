import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/snippets/snippet_enabled_scope.dart';
import 'package:voyager/core/snippets/snippet_index.dart';
import 'package:voyager/core/snippets/snippet_settings_launcher.dart';
import 'package:voyager/core/vim/vim_enabled_scope.dart';
import 'package:voyager/core/widgets/labeled_text_field.dart';
import 'package:voyager/core/widgets/snippet_editor.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/settings_models.dart';

/// Right-click → **Add snippet**, end to end: the menu item's gating, the
/// trigger it prefills, and what the popover writes.
///
/// The field under test is deliberately **single-line**, the case that had no
/// right-click menu at all before this flow existed.
void main() {
  late AppDatabase db;
  late DriftSettingsRepository repo;
  late TextEditingController controller;
  late FocusNode focusNode;

  setUp(() {
    db = AppDatabase.inMemory();
    repo = DriftSettingsRepository(db);
    controller = TextEditingController();
    focusNode = FocusNode();
  });

  tearDown(() async {
    controller.dispose();
    focusNode.dispose();
    await db.close();
  });

  Future<void> pumpField(
    WidgetTester tester, {
    String text = 'hello world',
    bool enabled = true,
    bool snippetsAllowed = true,
    int maxLines = 1,
    Set<String> dictionary = const {},
    List<String> manageOpened = const [],
  }) async {
    // Wide enough for the 560px quick-add popover to land unclipped.
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final field = LabeledTextField(
      label: 'Body',
      controller: controller,
      focusNode: focusNode,
      maxLines: maxLines,
      snippetsAllowed: snippetsAllowed,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          dictionaryProvider.overrideWith((ref) async => dictionary),
        ],
        child: MaterialApp(
          home: VimEnabledScope(
            enabled: false,
            child: SnippetEnabledScope(
              data: SnippetScopeData(
                enabled: enabled,
                expandKey: SnippetExpandKey.tab,
                index: SnippetIndex.empty,
              ),
              child: Scaffold(
                body: Consumer(
                  builder: (context, ref, _) {
                    // Warmed here the way a real page does it: the quick-add
                    // panel has nothing to validate against until settings
                    // have loaded, and would otherwise open on a spinner.
                    ref.watch(settingsProvider);
                    return SnippetSettingsLauncher(
                      open: (_) => manageOpened.add('opened'),
                      child: Center(child: SizedBox(width: 400, child: field)),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
    // Text is filled in after the first settle, and before the field takes
    // focus: that is the one moment a multiline field runs a spellcheck pass
    // of its own (see [forceSpellCheckDisplay]), and by then the dictionary
    // future has resolved into the service.
    await tester.pumpAndSettle();
    controller.text = text;
    controller.selection = TextSelection.collapsed(offset: text.length);
    await tester.pump();
    focusNode.requestFocus();
    await tester.pumpAndSettle();
  }

  /// Right-clicks the field [dx] pixels into its text, the way a mouse does:
  /// the app's own [Listener] selects the word on pointer-down, Flutter's
  /// secondary-tap recognizer opens the toolbar on the way up.
  Future<void> rightClick(WidgetTester tester, {double dx = 4}) async {
    final origin = tester.getTopLeft(find.byType(EditableText));
    final size = tester.getSize(find.byType(EditableText));
    final gesture = await tester.startGesture(
      origin + Offset(dx, size.height / 2),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
  }

  /// The quick-add popover's two boxes, in order: Trigger, then Replacement.
  Finder editorFields() => find.descendant(
    of: find.byType(SnippetEditor),
    matching: find.byType(EditableText),
  );

  Future<void> openQuickAdd(WidgetTester tester) async {
    await rightClick(tester);
    await tester.tap(find.text('Add snippet'));
    await tester.pumpAndSettle();
  }

  /// Drains the "Snippet saved" toast so it doesn't outlive the test.
  Future<void> settleToast(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  }

  group('the menu item', () {
    testWidgets('a correct word offers Add snippet on its own', (tester) async {
      await pumpField(tester);
      await rightClick(tester);

      expect(find.text('Add snippet'), findsOneWidget);
      // Nothing spellcheck-related: the word is not flagged.
      expect(find.text('Add to dictionary'), findsNothing);
      // The word under the pointer was selected to become the trigger.
      expect(controller.selection.textInside(controller.text), 'hello');
    });

    testWidgets('nothing is shown when snippets are switched off', (
      tester,
    ) async {
      await pumpField(tester, enabled: false);
      await rightClick(tester);
      expect(find.text('Add snippet'), findsNothing);
    });

    testWidgets('nothing is shown on a field that opts out', (tester) async {
      await pumpField(tester, snippetsAllowed: false);
      await rightClick(tester);
      expect(find.text('Add snippet'), findsNothing);
    });

    testWidgets('a misspelled word keeps its own items, and goes first', (
      tester,
    ) async {
      await pumpField(
        tester,
        text: 'helo',
        maxLines: 3,
        dictionary: const {'hello'},
      );
      await rightClick(tester);

      expect(find.text('hello'), findsOneWidget); // the correction
      expect(find.text('Add to dictionary'), findsOneWidget);
      // Add snippet sits below everything the spellchecker offers.
      expect(
        tester.getCenter(find.text('Add snippet')).dy,
        greaterThan(tester.getCenter(find.text('Add to dictionary')).dy),
      );
    });

    testWidgets('whitespace under the pointer is not a trigger', (
      tester,
    ) async {
      await pumpField(tester, text: '    hello');
      await rightClick(tester, dx: 2);

      expect(controller.selection.textInside(controller.text).trim(), isEmpty);
      expect(find.text('Add snippet'), findsNothing);
    });
  });

  group('the trigger', () {
    testWidgets('an existing selection survives the right-click', (
      tester,
    ) async {
      await pumpField(tester);
      controller.selection = const TextSelection(
        baseOffset: 0,
        extentOffset: 11,
      );
      await tester.pump();

      await openQuickAdd(tester);

      // The whole selection, not just the word the pointer landed on.
      expect(
        tester.widget<EditableText>(editorFields().at(0)).controller.text,
        'hello world',
      );
    });

    testWidgets('the clicked word prefills it, with focus on Replacement', (
      tester,
    ) async {
      await pumpField(tester);
      await openQuickAdd(tester);

      expect(
        tester.widget<EditableText>(editorFields().at(0)).controller.text,
        'hello',
      );
      expect(
        tester.widget<EditableText>(editorFields().at(1)).focusNode.hasFocus,
        isTrue,
      );
    });
  });

  group('saving', () {
    testWidgets('writes the snippet, confirms, and hands focus back', (
      tester,
    ) async {
      await pumpField(tester);
      await openQuickAdd(tester);
      await tester.enterText(editorFields().at(1), 'Hello there');
      await tester.tap(find.byTooltip('Save snippet'));
      await tester.pumpAndSettle();

      final saved = (await repo.getSettings()).snippets;
      expect(saved.single.trigger, 'hello');
      expect(saved.single.replacement, 'Hello there');
      // Both flags default off, whatever the user's other snippets do.
      expect(saved.single.autoExpand, isFalse);
      expect(saved.single.wordBoundary, isFalse);

      expect(find.text('Snippet saved'), findsOneWidget);
      expect(focusNode.hasFocus, isTrue);
      await settleToast(tester);
    });

    testWidgets('a duplicate trigger is refused without closing', (
      tester,
    ) async {
      await repo.saveSettings(
        (await repo.getSettings()).copyWith(
          snippets: const [
            Snippet(id: 'a', trigger: 'hello', replacement: 'hi'),
          ],
        ),
      );
      await pumpField(tester);
      await openQuickAdd(tester);
      await tester.tap(find.byTooltip('Save snippet'));
      await tester.pumpAndSettle();

      expect(
        find.text('Another snippet already uses "hello".'),
        findsOneWidget,
      );
      expect((await repo.getSettings()).snippets, hasLength(1));
    });

    testWidgets('an emptied trigger is refused', (tester) async {
      await pumpField(tester);
      await openQuickAdd(tester);
      await tester.enterText(editorFields().at(0), '   ');
      await tester.tap(find.byTooltip('Save snippet'));
      await tester.pumpAndSettle();

      expect(find.text('Give the snippet a trigger.'), findsOneWidget);
      expect((await repo.getSettings()).snippets, isEmpty);
    });

    testWidgets('cancel writes nothing and hands focus back', (tester) async {
      await pumpField(tester);
      await openQuickAdd(tester);
      await tester.tap(find.byTooltip('Cancel'));
      await tester.pumpAndSettle();

      expect((await repo.getSettings()).snippets, isEmpty);
      expect(find.byType(SnippetEditor), findsNothing);
      expect(focusNode.hasFocus, isTrue);
    });
  });

  testWidgets('Manage all snippets drops the draft and opens the list', (
    tester,
  ) async {
    final opened = <String>[];
    await pumpField(tester, manageOpened: opened);
    await openQuickAdd(tester);
    await tester.enterText(editorFields().at(1), 'half written');
    await tester.tap(find.text('Manage all snippets…'));
    await tester.pumpAndSettle();

    expect(opened, ['opened']);
    expect(find.byType(SnippetEditor), findsNothing);
    expect((await repo.getSettings()).snippets, isEmpty);
  });
}
