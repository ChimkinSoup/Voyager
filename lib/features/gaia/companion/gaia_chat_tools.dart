import 'dart:async';
import 'dart:convert';

import 'package:uuid/uuid.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/tools/gaia_mcp.dart';
import 'package:voyager/features/gaia/tools/gaia_proposals.dart';

const _uuid = Uuid();

/// How a card was decided, and what the user said.
typedef GaiaCardAnswer = ({GaiaCardState state, Map<String, Object?>? answer});

/// The cards whose tool calls are waiting on the user (GAIA_HLD.md §10),
/// across every chat: a turn's tools [wait], the composer or a card's
/// buttons [decide], and Abort or Stop [voidAll]s.
class GaiaCards {
  final _waiting =
      <String, ({String chatId, Completer<GaiaCardAnswer> done})>{};

  /// Whether a tool call is still waiting on card [id]. A question card
  /// left open after its wait ran out isn't: its answer goes as the next
  /// message instead.
  bool isWaiting(String id) => _waiting.containsKey(id);

  /// The chats with a card waiting, oldest card first.
  List<String> get waitingChats => [
    for (final waiting in _waiting.values) waiting.chatId,
  ];

  /// Holds until [card] is decided, voided or [hold] runs out: null then.
  Future<GaiaCardAnswer?> wait(
    String chatId,
    GaiaCardPart card,
    Duration hold,
  ) {
    final done = Completer<GaiaCardAnswer>();
    _waiting[card.id] = (chatId: chatId, done: done);
    return done.future
        .then<GaiaCardAnswer?>((answer) => answer)
        .timeout(hold, onTimeout: () => null)
        .whenComplete(() {
          if (_waiting[card.id]?.done == done) _waiting.remove(card.id);
        });
  }

  /// Ends card [id]'s wait with [state] and [answer]; false when nothing
  /// waits.
  bool decide(String id, GaiaCardState state, [Map<String, Object?>? answer]) {
    final waiting = _waiting.remove(id);
    if (waiting == null) return false;
    waiting.done.complete((state: state, answer: answer));
    return true;
  }

  /// Voids every waiting card, or [chatId]'s.
  void voidAll({String? chatId}) {
    for (final MapEntry(key: id, value: waiting) in [..._waiting.entries]) {
      if (chatId != null && waiting.chatId != chatId) continue;
      _waiting.remove(id);
      waiting.done.complete((state: GaiaCardState.voided, answer: null));
    }
  }
}

/// The main instance's side of a proposal (§10): [prepare] fills a
/// `propose_*` call in as card `cardId`'s proposal, [commit] writes it with
/// the user's fields once they accepted it, and [drop] forgets one that
/// won't be. Each throws a [GaiaToolException] the agent is shown.
typedef GaiaProposalHost = ({
  Future<GaiaProposal> Function(
    String cardId,
    String tool,
    Map<String, Object?> arguments,
  )
  prepare,
  Future<({Map<String, Object?> record, String text})> Function(
    String cardId,
    String token,
    Map<String, Object?> fields,
  )
  commit,
  void Function(String cardId) drop,
});

/// The main instance's side of a step list (§15.6): [plan] resolves an `os_*`
/// action call into card `cardId`'s `{window, app, steps}`, [run] sends its
/// next step, or with `once` all that are left, and gives `{ran, stopped?,
/// steps}`, and [drop] forgets one that won't run. [plan] and [run] throw a
/// [GaiaToolException] the agent is shown.
typedef GaiaControlHost = ({
  Future<Map<String, Object?>> Function(
    String cardId,
    String tool,
    Map<String, Object?> arguments,
  )
  plan,
  Future<Map<String, Object?>> Function(String cardId, {required bool once})
  run,
  void Function(String cardId) drop,
});

/// One turn's Gaia tools (§5.3), bound to its chat: `ask_user`, the CLI's
/// permission prompts, the `propose_*` tools and the `os_*` actions raise cards
/// in the reply through [onCard] and wait in [cards]; the `voyager_*` reads,
/// the `memory_*` tools (§11) and the `project_*` reads (GAIA_PROJECTS_HLD.md
/// §5.1) go to the main instance through [read], the
/// `os_*` reads through [screen], proposals through [proposals], and step lists
/// through [control]. While [aborted], every tool refuses (§15.7).
///
/// In Auto (GAIA_AUTONOMY_HLD.md §4), which [isAuto] asks the main instance at
/// each call, actions and the CLI's prompts raise no card: what ran goes in one
/// activity card for the turn (§7), through [onActivity].
class GaiaChatTools implements GaiaTurnTools, GaiaResultKeeper {
  GaiaChatTools({
    required this.chatId,
    required this.cards,
    required this.onCard,
    required this.read,
    required this.screen,
    required this.proposals,
    required this.control,
    required this.aborted,
    this.isAuto,
    this.onActivity,
    this.resume,
    this.onResult,
    this.hold = kGaiaCardHold,
  });

  final String chatId;
  final GaiaCards cards;
  final void Function(GaiaCardPart card) onCard;

  /// A kept-result tool answered call `callId` (§15.6).
  final void Function(String callId, GaiaToolResult result)? onResult;

  @override
  void keep(String callId, String name, GaiaToolResult result) =>
      onResult?.call(callId, result);

  /// Whether the chat is in Auto now; never, for null.
  final Future<bool> Function()? isAuto;

  /// The turn's activity card changed. It can change many times a second, so
  /// it needn't be saved each time (§7); [onCard] takes it for null.
  final void Function(GaiaCardPart card)? onActivity;

  /// The user answered a question: an Auto run waiting while Gaia is in front
  /// goes on (§5.2).
  final void Function()? resume;
  final Future<String> Function(String tool, Map<String, Object?> arguments)
  read;

  /// An `os_*` read (§15.6), which the main instance answers and refuses.
  final Future<GaiaToolResult> Function(
    String tool,
    Map<String, Object?> arguments,
  )
  screen;
  final GaiaProposalHost proposals;
  final GaiaControlHost control;
  final bool Function() aborted;
  final Duration hold;

  static const _aborted = GaiaToolResult(
    text: 'aborted: Gaia is aborted.',
    isError: true,
  );

  /// The turn's activity card (§7): its id once anything ran, what ran, newest
  /// last and at most [_maxActivity], and how much in all.
  String? _activityId;
  final _activity = <String>[];
  var _activityTotal = 0;
  String? _activityWindow;
  String? _activityApp;
  static const _maxActivity = 200;

  /// Actions that failed before any card came up, which the card lists first
  /// once it does: their chips leave them out then.
  final _failedBefore = <String>[];

  /// An action that failed before it ran: on the card, the only place a reply
  /// with one lists its actions (§7).
  void _logFailed(String tool, Object error) {
    final label = 'Failed: $tool: $error';
    if (_activityId == null) {
      _failedBefore.add(label);
    } else {
      _logActivity([label]);
    }
  }

  void _logActivity(Iterable<String> labels, {String? window, String? app}) {
    labels = [..._failedBefore, ...labels];
    _failedBefore.clear();
    for (var label in labels) {
      // The stop can come from the session and from the step it ended:
      // one row, after whatever ran. The step's may say more, as a drag's
      // does, so it's the same stop when one starts with the other, and
      // the fuller one is kept (BUG-370).
      if (label.startsWith('Stopped: ')) {
        final same = _activity.lastIndexWhere(
          (row) =>
              row.startsWith('Stopped: ') &&
              (row.startsWith(label) || label.startsWith(row)),
        );
        if (same >= 0) {
          final row = _activity.removeAt(same);
          _activityTotal--;
          if (row.length > label.length) label = row;
        }
      }
      _activity.add(label);
      _activityTotal++;
    }
    if (_activity.length > _maxActivity) {
      _activity.removeRange(0, _activity.length - _maxActivity);
    }
    _activityWindow = window ?? _activityWindow;
    _activityApp = app ?? _activityApp;
    final card = GaiaCardPart(
      id: _activityId ??= _uuid.v4(),
      kind: GaiaCardKind.control,
      state: GaiaCardState.accepted,
      tool: 'activity',
      input: {
        'activity': true,
        'window': ?_activityWindow,
        'app': ?_activityApp,
        'total': _activityTotal,
        'steps': [
          for (final label in _activity) {'label': label, 'resolved': true},
        ],
      },
      // As a step list that ran in full, for the action log and older builds.
      answer: {
        'ran': _activity.length,
        'committed': {'steps': _activityTotal},
      },
    );
    (onActivity ?? onCard)(card);
  }

  /// A stop that came from the session, which may land between calls, with
  /// no step to report it (BUG-357).
  void logStopped(String why) => _logActivity(['Stopped: $why']);

  /// How long the screen gets to settle before `read_after` reads it.
  static const _readSettle = Duration(milliseconds: 300);

  @override
  Future<GaiaToolResult> call(
    String name,
    Map<String, Object?> arguments,
  ) async {
    if (aborted()) return _aborted;
    if (name == 'ask_user') return _ask(arguments);
    if (kGaiaProposalTools.containsKey(name)) return _propose(name, arguments);
    if (isGaiaOsControl(name, arguments)) return _control(name, arguments);
    if (isGaiaOsRead(name, arguments)) {
      try {
        return await screen(name, arguments);
      } catch (error) {
        return GaiaToolResult(text: '$error', isError: true);
      }
    }
    if (isGaiaVoyagerRead(name) ||
        isGaiaMemoryTool(name) ||
        isGaiaProjectTool(name)) {
      try {
        return GaiaToolResult(
          text: await read(name, arguments),
          isError: false,
        );
      } catch (error) {
        return GaiaToolResult(text: '$error', isError: true);
      }
    }
    return GaiaToolResult(text: 'Unknown tool: $name', isError: true);
  }

  Future<GaiaToolResult> _ask(Map<String, Object?> arguments) async {
    final question = arguments['question'];
    if (question is! String || question.trim().isEmpty) {
      return GaiaToolResult(text: 'ask_user needs a question.', isError: true);
    }
    final options = <GaiaCardOption>[
      if (arguments['options'] case final List list)
        for (final option in list)
          if (option case {
            'label': final String label,
          } when label.trim().isNotEmpty)
            (
              label: label.trim(),
              description: switch (option['description']) {
                final String description => description.trim(),
                _ => '',
              },
            ),
    ];
    if (options.length > 9) {
      return GaiaToolResult(
        text: 'ask_user takes at most 9 options.',
        isError: true,
      );
    }
    final recommended = options.indexWhere(
      (option) => option.label == arguments['recommended'],
    );
    final card = GaiaCardPart(
      id: _uuid.v4(),
      kind: GaiaCardKind.question,
      question: question.trim(),
      options: options,
      multiSelect: arguments['multi_select'] == true && options.length > 1,
      recommended: recommended < 0 ? null : recommended,
    );
    onCard(card);
    final answer = await cards.wait(chatId, card, hold);
    if (answer == null) {
      // Left open: answered later, it goes as the next message.
      return GaiaToolResult(
        text:
            "pending:${card.id} The user hasn't answered yet. End your turn "
            'now without guessing; their answer will come as their next '
            'message.',
        isError: false,
      );
    }
    final decided = card.decided(answer.state, answer.answer);
    onCard(decided);
    if (decided.state != GaiaCardState.voided) resume?.call();
    return switch (decided.state) {
      GaiaCardState.accepted => GaiaToolResult(
        text: gaiaQuestionAnswerText(decided.answer),
        isError: false,
      ),
      GaiaCardState.rejected => GaiaToolResult(
        text: 'The user dismissed the question without answering.',
        isError: false,
      ),
      _ => _aborted,
    };
  }

  /// A `propose_*` call (§10): the main instance fills it in, the card holds
  /// it in an editor until the user decides, and accepted, the main
  /// instance commits what the editor holds with the token the acceptance
  /// issued. The agent is told what was written, or the user's correction.
  Future<GaiaToolResult> _propose(
    String tool,
    Map<String, Object?> arguments,
  ) async {
    final id = _uuid.v4();
    final GaiaProposal proposal;
    try {
      proposal = await proposals.prepare(id, tool, arguments);
    } catch (error) {
      return GaiaToolResult(text: '$error', isError: true);
    }
    final card = GaiaCardPart(
      id: id,
      kind: GaiaCardKind.proposal,
      tool: tool,
      proposal: proposal,
    );
    onCard(card);
    final answer = await cards.wait(chatId, card, hold);
    if (answer == null) {
      proposals.drop(id);
      onCard(card.decided(GaiaCardState.expired));
      return GaiaToolResult(
        text:
            "The user didn't answer within an hour, so nothing was written. "
            'End your turn; they can ask again.',
        isError: false,
      );
    }
    switch (answer.state) {
      case GaiaCardState.accepted:
        final fields = (answer.answer!['fields']! as Map)
            .cast<String, Object?>();
        final token = answer.answer!['token']! as String;
        try {
          final committed = await proposals.commit(id, token, fields);
          onCard(
            card.decided(GaiaCardState.accepted, {
              'fields': fields,
              'token': token,
              'committed': committed.record,
            }),
          );
          return GaiaToolResult(text: committed.text, isError: false);
        } catch (error) {
          onCard(card.decided(GaiaCardState.voided, {'error': '$error'}));
          return GaiaToolResult(
            text: 'The user accepted, but it could not be saved: $error',
            isError: true,
          );
        }
      case GaiaCardState.rejected:
        proposals.drop(id);
        final decided = card.decided(answer.state, answer.answer);
        onCard(decided);
        return GaiaToolResult(
          text: switch (decided.answer?['message']) {
            final String message when message.trim().isNotEmpty =>
              'rejected: the user wants changes: ${message.trim()}\n'
                  'Nothing was written. Propose again with their changes.',
            _ => 'The user turned it down; nothing was written.',
          },
          isError: false,
        );
      default:
        proposals.drop(id);
        onCard(card.decided(answer.state));
        return _aborted;
    }
  }

  /// An `os_*` action (§15.6): the main instance resolves it into steps, the
  /// card holds them until the user approves all at once or the next one, and
  /// the main instance sends them. The agent is told how far it got.
  Future<GaiaToolResult> _control(
    String tool,
    Map<String, Object?> arguments,
  ) async {
    final id = _uuid.v4();
    Map<String, Object?> plan;
    try {
      plan = await control.plan(id, tool, arguments);
    } catch (error) {
      _logFailed(tool, error);
      return GaiaToolResult(text: '$error', isError: true);
    }
    // In Auto the main instance runs it with no card (GAIA_AUTONOMY_HLD.md §5).
    final auto = plan['auto'] == true;
    plan = {...plan}..remove('auto');
    if (auto) {
      return _withRead(
        await _autoControl(id, plan, inWindow: tool != 'os_clipboard'),
        arguments,
      );
    }
    final total = (plan['steps']! as List).length;
    final stepWord = total == 1 ? 'step' : 'steps';
    GaiaCardPart cardWith(
      GaiaCardState state, {
      required int ran,
      String? stopped,
      String? message,
    }) => GaiaCardPart(
      id: id,
      kind: GaiaCardKind.control,
      state: state,
      tool: tool,
      input: plan,
      answer: {
        'ran': ran,
        'stopped': ?stopped,
        'message': ?message,
        if (ran > 0) 'committed': {'steps': ran},
      },
    );
    var ran = 0;
    var once = false;
    String? adopted;
    String? stopped;
    final how = <String>[];
    while (ran < total) {
      if (!once) {
        final open = cardWith(GaiaCardState.open, ran: ran);
        onCard(open);
        final answer = await cards.wait(chatId, open, hold);
        if (answer == null) {
          control.drop(id);
          onCard(cardWith(GaiaCardState.expired, ran: ran));
          return GaiaToolResult(
            text:
                "The user didn't answer within an hour. Ran $ran of $total "
                '$stepWord. End your turn; they can ask again.',
            isError: false,
          );
        }
        if (answer.state != GaiaCardState.accepted) {
          control.drop(id);
          final message = (answer.answer?['message'] as String? ?? '').trim();
          onCard(
            cardWith(
              answer.state,
              ran: ran,
              message: message.isEmpty ? null : message,
            ),
          );
          if (answer.state != GaiaCardState.rejected) return _aborted;
          return GaiaToolResult(
            text: [
              'The user declined. Ran $ran of $total $stepWord.',
              if (message.isNotEmpty) 'They said: $message',
            ].join(' '),
            isError: false,
          );
        }
        once = answer.answer?['once'] == true;
      }
      try {
        final result = await control.run(id, once: once);
        ran = (result['ran']! as num).toInt();
        plan = {...plan, 'steps': result['steps']};
        adopted = _windowNote(result) ?? adopted;
        how.addAll([for (final note in result['how'] as List? ?? []) '$note']);
        stopped = result['stopped'] as String?;
      } catch (error) {
        control.drop(id);
        onCard(cardWith(GaiaCardState.voided, ran: ran, stopped: '$error'));
        return GaiaToolResult(text: '$error', isError: true);
      }
      if (stopped != null) break;
    }
    onCard(cardWith(GaiaCardState.accepted, ran: ran, stopped: stopped));
    final notes = '${adopted ?? ''}${_howNote(how)}';
    return _withRead(
      stopped == null
          ? _sentResult(total, notes)
          : _stoppedResult(ran, total, stopped, notes),
      arguments,
    );
  }

  /// An Auto action (§5): run at once, and logged on the turn's activity card,
  /// which names the window it was in, unless it was in none ([inWindow]).
  Future<GaiaToolResult> _autoControl(
    String id,
    Map<String, Object?> plan, {
    required bool inWindow,
  }) async {
    final total = (plan['steps']! as List).length;
    List<String> labels(Object? steps, int ran) => [
      for (final step in (steps as List? ?? const []).take(ran))
        '${(step as Map)['label'] ?? ''}',
    ];
    final Map<String, Object?> result;
    try {
      result = await control.run(id, once: true);
    } catch (error) {
      control.drop(id);
      _logActivity(['Stopped: $error']);
      return GaiaToolResult(text: '$error', isError: true);
    }
    final ran = (result['ran']! as num).toInt();
    final adopted =
        '${_windowNote(result) ?? ''}'
        '${_howNote([for (final note in result['how'] as List? ?? []) '$note'])}';
    final stopped = result['stopped'] as String?;
    _logActivity(
      [
        ...labels(result['steps'], ran),
        if (stopped != null) 'Stopped: $stopped',
      ],
      window:
          result['front'] as String? ??
          result['adopted'] as String? ??
          (inWindow ? plan['window'] as String? : null),
      app: inWindow ? plan['app'] as String? : null,
    );
    return stopped == null
        ? _sentResult(total, adopted)
        : _stoppedResult(ran, total, stopped, adopted);
  }

  /// What the agent is told of the window a run left in front: the one
  /// `os_open` or `os_focus` brought up, or one that opened by itself.
  static String? _windowNote(Map<String, Object?> result) =>
      switch ((result['front'], result['adopted'], result['unconfirmed'])) {
        (final String window, _, final String opened) =>
          " Gaia couldn't confirm that $window is what $opened opened, but "
              'it came in front, and later calls act on it. Check it is the '
              'right one.',
        (final String window, _, _) =>
          ' $window is in front, and later calls act on it.',
        (_, final String window, _) =>
          ' A window opened, maybe behind others, and later calls act on it: '
              '$window.',
        _ => null,
      };

  /// How the steps ran, where Gaia didn't simply send input (§13.7).
  static String _howNote(List<String> how) =>
      how.isEmpty ? '' : ' How it ran: ${how.join('; ')}.';

  static GaiaToolResult _sentResult(int total, String? adopted) =>
      GaiaToolResult(
        text:
            '${total == 1 ? 'Sent the step' : 'Sent all $total steps'}. That '
            'says the input went, not that it worked: read the screen to see.'
            '${adopted ?? ''}',
        isError: false,
      );

  static GaiaToolResult _stoppedResult(
    int ran,
    int total,
    String stopped,
    String? adopted,
  ) => GaiaToolResult(
    text:
        'Stopped after $ran of $total ${total == 1 ? 'step' : 'steps'}: '
        '$stopped Nothing more was sent. Read the screen before assuming '
        "anything, and if the user stopped it, don't start again unless they "
        'ask.${adopted ?? ''}',
    isError: false,
  );

  /// With `read_after` (§5.6), [result] and the screen as it is now, read
  /// as `os_read_screen` reads it, so acting and looking take one call.
  Future<GaiaToolResult> _withRead(
    GaiaToolResult result,
    Map<String, Object?> arguments,
  ) async {
    if (arguments['read_after'] != true) return result;
    await Future<void>.delayed(_readSettle);
    try {
      final read = await screen('os_read_screen', const {});
      return GaiaToolResult(
        text: '${result.text}\n\nThe screen now:\n${read.text}',
        isError: result.isError,
      );
    } catch (error) {
      return GaiaToolResult(
        text: '${result.text}\n\nThe screen could not be read: $error',
        isError: result.isError,
      );
    }
  }

  @override
  Future<GaiaPermission> permit({
    required String tool,
    required Map<String, Object?> input,
    required String description,
  }) async {
    if (aborted()) return (allow: false, message: 'Gaia is aborted.');
    // Gaia's own tools ask for themselves where they need to: a proposal
    // is its own card. A CLI asking about one, outside Auto mode, gets no
    // second card in front of it.
    if (tool.startsWith('mcp__${kGaiaMcpServer}__')) {
      return (allow: true, message: '');
    }
    // Read now, so a chat taken out of Auto mid-turn asks again (§5.7). The
    // activity card still shows what ran.
    if (await isAuto?.call() ?? false) {
      if (aborted()) return (allow: false, message: 'Gaia is aborted.');
      _logActivity(['Allowed ${_permitted(tool, input)}']);
      return (allow: true, message: '');
    }
    final card = GaiaCardPart(
      id: _uuid.v4(),
      kind: GaiaCardKind.permission,
      tool: tool,
      input: gaiaTrimmedInput(input),
      description: description,
    );
    onCard(card);
    final answer = await cards.wait(chatId, card, hold);
    if (answer == null) {
      onCard(card.decided(GaiaCardState.expired));
      return (allow: false, message: "The user didn't answer within an hour.");
    }
    final decided = card.decided(answer.state, answer.answer);
    onCard(decided);
    return switch (decided.state) {
      GaiaCardState.accepted => (allow: true, message: ''),
      GaiaCardState.rejected => (
        allow: false,
        message: switch (decided.answer?['message']) {
          final String message when message.trim().isNotEmpty =>
            'The user declined: ${message.trim()}',
          _ => 'The user declined.',
        },
      ),
      _ => (allow: false, message: 'Gaia is aborted.'),
    };
  }
}

/// What the agent is told of a question card's [answer]: the options picked
/// and anything typed.
String gaiaQuestionAnswerText(Map<String, Object?>? answer) {
  final selected = (answer?['selected'] as List?)?.cast<String>() ?? const [];
  final text = (answer?['text'] as String? ?? '').trim();
  return [
    if (selected.isNotEmpty)
      'The user chose: ${selected.map((label) => '"$label"').join(', ')}.',
    if (text.isNotEmpty) 'The user wrote: $text',
    if (selected.isEmpty && text.isEmpty) 'The user answered without words.',
  ].join('\n');
}

/// A CLI prompt allowed in Auto, as its activity row says it: the command,
/// path or URL where there is one.
String _permitted(String tool, Map<String, Object?> input) {
  for (final key in ['command', 'file_path', 'notebook_path', 'url', 'path']) {
    if (input[key] case final String value when value.isNotEmpty) {
      final line = value.replaceAll(RegExp(r'\s+'), ' ');
      return '$tool: ${line.length > 200 ? '${line.substring(0, 200)}…' : line}';
    }
  }
  return tool;
}

/// A permission card keeps the call it asks about, shortened: a file write's
/// content can run to megabytes, and the card is synced.
Map<String, Object?> gaiaTrimmedInput(Map<String, Object?> input) => {
  for (final MapEntry(:key, :value) in input.entries)
    key: switch (value) {
      final String text => _short(text),
      final num number => number,
      final bool flag => flag,
      null => null,
      _ => _short(jsonEncode(value)),
    },
};

const _maxInputText = 2000;

String _short(String text) =>
    text.length > _maxInputText ? '${text.substring(0, _maxInputText)}…' : text;
