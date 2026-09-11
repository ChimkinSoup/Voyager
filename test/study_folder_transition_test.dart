// Opening a folder slides its contents in over the level being left, and the
// departing grid is stacked on top while the two cross. It has to get out of
// the way early: the AnimatedSwitcher reads its out-curve along the reversed
// animation, so an ease-out spring there held the old grid — the folder just
// tapped included — almost fully opaque and in place for most of the switch,
// then dropped it in the last few frames.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/domain/models/study_models.dart';
import 'package:voyager/domain/repositories/repositories.dart';
import 'package:voyager/features/study/study_page.dart';

const _outerId = 'folder-outer';

StudyFolder _folder(String id, String name, {String? parentFolderId}) =>
    StudyFolder(
      id: id,
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
      name: name,
      parentFolderId: parentFolderId,
    );

final _outer = _folder(_outerId, 'Biology');
final _inner = _folder('folder-inner', 'Cells', parentFolderId: _outerId);

/// A root holding one folder, which holds another. Folders only, so no deck
/// tile pulls in per-deck stats.
class _FakeStudyRepository implements StudyRepository {
  @override
  Future<List<StudyFolder>> listFolders({
    String? parentFolderId,
    bool includeDeleted = false,
  }) async => switch (parentFolderId) {
    null => [_outer],
    _outerId => [_inner],
    _ => [],
  };

  @override
  Future<StudyFolder?> getFolder(String id) async =>
      [_outer, _inner].where((f) => f.id == id).firstOrNull;

  @override
  Future<List<StudyDeck>> listDecks({
    String? parentFolderId,
    bool includeDeleted = false,
  }) async => [];

  @override
  Future<int> countDueCards({DateTime? now}) async => 0;

  @override
  Future<int> countCardsReviewedToday({DateTime? now}) async => 0;

  @override
  Future<int> countCardsReviewedTotal() async => 0;

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('the folder just opened leaves early in the switch', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          studyRepositoryProvider.overrideWithValue(_FakeStudyRepository()),
        ],
        child: const MaterialApp(home: Scaffold(body: StudyPage())),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    await tester.tap(find.text('Biology'));
    await tester.pump();
    // 30% of the 260ms switch.
    await tester.pump(const Duration(milliseconds: 78));

    // The breadcrumb now names 'Biology' too, and the page route has fades
    // of its own, so look only inside the switcher: there the one match is
    // the departing grid's tile, under the departing grid's fade.
    final inSwitcher = find.byType(AnimatedSwitcher);
    final departing = tester.widget<FadeTransition>(
      find.ancestor(
        of: find.descendant(of: inSwitcher, matching: find.text('Biology')),
        matching: find.descendant(
          of: inSwitcher,
          matching: find.byType(FadeTransition),
        ),
      ),
    );
    // Was still 1.0 here; now down to ~0.12.
    expect(departing.opacity.value, lessThan(0.5));
    expect(find.text('Cells'), findsOneWidget);
  });
}
