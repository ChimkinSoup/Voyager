import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/domain/repositories/repositories.dart';

/// One committed proposal in the action log (§17): [card], accepted, in
/// [message] of [chat].
typedef GaiaAction = ({GaiaChat chat, GaiaMessage message, GaiaCardPart card});

/// Whether a control card's step list ended with steps not sent, however it
/// ended: a run that stopped, or the rest declined, cancelled or unanswered. One
/// still open hasn't ended: its next step is waiting for its approval.
bool gaiaControlStopped(GaiaCardPart card) =>
    card.state != GaiaCardState.open &&
    (card.answer?['stopped'] != null ||
        ((card.answer?['ran'] as num?)?.toInt() ?? 0) <
            (card.input['steps'] as List? ?? const []).length);

/// The action log (§10, §15.6, §17): every accepted proposal that wrote
/// something and every step list that sent something, in live chats, newest
/// first. Read by the Gaia page and, through the pipe, by the companion's
/// settings panel (GAIA_SETTINGS_HLD.md §3.2).
Future<List<GaiaAction>> gaiaActions(GaiaRepository repository) async {
  final chats = {
    for (final chat in await repository.listChats()) chat.id: chat,
  };
  final actions = <GaiaAction>[
    for (final message in await repository.listMessagesWithCommits())
      if (chats[message.chatId] != null)
        for (final card in message.parts.whereType<GaiaCardPart>())
          if ((card.kind == GaiaCardKind.proposal ||
                  card.kind == GaiaCardKind.control) &&
              card.answer?['committed'] != null &&
              // A step list declined partway still sent what it sent.
              (card.state == GaiaCardState.accepted ||
                  card.kind == GaiaCardKind.control))
            (chat: chats[message.chatId]!, message: message, card: card),
  ];
  return actions
    ..sort((a, b) => b.message.createdAt.compareTo(a.message.createdAt));
}
