import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/snippets/snippet_enabled_scope.dart';
import 'package:voyager/core/snippets/snippet_index.dart';
import 'package:voyager/core/spellcheck/autocorrect_enabled_scope.dart';
import 'package:voyager/core/vim/vim_enabled_scope.dart';
import 'package:voyager/core/widgets/labeled_text_field.dart';
import 'package:voyager/core/widgets/text_field_context_menu.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/enums.dart';

/// Right-click → **Flag as misspelling…**, end to end: which menu the three
/// states in `FLAGGED_WORDS.md` §8 produce, what the popover writes, and what
/// "Replace this one" does to the occurrence that was clicked (§6).
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
    String text = 'neve mind',
    int? maxLines = 3,
    Set<String> dictionary = const {'neve', 'never', 'nerve', 'mind'},
  }) async {
    // Wide enough for the flag popover to land unclipped.
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

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
                enabled: false,
                expandKey: SnippetExpandKey.tab,
                index: SnippetIndex.empty,
              ),
              child: Scaffold(
                body: Consumer(
                  builder: (context, ref, _) {
                    ref.watch(settingsProvider);
                    // The same scope the app root installs: the service
                    // travels with it whether or not the toggle is on.
                    return AutocorrectEnabledScope(
                      data: AutocorrectScopeData(
                        enabled: true,
                        service: ref.watch(voyagerSpellCheckServiceProvider),
                      ),
                      child: Center(
                        child: SizedBox(
                          width: 400,
                          child: LabeledTextField(
                            label: 'Body',
                            controller: controller,
                            focusNode: focusNode,
                            maxLines: maxLines,
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    controller.text = text;
    controller.selection = TextSelection.collapsed(offset: text.length);
    await tester.pump();
    focusNode.requestFocus();
    await tester.pumpAndSettle();
  }

  /// Right-clicks [dx] pixels into the field's text, the way a mouse does.
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

  /// The popover's replacement box — the second field on screen, after the
  /// one under test.
  Finder replacementField() => find.byType(EditableText).last;

  Future<void> openFlagPopover(WidgetTester tester) async {
    await rightClick(tester);
    await tester.tap(find.text('Flag as misspelling…'));
    await tester.pumpAndSettle();
  }

  /// Drains a toast so it doesn't outlive the test.
  Future<void> settleToast(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  }

  group('the menu item', () {
    testWidgets('an open menu survives its field rebuilding', (tester) async {
      await pumpField(tester, text: 'helo mind');
      await rightClick(tester);
      expect(find.text('Add to dictionary'), findsOneWidget);
      final menu = tester.state(find.byType(TextFieldContextMenu));

      // What an autosave landing does: the field rebuilds while the menu is
      // up. A new contextMenuBuilder would make EditableText tear the menu
      // down and re-show a new one a frame later — the blink.
      tester.element(find.byType(LabeledTextField)).markNeedsBuild();
      await tester.pumpAndSettle();
      expect(tester.state(find.byType(TextFieldContextMenu)), same(menu));
    });

    testWidgets('right-clicking another word while the menu is open reopens it '
        'for that word', (tester) async {
      // `helo` second: the menu opens rightward from the click, so the next
      // right-click lands on `mind` rather than on the menu.
      await pumpField(tester, text: 'mind helo');
      final editable = tester
          .state<EditableTextState>(find.byType(EditableText))
          .renderEditable;
      final helo = editable.getLocalRectForCaret(const TextPosition(offset: 6));
      await rightClick(tester, dx: helo.left);
      expect(find.text('Add to dictionary'), findsOneWidget);

      // Flutter ends a desktop right-click with toggleToolbar, which closes a
      // menu that is still up unless the pointer-down already hid it.
      await rightClick(tester);

      expect(find.text('Add to dictionary'), findsNothing);
      expect(find.text('Flag as misspelling…'), findsOneWidget);
    });

    testWidgets('a word the checker accepts offers Flag', (tester) async {
      await pumpField(tester);
      await rightClick(tester);

      expect(find.text('Flag as misspelling…'), findsOneWidget);
      expect(find.text('Add to dictionary'), findsNothing);
    });

    testWidgets('an unknown word keeps Add to dictionary, not Flag', (
      tester,
    ) async {
      await pumpField(tester, text: 'helo mind');
      await rightClick(tester);

      expect(find.text('Add to dictionary'), findsOneWidget);
      expect(find.text('Flag as misspelling…'), findsNothing);
    });

    testWidgets('a flagged word gets Stop flagging and its pair first', (
      tester,
    ) async {
      await repo.flagWord('neve', replacement: 'nerve');
      await pumpField(tester);
      await rightClick(tester);

      expect(find.text('Stop flagging'), findsOneWidget);
      expect(find.text('Add to dictionary'), findsNothing);
      expect(find.text('Flag as misspelling…'), findsNothing);
      // The stored replacement is pinned above the generated suggestions, and
      // not repeated among them.
      expect(find.text('nerve'), findsOneWidget);
      final items = tester.widgetList<Text>(find.byType(Text)).toList();
      final labels = [for (final t in items) t.data];
      expect(labels.indexOf('nerve'), lessThan(labels.indexOf('never')));
    });

    testWidgets('Flag is not offered in a field with no squiggles', (
      tester,
    ) async {
      // §8: a single-line field is not spellchecked, so it has no business
      // offering to flag a word. Its existing spelling items are untouched.
      await pumpField(tester, maxLines: 1);
      await rightClick(tester);
      expect(find.text('Flag as misspelling…'), findsNothing);
    });

    testWidgets('Stop flagging clears the flag and its replacement', (
      tester,
    ) async {
      await repo.flagWord('neve', replacement: 'nerve');
      await pumpField(tester);
      await rightClick(tester);
      await tester.tap(find.text('Stop flagging'));
      await tester.pumpAndSettle();

      expect(await repo.getFlaggedWords(), isEmpty);
      // Allow wins does not mean a redundant custom row for a bundled word.
      expect(await repo.getCustomWords(), isEmpty);
    });
  });

  group('the popover', () {
    testWidgets('Flag with no replacement writes a flag-only row', (
      tester,
    ) async {
      await pumpField(tester);
      await openFlagPopover(tester);
      await tester.enterText(replacementField(), '');
      await tester.tap(find.text('Flag'));
      await tester.pumpAndSettle();

      expect(await repo.getFlaggedWords(), {'neve': null});
      // No second question, and no toast, for a flag on its own.
      expect(find.text('Replace this one'), findsNothing);
    });

    testWidgets('a replacement is prefilled from the suggestions', (
      tester,
    ) async {
      await pumpField(tester);
      await openFlagPopover(tester);

      final prefill = tester.widget<EditableText>(replacementField());
      // Generated against the set with this word already taken out, so the
      // answer is a real alternative rather than the word itself.
      expect(prefill.controller.text, isNot('neve'));
      expect(['never', 'nerve'], contains(prefill.controller.text));
    });

    testWidgets('saving a pair asks about the occurrence that was clicked', (
      tester,
    ) async {
      await pumpField(tester);
      await openFlagPopover(tester);
      await tester.enterText(replacementField(), 'never');
      await tester.tap(find.text('Flag'));
      await tester.pumpAndSettle();

      expect(await repo.getFlaggedWords(), {'neve': 'never'});
      expect(find.text('Replace this one'), findsOneWidget);
      expect(find.text('Leave it'), findsOneWidget);
    });

    testWidgets('Leave it keeps the flag and the word', (tester) async {
      await pumpField(tester);
      await openFlagPopover(tester);
      await tester.enterText(replacementField(), 'never');
      await tester.tap(find.text('Flag'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Leave it'));
      await tester.pumpAndSettle();

      expect(await repo.getFlaggedWords(), {'neve': 'never'});
      expect(controller.text, 'neve mind');
    });

    testWidgets('Replace this one rewrites only that occurrence', (
      tester,
    ) async {
      await pumpField(tester, text: 'neve say neve');
      await openFlagPopover(tester);
      await tester.enterText(replacementField(), 'never');
      await tester.tap(find.text('Flag'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Replace this one'));
      await tester.pumpAndSettle();

      // The second `neve` is left to squiggle — §5.2, no document walk.
      expect(controller.text, 'never say neve');
      await settleToast(tester);
    });

    testWidgets('a replacement the checker does not know is refused', (
      tester,
    ) async {
      await pumpField(tester);
      await openFlagPopover(tester);
      await tester.enterText(replacementField(), 'nevar');
      await tester.tap(find.text('Flag'));
      await tester.pumpAndSettle();

      expect(await repo.getFlaggedWords(), isEmpty);
      expect(find.textContaining('add it to the'), findsOneWidget);
    });

    testWidgets('flagging a custom-only word just removes the custom row', (
      tester,
    ) async {
      // §4: remove already makes it unknown, so there is nothing a flag row
      // would add.
      await repo.addCustomWord('voyagr');
      await pumpField(tester, text: 'voyagr mind');
      await openFlagPopover(tester);
      await tester.enterText(replacementField(), '');
      await tester.tap(find.text('Flag'));
      await tester.pumpAndSettle();

      expect(await repo.getCustomWords(), isEmpty);
      expect(await repo.getFlaggedWords(), isEmpty);
    });
  });
}
