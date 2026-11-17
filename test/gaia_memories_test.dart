import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/sync/firestore_document_mapper.dart';
import 'package:voyager/core/sync/synced_write_notifier.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/host/gaia_memories.dart';
import 'package:voyager/features/gaia/host/gaia_voyager_reads.dart';

/// Gaia's memories (GAIA_HLD.md §11) as the main instance keeps them: the
/// index a new session carries, `memory_search` and `memory_propose`,
/// `/remember`, the curator's proposals, and what reaches sync.

final _at = DateTime.utc(2026, 10, 30, 12);

GaiaMemory _memory(
  String id,
  String text, {
  List<String> tags = const [],
  GaiaMemoryStatus status = GaiaMemoryStatus.active,
  DateTime? at,
  String? projectId,
}) => GaiaMemory(
  id: id,
  text: text,
  tags: tags,
  status: status,
  projectId: projectId,
  createdAt: at ?? _at,
  updatedAt: at ?? _at,
  version: 1,
);

void main() {
  late AppDatabase db;
  late DriftGaiaRepository repository;
  late GaiaMemories memories;
  late List<String> uploads;

  setUp(() {
    db = AppDatabase.inMemory();
    uploads = [];
    final syncedWrites = SyncedWriteNotifier()
      ..onWrite = (collection, records) {
        for (final record in records) {
          uploads.add('$collection/${(record as dynamic).id}');
        }
      };
    repository = DriftGaiaRepository(db, syncedWrites: syncedWrites);
    memories = GaiaMemories(repository);
  });

  tearDown(() => db.close());

  Future<String> curatorList([
    String transcript = 'metric units waiting old',
  ]) async => (await memories.curatorContext(transcript)).kept;

  test("the curator's list has active memories only, one line each", () async {
    expect(await curatorList(), isEmpty);
    await repository.upsertMemory(
      _memory('a', 'Prefers metric\nunits', tags: ['units']),
    );
    await repository.upsertMemory(
      _memory('b', 'Waiting', status: GaiaMemoryStatus.proposed),
    );
    await repository.upsertMemory(
      _memory('c', 'Old', status: GaiaMemoryStatus.archived),
    );
    final index = await curatorList();
    expect(index, contains('- Prefers metric units [units]'));
    expect(index, isNot(contains('Waiting')));
    expect(index, isNot(contains('Old')));
  });

  test(
    "a long memory is cut in the curator's list and whole in a search",
    () async {
      final long = 'Likes ${'very ' * 60}long walks';
      await repository.upsertMemory(_memory('a', long));
      expect(await curatorList('long walks'), contains('…'));
      final found = await memories.tool('c1', 'memory_search', {
        'query': 'walks',
      });
      expect(found, contains(long));
      expect(found, startsWith('<memories>'));
    },
  );

  test('search ranks by words matched, filters by tags, and skips '
      'memories not active', () {
    final all = [
      _memory('a', 'Has a dog called Biscuit', tags: ['pets']),
      _memory('b', 'Walks the dog at seven', tags: ['pets', 'routine']),
      _memory('c', 'Works at the observatory', tags: ['work']),
    ];
    expect(gaiaSearchMemories(all, 'dog biscuit').map((m) => m.id), ['a', 'b']);
    expect(gaiaSearchMemories(all, '', tags: ['routine']).map((m) => m.id), [
      'b',
    ]);
    expect(gaiaSearchMemories(all, 'cat'), isEmpty);
    // One-letter words alone match nothing, rather than everything.
    expect(gaiaSearchMemories(all, 'a ?'), isEmpty);
    expect(gaiaSearchMemories(all, 'a', tags: ['work']).map((m) => m.id), [
      'c',
    ]);
  });

  test('memory_search needs a query, tags or a topic, and says when nothing '
      'matches', () async {
    await expectLater(
      memories.tool('c1', 'memory_search', {}),
      throwsA(isA<GaiaReadException>()),
    );
    expect(
      await memories.tool('c1', 'memory_search', {'query': 'dog'}),
      'The user has no memories saved.',
    );
  });

  test('memory_propose puts it in the inbox from its chat, once', () async {
    final first = await memories.tool('c1', 'memory_propose', {
      'text': ' Prefers tea ',
      'tags': ['#Drinks'],
    });
    expect(first, contains('inbox'));
    final saved = (await repository.listMemories()).single;
    expect(saved.text, 'Prefers tea');
    expect(saved.tags, ['drinks']);
    expect(saved.status, GaiaMemoryStatus.proposed);
    expect(saved.sourceChatId, 'c1');
    expect(uploads, ['${FirestoreCollections.gaiaMemories}/${saved.id}']);
    // The same again, in other spacing and case, isn't a second.
    final again = await memories.tool('c1', 'memory_propose', {
      'text': 'prefers  TEA',
    });
    expect(again, contains('Already'));
    expect(await repository.listMemories(), hasLength(1));
  });

  test(
    "propose gives the card the memory saved, none when it's not new",
    () async {
      final first = await memories.propose('c1', {'text': 'Prefers tea'});
      expect(first.memory?.text, 'Prefers tea');
      expect(first.text, contains('card'));
      final again = await memories.propose('c1', {'text': 'prefers tea'});
      expect(again.memory, isNull);
    },
  );

  test("a memory card remembers the user's edit, or dismisses as the inbox "
      'does', () async {
    final tea = (await memories.propose('c1', {'text': 'Prefers tea'})).memory!;
    final jazz = (await memories.propose('c1', {'text': 'Likes jazz'})).memory!;
    expect(
      await memories.decide(tea.id, accept: true, text: ' Prefers green tea '),
      (id: tea.id, state: GaiaCardState.accepted, text: 'Prefers green tea'),
    );
    final kept = await repository.getMemory(tea.id);
    expect(kept!.status, GaiaMemoryStatus.active);
    expect(kept.text, 'Prefers green tea');
    expect(await curatorList('green tea'), contains('Prefers green tea'));

    expect(
      (await memories.decide(jazz.id, accept: false, text: 'Likes jazz')).state,
      GaiaCardState.rejected,
    );
    expect((await repository.getMemory(jazz.id))!.isDeleted, isTrue);
    // Dismissed, it isn't offered again.
    expect(
      (await memories.propose('c1', {'text': 'Likes jazz'})).memory,
      isNull,
    );
  });

  test('a memory card edited to say what an active one does keeps that one, '
      'not a second copy', () async {
    await repository.upsertMemory(_memory('m1', 'Prefers green tea'));
    final tea = (await memories.propose('c1', {'text': 'Prefers tea'})).memory!;
    expect(
      await memories.decide(tea.id, accept: true, text: 'prefers  GREEN tea'),
      (id: 'm1', state: GaiaCardState.accepted, text: 'Prefers green tea'),
    );
    expect((await repository.getMemory(tea.id))!.isDeleted, isTrue);
    final active = (await repository.listMemories()).where(
      (memory) => memory.status == GaiaMemoryStatus.active,
    );
    expect(active.map((memory) => memory.id), ['m1']);
  });

  test("a card's dismissal undone puts it back in the inbox, not one decided "
      'since', () async {
    final tea = (await memories.propose('c1', {'text': 'Prefers tea'})).memory!;
    await memories.decide(tea.id, accept: false, text: 'Prefers tea');
    expect(await memories.restore(tea.id), 'Prefers tea');
    final back = (await repository.getMemory(tea.id))!;
    expect((back.isDeleted, back.status), (false, GaiaMemoryStatus.proposed));
    expect(await memories.restore(tea.id), isNull, reason: 'not dismissed');
    await memories.decide(tea.id, accept: true, text: 'Prefers tea');
    expect(await memories.restore(tea.id), isNull);
  });

  test('sameActive sees an active memory from any project, not an archived '
      'one or the one asked about (GAIA_MEMORY_TOPICS_HLD.md §5)', () async {
    for (final id in ['p1', 'p2']) {
      await repository.upsertProject(
        GaiaProject(id: id, name: id, createdAt: _at, updatedAt: _at),
      );
    }
    await repository.upsertMemory(_memory('g', 'Likes jazz'));
    await repository.upsertMemory(_memory('a', 'Uses vim', projectId: 'p1'));
    await repository.upsertMemory(
      _memory('z', 'Runs daily', status: GaiaMemoryStatus.archived),
    );
    expect((await memories.sameActive('likes  JAZZ'))?.id, 'g');
    expect((await memories.sameActive('Uses vim'))?.id, 'a');
    expect(await memories.sameActive('Runs daily'), isNull);
    expect(await memories.sameActive('Likes jazz', except: 'g'), isNull);
  });

  test('a memory card shows what the inbox decided first, and refuses empty '
      'or overlong text', () async {
    final tea = (await memories.propose('c1', {'text': 'Prefers tea'})).memory!;
    await repository.upsertMemory(
      tea.copyWith(text: 'Prefers oolong', status: GaiaMemoryStatus.active),
    );
    expect(await memories.decide(tea.id, accept: false, text: 'Prefers tea'), (
      id: tea.id,
      state: GaiaCardState.accepted,
      text: 'Prefers oolong',
    ));
    expect((await repository.getMemory(tea.id))!.isDeleted, isFalse);

    final jazz = (await memories.propose('c1', {'text': 'Likes jazz'})).memory!;
    await repository.upsertMemory(jazz.copyWith(deletedAt: _at));
    expect(
      (await memories.decide(jazz.id, accept: true, text: 'Likes jazz')).state,
      GaiaCardState.rejected,
    );

    final walks = (await memories.propose('c1', {'text': 'Walks'})).memory!;
    for (final text in ['  ', 'x' * (kGaiaMemoryMaxLength + 1)]) {
      await expectLater(
        memories.decide(walks.id, accept: true, text: text),
        throwsA(isA<GaiaReadException>()),
      );
    }
    expect(
      (await repository.getMemory(walks.id))!.status,
      GaiaMemoryStatus.proposed,
    );
  });

  test('tags are kept lower case, without #, spaces inside as -, once', () {
    expect(
      gaiaMemoryTags(['#Tea Time', ' drinks ', 'DRINKS', '#', '', 'a  b', 3]),
      ['tea-time', 'drinks', 'a-b'],
    );
    // Only a leading # goes.
    expect(gaiaMemoryTags(['c#', '##work', 'f#-minor']), [
      'c#',
      'work',
      'f#-minor',
    ]);
  });

  test('a memory past the limit is refused', () async {
    await expectLater(
      memories.save(
        'x' * (kGaiaMemoryMaxLength + 1),
        status: GaiaMemoryStatus.active,
      ),
      throwsA(isA<GaiaReadException>()),
    );
  });

  test("/remember's memory is active at once", () async {
    final saved = await memories.save(
      'Birthday is 3 May',
      chatId: 'c1',
      status: GaiaMemoryStatus.active,
      byUser: true,
    );
    expect(saved!.status, GaiaMemoryStatus.active);
    expect(await curatorList('birthday'), contains('Birthday is 3 May'));
  });

  test('what the user archived, dismissed or deleted is not proposed again, '
      'but /remember can save it', () async {
    await repository.upsertMemory(
      _memory('a', 'Prefers metric units', status: GaiaMemoryStatus.archived),
    );
    await repository.upsertMemory(
      _memory(
        'd',
        'Likes jazz',
        status: GaiaMemoryStatus.proposed,
      ).copyWith(deletedAt: _at),
    );
    final again = await memories.tool('c1', 'memory_propose', {
      'text': 'prefers metric units',
    });
    expect(again, contains('set aside'));
    await memories.curated('c1', 1, [_found('Likes  JAZZ')]);
    expect(await repository.listMemories(), hasLength(1));

    for (final text in ['Prefers metric units', 'Likes jazz']) {
      expect(
        await memories.save(
          text,
          status: GaiaMemoryStatus.active,
          byUser: true,
        ),
        isNotNull,
      );
    }
  });

  test('the curator proposes into the inbox and marks the chat read up to '
      'its last turn', () async {
    await repository.upsertChat(
      GaiaChat(
        id: 'c1',
        title: 'Chat',
        createdAt: _at,
        updatedAt: _at,
        lastMessageAt: _at,
      ),
    );
    await memories.curated('c1', 5, [
      _found('Runs on Sundays', ['fitness']),
      _found('x' * (kGaiaMemoryMaxLength + 1)),
    ]);
    final saved = (await repository.listMemories()).single;
    expect(saved.status, GaiaMemoryStatus.proposed);
    expect((await repository.getChat('c1'))!.curatedSeq, 5);
    // An older read never moves it back.
    await memories.curated('c1', 3, const []);
    expect((await repository.getChat('c1'))!.curatedSeq, 5);
  });

  test('with auto-accept on, the curator saves memories as active', () async {
    await repository.upsertSettings(
      GaiaSettings.initial().copyWith(autoAcceptCurator: true),
    );
    await memories.curated('gone', 1, [_found('Lives in Lisbon')]);
    expect(
      (await repository.listMemories()).single.status,
      GaiaMemoryStatus.active,
    );
  });

  test('a memory survives the trip to Firestore and back', () {
    final memory = _memory(
      'a',
      'Prefers metric units',
      tags: ['units'],
      status: GaiaMemoryStatus.archived,
    );
    final back = mergeGaiaMemoryFromRemote(gaiaMemoryToFirestore(memory), 'a');
    expect(back.text, memory.text);
    expect(back.tags, memory.tags);
    expect(back.status, GaiaMemoryStatus.archived);
    expect(back.version, memory.version);
    expect(back.projectId, isNull);
    final moved = mergeGaiaMemoryFromRemote(
      gaiaMemoryToFirestore(memory.copyWith(projectId: 'p1')),
      'a',
    );
    expect(moved.projectId, 'p1');
    expect(back.topicIds, isEmpty);
    expect(back.pinned, isFalse);
    expect(back.suggestedTopic, isNull);
  });

  group('project memories (GAIA_PROJECTS_HLD.md §6)', () {
    GaiaChat chat(String id, String? projectId) => GaiaChat(
      id: id,
      title: id,
      createdAt: _at,
      updatedAt: _at,
      lastMessageAt: _at,
      projectId: projectId,
    );

    setUp(() async {
      for (final id in ['p1', 'p2']) {
        await repository.upsertProject(
          GaiaProject(id: id, name: id, createdAt: _at, updatedAt: _at),
        );
      }
      await repository.upsertChat(chat('in1', 'p1'));
      await repository.upsertChat(chat('loose', null));
      await repository.upsertChat(chat('lost', 'gone'));
      await repository.upsertMemory(_memory('g', 'Likes green tea'));
      await repository.upsertMemory(
        _memory('m1', 'Trip tea house booked', projectId: 'p1'),
      );
      await repository.upsertMemory(
        _memory('m2', 'Other project tea notes', projectId: 'p2'),
      );
      // Its project isn't here: it counts as global (§2).
      await repository.upsertMemory(
        _memory('m3', 'Orphan tea fact', projectId: 'gone'),
      );
    });

    Future<String> search(String chatId) =>
        memories.tool(chatId, 'memory_search', {'query': 'tea'});

    test("the curator's list holds active memories from any project "
        '(GAIA_MEMORY_TOPICS_HLD.md §7)', () async {
      final index = await curatorList('tea');
      expect(index, contains('Likes green tea'));
      expect(index, contains('Orphan tea fact'));
      expect(index, contains('Trip tea house'));
      expect(index, contains('Other project'));
    });

    test('search finds every memory, from any project '
        '(GAIA_MEMORY_TOPICS_HLD.md §4.6)', () async {
      for (final id in ['in1', 'loose', 'lost']) {
        final found = await search(id);
        expect(found, contains('Trip tea house'));
        expect(found, contains('Likes green tea'));
        expect(found, contains('Orphan tea fact'));
        expect(found, contains('Other project'));
      }
    });

    test('memory_propose keeps it for the project unless scope is global, '
        'and outside a project it is global', () async {
      final reply = await memories.tool('in1', 'memory_propose', {
        'text': 'Rail pass bought',
      });
      expect(reply, contains('for this project'));
      await memories.tool('in1', 'memory_propose', {
        'text': 'Hates early flights',
        'scope': 'global',
      });
      await memories.tool('loose', 'memory_propose', {
        'text': 'Reads on trains',
        'scope': 'project',
      });
      await memories.tool('lost', 'memory_propose', {'text': 'Packs light'});
      // Filed in the project's topic, with no `projectId` written
      // (GAIA_MEMORY_TOPICS_HLD.md §10).
      final saved = {
        for (final memory in await repository.listMemories())
          memory.text: [?memory.projectId, ...memory.topicIds],
      };
      expect(saved['Rail pass bought'], ['project-p1']);
      expect(saved['Hates early flights'], isEmpty);
      expect(saved['Reads on trains'], isEmpty);
      expect(saved['Packs light'], isEmpty);
    });

    test("one gone with its project doesn't block a save; any other does, "
        'from any project (GAIA_MEMORY_TOPICS_HLD.md §5)', () async {
      await repository.upsertMemory(
        _memory('d', 'Uses pnpm', projectId: 'gone').copyWith(deletedAt: _at),
      );
      Future<GaiaMemory?> save(String text, String? projectId) => memories.save(
        text,
        status: GaiaMemoryStatus.proposed,
        projectId: projectId,
      );
      expect(await save('Other project tea notes', 'p1'), isNull);
      expect(await save('Uses pnpm', 'p1'), isNotNull);
      expect(await save('Likes green tea', 'p1'), isNull);
      expect(await save('Orphan tea fact', 'p2'), isNull);
      expect(await save('Trip tea house booked', 'p1'), isNull);
    });

    test("the curator saves to the chat's project", () async {
      await memories.curated('in1', 3, [_found('Ryokan in Kyoto')]);
      await memories.curated('loose', 3, [_found('Walks daily')]);
      final saved = {
        for (final memory in await repository.listMemories())
          memory.text: [?memory.projectId, ...memory.topicIds],
      };
      expect(saved['Ryokan in Kyoto'], ['project-p1']);
      expect(saved['Walks daily'], isEmpty);
    });

    test("projectOf is the chat's live project", () async {
      expect(await memories.projectOf('in1'), 'p1');
      expect(await memories.projectOf('loose'), isNull);
      expect(await memories.projectOf('lost'), isNull);
      expect(await memories.projectOf(null), isNull);
    });

    test('with no chat yet, projectOf is the live project picked', () async {
      expect(await memories.projectOf(null, newChat: 'p1'), 'p1');
      expect(await memories.projectOf(null, newChat: 'nowhere'), isNull);
      expect(await memories.projectOf('loose', newChat: 'p1'), isNull);
    });
  });
}

/// A memory the curator found, filed nowhere.
GaiaFoundMemory _found(String text, [List<String> tags = const []]) =>
    (text: text, tags: tags, topicIds: const [], suggested: null, pin: false);
