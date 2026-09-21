import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/features/settings/dictionary_dialog.dart';

/// Stands in for the 65k-word asset. Frequency-ordered, like the real one.
const _bundled = {'the', 'so', 'say', 'sad'};

void main() {
  late AppDatabase db;
  late DriftSettingsRepository repo;

  setUp(() {
    db = AppDatabase.inMemory();
    repo = DriftSettingsRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  Future<void> openDialog(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          dictionaryProvider.overrideWith((ref) async => _bundled),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showDictionaryDialog(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  /// Types into the search box. The rename editor mounts a second field below
  /// it, so the search box is the first one.
  Future<void> type(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField).first, text);
    await tester.pumpAndSettle();
  }

  testWidgets('typing a word and pressing + adds it', (tester) async {
    await openDialog(tester);
    await type(tester, 'voyager');
    await tester.tap(find.byTooltip('Add word'));
    await tester.pumpAndSettle();

    expect(await repo.getCustomWords(), {'voyager'});
    // And it is now listed as the user's own, with the controls to prove it.
    expect(find.byTooltip('Rename word'), findsOneWidget);
    expect(find.byTooltip('Remove word'), findsOneWidget);
  });

  testWidgets('a word the bundled list already has cannot be added', (
    tester,
  ) async {
    await openDialog(tester);
    await type(tester, 'the');

    final add = tester.widget<GlassButton>(
      find.ancestor(
        of: find.byTooltip('"the" is already known'),
        matching: find.byType(GlassButton),
      ),
    );
    expect(add.onPressed, isNull);
    // The bundled row is the answer instead: read-only, nothing to remove.
    expect(find.byTooltip('In the built-in dictionary'), findsOneWidget);
    expect(find.byTooltip('Remove word'), findsNothing);
  });

  testWidgets('search finds bundled words, ranked, without listing all', (
    tester,
  ) async {
    await openDialog(tester);
    await type(tester, 'sa');
    expect(find.byTooltip('In the built-in dictionary'), findsNWidgets(2));
    expect(find.text('say'), findsOneWidget);
    expect(find.text('sad'), findsOneWidget);
    expect(find.text('the'), findsNothing);
  });

  testWidgets('a new search starts at the top of the results', (tester) async {
    // Enough words to overflow the list, all of them still matching the query
    // below — so an offset that survived would be a real one, not a clamp.
    for (var i = 0; i < 40; i++) {
      final suffix =
          String.fromCharCode(97 + i ~/ 26) + String.fromCharCode(97 + i % 26);
      await repo.addCustomWord('theword$suffix');
    }
    await openDialog(tester);

    ScrollController listController() =>
        tester.widget<ListView>(find.byType(ListView)).controller!;

    await tester.drag(find.byType(ListView), const Offset(0, -200));
    await tester.pumpAndSettle();
    expect(listController().offset, greaterThan(0));

    await type(tester, 'the');
    expect(listController().offset, 0);
  });

  testWidgets('a custom word can be renamed', (tester) async {
    await repo.addCustomWord('voyagr');
    await openDialog(tester);

    await tester.tap(find.byTooltip('Rename word'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'voyager');
    await tester.tap(find.byTooltip('Save word'));
    await tester.pumpAndSettle();

    expect(await repo.getCustomWords(), {'voyager'});
  });

  testWidgets('renaming onto a bundled word just removes the custom one', (
    tester,
  ) async {
    await repo.addCustomWord('teh');
    await openDialog(tester);

    await tester.tap(find.byTooltip('Rename word'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'the');
    await tester.tap(find.byTooltip('Save word'));
    await tester.pumpAndSettle();

    expect(await repo.getCustomWords(), isEmpty);
    expect(
      find.text('Removed "teh" — "the" is already in the dictionary.'),
      findsOneWidget,
    );
  });

  testWidgets('removing a custom word takes it back out', (tester) async {
    await repo.addCustomWord('voyager');
    await openDialog(tester);

    await tester.tap(find.byTooltip('Remove word'));
    await tester.pumpAndSettle();

    expect(await repo.getCustomWords(), isEmpty);
    expect(find.byTooltip('Remove word'), findsNothing);
  });

  testWidgets('a two-word entry is rejected with a reason', (tester) async {
    await openDialog(tester);
    await type(tester, 'well known');
    await tester.tap(find.byTooltip('Add word'));
    await tester.pumpAndSettle();

    expect(await repo.getCustomWords(), isEmpty);
    expect(
      find.textContaining('A dictionary word is one word'),
      findsOneWidget,
    );
  });

  // `FLAGGED_WORDS.md` §7: the third override the dialog manages.
  group('flagged words', () {
    testWidgets('a bundled row can be flagged, with a replacement', (
      tester,
    ) async {
      await openDialog(tester);
      await type(tester, 'sad');

      await tester.tap(find.byTooltip('Flag as misspelling'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'say');
      await tester.tap(find.byTooltip('Flag word'));
      await tester.pumpAndSettle();

      expect(await repo.getFlaggedWords(), {'sad': 'say'});
    });

    testWidgets('flagging with no replacement is a flag on its own', (
      tester,
    ) async {
      await openDialog(tester);
      await type(tester, 'sad');

      await tester.tap(find.byTooltip('Flag as misspelling'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, '');
      await tester.tap(find.byTooltip('Flag word'));
      await tester.pumpAndSettle();

      expect(await repo.getFlaggedWords(), {'sad': null});
    });

    testWidgets('a replacement the checker does not know is refused', (
      tester,
    ) async {
      await openDialog(tester);
      await type(tester, 'sad');

      await tester.tap(find.byTooltip('Flag as misspelling'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'sadd');
      await tester.tap(find.byTooltip('Flag word'));
      await tester.pumpAndSettle();

      expect(await repo.getFlaggedWords(), isEmpty);
      expect(find.textContaining('add it to the'), findsOneWidget);
    });

    testWidgets('a flagged word is one row, not also a faint bundled one', (
      tester,
    ) async {
      await repo.flagWord('sad', replacement: 'say');
      await openDialog(tester);
      await type(tester, 'sad');

      expect(find.text('sad → say'), findsOneWidget);
      expect(find.byTooltip('In the built-in dictionary'), findsNothing);
      expect(find.byTooltip('Stop flagging'), findsOneWidget);
    });

    testWidgets('the empty query lists flags beside custom words', (
      tester,
    ) async {
      await repo.addCustomWord('voyager');
      await repo.flagWord('sad');
      await openDialog(tester);

      expect(find.text('voyager'), findsOneWidget);
      // No arrow: the flag carries no replacement.
      expect(find.text('sad'), findsOneWidget);
      expect(find.text('Flagged'), findsOneWidget);
    });

    testWidgets('editing a flagged row can clear the replacement', (
      tester,
    ) async {
      await repo.flagWord('sad', replacement: 'say');
      await openDialog(tester);

      await tester.tap(find.byTooltip('Edit replacement'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, '');
      await tester.tap(find.byTooltip('Save replacement'));
      await tester.pumpAndSettle();

      // Clearing the replacement keeps the flag.
      expect(await repo.getFlaggedWords(), {'sad': null});
    });

    testWidgets('stop flagging puts a bundled word back', (tester) async {
      await repo.flagWord('sad', replacement: 'say');
      await openDialog(tester);

      await tester.tap(find.byTooltip('Stop flagging'));
      await tester.pumpAndSettle();

      expect(await repo.getFlaggedWords(), isEmpty);
      expect(await repo.getCustomWords(), isEmpty);
    });

    testWidgets('adding a flagged bundled word clears the flag', (
      tester,
    ) async {
      // Allow wins (§4), and a bundled spelling gains no redundant custom row.
      await repo.flagWord('sad');
      await openDialog(tester);
      await type(tester, 'sad');

      await tester.tap(find.byTooltip('Add word'));
      await tester.pumpAndSettle();

      expect(await repo.getFlaggedWords(), isEmpty);
      expect(await repo.getCustomWords(), isEmpty);
      expect(find.textContaining('No longer flagging "sad"'), findsOneWidget);
    });

    testWidgets('flagging the target of an existing pair is refused', (
      tester,
    ) async {
      await repo.flagWord('sad', replacement: 'say');
      await openDialog(tester);
      await type(tester, 'say');

      await tester.tap(find.byTooltip('Flag as misspelling'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Flag word'));
      await tester.pumpAndSettle();

      expect(await repo.getFlaggedWords(), {'sad': 'say'});
      expect(find.textContaining('already replaces with it'), findsOneWidget);
    });
  });
}
