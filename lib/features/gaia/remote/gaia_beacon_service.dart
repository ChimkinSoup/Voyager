import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/remote/gaia_device_keys.dart';
import 'package:voyager/features/gaia/remote/gaia_remote.dart';

/// A command a beacon couldn't run, with why, for the phone.
class GaiaRemoteException implements Exception {
  GaiaRemoteException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Runs a verified command and gives back its result, or throws a
/// [GaiaRemoteException].
typedef GaiaCommandRunner =
    Future<Map<String, Object?>?> Function(GaiaRemoteCommand command);

/// The desktop's half of remote use (GAIA_HLD.md §8, §12.2), in the main
/// instance, which has Firestore: the heartbeat that says this desktop is
/// up and what it's running; the paired devices and the keys it pinned for
/// them; the signed commands they send it, claimed one at a time; the live
/// text of a run another device is watching; and each chat's run lease.
///
/// None of it is mirrored in drift: these documents are written in place
/// and read as they are.
class GaiaBeaconService {
  GaiaBeaconService({
    required this.firestore,
    required this.deviceId,
    required this.name,
    required this.adapters,
    required this.trust,
    required this.commandLog,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final FirebaseFirestore firestore;
  final String deviceId;
  final String name;

  /// The CLIs this desktop has, for the phone's tier picker.
  final List<String> adapters;
  final GaiaTrustStore trust;
  final GaiaCommandLog commandLog;
  final DateTime Function() _clock;

  /// Runs a verified command; set by the host.
  GaiaCommandRunner? onCommand;

  /// Every desktop's heartbeat, for the Status tab.
  final beacons = ValueNotifier<List<GaiaBeacon>>(const []);

  /// Every device that asked to pair, for the Status tab.
  final devices = ValueNotifier<List<GaiaDevice>>(const []);

  String? _uid;
  final _subscriptions = <StreamSubscription<Object?>>[];
  Timer? _heartbeat;
  Timer? _renew;

  var _runs = const <({String chatId, String title})>[];
  var _aborted = false;
  var _beaconMode = false;
  var _onBattery = false;
  ({String kind, int at})? _power;

  /// Chats a live device is watching, with when its registration ends.
  final _watched = <String, int>{};

  /// The streaming reply of each running chat, as last saved, for a
  /// watcher who arrives mid-run.
  final _streaming = <String, GaiaMessage>{};

  /// What each chat's live document last got, and when.
  final _live =
      <String, ({String text, String status, String cards, int at})>{};
  final _liveSoon = <String, Timer>{};

  /// Chats this desktop holds the lease of.
  final _leased = <String>{};

  /// Commands seen, so a snapshot that repeats one doesn't run it twice
  /// while its claim is on its way.
  final _seen = <String>{};

  /// Gaia's writes today (§8.2): past [kLiveWriteBudget], live text stops.
  var _writesDay = '';
  var _writes = 0;
  static const kLiveWriteBudget = 15000;
  bool get livePaused => _writes >= kLiveWriteBudget;

  String get _root => 'users/$_uid';

  CollectionReference<Map<String, dynamic>> _collection(String name) =>
      firestore.collection('$_root/$name');

  /// Starts or stops with the signed-in account; null signs out.
  Future<void> setUser(String? uid) async {
    if (uid == _uid) return;
    await _stop(goingOffline: _uid != null);
    _uid = uid;
    if (uid == null) return;
    _subscriptions
      ..add(
        _collection(FirestoreCollections.gaiaBeacons).snapshots().listen(
          (snapshot) => beacons.value = [
            for (final doc in snapshot.docs)
              GaiaBeacon.fromFirestore(doc.id, doc.data()),
          ],
          onError: _logError('beacons'),
        ),
      )
      ..add(
        _collection(FirestoreCollections.gaiaDevices).snapshots().listen(
          (snapshot) => unawaited(_onDevices(snapshot)),
          onError: _logError('devices'),
        ),
      )
      ..add(
        _collection(FirestoreCollections.gaiaRevoked).snapshots().listen(
          (snapshot) => unawaited(_onRevoked(snapshot)),
          onError: _logError('revoked keys'),
        ),
      )
      ..add(
        _collection(FirestoreCollections.gaiaCommands)
            .where('targetDevice', isEqualTo: deviceId)
            .where('status', isEqualTo: GaiaRemoteCommandStatus.pending.name)
            .snapshots()
            .listen(
              (snapshot) => unawaited(_onCommands(snapshot)),
              onError: _logError('commands'),
            ),
      )
      ..add(
        _collection(
          FirestoreCollections.gaiaWatch,
        ).snapshots().listen(_onWatchers, onError: _logError('watchers')),
      );
    _heartbeat = Timer.periodic(kGaiaHeartbeatEvery, (_) => _beat());
    _renew = Timer.periodic(kGaiaLeaseRenewEvery, (_) {
      unawaited(renewLeases());
      notifyLapsedWatchers();
    });
    _beat();
  }

  void Function(Object error) _logError(String what) =>
      (error) => debugPrint('[gaia] beacon $what: $error');

  /// Says this desktop is going, and stops listening.
  Future<void> dispose() => _stop(goingOffline: true);

  Future<void> _stop({required bool goingOffline}) async {
    _heartbeat?.cancel();
    _renew?.cancel();
    for (final timer in _liveSoon.values) {
      timer.cancel();
    }
    _liveSoon.clear();
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
    if (_uid == null) return;
    final live = [..._live.keys];
    _live.clear();
    final leased = [..._leased];
    _leased.clear();
    try {
      await Future.wait([
        for (final chatId in live) _deleteLive(chatId),
        for (final chatId in leased) _release(chatId),
        if (goingOffline)
          _collection(FirestoreCollections.gaiaBeacons).doc(deviceId).set({
            'heartbeatAt': 0,
            'runs': const <Object?>[],
          }, SetOptions(merge: true)),
      ]).timeout(const Duration(seconds: 2));
    } catch (error) {
      debugPrint('[gaia] beacon not stopped cleanly: $error');
    }
  }

  void _count([int writes = 1]) {
    final now = _clock();
    final day = '${now.year}-${now.month}-${now.day}';
    if (day != _writesDay) {
      _writesDay = day;
      _writes = 0;
    }
    final wasPaused = livePaused;
    _writes += writes;
    if (livePaused && !wasPaused) _beat();
  }

  /// Whether the desktop is unplugged, read at each heartbeat (§12.1).
  bool Function()? onBatteryNow;

  void _beat() {
    if (_uid == null) return;
    _onBattery = onBatteryNow?.call() ?? _onBattery;
    _count();
    unawaited(
      _collection(FirestoreCollections.gaiaBeacons)
          .doc(deviceId)
          .set({
            'deviceId': deviceId,
            'name': name,
            'heartbeatAt': _clock().millisecondsSinceEpoch,
            'adapters': adapters,
            'runs': [
              for (final run in _runs)
                {'chatId': run.chatId, 'title': run.title},
            ],
            'aborted': _aborted,
            'beaconMode': _beaconMode,
            'onBattery': _onBattery,
            'livePaused': livePaused,
            'power': _power == null
                ? null
                : {'kind': _power!.kind, 'at': _power!.at},
          })
          .catchError((Object error) => _logError('heartbeat')(error)),
    );
  }

  /// The companion's runs changed: the heartbeat says so at once, and a
  /// chat no longer running lets its lease go.
  void setRuns(List<({String chatId, String title})> runs) {
    final running = {for (final run in runs) run.chatId};
    for (final chatId in [..._leased]) {
      if (!running.contains(chatId)) unawaited(releaseLease(chatId));
    }
    for (final chatId in [..._streaming.keys]) {
      if (!running.contains(chatId)) _endLive(chatId);
    }
    _runs = runs;
    _beat();
  }

  void setAborted(bool aborted) {
    if (aborted == _aborted) return;
    _aborted = aborted;
    _beat();
  }

  void setBeaconMode({required bool on, required bool onBattery}) {
    if (on == _beaconMode && onBattery == _onBattery) return;
    _beaconMode = on;
    _onBattery = onBattery;
    _beat();
  }

  void setPower(({String kind, int at})? power) {
    _power = power;
    _beat();
  }

  // Devices and pairing.

  Future<void> _onDevices(QuerySnapshot<Map<String, dynamic>> snapshot) async {
    final list = [
      for (final doc in snapshot.docs)
        ?GaiaDevice.fromFirestore(doc.id, doc.data()),
    ]..sort((a, b) => b.requestedAt.compareTo(a.requestedAt));
    // A device revoked on any desktop is revoked here, for good: the key
    // pinned for it, and the one its document shows.
    for (final device in list) {
      if (!device.revoked) continue;
      if (trust.trusted[device.deviceId] case final pinned?) {
        await trust.revoke(pinned);
      }
      await trust.revoke(device.publicKey);
    }
    devices.value = list;
  }

  /// Keys revoked on any desktop, however long this one was off: unlike a
  /// device's document, this list keeps them through a Remove or a new
  /// pairing.
  Future<void> _onRevoked(QuerySnapshot<Map<String, dynamic>> snapshot) async {
    for (final doc in snapshot.docs) {
      if (doc.data()['publicKey'] case final String key) {
        await trust.revoke(key);
      }
    }
    devices.value = [...devices.value];
  }

  /// Whether commands from [device] are taken here: its key is the one
  /// pinned for it.
  bool trusts(GaiaDevice device) =>
      !device.revoked && trust.keyOf(device.deviceId) == device.publicKey;

  /// A key turned down or revoked here: it's never trusted again, and the
  /// phone pairs with a new one once its request is removed.
  bool refuses(GaiaDevice device) => trust.revoked.contains(device.publicKey);

  /// The user confirmed [device]'s pairing code on this desktop.
  Future<void> trustDevice(GaiaDevice device) async {
    // Unpinned, so nothing may say this desktop trusts it.
    if (refuses(device)) return;
    await trust.trust(device.deviceId, device.publicKey);
    _count();
    await _collection(
      FirestoreCollections.gaiaDevices,
    ).doc(device.deviceId).set({
      'trustedBy': {deviceId: _clock().millisecondsSinceEpoch},
    }, SetOptions(merge: true));
    devices.value = [...devices.value];
  }

  /// Revoked here and, through its document, on every other desktop.
  Future<void> revokeDevice(GaiaDevice device) async {
    final keys = {?trust.trusted[device.deviceId], device.publicKey};
    for (final key in keys) {
      await trust.revoke(key);
    }
    final at = _clock().millisecondsSinceEpoch;
    final batch = firestore.batch()
      ..set(
        _collection(FirestoreCollections.gaiaDevices).doc(device.deviceId),
        {'revokedAt': at},
        SetOptions(merge: true),
      );
    for (final key in keys) {
      batch.set(
        _collection(FirestoreCollections.gaiaRevoked).doc(gaiaRevokedId(key)),
        {'publicKey': key, 'revokedAt': at},
      );
    }
    _count(1 + keys.length);
    await batch.commit();
  }

  /// A request turned down, or a revoked device cleared from the list.
  Future<void> forgetDevice(GaiaDevice device) async {
    if (!device.revoked) await trust.revoke(device.publicKey);
    _count();
    await _collection(
      FirestoreCollections.gaiaDevices,
    ).doc(device.deviceId).delete();
  }

  // Commands.

  Future<void> _onCommands(QuerySnapshot<Map<String, dynamic>> snapshot) async {
    for (final doc in snapshot.docs) {
      if (!_seen.add(doc.id)) continue;
      final command = GaiaRemoteCommand.fromFirestore(doc.id, doc.data());
      unawaited(_handle(doc.reference, command));
    }
  }

  Future<void> _handle(
    DocumentReference<Map<String, dynamic>> ref,
    GaiaRemoteCommand? command,
  ) async {
    Future<void> settle(
      GaiaRemoteCommandStatus status, {
      String? error,
      Map<String, Object?>? result,
    }) async {
      _count();
      try {
        await ref.set({
          'status': status.name,
          'error': error,
          'result': result,
          'claimedBy': deviceId,
          'settledAt': _clock().millisecondsSinceEpoch,
        }, SetOptions(merge: true));
      } catch (error) {
        debugPrint('[gaia] command ${ref.id} not settled: $error');
      }
    }

    if (command == null) {
      return settle(
        GaiaRemoteCommandStatus.rejected,
        error:
            'This desktop runs an older Voyager that does not know that '
            'command.',
      );
    }
    // Only a key pinned here verifies: Firestore's copy of the device's
    // key is anyone's who can write there.
    final key = trust.keyOf(command.fromDevice);
    if (key == null || !await gaiaVerifyCommand(command, key)) {
      debugPrint(
        '[gaia] command ${command.id} refused: not signed by a '
        'device paired here',
      );
      return settle(
        GaiaRemoteCommandStatus.rejected,
        error:
            'This device is not paired with $name. Pair it on its Gaia '
            'page.',
      );
    }
    // Either way: a command dated ahead would stay fresh for too long.
    final age = _clock().millisecondsSinceEpoch - command.createdAt;
    if (age.abs() > kGaiaCommandMaxAge.inMilliseconds) {
      return settle(
        GaiaRemoteCommandStatus.rejected,
        error:
            'It reached $name too late to run, or this device and $name '
            'disagree about the time.',
      );
    }
    // Its signature is still good, so only this says it isn't new.
    if (commandLog.hasRun(command.id)) {
      debugPrint('[gaia] command ${command.id} refused: already run');
      return settle(
        GaiaRemoteCommandStatus.rejected,
        error: '$name already ran this command.',
      );
    }
    // From the server, not the list as last heard: a desktop just back on
    // can meet a pending command before it hears the key was revoked.
    try {
      final revoked = await _collection(
        FirestoreCollections.gaiaRevoked,
      ).doc(gaiaRevokedId(key)).get(const GetOptions(source: Source.server));
      if (revoked.exists) {
        await trust.revoke(key);
        debugPrint('[gaia] command ${command.id} refused: its key is revoked');
        return settle(
          GaiaRemoteCommandStatus.rejected,
          error:
              'This device is not paired with $name. Pair it on its Gaia '
              'page.',
        );
      }
    } catch (error) {
      debugPrint('[gaia] command ${command.id} not checked: $error');
      _seen.remove(command.id);
      return;
    }
    // Claimed in a transaction: a command runs once, here or nowhere.
    try {
      _count();
      final claimed = await firestore.runTransaction((tx) async {
        final current = await tx.get(ref);
        if (current.data()?['status'] != GaiaRemoteCommandStatus.pending.name) {
          return false;
        }
        tx.update(ref, {
          'status': GaiaRemoteCommandStatus.claimed.name,
          'claimedBy': deviceId,
        });
        return true;
      });
      if (!claimed) return;
    } catch (error) {
      debugPrint('[gaia] command ${command.id} not claimed: $error');
      _seen.remove(command.id);
      return;
    }
    try {
      // Before it runs: a crash mid-run mustn't let a copy run it again.
      await commandLog.add(command);
      final result =
          await (onCommand ?? (throw GaiaRemoteException('Gaia is starting.')))(
            command,
          );
      // What this chat does next is the phone's to hear about (§14).
      if (command.chatId case final chatId?
          when command.type == GaiaRemoteCommandType.prompt ||
              command.type == GaiaRemoteCommandType.answer ||
              command.type == GaiaRemoteCommandType.queuePop) {
        _remoteChats[chatId] = command.fromDevice;
      }
      await settle(GaiaRemoteCommandStatus.done, result: result);
    } on GaiaRemoteException catch (error) {
      await settle(GaiaRemoteCommandStatus.failed, error: error.message);
    } catch (error) {
      await settle(GaiaRemoteCommandStatus.failed, error: '$error');
    }
  }

  // Live streaming (§8.1).

  void _onWatchers(QuerySnapshot<Map<String, dynamic>> snapshot) {
    final was = {..._watched.keys};
    _watched.clear();
    for (final doc in snapshot.docs) {
      final data = doc.data();
      final chatId = data['chatId'];
      final expiresAt = (data['expiresAt'] as num?)?.toInt() ?? 0;
      if (chatId is! String || doc.id == deviceId) continue;
      if (expiresAt > (_watched[chatId] ?? 0)) _watched[chatId] = expiresAt;
    }
    // One catch-up write for a chat that's newly watched mid-run.
    for (final chatId in _watched.keys) {
      if (was.contains(chatId)) continue;
      if (_streaming[chatId] case final message?) {
        _live.remove(chatId);
        _writeLive(message);
      }
    }
    // A card the phone was shown, then left: it's still waiting on them.
    for (final chatId in was) {
      if (_watched.containsKey(chatId)) continue;
      if (_streaming[chatId] case final message?) _notifyFor(message);
    }
  }

  bool _isWatched(String chatId) =>
      (_watched[chatId] ?? 0) > _clock().millisecondsSinceEpoch;

  /// Every save of a reply, as the companion makes them while it streams
  /// (about one a second) and once it's done.
  void onMessage(GaiaMessage message) {
    if (message.role != GaiaMessageRole.assistant) return;
    _notifyFor(message);
    if (message.status != GaiaMessageStatus.streaming) {
      return _endLive(message.chatId);
    }
    _streaming[message.chatId] = message;
    if (_isWatched(message.chatId)) _writeLive(message);
  }

  // Push notifications (§14).

  /// A phone that died or lost its signal never deletes its watch, so no
  /// snapshot says it left: its open cards, and a reply that ended while it
  /// stood, notify once the watch runs out.
  void notifyLapsedWatchers() {
    for (final message in [..._streaming.values]) {
      _notifyFor(message);
    }
    for (final MapEntry(key: chatId, value: ended)
        in _endedWatched.entries.toList()) {
      if (_watched[chatId] != ended.watchEnds) {
        // Renewed, or deleted on leaving: that phone was alive and saw it.
        _endedWatched.remove(chatId);
      } else if (!_isWatched(chatId)) {
        _endedWatched.remove(chatId);
        _notifyFor(ended.message);
      }
    }
  }

  /// Replies that ended under a watch, with when that watch ends: whether
  /// the phone saw them depends on whether it renews.
  final _endedWatched = <String, ({GaiaMessage message, int watchEnds})>{};

  /// Chats a phone sent the last prompt or answer to, with which phone:
  /// their replies and cards notify it.
  final _remoteChats = <String, String>{};

  /// This desktop's user sent the last prompt to [chatId], not a phone.
  void onLocalRun(String chatId) => _remoteChats.remove(chatId);

  /// Cards already notified, and replies already notified as finished.
  final _notified = <String>{};

  /// A reply in a chat a phone is driving that finished, or raised a card,
  /// while nobody watches it: one `gaia_notify` document, which a Cloud
  /// Function sends as a push and deletes.
  void _notifyFor(GaiaMessage message) {
    final toDevice = _remoteChats[message.chatId];
    if (toDevice == null || _uid == null) return;
    for (final card in message.parts.whereType<GaiaCardPart>()) {
      if (!card.isOpen || _isWatched(message.chatId)) continue;
      if (!_notified.add(card.id)) continue;
      _writeNotify(
        message.chatId,
        toDevice,
        kind: card.kind == GaiaCardKind.question ? 'question' : 'card',
        title: switch (card.kind) {
          GaiaCardKind.question => 'Gaia has a question',
          GaiaCardKind.permission => 'Gaia asks to use ${card.tool}',
          GaiaCardKind.proposal => 'Gaia proposes a change',
        },
        text: card.kind == GaiaCardKind.question ? card.question : name,
      );
    }
    if (message.status == GaiaMessageStatus.streaming) return;
    if (_isWatched(message.chatId)) {
      _endedWatched[message.chatId] = (
        message: message,
        watchEnds: _watched[message.chatId]!,
      );
      return;
    }
    if (!_notified.add(message.id)) return;
    final firstLine = message.text.trim().split('\n').first;
    _writeNotify(
      message.chatId,
      toDevice,
      kind: message.needsInput ? 'question' : 'done',
      title: switch (message.status) {
        GaiaMessageStatus.complete when message.needsInput =>
          'Gaia has a question',
        GaiaMessageStatus.complete => 'Gaia replied',
        GaiaMessageStatus.error => 'Gaia ran into an error',
        _ => 'Gaia stopped',
      },
      text: firstLine.length > 200
          ? '${firstLine.substring(0, 200)}…'
          : firstLine.isEmpty
          ? 'On $name'
          : firstLine,
    );
  }

  void _writeNotify(
    String chatId,
    String toDevice, {
    required String kind,
    required String title,
    required String text,
  }) {
    _count();
    unawaited(
      _collection(FirestoreCollections.gaiaNotify)
          .add({
            'chatId': chatId,
            'kind': kind,
            'title': title,
            'text': text,
            'toDevice': toDevice,
            'fromBeacon': deviceId,
            'createdAt': _clock().millisecondsSinceEpoch,
          })
          .then<void>((_) {})
          .catchError((Object error) => _logError('notify')(error)),
    );
  }

  /// Messages a gone companion left streaming.
  void endAllLive() {
    for (final chatId in [..._streaming.keys, ..._live.keys]) {
      _endLive(chatId);
    }
  }

  void _endLive(String chatId) {
    _streaming.remove(chatId);
    _liveSoon.remove(chatId)?.cancel();
    if (_live.remove(chatId) != null) unawaited(_deleteLive(chatId));
  }

  Future<void> _deleteLive(String chatId) async {
    if (_uid == null) return;
    _count();
    try {
      await _collection(FirestoreCollections.gaiaLive).doc(chatId).delete();
    } catch (error) {
      debugPrint('[gaia] live $chatId not deleted: $error');
    }
  }

  /// Text at most once a second; a status line alone at most every 30 s
  /// (§8.1); a card opened or decided at once, since a tool call waits on
  /// it.
  void _writeLive(GaiaMessage message) {
    if (_uid == null) return;
    final chatId = message.chatId;
    final now = _clock().millisecondsSinceEpoch;
    final text = message.text;
    final status = gaiaLiveStatus(message, _clock());
    final cards = [
      for (final card in message.parts.whereType<GaiaCardPart>())
        if (card.isOpen) card.toJson(),
    ];
    final cardsKey = gaiaCanonicalJson(cards);
    final last = _live[chatId];
    // Past the budget only cards go: a tool call waits on them.
    if (livePaused && (last?.cards ?? '[]') == cardsKey) return;
    if (last != null && last.cards == cardsKey) {
      if (last.text == text && last.status == status) return;
      final wait = last.text == text
          ? const Duration(seconds: 30)
          : const Duration(seconds: 1);
      final due = last.at + wait.inMilliseconds - now;
      if (due > 0) {
        _liveSoon[chatId] ??= Timer(Duration(milliseconds: due), () {
          _liveSoon.remove(chatId);
          if (_streaming[chatId] case final latest?) _writeLive(latest);
        });
        return;
      }
    }
    _liveSoon.remove(chatId)?.cancel();
    _live[chatId] = (text: text, status: status, cards: cardsKey, at: now);
    _count();
    unawaited(
      _collection(FirestoreCollections.gaiaLive)
          .doc(chatId)
          .set({
            'messageId': message.id,
            'beacon': deviceId,
            'text': text,
            'status': status,
            'cards': cards,
            'seq': message.seq,
            'updatedAt': now,
          })
          .catchError((Object error) => _logError('live')(error)),
    );
  }

  // Run leases (§8).

  /// Takes [chatId]'s lease for a run here. Null when it's this desktop's
  /// now; else the name of the device running it. Offline, or signed out,
  /// the run goes ahead: Gaia is local first.
  Future<String?> takeLease(String chatId) async {
    if (_uid == null) return null;
    final ref = _collection(FirestoreCollections.gaiaLeases).doc(chatId);
    try {
      _count();
      final holder = await firestore
          .runTransaction<String?>((tx) async {
            final current = (await tx.get(ref)).data();
            final now = _clock().millisecondsSinceEpoch;
            final heldBy = current?['deviceId'];
            final expiresAt = (current?['expiresAt'] as num?)?.toInt() ?? 0;
            if (heldBy is String && heldBy != deviceId && expiresAt > now) {
              return heldBy;
            }
            tx.set(ref, {
              'deviceId': deviceId,
              'expiresAt': now + kGaiaLeaseFor.inMilliseconds,
            });
            return null;
          })
          .timeout(const Duration(seconds: 5));
      if (holder == null) {
        _leased.add(chatId);
        return null;
      }
      return beacons.value
              .where((beacon) => beacon.deviceId == holder)
              .firstOrNull
              ?.name ??
          'another device';
    } catch (error) {
      debugPrint('[gaia] lease of $chatId not checked ($error), running');
      return null;
    }
  }

  Future<void> releaseLease(String chatId) async {
    if (!_leased.remove(chatId)) return;
    await _release(chatId);
  }

  Future<void> _release(String chatId) async {
    if (_uid == null) return;
    final ref = _collection(FirestoreCollections.gaiaLeases).doc(chatId);
    try {
      _count(2);
      await firestore.runTransaction((tx) async {
        if ((await tx.get(ref)).data()?['deviceId'] == deviceId) {
          tx.delete(ref);
        }
      });
    } catch (error) {
      debugPrint('[gaia] lease of $chatId not released: $error');
    }
  }

  /// Each lease held here, as [takeLease] would: one that ran out while this
  /// desktop slept, and that another device took since, is that device's.
  Future<void> renewLeases() async {
    if (_uid == null) return;
    await Future.wait([
      for (final chatId in [..._leased]) _renewLease(chatId),
    ]);
  }

  Future<void> _renewLease(String chatId) async {
    final ref = _collection(FirestoreCollections.gaiaLeases).doc(chatId);
    try {
      _count(2);
      final lost = await firestore.runTransaction<bool>((tx) async {
        final current = (await tx.get(ref)).data();
        final now = _clock().millisecondsSinceEpoch;
        final heldBy = current?['deviceId'];
        final expiresAt = (current?['expiresAt'] as num?)?.toInt() ?? 0;
        if (heldBy is String && heldBy != deviceId && expiresAt > now) {
          return true;
        }
        tx.set(ref, {
          'deviceId': deviceId,
          'expiresAt': now + kGaiaLeaseFor.inMilliseconds,
        });
        return false;
      });
      if (lost) {
        debugPrint('[gaia] lease of $chatId was taken while it had run out');
        _leased.remove(chatId);
      }
    } catch (error) {
      _logError('lease')(error);
    }
  }
}

/// The live document's status line (§8.1) while [message] runs tools:
/// "Working · 37 tool calls · 12 min · Bash". Empty while it writes text.
/// Never what a tool was given or gave back.
String gaiaLiveStatus(GaiaMessage message, DateTime now) {
  final last = message.parts.lastOrNull;
  if (last is! GaiaActivityPart) return '';
  final calls = message.parts.whereType<GaiaActivityPart>().fold(
    0,
    (total, part) => total + part.tools.length,
  );
  final minutes = now.difference(message.createdAt).inMinutes;
  return [
    'Working',
    calls == 1 ? '1 tool call' : '$calls tool calls',
    if (minutes > 0) '$minutes min',
    ?last.tools.lastOrNull,
  ].join(' · ');
}
