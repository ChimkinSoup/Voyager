import 'package:voyager/core/soft_delete/erasure.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/domain/repositories/repositories.dart';

/// The companion's chat reads and writes, as the main instance serves them
/// over the pipe (GAIA_HLD.md §3.2), on top of [GaiaRepository].
///
/// The companion sends whole messages but never whole chats after creating
/// one: a chat it holds may be stale (pinned, renamed or deleted elsewhere),
/// so it only ever changes the fields it owns, through [setSession] and
/// [setTier]. The
/// sync fields are stamped here, against what's stored.
class GaiaChatStore {
  GaiaChatStore(this._repository, {required this.deviceId});

  final GaiaRepository _repository;

  /// This device, whose native sessions [setSession] records.
  final String deviceId;

  Future<List<GaiaChat>> chats() => _repository.listChats();

  /// Saves a chat the companion just started. A chat already stored is left
  /// as it is.
  Future<void> createChat(GaiaChat chat) async {
    if (await _repository.getChat(chat.id) != null) return;
    await _repository.upsertChat(chat.copyWith(version: 1));
  }

  /// Records the native session [chatId] resumes on this device with
  /// [adapter], and the last message it took part in.
  Future<void> setSession(
    String chatId,
    String sessionId,
    int lastSeq, {
    String adapter = kGaiaClaudeCodeAdapter,
  }) async {
    final chat = await _repository.getChat(chatId);
    if (chat == null) return;
    await _repository.upsertChat(
      chat.copyWith(
        agentSessions: {
          ...chat.agentSessions,
          gaiaSessionKey(deviceId, adapter: adapter): GaiaAgentSession(
            sessionId: sessionId,
            lastSeq: lastSeq,
          ),
        },
      ),
    );
  }

  /// The tier [chatId] now uses (§7.2).
  Future<void> setTier(String chatId, GaiaTier tier) async {
    final chat = await _repository.getChat(chatId);
    if (chat == null || chat.tier == tier) return;
    await _repository.upsertChat(chat.copyWith(tier: tier));
  }

  /// The tier a new chat starts on (§7.2).
  Future<void> setLastTier(GaiaTier tier) async {
    final settings = await _repository.getSettings();
    if (settings.lastTier == tier) return;
    await _repository.upsertSettings(settings.copyWith(lastTier: tier));
  }

  Future<List<GaiaMessage>> messages(String chatId) =>
      _repository.listMessages(chatId);

  /// A message's first write also moves its chat to the top.
  ///
  /// A message erased while its run streams stays erased, as does a chat
  /// erased meanwhile: the run's later writes are dropped, or they'd bring the
  /// erased text back.
  Future<void> putMessage(GaiaMessage message) async {
    final existing = await _repository.getMessage(message.id);
    if (existing != null && existing.isDeleted) return;
    if (isErasedAt((await _repository.getChat(message.chatId))?.deletedAt)) {
      return;
    }
    await _repository.upsertMessage(
      message.copyWith(version: (existing?.version ?? 0) + 1),
    );
    final chat = await _repository.getChat(message.chatId);
    if (chat == null) throw StateError('No chat ${message.chatId}');
    if (message.createdAt.isAfter(chat.lastMessageAt)) {
      await _repository.upsertChat(
        chat.copyWith(lastMessageAt: message.createdAt),
      );
    }
  }

  /// Marks messages a companion left streaming as [status]: the companion
  /// that streamed them is gone, and their runs with it.
  Future<void> endStreaming(GaiaMessageStatus status) =>
      _repository.endStreaming(status);
}
