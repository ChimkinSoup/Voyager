// The rankings mappers, on the cases a round trip cannot reach: a remote that
// predates a field, and a remote that deliberately cleared one. Both arrive as
// "no value" if you only look at `data['x'] == null`, and they mean opposite
// things.

import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/sync/firestore_document_mapper.dart';
import 'package:voyager/domain/models/ranking_models.dart';

final _older = DateTime.utc(2026, 1, 1);
final _newer = DateTime.utc(2026, 2, 1);

RankingParent localParent({
  double? score,
  bool starred = false,
  RankingStatus status = RankingStatus.queued,
  List<String> tags = const [],
}) => RankingParent(
  id: 'p1',
  categoryId: 'cat',
  title: 'Severance',
  overallScore: score,
  starred: starred,
  status: status,
  tags: tags,
  createdAt: _older,
  updatedAt: _older,
  version: 1,
);

Map<String, dynamic> remote(Map<String, dynamic> overrides) => {
  'categoryId': 'cat',
  'title': 'Severance',
  'updatedAt': _newer.toIso8601String(),
  'version': 2,
  ...overrides,
};

void main() {
  group('Parent merge', () {
    test('an explicit null score demotes the local copy', () {
      final merged = mergeRankingParentFromRemote(
        remote({'overallScore': null}),
        'p1',
        local: localParent(score: 9),
      );
      // The other device cleared the score. Treating that as "no news" would
      // leave this device showing the entry as still ranked.
      expect(merged.overallScore, isNull);
      expect(merged.isRanked, isFalse);
    });

    test('a payload with no score key at all keeps the local one', () {
      final merged = mergeRankingParentFromRemote(
        remote({}),
        'p1',
        local: localParent(score: 9),
      );
      expect(merged.overallScore, 9);
    });

    test('field values survive the trip, notes-only ones included', () {
      final parent = localParent().copyWith(
        fieldValues: const {
          'f1': RankingFieldValue(score: 4.5, notes: 'tight'),
          'f2': RankingFieldValue(notes: 'unscored'),
          'f3': RankingFieldValue(),
        },
      );
      final payload = rankingParentToFirestore(parent);
      final merged = mergeRankingParentFromRemote(payload, parent.id);

      expect(merged.fieldValues['f1']!.score, 4.5);
      expect(merged.fieldValues['f1']!.notes, 'tight');
      expect(merged.fieldValues['f2']!.score, isNull);
      expect(merged.fieldValues['f2']!.notes, 'unscored');
      // An empty value is not written, so it does not come back as one either.
      expect(merged.fieldValues.containsKey('f3'), isFalse);
    });

    test('the local copy wins when it is the newer version', () {
      final local = localParent(score: 9).copyWith(version: 5);
      final merged = mergeRankingParentFromRemote(
        {
          ...remote({'overallScore': 2}),
          'version': 3,
        },
        'p1',
        local: local,
      );
      expect(merged.overallScore, 9);
    });

    test('the star and the status round trip', () {
      final parent = localParent(
        starred: true,
        status: RankingStatus.inProgress,
      );
      final merged = mergeRankingParentFromRemote(
        rankingParentToFirestore(parent),
        parent.id,
      );
      expect(merged.starred, isTrue);
      expect(merged.status, RankingStatus.inProgress);
    });

    test('tags round trip in the order they were added', () {
      final parent = localParent(tags: ['rom-com', 'a24']);
      final merged = mergeRankingParentFromRemote(
        rankingParentToFirestore(parent),
        parent.id,
      );
      expect(merged.tags, ['rom-com', 'a24']);
    });

    test('a payload written before tags existed keeps the local ones', () {
      final merged = mergeRankingParentFromRemote(
        remote({}),
        'p1',
        local: localParent(tags: ['thai']),
      );
      expect(merged.tags, ['thai']);
    });

    test('a legacy payload on a device that has none loads empty', () {
      final merged = mergeRankingParentFromRemote(remote({}), 'p1');
      expect(merged.tags, isEmpty);
    });

    test('another device clearing every tag clears them here', () {
      final merged = mergeRankingParentFromRemote(
        remote({'tags': <String>[]}),
        'p1',
        local: localParent(tags: ['thai']),
      );
      expect(merged.tags, isEmpty);
    });

    test('a remote tag written by an older build is normalized on the way in', () {
      final merged = mergeRankingParentFromRemote(
        remote({
          'tags': ['#Thai', 'rom com', 'THAI'],
        }),
        'p1',
      );
      expect(merged.tags, ['thai']);
    });
  });

  group('Category merge', () {
    RankingCategory local({String? sortFieldId, DateTime? archivedAt}) =>
        RankingCategory(
          id: 'c1',
          name: 'Shows',
          colorValue: 0xFF7C9EFF,
          sortMode: RankingSortMode.customField,
          sortFieldId: sortFieldId,
          archivedAt: archivedAt,
          createdAt: _older,
          updatedAt: _older,
          version: 1,
        );

    test('templates round trip with their removed fields', () {
      final category = local().copyWith(
        parentTemplate: [
          const RankingTemplateField(
            id: 'f1',
            label: 'Writing',
            sortOrder: 0,
            scoreMax: 10,
          ),
          RankingTemplateField(
            id: 'f2',
            label: 'Retired',
            sortOrder: 1,
            removedAt: _older,
          ),
        ],
      );
      final merged = mergeRankingCategoryFromRemote(
        rankingCategoryToFirestore(category),
        category.id,
      );

      expect(merged.parentTemplate, hasLength(2));
      expect(merged.activeParentTemplate.single.label, 'Writing');
      expect(merged.activeParentTemplate.single.scoreMax, 10);
      // The orphan has to survive, or the values entries hold against it stop
      // being restorable on this device.
      expect(merged.parentTemplate.last.isRemoved, isTrue);
    });

    test('precision round-trips, and carries a legacy boolean along', () {
      final payload = rankingCategoryToFirestore(
        local().copyWith(
          parentScorePrecision: RankingScorePrecision.tenths,
          childScorePrecision: RankingScorePrecision.integers,
        ),
      );

      expect(payload['parentScorePrecision'], 'tenths');
      expect(payload['childScorePrecision'], 'integers');
      // Written for a device still on the build before precision existed:
      // without it, that device reads nothing and pushes its own stale
      // setting back over a tenths category.
      expect(payload['parentHalfStepsEnabled'], isTrue);
      expect(payload['childHalfStepsEnabled'], isFalse);

      final merged = mergeRankingCategoryFromRemote(payload, 'c1');
      expect(merged.parentScorePrecision, RankingScorePrecision.tenths);
      expect(merged.childScorePrecision, RankingScorePrecision.integers);
    });

    test('a payload written before precision reads its booleans', () {
      final merged = mergeRankingCategoryFromRemote(
        {
          'name': 'Shows',
          'parentHalfStepsEnabled': false,
          'childHalfStepsEnabled': true,
          'updatedAt': _newer.toIso8601String(),
          'version': 2,
        },
        'c1',
        local: local(),
      );
      expect(merged.parentScorePrecision, RankingScorePrecision.integers);
      expect(merged.childScorePrecision, RankingScorePrecision.half);
    });

    test('the enum wins over a boolean that disagrees with it', () {
      // An old device that pushed `true` back alongside an untouched enum
      // must not be able to drag a tenths category down to halves.
      final merged = mergeRankingCategoryFromRemote(
        {
          'name': 'Shows',
          'parentScorePrecision': 'tenths',
          'parentHalfStepsEnabled': true,
          'updatedAt': _newer.toIso8601String(),
          'version': 2,
        },
        'c1',
        local: local(),
      );
      expect(merged.parentScorePrecision, RankingScorePrecision.tenths);
    });

    test('an explicit null sort field clears the local one', () {
      final merged = mergeRankingCategoryFromRemote(
        {
          'name': 'Shows',
          'sortMode': 'overallScore',
          'sortFieldId': null,
          'updatedAt': _newer.toIso8601String(),
          'version': 2,
        },
        'c1',
        local: local(sortFieldId: 'f1'),
      );
      expect(merged.sortFieldId, isNull);
    });

    test('a payload with no sort field key keeps the local one', () {
      final merged = mergeRankingCategoryFromRemote(
        {'name': 'Shows', 'updatedAt': _newer.toIso8601String(), 'version': 2},
        'c1',
        local: local(sortFieldId: 'f1'),
      );
      expect(merged.sortFieldId, 'f1');
    });

    test('unarchiving on another device unarchives here', () {
      final merged = mergeRankingCategoryFromRemote(
        {
          'name': 'Shows',
          'archivedAt': null,
          'updatedAt': _newer.toIso8601String(),
          'version': 2,
        },
        'c1',
        local: local(archivedAt: _older),
      );
      expect(merged.archivedAt, isNull);
      expect(merged.isArchived, isFalse);
    });
  });

  group('Child merge', () {
    test('a cleared score comes across as cleared', () {
      final local = RankingChild(
        id: 'ch1',
        parentId: 'p1',
        name: 'Pilot',
        overallScore: 4,
        createdAt: _older,
        updatedAt: _older,
        version: 1,
      );
      final merged = mergeRankingChildFromRemote(
        {
          'parentId': 'p1',
          'name': 'Pilot',
          'overallScore': null,
          'updatedAt': _newer.toIso8601String(),
          'version': 2,
        },
        'ch1',
        local: local,
      );
      expect(merged.overallScore, isNull);
    });
  });
}
