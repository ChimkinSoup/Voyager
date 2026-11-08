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

  // A rewind pauses drain mode, and the companion's copy of the chat can
  // still say it's on (GAIA_REWIND_HLD.md §4 step 0).
  test(
    "a drain's pop takes nothing once the chat's drain mode is off",
    () async {
      await store.createChat(_chat('c1'));
      await store.enqueue('c1', 'Later');
      expect(await store.queuePop('c1', draining: true), isNull);
      expect(await store.queue('c1'), hasLength(1));
      await store.setDrain('c1', true);
      expect((await store.queuePop('c1', draining: true))?.text, 'Later');
    },
  );

  test('restorable chats: live and in the trash, not erased or expired '
      '(kept tool results, §15.6)', () async {
    for (final id in ['live', 'trashed', 'erased', 'expired']) {
      await store.createChat(_chat(id));
    }
    await store.deleteChat('trashed');
    final erased = (await repository.getChat('erased'))!;
    await repository.upsertChat(erased.copyWith(deletedAt: kErasedAt));
    final expired = (await repository.getChat('expired'))!;
    await repository.upsertChat(
      expired.copyWith(deletedAt: DateTime.utc(2020)),
    );
    expect(await store.restorableChatIds(), unorderedEquals(['live', 'trashed']));
  });

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

  test('a tick stays as stored through the streaming writes after it, '
      'whatever ticks they carry', () async {
    await store.createChat(_chat('c1'));
    final streaming = _message(
      'b',
      1,
      status: GaiaMessageStatus.streaming,
      text: '- [ ] a\n- [ ] b',
    );
    await store.putMessage(streaming);
    expect(await store.toggleCheck('b', 0, 1, true), isNotNull);
    final written = await store.putMessage(
      _message('b', 1, text: '- [ ] a\n- [ ] b\n\nDone.').copyWith(
        parts: [
          const GaiaTextPart('- [ ] a\n- [ ] b\n\nDone.', checks: {0}),
        ],
      ),
    );
    expect((written!.parts.single as GaiaTextPart).checks, {1});
    final stored = (await store.messages('c1')).single;
    expect((stored.parts.single as GaiaTextPart).text, endsWith('Done.'));
    expect((stored.parts.single as GaiaTextPart).checks, {1});
    expect(await store.toggleCheck('missing', 0, 0, true), isNull);
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

  test('setPinned changes only whether the chat is pinned', () async {
    await store.createChat(_chat('c1'));
    final stored = (await repository.getChat('c1'))!;
    await repository.upsertChat(stored.copyWith(title: 'Renamed'));

    await store.setPinned('c1', true);
    final pinned = (await repository.getChat('c1'))!;
    expect(pinned.pinned, isTrue);
    expect(pinned.title, 'Renamed');

    await store.setPinned('c1', false);
    expect((await repository.getChat('c1'))!.pinned, isFalse);
  });

  test('setPinned on a chat not stored does nothing', () async {
    await store.setPinned('missing', true);
    expect(await repository.getChat('missing'), isNull);
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

  group('chapters (GAIA_CHAPTERS_HLD.md §3.1)', () {
    setUp(() async {
      await store.createChat(_chat('c1'));
      await store.putMessage(_message('m', 1));
    });

    Future<String?> chapter() async =>
        (await repository.getMessage('m'))!.chapter;

    test("a whole-message put keeps the stored chapter, whatever the "
        "companion's copy says", () async {
      await store.setChapter('m', 'Stored');
      await store.putMessage(_message('m', 1, text: 'answered'));
      expect(await chapter(), 'Stored');
      await store.putMessage(
        _message('m', 1).copyWith(chapter: 'Stale', bumpVersion: false),
      );
      expect(await chapter(), 'Stored');
    });

    test('a first put keeps its own chapter: one pinned before it was '
        'stored', () async {
      await store.putMessage(
        _message('n', 2).copyWith(chapter: 'Early', bumpVersion: false),
      );
      expect((await repository.getMessage('n'))!.chapter, 'Early');
    });

    test('watchChapters gives each live message with a chapter', () async {
      final seen = <Map<String, String>>[];
      final sub = repository.watchChapters().listen(seen.add);
      await pumpEventQueue();
      await store.setChapter('m', 'Stored');
      await pumpEventQueue();
      await store.setChapter('m', null);
      await pumpEventQueue();
      await sub.cancel();
      expect(seen.first, isEmpty);
      expect(seen, contains(equals({'m': 'Stored'})));
      expect(seen.last, isEmpty);
    });

    test('setChapter with from writes only over that title', () async {
      await store.setChapter('m', 'First line');
      await store.setChapter('m', 'Renamed');
      await store.setChapter('m', 'Utility', from: 'First line');
      expect(await chapter(), 'Renamed');
      await store.setChapter('m', 'Utility', from: 'Renamed');
      expect(await chapter(), 'Utility');
      // An unpin is stored, and the utility's title doesn't bring it back.
      await store.setChapter('m', null);
      await store.setChapter('m', 'Late', from: 'Utility');
      expect(await chapter(), isNull);
    });

    test('nothing for a message gone, and a take-back erases it', () async {
      await store.setChapter('gone', 'X');
      expect(await repository.getMessage('gone'), isNull);
      await store.setChapter('m', 'Stored');
      await store.takeBack([(await repository.getMessage('m'))!], chat: false);
      expect(await chapter(), isNull);
      await store.setChapter('m', 'Again');
      expect(await chapter(), isNull);
    });
  });

  test('a deleted chat leaves the list and comes back on restore', () async {
    await store.createChat(_chat('c1'));
    await repository.softDeleteChat('c1');
    expect(await store.chats(), isEmpty);
    await repository.restoreChat('c1');
    expect((await store.chats()).single.id, 'c1');
  });

  GaiaDraft draft(String text) =>
      GaiaDraft(id: 'c1', text: text, createdAt: _created, updatedAt: _created);

  test('a draft goes with its chat, and comes back with it', () async {
    await store.putDraft(draft('Half typed'));
    await store.deleteDraft('c1');
    final deleted = (await repository.getDraft('c1'))!;
    expect(deleted.deletedAt, isNotNull);
    expect(deleted.text, 'Half typed');

    final restored = (await store.restoreDraft('c1'))!;
    expect(restored.deletedAt, isNull);
    expect(restored.version, deleted.version + 1);
    expect((await repository.getDraft('c1'))!.text, 'Half typed');
  });

  test('an empty draft is kept deleted, and not restored', () async {
    await store.putDraft(draft('Hi'));
    await store.putDraft(draft(''));
    expect((await repository.getDraft('c1'))!.deletedAt, isNotNull);
    expect(await store.restoreDraft('c1'), isNull);
    await store.putDraft(draft('Again'));
    expect((await repository.getDraft('c1'))!.deletedAt, isNull);
  });

  group('grants (§15.6)', () {
    setUp(() async {
      await store.createChat(_chat('c1'));
      await store.setSeeScreen('c1', true);
    });

    test('only count on the device that gave them', () async {
      expect(await store.canSeeScreen('c1'), isTrue);
      final phone = GaiaChatStore(repository, deviceId: 'phone');
      expect(await phone.canSeeScreen('c1'), isFalse);
    });

    test('revoking leaves another device\'s alone', () async {
      await GaiaChatStore(
        repository,
        deviceId: 'phone',
      ).setSeeScreen('c1', true);
      await store.revokeGrants();
      expect(await store.canSeeScreen('c1'), isFalse);
      expect(
        await GaiaChatStore(repository, deviceId: 'phone').canSeeScreen('c1'),
        isTrue,
      );
    });

    test('a chat in the trash has none, and restored, still none', () async {
      await store.deleteChat('c1');
      expect(await store.canSeeScreen('c1'), isFalse);
      await store.revokeGrants();
      await store.restoreChat('c1');
      expect(await store.canSeeScreen('c1'), isFalse);
    });
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
      final local = _chat(
        'c1',
      ).copyWith(agentSessions: {gaiaSessionKey('laptop'): mine});
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

    test("rewinds merge as a union, so two devices' both count", () {
      const mine = GaiaRewind(from: 2, to: 3, forkId: 'f1', by: 'laptop');
      const theirs = GaiaRewind(from: 4, to: 7, forkId: 'f2', by: 'desktop');
      final local = _chat('c1').copyWith(rewinds: [mine]);
      final remote = _chat(
        'c1',
      ).copyWith(rewinds: [theirs, mine], version: local.version + 1);
      final merged = mergeGaiaChatFromRemote(
        gaiaChatToFirestore(remote),
        'c1',
        local: local,
      );
      expect(merged.rewinds, [mine, theirs]);
      // A copy that lacks one keeps it.
      final stale = mergeGaiaChatFromRemote(
        gaiaChatToFirestore(_chat('c1').copyWith(version: merged.version + 1)),
        'c1',
        local: merged,
      );
      expect(stale.rewinds, [mine, theirs]);
      expect(GaiaChat.fromJson(merged.toJson()).rewinds, [mine, theirs]);
    });

    test("a winning copy doesn't take curatedSeq back", () {
      final local = _chat('c1').copyWith(curatedSeq: 12);
      final remote = _chat('c1').copyWith(version: local.version + 1);
      final merged = mergeGaiaChatFromRemote(
        gaiaChatToFirestore(remote),
        'c1',
        local: local,
      );
      expect(merged.curatedSeq, 12);
      final ahead = mergeGaiaChatFromRemote(
        gaiaChatToFirestore(remote.copyWith(curatedSeq: 20)),
        'c1',
        local: local,
      );
      expect(ahead.curatedSeq, 20);
    });

    test("a message's chapter: taken when the payload has it, an explicit "
        'null unpinning, and kept from a build before chapters', () {
      final local = _message('m', 1).copyWith(chapter: 'Mine');
      final remote = local.copyWith(version: local.version + 5);
      final payload = gaiaMessageToFirestore(remote);
      GaiaMessage merge(Map<String, dynamic> data) =>
          mergeGaiaMessageFromRemote(data, 'm', local: local);
      expect(merge({...payload, 'chapter': 'Theirs'}).chapter, 'Theirs');
      expect(merge({...payload, 'chapter': null}).chapter, isNull);
      expect(merge({...payload}..remove('chapter')).chapter, 'Mine');
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

  test('the action log reads only live messages holding a commit', () async {
    GaiaCardPart card(GaiaCardState state, {bool committed = true}) =>
        GaiaCardPart(
          id: 'card',
          kind: GaiaCardKind.proposal,
          state: state,
          tool: 'propose_todo',
          proposal: const GaiaProposal(
            entity: GaiaProposalEntity.todo,
            fields: {'title': 'One'},
          ),
          answer: {
            'fields': const {'title': 'One'},
            if (committed) 'committed': const {'entity': 'todo', 'id': 't1'},
          },
        );
    GaiaMessage withParts(String id, int seq, List<GaiaPart> parts) =>
        _message(id, seq).copyWith(parts: parts);
    await repository.upsertMessage(
      withParts('kept', 0, [card(GaiaCardState.accepted)]),
    );
    await repository.upsertMessage(
      withParts('rejected', 1, [card(GaiaCardState.rejected)]),
    );
    await repository.upsertMessage(
      withParts('unwritten', 2, [
        card(GaiaCardState.accepted, committed: false),
      ]),
    );
    await repository.upsertMessage(
      _message('talk', 3, text: '"state":"accepted" and "committed": both'),
    );
    await repository.upsertMessage(
      withParts('deleted', 4, [
        card(GaiaCardState.accepted),
      ]).copyWith(deletedAt: _created),
    );
    await repository.upsertMessage(
      withParts('steps declined partway', 5, [
        const GaiaCardPart(
          id: 'steps',
          kind: GaiaCardKind.control,
          state: GaiaCardState.rejected,
          tool: 'os_steps',
          answer: {
            'ran': 1,
            'committed': {'steps': 1},
          },
        ),
      ]),
    );
    final found = await repository.listMessagesWithCommits();
    // Text's quotes are escaped in the JSON, so words alone don't match.
    expect(found.map((m) => m.id), ['kept', 'steps declined partway']);
  });

  test('a question is told apart from a statement', () {
    expect(gaiaEndsWithQuestion('Done.\n\nShould I push?'), isTrue);
    expect(gaiaEndsWithQuestion('Want me to **merge it?**'), isTrue);
    expect(gaiaEndsWithQuestion('Is it? Yes.\n\nDone.'), isFalse);
    expect(gaiaEndsWithQuestion(''), isFalse);
  });
}
