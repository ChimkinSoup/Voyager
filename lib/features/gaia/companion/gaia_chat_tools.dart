import 'dart:async';
import 'dart:convert';

import 'package:uuid/uuid.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/tools/gaia_mcp.dart';

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

/// One turn's Gaia tools (§5.3), bound to its chat: `ask_user` and the
/// CLI's permission prompts raise cards in the reply through [onCard] and
/// wait in [cards]; the `voyager_*` reads go to the main instance through
/// [read]. While [aborted], every tool refuses (§15.7).
class GaiaChatTools implements GaiaTurnTools {
  GaiaChatTools({
    required this.chatId,
    required this.cards,
    required this.onCard,
    required this.read,
    required this.aborted,
    this.hold = kGaiaCardHold,
  });

  final String chatId;
  final GaiaCards cards;
  final void Function(GaiaCardPart card) onCard;
  final Future<String> Function(String tool, Map<String, Object?> arguments)
  read;
  final bool Function() aborted;
  final Duration hold;

  static const _aborted = (text: 'aborted: Gaia is aborted.', isError: true);

  @override
  Future<GaiaToolResult> call(
    String name,
    Map<String, Object?> arguments,
  ) async {
    if (aborted()) return _aborted;
    if (name == 'ask_user') return _ask(arguments);
    if (isGaiaVoyagerRead(name)) {
      try {
        return (text: await read(name, arguments), isError: false);
      } catch (error) {
        return (text: '$error', isError: true);
      }
    }
    return (text: 'Unknown tool: $name', isError: true);
  }

  Future<GaiaToolResult> _ask(Map<String, Object?> arguments) async {
    final question = arguments['question'];
    if (question is! String || question.trim().isEmpty) {
      return (text: 'ask_user needs a question.', isError: true);
    }
    final options = <GaiaCardOption>[
      if (arguments['options'] case final List list)
        for (final option in list)
          if (option case {'label': final String label}
              when label.trim().isNotEmpty)
            (
              label: label.trim(),
              description: switch (option['description']) {
                final String description => description.trim(),
                _ => '',
              },
            ),
    ];
    if (options.length > 9) {
      return (text: 'ask_user takes at most 9 options.', isError: true);
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
      return (
        text:
            "pending:${card.id} The user hasn't answered yet. End your turn "
            'now without guessing; their answer will come as their next '
            'message.',
        isError: false,
      );
    }
    final decided = card.decided(answer.state, answer.answer);
    onCard(decided);
    return switch (decided.state) {
      GaiaCardState.accepted => (
        text: gaiaQuestionAnswerText(decided.answer),
        isError: false,
      ),
      GaiaCardState.rejected => (
        text: 'The user dismissed the question without answering.',
        isError: false,
      ),
      _ => _aborted,
    };
  }

  @override
  Future<GaiaPermission> permit({
    required String tool,
    required Map<String, Object?> input,
    required String description,
  }) async {
    if (aborted()) return (allow: false, message: 'Gaia is aborted.');
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

String _short(String text) => text.length > _maxInputText
    ? '${text.substring(0, _maxInputText)}…'
    : text;
