import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/soft_delete/erasure.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/sync/firestore_document_mapper.dart';
import 'package:voyager/core/sync/synced_write_notifier.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/host/gaia_chat_store.dart';

/// Gaia's store (GAIA_HLD.md §8): the companion's reads and writes on top of
/// the drift repository, what reaches sync, and message search.

final _created = DateTime.utc(2026, 10, 24);

GaiaChat _chat(String id, {DateTime? at}) => GaiaChat(
  id: id,
  title: 'Chat $id',
  createdAt: _created,
  updatedAt: _created,
  lastMessageAt: at ?? _created,
);

GaiaMessage _message(
  String id,
  int seq, {
  String chatId = 'c1',
  GaiaMessageStatus status = GaiaMessageStatus.complete,
  DateTime? at,
  String text = 'x',
}) => GaiaMessage(
  id: id,
  chatId: chatId,
  seq: seq,
  role: seq.isEven ? GaiaMessageRole.user : GaiaMessageRole.assistant,
  parts: [GaiaTextPart(text)],
  status: status,
  createdAt: at ?? _created,
  updatedAt: at ?? _created,
);

void main() {
  late AppDatabase db;
  late DriftGaiaRepository repository;
  late GaiaChatStore store;

  /// Uploads asked for, as `collection/id`.
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
    store = GaiaChatStore(repository, deviceId: 'laptop');
  });

  tearDown(() => db.close());

  test('messages come back in seq order, and a put replaces by id', () async {
    await store.createChat(_chat('c1'));
    await store.putMessage(
      _message('b', 1, status: GaiaMessageStatus.streaming),
    );
    await store.putMessage(_message('a', 0));
    await store.putMessage(_message('b', 1));
    final messages = await store.messages('c1');
    expect(messages.map((m) => m.id), ['a', 'b']);
    expect(messages.last.status, GaiaMessageStatus.complete);
    // Each put is a new version of what's stored.
    expect(messages.last.version, 2);
  });

  test('a later message moves its chat to the top', () async {
    await store.createChat(_chat('c1'));
    await store.createChat(
      _chat('c2', at: _created.add(const Duration(hours: 1))),
    );
    expect((await store.chats()).first.id, 'c2');
    await store.putMessage(
      _message('a', 0, at: _created.add(const Duration(hours: 2))),
    );
    expect((await store.chats()).first.id, 'c1');
  });

  test('a pinned chat stays above more recent ones', () async {
    await store.createChat(_chat('c1'));
    await store.createChat(
      _chat('c2', at: _created.add(const Duration(hours: 1))),
    );
    final c1 = (await repository.getChat('c1'))!;
    await repository.upsertChat(c1.copyWith(pinned: true));
    expect((await store.chats()).map((c) => c.id), ['c1', 'c2']);
  });

  test('a chat the companion re-sends is left as stored', () async {
    await store.createChat(_chat('c1'));
    final stored = (await repository.getChat('c1'))!;
    await repository.upsertChat(stored.copyWith(title: 'Renamed'));
    await store.createChat(_chat('c1'));
    expect((await repository.getChat('c1'))!.title, 'Renamed');
  });

  test('sessions are kept per device', () async {
    await store.createChat(_chat('c1'));
    await GaiaChatStore(
      repository,
      deviceId: 'desktop',
    ).setSession('c1', 'desktop-session', 1);
    await store.setSession('c1', 'laptop-session', 3);
    final chat = (await repository.getChat('c1'))!;
    expect(chat.sessionOn('desktop'), 'desktop-session');
    expect(chat.sessionOn('laptop'), 'laptop-session');
    expect(chat.agentSessions[gaiaSessionKey('laptop')]!.lastSeq, 3);
  });

  test('a lost companion leaves no message streaming', () async {
    await store.createChat(_chat('c1'));
    await store.putMessage(_message('a', 0));
    await store.putMessage(
      _message('b', 1, status: GaiaMessageStatus.streaming),
    );
    await store.endStreaming(GaiaMessageStatus.aborted);
    expect((await store.messages('c1')).map((m) => m.status), [
      GaiaMessageStatus.complete,
      GaiaMessageStatus.aborted,
    ]);
  });

  test('a streaming message uploads only once it ends', () async {
    await store.createChat(_chat('c1'));
    uploads.clear();
    await store.putMessage(
      _message('m', 1, status: GaiaMessageStatus.streaming),
    );
    expect(uploads, isNot(contains('${FirestoreCollections.gaiaMessages}/m')));
    await store.putMessage(_message('m', 1));
    expect(uploads, contains('${FirestoreCollections.gaiaMessages}/m'));
  });

  test('a message erased mid-run stays erased', () async {
    await store.createChat(_chat('c1'));
    await store.putMessage(
      _message('m', 1, status: GaiaMessageStatus.streaming),
    );
    final stored = (await repository.getMessage('m'))!;
    final erased = stored.copyWith(
      parts: const [],
      deletedAt: kErasedAt,
      version: stored.version + kEraseVersionStep,
    );
    await repository.upsertMessage(erased, recordLocalActivity: false);
    uploads.clear();
    await store.putMessage(_message('m', 1, text: 'secret'));
    // A message the run had yet to write, in the erased chat, is dropped too.
    final chat = (await repository.getChat('c1'))!;
    await repository.upsertChat(
      chat.copyWith(deletedAt: kErasedAt),
      recordLocalActivity: false,
    );
    await store.putMessage(_message('n', 2, text: 'secret'));
    expect((await repository.getMessage('m'))!.toJson(), erased.toJson());
    expect(await repository.getMessage('n'), isNull);
    expect(uploads, isEmpty);
    expect(await repository.searchChatIds('secret'), isEmpty);
  });

  test('a deleted chat leaves the list and comes back on restore', () async {
    await store.createChat(_chat('c1'));
    await repository.softDeleteChat('c1');
    expect(await store.chats(), isEmpty);
    await repository.restoreChat('c1');
    expect((await store.chats()).single.id, 'c1');
  });

  group('search', () {
    setUp(() async {
      await store.createChat(_chat('c1'));
      await store.createChat(_chat('c2'));
      await store.putMessage(_message('a', 0, text: 'Flutter drift migration'));
      await store.putMessage(
        _message('b', 0, chatId: 'c2', text: 'A recipe for bread'),
      );
    });

    test('matches every word, as a prefix', () async {
      expect(await repository.searchChatIds('drif migr'), {'c1'});
      expect(await repository.searchChatIds('bread'), {'c2'});
      expect(await repository.searchChatIds('drift bread'), isEmpty);
    });

    test('FTS syntax in a query is plain text', () async {
      expect(await repository.searchChatIds('"bread'), {'c2'});
      expect(await repository.searchChatIds('AND OR'), isEmpty);
      expect(await repository.searchChatIds('   '), isEmpty);
    });

    test('follows edits, and leaves out deleted chats', () async {
      await store.putMessage(_message('a', 0, text: 'Something else'));
      expect(await repository.searchChatIds('drift'), isEmpty);
      await repository.softDeleteChat('c2');
      expect(await repository.searchChatIds('bread'), isEmpty);
    });

    test('indexes a streamed reply once its run ends', () async {
      await store.putMessage(
        _message('s', 1, status: GaiaMessageStatus.streaming, text: 'kiwi'),
      );
      expect(await repository.searchChatIds('kiwi'), isEmpty);
      await store.putMessage(_message('s', 1, text: 'kiwi'));
      expect(await repository.searchChatIds('kiwi'), {'c1'});
    });

    test('an account wipe empties it', () async {
      for (final table in db.allTables) {
        await db.delete(table).go();
      }
      expect(await db.select(db.gaiaMessageSearch).get(), isEmpty);
    });
  });

  group('sync mapping', () {
    test('a chat round-trips through Firestore', () {
      final chat = _chat('c1').copyWith(
        pinned: true,
        agentSessions: {
          gaiaSessionKey('laptop'): const GaiaAgentSession(
            sessionId: 's',
            lastSeq: 4,
          ),
        },
      );
      final back = mergeGaiaChatFromRemote(gaiaChatToFirestore(chat), 'c1');
      expect(back.toJson(), chat.toJson());
    });

    test('a winning copy keeps the sessions it lacks', () {
      const mine = GaiaAgentSession(sessionId: 'mine', lastSeq: 2);
      const theirs = GaiaAgentSession(sessionId: 'theirs', lastSeq: 3);
      final local = _chat('c1').copyWith(
        agentSessions: {gaiaSessionKey('laptop'): mine},
      );
      final remote = _chat('c1').copyWith(
        agentSessions: {gaiaSessionKey('desktop'): theirs},
        version: local.version + 1,
      );
      final merged = mergeGaiaChatFromRemote(
        gaiaChatToFirestore(remote),
        'c1',
        local: local,
      );
      expect(merged.sessionOn('laptop'), 'mine');
      expect(merged.sessionOn('desktop'), 'theirs');
      // An erase doesn't.
      final erased = mergeGaiaChatFromRemote(
        gaiaChatToFirestore(
          remote.copyWith(
            agentSessions: const {},
            deletedAt: kErasedAt,
            version: local.version + kEraseVersionStep,
          ),
        ),
        'c1',
        local: local,
      );
      expect(erased.agentSessions, isEmpty);
    });

    test('a message round-trips through Firestore', () {
      final message = _message('m', 1).copyWith(
        parts: const [
          GaiaTextPart('before'),
          GaiaActivityPart(['Bash', 'Edit']),
          GaiaTextPart('after'),
        ],
        needsInput: true,
      );
      final back = mergeGaiaMessageFromRemote(
        gaiaMessageToFirestore(message),
        'm',
      );
      expect(back.toJson(), message.toJson());
    });

    test('an older remote copy loses to the local one', () {
      final local = _message('m', 1).copyWith(version: 5);
      final remote = gaiaMessageToFirestore(
        _message('m', 1, text: 'stale').copyWith(version: 2),
      );
      expect(mergeGaiaMessageFromRemote(remote, 'm', local: local), local);
    });

    test("a newer build's part is kept unshown, and written back as it "
        'came', () {
      final data = gaiaMessageToFirestore(_message('m', 1))
        ..['parts'] = [
          {'type': 'hologram', 'depth': 3},
        ];
      final message = mergeGaiaMessageFromRemote(data, 'm');
      expect(message.parts.single, isA<GaiaUnknownPart>());
      expect(gaiaMessageToFirestore(message)['parts'], [
        {'type': 'hologram', 'depth': 3},
      ]);
    });
  });

  test('a message round-trips through the pipe', () {
    final message = _message(
      'a',
      3,
    ).copyWith(status: GaiaMessageStatus.error, error: 'boom');
    expect(GaiaMessage.fromJson(message.toJson()).toJson(), message.toJson());
  });

  test('a question is told apart from a statement', () {
    expect(gaiaEndsWithQuestion('Done.\n\nShould I push?'), isTrue);
    expect(gaiaEndsWithQuestion('Want me to **merge it?**'), isTrue);
    expect(gaiaEndsWithQuestion('Is it? Yes.\n\nDone.'), isFalse);
    expect(gaiaEndsWithQuestion(''), isFalse);
  });
}
