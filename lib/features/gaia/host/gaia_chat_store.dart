import 'package:uuid/uuid.dart';
import 'package:voyager/core/soft_delete/erasure.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/domain/repositories/repositories.dart';

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

  /// Saves a chat the companion just started. A chat already stored is left
  /// as it is.
  Future<void> createChat(GaiaChat chat) => _serial(() async {
    if (await _repository.getChat(chat.id) != null) return;
    await _repository.upsertChat(chat.copyWith(version: 1));
  });

  /// Records the native session [chatId] resumes on this device with
  /// [adapter] and [account], and the last message it took part in; a null
  /// [sessionId] forgets it.
  Future<void> setSession(
    String chatId,
    String? sessionId,
    int lastSeq, {
    String adapter = kGaiaClaudeCodeAdapter,
    String account = kGaiaDefaultAccountId,
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
                key: GaiaAgentSession(sessionId: sessionId, lastSeq: lastSeq),
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

  /// Pinned or unpinned from Gaia's sidebar, as on the Gaia page.
  Future<void> setPinned(String chatId, bool pinned) => _serial(() async {
    final chat = await _repository.getChat(chatId);
    if (chat == null || chat.pinned == pinned) return;
    await _repository.upsertChat(chat.copyWith(pinned: pinned));
  });

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
  /// device sends it again; null when there's none.
  Future<GaiaQueueItem?> queuePop(String? chatId) => _serial(() async {
    final next = (await _repository.listQueue())
        .where((item) => item.chatId == chatId)
        .firstOrNull;
    if (next == null) return null;
    await _repository.upsertQueueItem(next.copyWith(consumedAt: utcNow()));
    return next;
  });

  /// Deleted from Gaia's sidebar: tombstoned, as on the Gaia page, so
  /// [restoreChat] can undo it.
  Future<void> deleteChat(String chatId) => _repository.softDeleteChat(chatId);

  Future<void> restoreChat(String chatId) => _repository.restoreChat(chatId);

  /// The account [adapter]'s next messages run on (§6.5).
  Future<void> setCurrentAccount(String adapter, String account) async {
    final settings = await _repository.getSettings();
    if (settings.currentAccounts[adapter] == account) return;
    await _repository.upsertSettings(
      settings.copyWith(
        currentAccounts: {...settings.currentAccounts, adapter: account},
      ),
    );
  }

  /// The tier a new chat starts on (§7.2).
  Future<void> setLastTier(GaiaTier tier) async {
    final settings = await _repository.getSettings();
    if (settings.lastTier == tier) return;
    await _repository.upsertSettings(settings.copyWith(lastTier: tier));
  }

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

  /// A message's first write also moves its chat to the top. Gives back
  /// what was written, or null for nothing.
  ///
  /// A message erased while its run streams stays erased, as does a chat
  /// erased meanwhile: the run's later writes are dropped, or they'd bring the
  /// erased text back. Its task ticks stay as stored: only [toggleCheck]
  /// changes them, from the companion or the Gaia page, as it streams too.
  Future<GaiaMessage?> putMessage(GaiaMessage message) => _serial(() async {
    final existing = await _repository.getMessage(message.id);
    if (existing != null && existing.isDeleted) return null;
    if (isErasedAt((await _repository.getChat(message.chatId))?.deletedAt)) {
      return null;
    }
    final written = message.copyWith(
      parts: existing == null
          ? null
          : gaiaKeepChecks(message.parts, gaiaChecksOf(existing.parts)),
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
  /// that streamed them is gone, and their runs with it.
  Future<void> endStreaming(GaiaMessageStatus status) =>
      _repository.endStreaming(status);
}
