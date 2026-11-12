import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/sync/firestore_document_mapper.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/host/gaia_chat_store.dart';
import 'package:voyager/features/gaia/host/gaia_project_reads.dart';
import 'package:voyager/features/gaia/host/gaia_voyager_reads.dart';
import 'package:voyager/features/gaia/tools/gaia_mcp.dart';

/// Projects, Phase 2 (GAIA_PROJECTS_HLD.md §5, §12): the project tools, the
/// block that tells a session about its project, and chat summaries.

final _at = DateTime.utc(2026, 11, 11, 12);

GaiaChat _chat(
  String id, {
  String? projectId,
  String? summary,
  List<GaiaRewind> rewinds = const [],
  int minutes = 0,
}) => GaiaChat(
  id: id,
  title: 'Title $id',
  createdAt: _at,
  updatedAt: _at,
  lastMessageAt: _at.add(Duration(minutes: minutes)),
  projectId: projectId,
  summary: summary,
  rewinds: rewinds,
);

GaiaMessage _message(
  String chatId,
  int seq,
  List<GaiaPart> parts, {
  GaiaMessageStatus status = GaiaMessageStatus.complete,
}) => GaiaMessage(
  id: '$chatId-$seq',
  chatId: chatId,
  seq: seq,
  role: seq.isEven ? GaiaMessageRole.user : GaiaMessageRole.assistant,
  parts: parts,
  status: status,
  createdAt: _at.add(Duration(seconds: seq)),
  updatedAt: _at,
);

GaiaMessage _text(String chatId, int seq, String text) =>
    _message(chatId, seq, [GaiaTextPart(text)]);

void main() {
  group('the reads (§5.1, §5.3)', () {
    late AppDatabase db;
    late DriftGaiaRepository repository;
    late GaiaProjectReads reads;

    setUp(() async {
      db = AppDatabase.inMemory();
      repository = DriftGaiaRepository(db);
      reads = GaiaProjectReads(repository);
      await repository.upsertProject(
        GaiaProject(id: 'p1', name: 'Trip', createdAt: _at, updatedAt: _at),
      );
      await repository.upsertProject(
        GaiaProject(id: 'p2', name: 'Work', createdAt: _at, updatedAt: _at),
      );
      await repository.upsertChat(
        _chat('here', projectId: 'p1', summary: 'Booking flights.', minutes: 2),
      );
      await repository.upsertChat(
        _chat('sibling', projectId: 'p1', minutes: 1),
      );
      await repository.upsertChat(_chat('other', projectId: 'p2'));
      await repository.upsertChat(_chat('loose'));
      await repository.upsertMessage(_text('here', 0, 'Ryokan near Kyoto'));
      await repository.upsertMessage(
        _text('sibling', 0, 'Which ryokan has an onsen?\nMore detail'),
      );
      await repository.upsertMessage(_text('other', 0, 'Ryokan budget memo'));
      await repository.upsertMessage(_text('loose', 0, 'Ryokan for a friend'));
    });

    tearDown(() => db.close());

    test('a chat in no project, or in one that is gone, is told so', () async {
      expect(
        await reads.tool('loose', 'project_chats', const {}),
        "This chat isn't in a project.",
      );
      await repository.upsertChat(_chat('stray', projectId: 'gone'));
      expect(
        await reads.tool('stray', 'project_search', const {'query': 'x'}),
        "This chat isn't in a project.",
      );
    });

    test('project_chats lists only the project, marks this chat, and falls '
        'back to the first line for a chat with no summary', () async {
      final text = await reads.tool('here', 'project_chats', const {});
      expect(text, startsWith('<project_chats project="Trip">'));
      expect(text, contains('- Title here (this chat)'));
      expect(text, contains('About: Booking flights.'));
      expect(text, contains('About: Which ryokan has an onsen?'));
      expect(text, isNot(contains('More detail')));
      expect(text, contains('1 message'));
      expect(text, isNot(contains('other')));
      expect(text, isNot(contains('loose')));
      // Most recent first.
      expect(text.indexOf('Title here'), lessThan(text.indexOf('Title sib')));
    });

    test('project_search finds only the project, and no message still '
        'streaming', () async {
      await repository.upsertMessage(
        _message('sibling', 1, const [
          GaiaTextPart('Ryokan answer half written'),
        ], status: GaiaMessageStatus.streaming),
      );
      final text = await reads.tool('here', 'project_search', const {
        'query': 'ryokan',
      });
      expect(text, contains('(id: here), seq 0, User: **Ryokan** near Kyoto'));
      expect(text, contains('(id: sibling), seq 0'));
      expect(text, isNot(contains('half written')));
      expect(text, isNot(contains('budget')));
      expect(text, isNot(contains('friend')));
      expect(
        await reads.tool('here', 'project_search', const {'query': 'zebra'}),
        "Nothing in this project's chats matches.",
      );
    });

    test('project_chats counts no message a rewind dropped, and sets aside a '
        'summary written into them', () async {
      await repository.upsertMessage(_text('sibling', 1, 'Onsen answer'));
      await repository.upsertMessage(_text('sibling', 2, 'Dropped prompt'));
      await repository.upsertMessage(_text('sibling', 3, 'Dropped answer'));
      await repository.upsertChat(
        _chat(
          'sibling',
          projectId: 'p1',
          summary: 'Tells of the dropped turns.',
          rewinds: const [GaiaRewind(from: 2, to: 3, forkId: 'f', by: 'desk')],
          minutes: 1,
        ).copyWith(summarizedSeq: 3),
      );
      final text = await reads.tool('here', 'project_chats', const {});
      expect(text, contains('2 messages'));
      expect(text, isNot(contains('Tells of the dropped')));
      expect(text, contains('About: Which ryokan has an onsen?'));
    });

    test("project_search's limit counts no message streaming again", () async {
      // Indexed when it finished, then streaming again: its row stays.
      await repository.upsertMessage(_text('sibling', 1, 'Ryokan done'));
      await repository.upsertMessage(
        _message('sibling', 1, const [
          GaiaTextPart('Ryokan done, and more'),
        ], status: GaiaMessageStatus.streaming),
      );
      final text = await reads.tool('here', 'project_search', const {
        'query': 'ryokan',
        'limit': 1,
      });
      expect(text, contains('seq 0'));
      expect(text, isNot(contains('seq 1')));
    });

    test('project_read refuses a chat outside the project', () async {
      for (final id in ['other', 'loose', 'nowhere']) {
        expect(
          () => reads.tool('here', 'project_read', {'chatId': id}),
          throwsA(isA<GaiaReadException>()),
        );
      }
    });

    test('project_read leaves out what a rewind dropped and deleted '
        'messages, and says a reply is still going', () async {
      await repository.upsertChat(
        _chat(
          'sibling',
          projectId: 'p1',
          rewinds: const [
            GaiaRewind(from: 1, to: 2, forkId: 'f', by: 'laptop'),
          ],
        ),
      );
      await repository.upsertMessage(_text('sibling', 1, 'Dropped reply'));
      await repository.upsertMessage(_text('sibling', 2, 'Dropped prompt'));
      await repository.upsertMessage(
        _text('sibling', 3, 'Deleted').copyWith(deletedAt: _at),
      );
      await repository.upsertMessage(
        _message('sibling', 5, const [
          GaiaTextPart('Thinking'),
        ], status: GaiaMessageStatus.streaming),
      );
      final text = await reads.tool('here', 'project_read', const {
        'chatId': 'sibling',
      });
      expect(text, startsWith('<project_chat id="sibling" title="Title sib'));
      expect(text, contains('[seq 0] User:'));
      expect(text, isNot(contains('Dropped')));
      expect(text, isNot(contains('Deleted')));
      expect(text, contains('[seq 5] Gaia:\nThinking\n(still replying)'));
    });
  });

  test('a message reads as the user sees it: tools by name, a card in a '
      'line, quotes and files', () {
    final text = gaiaProjectMessageText(
      _message('c', 1, [
        const GaiaActivityPart(['Bash', 'project_search'], details: ['rm -rf']),
        const GaiaTextPart('Done. See [image 1].'),
        const GaiaQuotePart(role: GaiaMessageRole.user, text: 'Earlier ask'),
        const GaiaFilePart(path: r'C:\Notes', folder: true),
        GaiaCardPart(
          id: 'k',
          kind: GaiaCardKind.proposal,
          state: GaiaCardState.accepted,
          tool: 'propose_todo',
          proposal: const GaiaProposal(
            entity: GaiaProposalEntity.todo,
            fields: {'title': 'Book ryokan'},
          ),
        ),
      ]),
    );
    expect(
      text,
      '[seq 1] Gaia:\n'
      '(Tools: Bash, project_search)\n'
      'Done. See [image 1].\n'
      '(Quoted (User): Earlier ask)\n'
      r'(Attached: C:\Notes (folder))'
      '\n'
      "(Proposal: todo 'Book ryokan', accepted)",
    );
    expect(text, isNot(contains('rm -rf')));
  });

  group('the range and the cap (§5.3)', () {
    final chat = _chat('c', projectId: 'p1');
    final messages = [
      for (var seq = 0; seq < 40; seq++) _text('c', seq, 'm$seq'),
    ];

    test('no range is the last 30; a range is from and to', () {
      final last = gaiaProjectReadText(chat, messages);
      expect(last, isNot(contains('[seq 9]')));
      expect(last, contains('[seq 10]'));
      expect(last, contains('[seq 39]'));
      final some = gaiaProjectReadText(chat, messages, from: 3, to: 5);
      expect(RegExp(r'\[seq').allMatches(some), hasLength(3));
      expect(some, isNot(contains('Cut short')));
    });

    test('a long range is cut at a message, with the seq to go on from', () {
      final long = [
        for (var seq = 0; seq < 5; seq++) _text('c', seq, 'x' * 10000),
      ];
      final text = gaiaProjectReadText(chat, long, from: 0);
      expect(text, contains('[seq 1]'));
      expect(text, isNot(contains('[seq 2]')));
      expect(text, contains('Cut short: read on with from=2.'));
    });
  });

  group('the block (§5.2)', () {
    final trip = GaiaProject(
      id: 'p1',
      name: 'Trip "Japan"',
      createdAt: _at,
      updatedAt: _at,
    );

    String? block({
      String? told,
      String? toldFolder,
      GaiaProject? project,
      String? folder,
      int chats = 7,
    }) => gaiaProjectPreamble(
      told: told,
      toldFolder: toldFolder,
      project: project,
      folder: folder,
      chats: chats,
    );

    test('told once, after a change, and of a removal', () {
      expect(
        block(project: trip),
        startsWith('<gaia_project name="Trip &quot;Japan&quot;" chats="7">'),
      );
      expect(block(told: 'p1', project: trip), isNull);
      expect(block(told: 'p0', project: trip), isNotNull);
      expect(block(told: 'p1', chats: 0), '<gaia_project removed/>');
      expect(block(chats: 0), isNull);
    });

    test('its folder (§4): here, elsewhere, or none', () {
      final foldered = trip.copyWith(
        folders: {'desk': 'D:/Notes/Japan', 'laptop': 'C:/Japan'},
      );
      expect(gaiaProjectFolder(trip, 'desk'), isNull);
      expect(gaiaProjectFolder(foldered, 'desk'), 'D:/Notes/Japan');
      expect(gaiaProjectFolder(foldered, 'phone'), 'not on this device');
      expect(gaiaProjectFolder(null, 'desk'), isNull);

      final here = block(project: foldered, folder: 'D:/Notes/Japan')!;
      expect(here, contains('chats="7" folder="D:/Notes/Japan">'));
      expect(here, contains("The project's folder is D:/Notes/Japan."));
      final away = block(project: foldered, folder: 'not on this device')!;
      expect(away, contains('folder="not on this device">'));
      expect(away, contains('but not on this one'));
      expect(block(project: trip), isNot(contains('folder')));
    });

    test('told again when its folder here changes', () {
      final foldered = trip.copyWith(folders: {'desk': 'D:/Japan'});
      expect(
        block(told: 'p1', project: foldered, folder: 'D:/Japan'),
        isNotNull,
      );
      expect(
        block(
          told: 'p1',
          toldFolder: 'D:/Japan',
          project: foldered,
          folder: 'D:/Japan',
        ),
        isNull,
      );
      expect(
        block(
          told: 'p1',
          toldFolder: 'not on this device',
          project: foldered,
          folder: 'D:/Japan',
        ),
        isNotNull,
      );
    });

    test('a session keeps the project it was told of, and its folder', () {
      const session = GaiaAgentSession(
        sessionId: 's',
        lastSeq: 3,
        project: 'p1',
        folder: 'D:/Japan',
      );
      final back = GaiaAgentSession.fromJson(session.toJson());
      expect(back.project, 'p1');
      expect(back.folder, 'D:/Japan');
      final bare = GaiaAgentSession.fromJson(const {'sessionId': 's'});
      expect(bare.project, isNull);
      expect(bare.folder, isNull);
    });
  });

  group('summaries (§5.5)', () {
    test('a stored summary is only replaced by one covering more', () async {
      final db = AppDatabase.inMemory();
      addTearDown(db.close);
      final repository = DriftGaiaRepository(db);
      final store = GaiaChatStore(repository, deviceId: 'laptop');
      await repository.upsertChat(_chat('c', projectId: 'p1'));
      await store.setSummary('c', 'Newer', 5);
      await store.setSummary('c', 'Older', 3);
      final chat = (await repository.getChat('c'))!;
      expect(chat.summary, 'Newer');
      expect(chat.summarizedSeq, 5);
    });

    test('sync keeps the summary covering more of the chat', () {
      final local = _chat(
        'c',
      ).copyWith(summary: 'Local', summarizedSeq: 6, version: 1);
      final stale = {
        ...gaiaChatToFirestore(
          local.copyWith(summary: 'Stale', summarizedSeq: 2, version: 5),
        ),
      };
      final merged = mergeGaiaChatFromRemote(stale, 'c', local: local);
      expect(merged.summary, 'Local');
      expect(merged.summarizedSeq, 6);
      final newer = gaiaChatToFirestore(
        local.copyWith(summary: 'Remote', summarizedSeq: 9, version: 5),
      );
      expect(
        mergeGaiaChatFromRemote(newer, 'c', local: local).summary,
        'Remote',
      );
    });
  });

  group('shown as tool calls (§5.4)', () {
    test(
      "each project read's result is kept on the device that ran it",
      () async {
        final tools = _Keeping();
        for (final name in [
          'project_chats',
          'project_search',
          'project_read',
        ]) {
          await gaiaMcpAnswer(
            {
              'jsonrpc': '2.0',
              'id': 1,
              'method': 'tools/call',
              'params': {'name': name, 'arguments': <String, Object?>{}},
            },
            tools,
            callId: 'call-$name',
          );
        }
        expect(tools.kept, [
          'call-project_chats',
          'call-project_search',
          'call-project_read',
        ]);
      },
    );

    test('they are listed for every chat', () {
      final names = {for (final tool in kGaiaToolDefinitions) tool['name']};
      expect(
        names,
        containsAll(['project_chats', 'project_search', 'project_read']),
      );
    });
  });
}

class _Keeping implements GaiaTurnTools, GaiaResultKeeper {
  final kept = <String>[];

  @override
  Future<GaiaToolResult> call(
    String name,
    Map<String, Object?> arguments,
  ) async => const GaiaToolResult(text: 'read', isError: false);

  @override
  Future<GaiaPermission> permit({
    required String tool,
    required Map<String, Object?> input,
    required String description,
  }) async => (allow: true, message: '');

  @override
  void keep(String callId, String name, GaiaToolResult result) =>
      kept.add(callId);
}
