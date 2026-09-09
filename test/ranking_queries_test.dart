import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/domain/models/ranking_models.dart';
import 'package:voyager/domain/rankings/ranking_queries.dart';

final _base = DateTime.utc(2026, 8, 1);

RankingParent parent(
  String id, {
  double? score,
  RankingStatus status = RankingStatus.queued,
  bool starred = false,
  int queueSortOrder = 0,
  String notes = '',
  List<String> tags = const [],
  Map<String, RankingFieldValue> fieldValues = const {},
  int updatedDays = 0,
  int createdDays = 0,
  String? title,
}) => RankingParent(
  id: id,
  categoryId: 'cat',
  title: title ?? id,
  overallScore: score,
  status: status,
  starred: starred,
  queueSortOrder: queueSortOrder,
  notes: notes,
  tags: tags,
  fieldValues: fieldValues,
  createdAt: _base.add(Duration(days: createdDays)),
  updatedAt: _base.add(Duration(days: updatedDays)),
);

RankingChild child(
  String id, {
  double? score,
  int sortOrder = 0,
  String notes = '',
  String? name,
  Map<String, RankingFieldValue> fieldValues = const {},
}) => RankingChild(
  id: id,
  parentId: 'p1',
  name: name ?? id,
  overallScore: score,
  notes: notes,
  fieldValues: fieldValues,
  sortOrder: sortOrder,
  createdAt: _base,
  updatedAt: _base,
);

List<String> ids(Iterable<RankingParent> parents) => [
  for (final parent in parents) parent.id,
];

void main() {
  group('Scoring', () {
    test('snaps to the step of the mode and clamps into the scale', () {
      expect(roundRankingScore(3.3, scoreMax: 5, precision: RankingScorePrecision.half), 3.5);
      expect(roundRankingScore(3.3, scoreMax: 5, precision: RankingScorePrecision.integers), 3);
      expect(roundRankingScore(-2, scoreMax: 5, precision: RankingScorePrecision.half), 0);
      expect(roundRankingScore(99, scoreMax: 10, precision: RankingScorePrecision.half), 10);
    });

    test('midpoint follows the scale and its steps', () {
      expect(rankingFieldMidpoint(5, precision: RankingScorePrecision.half), 2.5);
      // In integer mode 2.5 is not a value the scale can hold, so the
      // midpoint has to be one of the whole values either side of it.
      expect(rankingFieldMidpoint(5, precision: RankingScorePrecision.integers), 3);
      expect(rankingFieldMidpoint(10, precision: RankingScorePrecision.half), 5);
    });

    test('average from children skips the unscored ones', () {
      final average = rankingAverageFromChildren(
        [child('a', score: 4), child('b'), child('c', score: 5)],
        scoreMax: 5,
        precision: RankingScorePrecision.half,
      );
      // 4 and 5 average to 4.5; the unscored child is not a zero.
      expect(average, 4.5);
    });

    test('average is null when no child has a score', () {
      expect(
        rankingAverageFromChildren(
          [child('a'), child('b')],
          scoreMax: 5,
          precision: RankingScorePrecision.half,
        ),
        isNull,
      );
    });

    test('average rounds to the parent steps, not the children', () {
      final average = rankingAverageFromChildren(
        [child('a', score: 4), child('b', score: 5)],
        scoreMax: 5,
        precision: RankingScorePrecision.integers,
      );
      expect(average, 5);
    });

    test('rescale carries a score onto the other scale', () {
      expect(rescaleRankingScore(8, fromMax: 10, toMax: 5, precision: RankingScorePrecision.half), 4);
      expect(
        rescaleRankingScore(9, fromMax: 10, toMax: 5, precision: RankingScorePrecision.half),
        4.5,
      );
      // Lossy going down in integer mode: 4.5 has nowhere to land.
      expect(
        rescaleRankingScore(9, fromMax: 10, toMax: 5, precision: RankingScorePrecision.integers),
        5,
      );
      expect(
        rescaleRankingScore(3.5, fromMax: 5, toMax: 10, precision: RankingScorePrecision.half),
        7,
      );
    });

    test('formats whole scores without a trailing zero', () {
      expect(formatRankingScore(9), '9');
      expect(formatRankingScore(9.5), '9.5');
      expect(formatRankingScore(8.4), '8.4');
      // Never `8.0`: a whole score reads as a whole number in every mode
      // (HLD §4).
      expect(
        formatRankingScore(
          roundRankingScore(
            8.02,
            scoreMax: 10,
            precision: RankingScorePrecision.tenths,
          ),
        ),
        '8',
      );
    });

    test('tenths land exactly, so neighbours stay distinguishable', () {
      final low = roundRankingScore(
        8.3,
        scoreMax: 10,
        precision: RankingScorePrecision.tenths,
      );
      final high = roundRankingScore(
        8.4,
        scoreMax: 10,
        precision: RankingScorePrecision.tenths,
      );
      // Not `closeTo`: rank ties are exact equality (§12.14), so a snapped
      // tenth has to *be* the double 8.3 rather than drift near it.
      expect(low, 8.3);
      expect(high, 8.4);
      expect(low == high, isFalse);
      expect(formatRankingScore(low), '8.3');
      expect(formatRankingScore(high), '8.4');
    });

    test('each mode snaps 8.4 to its own grid', () {
      expect(
        roundRankingScore(
          8.4,
          scoreMax: 10,
          precision: RankingScorePrecision.integers,
        ),
        8,
      );
      expect(
        roundRankingScore(
          8.4,
          scoreMax: 10,
          precision: RankingScorePrecision.half,
        ),
        8.5,
      );
      expect(
        roundRankingScore(
          8.4,
          scoreMax: 10,
          precision: RankingScorePrecision.tenths,
        ),
        8.4,
      );
    });

    test('a score off the grid is what makes a mode change warn', () {
      // 8.4 survives tenths untouched and has to move under either of the
      // coarser modes — which is exactly the condition §8.1 warns on.
      expect(
        rankingScoreIsOnStep(
          8.4,
          scoreMax: 10,
          precision: RankingScorePrecision.tenths,
        ),
        isTrue,
      );
      expect(
        rankingScoreIsOnStep(
          8.4,
          scoreMax: 10,
          precision: RankingScorePrecision.half,
        ),
        isFalse,
      );
      expect(
        rankingScoreIsOnStep(
          8.5,
          scoreMax: 10,
          precision: RankingScorePrecision.half,
        ),
        isTrue,
      );
    });

    test('zero is a score, not the absence of one', () {
      final zero = roundRankingScore(
        -0.4,
        scoreMax: 5,
        precision: RankingScorePrecision.tenths,
      );
      expect(zero, 0);
      expect(formatRankingScore(zero), '0');
    });

    test('a field follows the overall until it opts out', () {
      const field = RankingTemplateField(id: 'f', label: 'Plot', sortOrder: 0);
      expect(
        rankingFieldPrecision(
          field,
          overallPrecision: RankingScorePrecision.tenths,
        ),
        RankingScorePrecision.tenths,
      );

      final own = field.copyWith(
        inheritPrecision: false,
        scorePrecision: RankingScorePrecision.integers,
      );
      expect(
        rankingFieldPrecision(
          own,
          overallPrecision: RankingScorePrecision.tenths,
        ),
        RankingScorePrecision.integers,
      );

      // Opted out without choosing: the overall is still the only answer
      // there is, rather than a hardcoded default.
      final orphaned = field.copyWith(inheritPrecision: false);
      expect(
        rankingFieldPrecision(
          orphaned,
          overallPrecision: RankingScorePrecision.half,
        ),
        RankingScorePrecision.half,
      );
    });

    test('a field carries its precision through JSON', () {
      const field = RankingTemplateField(
        id: 'f',
        label: 'Plot',
        sortOrder: 0,
        inheritPrecision: false,
        scorePrecision: RankingScorePrecision.tenths,
      );
      final decoded = decodeRankingTemplate(encodeRankingTemplate([field]));
      expect(decoded.single.inheritPrecision, isFalse);
      expect(decoded.single.scorePrecision, RankingScorePrecision.tenths);

      // A template written before precision existed inherits, which is what
      // keeps every field already out there on the overall's step.
      final legacy = decodeRankingTemplate(
        '[{"id":"f","label":"Plot","sortOrder":0}]',
      );
      expect(legacy.single.inheritPrecision, isTrue);
      expect(legacy.single.scorePrecision, isNull);
    });

    test('the legacy half-step boolean maps onto a mode', () {
      expect(
        RankingScorePrecision.fromHalfSteps(true),
        RankingScorePrecision.half,
      );
      expect(
        RankingScorePrecision.fromHalfSteps(false),
        RankingScorePrecision.integers,
      );
      // And back, for the boolean an older build still reads.
      expect(RankingScorePrecision.tenths.halfStepsEquivalent, isTrue);
      expect(RankingScorePrecision.integers.halfStepsEquivalent, isFalse);
    });
  });

  group('Lifecycle rules', () {
    test('a non-title edit promotes a queued entry to in progress', () {
      final before = parent('p1');
      final after = applyRankingEditRules(
        before,
        before.copyWith(notes: 'started it'),
      );
      expect(after.status, RankingStatus.inProgress);
    });

    test('a title-only edit leaves it queued', () {
      final before = parent('p1');
      final after = applyRankingEditRules(
        before,
        before.copyWith(title: 'Renamed'),
      );
      expect(after.status, RankingStatus.queued);
    });

    test('a field score promotes it too', () {
      final before = parent('p1');
      final after = applyRankingEditRules(
        before,
        before.copyWith(fieldValues: {'f1': const RankingFieldValue(score: 3)}),
      );
      expect(after.status, RankingStatus.inProgress);
    });

    test('a status the user set by hand is not overwritten', () {
      final before = parent('p1');
      final after = applyRankingEditRules(
        before,
        before.copyWith(status: RankingStatus.inProgress, notes: 'x'),
      );
      expect(after.status, RankingStatus.inProgress);

      final backToQueue = applyRankingEditRules(
        after,
        after.copyWith(status: RankingStatus.queued),
      );
      expect(backToQueue.status, RankingStatus.queued);
    });

    test('promoting to ranked clears the star', () {
      final before = parent('p1', starred: true);
      final after = applyRankingEditRules(
        before,
        before.copyWith(overallScore: 4),
      );
      expect(after.isRanked, isTrue);
      expect(after.starred, isFalse);
    });

    test('clearing the score demotes to in progress and clears the star', () {
      final before = parent('p1', score: 4, starred: true);
      final after = applyRankingEditRules(
        before,
        before.copyWith(clearOverallScore: true),
      );
      expect(after.isRanked, isFalse);
      expect(after.status, RankingStatus.inProgress);
      expect(after.starred, isFalse);
    });

    test('a star survives an edit that does not cross sections', () {
      final before = parent('p1', score: 4, starred: true);
      final after = applyRankingEditRules(
        before,
        before.copyWith(overallScore: 5),
      );
      expect(after.starred, isTrue);
    });
  });

  group('Ranked sort', () {
    test('defaults to score descending, ties on recency', () {
      final rows = sortRankedParents([
        parent('low', score: 3, updatedDays: 9),
        parent('tieOld', score: 5, updatedDays: 1),
        parent('tieNew', score: 5, updatedDays: 4),
      ], sortMode: RankingSortMode.overallScore);
      expect(ids(rows), ['tieNew', 'tieOld', 'low']);
    });

    test('unranked entries never appear', () {
      final rows = sortRankedParents([
        parent('queued'),
        parent('ranked', score: 1),
      ], sortMode: RankingSortMode.overallScore);
      expect(ids(rows), ['ranked']);
    });

    test('stars pin to the top, ordered among themselves by the key', () {
      final rows = sortRankedParents([
        parent('top', score: 10),
        parent('starLow', score: 1, starred: true),
        parent('starHigh', score: 4, starred: true),
      ], sortMode: RankingSortMode.overallScore);
      expect(ids(rows), ['starHigh', 'starLow', 'top']);
    });

    test('ascending flips the key but not the star pinning', () {
      final rows = sortRankedParents(
        [
          parent('a', score: 2),
          parent('b', score: 8),
          parent('star', score: 5, starred: true),
        ],
        sortMode: RankingSortMode.overallScore,
        ascending: true,
      );
      expect(ids(rows), ['star', 'a', 'b']);
    });

    test('a custom-field sort drops entries with no value for it', () {
      final rows = sortRankedParents(
        [
          parent(
            'scored',
            score: 1,
            fieldValues: {'f1': const RankingFieldValue(score: 2)},
          ),
          parent('unscoredField', score: 9),
          parent(
            'notesOnly',
            score: 8,
            fieldValues: {'f1': const RankingFieldValue(notes: 'hm')},
          ),
        ],
        sortMode: RankingSortMode.customField,
        sortFieldId: 'f1',
      );
      // Only the entry with a stored *score* for f1 survives — a note about
      // the field is not a position on it.
      expect(ids(rows), ['scored']);
    });

    test('sorts by createdAt in the direction asked for', () {
      final rows = sortRankedParents(
        [
          parent('old', score: 1, createdDays: 0),
          parent('new', score: 1, createdDays: 5),
        ],
        sortMode: RankingSortMode.createdAt,
        ascending: true,
      );
      expect(ids(rows), ['old', 'new']);
    });
  });

  group('Unranked sort', () {
    test('stars, then in progress, then the queue in its manual order', () {
      final rows = sortUnrankedParents([
        parent('q2', queueSortOrder: 2),
        parent('q1', queueSortOrder: 1),
        parent('running', status: RankingStatus.inProgress, updatedDays: 1),
        parent('starred', queueSortOrder: 9, starred: true),
      ]);
      expect(ids(rows), ['starred', 'running', 'q1', 'q2']);
    });

    test('in-progress entries lead with the most recently touched', () {
      final rows = sortUnrankedParents([
        parent('older', status: RankingStatus.inProgress, updatedDays: 1),
        parent('newer', status: RankingStatus.inProgress, updatedDays: 6),
      ]);
      expect(ids(rows), ['newer', 'older']);
    });

    test('ranked entries never appear', () {
      final rows = sortUnrankedParents([
        parent('ranked', score: 3),
        parent('queued'),
      ]);
      expect(ids(rows), ['queued']);
    });
  });

  group('Queue drag', () {
    // The list the user drags in: a star and an in-progress row above three
    // queued ones, which are the only rows the queue actually orders.
    List<RankingParent> unranked() => sortUnrankedParents([
      parent('star', starred: true),
      parent('running', status: RankingStatus.inProgress),
      parent('q0', queueSortOrder: 0),
      parent('q1', queueSortOrder: 1),
      parent('q2', queueSortOrder: 2),
    ]);

    test('moving a queued row down lands it where it was dropped', () {
      final rows = unranked();
      expect(ids(rows), ['star', 'running', 'q0', 'q1', 'q2']);
      // q0 (index 2) dropped at the end of the list.
      expect(rankingQueueOrderAfterDrag(rows, 2, 4), ['q1', 'q2', 'q0']);
    });

    test('moving a queued row up lands it where it was dropped', () {
      final rows = unranked();
      // q2 (index 4) dropped just under the in-progress row.
      expect(rankingQueueOrderAfterDrag(rows, 4, 2), ['q2', 'q0', 'q1']);
    });

    test('a drop into the pinned block lands at the top of the queue', () {
      final rows = unranked();
      // q2 dropped above the star, which the queue has no position for.
      expect(rankingQueueOrderAfterDrag(rows, 4, 0), ['q2', 'q0', 'q1']);
    });

    test('a row the queue does not order cannot be dragged', () {
      final rows = unranked();
      expect(rankingQueueOrderAfterDrag(rows, 0, 3), isNull);
      expect(rankingQueueOrderAfterDrag(rows, 1, 3), isNull);
    });
  });

  group('Search and filters', () {
    final children = {
      'p1': [child('c1', name: 'Good News About Hell', notes: 'cold #open')],
      'p2': <RankingChild>[],
    };

    test('a hit inside a child surfaces its parent', () {
      final rows = filterRankingParents(
        [parent('p1', title: 'Severance'), parent('p2', title: 'Andor')],
        childrenByParent: children,
        query: 'hell',
        filters: RankingFilters.none,
      );
      expect(ids(rows), ['p1']);
    });

    test('every term has to hit somewhere', () {
      final rows = filterRankingParents(
        [parent('p1', title: 'Severance', notes: 'slow burn')],
        childrenByParent: children,
        query: 'severance burn',
        filters: RankingFilters.none,
      );
      expect(ids(rows), ['p1']);

      final missed = filterRankingParents(
        [parent('p1', title: 'Severance', notes: 'slow burn')],
        childrenByParent: children,
        query: 'severance western',
        filters: RankingFilters.none,
      );
      expect(missed, isEmpty);
    });

    test('the tag filter matches structured tags', () {
      final rows = filterRankingParents(
        [
          parent('p1', tags: ['thai']),
          parent('p2', tags: ['korean']),
        ],
        childrenByParent: children,
        query: '',
        filters: const RankingFilters(tag: 'thai'),
      );
      expect(ids(rows), ['p1']);
    });

    test('the tag filter ignores note tags on the parent and its children', () {
      final rows = filterRankingParents(
        [parent('p1', notes: 'ate #thai here')],
        childrenByParent: children,
        query: '',
        filters: const RankingFilters(tag: 'thai'),
      );
      expect(rows, isEmpty);

      // 'c1' carries '#open' in its notes; the filter no longer reaches it.
      final viaChild = filterRankingParents(
        [parent('p1')],
        childrenByParent: children,
        query: '',
        filters: const RankingFilters(tag: 'open'),
      );
      expect(viaChild, isEmpty);
    });

    test('a structured tag and the same note tag are one hit', () {
      final rows = filterRankingParents(
        [
          parent('p1', tags: ['thai'], notes: 'proper #thai'),
        ],
        childrenByParent: children,
        query: 'thai',
        filters: const RankingFilters(tag: 'thai'),
      );
      expect(ids(rows), ['p1']);
    });

    test('search finds a structured tag the title never mentions', () {
      final rows = filterRankingParents(
        [
          parent('p1', title: 'Anatomy of a Fall', tags: ['courtroom']),
          parent('p2', title: 'Past Lives'),
        ],
        childrenByParent: children,
        query: 'courtroom',
        filters: RankingFilters.none,
      );
      expect(ids(rows), ['p1']);
    });

    test('has-images counts a picture on a child', () {
      final rows = filterRankingParents(
        [parent('p1'), parent('p2')],
        childrenByParent: children,
        query: '',
        filters: const RankingFilters(hasImages: true),
        documentIdsWithImages: {'c1'},
      );
      expect(ids(rows), ['p1']);
    });

    test('the status filter leaves ranked entries alone', () {
      final rows = filterRankingParents(
        [
          parent('ranked', score: 5),
          parent('queued'),
          parent('running', status: RankingStatus.inProgress),
        ],
        childrenByParent: const {},
        query: '',
        filters: const RankingFilters(statuses: {RankingStatus.inProgress}),
      );
      // The ranked entry has no queued/in-progress state left to match on, so
      // narrowing the unranked section does not hide it.
      expect(ids(rows), ['ranked', 'running']);
    });

    test('the score range leaves unranked entries alone', () {
      final rows = filterRankingParents(
        [parent('low', score: 2), parent('high', score: 9), parent('queued')],
        childrenByParent: const {},
        query: '',
        filters: const RankingFilters(scoreMin: 8),
      );
      expect(ids(rows), ['high', 'queued']);
    });
  });

  group('Status chips', () {
    test('an empty chip set shows every unranked row', () {
      final rows = filterUnrankedByStatus([
        parent('queued'),
        parent('running', status: RankingStatus.inProgress),
      ], const {});
      expect(ids(rows), ['queued', 'running']);
    });

    test('a chip narrows to its own status', () {
      final rows = filterUnrankedByStatus([
        parent('queued'),
        parent('running', status: RankingStatus.inProgress),
      ], const {RankingStatus.inProgress});
      expect(ids(rows), ['running']);
    });
  });

  group('Rank numbers', () {
    test('a tier states its rank once and the next score skips past it', () {
      final ranks = rankingDisplayRanks([
        parent('a', score: 10),
        parent('b', score: 10),
        parent('c', score: 10),
        parent('d', score: 9),
        parent('e', score: 8),
      ]);
      expect(ranks, [1, null, null, 4, 5]);
    });

    test('every score distinct numbers straight through', () {
      final ranks = rankingDisplayRanks([
        parent('a', score: 5),
        parent('b', score: 3),
        parent('c', score: 1),
      ]);
      expect(ranks, [1, 2, 3]);
    });

    test('a pinned row carries its tier rank, not its list position', () {
      // A starred 5 sits at the top of the list, but the number is a fact
      // about the score: three 10s beat it, so it is fourth.
      final ranks = rankingDisplayRanks([
        parent('pinned', score: 5, starred: true),
        parent('a', score: 10),
        parent('b', score: 10),
        parent('c', score: 10),
      ]);
      expect(ranks, [4, 1, null, null]);
    });

    test('a pinned row inside a tie takes the number from it', () {
      // The tier is split across the list by the pinning, and states its rank
      // at the first row of it either way.
      final ranks = rankingDisplayRanks([
        parent('pinned', score: 10, starred: true),
        parent('a', score: 10),
        parent('b', score: 9),
      ]);
      expect(ranks, [1, null, 3]);
    });
  });

  group('Stats and progress', () {
    test('counts and averages only what is ranked', () {
      final stats = rankingCategoryStats([
        parent('a', score: 4),
        parent('b', score: 5),
        parent('c'),
        parent('d', status: RankingStatus.inProgress),
      ]);
      expect(stats.ranked, 2);
      expect(stats.queued, 1);
      expect(stats.inProgress, 1);
      expect(stats.average, 4.5);
    });

    test('no ranked entries means no average, not zero', () {
      final stats = rankingCategoryStats([parent('a'), parent('b')]);
      expect(stats.ranked, 0);
      expect(stats.average, isNull);
    });

    test('child progress counts the scored ones', () {
      final progress = rankingChildProgress([
        child('a', score: 1),
        child('b'),
        child('c', score: 2),
      ]);
      expect(progress.scored, 2);
      expect(progress.total, 3);
    });
  });

  group('Child view sorts', () {
    final children = [
      child('c1', name: 'Zulu', score: 2, sortOrder: 0),
      child('c2', name: 'Alpha', sortOrder: 1),
      child('c3', name: 'Mike', score: 5, sortOrder: 2),
    ];

    test('the saved order is the manual one', () {
      expect(
        [for (final c in sortRankingChildrenForView(children)) c.id],
        ['c1', 'c2', 'c3'],
      );
    });

    test('by score puts the unscored last rather than hiding them', () {
      final rows = sortRankingChildrenForView(
        children,
        sort: RankingChildSort.overallScore,
      );
      expect([for (final c in rows) c.id], ['c3', 'c1', 'c2']);
    });

    test('by name is alphabetical and case-insensitive', () {
      final rows = sortRankingChildrenForView(
        children,
        sort: RankingChildSort.name,
      );
      expect([for (final c in rows) c.id], ['c2', 'c3', 'c1']);
    });

    test('a view sort never rewrites the saved order', () {
      final rows = sortRankingChildrenForView(
        children,
        sort: RankingChildSort.name,
      );
      expect([for (final c in rows) c.sortOrder], [1, 2, 0]);
    });
  });

  group('Tags', () {
    test('the vocab is the structured tags, sorted and deduped', () {
      final tags = rankingTags([
        parent('p1', tags: ['scifi', 'slow']),
        parent('p2', tags: ['slow', 'anime']),
      ]);
      expect(tags, ['anime', 'scifi', 'slow']);
    });

    test('a note tag never reaches the vocab', () {
      final tags = rankingTags([
        parent('p1', notes: 'watch #scifi later', tags: ['anime']),
      ]);
      expect(tags, ['anime']);
    });

    test('suggestions are ranked by usage, ties alphabetical', () {
      final suggestions = rankingTagSuggestions([
        parent('p1', tags: ['slow', 'anime']),
        parent('p2', tags: ['slow', 'thriller']),
        parent('p3', tags: ['slow']),
      ]);
      expect(suggestions, ['slow', 'anime', 'thriller']);
    });

    group('normalization', () {
      test('strips a leading hash and lowercases', () {
        expect(normalizeRankingTags(['#Thai', 'ROM-COM']), ['thai', 'rom-com']);
      });

      test('refuses a space rather than hyphenating it', () {
        expect(normalizeRankingTags(['rom com']), isEmpty);
      });

      test('drops punctuation and edge hyphens', () {
        expect(
          normalizeRankingTags(['thai!', '-thai', 'thai-', 'th--ai']),
          isEmpty,
        );
      });

      test('dedupes case-insensitively, keeping the first', () {
        expect(normalizeRankingTags(['Thai', 'thai', 'THAI']), ['thai']);
      });

      test('keeps the first ten and ignores the rest', () {
        final tags = normalizeRankingTags([
          for (var i = 0; i < 14; i++) 'tag$i',
        ]);
        expect(tags.length, maxRankingParentTags);
        expect(tags.first, 'tag0');
        expect(tags.last, 'tag9');
      });

      test('keeps the order the user added them in', () {
        expect(normalizeRankingTags(['zulu', 'alpha']), ['zulu', 'alpha']);
      });
    });
  });

  group('Edit rules', () {
    test('a tag-only edit leaves a queued entry queued', () {
      final before = parent('p1');
      final after = applyRankingEditRules(
        before,
        before.copyWith(tags: ['thai']),
      );
      expect(after.status, RankingStatus.queued);
      expect(after.tags, ['thai']);
    });

    test('tags edited alongside notes still promote', () {
      final before = parent('p1');
      final after = applyRankingEditRules(
        before,
        before.copyWith(tags: ['thai'], notes: 'went back'),
      );
      expect(after.status, RankingStatus.inProgress);
    });
  });
}
