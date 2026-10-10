// BUG-191: a long parent name under "Included in:" and the library's
// floating "+" both took room they had no business taking.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/domain/models/study_models.dart';
import 'package:voyager/features/study/study_deck_workbench_page.dart';
import 'package:voyager/features/study/study_page.dart';

import 'fakes/fake_weather_api_client.dart';

final _now = DateTime.utc(2026, 10, 1);

StudyDeck _deck(String id, String name) =>
    StudyDeck(id: id, name: name, createdAt: _now, updatedAt: _now);

Future<ProviderContainer> _container() async {
  final db = AppDatabase.inMemory();
  addTearDown(db.close);
  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      syncRepositoryProvider.overrideWithValue(InMemorySyncRepository()),
      weatherApiClientProvider.overrideWithValue(FakeWeatherApiClient()),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Future<void> _pump(
  WidgetTester tester,
  ProviderContainer container,
  Widget home,
  Size size,
) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: Scaffold(body: home)),
    ),
  );
  for (var i = 0; i < 20; i++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  testWidgets('BUG-191 a long name under "Included in:" stays on one line', (
    tester,
  ) async {
    final container = await _container();
    final repo = container.read(studyRepositoryProvider);
    final longName = 'L${'x' * 298}Z';
    await repo.upsertDeck(_deck('parent', longName));
    await repo.upsertDeck(_deck('child', 'Child'));
    await repo.upsertDeckLink(
      StudyDeckLink(
        id: 'link',
        createdAt: _now,
        updatedAt: _now,
        parentDeckId: 'parent',
        childDeckId: 'child',
      ),
    );

    await _pump(
      tester,
      container,
      StudyDeckWorkbenchPage(
        deckId: 'child',
        folderStack: const [],
        onBack: () {},
        onJumpToRoot: () {},
        onJumpToFolder: (_) {},
        onOpenDeck: (_) {},
      ),
      const Size(1440, 1040),
    );

    final name = find.text(longName);
    expect(name, findsOneWidget);
    final label = tester.getSize(find.text('Included in: '));
    final size = tester.getSize(name);
    expect(size.height, label.height, reason: 'one line, like its label');
    expect(size.width, lessThanOrEqualTo(240));
  });

  testWidgets('BUG-191 at the minimum size no library tile slides under the '
      '"+"', (tester) async {
    final container = await _container();
    final repo = container.read(studyRepositoryProvider);
    for (var i = 0; i < 8; i++) {
      await repo.upsertDeck(_deck('deck-$i', 'Deck $i'));
    }

    await _pump(tester, container, const StudyPage(), const Size(720, 520));

    final fab = tester.getRect(
      find.ancestor(
        of: find.byIcon(PhosphorIconsRegular.plus),
        matching: find.byType(GlassButton),
      ),
    );
    final grid = tester.getRect(find.byType(GridView));
    expect(grid.bottom, lessThanOrEqualTo(fab.top));
  });
}
