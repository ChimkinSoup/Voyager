// Phase 16 Life fixes: the bucket list's add field is focused on open and
// keeps focus after a blank Enter (BUG-136), Tab stays inside the tree popover
// (BUG-137), a long title wraps instead of being cut (BUG-140), and fallen
// leaves no longer stack into a column at the ground's edges (BUG-139).

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/life_tracker_models.dart';
import 'package:voyager/features/life_tracker/bucket_list_popup.dart';
import 'package:voyager/features/life_tracker/life_tree_canvas.dart';
import 'package:voyager/features/life_tracker/life_tree_geometry.dart';
import 'package:voyager/features/life_tracker/life_tree_popover.dart';

import 'fakes/fake_weather_api_client.dart';

/// Opens the bucket list in its tree popover over a page that has a button of
/// its own, and returns the repository.
Future<DriftBucketListRepository> _open(
  WidgetTester tester, {
  List<String> titles = const ['Climb'],
}) async {
  tester.view.physicalSize = const Size(900, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final db = AppDatabase.inMemory();
  addTearDown(db.close);
  final repo = DriftBucketListRepository(db);
  final now = utcNow();
  for (final (i, title) in titles.indexed) {
    await repo.upsertItem(
      BucketListItem(
        id: 'item-$i',
        title: title,
        sortOrder: i,
        createdAt: now,
        updatedAt: now,
      ),
    );
  }

  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      syncRepositoryProvider.overrideWithValue(InMemorySyncRepository()),
      weatherApiClientProvider.overrideWithValue(FakeWeatherApiClient()),
    ],
  );
  addTearDown(container.dispose);
  await container.read(bucketListItemsProvider.future);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        // The popover goes on a nested navigator, beside a control outside
        // it — the shell's other pages, in the app.
        home: Scaffold(
          body: Row(
            children: [
              TextButton(onPressed: () {}, child: const Text('outside')),
              Expanded(
                child: Navigator(
                  onGenerateRoute: (_) => MaterialPageRoute<void>(
                    builder: (context) => TextButton(
                      onPressed: () => showTreePopover<void>(
                        context: context,
                        anchorGlobalCenter: const Offset(450, 450),
                        width: 480,
                        height: 460,
                        builder: (_) =>
                            const BucketListPopup(accentColor: Colors.green),
                      ),
                      child: const Text('page button'),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('page button'));
  await tester.pumpAndSettle();
  return repo;
}

FocusNode _addFieldNode(WidgetTester tester) =>
    tester.widget<TextField>(find.byType(TextField).last).focusNode!;

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  testWidgets('BUG-136 the add field is focused on open and after a blank '
      'Enter', (tester) async {
    await _open(tester);
    expect(_addFieldNode(tester).hasFocus, isTrue);

    await tester.enterText(find.byType(TextField).last, '   ');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(_addFieldNode(tester).hasFocus, isTrue);
  });

  testWidgets('BUG-137 Tab cycles inside the popover', (tester) async {
    await _open(tester);
    for (var i = 0; i < 8; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      final focused = FocusManager.instance.primaryFocus!.context!;
      expect(
        focused.findAncestorWidgetOfExactType<BucketListPopup>(),
        isNotNull,
        reason: 'Tab ${i + 1} left the popover',
      );
    }
  });

  testWidgets('BUG-140 a long title wraps and the row grows', (tester) async {
    final long = 'L${'x' * 298}Z';
    await _open(tester, titles: [long, 'Short']);
    final title = tester.renderObject<RenderParagraph>(find.text(long));
    expect(title.didExceedMaxLines, isFalse);
    expect(title.size.height, greaterThan(40));
    // A short title keeps the old one-line height.
    expect(tester.getSize(find.text('Short')).height, lessThan(24));
  });

  test('BUG-139 no two fallen leaves share an x at the edges', () {
    final geometry = generateLifeTreeGeometry();
    final xs = [
      for (var i = 0; i < 4160; i++) groundPositionFor(i, geometry).dx,
    ];
    expect(xs.every((x) => x >= 0.04 && x <= 0.96), isTrue);
    expect(xs.where((x) => x == 0.96 || x == 0.04), isEmpty);
  });
}
