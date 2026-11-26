import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/host/gaia_memories.dart';
import 'package:voyager/features/gaia/host/gaia_voyager_reads.dart';
import 'package:voyager/features/gaia/utility/gaia_utility.dart';

import 'fakes/gaia_fakes.dart';

/// Memory upkeep, part 2 (GAIA_MEMORY_TOPICS_HLD.md §27.4, §27.5): the
/// weekly sweep's groups, its answer, the suggestions it keeps and how
/// each is decided, its placing of Unsorted memories, and Leave unsorted.

final _at = DateTime.utc(2026, 11, 10, 12);

GaiaMemoryTopic _topic(String id, String name, {String? projectId}) =>
    GaiaMemoryTopic(
      id: id,
      name: name,
      projectId: projectId,
      createdAt: _at,
      updatedAt: _at,
      version: 1,
    );

GaiaMemory _memory(
  String id,
  String text, {
  List<String> topicIds = const [],
  List<String> tags = const [],
  bool pinned = false,
  int minutes = 0,
  GaiaMemoryStatus status = GaiaMemoryStatus.active,
}) => GaiaMemory(
  id: id,
  text: text,
  status: status,
  topicIds: topicIds,
  tags: tags,
  pinned: pinned,
  createdAt: _at.add(Duration(minutes: minutes)),
  updatedAt: _at,
  version: 1,
);

GaiaMemorySuggestion _found(
  GaiaSuggestionKind kind, {
  List<String> memoryIds = const [],
  List<String> topicIds = const [],
  String? text,
  GaiaPlacement? placement,
}) => (
  id: '',
  kind: kind,
  memoryIds: memoryIds,
  topicIds: topicIds,
  text: text,
  why: 'Because',
  placement: placement,
  madeAt: _at,
);

void main() {
  group("the sweep's answer (§27.4)", () {
    const ids = ['a', 'b', 'c'];
    const topics = ['t1', 't2'];

    test('each kind read by its numbers; a wrong count or one out of range '
        'is dropped', () {
      final found = parseSweepAnswer(
        'Here:\n[{"kind": "same", "n": [1, 3], "text": " One ", "why": "x"},'
        ' {"kind": "same", "n": [1], "text": "y"},'
        ' {"kind": "same", "n": [1, 2]},'
        ' {"kind": "conflict", "n": [2, 3]},'
        ' {"kind": "conflict", "n": [2, 9]},'
        ' {"kind": "expired", "n": 2, "why": "past"},'
        ' {"kind": "expired", "n": "3"},'
        ' {"kind": "topicMerge", "from": "T2", "into": "T1"},'
        ' {"kind": "topicMerge", "from": "T1", "into": "T1"},'
        ' {"kind": "topicRename", "topic": "T3", "name": "Z"},'
        ' {"kind": "topicRename", "topic": "t1", "name": "Home › School"},'
        ' {"kind": "place", "n": 1}, "junk"]',
        ids,
        topics,
      );
      expect(found.map((f) => f.kind.name), [
        'same',
        'conflict',
        'expired',
        'expired',
        'topicMerge',
        'topicRename',
      ]);
      expect(found[0].memoryIds, ['a', 'c']);
      expect(found[0].text, 'One');
      expect(found[0].why, 'x');
      expect(found[1].memoryIds, ['b', 'c']);
      expect(found[3].memoryIds, ['c']);
      expect(found[4].topicIds, ['t2', 't1']);
      expect(found[5].topicIds, ['t1']);
      expect(found[5].text, 'School');
      expect(parseSweepAnswer('[]', ids, topics), isEmpty);
      expect(
        () => parseSweepAnswer('Nothing', ids, topics),
        throwsFormatException,
      );
      expect(() => parseSweepAnswer('[{', ids, topics), throwsFormatException);
    });

    test('a call sends the memories numbered with topics and saved day, and '
        "today; the topics only when given; it's labelled; a failure is "
        'null', () async {
      final runner = FakeUtilityRunner(
        (_) => '[{"kind": "expired", "n": 1, "why": "past"}]',
      );
      final utility = GaiaUtility(runner);
      final lines = <GaiaSweepLine>[
        (
          id: 'm1',
          text: 'My exam is\n next week',
          topics: ['School'],
          saved: _at,
          pinned: true,
        ),
        (id: 'm2', text: 'Likes tea', topics: [], saved: _at, pinned: false),
      ];
      final found = await utility.sweep(lines, DateTime.utc(2026, 11, 25, 12));
      expect(found!.single.memoryIds, ['m1']);
      expect(runner.jobs.single, contains('Today is 2026-11-25'));
      expect(runner.jobs.single, isNot(contains('topicRename')));
      expect(
        runner.inputs.single,
        contains(
          '1. My exam is next week · topics: School · saved 2026-11-10 · pinned',
        ),
      );
      expect(runner.inputs.single, contains('2. Likes tea · topics: Unsorted'));
      expect(runner.usages.single, 'memory sweep');

      await utility.sweep(
        const [],
        _at,
        topics: [
          (id: 't1', path: 'School', count: 3, project: false),
          (id: 'p', path: 'Trip', count: 1, project: true),
        ],
      );
      expect(runner.jobs.last, contains('topicRename'));
      expect(
        runner.inputs.last,
        'Topics:\nT1. School (3)\nT2. Trip (1) (project)',
      );

      expect(
        await GaiaUtility(FakeUtilityRunner((_) => 'no')).sweep(lines, _at),
        isNull,
      );
    });

    test("the sweep's Sort these is labelled", () async {
      final runner = FakeUtilityRunner((_) => '[]');
      await GaiaUtility(runner).placeMany(
        [(id: 'm1', text: 'x')],
        const [],
        usage: 'memory sweep sort',
      );
      expect(runner.usages.single, 'memory sweep sort');
    });
  });

  group('the groups (§27.4)', () {
    test("a changed memory's group holds its topic's memories and its "
        'nearest elsewhere; unchanged topics are left out', () {
      final plan = gaiaSweepGroups(
        [
          _memory('a', 'I live in Toronto', topicIds: ['places']),
          _memory('b', 'My office is in Toronto downtown', topicIds: ['work']),
          _memory('c', 'I like green tea', topicIds: ['food']),
          _memory('d', 'My flat in Toronto is on Queen Street'),
          _memory('e', 'Biscuit is a beagle', topicIds: ['pets']),
        ].map((m) => m.id == 'a' ? m.copyWith() : m).toList(),
        [
          _topic('places', 'Places'),
          _topic('work', 'Work'),
          _topic('food', 'Food'),
          _topic('pets', 'Pets'),
        ],
        const {},
        _at.add(const Duration(minutes: 1)),
        _at.add(const Duration(days: 8)),
      );
      expect(plan.groups, hasLength(1));
      final ids = plan.groups.single.map((line) => line.id).toSet();
      expect(ids, containsAll(['a', 'b', 'd']));
      expect(ids, isNot(contains('e')));
      expect(plan.topics.map((t) => t.path), [
        'Food',
        'Pets',
        'Places',
        'Work',
      ]);
    });

    test('the first sweep reads everything: one group per topic, Unsorted '
        'as one', () {
      final plan = gaiaSweepGroups(
        [
          _memory('a', 'Alpha', topicIds: ['t1']),
          _memory('b', 'Beta', topicIds: ['t2']),
          _memory('c', 'Gamma'),
          _memory(
            'x',
            'Gone',
            topicIds: ['t1'],
            status: GaiaMemoryStatus.archived,
          ),
        ],
        [_topic('t1', 'One'), _topic('t2', 'Two')],
        const {},
        null,
        _at,
      );
      expect(
        [for (final group in plan.groups) group.map((l) => l.id).toList()],
        unorderedEquals([
          ['a'],
          ['b'],
          ['c'],
        ]),
      );
    });

    test('a group past 80 lines is split, each part at most 80 and holding a '
        'changed memory', () {
      final plan = gaiaSweepGroups(
        [
          for (var i = 0; i < 170; i++)
            _memory('m$i', 'Fact number $i about thing$i', topicIds: ['t1']),
        ],
        [_topic('t1', 'One')],
        const {},
        null,
        _at,
      );
      expect(plan.groups.length, 3);
      expect(plan.groups.every((group) => group.length <= 80), isTrue);
      expect(
        plan.groups.expand((g) => g).map((l) => l.id).toSet(),
        hasLength(170),
      );
    });
  });

  group('suggestions (§27.4)', () {
    late AppDatabase db;
    late DriftGaiaRepository repository;
    late GaiaMemories memories;

    setUp(() async {
      db = AppDatabase.inMemory();
      repository = DriftGaiaRepository(db);
      memories = GaiaMemories(repository);
      await repository.upsertProject(
        GaiaProject(
          id: 'p1',
          name: 'Trip',
          createdAt: _at,
          updatedAt: _at,
          version: 1,
        ),
      );
      await repository.upsertMemoryTopics(
        [
          _topic('places', 'Places'),
          _topic('home', 'Home'),
          _topic('cs', 'cs246'),
          _topic('project-p1', 'Trip', projectId: 'p1'),
        ],
        [
          _memory(
            'old',
            'I live in Toronto',
            topicIds: ['places'],
            tags: ['city'],
          ),
          _memory(
            'new',
            'Toronto is where I live',
            topicIds: ['home'],
            tags: ['home'],
            pinned: true,
            minutes: 5,
          ),
          _memory('v', 'I moved to Vancouver', minutes: 9),
          _memory('exam', 'My exam is next week', minutes: 2),
        ],
      );
    });

    tearDown(() => db.close());

    Future<List<GaiaMemorySuggestion>> standing() async =>
        (await memories.list()).suggestions;

    test('kept only when what it names is there and active, a project topic '
        'merged into rather than away, never renamed, and not twice', () async {
      final kept = await memories.addSuggestions([
        _found(
          GaiaSuggestionKind.same,
          memoryIds: ['old', 'new'],
          text: 'I live in Toronto.',
        ),
        _found(
          GaiaSuggestionKind.same,
          memoryIds: ['new', 'old'],
          text: 'Again',
        ),
        _found(GaiaSuggestionKind.same, memoryIds: ['old', 'gone'], text: 'x'),
        _found(GaiaSuggestionKind.conflict, memoryIds: ['old', 'v']),
        _found(GaiaSuggestionKind.expired, memoryIds: ['exam']),
        _found(GaiaSuggestionKind.topicMerge, topicIds: ['project-p1', 'home']),
        _found(
          GaiaSuggestionKind.topicRename,
          topicIds: ['project-p1'],
          text: 'Japan',
        ),
        _found(GaiaSuggestionKind.topicRename, topicIds: ['cs'], text: 'CS246'),
        _found(GaiaSuggestionKind.topicRename, topicIds: ['cs'], text: 'cs246'),
      ], _at.add(const Duration(days: 1)));
      expect(kept, 5);
      final list = await standing();
      expect(
        list.map((s) => s.kind.name),
        ['same', 'conflict', 'expired', 'topicMerge', 'topicRename']
          ..sort((a, b) => 0),
      );
      expect(
        list
            .firstWhere((s) => s.kind == GaiaSuggestionKind.topicMerge)
            .topicIds,
        ['home', 'project-p1'],
      );
    });

    test('merge keeps the oldest with the new text, every topic and tag, and '
        'the pin; the others go to the trash; undo puts all back', () async {
      await memories.addSuggestions([
        _found(
          GaiaSuggestionKind.same,
          memoryIds: ['new', 'old'],
          text: 'I live in Toronto.',
        ),
      ], utcNow());
      final suggestion = (await standing()).single;
      final decided = await memories.decideSuggestion(
        suggestion.id,
        accept: true,
        text: 'I live in Toronto, Canada.',
      );
      final kept = (await repository.getMemory('old'))!;
      expect(kept.text, 'I live in Toronto, Canada.');
      expect(kept.topicIds, ['places', 'home']);
      expect(kept.tags, ['city', 'home']);
      expect(kept.pinned, isTrue);
      expect((await repository.getMemory('new'))!.isDeleted, isTrue);
      expect(await standing(), isEmpty);

      await memories.revert(memories: decided.memories);
      await memories.restoreSuggestion(decided.suggestion);
      expect((await repository.getMemory('old'))!.text, 'I live in Toronto');
      expect((await repository.getMemory('new'))!.isDeleted, isFalse);
      expect((await standing()).single.id, suggestion.id);
    });

    test('a merge past the pin budget, or saying what another memory says, '
        'changes nothing', () async {
      await memories.addSuggestions([
        _found(GaiaSuggestionKind.same, memoryIds: ['new', 'old'], text: 'x'),
      ], utcNow());
      final id = (await standing()).single.id;
      await expectLater(
        memories.decideSuggestion(id, accept: true, text: 'y' * 2001),
        throwsA(isA<GaiaReadException>()),
      );
      await expectLater(
        memories.decideSuggestion(
          id,
          accept: true,
          text: 'I moved to Vancouver',
        ),
        throwsA(isA<GaiaReadException>()),
      );
      expect((await repository.getMemory('old'))!.text, 'I live in Toronto');
      expect((await standing()).single.id, id);
    });

    test('keeping one of two that disagree trashes the other; out of date '
        'archives', () async {
      await memories.addSuggestions([
        _found(GaiaSuggestionKind.conflict, memoryIds: ['old', 'v']),
        _found(GaiaSuggestionKind.expired, memoryIds: ['exam']),
      ], utcNow());
      final [conflict, expired] = await standing();
      await memories.decideSuggestion(conflict.id, keep: 'v');
      expect((await repository.getMemory('old'))!.isDeleted, isTrue);
      expect((await repository.getMemory('v'))!.isDeleted, isFalse);
      await memories.decideSuggestion(expired.id, accept: true);
      expect(
        (await repository.getMemory('exam'))!.status,
        GaiaMemoryStatus.archived,
      );
    });

    test('kept apart is not suggested again until a text changes; undone, '
        "it's back", () async {
      await memories.addSuggestions([
        _found(GaiaSuggestionKind.conflict, memoryIds: ['old', 'v']),
      ], utcNow());
      final decided = await memories.decideSuggestion(
        (await standing()).single.id,
      );
      expect(await standing(), isEmpty);
      expect(
        await memories.addSuggestions([
          _found(GaiaSuggestionKind.conflict, memoryIds: ['v', 'old']),
        ], utcNow()),
        0,
      );
      await memories.restoreSuggestion(decided.suggestion);
      expect(await standing(), hasLength(1));

      await memories.decideSuggestion((await standing()).single.id);
      await memories.edit('v', text: 'I moved to Vancouver in 2025');
      expect(
        await memories.addSuggestions([
          _found(GaiaSuggestionKind.conflict, memoryIds: ['old', 'v']),
        ], utcNow()),
        1,
      );
    });

    test('a topic merge or rename kept apart is not suggested again', () async {
      await memories.addSuggestions([
        _found(GaiaSuggestionKind.topicMerge, topicIds: ['home', 'places']),
        _found(GaiaSuggestionKind.topicRename, topicIds: ['cs'], text: 'CS246'),
      ], utcNow());
      for (final suggestion in await standing()) {
        await memories.decideSuggestion(suggestion.id);
      }
      expect(
        await memories.addSuggestions([
          _found(GaiaSuggestionKind.topicMerge, topicIds: ['places', 'home']),
          _found(
            GaiaSuggestionKind.topicRename,
            topicIds: ['cs'],
            text: 'CS 246',
          ),
        ], utcNow()),
        0,
      );
      // The Phase 6 merge suggestion for the pair is kept apart too.
      expect((await memories.list()).merges, isEmpty);
    });

    test('topics merged or renamed from a suggestion', () async {
      await memories.addSuggestions([
        _found(GaiaSuggestionKind.topicMerge, topicIds: ['home', 'places']),
        _found(GaiaSuggestionKind.topicRename, topicIds: ['cs'], text: 'CS246'),
      ], utcNow());
      for (final suggestion in await standing()) {
        await memories.decideSuggestion(suggestion.id, accept: true);
      }
      expect((await repository.getMemory('new'))!.topicIds, ['places']);
      expect((await repository.getMemoryTopic('home'))!.isDeleted, isTrue);
      expect((await repository.getMemoryTopic('cs'))!.name, 'CS246');
    });

    test(
      'a suggestion goes stale once what it names changes or goes',
      () async {
        await memories.addSuggestions([
          _found(GaiaSuggestionKind.expired, memoryIds: ['exam']),
          _found(GaiaSuggestionKind.conflict, memoryIds: ['old', 'v']),
          _found(
            GaiaSuggestionKind.topicRename,
            topicIds: ['cs'],
            text: 'CS246',
          ),
        ], utcNow());
        expect(await standing(), hasLength(3));
        await memories.edit('exam', text: 'My exam is on Dec 3');
        await memories.delete('v');
        await memories.renameTopic('cs', 'CS 246');
        expect(await standing(), isEmpty);
        expect(await repository.listMemorySuggestions(), isEmpty);
      },
    );

    test('a decision on a suggestion gone is refused', () async {
      await expectLater(
        memories.decideSuggestion('nope', accept: true),
        throwsA(isA<GaiaReadException>()),
      );
    });
  });

  group('the plan and placing Unsorted (§27.4)', () {
    late AppDatabase db;
    late DriftGaiaRepository repository;
    late GaiaMemories memories;

    setUp(() async {
      db = AppDatabase.inMemory();
      repository = DriftGaiaRepository(db);
      memories = GaiaMemories(repository);
      await repository.upsertMemoryTopics(
        [_topic('t1', 'Food')],
        [
          _memory('u1', 'Exam on Monday'),
          _memory('u2', 'Buy rice'),
          _memory('u3', 'Call mum'),
          _memory('f', 'Likes tea', topicIds: ['t1']),
        ],
      );
    });

    tearDown(() => db.close());

    test('not due within a week of the last unless forced, and nothing to do '
        'with nothing changed', () async {
      final now = utcNow();
      expect(await memories.sweepPlan(now), isNotNull);
      await memories.swept(now);
      expect(
        await memories.sweepPlan(now.add(const Duration(days: 6))),
        isNull,
      );
      expect(
        await memories.sweepPlan(now.add(const Duration(days: 6)), force: true),
        isNull,
        reason: 'nothing changed since',
      );
      expect(
        await memories.sweepPlan(now.add(const Duration(days: 8))),
        isNull,
      );
      await memories.edit('f', text: 'Likes green tea');
      final plan = await memories.sweepPlan(now.add(const Duration(days: 8)));
      expect(plan!.groups.single.map((l) => l.id), contains('f'));
    });

    test('the first sweep places every Unsorted one; later only those new or '
        'edited, none waiting, left unsorted or in this sweep\'s same or '
        'conflict', () async {
      final at = utcNow();
      expect([
        for (final m in await memories.sweepUnsorted({}, at)) m.id,
      ], unorderedEquals(['u1', 'u2', 'u3']));
      expect([
        for (final m in await memories.sweepUnsorted({'u3'}, at)) m.id,
      ], unorderedEquals(['u1', 'u2']));
      await memories.addSuggestions([
        _found(
          GaiaSuggestionKind.place,
          memoryIds: ['u1'],
          placement: (topicIds: ['t1'], suggested: null, tags: const []),
        ),
      ], utcNow());
      await memories.leaveUnsorted('u2');
      expect(
        [for (final m in await memories.sweepUnsorted({}, at)) m.id],
        ['u3'],
      );

      // u3 was held back above, so the next sweep places it once.
      await memories.swept(at);
      final next = utcNow();
      expect(
        [for (final m in await memories.sweepUnsorted({}, next)) m.id],
        ['u3'],
      );
      await memories.swept(next);
      final last = utcNow();
      expect(await memories.sweepUnsorted({}, last), isEmpty);
      await memories.edit('u3', text: 'Call mum on Sunday');
      expect(
        [for (final m in await memories.sweepUnsorted({}, last)) m.id],
        ['u3'],
      );
    });

    test('one held back for a same or conflict is placed by the next sweep, '
        'though unchanged', () async {
      final first = utcNow();
      expect([
        for (final m in await memories.sweepUnsorted({'u3'}, first)) m.id,
      ], unorderedEquals(['u1', 'u2']));
      await memories.swept(first);

      // Held back again: still waits.
      final second = utcNow();
      expect(await memories.sweepUnsorted({'u3'}, second), isEmpty);
      await memories.swept(second);

      final third = utcNow();
      expect(
        [for (final m in await memories.sweepUnsorted({}, third)) m.id],
        ['u3'],
      );
      await memories.swept(third);
      expect(await memories.sweepUnsorted({}, utcNow()), isEmpty);
    });

    test("a stored placement shows until it's filed some other way", () async {
      await memories.addSuggestions([
        _found(
          GaiaSuggestionKind.place,
          memoryIds: ['u1'],
          placement: (topicIds: ['t1'], suggested: null, tags: const []),
        ),
      ], utcNow());
      expect((await memories.list()).suggestions.single.placement!.topicIds, [
        't1',
      ]);
      await memories.addMemoryTopic('u1', 't1');
      expect((await memories.list()).suggestions, isEmpty);
    });
  });

  group('Leave unsorted (§27.5)', () {
    late AppDatabase db;
    late DriftGaiaRepository repository;
    late GaiaMemories memories;

    setUp(() async {
      db = AppDatabase.inMemory();
      repository = DriftGaiaRepository(db);
      memories = GaiaMemories(repository);
      await repository.upsertMemoryTopics(
        [_topic('t1', 'Food')],
        [_memory('u1', 'Exam on Monday'), _memory('u2', 'Buy rice')],
      );
    });

    tearDown(() => db.close());

    test('remembered, and undone', () async {
      await memories.leaveUnsorted('u1');
      expect((await memories.list()).leftUnsorted, {'u1'});
      await memories.undoLeaveUnsorted('u1');
      expect((await memories.list()).leftUnsorted, isEmpty);
    });

    test('its stored placement comes back on Undo', () async {
      await memories.addSuggestions([
        _found(
          GaiaSuggestionKind.place,
          memoryIds: ['u1'],
          placement: (topicIds: ['t1'], suggested: null, tags: const []),
        ),
      ], utcNow());
      await memories.leaveUnsorted('u1');
      expect((await memories.list()).suggestions, isEmpty);
      await memories.undoLeaveUnsorted('u1');
      expect((await memories.list()).suggestions.single.placement!.topicIds, [
        't1',
      ]);
    });

    test('dropped once its text changes, or it is filed', () async {
      await memories.leaveUnsorted('u1');
      await memories.leaveUnsorted('u2');
      await memories.edit('u1', text: 'Exam on Tuesday');
      await memories.addMemoryTopic('u2', 't1');
      expect((await memories.list()).leftUnsorted, isEmpty);
      // Back in Unsorted, it's asked about again.
      await memories.removeMemoryTopic('u2', 't1');
      expect((await memories.list()).leftUnsorted, isEmpty);
      expect(
        (await repository.listMemoryHints()).where(
          (hint) => hint.kind == GaiaMemoryHintKind.leftUnsorted,
        ),
        isEmpty,
      );
    });
  });

  test("a topic pair the sweep suggests isn't offered twice", () async {
    final db = AppDatabase.inMemory();
    addTearDown(db.close);
    final memories = GaiaMemories(DriftGaiaRepository(db));
    await DriftGaiaRepository(
      db,
    ).upsertMemoryTopics([_topic('t1', 'Books'), _topic('t2', 'book')], []);
    expect((await memories.list()).merges, hasLength(1));
    await memories.addSuggestions([
      _found(GaiaSuggestionKind.topicMerge, topicIds: ['t2', 't1']),
    ], utcNow());
    final list = await memories.list();
    expect(list.merges, isEmpty);
    expect(list.suggestions.single.kind, GaiaSuggestionKind.topicMerge);
  });

  test('a suggestion and the list make the trip through the pipe', () {
    final GaiaMemorySuggestion suggestion = (
      id: 's1',
      kind: GaiaSuggestionKind.place,
      memoryIds: ['m1'],
      topicIds: const [],
      text: null,
      why: null,
      placement: (
        topicIds: ['t1'],
        suggested: (name: 'New', parentId: null),
        tags: ['x'],
      ),
      madeAt: _at,
    );
    final back = gaiaMemorySuggestionFromJson(
      gaiaMemorySuggestionToJson(suggestion),
    )!;
    expect(back.placement!.suggested!.name, 'New');
    expect(back.madeAt, _at);
    final list = gaiaMemoryListFromJson(
      gaiaMemoryListToJson((
        memories: const [],
        topics: const [],
        projects: const {},
        pins: const [],
        merges: const [],
        suggestions: [suggestion],
        leftUnsorted: {'m2'},
      )),
    );
    expect(list.suggestions.single.id, 's1');
    expect(list.leftUnsorted, {'m2'});
    expect(gaiaMemorySuggestionFromJson({'kind': 'unknown'}), isNull);
  });
}
