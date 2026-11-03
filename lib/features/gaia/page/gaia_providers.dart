import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/adapters/claude_code/claude_code_runner.dart';
import 'package:voyager/features/gaia/adapters/claude_code/claude_code_setup.dart';
import 'package:voyager/features/gaia/adapters/codex/codex_runner.dart';
import 'package:voyager/features/gaia/adapters/codex/codex_setup.dart';
import 'package:voyager/features/gaia/host/gaia_host.dart';
import 'package:voyager/features/gaia/remote/gaia_device_keys.dart';
import 'package:voyager/features/gaia/remote/gaia_remote.dart';
import 'package:voyager/features/gaia/remote/gaia_remote_client.dart';
import 'package:voyager/features/gaia/usage/gaia_usage.dart';

/// Live chats, pinned first, then the most recent.
final gaiaChatsProvider = StreamProvider<List<GaiaChat>>(
  (ref) => ref.watch(gaiaRepositoryProvider).watchChats(),
);

/// Live memories (§11), oldest first.
final gaiaMemoriesProvider = StreamProvider<List<GaiaMemory>>(
  (ref) => ref.watch(gaiaRepositoryProvider).watchMemories(),
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
/// first. Read again on every write to the chats or
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

/// Each adapter's usage on this desktop (§6.4), as the companion reports it.
final gaiaUsageProvider = Provider.autoDispose<Map<String, GaiaAccountUsage>>((
  ref,
) {
  final usage = GaiaHost.instance.usage;
  usage.addListener(ref.invalidateSelf);
  ref.onDispose(() => usage.removeListener(ref.invalidateSelf));
  return usage.value;
});

/// Asks for an account's usage to be read again, by its key.
final gaiaRecheckUsageProvider = Provider<void Function(String key)>(
  (ref) => GaiaHost.instance.recheckUsage,
);

/// The setup checklist's version check; invalidated to re-check. Each
/// account's login is its own provider's, below.
final gaiaClaudeSetupProvider = FutureProvider.autoDispose<ClaudeCodeSetup>(
  (ref) async => ClaudeCodeSetup(version: await claudeCodeVersion()),
);

final gaiaCodexSetupProvider = FutureProvider.autoDispose<CodexSetup>(
  (ref) async => CodexSetup(version: await codexVersion()),
);

/// A Claude account's login, by its config folder (§6.1).
final gaiaClaudeAccountProvider = FutureProvider.autoDispose
    .family<ClaudeCodeSetup, String>(
      (ref, dir) => probeClaudeCode(configDir: dir),
    );

/// A Codex account's login and sandbox (§6.1).
final gaiaCodexAccountProvider = FutureProvider.autoDispose
    .family<CodexSetup, GaiaAccount>((ref, account) => probeCodex(account));

/// The signed-in account, whose Firestore remote use goes through; null
/// signed out.
final _gaiaUidProvider = Provider<String?>(
  (ref) => ref.watch(authNotifierProvider.select((auth) => auth.userId)),
);

/// Every desktop's heartbeat (§12.2).
final gaiaBeaconsProvider = StreamProvider<List<GaiaBeacon>>((ref) {
  final uid = ref.watch(_gaiaUidProvider);
  if (uid == null) return Stream.value(const []);
  return gaiaBeacons(ref.watch(firestoreProvider), uid);
});

/// Every device that asked to pair (§12.2).
final gaiaDevicesProvider = StreamProvider<List<GaiaDevice>>((ref) {
  final uid = ref.watch(_gaiaUidProvider);
  if (uid == null) return Stream.value(const []);
  return gaiaDevices(ref.watch(firestoreProvider), uid);
});

/// A chat's live text while a beacon streams it to this device (§8.1).
final gaiaLiveProvider = StreamProvider.autoDispose.family<GaiaLive?, String>((
  ref,
  chatId,
) {
  final uid = ref.watch(_gaiaUidProvider);
  if (uid == null) return Stream.value(null);
  return gaiaLive(ref.watch(firestoreProvider), uid, chatId);
});

/// The time, every 30 s: whether a beacon counts as online moves with it.
final gaiaClockProvider = StreamProvider.autoDispose<DateTime>(
  (ref) => _timeEvery(ref, const Duration(seconds: 30)),
);

/// The time, every second, for what counts down on screen.
final gaiaTickProvider = StreamProvider.autoDispose<DateTime>(
  (ref) => _timeEvery(ref, const Duration(seconds: 1)),
);

/// The time, every [period], until [ref] is disposed. Not `Stream.periodic`:
/// a provider disposed before its first event leaves that one's timer running.
Stream<DateTime> _timeEvery(Ref ref, Duration period) {
  final times = StreamController<DateTime>();
  final timer = Timer.periodic(period, (_) => times.add(DateTime.now()));
  ref.onDispose(() {
    timer.cancel();
    unawaited(times.close());
  });
  return times.stream;
}

/// This device's signing key (§12.2); invalidated after [GaiaDeviceKey.reset].
final gaiaDeviceKeyProvider = FutureProvider<GaiaDeviceKey>(
  (ref) => GaiaDeviceKey.load(),
);

/// The phone's way to its beacons; null signed out.
final gaiaRemoteClientProvider = FutureProvider<GaiaRemoteClient?>((ref) async {
  final uid = ref.watch(_gaiaUidProvider);
  if (uid == null) return null;
  final key = await ref.watch(gaiaDeviceKeyProvider.future);
  return GaiaRemoteClient(
    firestore: ref.watch(firestoreProvider),
    uid: uid,
    deviceId: await ensureDeviceId(ref.read(settingsRepositoryProvider)),
    key: key,
  );
});

/// Every waiting prompt (§13), in order.
final gaiaQueueProvider = StreamProvider<List<GaiaQueueItem>>(
  (ref) => ref.watch(gaiaRepositoryProvider).watchQueue(),
);
