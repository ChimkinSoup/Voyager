// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'package:flutter/foundation.dart';

/// Refusal from [FirestoreWriteGate] when too many writes are already waiting
/// for the server to acknowledge them.
///
/// Deliberately not a [FirebaseException]: `classifySyncFailure` treats
/// anything it doesn't recognise as transient, which is exactly right here.
/// The write is fine, the moment isn't, and the caller's existing failure path
/// puts it on the outbox to be sent again later.
class SyncBackpressureException implements Exception {
  const SyncBackpressureException({
    required this.inFlight,
    required this.limit,
    this.stalled = false,
  });

  /// Writes this session has issued and not yet seen acknowledged.
  final int inFlight;

  /// The ceiling that was hit.
  final int limit;

  /// Whether the gate is shut because a write timed out rather than because
  /// the ordinary ceiling was reached. Reported separately because the two
  /// mean different things: a full gate is a busy connection, a stalled one
  /// is a queue that has stopped moving altogether.
  final bool stalled;

  @override
  String toString() {
    if (stalled) {
      return 'Sync stalled: a write went unacknowledged for '
          '${FirestoreWriteGate.writeTimeout.inSeconds}s and the queue has '
          'not drained since.';
    }
    return 'Sync paused: $inFlight writes are still waiting for the server '
        '(limit $limit).';
  }
}

/// Bounds how many writes the app will hand Firestore before hearing back.
///
/// Firestore accepts a write into its own local queue the moment you call
/// `set` and only completes the future once the server acknowledges it. On a
/// bad connection that future simply never completes, and nothing in the
/// public API reports how deep that queue has become — so an app that keeps
/// writing regardless has no way to notice it is digging. Past some depth the
/// backend starts rejecting the whole write stream with
/// `RESOURCE_EXHAUSTED: Write stream exhausted maximum allowed queued writes`,
/// and from then on *nothing* syncs: the stream reconnects, re-sends the same
/// backlog, is rejected again, and loops. Recovering means clearing the local
/// cache, which throws away every unsent edit in it.
///
/// So the app keeps its own count and stops well short. Refused writes are not
/// lost: every caller already routes a failed upload to [OutboxSyncWorker],
/// which is a queue this code *can* measure, cap and drain in order.
///
/// The count is per-session, which on its own would let a restart-happy
/// afternoon add a fresh allowance to a backlog that never drained. That is
/// what [_startupBacklogLimit] is for — until Firestore confirms the queue it
/// inherited is empty, the gate runs on a much smaller allowance.
///
/// Counting admissions is not enough on its own, because a write handed to a
/// wedged stream never comes back at all: its slot is held for the life of the
/// process, and once every slot is held that way the gate refuses everything
/// forever with no route back. [writeTimeout] is what breaks that — see [run]
/// for what a timeout does, and deliberately does not do.
class FirestoreWriteGate extends ChangeNotifier {
  FirestoreWriteGate({required Future<void> Function() waitForPendingWrites})
    : _waitForPendingWrites = waitForPendingWrites {
    _watchQueueDrain();
  }

  /// Completes once Firestore has acknowledged every write it was holding,
  /// including ones queued by earlier runs of the app — normally
  /// `FirebaseFirestore.waitForPendingWrites`.
  final Future<void> Function() _waitForPendingWrites;

  /// Ceiling once the inherited queue is known to be empty.
  ///
  /// Far below anything the backend objects to. The point is not to ride the
  /// limit but to fail fast enough that the outbox — which survives a restart
  /// and drains in order — takes over long before Firestore's queue is deep
  /// enough to matter.
  static const inFlightLimit = 50;

  /// Ceiling while a queue inherited from an earlier session may still be
  /// unsent. Small, because the writes already down there are invisible to
  /// this count and have to be assumed numerous.
  static const _startupBacklogLimit = 10;

  /// How long a write may go unacknowledged before the gate stops believing it
  /// is on its way.
  ///
  /// Generous on purpose. A healthy acknowledgement lands well inside a second,
  /// so anything past this is not a slow connection but a stopped one, and the
  /// only cost of waiting longer to say so is that the write sits on the outbox
  /// a little longer before being retried.
  static const writeTimeout = Duration(seconds: 45);

  int _inFlight = 0;
  int _peakInFlight = 0;
  int _refusedWrites = 0;
  int _timedOutWrites = 0;

  /// False until Firestore confirms every write it was holding at launch has
  /// been acknowledged. Starts pessimistic: assuming a clean queue is the
  /// assumption that lets a backlog compound across restarts.
  bool _startupBacklogCleared = false;

  /// True from the first write that times out until the queue is next seen to
  /// drain.
  ///
  /// This latch is what keeps the timeout from being worse than the hang it
  /// replaces. Releasing a slot without it would let the gate admit a fresh
  /// batch into the same stopped queue every [writeTimeout] — digging exactly
  /// the hole this class exists to prevent, only more slowly.
  bool _stalled = false;

  /// Writes issued this session and not yet acknowledged.
  int get inFlight => _inFlight;

  /// Highest [inFlight] reached this session, so a burst that has since
  /// drained still shows up in the dev readout.
  int get peakInFlight => _peakInFlight;

  /// How many writes have been refused and sent to the outbox instead.
  int get refusedWrites => _refusedWrites;

  /// How many writes have gone unacknowledged past [writeTimeout].
  int get timedOutWrites => _timedOutWrites;

  /// Whether writes are being refused right now.
  bool get isPaused => _inFlight >= _currentLimit;

  /// Whether the gate is shut because the queue stopped moving, as opposed to
  /// merely being full.
  bool get isStalled => _stalled;

  /// The ceiling in force, which tightens while an inherited queue is unsent
  /// and closes altogether while [_stalled].
  int get _currentLimit {
    if (_stalled) return 0;
    return _startupBacklogCleared ? inFlightLimit : _startupBacklogLimit;
  }

  /// The ceiling in force, for display.
  int get limit => _currentLimit;

  /// Whether a queue left over from an earlier session is still unsent.
  bool get hasStartupBacklog => !_startupBacklogCleared;

  /// Runs [write] unless the backlog is already too deep.
  ///
  /// Throws [SyncBackpressureException] instead of issuing the write when it
  /// is. The counter is released in a `finally` so a rejected write — which
  /// Firestore has already dropped from its queue — doesn't leak a slot.
  ///
  /// A write left unacknowledged for [writeTimeout] throws [TimeoutException]
  /// and latches the gate shut until the queue is seen to drain. Note what the
  /// timeout does *not* do: Firestore offers no way to withdraw a queued write,
  /// so the write is still down there and will still be delivered if the stream
  /// recovers. Giving up on the future only stops this class waiting on it.
  ///
  /// The caller treats the timeout as a transient failure and re-queues the
  /// write on the outbox, so it can be delivered twice. That is safe for both
  /// shapes of write the app makes: mirrored documents are `set(merge: true)`
  /// against a fixed id, and an operation-log entry carries character
  /// operations that `CharacterSequenceCrdtMerger` deduplicates by operation
  /// id — ids that `CharacterOpRegistry.restorePendingOps` hands back
  /// unchanged, so the retry re-sends the same ones rather than minting new
  /// ones at the same positions.
  Future<T> run<T>(Future<T> Function() write) async {
    final limit = _currentLimit;
    if (_inFlight >= limit) {
      _refusedWrites++;
      notifyListeners();
      throw SyncBackpressureException(
        inFlight: _inFlight,
        limit: limit,
        stalled: _stalled,
      );
    }
    _inFlight++;
    if (_inFlight > _peakInFlight) _peakInFlight = _inFlight;
    notifyListeners();
    try {
      return await write().timeout(writeTimeout);
    } on TimeoutException {
      _timedOutWrites++;
      // Only the write that opens a stall arms the probe, so a batch timing
      // out together arms one watcher rather than one each.
      if (!_stalled) {
        _stalled = true;
        _watchQueueDrain();
      }
      rethrow;
    } finally {
      _inFlight--;
      notifyListeners();
    }
  }

  /// Watches for Firestore's queue to drain — at launch, and again after a
  /// stall.
  ///
  /// `waitForPendingWrites` completes when every write Firestore is holding —
  /// including ones queued by previous runs of the app — has been
  /// acknowledged. It is the only reading the SDK offers on a queue this code
  /// did not issue and therefore cannot count, which makes it the right probe
  /// for both questions the gate asks: at construction, whether a backlog was
  /// inherited; after a timeout, whether the stream ever recovered.
  ///
  /// Re-arming it is what lets a stall end without a restart, and nothing else
  /// would. The writes holding the queue open are invisible to [_inFlight], and
  /// the gate cannot tell a recovered stream from a stopped one by attempting a
  /// write, because attempting is the thing that deepens the queue.
  ///
  /// Unawaited on purpose: on a healthy connection it resolves in moments, and
  /// on a wedged one it never resolves at all, which is itself the answer —
  /// and the reason a stall must arm its own probe rather than wait on the one
  /// from launch. In the case this all exists for, that first probe is exactly
  /// the one that is never going to answer.
  void _watchQueueDrain() {
    final Future<void> pending;
    try {
      pending = _waitForPendingWrites();
    } catch (error) {
      // A platform without the call is a platform that cannot tell us, and
      // refusing every write forever is worse than trusting the counter.
      if (kDebugMode) {
        debugPrint('[sync] waitForPendingWrites unavailable: $error');
      }
      _onQueueDrained();
      return;
    }
    unawaited(
      pending.then(
        (_) => _onQueueDrained(),
        // A signed-out user rejects outstanding calls. Nothing is queued for
        // a user who isn't there, so that is a cleared queue too.
        onError: (Object error) {
          if (kDebugMode) {
            debugPrint('[sync] waitForPendingWrites failed: $error');
          }
          _onQueueDrained();
        },
      ),
    );
  }

  /// Firestore is holding nothing: the inherited backlog is gone and whatever
  /// stalled has moved. Both latches come off together because both stand for
  /// that one fact, and this is the direct measurement of it.
  void _onQueueDrained() {
    if (_startupBacklogCleared && !_stalled) return;
    _startupBacklogCleared = true;
    _stalled = false;
    notifyListeners();
  }
}
