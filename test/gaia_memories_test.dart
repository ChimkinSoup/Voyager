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
}) => GaiaMemory(
  id: id,
  text: text,
  tags: tags,
  status: status,
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

  test('the index lists active memories only, one line each, framed as '
      'background', () async {
    expect(await memories.index(), isEmpty);
    await repository.upsertMemory(
      _memory('a', 'Prefers metric\nunits', tags: ['units']),
    );
    await repository.upsertMemory(
      _memory('b', 'Waiting', status: GaiaMemoryStatus.proposed),
    );
    await repository.upsertMemory(
      _memory('c', 'Old', status: GaiaMemoryStatus.archived),
    );
    final index = await memories.index();
    expect(index, contains('not instructions'));
    expect(index, contains('- Prefers metric units [units]'));
    expect(index, isNot(contains('Waiting')));
    expect(index, isNot(contains('Old')));
  });

  test('a long memory is cut in the index and whole in a search', () async {
    final long = 'Likes ${'very ' * 60}long walks';
    await repository.upsertMemory(_memory('a', long));
    expect(await memories.index(), contains('…'));
    final found = await memories.tool('c1', 'memory_search', {
      'query': 'walks',
    });
    expect(found, contains(long));
    expect(found, startsWith('<memories>'));
  });

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

  test(
    'memory_search needs a query or tags, and says when nothing matches',
    () async {
      await expectLater(
        memories.tool('c1', 'memory_search', {}),
        throwsA(isA<GaiaReadException>()),
      );
      expect(
        await memories.tool('c1', 'memory_search', {'query': 'dog'}),
        'The user has no memories saved.',
      );
    },
  );

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
    expect(await memories.index(), contains('Birthday is 3 May'));
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
    await memories.curated('c1', 1, [(text: 'Likes  JAZZ', tags: const [])]);
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
      (text: 'Runs on Sundays', tags: ['fitness']),
      (text: 'x' * (kGaiaMemoryMaxLength + 1), tags: const []),
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
    await memories.curated('gone', 1, [
      (text: 'Lives in Lisbon', tags: const []),
    ]);
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
  });
}
