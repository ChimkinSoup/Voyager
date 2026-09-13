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

  group('Per-field merge', () {
    final base = DateTime.utc(2026, 3, 1);
    final t1 = DateTime.utc(2026, 3, 2);
    final t2 = DateTime.utc(2026, 3, 3);

    /// One entry as both devices started from it, stamped at [base].
    RankingParent start() => RankingParent(
      id: 'p1',
      categoryId: 'cat',
      title: 'Severance',
      notes: '',
      createdAt: base,
      updatedAt: base,
      version: 3,
    );

    /// Every stamp a row carries once `copyWith` has touched it: [base] for
    /// each field, with [changed] moved on.
    RankingFieldStamps stampsFor(
      Map<String, Object?> values,
      Map<String, DateTime> changed,
    ) => {for (final key in values.keys) key: base, ...changed};

    test('a note typed on one device and a score set on another both '
        'survive', () {
      // This device typed a note at t1, and wrote a lot doing it.
      final localRow = RankingParent(
        id: 'p1',
        categoryId: 'cat',
        title: 'Severance',
        notes: 'slow burn',
        createdAt: base,
        updatedAt: t1,
        version: 9,
      );
      final local = RankingParent(
        id: 'p1',
        categoryId: 'cat',
        title: 'Severance',
        notes: 'slow burn',
        createdAt: base,
        updatedAt: t1,
        version: 9,
        fieldUpdatedAt: stampsFor(rankingParentStampValues(localRow), {
          'notes': t1,
        }),
      );
      // The other device scored a field at t2, in one write.
      const scored = {'plot': RankingFieldValue(score: 4)};
      final remoteRow = RankingParent(
        id: 'p1',
        categoryId: 'cat',
        title: 'Severance',
        fieldValues: scored,
        createdAt: base,
        updatedAt: t2,
        version: 4,
      );
      final remote = rankingParentToFirestore(
        RankingParent(
          id: 'p1',
          categoryId: 'cat',
          title: 'Severance',
          fieldValues: scored,
          createdAt: base,
          updatedAt: t2,
          version: 4,
          fieldUpdatedAt: stampsFor(rankingParentStampValues(remoteRow), {
            'fv:plot:score': t2,
          }),
        ),
      );

      final result = resolveRankingParentFromRemote(remote, 'p1', local: local);

      expect(result.merged.notes, 'slow burn');
      expect(result.merged.fieldValues['plot']!.score, 4);
      // The note is only here, so this device has to upload the merge.
      expect(result.localWon, isTrue);
      expect(result.merged.version, greaterThan(9));
    });

    test('nothing newer here means nothing to upload', () {
      final local = start();
      final remote = rankingParentToFirestore(
        start().copyWith(title: 'Severance S2'),
      );
      final result = resolveRankingParentFromRemote(remote, 'p1', local: local);
      expect(result.merged.title, 'Severance S2');
      expect(result.localWon, isFalse);
    });

    test('a score cleared on another device clears here', () {
      final scored = start().copyWith(
        fieldValues: const {'plot': RankingFieldValue(score: 4, notes: 'ok')},
      );
      final cleared = scored.copyWith(
        fieldValues: const {'plot': RankingFieldValue(notes: 'ok')},
      );
      final payload = rankingParentToFirestore(cleared);
      // Written as an explicit null: uploads merge into the stored document,
      // and a key left out would keep the old score there.
      expect(
        (payload['fieldValues'] as Map)['plot'],
        {'score': null, 'notes': 'ok'},
      );

      final merged = mergeRankingParentFromRemote(payload, 'p1', local: scored);
      expect(merged.fieldValues['plot']!.score, isNull);
      expect(merged.fieldValues['plot']!.notes, 'ok');
    });

    test('a field value emptied entirely is still written, as nulls', () {
      final scored = start().copyWith(
        fieldValues: const {'plot': RankingFieldValue(score: 4)},
      );
      final emptied = scored.copyWith(fieldValues: const {});
      final payload = rankingParentToFirestore(emptied);
      expect(
        (payload['fieldValues'] as Map)['plot'],
        {'score': null, 'notes': ''},
      );
      final merged = mergeRankingParentFromRemote(payload, 'p1', local: scored);
      expect(merged.fieldValues, isEmpty);
    });

    test('stamps an older build wrote over fall back to the version', () {
      final local = start().copyWith(notes: 'local', version: 10);
      // A newer build stamped version 4; an older one then wrote version 5
      // over it, and the merge kept the stale stamps on the document.
      final payload = {
        ...rankingParentToFirestore(
          start().copyWith(notes: 'remote', version: 4),
        ),
        'version': 5,
      };
      final merged = mergeRankingParentFromRemote(payload, 'p1', local: local);
      // Whole-document version-wins, as before stamps: the local 10 wins.
      expect(merged.notes, 'local');
    });

    test('editing one field of an unstamped row does not freshen the rest', () {
      final unstamped = start();
      final edited = unstamped.copyWith(title: 'Severance S2');
      expect(edited.fieldUpdatedAt['notes'], base);
      expect(edited.fieldUpdatedAt['title']!.isAfter(base), isTrue);
    });

    test('a unit merges field by field too', () {
      RankingChild unit({
        String notes = '',
        double? score,
        required DateTime updated,
        Map<String, DateTime> changed = const {},
      }) {
        RankingChild build(RankingFieldStamps stamps) => RankingChild(
          id: 'c1',
          parentId: 'p1',
          name: 'Pilot',
          notes: notes,
          overallScore: score,
          createdAt: base,
          updatedAt: updated,
          version: 2,
          fieldUpdatedAt: stamps,
        );
        return build(
          stampsFor(rankingChildStampValues(build(const {})), changed),
        );
      }

      final local = unit(
        notes: 'cold open',
        updated: t1,
        changed: {'notes': t1},
      );
      final remote = rankingChildToFirestore(
        unit(score: 4.5, updated: t2, changed: {'overallScore': t2}),
      );
      final result = resolveRankingChildFromRemote(remote, 'c1', local: local);
      expect(result.merged.notes, 'cold open');
      expect(result.merged.overallScore, 4.5);
      expect(result.localWon, isTrue);
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
