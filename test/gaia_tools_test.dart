import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/adapters/gaia_agent_runner.dart';
import 'package:voyager/features/gaia/companion/gaia_chat_tools.dart';
import 'package:voyager/features/gaia/tools/gaia_mcp.dart';
import 'package:voyager/features/gaia/tools/gaia_proposals.dart';

/// Gaia's tools (GAIA_HLD.md §5.3, §10.1): the MCP server both transports
/// hand messages to, and a turn's tools, whose cards wait on the user.

class _Tools implements GaiaTurnTools {
  final calls = <(String, Map<String, Object?>)>[];

  @override
  Future<GaiaToolResult> call(String name, Map<String, Object?> arguments) {
    calls.add((name, arguments));
    return Future.value((text: 'did $name', isError: false));
  }

  @override
  Future<GaiaPermission> permit({
    required String tool,
    required Map<String, Object?> input,
    required String description,
  }) async => (allow: true, message: '');
}

void main() {
  group('the MCP server', () {
    test('answers the handshake with the client\'s protocol version', () async {
      final answer = await gaiaMcpAnswer({
        'jsonrpc': '2.0',
        'id': 0,
        'method': 'initialize',
        'params': {'protocolVersion': '2025-11-25'},
      }, null);
      expect(answer, {
        'jsonrpc': '2.0',
        'id': 0,
        'result': {
          'protocolVersion': '2025-11-25',
          'capabilities': {'tools': <String, Object?>{}},
          'serverInfo': {'name': 'gaia', 'version': '1'},
        },
      });
    });

    test('lists every tool, with names the Messages API allows', () async {
      final answer = await gaiaMcpAnswer({
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'tools/list',
      }, null);
      final tools = ((answer!['result']! as Map)['tools']! as List)
          .cast<Map<String, Object?>>();
      expect(tools.map((tool) => tool['name']), [
        'ask_user',
        'voyager_todos',
        'voyager_calendar',
        'voyager_journal',
        'voyager_workouts',
        'propose_todo',
        'propose_calendar_event',
        'propose_journal_entry',
        'memory_search',
        'memory_propose',
      ]);
      for (final tool in tools) {
        expect(tool['name'], matches(RegExp(r'^[a-zA-Z0-9_-]{1,64}$')));
        expect(tool['inputSchema'], isA<Map<String, Object?>>());
      }
    });

    test('a call goes to the turn\'s tools', () async {
      final tools = _Tools();
      final answer = await gaiaMcpAnswer({
        'jsonrpc': '2.0',
        'id': 2,
        'method': 'tools/call',
        'params': {
          'name': 'voyager_todos',
          'arguments': {'list': 'Inbox'},
        },
      }, tools);
      expect(tools.calls.single.$1, 'voyager_todos');
      expect(tools.calls.single.$2, {'list': 'Inbox'});
      expect(answer!['result'], {
        'content': [
          {'type': 'text', 'text': 'did voyager_todos'},
        ],
        'isError': false,
      });
    });

    test('a call outside a turn, or to no such tool, fails as a result', () async {
      Future<Map<String, Object?>> call(String name, GaiaTurnTools? tools) async =>
          (await gaiaMcpAnswer({
                    'jsonrpc': '2.0',
                    'id': 3,
                    'method': 'tools/call',
                    'params': {'name': name},
                  }, tools))!['result']!
              as Map<String, Object?>;
      expect(await call('ask_user', null), {
        'content': [
          {'type': 'text', 'text': 'No Gaia run is active.'},
        ],
        'isError': true,
      });
      final tools = _Tools();
      expect((await call('rm_rf', tools))['isError'], isTrue);
      expect(tools.calls, isEmpty);
    });

    test('a notification has no answer; an unknown method is an error', () async {
      expect(
        await gaiaMcpAnswer({
          'jsonrpc': '2.0',
          'method': 'notifications/initialized',
        }, null),
        isNull,
      );
      final answer = await gaiaMcpAnswer({
        'jsonrpc': '2.0',
        'id': 4,
        'method': 'resources/list',
      }, null);
      expect((answer!['error']! as Map)['code'], -32601);
    });
  });

  group('a card part', () {
    test('round-trips through JSON, for each kind', () {
      const question = GaiaCardPart(
        id: 'q',
        kind: GaiaCardKind.question,
        question: 'Which?',
        options: [
          (label: 'A', description: 'first'),
          (label: 'B', description: ''),
        ],
        multiSelect: true,
        recommended: 1,
        state: GaiaCardState.accepted,
        answer: {
          'selected': ['B'],
          'text': 'and why',
        },
      );
      const permission = GaiaCardPart(
        id: 'p',
        kind: GaiaCardKind.permission,
        tool: 'Bash',
        input: {'command': 'ls'},
        description: 'List files',
      );
      for (final card in [question, permission]) {
        final again = GaiaPart.fromJson(card.toJson()) as GaiaCardPart;
        expect(again.toJson(), card.toJson());
      }
    });

    test('a new id joins the reply; the same id replaces it in place', () {
      final builder = GaiaTurnBuilder()
        ..apply(const GaiaTextStart())
        ..apply(const GaiaTextDelta('Let me ask.'));
      const card = GaiaCardPart(
        id: 'c',
        kind: GaiaCardKind.question,
        question: 'Q?',
      );
      builder
        ..apply(const GaiaCardUpdate(card))
        ..apply(const GaiaTextStart())
        ..apply(const GaiaTextDelta('Thanks.'))
        ..apply(GaiaCardUpdate(card.decided(GaiaCardState.accepted)));
      expect(builder.finished.map((part) => part.runtimeType), [
        GaiaTextPart,
        GaiaCardPart,
        GaiaTextPart,
      ]);
      expect((builder.finished[1] as GaiaCardPart).state, GaiaCardState.accepted);
    });
  });

  group('a turn\'s tools', () {
    late GaiaCards cards;
    late List<GaiaCardPart> raised;
    late bool aborted;
    late List<String> reads;
    late List<(String, String, Map<String, Object?>)> committed;
    late List<String> dropped;
    late Object? commitError;

    const proposal = GaiaProposal(
      entity: GaiaProposalEntity.todo,
      fields: {
        'list': 'l1',
        'title': 'Call the dentist',
        'notes': '',
        'due': null,
        'starred': false,
        'completed': false,
      },
      choices: [(id: 'l1', name: 'Inbox')],
    );

    final GaiaProposalHost proposals = (
      prepare: (cardId, tool, arguments) async {
        if (arguments['fail'] == true) {
          throw GaiaToolException('No todo list is called "Nope".');
        }
        return proposal;
      },
      commit: (cardId, token, fields) async {
        if (commitError case final error?) throw error;
        committed.add((cardId, token, fields));
        return (
          record: <String, Object?>{'entity': 'todo', 'id': 't9', 'version': 0},
          text: 'Saved a new task (id t9)',
        );
      },
      drop: (cardId) => dropped.add(cardId),
    );

    GaiaChatTools tools({Duration hold = const Duration(hours: 1)}) =>
        GaiaChatTools(
          chatId: 'chat',
          cards: cards,
          onCard: raised.add,
          read: (tool, arguments) async {
            reads.add(tool);
            if (arguments['fail'] == true) throw GaiaToolException('bad range');
            return 'data for $tool';
          },
          proposals: proposals,
          aborted: () => aborted,
          hold: hold,
        );

    setUp(() {
      cards = GaiaCards();
      raised = [];
      aborted = false;
      reads = [];
      committed = [];
      dropped = [];
      commitError = null;
    });

    test('a proposal raises an editor card and commits what the user '
        'accepted, with the token the acceptance issued', () async {
      final result = tools().call('propose_todo', {'title': 'Call'});
      await pumpEventQueue();
      final card = raised.single;
      expect(card.kind, GaiaCardKind.proposal);
      expect(card.tool, 'propose_todo');
      expect(card.proposal!.fields['title'], 'Call the dentist');
      expect(cards.isWaiting(card.id), isTrue);
      final edited = {...proposal.fields, 'title': 'Call the dentist at 2'};
      final token = gaiaApprovalToken();
      cards.decide(card.id, GaiaCardState.accepted, {
        'fields': edited,
        'token': token,
      });
      expect(await result, (text: 'Saved a new task (id t9)', isError: false));
      final (cardId, sentToken, fields) = committed.single;
      expect((cardId, sentToken), (card.id, token));
      expect(fields, edited);
      expect(raised.last.state, GaiaCardState.accepted);
      expect(raised.last.answer!['committed'], containsPair('id', 't9'));
      expect(raised.last.answer!['fields'], edited);
    });

    test('a typed correction turns a proposal down and tells the agent to '
        're-propose', () async {
      final result = tools().call('propose_todo', {});
      await pumpEventQueue();
      final card = raised.single;
      cards.decide(card.id, GaiaCardState.rejected, {'message': 'make it 3'});
      final text = (await result).text;
      expect(text, startsWith('rejected: the user wants changes: make it 3'));
      expect(text, contains('Propose again'));
      expect(committed, isEmpty);
      expect(dropped, [card.id]);
      expect(raised.last.state, GaiaCardState.rejected);
    });

    test('a proposal the main instance refuses raises no card', () async {
      expect(
        await tools().call('propose_todo', {'fail': true}),
        (text: 'No todo list is called "Nope".', isError: true),
      );
      expect(raised, isEmpty);
    });

    test('Abort voids a proposal, and nothing is committed', () async {
      final result = tools().call('propose_todo', {});
      await pumpEventQueue();
      cards.voidAll();
      expect(await result, (text: 'aborted: Gaia is aborted.', isError: true));
      expect(committed, isEmpty);
      expect(dropped, hasLength(1));
      expect(raised.last.state, GaiaCardState.voided);
    });

    test('a commit that fails voids the card with why', () async {
      commitError = GaiaToolException("It's been changed since.");
      final result = tools().call('propose_todo', {});
      await pumpEventQueue();
      cards.decide(raised.single.id, GaiaCardState.accepted, {
        'fields': proposal.fields,
        'token': gaiaApprovalToken(),
      });
      final answer = await result;
      expect(answer.isError, isTrue);
      expect(answer.text, contains("It's been changed since."));
      expect(raised.last.state, GaiaCardState.voided);
      expect(raised.last.answer, {'error': "It's been changed since."});
    });

    test('a proposal left for the hour expires with nothing written', () {
      fakeAsync((async) {
        GaiaToolResult? answer;
        tools(hold: const Duration(minutes: 1))
            .call('propose_todo', {})
            .then((value) => answer = value);
        async.elapse(const Duration(minutes: 2));
        expect(answer!.text, contains('nothing was written'));
        expect(raised.last.state, GaiaCardState.expired);
        expect(dropped, hasLength(1));
      });
    });

    test("the CLI's prompt about one of Gaia's own tools is allowed without "
        'a card', () async {
      expect(
        await tools().permit(
          tool: 'mcp__gaia__propose_todo',
          input: const {},
          description: '',
        ),
        (allow: true, message: ''),
      );
      expect(raised, isEmpty);
    });

    test('ask_user raises a card and returns what the user picked and wrote',
        () async {
      final result = tools().call('ask_user', {
        'question': ' Which colour? ',
        'options': [
          {'label': 'Red', 'description': 'warm'},
          {'label': 'Blue'},
          {'label': '  '},
        ],
        'recommended': 'Blue',
      });
      await pumpEventQueue();
      final card = raised.single;
      expect(card.question, 'Which colour?');
      expect(card.options.map((o) => o.label), ['Red', 'Blue']);
      expect(card.recommended, 1);
      expect(cards.isWaiting(card.id), isTrue);
      expect(
        cards.decide(card.id, GaiaCardState.accepted, {
          'selected': ['Blue'],
          'text': 'navy if you can',
        }),
        isTrue,
      );
      expect(
        await result,
        (
          text: 'The user chose: "Blue".\nThe user wrote: navy if you can',
          isError: false,
        ),
      );
      expect(raised.last.id, card.id);
      expect(raised.last.state, GaiaCardState.accepted);
      expect(raised.last.question, 'Which colour?', reason: 'kept whole');
      expect(cards.isWaiting(card.id), isFalse);
    });

    test('ask_user without a question, or with ten options, is refused', () async {
      expect((await tools().call('ask_user', {})).isError, isTrue);
      final ten = [
        for (var i = 0; i < 10; i++) {'label': 'o$i'},
      ];
      expect(
        (await tools().call('ask_user', {'question': 'Q', 'options': ten}))
            .isError,
        isTrue,
      );
      expect(raised, isEmpty);
    });

    test('a question left unanswered for the hold stays open, and the agent '
        'is told to end its turn', () {
      fakeAsync((async) {
        GaiaToolResult? result;
        tools(
          hold: const Duration(minutes: 5),
        ).call('ask_user', {'question': 'Q?'}).then((r) => result = r);
        async.elapse(const Duration(minutes: 5, seconds: 1));
        final card = raised.single;
        expect(result!.text, startsWith('pending:${card.id}'));
        expect(result!.isError, isFalse);
        expect(raised, hasLength(1), reason: 'the card stays open');
        expect(cards.isWaiting(card.id), isFalse);
      });
    });

    test('Abort voids a waiting question, and the agent hears "aborted"',
        () async {
      final result = tools().call('ask_user', {'question': 'Q?'});
      await pumpEventQueue();
      cards.voidAll();
      expect(await result, (text: 'aborted: Gaia is aborted.', isError: true));
      expect(raised.last.state, GaiaCardState.voided);
      expect(raised.last.question, 'Q?');
    });

    test('voiding one chat leaves another\'s cards waiting', () async {
      final mine = tools().call('ask_user', {'question': 'Mine?'});
      final theirs = GaiaChatTools(
        chatId: 'other',
        cards: cards,
        onCard: raised.add,
        read: (_, _) async => '',
        proposals: proposals,
        aborted: () => false,
      ).call('ask_user', {'question': 'Theirs?'});
      await pumpEventQueue();
      cards.voidAll(chatId: 'chat');
      expect((await mine).isError, isTrue);
      final other = raised.firstWhere((card) => card.question == 'Theirs?');
      expect(cards.isWaiting(other.id), isTrue);
      cards.decide(other.id, GaiaCardState.rejected);
      expect((await theirs).text, contains('dismissed'));
    });

    test('a permission allowed, and one denied with the user\'s reason', () async {
      final allowed = tools().permit(
        tool: 'Bash',
        input: {'command': 'ls'},
        description: 'List files',
      );
      await pumpEventQueue();
      cards.decide(raised.single.id, GaiaCardState.accepted);
      expect(await allowed, (allow: true, message: ''));

      final denied = tools().permit(
        tool: 'Write',
        input: {'file_path': 'C:\\x', 'content': 'x' * 5000},
        description: '',
      );
      await pumpEventQueue();
      final card = raised.lastWhere((c) => c.tool == 'Write');
      expect(
        (card.input['content']! as String).length,
        lessThan(2100),
        reason: 'a synced card keeps a shortened call',
      );
      cards.decide(card.id, GaiaCardState.rejected, {'message': 'not there'});
      expect(
        await denied,
        (allow: false, message: 'The user declined: not there'),
      );
    });

    test('a permission unanswered for the hold expires, denied', () {
      fakeAsync((async) {
        GaiaPermission? result;
        tools(hold: const Duration(minutes: 1))
            .permit(tool: 'Bash', input: const {}, description: '')
            .then((r) => result = r);
        async.elapse(const Duration(minutes: 2));
        expect(result!.allow, isFalse);
        expect(raised.last.state, GaiaCardState.expired);
      });
    });

    test('reads go to the main instance, its errors to the agent', () async {
      expect(
        await tools().call('voyager_calendar', {}),
        (text: 'data for voyager_calendar', isError: false),
      );
      expect(
        await tools().call('voyager_calendar', {'fail': true}),
        (text: 'bad range', isError: true),
      );
    });

    test('while aborted, every tool refuses and no card is raised', () async {
      aborted = true;
      expect((await tools().call('ask_user', {'question': 'Q?'})).isError, isTrue);
      expect((await tools().call('voyager_todos', {})).isError, isTrue);
      expect(
        (await tools().permit(tool: 'Bash', input: const {}, description: ''))
            .allow,
        isFalse,
      );
      expect(raised, isEmpty);
      expect(reads, isEmpty);
    });
  });

  test('a question\'s answer, as the agent is told it', () {
    expect(gaiaQuestionAnswerText({'selected': ['A', 'B'], 'text': ''}),
        'The user chose: "A", "B".');
    expect(gaiaQuestionAnswerText({'selected': <String>[], 'text': ' hi '}),
        'The user wrote: hi');
  });
}
