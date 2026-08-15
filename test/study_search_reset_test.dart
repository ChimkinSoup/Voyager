// The Workbench's control bar — search query, multi-select mode, checked card
// ids — lives in providers that outlive the Workbench, which closing a deck
// unmounts. Anything left behind therefore follows the user into the next
// deck, where it no longer has any on-screen counterpart: a stale query
// filters cards behind a blank field, and a stale selection puts a live
// "N selected" bar over rows that show no checks. The second is destructive
// rather than merely confusing, since the bulk actions take card ids without
// scoping them to the open deck. Opening a deck has to start clean.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/sync/remote_sync_service.dart';
import 'package:voyager/domain/models/study_models.dart';
import 'package:voyager/domain/repositories/repositories.dart';
import 'package:voyager/features/study/study_deck_workbench_page.dart';
import 'package:voyager/features/study/study_page.dart';
import 'package:voyager/features/study/study_providers.dart';

const _deckId = 'deck-1';
const _otherDeckId = 'deck-2';

/// In-memory stand-in for the Drift repository — every study provider the
/// Hub and Workbench read funnels through this one dependency.
class _FakeStudyRepository implements StudyRepository {
  _FakeStudyRepository(this.cardsByDeck);

  final Map<String, List<StudyCard>> cardsByDeck;

  /// Ids passed to a bulk delete, so a test can prove which deck's cards a
  /// cross-deck selection would have reached.
  final deletedIds = <String>[];

  static StudyDeck _deck(String id, String name) => StudyDeck(
    id: id,
    createdAt: DateTime.utc(2026),
    updatedAt: DateTime.utc(2026),
    name: name,
  );

  static final _decks = [
    _deck(_deckId, 'Biology'),
    _deck(_otherDeckId, 'Chemistry'),
  ];

  @override
  Future<List<StudyDeck>> listDecks({
    String? parentFolderId,
    bool includeDeleted = false,
  }) async => parentFolderId == null ? _decks : [];

  @override
  Future<StudyDeck?> getDeck(String id) async =>
      _decks.where((d) => d.id == id).firstOrNull;

  @override
  Future<List<StudyCard>> listCards(
    String deckId, {
    bool includeDeleted = false,
  }) async => cardsByDeck[deckId] ?? const [];

  @override
  Future<void> softDeleteCard(String id) async => deletedIds.add(id);

  @override
  Future<StudyCard?> getCard(String id) async => null;

  @override
  Future<List<StudyFolder>> listFolders({
    String? parentFolderId,
    bool includeDeleted = false,
  }) async => [];

  @override
  Future<int> countDueCardsInDeck(String deckId, {DateTime? now}) async => 0;

  @override
  Future<int> countDueCards({DateTime? now}) async => 0;

  @override
  Future<int> countCardsReviewedToday({DateTime? now}) async => 0;

  @override
  Future<int> countCardsReviewedTotal() async => 0;

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Swallows the push a bulk delete fires. The real service is built from
/// Firebase, which isn't initialised under `flutter test`.
class _NoopRemoteSync implements RemoteSyncService {
  @override
  noSuchMethod(Invocation invocation) => null;
}

List<StudyCard> _cards(String deckId, List<String> fronts) {
  final now = DateTime.utc(2026);
  return [
    for (final front in fronts)
      StudyCard(
        id: 'card-$front',
        createdAt: now,
        updatedAt: now,
        deckId: deckId,
        frontText: front,
        backText: 'about $front',
        dueAt: now,
      ),
  ];
}

Future<_FakeStudyRepository> _pumpHub(WidgetTester tester) async {
  final repo = _FakeStudyRepository({
    _deckId: _cards(_deckId, ['Mitochondria', 'Ribosome', 'Nucleus']),
    _otherDeckId: _cards(_otherDeckId, ['Benzene', 'Alkane']),
  });
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        studyRepositoryProvider.overrideWithValue(repo),
        remoteSyncServiceProvider.overrideWithValue(_NoopRemoteSync()),
      ],
      child: const MaterialApp(home: Scaffold(body: StudyPage())),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  return repo;
}

/// Taps a deck tile in the Hub grid and lets the zoom transition finish.
Future<void> _openDeck(WidgetTester tester, [String name = 'Biology']) async {
  await tester.tap(find.text(name).last);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

/// Leaves via the Workbench's own breadcrumb — the Hub behind it renders a
/// 'Root' pill too, so this scopes to the one actually on screen. Runs the
/// close animation out, since the Workbench only unmounts once it finishes.
Future<void> _leaveDeck(WidgetTester tester) async {
  await tester.tap(
    find.descendant(
      of: find.byType(StudyDeckWorkbenchPage),
      matching: find.text('Root'),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

/// The Workbench control-bar state as the providers currently hold it.
({String query, bool multiSelect, Set<String> selected}) _controlBar(
  WidgetTester tester,
) {
  final container = ProviderScope.containerOf(
    tester.element(find.byType(StudyDeckWorkbenchPage)),
  );
  return (
    query: container.read(studySearchQueryProvider),
    multiSelect: container.read(studyMultiSelectEnabledProvider),
    selected: container.read(studySelectedCardIdsProvider),
  );
}

/// Turns on multi-select and checks the first card in the roster.
Future<void> _selectFirstCard(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Select cards'));
  await tester.pump();
  await tester.tap(find.byType(Checkbox).first);
  await tester.pump();
}

/// A surface wide enough for the card roster and the floating selection bar.
void _useDesktopSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  testWidgets('reopening a deck starts from a clean filter', (tester) async {
    _useDesktopSurface(tester);

    await _pumpHub(tester);
    await _openDeck(tester);
    expect(find.byType(StudyDeckWorkbenchPage), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, 'Mitochondria');
    await tester.pump();
    expect(find.text('Ribosome'), findsNothing);
    expect(_controlBar(tester).query, 'Mitochondria');

    await _leaveDeck(tester);
    expect(find.byType(StudyDeckWorkbenchPage), findsNothing);

    await _openDeck(tester);

    // The remounted field is blank, so the filter behind it must be too —
    // otherwise the deck silently shows one card with nothing explaining why.
    final field = tester.widget<TextField>(find.byType(TextField).first);
    expect(field.controller?.text ?? '', '');
    expect(_controlBar(tester).query, '');
    expect(find.text('Ribosome'), findsOneWidget);
    expect(find.text('Nucleus'), findsOneWidget);
  });

  testWidgets('reopening a deck starts with nothing selected', (tester) async {
    _useDesktopSurface(tester);

    await _pumpHub(tester);
    await _openDeck(tester);

    await _selectFirstCard(tester);
    expect(find.text('1 selected'), findsOneWidget);
    expect(_controlBar(tester).selected, isNotEmpty);

    await _leaveDeck(tester);
    await _openDeck(tester);

    // No checked rows to go with it, so the bar must be gone as well.
    expect(find.text('1 selected'), findsNothing);
    expect(_controlBar(tester).selected, isEmpty);
    expect(_controlBar(tester).multiSelect, isFalse);
  });

  testWidgets('a selection abandoned in one deck cannot delete from another', (
    tester,
  ) async {
    _useDesktopSurface(tester);

    final repo = await _pumpHub(tester);
    await _openDeck(tester);
    await _selectFirstCard(tester);
    await _leaveDeck(tester);

    // Biology's card is the one that was checked; Chemistry is a different
    // deck, and its roster never showed it. The bulk actions take raw card
    // ids, so a selection surviving this hop would reach across decks.
    await _openDeck(tester, 'Chemistry');
    expect(find.text('Benzene'), findsOneWidget);
    expect(find.textContaining('selected'), findsNothing);

    // Then delete for real from Chemistry: the ids that reach the repository
    // are only ever the ones checked in the deck on screen.
    await _selectFirstCard(tester);
    expect(find.text('1 selected'), findsOneWidget);
    await tester.tap(find.text('Delete'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(repo.deletedIds, ['card-Benzene']);
  });
}
