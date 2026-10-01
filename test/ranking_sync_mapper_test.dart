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

/// What Firestore holds after [update] is uploaded over [stored] with merge:
/// maps are merged key by key, everything else is replaced.
Map<String, dynamic> firestoreMerge(
  Map<String, dynamic> stored,
  Map<String, dynamic> update,
) => {
  ...stored,
  for (final entry in update.entries)
    entry.key: entry.value is Map && stored[entry.key] is Map
        ? firestoreMerge(
            Map<String, dynamic>.from(stored[entry.key] as Map),
            Map<String, dynamic>.from(entry.value as Map),
          )
        : entry.value,
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

    test(
      'a remote tag written by an older build is normalized on the way in',
      () {
        final merged = mergeRankingParentFromRemote(
          remote({
            'tags': ['#Thai', 'rom com', 'THAI'],
          }),
          'p1',
        );
        expect(merged.tags, ['thai']);
      },
    );
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
      expect((payload['fieldValues'] as Map)['plot'], {
        'score': null,
        'notes': 'ok',
      });

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
      expect((payload['fieldValues'] as Map)['plot'], {
        'score': null,
        'notes': '',
      });
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

  group('Location merge', () {
    final base = DateTime.utc(2026, 3, 1);
    final t1 = DateTime.utc(2026, 3, 2);
    final t2 = DateTime.utc(2026, 3, 3);

    RankingLocation branch(String id, {String label = ''}) => RankingLocation(
      id: id,
      latitude: 43.4834,
      longitude: -80.526,
      address: '384 King Street North',
      label: label,
    );

    /// One device's copy of the entry: [locations] as it holds them, every
    /// field it has stamped at [base], and [changed] moved on. A removal is a
    /// key in [changed] with no location behind it.
    RankingParent device({
      required List<RankingLocation> locations,
      required DateTime updatedAt,
      required int version,
      Map<String, DateTime> changed = const {},
    }) {
      RankingParent build(RankingFieldStamps stamps) => RankingParent(
        id: 'p1',
        categoryId: 'cat',
        title: 'Lazeez',
        locations: locations,
        createdAt: base,
        updatedAt: updatedAt,
        version: version,
        fieldUpdatedAt: stamps,
      );
      return build({
        for (final key in rankingParentStampValues(build(const {})).keys)
          key: base,
        ...changed,
      });
    }

    List<String> idsOf(RankingParent parent) => [
      for (final location in parent.locations) location.id,
    ];

    test('locations round trip', () {
      final parent = device(
        locations: [branch('x', label: 'Queen St')],
        updatedAt: base,
        version: 1,
      );
      final merged = mergeRankingParentFromRemote(
        rankingParentToFirestore(parent),
        parent.id,
      );
      final location = merged.locations.single;
      expect(location.id, 'x');
      expect(location.latitude, 43.4834);
      expect(location.longitude, -80.526);
      expect(location.address, '384 King Street North');
      expect(location.label, 'Queen St');
    });

    test('a payload written before locations keeps the local ones', () {
      final local = RankingParent(
        id: 'p1',
        categoryId: 'cat',
        title: 'Severance',
        locations: [branch('x')],
        createdAt: _older,
        updatedAt: _older,
        version: 1,
      );
      final merged = mergeRankingParentFromRemote(
        remote({}),
        'p1',
        local: local,
      );
      expect(idsOf(merged), ['x']);
      expect(mergeRankingParentFromRemote(remote({}), 'p1').locations, isEmpty);
    });

    // HLD §10: device A adds branch X, device B removes branch Y, both
    // offline. B's removal makes its row newer than A's add, and B has no
    // stamp for X at all — which must read as "never heard of it", not as
    // "last touched when the row was".
    test('an add on one device and a removal on another both survive', () {
      final a = device(
        locations: [branch('y'), branch('x')],
        updatedAt: t1,
        version: 4,
        changed: {'loc:x': t1},
      );
      final b = device(
        locations: const [],
        updatedAt: t2,
        version: 4,
        changed: {'loc:y': t2},
      );

      final onB = resolveRankingParentFromRemote(
        rankingParentToFirestore(a),
        'p1',
        local: b,
      );
      expect(idsOf(onB.merged), ['x']);
      // Y's removal is only on B, so B uploads the merge.
      expect(onB.localWon, isTrue);

      final onA = resolveRankingParentFromRemote(
        rankingParentToFirestore(b),
        'p1',
        local: a,
      );
      expect(idsOf(onA.merged), ['x']);
      expect(onA.localWon, isTrue);
    });

    test('two devices adding different branches both keep theirs', () {
      final a = device(
        locations: [branch('x')],
        updatedAt: t1,
        version: 4,
        changed: {'loc:x': t1},
      );
      final b = device(
        locations: [branch('y')],
        updatedAt: t2,
        version: 4,
        changed: {'loc:y': t2},
      );
      for (final (local, other) in [(a, b), (b, a)]) {
        final result = resolveRankingParentFromRemote(
          rankingParentToFirestore(other),
          'p1',
          local: local,
        );
        expect(idsOf(result.merged).toSet(), {'x', 'y'});
      }
    });

    test('a removal later than a label edit removes the branch', () {
      final a = device(
        locations: [branch('x', label: 'Airport')],
        updatedAt: t1,
        version: 4,
        changed: {'loc:x': t1},
      );
      final b = device(
        locations: const [],
        updatedAt: t2,
        version: 4,
        changed: {'loc:x': t2},
      );
      for (final (local, other) in [(a, b), (b, a)]) {
        final result = resolveRankingParentFromRemote(
          rankingParentToFirestore(other),
          'p1',
          local: local,
        );
        expect(result.merged.locations, isEmpty);
        // The removal keeps its stamp, so a third device loses to it too.
        expect(result.merged.fieldUpdatedAt['loc:x'], t2);
      }
    });

    test('a label edit later than a removal keeps the branch', () {
      final a = device(
        locations: [branch('x', label: 'Airport')],
        updatedAt: t2,
        version: 4,
        changed: {'loc:x': t2},
      );
      final b = device(
        locations: const [],
        updatedAt: t1,
        version: 4,
        changed: {'loc:x': t1},
      );
      for (final (local, other) in [(a, b), (b, a)]) {
        final result = resolveRankingParentFromRemote(
          rankingParentToFirestore(other),
          'p1',
          local: local,
        );
        expect(result.merged.locations.single.label, 'Airport');
      }
    });

    // Uploads merge into the stored document key by key. A device that has
    // not pulled another's new branch uploads without it — and must not take
    // it out of the document, or the device that added it reads its own
    // surviving stamp with no branch behind it as a removal.
    test('a device that never saw a branch cannot upload it away', () {
      final a = device(
        locations: [branch('x')],
        updatedAt: t1,
        version: 4,
        changed: {'loc:x': t1},
      );
      // B edited a note at t2 and has never heard of X.
      final b = RankingParent(
        id: 'p1',
        categoryId: 'cat',
        title: 'Lazeez',
        notes: 'went again',
        createdAt: base,
        updatedAt: t2,
        version: 5,
        fieldUpdatedAt: {
          for (final key in rankingParentStampValues(
            device(locations: const [], updatedAt: base, version: 3),
          ).keys)
            key: base,
          'notes': t2,
        },
      );
      final stored = firestoreMerge(
        rankingParentToFirestore(a),
        rankingParentToFirestore(b),
      );

      final onA = resolveRankingParentFromRemote(stored, 'p1', local: a);
      expect(idsOf(onA.merged), ['x']);
      expect(onA.merged.notes, 'went again');
      final onB = resolveRankingParentFromRemote(stored, 'p1', local: b);
      expect(idsOf(onB.merged), ['x']);
    });

    test('a removal reaches the stored document as an explicit null', () {
      final added = device(
        locations: [branch('x'), branch('y')],
        updatedAt: t1,
        version: 4,
        changed: {'loc:x': t1, 'loc:y': t1},
      );
      final removed = device(
        locations: [branch('y')],
        updatedAt: t2,
        version: 5,
        changed: {'loc:x': t2, 'loc:y': t1},
      );
      final stored = firestoreMerge(
        rankingParentToFirestore(added),
        rankingParentToFirestore(removed),
      );
      expect((stored['locations'] as Map)['x'], isNull);
      expect(
        idsOf(
          resolveRankingParentFromRemote(stored, 'p1', local: added).merged,
        ),
        ['y'],
      );
    });

    test('locations written as a list still read', () {
      final merged = mergeRankingParentFromRemote(
        remote({
          'locations': [branch('x').toJson()],
        }),
        'p1',
      );
      expect(idsOf(merged), ['x']);
    });

    test('a category carries its location toggle, and a legacy one is off', () {
      final category = RankingCategory(
        id: 'cat',
        name: 'Restaurants',
        colorValue: 0xFF7C9EFF,
        locationEnabled: true,
        createdAt: _older,
        updatedAt: _older,
      );
      final merged = mergeRankingCategoryFromRemote(
        rankingCategoryToFirestore(category),
        'cat',
      );
      expect(merged.locationEnabled, isTrue);
      expect(
        mergeRankingCategoryFromRemote(
          remote({'name': 'Shows'}),
          'cat',
        ).locationEnabled,
        isFalse,
      );
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
