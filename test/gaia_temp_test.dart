import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/sync/firestore_document_mapper.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/host/gaia_chat_store.dart';
import 'package:voyager/features/gaia/host/gaia_memories.dart';

/// Temporary chats (GAIA_TEMP_HLD.md): off the lists once out of view, never
/// read by the curator, their waiting suggestions thrown out.

final _at = DateTime.utc(2026, 11, 24, 12);

GaiaChat _chat(String id, {int minutes = 0}) => GaiaChat(
  id: id,
  title: id,
  createdAt: _at,
  updatedAt: _at,
  lastMessageAt: _at.add(Duration(minutes: minutes)),
);

GaiaMessage _message(String chatId, int seq, {List<GaiaPart>? parts}) =>
    GaiaMessage(
      id: '$chatId-$seq',
      chatId: chatId,
      seq: seq,
      role: seq.isEven ? GaiaMessageRole.user : GaiaMessageRole.assistant,
      parts: parts ?? [GaiaTextPart('turn $seq')],
      status: GaiaMessageStatus.complete,
      createdAt: _at,
      updatedAt: _at,
    );

List<String> _ids(List<GaiaForkGroup> groups) => [
  for (final group in groups) group.chat.id,
];

void main() {
  group('the model (§2, §4)', () {
    test('a temporary chat stays archived after a later message', () {
      final temp = gaiaTemporary(_chat('c'));
      expect(temp.archived, isTrue);
      final later = temp.copyWith(
        lastMessageAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
      );
      expect(later.archived, isTrue);
    });

    test('making it temporary unpins it', () {
      final pinned = gaiaPinned(_chat('c'), true, const []);
      final temp = gaiaTemporary(pinned);
      expect(temp.pinned, isFalse);
      expect(temp.order, isNull);
    });

    test('in view, it is listed where it would be; out of view, in '
        'Archived', () {
      final chats = [gaiaTemporary(_chat('temp', minutes: 2)), _chat('other')];
      final inView = gaiaChatSections(chats, const [], inView: 'temp');
      expect(_ids(inView.chats), ['temp', 'other']);
      expect(inView.archived, isEmpty);
      final away = gaiaChatSections(chats, const [], inView: 'other');
      expect(_ids(away.chats), ['other']);
      expect(_ids(away.archived), ['temp']);
      // Only a temporary one: an archived chat in view stays archived.
      final archived = gaiaChatSections(
        [gaiaArchived(_chat('a'), true)],
        const [],
        inView: 'a',
      );
      expect(_ids(archived.archived), ['a']);
    });

    test('unarchiving its original leaves a temporary fork temporary', () {
      final original = gaiaArchived(_chat('a'), true);
      final fork = gaiaTemporary(
        GaiaChat(
          id: 'f',
          title: 'f',
          createdAt: _at,
          updatedAt: _at,
          lastMessageAt: _at,
          forkOf: 'a',
        ),
      );
      final back = gaiaArchivedWithForks(original, false, [original, fork]);
      expect([for (final chat in back) chat.id], ['a']);
    });

    test('pinning makes it an ordinary chat', () {
      final pinned = gaiaPinned(gaiaTemporary(_chat('c')), true, const []);
      expect(pinned.temporary, isFalse);
      expect(pinned.archived, isFalse);
    });

    test('unarchiving makes it an ordinary chat', () {
      final back = gaiaArchived(gaiaTemporary(_chat('c')), false);
      expect(back.temporary, isFalse);
      expect(back.archived, isFalse);
    });

    test('it syncs, and turning it off clears it on the other device', () {
      final temp = gaiaTemporary(_chat('c'));
      final remote = mergeGaiaChatFromRemote(
        gaiaChatToFirestore(temp),
        'c',
        local: _chat('c'),
      );
      expect(remote.temporaryAt, temp.temporaryAt);
      final cleared = mergeGaiaChatFromRemote(
        gaiaChatToFirestore(gaiaArchived(temp, false)),
        'c',
        local: temp,
      );
      expect(cleared.temporary, isFalse);
      expect(GaiaChat.fromJson(temp.toJson()).temporaryAt, temp.temporaryAt);
    });
  });

  group('the main instance (§3, §5, §6)', () {
    late AppDatabase db;
    late DriftGaiaRepository repository;
    late GaiaChatStore store;
    late GaiaMemories memories;

    setUp(() async {
      db = AppDatabase.inMemory();
      repository = DriftGaiaRepository(db);
      store = GaiaChatStore(repository, deviceId: 'laptop');
      memories = GaiaMemories(repository);
      await repository.upsertChat(_chat('c1'));
      for (var seq = 0; seq < 4; seq++) {
        await repository.upsertMessage(_message('c1', seq));
      }
    });

    tearDown(() => db.close());

    test('the drift row keeps it', () async {
      await store.setTemporary('c1', true);
      final stored = (await repository.getChat('c1'))!;
      expect(stored.temporary, isTrue);
      expect(stored.archived, isTrue);
    });

    test('turning it off marks the chat read up to its last message, so '
        'the curator never reads the temporary part (§3.3)', () async {
      await store.setTemporary('c1', true);
      await store.setTemporary('c1', false);
      final chat = (await repository.getChat('c1'))!;
      expect(chat.temporary, isFalse);
      expect(chat.archived, isFalse);
      expect(chat.curatedSeq, 3);
    });

    test('Unarchive does the same', () async {
      await store.setTemporary('c1', true);
      await store.setArchived('c1', false);
      final chat = (await repository.getChat('c1'))!;
      expect(chat.temporary, isFalse);
      expect(chat.curatedSeq, 3);
    });

    test('Pin does the same, where it was dropped or not', () async {
      await store.setTemporary('c1', true);
      await store.setPinned('c1', true);
      final chat = (await repository.getChat('c1'))!;
      expect(chat.temporary, isFalse);
      expect(chat.archived, isFalse);
      expect(chat.curatedSeq, 3);
      await store.setPinned('c1', false);
      await store.setTemporary('c1', true);
      await repository.upsertChat(
        (await repository.getChat('c1'))!.copyWith(curatedSeq: -1),
      );
      await store.setPinned('c1', true, order: 5);
      final dropped = (await repository.getChat('c1'))!;
      expect(dropped.temporary, isFalse);
      expect(dropped.curatedSeq, 3);
    });

    test('the curator finishing after /temp saves nothing and leaves the '
        'chat unread (§5)', () async {
      await store.setTemporary('c1', true);
      await memories.curated('c1', 3, [
        (
          text: 'Runs on Sundays',
          tags: const [],
          topicIds: const [],
          suggested: null,
          pin: false,
          replacesId: null,
        ),
      ]);
      expect(await repository.listMemories(), isEmpty);
      expect((await repository.getChat('c1'))!.curatedSeq, -1);
    });

    test("only the chat's waiting curator suggestions are thrown out, and "
        'restore brings them back (§6)', () async {
      Future<GaiaMemory> saved(
        String text, {
        String chatId = 'c1',
        GaiaMemoryStatus status = GaiaMemoryStatus.proposed,
      }) async => (await memories.save(text, chatId: chatId, status: status))!;
      final waiting = await saved('Likes jazz');
      final carded = await saved('Has a dog');
      final active = await saved('Studies CS', status: GaiaMemoryStatus.active);
      final elsewhere = await saved('Lives in Lisbon', chatId: 'c2');
      await repository.upsertMessage(
        _message(
          'c1',
          4,
          parts: [GaiaMemoryPart(memoryId: carded.id, text: carded.text)],
        ),
      );

      final thrown = await memories.throwOut('c1');
      expect(thrown, [waiting.id]);
      final live = {
        for (final memory in await repository.listMemories())
          if (!memory.isDeleted) memory.id,
      };
      expect(live, {carded.id, active.id, elsewhere.id});

      for (final id in thrown) {
        await memories.restore(id);
      }
      expect((await repository.getMemory(waiting.id))!.isDeleted, isFalse);
    });
  });
}
