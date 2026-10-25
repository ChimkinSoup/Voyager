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

/// Runs in progress on this desktop, as the companion reports them.
final gaiaRunsProvider = Provider.autoDispose<List<GaiaRun>>((ref) {
  final runs = GaiaHost.instance.runs;
  runs.addListener(ref.invalidateSelf);
  ref.onDispose(() => runs.removeListener(ref.invalidateSelf));
  return runs.value;
});

/// The setup checklist's probe; invalidated to re-check.
final gaiaClaudeSetupProvider = FutureProvider.autoDispose<ClaudeCodeSetup>(
  (ref) => probeClaudeCode(),
);

final gaiaCodexSetupProvider = FutureProvider.autoDispose<CodexSetup>(
  (ref) => probeCodex(),
);
