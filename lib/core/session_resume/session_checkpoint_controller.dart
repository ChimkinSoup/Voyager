import 'dart:async';

import 'package:voyager/core/session_resume/session_checkpoint.dart';
import 'package:voyager/core/session_resume/session_checkpoint_store.dart';
import 'package:voyager/core/sync/pending_flush_registry.dart';
import 'package:voyager/core/utils/ids.dart';

/// Debounce before a session reaches disk. The same 400 ms the scratch pad
/// uses — long enough that a burst of typing writes once, short enough that a
/// process death costs at most the last keystrokes.
const kSessionCheckpointDebounce = Duration(milliseconds: 400);

/// One session page's hold on its checkpoint slot.
///
/// Owned by the page, the way the scratch session is: this is the run that is
/// happening now, and it goes when the run does. Nothing watches it from
/// outside — an entry point offers resume by opening the page it always
/// opened, and the page is what finds the file.
class SessionCheckpointController {
  SessionCheckpointController({
    required this.store,
    required this.kind,
    required this.scopeKey,
    required this.build,
  }) : _sessionId = newId(),
       _startedAt = DateTime.now().toUtc() {
    // The app going to the background is an incomplete exit that never reaches
    // dispose — and the process can be killed from there without waking up
    // again, taking a still-pending debounce with it. The same registry the
    // Track and journal drafts use, for the same reason.
    PendingFlushRegistry.instance.register(flush);
  }

  final SessionCheckpointStore store;
  final SessionCheckpointKind kind;
  final String scopeKey;

  /// The session as it stands, or null when there is nothing worth resuming:
  /// a queue that has not been built yet, or one that has been finished. A
  /// null is what clears the slot, which is how reaching the completion screen
  /// ends the checkpoint without a separate call.
  final SessionCheckpoint? Function() build;

  String _sessionId;
  DateTime _startedAt;
  Timer? _debounce;

  /// Reads the slot, adopting the identity of whatever it finds: a resumed run
  /// goes on being the session it was before the app closed.
  Future<SessionCheckpoint?> load() async {
    final loaded = await store.load(kind, scopeKey);
    if (loaded != null) {
      _sessionId = loaded.sessionId;
      _startedAt = loaded.startedAt;
    }
    return loaded;
  }

  /// Wraps the parts the page keeps in the envelope this controller owns.
  SessionCheckpoint envelope({
    Set<String> sourceIds = const {},
    List<String> remainingQueue = const [],
    CramBucketsDto? buckets,
    List<GradeStepDto> graded = const [],
    List<GradeStepDto> undone = const [],
    List<CramBucketsDto> decided = const [],
    List<CramBucketsDto> undoneCram = const [],
    Map<String, dynamic>? scratch,
  }) => SessionCheckpoint(
    kind: kind,
    scopeKey: scopeKey,
    sessionId: _sessionId,
    startedAt: _startedAt,
    updatedAt: DateTime.now().toUtc(),
    // Copied: the page goes on holding the set it passed in.
    sourceIds: {...sourceIds},
    remainingQueue: remainingQueue,
    buckets: buckets,
    graded: graded,
    undone: undone,
    decided: decided,
    undoneCram: undoneCram,
    scratch: scratch,
  );

  /// Records the session as it now stands, once the writes stop coming.
  void persist() {
    _debounce?.cancel();
    _debounce = Timer(kSessionCheckpointDebounce, flush);
  }

  /// Writes whatever is pending right now, ahead of the debounce — every
  /// incomplete exit goes through here.
  Future<void> flush() {
    _debounce?.cancel();
    _debounce = null;
    final checkpoint = build();
    return checkpoint == null
        ? store.clear(kind, scopeKey)
        : store.save(checkpoint);
  }

  /// Throws the run away: Start over opens a session with no history behind
  /// it, so the one it replaces stops being a session at all.
  Future<void> discard() {
    _debounce?.cancel();
    _debounce = null;
    _sessionId = newId();
    _startedAt = DateTime.now().toUtc();
    return store.clear(kind, scopeKey);
  }

  void dispose() {
    PendingFlushRegistry.instance.unregister(flush);
    _debounce?.cancel();
    _debounce = null;
  }
}
