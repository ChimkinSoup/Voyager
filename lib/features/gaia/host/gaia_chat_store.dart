import 'dart:math';

import 'package:uuid/uuid.dart';
import 'package:voyager/core/soft_delete/erasure.dart';
import 'package:voyager/core/sync/soft_delete_policy.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/domain/repositories/repositories.dart';
import 'package:voyager/features/gaia/host/gaia_actions.dart';

const _uuid = Uuid();

/// Sets task [task] in text part [part] of message [messageId] [flipped]
/// or not in [repository]; gives back what was written, or null for
/// nothing. Where there's no [GaiaChatStore], as on the phone.
Future<GaiaMessage?> gaiaToggleCheck(
  GaiaRepository repository,
  String messageId,
  int part,
  int task,
  bool flipped,
) async {
  final message = await repository.getMessage(messageId);
  if (message == null ||
      message.isDeleted ||
      message.parts.elementAtOrNull(part) is! GaiaTextPart) {
    return null;
  }
  final written = message.copyWith(
    parts: gaiaWithCheck(message.parts, part, task, flipped),
  );
  await repository.upsertMessage(written);
  return written;
}

/// Memory [memoryId]'s cards in [chatId]'s messages set to [state] with
/// [text] in [repository] (GAIA_HLD.md §11): what came of it, decided on
/// its card or in the memory inbox, or open again once a dismissal is
/// undone, [updated] when it was applied as an update
/// (GAIA_MEMORY_TOPICS_HLD.md §27.3). Where there's no [GaiaChatStore], as
/// on the phone.
Future<void> gaiaSetMemoryCards(
  GaiaRepository repository,
  String chatId,
  String memoryId,
  GaiaCardState state,
  String text, {
  bool updated = false,
}) async {
  bool stale(GaiaPart part) =>
      part is GaiaMemoryPart &&
      part.memoryId == memoryId &&
      (part.state != state || part.text != text || part.updated != updated);
  for (final message in await repository.listMessages(chatId)) {
    if (message.isDeleted || !message.parts.any(stale)) continue;
    await repository.upsertMessage(
      message.copyWith(
        parts: [
          for (final part in message.parts)
            stale(part)
                ? (part as GaiaMemoryPart).decided(
                    state,
                    text: text,
                    updated: updated,
                  )
                : part,
        ],
      ),
    );
  }
}

/// Revision card [cardId] in [chatId]'s messages set to [state] with [text]
/// in [repository] (GAIA_SETTINGS_HLD.md §7.4): applied as [text] says, with
/// the topic changes [topics] when given (§7.5), dismissed, or open again.
Future<void> gaiaSetRevisionCard(
  GaiaRepository repository,
  String chatId,
  String cardId,
  GaiaCardState state,
  String text, {
  List<GaiaTopicChange>? topics,
}) async {
  bool stale(GaiaPart part) =>
      part is GaiaRevisionPart &&
      part.id == cardId &&
      (part.state != state ||
          part.text != text ||
          (topics != null &&
              part.topics.map((change) => change.path).join('\n') !=
                  topics.map((change) => change.path).join('\n')));
  for (final message in await repository.listMessages(chatId)) {
    if (message.isDeleted || !message.parts.any(stale)) continue;
    await repository.upsertMessage(
      message.copyWith(
        parts: [
          for (final part in message.parts)
            stale(part)
                ? (part as GaiaRevisionPart).decided(
                    state,
                    text: text,
                    topics: topics,
                  )
                : part,
        ],
      ),
    );
  }
}

/// Deletes project [projectId] (GAIA_PROJECTS_HLD.md §3.3). With
/// [withChats] its chats go to the trash with it, at the same instant, so
/// restoring it brings them back; without, they're let go, to no project.
/// Either way its memories stay in its topic, which becomes an ordinary one
/// (GAIA_MEMORY_TOPICS_HLD.md §7). Gives back the chats it deleted.
Future<List<GaiaChat>> gaiaDeleteProject(
  GaiaRepository repository,
  String projectId, {
  required bool withChats,
}) async {
  final project = await repository.getProject(projectId);
  if (project == null || project.isDeleted) return const [];
  final at = utcNow();
  final all = await repository.listChats();
  final chats = [
    for (final chat in all)
      if (chat.projectId == projectId) chat,
  ]..sort(gaiaChatListed);
  // Let go, a pinned one goes to the bottom of the pinned chats in no
  // project, as pinning puts it, in the order they were in.
  final released = <GaiaChat>[];
  for (final chat in withChats ? const <GaiaChat>[] : chats) {
    final loose = chat.copyWith(clearProjectId: true);
    released.add(
      loose.pinned ? gaiaPinned(loose, true, [...all, ...released]) : loose,
    );
  }
  await repository.upsertProjectWithChats(
    project.copyWith(deletedAt: at),
    withChats
        ? [for (final chat in chats) chat.copyWith(deletedAt: at)]
        : released,
    topics: [
      if (await repository.getMemoryTopic(gaiaProjectTopicId(projectId))
          case final topic? when topic.projectId == projectId)
        topic.copyWith(clearProjectId: true),
    ],
  );
  return withChats ? chats : const [];
}

/// [chatId] moved into project [projectId], or out of its project for null
/// (GAIA_PROJECTS_HLD.md §3.2). A pinned one goes to the bottom of the
/// pinned chats there, as pinning puts it, or to [order] where that's
/// worked out already. Where there's no [GaiaChatStore], as on the phone.
Future<void> gaiaMoveChat(
  GaiaRepository repository,
  String chatId,
  String? projectId, {
  double? order,
}) async {
  final chat = await repository.getChat(chatId);
  if (chat == null || chat.projectId == projectId) return;
  final moved = projectId == null
      ? chat.copyWith(clearProjectId: true)
      : chat.copyWith(projectId: projectId);
  await repository.upsertChat(switch (order) {
    _ when !moved.pinned => moved,
    final order? => moved.copyWith(order: order, orderedAt: utcNow()),
    null => gaiaPinned(moved, true, await repository.listChats()),
  });
}

/// [chatId] archived or unarchived, with its forks as
/// [gaiaArchivedWithForks] has them. One that was temporary is an ordinary
/// chat again, read by the curator up to its last message, so its temporary
/// part never is (GAIA_TEMP_HLD.md §3.3). Where there's no [GaiaChatStore],
/// as on the phone.
Future<void> gaiaSetArchived(
  GaiaRepository repository,
  String chatId,
  bool archived,
) async {
  final chat = await repository.getChat(chatId);
  if (chat == null || chat.archived == archived) return;
  final all = await repository.listChats();
  final temporary = {
    for (final c in [chat, ...all])
      if (c.temporary) c.id,
  };
  for (final changed in gaiaArchivedWithForks(chat, archived, all)) {
    await repository.upsertChat(
      temporary.contains(changed.id) && !changed.temporary
          ? await _readSoFar(repository, changed)
          : changed,
    );
  }
}

/// [chatId] pinned or unpinned as [gaiaPinned] has it, or pinned to [order]
/// where that's worked out already. One that was temporary is an ordinary
/// chat again, read by the curator up to its last message, as
/// [gaiaSetArchived] has it. Where there's no [GaiaChatStore], as on the
/// phone.
Future<void> gaiaSetPinned(
  GaiaRepository repository,
  String chatId,
  bool pinned, {
  double? order,
}) async {
  final chat = await repository.getChat(chatId);
  if (chat == null || chat.pinned == pinned) return;
  final changed = pinned && order != null
      ? chat.copyWith(
          pinned: true,
          clearArchivedAt: true,
          clearTemporaryAt: true,
          order: order,
          orderedAt: utcNow(),
        )
      : gaiaPinned(chat, pinned, await repository.listChats());
  await repository.upsertChat(
    chat.temporary && !changed.temporary
        ? await _readSoFar(repository, changed)
        : changed,
  );
}

/// [chat] marked read by the curator up to its last message.
Future<GaiaChat> _readSoFar(GaiaRepository repository, GaiaChat chat) async =>
    chat.copyWith(
      curatedSeq: [
        for (final message in await repository.listMessages(chat.id))
          message.seq,
      ].fold<int>(chat.curatedSeq, max),
    );

/// The companion's chat reads and writes, as the main instance serves them
/// over the pipe (GAIA_HLD.md §3.2), on top of [GaiaRepository].
///
/// The companion sends whole messages but never whole chats after creating
/// one: a chat it holds may be stale (pinned, renamed or deleted elsewhere),
/// so it only ever changes the fields it owns, through [setSession],
/// [setTier], [setTitle] and [setPinned]. The
/// sync fields are stamped here, against what's stored.
class GaiaChatStore {
  GaiaChatStore(this._repository, {required this.deviceId});

  final GaiaRepository _repository;

  /// This device, whose native sessions [setSession] records.
  final String deviceId;

  Future<List<GaiaChat>> chats() => _repository.listChats();

  /// The chats live or still in the trash: those deleted but neither erased
  /// nor expired, which can still be restored.
  Future<List<String>> restorableChatIds() async {
    final now = utcNow();
    bool gone(DateTime? deletedAt) =>
        deletedAt != null &&
        (isErasedAt(deletedAt) ||
            const SoftDeletePolicy().isExpired(deletedAt, now));
    return [
      for (final chat in await _repository.listChats(includeDeleted: true))
        if (!gone(chat.deletedAt)) chat.id,
    ];
  }

  /// Saves a chat the companion just started. A chat already stored is left
  /// as it is.
  Future<void> createChat(GaiaChat chat) => _serial(() async {
    if (await _repository.getChat(chat.id) != null) return;
    await _repository.upsertChat(chat.copyWith(version: 1));
  });

  /// Saves a fork the companion just made (GAIA_FORKING_HLD.md §2): [chat]
  /// and its copied [messages], all at once. A chat already stored is left
  /// as it is.
  Future<void> forkChat(GaiaChat chat, List<GaiaMessage> messages) =>
      _serial(() async {
        if (await _repository.getChat(chat.id) != null) return;
        await _repository.upsertChat(chat.copyWith(version: 1));
        for (final message in messages) {
          await _repository.upsertMessage(message.copyWith(version: 1));
        }
      });

  /// A rewind of [chatId] (GAIA_REWIND_HLD.md §4), all at once: the
  /// auto-fork [fork] with its [copies]; then [dropped] erased from the chat,
  /// its sessions cleared, its fork record set to [record], and [rewind]
  /// added to what it dropped. Nothing when the chat is gone, or the
  /// auto-fork is already stored.
  Future<void> rewindChat(
    String chatId, {
    required GaiaChat fork,
    required List<GaiaMessage> copies,
    required List<GaiaMessage> dropped,
    required GaiaForkRecord? record,
    required GaiaRewind rewind,
  }) => _serial(() async {
    final chat = await _repository.getChat(chatId);
    if (chat == null ||
        chat.isDeleted ||
        await _repository.getChat(fork.id) != null) {
      return;
    }
    await _repository.upsertChat(fork.copyWith(version: 1));
    for (final message in copies) {
      await _repository.upsertMessage(message.copyWith(version: 1));
    }
    await _erase(dropped);
    await _repository.upsertChat(
      chat.copyWith(
        agentSessions: const {},
        fork: record,
        clearFork: record == null,
        rewinds: [...chat.rewinds, rewind],
      ),
    );
  });

  /// A reply that ended in a range a rewind dropped, moved to the range's
  /// auto-fork (GAIA_REWIND_HLD.md §5.1): [copy] saved there, [late] erased.
  Future<void> moveLate(GaiaMessage late, GaiaMessage copy) =>
      _serial(() async {
        if (await _repository.getChat(copy.chatId) == null) return;
        await _repository.upsertMessage(copy.copyWith(version: 1));
        await _erase([late]);
      });

  /// Forgets [chatId]'s fork record (GAIA_FORKING_HLD.md §5.3): its native
  /// session was made, or can't be.
  Future<void> dropFork(String chatId) => _serial(() async {
    final chat = await _repository.getChat(chatId);
    if (chat == null || chat.fork == null) return;
    // This device's alone: nothing for sync to carry.
    await _repository.upsertChat(
      chat.copyWith(clearFork: true, bumpVersion: false, touch: false),
      recordLocalActivity: false,
    );
  });

  /// Records the native session [chatId] resumes on this device with
  /// [adapter] and [account], the last message it took part in, and the
  /// project it was last told it's in (GAIA_PROJECTS_HLD.md §5.2), and the
  /// memories it was given (GAIA_MEMORY_TOPICS_HLD.md §4.4); a null
  /// [sessionId] forgets it.
  Future<void> setSession(
    String chatId,
    String? sessionId,
    int lastSeq, {
    String adapter = kGaiaClaudeCodeAdapter,
    String account = kGaiaDefaultAccountId,
    String? project,
    String? folder,
    List<String> recalled = const [],
    List<String>? pinned,
  }) => _serial(() async {
    final chat = await _repository.getChat(chatId);
    if (chat == null) return;
    final key = gaiaSessionKey(deviceId, adapter: adapter, account: account);
    await _repository.upsertChat(
      chat.copyWith(
        agentSessions: sessionId == null
            ? ({...chat.agentSessions}..remove(key))
            : {
                ...chat.agentSessions,
                key: GaiaAgentSession(
                  sessionId: sessionId,
                  lastSeq: lastSeq,
                  project: project,
                  folder: folder,
                  recalled: recalled,
                  pinned: pinned,
                ),
              },
      ),
    );
  });

  /// The tier [chatId] now uses (§7.2).
  Future<void> setTier(String chatId, GaiaTier tier) => _serial(() async {
    final chat = await _repository.getChat(chatId);
    if (chat == null || chat.tier == tier) return;
    await _repository.upsertChat(chat.copyWith(tier: tier));
  });

  /// The utility model's title for [chatId], over [from]; a chat renamed
  /// since keeps its name.
  Future<void> setTitle(String chatId, String title, String from) =>
      _serial(() async {
        final chat = await _repository.getChat(chatId);
        if (chat == null || chat.title != from) return;
        await _repository.upsertChat(chat.copyWith(title: title));
      });

  /// Pinned or unpinned from Gaia's sidebar, as on the Gaia page; pinned
  /// to [order] where the sidebar's worked that out already, so it stays
  /// where it showed.
  Future<void> setPinned(String chatId, bool pinned, {double? order}) =>
      _serial(() => gaiaSetPinned(_repository, chatId, pinned, order: order));

  /// Archived or unarchived from Gaia's sidebar, as on the Gaia page.
  Future<void> setArchived(String chatId, bool archived) =>
      _serial(() => gaiaSetArchived(_repository, chatId, archived));

  /// Made temporary by `/temp` (GAIA_TEMP_HLD.md §3.1), or an ordinary chat
  /// again, read by the curator up to its last message (§3.3).
  Future<void> setTemporary(String chatId, bool temporary) =>
      _serial(() async {
        final chat = await _repository.getChat(chatId);
        if (chat == null || chat.temporary == temporary) return;
        await _repository.upsertChat(
          temporary
              ? gaiaTemporary(chat)
              : await _readSoFar(_repository, gaiaArchived(chat, false)),
        );
      });

  /// Dragged in Gaia's sidebar to [order] (`GaiaChat.order`).
  Future<void> reorderChat(String chatId, double order) => _serial(() async {
    final chat = await _repository.getChat(chatId);
    if (chat == null) return;
    await _repository.upsertChat(
      chat.copyWith(order: order, orderedAt: utcNow()),
    );
  });

  /// Dragged in Gaia's sidebar to [order] (`GaiaProject.order`).
  Future<void> reorderProject(String projectId, double order) =>
      _serial(() async {
        final project = await _repository.getProject(projectId);
        if (project == null) return;
        await _repository.upsertProject(
          project.copyWith(order: order, orderedAt: utcNow()),
        );
      });

  /// [chatId]'s [summary] up to [seq] (GAIA_PROJECTS_HLD.md §5.5); one that
  /// covers less than the stored one is dropped.
  Future<void> setSummary(String chatId, String summary, int seq) =>
      _serial(() async {
        final chat = await _repository.getChat(chatId);
        if (chat == null || chat.summarizedSeq >= seq) return;
        await _repository.upsertChat(
          chat.copyWith(summary: summary, summarizedSeq: seq),
        );
      });

  /// Moved into a project or out of one (GAIA_PROJECTS_HLD.md §3.2).
  Future<void> setProject(String chatId, String? projectId, {double? order}) =>
      _serial(() => gaiaMoveChat(_repository, chatId, projectId, order: order));

  Future<List<GaiaProject>> projects() => _repository.listProjects();

  /// Saves a project the companion just made. One already stored is left
  /// as it is.
  Future<void> createProject(GaiaProject project) => _serial(() async {
    if (await _repository.getProject(project.id) != null) return;
    await _repository.upsertProject(project.copyWith(version: 1));
  });

  Future<void> renameProject(String projectId, String name) =>
      _serial(() async {
        final project = await _repository.getProject(projectId);
        if (project == null || project.name == name) return;
        await _repository.upsertProject(project.copyWith(name: name));
      });

  /// [projectId]'s folder on this device is [path], or none for null
  /// (GAIA_PROJECTS_HLD.md §4); other devices' stay as they are.
  Future<void> setProjectFolder(String projectId, String? path) =>
      _serial(() async {
        final project = await _repository.getProject(projectId);
        if (project == null || project.folderPaths[deviceId] == path) return;
        await _repository.upsertProject(
          project.copyWith(folders: {...project.folders, deviceId: path ?? ''}),
        );
      });

  /// [gaiaDeleteProject]: the chats it deleted.
  Future<List<GaiaChat>> deleteProject(
    String projectId, {
    required bool withChats,
  }) => _serial(
    () => gaiaDeleteProject(_repository, projectId, withChats: withChats),
  );

  /// Drain mode on or off for [chatId] (§13).
  Future<void> setDrain(String chatId, bool drain) => _serial(() async {
    final chat = await _repository.getChat(chatId);
    if (chat == null || chat.drain == drain) return;
    await _repository.upsertChat(chat.copyWith(drain: drain));
  });

  /// Drain mode off everywhere: Abort stops it (§13).
  Future<void> stopDraining() => _serial(() async {
    for (final chat in await _repository.listChats()) {
      if (chat.drain) await _repository.upsertChat(chat.copyWith(drain: false));
    }
  });

  /// Whether [chatId] may see the screen on this device (§15.6): a grant from
  /// another device doesn't count here.
  Future<bool> canSeeScreen(String chatId) async {
    final chat = await _repository.getChat(chatId);
    return chat != null &&
        !chat.isDeleted &&
        (chat.grants[deviceId]?.seeScreen ?? false);
  }

  /// *Can see screen* on or off for [chatId], on this device (§15.6).
  Future<void> setSeeScreen(String chatId, bool on) => _serial(() async {
    final chat = await _repository.getChat(chatId);
    if (chat == null || (chat.grants[deviceId]?.seeScreen ?? false) == on) {
      return;
    }
    await _repository.upsertChat(
      chat.copyWith(
        grants: {
          ...chat.grants,
          deviceId: GaiaGrant(
            seeScreen: on,
            canControl: chat.grants[deviceId]?.canControl ?? false,
            // Auto needs reading (GAIA_AUTONOMY_HLD.md §4): off drops to Ask.
            auto: on && (chat.grants[deviceId]?.auto ?? false),
            at: utcNow(),
          ),
        },
      ),
    );
  });

  /// Whether [chatId] may send input on this device (§15.6): a grant from
  /// another device doesn't count here.
  Future<bool> canControl(String chatId) async {
    final chat = await _repository.getChat(chatId);
    return chat != null &&
        !chat.isDeleted &&
        (chat.grants[deviceId]?.canControl ?? false);
  }

  /// *Can control* on or off for [chatId], on this device (§15.6).
  Future<void> setCanControl(String chatId, bool on) => _serial(() async {
    final chat = await _repository.getChat(chatId);
    if (chat == null || (chat.grants[deviceId]?.canControl ?? false) == on) {
      return;
    }
    await _repository.upsertChat(
      chat.copyWith(
        grants: {
          ...chat.grants,
          deviceId: GaiaGrant(
            seeScreen: chat.grants[deviceId]?.seeScreen ?? false,
            canControl: on,
            // On again, it's Ask: Auto is chosen each time.
            at: utcNow(),
          ),
        },
      ),
    );
  });

  /// Whether [chatId] is in Auto on this device (GAIA_AUTONOMY_HLD.md §4).
  Future<bool> isAuto(String chatId) async {
    final chat = await _repository.getChat(chatId);
    return chat != null &&
        !chat.isDeleted &&
        (chat.grants[deviceId]?.isAuto ?? false);
  }

  /// The hand to Auto, or back to Ask, for [chatId] on this device. Auto turns
  /// on *can control* and *can see screen* with it (§4).
  Future<void> setAuto(String chatId, bool on) => _serial(() async {
    final chat = await _repository.getChat(chatId);
    if (chat == null || chat.isDeleted) return;
    final grant = chat.grants[deviceId];
    if (on ? grant?.isAuto ?? false : !(grant?.auto ?? false)) return;
    await _repository.upsertChat(
      chat.copyWith(
        grants: {
          ...chat.grants,
          deviceId: GaiaGrant(
            seeScreen: on || (grant?.seeScreen ?? false),
            canControl: on || (grant?.canControl ?? false),
            auto: on,
            at: utcNow(),
          ),
        },
      ),
    );
  });

  /// Live chats with *can control* on, on this device, and whether each is in
  /// Auto: what the border names (§15.6).
  Future<List<({String title, bool auto})>> controlledChats() async => [
    for (final chat in await _repository.listChats())
      if (!chat.isDeleted && (chat.grants[deviceId]?.canControl ?? false))
        (title: chat.title, auto: chat.grants[deviceId]!.isAuto),
  ];

  /// Every chat's grants on this device off: Abort (§15.7), and Re-arm leaves
  /// them so.
  Future<void> revokeGrants() => _serial(() async {
    // Those in the trash too, or a restore would bring theirs back.
    for (final chat in await _repository.listChats(includeDeleted: true)) {
      final grant = chat.grants[deviceId];
      if (grant == null ||
          !(grant.seeScreen || grant.canControl || grant.auto)) {
        continue;
      }
      await _repository.upsertChat(
        chat.copyWith(
          grants: {
            ...chat.grants,
            deviceId: GaiaGrant(seeScreen: false, at: utcNow()),
          },
        ),
      );
    }
  });

  /// Every waiting prompt, in order.
  Future<List<GaiaQueueItem>> allQueued() => _repository.listQueue();

  /// [chatId]'s waiting prompts in order, the global queue's for null.
  Future<List<GaiaQueueItem>> queue(String? chatId) async => [
    for (final item in await _repository.listQueue())
      if (item.chatId == chatId) item,
  ];

  /// [text] at the end of [chatId]'s queue (§13), or the [front] of it for
  /// a popped prompt that didn't go.
  Future<GaiaQueueItem> enqueue(
    String? chatId,
    String text, {
    bool front = false,
  }) => _serial(() async {
    final waiting = [
      for (final item in await _repository.listQueue())
        if (item.chatId == chatId) item,
    ];
    final now = utcNow();
    final item = GaiaQueueItem(
      id: _uuid.v4(),
      chatId: chatId,
      text: text,
      order: front
          ? (waiting.firstOrNull?.order ?? 1) - 1
          : (waiting.lastOrNull?.order ?? 0) + 1,
      createdAt: now,
      updatedAt: now,
      version: 1,
    );
    await _repository.upsertQueueItem(item);
    return item;
  });

  /// Takes [chatId]'s next waiting prompt off its queue, marked sent, so no
  /// device sends it again; null when there's none. For [draining], null too
  /// once the chat's drain mode is off: the companion's copy of the chat can
  /// be a moment behind, as when a rewind has just paused it
  /// (GAIA_REWIND_HLD.md §4 step 0).
  Future<GaiaQueueItem?> queuePop(String? chatId, {bool draining = false}) =>
      _serial(() async {
        if (draining &&
            chatId != null &&
            !((await _repository.getChat(chatId))?.drain ?? false)) {
          return null;
        }
        final next = (await _repository.listQueue())
            .where((item) => item.chatId == chatId)
            .firstOrNull;
        if (next == null) return null;
        await _repository.upsertQueueItem(next.copyWith(consumedAt: utcNow()));
        return next;
      });

  /// Waiting prompt [id] changed from the settings panel's Queue tab
  /// (GAIA_SETTINGS_HLD.md §4), as the Gaia page changes it: [text]
  /// rewritten, [order] moved, or [delete]d. Nothing for one that's gone,
  /// sent or deleted meanwhile.
  Future<void> changeQueued(
    String id, {
    String? text,
    double? order,
    bool delete = false,
  }) => _serial(() async {
    final item = await _repository.getQueueItem(id);
    if (item == null || item.deletedAt != null || item.consumedAt != null) {
      return;
    }
    await _repository.upsertQueueItem(
      item.copyWith(
        text: text ?? item.text,
        order: order ?? item.order,
        deletedAt: delete ? utcNow() : null,
      ),
    );
  });

  /// The action log (GAIA_HLD.md §17), as the Gaia page reads it.
  Future<List<GaiaAction>> actions() => gaiaActions(_repository);

  /// Message [id], live or not; null for none.
  Future<GaiaMessage?> message(String id) => _repository.getMessage(id);

  /// Deleted from Gaia's sidebar: tombstoned, as on the Gaia page, so
  /// [restoreChat] can undo it.
  Future<void> deleteChat(String chatId) => _repository.softDeleteChat(chatId);

  /// [deleteChat] for each of [chatIds] that's still live, one write at a
  /// time with a stopped run's last saves; gives back those it deleted.
  Future<List<String>> deleteChats(List<String> chatIds) => _serial(() async {
    final deleted = <String>[];
    for (final chatId in chatIds) {
      final chat = await _repository.getChat(chatId);
      if (chat == null || chat.isDeleted) continue;
      await _repository.softDeleteChat(chatId);
      deleted.add(chatId);
    }
    return deleted;
  });

  /// A stopped message given back to the composer (GAIA_HLD.md §9.6): it
  /// and its empty reply erased, as the trash's "Delete forever" leaves a
  /// row, and with [chat] their chat, which held nothing else. Erased even
  /// if not stored yet, so a save still on its way stays out.
  Future<void> takeBack(List<GaiaMessage> messages, {required bool chat}) =>
      _serial(() async {
        await _erase(messages);
        final chatId = messages.first.chatId;
        final stored = await _repository.getChat(chatId);
        if (!chat || stored == null || isErasedAt(stored.deletedAt)) return;
        await _repository.upsertChat(
          stored.copyWith(
            title: '',
            deletedAt: kErasedAt,
            version: stored.version + kEraseVersionStep,
          ),
        );
      });

  /// [messages] erased, as the trash's "Delete forever" leaves a row, even
  /// if not stored yet, so a save still on its way stays out.
  Future<void> _erase(List<GaiaMessage> messages) async {
    for (final message in messages) {
      final existing = await _repository.getMessage(message.id) ?? message;
      if (isErasedAt(existing.deletedAt)) continue;
      await _repository.upsertMessage(
        existing.copyWith(
          parts: const [],
          clearChapter: true,
          status: GaiaMessageStatus.cancelled,
          deletedAt: kErasedAt,
          version: existing.version + kEraseVersionStep,
        ),
      );
    }
  }

  Future<void> restoreChat(String chatId) => _repository.restoreChat(chatId);

  /// The account [adapter]'s next messages run on (§6.5).
  Future<void> setCurrentAccount(String adapter, String account) =>
      _serial(() async {
        final settings = await _repository.getSettings();
        if (settings.currentAccounts[adapter] == account) return;
        await _repository.upsertSettings(
          settings.copyWith(
            currentAccounts: {...settings.currentAccounts, adapter: account},
          ),
        );
      });

  /// The settings panel's save (GAIA_SETTINGS_HLD.md §3.4): [changes] made
  /// to what's stored now.
  Future<void> putSettings(Map<String, Object?> changes) => _serial(() async {
    final settings = await _repository.getSettings();
    await _repository.upsertSettings(settings.patched(changes));
  });

  /// Tidy memories weekly is on by default with no device to sweep on
  /// (GAIA_MEMORY_TOPICS_HLD.md §27.7 item 3): this desktop takes it. Run
  /// after the startup pull, so an account that turned it off has said so.
  Future<void> claimTidyMemories() => _serial(() async {
    final settings = await _repository.getSettings();
    if (!settings.tidyMemories || settings.tidyMemoriesDevice.isNotEmpty) {
      return;
    }
    await _repository.upsertSettings(
      settings.copyWith(tidyMemoriesDevice: deviceId),
    );
  });

  /// Proposed memories waiting in the inbox (GAIA_SETTINGS_HLD.md §5.5).
  Future<int> inboxCount() async =>
      gaiaInboxCount(await _repository.listMemories());

  /// The tier a new chat starts on (§7.2).
  Future<void> setLastTier(GaiaTier tier) => _serial(() async {
    final settings = await _repository.getSettings();
    if (settings.lastTier == tier) return;
    await _repository.upsertSettings(settings.copyWith(lastTier: tier));
  });

  /// Each chat's draft (§9.3), as this device or another left it. Deleted
  /// ones too: the companion takes one as emptied.
  Future<List<GaiaDraft>> drafts() => _repository.listDrafts();

  /// The companion's [draft], versioned on from what's stored. Its
  /// `updatedAt` is the companion's, so it knows its own write when it
  /// comes back. An empty one is kept deleted.
  Future<void> putDraft(GaiaDraft draft) async {
    final existing = await _repository.getDraft(draft.id);
    await _repository.upsertDraft(
      GaiaDraft(
        id: draft.id,
        text: draft.text,
        caret: draft.caret,
        images: draft.images,
        files: draft.files,
        createdAt: existing?.createdAt ?? draft.createdAt,
        updatedAt: draft.updatedAt,
        version: (existing?.version ?? 0) + 1,
        deletedAt: draft.isEmpty ? draft.updatedAt : null,
      ),
    );
  }

  /// [chatId]'s draft goes with its chat, what it holds kept for
  /// [restoreDraft].
  Future<void> deleteDraft(String chatId) async {
    final draft = await _repository.getDraft(chatId);
    if (draft == null || draft.deletedAt != null) return;
    final now = utcNow();
    await _repository.upsertDraft(_restamped(draft, now, deletedAt: now));
  }

  /// [chatId]'s draft back with its chat; null when it had none.
  Future<GaiaDraft?> restoreDraft(String chatId) async {
    final draft = await _repository.getDraft(chatId);
    if (draft == null || draft.deletedAt == null || draft.isEmpty) return null;
    final restored = _restamped(draft, utcNow());
    await _repository.upsertDraft(restored);
    return restored;
  }

  static GaiaDraft _restamped(
    GaiaDraft draft,
    DateTime at, {
    DateTime? deletedAt,
  }) => GaiaDraft(
    id: draft.id,
    text: draft.text,
    caret: draft.caret,
    images: draft.images,
    files: draft.files,
    createdAt: draft.createdAt,
    updatedAt: at,
    version: draft.version + 1,
    deletedAt: deletedAt,
  );

  Future<List<GaiaMessage>> messages(String chatId) =>
      _repository.listMessages(chatId);

  Future<List<GaiaSearchHit>> searchMessages(String query) =>
      _repository.searchMessages(query);

  /// A message's first write also moves its chat to the top. Gives back
  /// what was written, or null for nothing.
  ///
  /// A message erased while its run streams stays erased, as does a chat
  /// erased meanwhile: the run's later writes are dropped, or they'd bring the
  /// erased text back. Its task ticks stay as stored: only [toggleCheck]
  /// changes them, from the companion or the Gaia page, as it streams too.
  /// So do its memory cards, once stored: only [setMemoryCards] changes them,
  /// and its revision cards, which only [setRevisionCard] does.
  /// Its chapter stays as stored too: only [setChapter] changes it.
  Future<GaiaMessage?> putMessage(GaiaMessage message) => _serial(() async {
    final existing = await _repository.getMessage(message.id);
    if (existing != null && existing.isDeleted) return null;
    if (isErasedAt((await _repository.getChat(message.chatId))?.deletedAt)) {
      return null;
    }
    final written = message.copyWith(
      parts: existing == null
          ? null
          : gaiaKeepMemoryCards(
              gaiaKeepChecks(message.parts, gaiaChecksOf(existing.parts)),
              existing.parts,
            ),
      // A first write keeps its own: one pinned before it was stored.
      chapter: existing == null ? message.chapter : existing.chapter,
      clearChapter: existing != null && existing.chapter == null,
      version: (existing?.version ?? 0) + 1,
    );
    await _repository.upsertMessage(written);
    final chat = await _repository.getChat(message.chatId);
    if (chat == null) throw StateError('No chat ${message.chatId}');
    if (message.createdAt.isAfter(chat.lastMessageAt)) {
      await _repository.upsertChat(
        chat.copyWith(lastMessageAt: message.createdAt),
      );
    }
    return written;
  });

  /// Sets task [task] in text part [part] of message [messageId] [flipped]
  /// or not, as stored; gives back what was written, or null for nothing.
  Future<GaiaMessage?> toggleCheck(
    String messageId,
    int part,
    int task,
    bool flipped,
  ) => _serial(
    () => gaiaToggleCheck(_repository, messageId, part, task, flipped),
  );

  /// [gaiaSetMemoryCards], one write at a time with the companion's.
  Future<void> setMemoryCards(
    String chatId,
    String memoryId,
    GaiaCardState state,
    String text, {
    bool updated = false,
  }) => _serial(
    () => gaiaSetMemoryCards(
      _repository,
      chatId,
      memoryId,
      state,
      text,
      updated: updated,
    ),
  );

  /// [gaiaSetRevisionCard], one write at a time with the companion's.
  Future<void> setRevisionCard(
    String chatId,
    String cardId,
    GaiaCardState state,
    String text, {
    List<GaiaTopicChange>? topics,
  }) => _serial(
    () => gaiaSetRevisionCard(
      _repository,
      chatId,
      cardId,
      state,
      text,
      topics: topics,
    ),
  );

  /// Message [messageId]'s chapter set to [chapter], or unpinned for null
  /// (GAIA_CHAPTERS_HLD.md §3.1). Nothing for a message gone or deleted, nor
  /// with [from] given when the stored chapter isn't [from], so the utility
  /// model's title never overwrites a rename.
  Future<GaiaMessage?> setChapter(
    String messageId,
    String? chapter, {
    String? from,
  }) => _serial(() async {
    final existing = await _repository.getMessage(messageId);
    if (existing == null || existing.isDeleted) return null;
    if (from != null && existing.chapter != from) return null;
    if (existing.chapter == chapter) return null;
    final written = existing.copyWith(
      chapter: chapter,
      clearChapter: chapter == null,
    );
    await _repository.upsertMessage(written);
    return written;
  });

  /// [chatId]'s live side questions, oldest first (GAIA_BTW_HLD.md §2).
  Future<List<GaiaBtw>> btws(String chatId) =>
      _repository.listBtws(chatId: chatId);

  /// A side question as the companion has it, versioned on from what's
  /// stored; gives back what was written, or null for nothing. One cleared
  /// meanwhile stays cleared, as does one whose chat was erased. Synced as
  /// it starts and once it's done, not as it streams (§2).
  Future<GaiaBtw?> putBtw(GaiaBtw btw) => _serial(() async {
    final existing = await _repository.getBtw(btw.id);
    if (existing != null && existing.isDeleted) return null;
    if (isErasedAt((await _repository.getChat(btw.chatId))?.deletedAt)) {
      return null;
    }
    final synced =
        existing == null || btw.status != GaiaMessageStatus.streaming;
    // Versioned only as it syncs: a version per streaming save would outrank
    // a clear made meanwhile on another device, bringing the btw back.
    final written = btw.copyWith(
      version: (existing?.version ?? 0) + (synced ? 1 : 0),
    );
    await _repository.upsertBtw(written, recordLocalActivity: synced);
    return written;
  });

  /// Every live side question of [chatId] cleared (§4.2); gives back their
  /// ids, for [restoreBtws].
  Future<List<String>> clearBtws(String chatId) => _serial(() async {
    final now = utcNow();
    final cleared = <String>[];
    for (final btw in await _repository.listBtws(chatId: chatId)) {
      await _repository.upsertBtw(
        btw.copyWith(
          deletedAt: now,
          // One still streaming here was stopped first; elsewhere, it ends.
          status: btw.status == GaiaMessageStatus.streaming
              ? GaiaMessageStatus.cancelled
              : null,
        ),
      );
      cleared.add(btw.id);
    }
    return cleared;
  });

  /// The side questions [clearBtws] cleared, back (§4.2).
  Future<void> restoreBtws(List<String> ids) => _serial(() async {
    for (final id in ids) {
      final btw = await _repository.getBtw(id);
      if (btw == null || !btw.isDeleted || isErasedAt(btw.deletedAt)) continue;
      await _repository.upsertBtw(btw.copyWith(clearDeletedAt: true));
    }
  });

  /// Writes that read what they change, one at a time: a tick written
  /// between a streaming reply's read and its write would be lost, as would
  /// a session [setSession] forgot under the chat [putMessage] read before.
  var _writes = Future<void>.value();

  Future<T> _serial<T>(Future<T> Function() write) {
    final done = _writes.then((_) => write());
    _writes = done.then((_) {}, onError: (_) {});
    return done;
  }

  /// Marks messages a companion left streaming as [status]: the companion
  /// that streamed them is gone, and their runs with it. So are this
  /// device's side questions; another device's may still be running there.
  Future<void> endStreaming(GaiaMessageStatus status) async {
    await _repository.endStreaming(status);
    for (final btw in await _repository.listBtws()) {
      if (btw.status == GaiaMessageStatus.streaming &&
          btw.deviceId == deviceId) {
        await putBtw(btw.copyWith(status: status));
      }
    }
  }
}
