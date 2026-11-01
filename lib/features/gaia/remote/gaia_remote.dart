/// Gaia's remote use (GAIA_HLD.md §12.2): what a beacon, a paired device
/// and a signed command look like in Firestore, shared by the desktop that
/// runs commands and the phone that sends them.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:voyager/domain/models/gaia_models.dart';

/// How often a beacon says it's up, and how long without one counts as
/// offline (§12.2).
const kGaiaHeartbeatEvery = Duration(minutes: 2);
const kGaiaOfflineAfter = Duration(minutes: 5);

/// How long a watcher's registration lasts, and how often a watching device
/// renews it (§8.1).
const kGaiaWatchFor = Duration(seconds: 60);
const kGaiaWatchRenewEvery = Duration(seconds: 30);

/// A run lease's life, and how often its holder renews it (§8).
const kGaiaLeaseFor = Duration(minutes: 3);
const kGaiaLeaseRenewEvery = Duration(minutes: 1);

/// How old a command may be when a beacon first sees it. Older ones are
/// refused: a beacon that was asleep shouldn't run what was asked of it
/// hours ago.
const kGaiaCommandMaxAge = Duration(minutes: 10);

/// What a command asks a beacon to do (§12.2).
enum GaiaRemoteCommandType {
  /// `{text, tier?, isNew, title?}`: a message in `chatId`, a new chat when
  /// `isNew`.
  prompt,

  /// `{cardId, decision, selected?, text?}`: an open card in `chatId`
  /// answered, `decision` one of `accept`, `reject`.
  answer,

  /// Stops `chatId`'s run.
  cancel,
  abort,
  rearm,

  /// `{queueId?}`: the next item of `chatId`'s queue sent (§13).
  queuePop,

  /// Puts the beacon to sleep or shuts it down after a 30 s countdown the
  /// desktop can cancel; `cancelPower` cancels it from the phone (§12.2).
  sleep,
  shutdown,
  cancelPower,
}

GaiaRemoteCommandType? gaiaCommandTypeFromName(Object? name) =>
    GaiaRemoteCommandType.values.where((type) => type.name == name).firstOrNull;

enum GaiaRemoteCommandStatus { pending, claimed, done, failed, rejected }

GaiaRemoteCommandStatus gaiaCommandStatusFromName(Object? name) =>
    GaiaRemoteCommandStatus.values.where((s) => s.name == name).firstOrNull ??
    GaiaRemoteCommandStatus.pending;

/// A command as the phone writes it to `gaia_commands/{id}`: the fields
/// [signedBytes] covers, plus its signature, which a beacon checks against
/// the key it pinned when the device was paired.
class GaiaRemoteCommand {
  const GaiaRemoteCommand({
    required this.id,
    required this.type,
    required this.fromDevice,
    required this.createdAt,
    this.chatId,
    this.targetDevice,
    this.payload = const {},
    this.signature = '',
    this.status = GaiaRemoteCommandStatus.pending,
    this.claimedBy,
    this.error,
    this.result,
  });

  final String id;
  final GaiaRemoteCommandType type;
  final String? chatId;
  final Map<String, Object?> payload;
  final String fromDevice;

  /// The beacon that must run it; null for any online one.
  final String? targetDevice;

  /// Milliseconds since the epoch, on the sender's clock.
  final int createdAt;

  /// Base64 Ed25519 over [signedBytes].
  final String signature;
  final GaiaRemoteCommandStatus status;
  final String? claimedBy;
  final String? error;
  final Map<String, Object?>? result;

  bool get settled =>
      status == GaiaRemoteCommandStatus.done ||
      status == GaiaRemoteCommandStatus.failed ||
      status == GaiaRemoteCommandStatus.rejected;

  /// What the signature covers: everything that says what to do, where and
  /// for whom, the id included, so a copy under another id doesn't verify.
  Uint8List get signedBytes => Uint8List.fromList(
    utf8.encode(
      gaiaCanonicalJson({
        'id': id,
        'type': type.name,
        'chatId': chatId,
        'payload': payload,
        'fromDevice': fromDevice,
        'targetDevice': targetDevice,
        'createdAt': createdAt,
      }),
    ),
  );

  GaiaRemoteCommand signed(String signature) => GaiaRemoteCommand(
    id: id,
    type: type,
    chatId: chatId,
    payload: payload,
    fromDevice: fromDevice,
    targetDevice: targetDevice,
    createdAt: createdAt,
    signature: signature,
  );

  Map<String, Object?> toFirestore() => {
    'id': id,
    'type': type.name,
    'chatId': chatId,
    'payload': payload,
    'fromDevice': fromDevice,
    'targetDevice': targetDevice,
    'createdAt': createdAt,
    'signature': signature,
    'status': status.name,
  };

  /// Null for a document this build can't read: a type it doesn't know.
  static GaiaRemoteCommand? fromFirestore(
    String id,
    Map<String, Object?> data,
  ) {
    final type = gaiaCommandTypeFromName(data['type']);
    if (type == null) return null;
    return GaiaRemoteCommand(
      id: id,
      type: type,
      chatId: data['chatId'] as String?,
      payload: (data['payload'] as Map?)?.cast<String, Object?>() ?? const {},
      fromDevice: data['fromDevice'] as String? ?? '',
      targetDevice: data['targetDevice'] as String?,
      createdAt: (data['createdAt'] as num?)?.toInt() ?? 0,
      signature: data['signature'] as String? ?? '',
      status: gaiaCommandStatusFromName(data['status']),
      claimedBy: data['claimedBy'] as String?,
      error: data['error'] as String?,
      result: (data['result'] as Map?)?.cast<String, Object?>(),
    );
  }
}

/// [value] as JSON with every map's keys sorted, so the same command
/// encodes to the same bytes on every device.
String gaiaCanonicalJson(Object? value) => jsonEncode(_sorted(value));

Object? _sorted(Object? value) => switch (value) {
  final Map<Object?, Object?> map => {
    for (final key in map.keys.map((k) => '$k').toList()..sort())
      key: _sorted(map[key]),
  },
  final List<Object?> list => [for (final item in list) _sorted(item)],
  _ => value,
};

/// The code both sides of a pairing show (§12.2), from the device's public
/// key: the user checks they match before the desktop trusts it, so a
/// request someone else wrote can't be mistaken for their phone's. 80 bits
/// (16 characters, none easily misread), since whoever can write to the
/// user's Firestore can search for a key of their own showing the same code,
/// and a shorter one is within reach of that search.
String gaiaPairingCode(String publicKey) {
  const alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
  final digest = sha256.convert(base64Decode(publicKey)).bytes;
  final code = StringBuffer();
  for (var i = 0; i < 16; i++) {
    if (i > 0 && i % 4 == 0) code.write(' ');
    // Five bits at a time, from the top of the hash.
    final bit = i * 5;
    final pair = (digest[bit ~/ 8] << 8) | digest[bit ~/ 8 + 1];
    code.write(alphabet[(pair >> (11 - bit % 8)) & 31]);
  }
  return '$code';
}

/// [publicKey]'s document in `gaia_revoked`. A hash: a key can hold a `/`, and
/// the one a device's document shows can be anything.
String gaiaRevokedId(String publicKey) =>
    sha256.convert(utf8.encode(publicKey)).toString();

/// A desktop as its heartbeat describes it (§12.2), from
/// `gaia_beacons/{deviceId}`.
class GaiaBeacon {
  const GaiaBeacon({
    required this.deviceId,
    required this.name,
    required this.heartbeatAt,
    this.adapters = const [],
    this.runs = const [],
    this.aborted = false,
    this.beaconMode = false,
    this.onBattery = false,
    this.livePaused = false,
    this.power,
  });

  final String deviceId;
  final String name;

  /// Milliseconds since the epoch; 0 once it said it was going.
  final int heartbeatAt;

  /// The CLIs it can run (`kGaia…Adapter` ids).
  final List<String> adapters;
  final List<({String chatId, String title})> runs;
  final bool aborted;
  final bool beaconMode;

  /// Unplugged: the lid still sleeps it (§12.1).
  final bool onBattery;

  /// Past the day's write budget: no live text until tomorrow (§8.2).
  final bool livePaused;

  /// A sleep or shutdown counting down: `{kind, at}`, `at` in ms.
  final ({String kind, int at})? power;

  bool onlineAt(DateTime now) =>
      heartbeatAt > 0 &&
      now.millisecondsSinceEpoch - heartbeatAt <
          kGaiaOfflineAfter.inMilliseconds;

  bool isRunning(String chatId) => runs.any((run) => run.chatId == chatId);

  static GaiaBeacon fromFirestore(String id, Map<String, Object?> data) =>
      GaiaBeacon(
        deviceId: id,
        name: data['name'] as String? ?? id,
        heartbeatAt: (data['heartbeatAt'] as num?)?.toInt() ?? 0,
        adapters: [...?(data['adapters'] as List?)?.cast<String>()],
        runs: [
          for (final run in (data['runs'] as List?) ?? const [])
            if (run case {'chatId': final String chatId})
              (chatId: chatId, title: run['title'] as String? ?? ''),
        ],
        aborted: data['aborted'] == true,
        beaconMode: data['beaconMode'] == true,
        onBattery: data['onBattery'] == true,
        livePaused: data['livePaused'] == true,
        power: switch (data['power']) {
          {'kind': final String kind, 'at': final num at} => (
            kind: kind,
            at: at.toInt(),
          ),
          _ => null,
        },
      );
}

/// A device that asked to send commands (§12.2), from
/// `gaia_devices/{deviceId}`. Firestore's copy is a request: a beacon
/// trusts only the key it pinned when the user confirmed [code] on it.
class GaiaDevice {
  const GaiaDevice({
    required this.deviceId,
    required this.name,
    required this.publicKey,
    required this.platform,
    this.requestedAt = 0,
    this.trustedBy = const {},
    this.revokedAt,
    this.fcmToken,
  });

  final String deviceId;
  final String name;

  /// Base64 Ed25519 public key.
  final String publicKey;
  final String platform;
  final int requestedAt;

  /// The desktops that pinned its key, by device id, with when.
  final Map<String, int> trustedBy;
  final int? revokedAt;
  final String? fcmToken;

  bool get revoked => revokedAt != null;

  String get code => gaiaPairingCode(publicKey);

  static GaiaDevice? fromFirestore(String id, Map<String, Object?> data) {
    final key = data['publicKey'];
    if (key is! String || key.isEmpty) return null;
    return GaiaDevice(
      deviceId: id,
      name: data['name'] as String? ?? 'Device',
      publicKey: key,
      platform: data['platform'] as String? ?? '',
      requestedAt: (data['requestedAt'] as num?)?.toInt() ?? 0,
      trustedBy: {
        for (final MapEntry(:key, :value)
            in ((data['trustedBy'] as Map?) ?? const {}).entries)
          if (value is num) '$key': value.toInt(),
      },
      revokedAt: (data['revokedAt'] as num?)?.toInt(),
      fcmToken: data['fcmToken'] as String?,
    );
  }
}

/// A watched run's text so far (§8.1), from `gaia_live/{chatId}`.
class GaiaLive {
  const GaiaLive({
    required this.chatId,
    required this.messageId,
    required this.text,
    required this.status,
    required this.updatedAt,
    this.cards = const [],
  });

  final String chatId;
  final String messageId;
  final String text;

  /// "Working · 37 tool calls · 12 min · Bash", or empty while it writes.
  final String status;
  final int updatedAt;

  /// The reply's open cards (§10): the phone answers them from here, since
  /// the reply itself syncs only once it ends.
  final List<GaiaCardPart> cards;

  static GaiaLive fromFirestore(String id, Map<String, Object?> data) =>
      GaiaLive(
        chatId: id,
        messageId: data['messageId'] as String? ?? '',
        text: data['text'] as String? ?? '',
        status: data['status'] as String? ?? '',
        updatedAt: (data['updatedAt'] as num?)?.toInt() ?? 0,
        cards: [
          for (final card in (data['cards'] as List?) ?? const [])
            if (card is Map)
              GaiaCardPart.fromJson(card.cast<String, Object?>()),
        ],
      );
}

/// Where a phone sends a command for a chat (§12.2): the beacon whose
/// native session last ran it, while online, else any online one; null
/// when none is.
GaiaBeacon? gaiaBeaconFor(
  Map<String, int> lastSeqByDevice,
  List<GaiaBeacon> beacons,
  DateTime now,
) {
  final online = [
    for (final beacon in beacons)
      if (beacon.onlineAt(now)) beacon,
  ];
  if (online.isEmpty) return null;
  final ranLast =
      (lastSeqByDevice.entries.toList()
            ..sort((a, b) => b.value.compareTo(a.value)))
          .map((entry) => entry.key);
  for (final deviceId in ranLast) {
    if (online.where((b) => b.deviceId == deviceId).firstOrNull
        case final beacon?) {
      return beacon;
    }
  }
  return online.first;
}
