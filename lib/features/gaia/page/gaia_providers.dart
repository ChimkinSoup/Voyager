import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/adapters/claude_code/claude_code_setup.dart';
import 'package:voyager/features/gaia/adapters/codex/codex_setup.dart';
import 'package:voyager/features/gaia/host/gaia_host.dart';

/// Live chats, pinned first, then the most recent.
final gaiaChatsProvider = StreamProvider<List<GaiaChat>>(
  (ref) => ref.watch(gaiaRepositoryProvider).watchChats(),
);

final gaiaSettingsProvider = StreamProvider<GaiaSettings>(
  (ref) => ref.watch(gaiaRepositoryProvider).watchSettings(),
);

final gaiaMessagesProvider = StreamProvider.autoDispose
    .family<List<GaiaMessage>, String>(
      (ref, chatId) => ref.watch(gaiaRepositoryProvider).watchMessages(chatId),
    );

/// Chats with a message matching the query. Re-run when the chats change,
/// which every new message does (its chat's `lastMessageAt`).
final gaiaSearchProvider = FutureProvider.autoDispose
    .family<Set<String>, String>((ref, query) {
      ref.watch(gaiaChatsProvider);
      return ref.watch(gaiaRepositoryProvider).searchChatIds(query);
    });

/// One committed proposal in the action log (§17): [card], accepted, in
/// [message] of [chat].
typedef GaiaAction = ({GaiaChat chat, GaiaMessage message, GaiaCardPart card});

/// The action log (§10, §17): every accepted proposal that wrote something,
/// in live chats, newest first. Read again on every write to the chats or
/// messages, since an undo changes a card without touching its chat.
final gaiaActionsProvider = StreamProvider.autoDispose<List<GaiaAction>>((
  ref,
) async* {
  final repository = ref.watch(gaiaRepositoryProvider);
  Future<List<GaiaAction>> load() async {
    final chats = {
      for (final chat in await repository.listChats()) chat.id: chat,
    };
    final actions = <GaiaAction>[
      for (final message in await repository.listMessagesWithCommits())
        if (chats[message.chatId] != null)
          for (final card in message.parts.whereType<GaiaCardPart>())
            if (card.kind == GaiaCardKind.proposal &&
                card.state == GaiaCardState.accepted &&
                card.answer?['committed'] != null)
              (chat: chats[message.chatId]!, message: message, card: card),
    ];
    return actions
      ..sort((a, b) => b.message.createdAt.compareTo(a.message.createdAt));
  }

  yield await load();
  await for (final _ in repository.watchChanges()) {
    yield await load();
  }
});

/// Runs in progress on this desktop, as the companion reports them.
final gaiaRunsProvider = Provider.autoDispose<List<GaiaRun>>((ref) {
  final runs = GaiaHost.instance.runs;
  runs.addListener(ref.invalidateSelf);
  ref.onDispose(() => runs.removeListener(ref.invalidateSelf));
  return runs.value;
});

/// The setup checklist's probe; invalidated to re-check.
final gaiaClaudeSetupProvider = FutureProvider.autoDispose<ClaudeCodeSetup>(
  (ref) async => probeClaudeCode(
    configDir: (await ref.watch(gaiaSettingsProvider.future)).claudeConfigDir,
  ),
);

final gaiaCodexSetupProvider = FutureProvider.autoDispose<CodexSetup>(
  (ref) => probeCodex(),
);
