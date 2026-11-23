import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/platform/app_data_directory.dart';
import 'package:voyager/core/platform/platform_info.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/adapters/claude_code/claude_code_runner.dart';
import 'package:voyager/features/gaia/adapters/claude_code/claude_code_setup.dart';
import 'package:voyager/features/gaia/adapters/codex/codex_runner.dart';
import 'package:voyager/features/gaia/adapters/codex/codex_setup.dart';
import 'package:voyager/features/gaia/host/gaia_actions.dart';
import 'package:voyager/features/gaia/host/gaia_host.dart';
import 'package:voyager/features/gaia/host/gaia_memories.dart';
import 'package:voyager/features/gaia/host/gaia_voyager_reads.dart';
import 'package:voyager/features/gaia/remote/gaia_device_keys.dart';
import 'package:voyager/features/gaia/remote/gaia_remote.dart';
import 'package:voyager/features/gaia/remote/gaia_remote_client.dart';
import 'package:voyager/features/gaia/usage/gaia_usage.dart';

export 'package:voyager/features/gaia/host/gaia_actions.dart'
    show GaiaAction, gaiaControlStopped;

/// Live chats, pinned first, then the most recent.
final gaiaChatsProvider = StreamProvider<List<GaiaChat>>(
  (ref) => ref.watch(gaiaRepositoryProvider).watchChats(),
);

/// Live projects (GAIA_PROJECTS_HLD.md §1), oldest first.
final gaiaProjectsProvider = StreamProvider<List<GaiaProject>>(
  (ref) => ref.watch(gaiaRepositoryProvider).watchProjects(),
);

/// The projects folded shut on the Gaia page's Chats tab
/// (GAIA_PROJECTS_HLD.md §7.3), as they were left. This device's own, like
/// the sidebar's, so never synced: kept in a JSON file beside the database.
final gaiaClosedProjectsProvider =
    StateNotifierProvider<GaiaClosedProjects, Set<String>>(
      (ref) => GaiaClosedProjects(
        () async =>
            File(p.join((await appDataDirectory()).path, 'gaia_page.json')),
      ),
    );

class GaiaClosedProjects extends StateNotifier<Set<String>> {
  GaiaClosedProjects(this._file) : super(const {}) {
    unawaited(_load());
  }

  final Future<File> Function() _file;

  /// Set once one is folded, so a slow first read can't undo it.
  var _touched = false;
  var _saved = Future<void>.value();

  Future<void> _load() async {
    try {
      final file = await _file();
      if (!await file.exists()) return;
      final json = jsonDecode(await file.readAsString()) as Map;
      if (_touched || !mounted) return;
      state = {
        for (final id in json['closedProjects'] as List? ?? const [])
          id as String,
      };
    } catch (error) {
      debugPrint('[gaia] page prefs unreadable, using defaults: $error');
    }
  }

  void toggle(String projectId) {
    _touched = true;
    state = state.contains(projectId)
        ? ({...state}..remove(projectId))
        : {...state, projectId};
    final closed = state.toList();
    // In turn, so an older write never lands after a newer one.
    _saved = _saved.then((_) async {
      try {
        final file = await _file();
        await file.parent.create(recursive: true);
        await file.writeAsString(jsonEncode({'closedProjects': closed}));
      } catch (error) {
        debugPrint('[gaia] page prefs not saved: $error');
      }
    });
  }
}

/// Live memories (§11), oldest first.
final gaiaMemoriesProvider = StreamProvider<List<GaiaMemory>>(
  (ref) => ref.watch(gaiaRepositoryProvider).watchMemories(),
);

/// Live memory topics (GAIA_MEMORY_TOPICS_HLD.md §3.1), oldest first.
final gaiaMemoryTopicsProvider = StreamProvider<List<GaiaMemoryTopic>>(
  (ref) => ref.watch(gaiaRepositoryProvider).watchMemoryTopics(),
);

/// This device's recall history (GAIA_MEMORY_TOPICS_HLD.md §3.3), for pin
/// suggestions.
final gaiaRecallHistoryProvider = StreamProvider<List<GaiaRecallRow>>(
  (ref) => ref.watch(gaiaRepositoryProvider).watchRecallHistory(),
);

/// This device's pin and merge suggestion hints (§23).
final gaiaMemoryHintsProvider = StreamProvider<List<GaiaMemoryHint>>(
  (ref) => ref.watch(gaiaRepositoryProvider).watchMemoryHints(),
);

/// Where the utility model would file a batch of memories: the host's, which
/// asks the companion; tests give their own.
final gaiaSortMemoriesProvider =
    Provider<Future<Map<String, GaiaPlacement>> Function(List<GaiaMemory>)>(
      (ref) => GaiaHost.instance.sortMemories,
    );

/// The Gaia page's Sort these (GAIA_MEMORY_TOPICS_HLD.md §6): where the
/// utility model would file each Unsorted memory, by memory id, until
/// it's accepted or skipped; whether a batch is out; and why the last one
/// failed. Kept while the page is closed, not across a restart.
typedef GaiaSortState = ({
  Map<String, GaiaPlacement> suggested,
  bool running,
  String? error,
});

final gaiaSortProvider = NotifierProvider<GaiaSortNotifier, GaiaSortState>(
  GaiaSortNotifier.new,
);

class GaiaSortNotifier extends Notifier<GaiaSortState> {
  @override
  GaiaSortState build() {
    // A memory filed some other way, or deleted, loses its suggestion, so
    // none is left to show if it's ever Unsorted again.
    ref.listen(gaiaMemoriesProvider, (_, next) {
      final memories = next.valueOrNull;
      if (memories == null || state.suggested.isEmpty) return;
      final tree = GaiaTopicTree(
        ref.read(gaiaMemoryTopicsProvider).valueOrNull ?? const [],
      );
      final unsorted = {
        for (final memory in memories)
          if (!memory.isDeleted &&
              memory.topicIds.every((id) => tree.path(id).isEmpty))
            memory.id,
      };
      final kept = {
        for (final MapEntry(:key, :value) in state.suggested.entries)
          if (unsorted.contains(key)) key: value,
      };
      if (kept.length == state.suggested.length) return;
      state = (suggested: kept, running: state.running, error: state.error);
    });
    return (suggested: const {}, running: false, error: null);
  }

  /// [memories] not already suggested for, sent in batches of
  /// [kGaiaSortBatch], each batch's suggestions shown as it's answered. A
  /// failure stops it, saying why.
  Future<void> sort(List<GaiaMemory> memories) async {
    if (state.running) return;
    final left = [
      for (final memory in memories)
        if (!state.suggested.containsKey(memory.id)) memory,
    ];
    state = (suggested: state.suggested, running: true, error: null);
    String? error;
    final ask = ref.read(gaiaSortMemoriesProvider);
    try {
      for (var at = 0; at < left.length; at += kGaiaSortBatch) {
        try {
          final placed = await ask(
            left.sublist(at, min(at + kGaiaSortBatch, left.length)),
          );
          state = (
            suggested: {...state.suggested, ...placed},
            running: true,
            error: null,
          );
        } on GaiaReadException catch (failed) {
          error = failed.message;
          break;
        }
      }
    } finally {
      state = (suggested: state.suggested, running: false, error: error);
    }
  }

  /// Memory [id]'s suggestion as [placement]; dropped once it places
  /// nothing.
  void change(String id, GaiaPlacement placement) {
    final suggested = {...state.suggested};
    if (placement.topicIds.isEmpty && placement.suggested == null) {
      suggested.remove(id);
    } else {
      suggested[id] = placement;
    }
    state = (suggested: suggested, running: state.running, error: state.error);
  }

  /// Memory [id]'s suggestion dropped: skipped, or accepted.
  void drop(String id) =>
      change(id, (topicIds: const [], suggested: null, tags: const []));
}

/// A memory to show on the Gaia page's Memories tab, from a recall chip
/// (GAIA_MEMORY_TOPICS_HLD.md §4.5); null for none.
final gaiaRevealMemoryProvider = StateProvider<String?>((ref) => null);

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

/// The action log (§10, §15.6, §17), newest first. Read again on every
/// write to the chats or messages, since an undo changes a card without
/// touching its chat.
final gaiaActionsProvider = StreamProvider.autoDispose<List<GaiaAction>>((
  ref,
) async* {
  final repository = ref.watch(gaiaRepositoryProvider);
  yield await gaiaActions(repository);
  await for (final _ in repository.watchChanges()) {
    yield await gaiaActions(repository);
  }
});

/// Runs in progress on this desktop, as the companion reports them.
final gaiaRunsProvider = Provider.autoDispose<List<GaiaRun>>((ref) {
  final runs = GaiaHost.instance.runs;
  runs.addListener(ref.invalidateSelf);
  ref.onDispose(() => runs.removeListener(ref.invalidateSelf));
  return runs.value;
});

/// The chats running now: this desktop's, or on the phone, what every
/// desktop says it's running (§12.2).
final gaiaRunningChatsProvider = Provider.autoDispose<Set<String>>(
  (ref) => isWindows
      ? {for (final run in ref.watch(gaiaRunsProvider)) run.chatId}
      : {
          for (final beacon
              in ref.watch(gaiaBeaconsProvider).valueOrNull ?? const [])
            for (final run in beacon.runs) run.chatId,
        },
);

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
