import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/features/gaia/remote/gaia_device_keys.dart';
import 'package:voyager/features/gaia/remote/gaia_remote.dart';

/// The phone's half of remote use (GAIA_HLD.md §12.2): asks to pair, sends
/// signed commands to a beacon and follows them, and says which chat it's
/// watching so the beacon streams it (§8.1).
class GaiaRemoteClient {
  GaiaRemoteClient({
    required this.firestore,
    required this.uid,
    required this.deviceId,
    required this.key,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final FirebaseFirestore firestore;
  final String uid;
  final String deviceId;
  final GaiaDeviceKey key;
  final DateTime Function() _clock;

  CollectionReference<Map<String, dynamic>> _collection(String name) =>
      firestore.collection('users/$uid/$name');

  String get pairingCode => gaiaPairingCode(key.publicKey);

  /// Writes this device's pairing request (§12.2): its name and public key.
  /// Each desktop that should take its commands trusts it once the user
  /// checks [pairingCode] there.
  Future<void> requestPairing({
    required String name,
    required String platform,
  }) => _collection(FirestoreCollections.gaiaDevices).doc(deviceId).set({
    'deviceId': deviceId,
    'name': name,
    'platform': platform,
    'publicKey': key.publicKey,
    'requestedAt': _clock().millisecondsSinceEpoch,
    // A new request, with a new key, starts from no desktop's trust.
    'trustedBy': <String, Object?>{},
    'revokedAt': null,
  }, SetOptions(merge: true));

  /// Where the `gaiaNotify` Cloud Function sends this device's pushes
  /// (§14). Merged in, so a device that hasn't asked to pair yet keeps no
  /// key, and its document reads as no device.
  Future<void> setFcmToken(String token) => _collection(
    FirestoreCollections.gaiaDevices,
  ).doc(deviceId).set({'fcmToken': token}, SetOptions(merge: true));

  /// Sends [type] to [target], signed. Gives back its id, to [command].
  Future<String> send(
    GaiaRemoteCommandType type, {
    required String target,
    String? chatId,
    Map<String, Object?> payload = const {},
  }) async {
    final id = const Uuid().v4();
    final command = await key.sign(
      GaiaRemoteCommand(
        id: id,
        type: type,
        chatId: chatId,
        payload: payload,
        fromDevice: deviceId,
        targetDevice: target,
        createdAt: _clock().millisecondsSinceEpoch,
      ),
    );
    await _collection(
      FirestoreCollections.gaiaCommands,
    ).doc(id).set(command.toFirestore());
    return id;
  }

  /// Command [id] as it goes: claimed, then done, failed or rejected.
  Stream<GaiaRemoteCommand?> command(String id) =>
      _collection(FirestoreCollections.gaiaCommands).doc(id).snapshots().map((
        doc,
      ) {
        final data = doc.data();
        return data == null
            ? null
            : GaiaRemoteCommand.fromFirestore(doc.id, data);
      });

  /// A settled command is taken off Firestore by its sender.
  Future<void> forget(String id) =>
      _collection(FirestoreCollections.gaiaCommands).doc(id).delete();

  /// [send], followed until it's settled and forgotten; gives back why it
  /// failed, or null once it ran.
  Future<String?> sendAndSettle(
    GaiaRemoteCommandType type, {
    required String target,
  }) async {
    final id = await send(type, target: target);
    final settled = await command(
      id,
    ).firstWhere((command) => command?.settled ?? false);
    unawaited(forget(id).catchError((Object _) {}));
    return settled!.error;
  }

  /// Says this device is watching [chatId], renewing it until the returned
  /// callback stops it (§8.1). A device that dies stops being a watcher
  /// within [kGaiaWatchFor].
  void Function() watch(String chatId) {
    final ref = _collection(FirestoreCollections.gaiaWatch).doc(deviceId);
    void renew() => unawaited(
      ref
          .set({
            'chatId': chatId,
            'expiresAt':
                _clock().millisecondsSinceEpoch + kGaiaWatchFor.inMilliseconds,
          })
          .catchError(
            (Object error) => debugPrint('[gaia] watch not renewed: $error'),
          ),
    );
    renew();
    final timer = Timer.periodic(kGaiaWatchRenewEvery, (_) => renew());
    return () {
      timer.cancel();
      unawaited(ref.delete().catchError((Object _) {}));
    };
  }
}

/// Every desktop's heartbeat (§12.2), as it changes.
Stream<List<GaiaBeacon>> gaiaBeacons(FirebaseFirestore firestore, String uid) =>
    firestore
        .collection('users/$uid/${FirestoreCollections.gaiaBeacons}')
        .snapshots()
        .map(
          (snapshot) => [
            for (final doc in snapshot.docs)
              GaiaBeacon.fromFirestore(doc.id, doc.data()),
          ]..sort((a, b) => a.name.compareTo(b.name)),
        );

/// Every device that asked to pair, newest first.
Stream<List<GaiaDevice>> gaiaDevices(FirebaseFirestore firestore, String uid) =>
    firestore
        .collection('users/$uid/${FirestoreCollections.gaiaDevices}')
        .snapshots()
        .map(
          (snapshot) => [
            for (final doc in snapshot.docs)
              ?GaiaDevice.fromFirestore(doc.id, doc.data()),
          ]..sort((a, b) => b.requestedAt.compareTo(a.requestedAt)),
        );

/// [chatId]'s live text while a beacon streams it to a watcher (§8.1);
/// null when there's none.
Stream<GaiaLive?> gaiaLive(
  FirebaseFirestore firestore,
  String uid,
  String chatId,
) => firestore
    .doc('users/$uid/${FirestoreCollections.gaiaLive}/$chatId')
    .snapshots()
    .map((doc) {
      final data = doc.data();
      return data == null ? null : GaiaLive.fromFirestore(doc.id, data);
    });
