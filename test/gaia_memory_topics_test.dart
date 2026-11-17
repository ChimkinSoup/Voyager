import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/sync/firestore_document_mapper.dart';
import 'package:voyager/core/sync/synced_write_notifier.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/host/gaia_chat_store.dart';
import 'package:voyager/features/gaia/host/gaia_memories.dart';
import 'package:voyager/features/gaia/host/gaia_voyager_reads.dart';

/// Memory topics, Phase 1 (GAIA_MEMORY_TOPICS_HLD.md §10, §13): the tree,
/// its sync, project topics and the migration, and `memory_search` by
/// topic.

final _at = DateTime.utc(2026, 11, 10, 12);

GaiaMemoryTopic _topic(
  String id,
  String name, {
  String? parentId,
  int minutes = 0,
}) => GaiaMemoryTopic(
  id: id,
  name: name,
  parentId: parentId,
  createdAt: _at,
  updatedAt: _at.add(Duration(minutes: minutes)),
  version: 1,
);

GaiaMemory _memory(
  String id,
  String text, {
  List<String> topicIds = const [],
  String? projectId,
  int minutes = 0,
}) => GaiaMemory(
  id: id,
  text: text,
  status: GaiaMemoryStatus.active,
  topicIds: topicIds,
  projectId: projectId,
  createdAt: _at.add(Duration(minutes: minutes)),
  updatedAt: _at,
  version: 1,
);

GaiaProject _project(String id, String name) =>
    GaiaProject(id: id, name: name, createdAt: _at, updatedAt: _at, version: 1);

void main() {
  group('the tree (§3.1)', () {
    final tree = GaiaTopicTree([
      _topic('uni', 'University'),
      _topic('cs246', 'CS246', parentId: 'uni'),
      _topic('a1', 'Assignments', parentId: 'cs246'),
      _topic('cs245', 'CS245', parentId: 'uni'),
      _topic('a2', 'Assignments', parentId: 'cs245'),
      _topic('lost', 'Lost', parentId: 'nowhere'),
      _topic('gone', 'Gone').copyWith(deletedAt: _at),
      _topic('under-gone', 'Orphan', parentId: 'gone'),
    ]);

    test('paths run from the root; a parent that points nowhere, or is '
        'deleted, makes a root', () {
      expect(tree.path('a1'), ['University', 'CS246', 'Assignments']);
      expect(tree.path('lost'), ['Lost']);
      expect(tree.parentOf('lost'), isNull);
      expect(tree.path('under-gone'), ['Orphan']);
      expect(tree.path('gone'), isEmpty);
      expect(tree.path('nowhere'), isEmpty);
    });

    test('a subtree holds the topic and everything under it', () {
      expect(tree.subtree('uni'), {'uni', 'cs246', 'a1', 'cs245', 'a2'});
      expect(tree.subtree('cs246'), {'cs246', 'a1'});
      expect(tree.subtree('gone'), isEmpty);
    });

    test('find takes a name or the end of a path, case aside', () {
      expect(tree.find('assignments'), {'a1', 'a2'});
      expect(tree.find('CS246 › Assignments'), {'a1'});
      expect(tree.find('university > cs245 > assignments'), {'a2'});
      expect(tree.find('CS246/Assignments'), {'a1'});
      expect(tree.find('Nope'), isEmpty);
      expect(tree.find(' › '), isEmpty);
    });

    test('find takes a name holding a separator, alone or in a path', () {
      final tree = GaiaTopicTree([
        _topic('cs', 'CS 246/247'),
        _topic('ab', 'A/B tests', parentId: 'cs'),
      ]);
      expect(tree.find('CS 246/247'), {'cs'});
      expect(tree.find('cs 246/247 › a/b tests'), {'ab'});
      expect(tree.find('A/B tests'), {'ab'});
      // Only from where a name starts, not partway through one.
      expect(tree.find('247'), isEmpty);
      expect(tree.find('B tests'), isEmpty);
    });

    test('a cycle from sync is broken at the topic changed longest ago', () {
      // a → b → c → a; b was changed first, so it becomes the root.
      final cyclic = GaiaTopicTree([
        _topic('a', 'A', parentId: 'c', minutes: 5),
        _topic('b', 'B', parentId: 'a', minutes: 1),
        _topic('c', 'C', parentId: 'b', minutes: 9),
        _topic('d', 'D', parentId: 'c'),
      ]);
      expect(cyclic.parentOf('b'), isNull);
      expect(cyclic.path('a'), ['B', 'C', 'A']);
      expect(cyclic.path('d'), ['B', 'C', 'D']);
      expect(cyclic.subtree('b'), {'a', 'b', 'c', 'd'});
      // A topic that is its own parent is a root.
      expect(GaiaTopicTree([_topic('x', 'X', parentId: 'x')]).path('x'), ['X']);
    });
  });

  group('sync (§3.1)', () {
    test('a topic survives the trip to Firestore and back', () {
      final topic = GaiaMemoryTopic(
        id: 'project-p1',
        name: 'Trip',
        parentId: 'travel',
        projectId: 'p1',
        createdAt: _at,
        updatedAt: _at,
        version: 3,
      );
      final back = mergeGaiaMemoryTopicFromRemote(
        gaiaMemoryTopicToFirestore(topic),
        topic.id,
      );
      expect(back.name, 'Trip');
      expect(back.parentId, 'travel');
      expect(back.projectId, 'p1');
      expect(back.version, 3);
      expect(back.isDeleted, isFalse);
    });

    test("a memory's topics, pin and suggested topic make the trip; an "
        "older build's write, without them, leaves them as they are", () {
      final memory = GaiaMemory(
        id: 'm',
        text: 'Assignments use C++',
        status: GaiaMemoryStatus.active,
        topicIds: const ['cs246', 'cpp'],
        pinned: true,
        suggestedTopic: (name: 'Assignments', parentId: 'cs246'),
        createdAt: _at,
        updatedAt: _at,
        version: 2,
      );
      final back = mergeGaiaMemoryFromRemote(
        gaiaMemoryToFirestore(memory),
        'm',
      );
      expect(back.topicIds, ['cs246', 'cpp']);
      expect(back.pinned, isTrue);
      expect(back.suggestedTopic, (name: 'Assignments', parentId: 'cs246'));

      final older = gaiaMemoryToFirestore(memory.copyWith(text: 'Edited'))
        ..remove('topicIds')
        ..remove('pinned')
        ..remove('suggestedTopic');
      final merged = mergeGaiaMemoryFromRemote(older, 'm', local: memory);
      expect(merged.text, 'Edited');
      expect(merged.topicIds, ['cs246', 'cpp']);
      expect(merged.pinned, isTrue);
      expect(merged.suggestedTopic?.name, 'Assignments');
    });

    test('topics and memories are written in one batch and reach sync once '
        'per collection', () async {
      final db = AppDatabase.inMemory();
      addTearDown(db.close);
      final writes = <String>[];
      final repository = DriftGaiaRepository(
        db,
        syncedWrites: SyncedWriteNotifier()
          ..onWrite = (collection, records) => writes.add(
            '$collection: ${records.map((r) => (r as dynamic).id).join(' ')}',
          ),
      );
      await repository.upsertMemoryTopics(
        [_topic('t1', 'One'), _topic('t2', 'Two', parentId: 't1')],
        [
          _memory('m1', 'Fact', topicIds: ['t2']),
        ],
      );
      expect(writes, [
        '${FirestoreCollections.gaiaMemoryTopics}: t1 t2',
        '${FirestoreCollections.gaiaMemories}: m1',
      ]);
      expect((await repository.getMemoryTopic('t2'))!.parentId, 't1');
      expect((await repository.getMemory('m1'))!.topicIds, ['t2']);
      expect(
        (await repository.listMemoryTopics()).map((t) => t.id),
        unorderedEquals(['t1', 't2']),
      );
    });
  });

  group('project topics and the migration (§7, §8)', () {
    late AppDatabase db;
    late DriftGaiaRepository repository;
    late GaiaMemories memories;

    setUp(() async {
      db = AppDatabase.inMemory();
      repository = DriftGaiaRepository(db);
      memories = GaiaMemories(repository);
      await repository.upsertProject(_project('p1', 'Trip'));
      await repository.upsertProject(_project('p2', 'Thesis'));
      await repository.upsertMemory(
        _memory('m1', 'Flights booked', projectId: 'p1'),
      );
      await repository.upsertMemory(
        _memory('m2', 'Uses LaTeX', projectId: 'p2'),
      );
      await repository.upsertMemory(_memory('g', 'Likes tea'));
      await repository.upsertMemory(
        _memory('orphan', 'Old fact', projectId: 'gone'),
      );
    });

    tearDown(() => db.close());

    Future<Map<String, List<String>>> filed() async => {
      for (final memory in await repository.listMemories())
        memory.id: memory.topicIds,
    };

    test('each live project gets its topic, at the root under its fixed id, '
        'and its memories go in it; the rest are Unsorted', () async {
      await memories.syncProjectTopics();
      final topics = {
        for (final topic in await repository.listMemoryTopics())
          topic.id: topic,
      };
      expect(topics.keys, unorderedEquals(['project-p1', 'project-p2']));
      expect(topics['project-p1']!.name, 'Trip');
      expect(topics['project-p1']!.projectId, 'p1');
      expect(topics['project-p1']!.parentId, isNull);
      expect(await filed(), {
        'm1': ['project-p1'],
        'm2': ['project-p2'],
        'g': <String>[],
        'orphan': <String>[],
      });
      // Nothing is pinned (§8).
      expect((await repository.listMemories()).where((m) => m.pinned), isEmpty);
    });

    test('run twice, it writes nothing more', () async {
      await memories.syncProjectTopics();
      final before = {
        for (final memory in await repository.listMemories())
          memory.id: memory.version,
        for (final topic in await repository.listMemoryTopics())
          topic.id: topic.version,
      };
      await memories.syncProjectTopics();
      final after = {
        for (final memory in await repository.listMemories())
          memory.id: memory.version,
        for (final topic in await repository.listMemoryTopics())
          topic.id: topic.version,
      };
      expect(after, before);
    });

    test('two devices make the same topic for one project', () async {
      final other = AppDatabase.inMemory();
      addTearDown(other.close);
      final otherRepository = DriftGaiaRepository(other);
      await otherRepository.upsertProject(_project('p1', 'Trip'));
      await otherRepository.upsertMemory(
        _memory('m1', 'Flights booked', projectId: 'p1'),
      );
      await GaiaMemories(otherRepository).syncProjectTopics();
      await memories.syncProjectTopics();

      final mine = (await repository.getMemoryTopic('project-p1'))!;
      final theirs = (await otherRepository.getMemoryTopic('project-p1'))!;
      expect(
        gaiaMemoryTopicToFirestore(theirs)
          ..remove('createdAt')
          ..remove('updatedAt'),
        gaiaMemoryTopicToFirestore(mine)
          ..remove('createdAt')
          ..remove('updatedAt'),
      );
      // Pulling theirs over mine leaves one topic, and m1 filed once.
      final merged = mergeGaiaMemoryTopicFromRemote(
        gaiaMemoryTopicToFirestore(theirs),
        theirs.id,
        local: mine,
      );
      await repository.upsertMemoryTopic(merged);
      expect(
        (await repository.listMemoryTopics())
            .where((t) => t.projectId == 'p1')
            .map((t) => t.id),
        ['project-p1'],
      );
      expect((await otherRepository.getMemory('m1'))!.topicIds, ['project-p1']);
    });

    test('a memory taken out of its project topic after the migration '
        'stays out', () async {
      await memories.syncProjectTopics();
      final m1 = (await repository.getMemory('m1'))!;
      // Taken out by this build, which clears `projectId` as it does
      // (§16.2).
      await repository.upsertMemory(
        m1.copyWith(topicIds: const [], clearProjectId: true),
      );
      await memories.syncProjectTopics();
      expect((await repository.getMemory('m1'))!.topicIds, isEmpty);
    });

    test('a memory an older build saves in a project after its topic was '
        'made is filed in it (GAIA_MEMORY_TOPICS_HLD.md §16.2)', () async {
      await memories.syncProjectTopics();
      // An older build writes `projectId` and no topics.
      await repository.upsertMemory(
        _memory('old', 'Booked the ryokan', projectId: 'p1'),
      );
      // One in a deleted project, or with topics already, is left alone.
      await repository.upsertMemory(
        _memory('gone', 'Gone project fact', projectId: 'p-gone'),
      );
      await repository.upsertMemory(
        _memory('own', 'Has its own topic', projectId: 'p1', topicIds: ['x']),
      );
      await memories.syncProjectTopics();
      expect((await repository.getMemory('old'))!.topicIds, ['project-p1']);
      expect((await repository.getMemory('gone'))!.topicIds, isEmpty);
      expect((await repository.getMemory('own'))!.topicIds, ['x']);
    });

    test(
      'keepProjectTopics files an older build\'s memory as it arrives',
      () async {
        await memories.syncProjectTopics();
        memories.keepProjectTopics();
        addTearDown(memories.stopProjectTopics);
        await repository.upsertMemory(
          _memory('old', 'Booked the ryokan', projectId: 'p1'),
        );
        for (var i = 0; i < 20; i++) {
          if ((await repository.getMemory('old'))!.topicIds.isNotEmpty) break;
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect((await repository.getMemory('old'))!.topicIds, ['project-p1']);
      },
    );

    test(
      'a renamed project renames its topic, wherever it was moved',
      () async {
        await memories.syncProjectTopics();
        final topic = (await repository.getMemoryTopic('project-p1'))!;
        await repository.upsertMemoryTopic(
          GaiaMemoryTopic(
            id: topic.id,
            name: topic.name,
            parentId: 'travel',
            projectId: topic.projectId,
            createdAt: topic.createdAt,
            updatedAt: topic.updatedAt,
            version: topic.version + 1,
          ),
        );
        final project = (await repository.getProject('p1'))!;
        await repository.upsertProject(project.copyWith(name: 'Japan trip'));
        await memories.syncProjectTopics();
        final renamed = (await repository.getMemoryTopic('project-p1'))!;
        expect(renamed.name, 'Japan trip');
        expect(renamed.parentId, 'travel');
      },
    );

    test('a deleted project keeps its topic and memories, now ordinary; a '
        'restore links it again', () async {
      await memories.syncProjectTopics();
      await gaiaDeleteProject(repository, 'p1', withChats: true);
      final topic = (await repository.getMemoryTopic('project-p1'))!;
      expect(topic.isDeleted, isFalse);
      expect(topic.projectId, isNull);
      expect((await repository.getMemory('m1'))!.isDeleted, isFalse);
      expect((await filed())['m1'], ['project-p1']);

      await repository.upsertProject(
        (await repository.getProject('p1'))!.copyWith(clearDeletedAt: true),
      );
      await memories.syncProjectTopics();
      expect((await repository.getMemoryTopic('project-p1'))!.projectId, 'p1');
    });

    test("a project deleted elsewhere has its topic let go here", () async {
      await memories.syncProjectTopics();
      await repository.upsertProject(
        (await repository.getProject('p2'))!.copyWith(deletedAt: _at),
      );
      await memories.syncProjectTopics();
      expect(
        (await repository.getMemoryTopic('project-p2'))!.projectId,
        isNull,
      );
    });

    test("a project whose topic is gone gets a new one, at the root and "
        'empty, under the same id', () async {
      await memories.syncProjectTopics();
      final topic = (await repository.getMemoryTopic('project-p1'))!;
      await repository.upsertMemoryTopic(topic.copyWith(deletedAt: _at));
      // Deleting a topic takes it off its memories (§3.2), and clears
      // `projectId` as any removal by this build does (§16.2).
      await repository.upsertMemory(
        (await repository.getMemory(
          'm1',
        ))!.copyWith(topicIds: const [], clearProjectId: true),
      );
      await memories.syncProjectTopics();
      final back = (await repository.getMemoryTopic('project-p1'))!;
      expect(back.isDeleted, isFalse);
      expect(back.projectId, 'p1');
      expect(back.parentId, isNull);
      expect(back.version, greaterThan(topic.version + 1));
      expect((await filed())['m1'], isEmpty);
    });

    test(
      'keepProjectTopics makes a new project its topic as it appears',
      () async {
        memories.keepProjectTopics();
        await repository.upsertProject(_project('p3', 'Garden'));
        for (var i = 0; i < 20; i++) {
          if (await repository.getMemoryTopic('project-p3') != null) break;
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect((await repository.getMemoryTopic('project-p3'))!.name, 'Garden');
        expect((await filed())['m1'], ['project-p1']);
      },
    );

    test('stopProjectTopics, at sign-out, leaves new projects alone until '
        'it is kept again', () async {
      memories.keepProjectTopics();
      memories.stopProjectTopics();
      await repository.upsertProject(_project('p3', 'Garden'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(await repository.getMemoryTopic('project-p3'), isNull);
      memories.keepProjectTopics();
      for (var i = 0; i < 20; i++) {
        if (await repository.getMemoryTopic('project-p3') != null) break;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(await repository.getMemoryTopic('project-p3'), isNotNull);
    });

    test('a memory saved for a project is filed in its topic too', () async {
      final saved = await memories.save(
        'Hotel near the station',
        status: GaiaMemoryStatus.active,
        projectId: 'p1',
      );
      // No `projectId` from Phase 2 on (§10).
      expect(saved!.projectId, isNull);
      expect(saved.topicIds, ['project-p1']);
      final global = await memories.save(
        'Drinks oolong',
        status: GaiaMemoryStatus.active,
      );
      expect(global!.topicIds, isEmpty);
    });
  });

  group('memory_search by topic (§4.6)', () {
    late AppDatabase db;
    late DriftGaiaRepository repository;
    late GaiaMemories memories;

    setUp(() async {
      db = AppDatabase.inMemory();
      repository = DriftGaiaRepository(db);
      memories = GaiaMemories(repository);
      await repository.upsertMemoryTopics(
        [
          _topic('uni', 'University'),
          _topic('cs246', 'CS246', parentId: 'uni'),
          _topic('a1', 'Assignments', parentId: 'cs246'),
          _topic('cpp', 'C++'),
        ],
        [
          _memory('use-cpp', 'Assignments use C++', topicIds: ['a1', 'cpp']),
          _memory(
            'marmoset',
            'Submit with marmoset_submit',
            topicIds: ['a1'],
            minutes: 5,
          ),
          _memory(
            'prof',
            'The prof is strict on style',
            topicIds: ['cs246'],
            minutes: -5,
          ),
          _memory('tea', 'Likes tea'),
          _memory('ghost', 'Points nowhere', topicIds: ['gone']),
        ],
      );
    });

    tearDown(() => db.close());

    Future<String> search(Map<String, Object?> arguments) =>
        memories.tool('c1', 'memory_search', arguments);

    test(
      "a topic alone lists its memories and its subtopics', newest first",
      () async {
        final found = await search({'topic': 'CS246'});
        final at = [
          found.indexOf('marmoset_submit'),
          found.indexOf('Assignments use C++'),
          found.indexOf('strict on style'),
        ];
        expect(at.every((i) => i >= 0), isTrue);
        expect(at, orderedEquals([...at]..sort()));
        expect(found, isNot(contains('Likes tea')));
      },
    );

    test(
      'a path names one topic; with a query, only its memories match',
      () async {
        final found = await search({
          'topic': 'cs246 › assignments',
          'query': 'use style',
        });
        expect(found, contains('Assignments use C++'));
        expect(found, isNot(contains('strict on style')));
      },
    );

    test("each result shows its topics' paths; one that points nowhere is "
        'left out', () async {
      final found = await search({'topic': 'C++'});
      expect(found, contains('topics: University › CS246 › Assignments; C++'));
      final ghost = await search({'query': 'nowhere'});
      expect(ghost, contains('Points nowhere'));
      expect(ghost, isNot(contains('topics:')));
    });

    test(
      'a topic that matches none is refused, and so is no argument',
      () async {
        await expectLater(
          search({'topic': 'Chemistry'}),
          throwsA(isA<GaiaReadException>()),
        );
        await expectLater(search({}), throwsA(isA<GaiaReadException>()));
      },
    );
  });

  group('editing the tree (§3.2, Phase 4)', () {
    late AppDatabase db;
    late DriftGaiaRepository repository;
    late GaiaMemories memories;

    setUp(() async {
      db = AppDatabase.inMemory();
      repository = DriftGaiaRepository(db);
      memories = GaiaMemories(repository);
      await repository.upsertMemoryTopics(
        [
          _topic('uni', 'University'),
          _topic('cs246', 'CS246', parentId: 'uni'),
          _topic('a1', 'Assignments', parentId: 'cs246'),
          _topic('cpp', 'C++'),
        ],
        [
          _memory('m1', 'Assignments use C++', topicIds: ['a1', 'cpp']),
          _memory('m2', 'Marmoset for hand-in', topicIds: ['cs246']),
          _memory('m3', 'Likes tea'),
        ],
      );
    });

    tearDown(() => db.close());

    Future<List<String>> topicsOf(String id) async =>
        (await repository.getMemory(id))!.topicIds;

    test('a new topic goes at the root or under its parent', () async {
      final root = await memories.newTopic('  Obsidian ');
      final sub = await memories.newTopic('Plugins', parentId: root.id);
      final tree = GaiaTopicTree(await repository.listMemoryTopics());
      expect(tree.path(sub.id), ['Obsidian', 'Plugins']);
    });

    test('re-parenting moves a topic and its subtree; under itself or a '
        'subtopic is refused', () async {
      await memories.moveTopic('cs246', 'cpp');
      var tree = GaiaTopicTree(await repository.listMemoryTopics());
      expect(tree.path('a1'), ['C++', 'CS246', 'Assignments']);
      await memories.moveTopic('cs246', null);
      tree = GaiaTopicTree(await repository.listMemoryTopics());
      expect(tree.path('a1'), ['CS246', 'Assignments']);
      for (final under in ['cs246', 'a1']) {
        await expectLater(
          memories.moveTopic('cs246', under),
          throwsA(isA<GaiaReadException>()),
        );
      }
      expect((await repository.getMemoryTopic('cs246'))!.parentId, isNull);
    });

    test('a topic under a trashed one, shown at the root, moves to the root '
        "for real, so it doesn't follow it back from the trash", () async {
      final uni = (await repository.getMemoryTopic('uni'))!;
      await repository.upsertMemoryTopic(
        uni.copyWith(deletedAt: DateTime.utc(2026, 11, 16)),
      );
      await memories.moveTopic('cs246', null);
      expect((await repository.getMemoryTopic('cs246'))!.parentId, isNull);
    });

    test('deleting a topic takes it off its memories and moves its '
        'subtopics up to its parent, in one write', () async {
      await memories.deleteTopic('cs246');
      expect((await repository.getMemoryTopic('cs246'))!.isDeleted, isTrue);
      expect((await repository.getMemoryTopic('a1'))!.parentId, 'uni');
      expect(await topicsOf('m2'), isEmpty);
      expect(await topicsOf('m1'), ['a1', 'cpp']);
      // At the root, its subtopics become roots.
      await memories.deleteTopic('uni');
      expect((await repository.getMemoryTopic('a1'))!.parentId, isNull);
    });

    test("a live project's topic can't be deleted; once the project is, "
        'it can', () async {
      await repository.upsertProject(_project('p1', 'Trip'));
      await memories.syncProjectTopics();
      await expectLater(
        memories.deleteTopic('project-p1'),
        throwsA(isA<GaiaReadException>()),
      );
      await gaiaDeleteProject(repository, 'p1', withChats: false);
      await memories.deleteTopic('project-p1');
      expect(
        (await repository.getMemoryTopic('project-p1'))!.isDeleted,
        isTrue,
      );
    });

    test("renaming a project's topic renames the project, and the upkeep "
        'keeps the new name', () async {
      await repository.upsertProject(_project('p1', 'Trip'));
      await memories.syncProjectTopics();
      await memories.renameTopic('project-p1', 'Japan trip');
      expect((await repository.getProject('p1'))!.name, 'Japan trip');
      await memories.syncProjectTopics();
      expect(
        (await repository.getMemoryTopic('project-p1'))!.name,
        'Japan trip',
      );
      // An ordinary topic renames alone; a blank name does nothing.
      await memories.renameTopic('cpp', ' ');
      await memories.renameTopic('cpp', 'C plus plus');
      expect((await repository.getMemoryTopic('cpp'))!.name, 'C plus plus');
    });

    test("a move replaces the memory's topics within the selected subtree "
        'only; add keeps them; remove leaves Unsorted', () async {
      final tree = GaiaTopicTree(await repository.listMemoryTopics());
      await memories.moveMemory('m1', 'cs246', within: tree.subtree('uni'));
      expect(await topicsOf('m1'), ['cpp', 'cs246']);
      await memories.moveMemory('m1', 'uni');
      expect(await topicsOf('m1'), ['uni']);
      await memories.addMemoryTopic('m3', 'cpp');
      await memories.addMemoryTopic('m3', 'uni');
      expect(await topicsOf('m3'), ['cpp', 'uni']);
      await memories.removeMemoryTopic('m3', 'cpp');
      await memories.removeMemoryTopic('m3', 'uni');
      expect(await topicsOf('m3'), isEmpty);
    });

    test("a memory taken out of its project's topic each way loses its "
        'projectId, so the upkeep leaves it out (§16.2 item 6)', () async {
      await repository.upsertProject(_project('p1', 'Trip'));
      for (final id in ['removed', 'moved', 'deleted']) {
        await repository.upsertMemory(_memory(id, 'Fact $id', projectId: 'p1'));
      }
      await memories.syncProjectTopics();
      expect(await topicsOf('removed'), ['project-p1']);

      await memories.removeMemoryTopic('removed', 'project-p1');
      await memories.moveMemory('moved', 'cpp');
      for (final id in ['removed', 'moved']) {
        expect((await repository.getMemory(id))!.projectId, isNull);
      }
      // Deleting the topic: possible once the project is gone, and a
      // restored project must not file the memory back.
      await gaiaDeleteProject(repository, 'p1', withChats: false);
      await memories.deleteTopic('project-p1');
      expect((await repository.getMemory('deleted'))!.projectId, isNull);
      await repository.upsertProject(
        (await repository.getProject('p1'))!.copyWith(clearDeletedAt: true),
      );
      await memories.syncProjectTopics();
      expect(await topicsOf('removed'), isEmpty);
      expect(await topicsOf('moved'), ['cpp']);
      expect(await topicsOf('deleted'), isEmpty);
    });
  });
}
