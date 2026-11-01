import 'dart:convert';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/remote/gaia_beacon_service.dart';
import 'package:voyager/features/gaia/remote/gaia_device_keys.dart';
import 'package:voyager/features/gaia/remote/gaia_power.dart';
import 'package:voyager/features/gaia/remote/gaia_remote.dart';
import 'package:voyager/features/gaia/remote/gaia_remote_client.dart';

/// Remote use (GAIA_HLD.md §8, §12.2): signed commands, pairing, the
/// beacon's heartbeat, claims, live text and leases, on a fake Firestore.

Future<void> settle() async {
  Future<void> turns() async {
    for (var i = 0; i < 30; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  await turns();
  // A command noted down before it runs goes through the real disk.
  await Future<void>.delayed(const Duration(milliseconds: 50));
  await turns();
}

void main() {
  late Directory dir;
  late FakeFirebaseFirestore firestore;
  late GaiaTrustStore trust;
  late GaiaCommandLog commandLog;
  late GaiaBeaconService beacon;
  late GaiaDeviceKey phoneKey;
  late GaiaRemoteClient phone;
  var now = DateTime(2026, 10, 31, 12);
  final ran = <GaiaRemoteCommand>[];

  Future<GaiaCommandLog> loadLog() => GaiaCommandLog.load(
    file: File(p.join(dir.path, 'commands_run.log')),
    clock: () => now,
  );

  GaiaBeaconService laptop(GaiaCommandLog log) =>
      GaiaBeaconService(
          firestore: firestore,
          deviceId: 'laptop',
          name: 'LAPTOP',
          adapters: const ['claude_code'],
          trust: trust,
          commandLog: log,
          clock: () => now,
        )
        ..onCommand = (command) async {
          ran.add(command);
          if (command.payload['fail'] == true) {
            throw GaiaRemoteException('It would not.');
          }
          return {'started': true};
        };

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('gaia_remote');
    firestore = FakeFirebaseFirestore();
    now = DateTime(2026, 10, 31, 12);
    ran.clear();
    trust = await GaiaTrustStore.load(
      file: File(p.join(dir.path, 'trusted.json')),
    );
    commandLog = await loadLog();
    beacon = laptop(commandLog);
    phoneKey = await GaiaDeviceKey.load(
      file: File(p.join(dir.path, 'key.json')),
    );
    phone = GaiaRemoteClient(
      firestore: firestore,
      uid: 'u',
      deviceId: 'phone',
      key: phoneKey,
      clock: () => now,
    );
  });

  tearDown(() async {
    await beacon.dispose();
    await dir.delete(recursive: true);
  });

  Future<Map<String, dynamic>?> doc(String collection, String id) async =>
      (await firestore.doc('users/u/$collection/$id').get()).data();

  Future<void> pairPhone() async {
    await phone.requestPairing(name: 'Pixel', platform: 'android');
    await settle();
    await beacon.trustDevice(beacon.devices.value.single);
  }

  group('signing and pairing', () {
    test('a command verifies against its key, and not once changed or '
        'copied under another id', () async {
      final command = await phoneKey.sign(
        GaiaRemoteCommand(
          id: 'a',
          type: GaiaRemoteCommandType.prompt,
          chatId: 'c',
          payload: {'text': 'Hi', 'tier': null},
          fromDevice: 'phone',
          targetDevice: 'laptop',
          createdAt: 1,
        ),
      );
      expect(await gaiaVerifyCommand(command, phoneKey.publicKey), isTrue);
      final changed = GaiaRemoteCommand.fromFirestore('a', {
        ...command.toFirestore(),
        'payload': {'text': 'rm -rf'},
      })!;
      expect(await gaiaVerifyCommand(changed, phoneKey.publicKey), isFalse);
      final copied = GaiaRemoteCommand.fromFirestore(
        'b',
        command.toFirestore(),
      )!;
      expect(await gaiaVerifyCommand(copied, phoneKey.publicKey), isFalse);
      final other = await GaiaDeviceKey.load(
        file: File(p.join(dir.path, 'other.json')),
      );
      expect(await gaiaVerifyCommand(command, other.publicKey), isFalse);
    });

    test('the key is kept, so the pairing code stays the same; a reset '
        'makes a new one', () async {
      final file = File(p.join(dir.path, 'key.json'));
      final again = await GaiaDeviceKey.load(file: file);
      expect(again.publicKey, phoneKey.publicKey);
      await GaiaDeviceKey.reset(file: file);
      final fresh = await GaiaDeviceKey.load(file: file);
      expect(fresh.publicKey, isNot(phoneKey.publicKey));
    });

    test('the pairing code is 80 bits of the key\'s hash, the same on every '
        'device', () {
      // SHA-256 of 32 zero bytes starts 66 68 7a ad f8 62 bd 77 6c 8f.
      expect(
        gaiaPairingCode(base64Encode(List.filled(32, 0))),
        'CSM7 NBFR CAYQ EV4F',
      );
    });

    test('canonical JSON sorts keys at every depth', () {
      expect(
        gaiaCanonicalJson({
          'b': 1,
          'a': {
            'd': 2,
            'c': [
              3,
              {'f': 4, 'e': 5},
            ],
          },
        }),
        '{"a":{"c":[3,{"e":5,"f":4}],"d":2},"b":1}',
      );
    });
  });

  group('beacon', () {
    test('the heartbeat says who it is, what it runs, and goes to 0 when it '
        'stops', () async {
      await beacon.setUser('u');
      beacon.setRuns(const [(chatId: 'c', title: 'Plan')]);
      await settle();
      final data = (await doc(FirestoreCollections.gaiaBeacons, 'laptop'))!;
      final read = GaiaBeacon.fromFirestore('laptop', data);
      expect(read.name, 'LAPTOP');
      expect(read.onlineAt(now), isTrue);
      expect(read.onlineAt(now.add(const Duration(minutes: 6))), isFalse);
      expect(read.isRunning('c'), isTrue);
      await beacon.dispose();
      expect(
        (await doc(FirestoreCollections.gaiaBeacons, 'laptop'))!['heartbeatAt'],
        0,
      );
    });

    test(
      'a command from a device not paired here is rejected, unrun',
      () async {
        await beacon.setUser('u');
        await phone.requestPairing(name: 'Pixel', platform: 'android');
        final id = await phone.send(
          GaiaRemoteCommandType.prompt,
          target: 'laptop',
          chatId: 'c',
          payload: {'text': 'Hi'},
        );
        await settle();
        expect(ran, isEmpty);
        final data = (await doc(FirestoreCollections.gaiaCommands, id))!;
        expect(data['status'], 'rejected');
        expect(data['error'], contains('not paired'));
      },
    );

    test('a paired device\'s command is claimed, run once, and settled with '
        'its result or its error', () async {
      await beacon.setUser('u');
      await pairPhone();
      final ok = await phone.send(
        GaiaRemoteCommandType.prompt,
        target: 'laptop',
        chatId: 'c',
        payload: {'text': 'Hi'},
      );
      final bad = await phone.send(
        GaiaRemoteCommandType.prompt,
        target: 'laptop',
        chatId: 'c',
        payload: {'fail': true},
      );
      await settle();
      expect(ran.map((c) => c.id), unorderedEquals([ok, bad]));
      final done = (await doc(FirestoreCollections.gaiaCommands, ok))!;
      expect(done['status'], 'done');
      expect(done['result'], {'started': true});
      final failed = (await doc(FirestoreCollections.gaiaCommands, bad))!;
      expect(failed['status'], 'failed');
      expect(failed['error'], 'It would not.');

      // Put back to pending by anyone: it was claimed once, and runs once.
      await firestore
          .doc('users/u/${FirestoreCollections.gaiaCommands}/$ok')
          .update({'status': 'pending'});
      await settle();
      expect(ran, hasLength(2));
    });

    test('a command put back after a restart, signature intact, is rejected '
        'unrun', () async {
      await beacon.setUser('u');
      await pairPhone();
      final id = await phone.send(
        GaiaRemoteCommandType.prompt,
        target: 'laptop',
        chatId: 'c',
        payload: {'text': 'Hi'},
      );
      await settle();
      expect(ran, hasLength(1));
      await beacon.dispose();

      final restarted = laptop(await loadLog());
      addTearDown(restarted.dispose);
      now = now.add(const Duration(minutes: 5));
      await restarted.setUser('u');
      await firestore
          .doc('users/u/${FirestoreCollections.gaiaCommands}/$id')
          .update({'status': 'pending'});
      await settle();
      expect(ran, hasLength(1));
      final data = (await doc(FirestoreCollections.gaiaCommands, id))!;
      expect(data['status'], 'rejected');
      expect(data['error'], contains('already ran'));
    });

    test('a command sent while the desktop was off still runs once it is '
        'back', () async {
      await beacon.setUser('u');
      await pairPhone();
      await beacon.dispose();
      final id = await phone.send(
        GaiaRemoteCommandType.prompt,
        target: 'laptop',
        chatId: 'c',
        payload: {'text': 'Hi'},
      );

      final restarted = laptop(await loadLog());
      addTearDown(restarted.dispose);
      await restarted.setUser('u');
      await settle();
      expect(ran.single.id, id);
    });

    test('a command it could not note down is not run', () async {
      await beacon.setUser('u');
      await pairPhone();
      final log = File(p.join(dir.path, 'commands_run.log'));
      await log.delete();
      await Directory(log.path).create();
      final id = await phone.send(
        GaiaRemoteCommandType.prompt,
        target: 'laptop',
        chatId: 'c',
        payload: {'text': 'Hi'},
      );
      await settle();
      expect(ran, isEmpty);
      expect(
        (await doc(FirestoreCollections.gaiaCommands, id))!['status'],
        'failed',
      );
    });

    test('the log drops what is too old to run anyway, and survives a '
        'damaged line', () async {
      final file = File(p.join(dir.path, 'commands_run.log'));
      final fresh = now.millisecondsSinceEpoch - 60000;
      final stale =
          now.millisecondsSinceEpoch - kGaiaCommandMaxAge.inMilliseconds - 1000;
      await file.writeAsString('$fresh a\n$stale b\ngarbage\n\n$fresh c');
      final log = await loadLog();
      expect(log.hasRun('a'), isTrue);
      expect(log.hasRun('b'), isFalse);
      expect(log.hasRun('c'), isTrue);
      expect(await file.readAsLines(), ['$fresh a', '$fresh c']);
    });

    test('a key swapped in Firestore is not trusted; one revoked anywhere '
        'stays revoked here', () async {
      await beacon.setUser('u');
      await pairPhone();
      final device = beacon.devices.value.single;
      expect(beacon.trusts(device), isTrue);

      final attacker = await GaiaDeviceKey.load(
        file: File(p.join(dir.path, 'attacker.json')),
      );
      final forged = GaiaRemoteClient(
        firestore: firestore,
        uid: 'u',
        deviceId: 'phone',
        key: attacker,
        clock: () => now,
      );
      await forged.requestPairing(name: 'Pixel', platform: 'android');
      final id = await forged.send(
        GaiaRemoteCommandType.prompt,
        target: 'laptop',
        chatId: 'c',
      );
      await settle();
      expect(ran, isEmpty);
      expect(
        (await doc(FirestoreCollections.gaiaCommands, id))!['status'],
        'rejected',
      );

      // Revoked from another desktop: the pinned key goes for good.
      await firestore
          .doc('users/u/${FirestoreCollections.gaiaDevices}/phone')
          .update({'revokedAt': 5});
      await settle();
      expect(trust.keyOf('phone'), isNull);
      await firestore
          .doc('users/u/${FirestoreCollections.gaiaDevices}/phone')
          .update({'revokedAt': null, 'publicKey': phoneKey.publicKey});
      await settle();
      expect(trust.keyOf('phone'), isNull);
      final reloaded = await GaiaTrustStore.load(
        file: File(p.join(dir.path, 'trusted.json')),
      );
      expect(reloaded.revoked, contains(phoneKey.publicKey));
    });

    test('a desktop that was off hears of a revoke even after the device was '
        'removed, and refuses what it sent', () async {
      await beacon.setUser('u');
      await pairPhone();
      await beacon.dispose();

      final otherTrust = await GaiaTrustStore.load(
        file: File(p.join(dir.path, 'other_trusted.json')),
      );
      final desktop = GaiaBeaconService(
        firestore: firestore,
        deviceId: 'desktop',
        name: 'DESKTOP',
        adapters: const [],
        trust: otherTrust,
        commandLog: commandLog,
        clock: () => now,
      );
      await desktop.setUser('u');
      await settle();
      await desktop.trustDevice(desktop.devices.value.single);
      await desktop.revokeDevice(desktop.devices.value.single);
      await settle();
      await desktop.forgetDevice(desktop.devices.value.single);
      await settle();
      expect(await doc(FirestoreCollections.gaiaDevices, 'phone'), isNull);
      expect(trust.keyOf('phone'), phoneKey.publicKey, reason: 'still off');
      final id = await phone.send(
        GaiaRemoteCommandType.prompt,
        target: 'laptop',
        chatId: 'c',
      );

      beacon = laptop(commandLog);
      await beacon.setUser('u');
      await settle();
      expect(trust.keyOf('phone'), isNull);
      expect(ran, isEmpty);
      expect(
        (await doc(FirestoreCollections.gaiaCommands, id))!['status'],
        'rejected',
      );

      // Asking to pair again with that key doesn't bring it back.
      await phone.requestPairing(name: 'Pixel', platform: 'android');
      await settle();
      final again = beacon.devices.value.single;
      expect(beacon.refuses(again), isTrue);
      await beacon.trustDevice(again);
      expect(trust.keyOf('phone'), isNull);
      await desktop.dispose();
    });

    test('a key turned down here is refused at Pair: nothing says this '
        'desktop trusts it, and a new key pairs', () async {
      await beacon.setUser('u');
      await phone.requestPairing(name: 'Pixel', platform: 'android');
      await settle();
      await beacon.forgetDevice(beacon.devices.value.single);
      await settle();

      await phone.requestPairing(name: 'Pixel', platform: 'android');
      await settle();
      final turnedDown = beacon.devices.value.single;
      expect(beacon.refuses(turnedDown), isTrue);
      await beacon.trustDevice(turnedDown);
      await settle();
      expect(trust.keyOf('phone'), isNull);
      expect(beacon.devices.value.single.trustedBy, isEmpty);

      // What the phone does once its request is gone.
      await beacon.forgetDevice(turnedDown);
      await settle();
      final newKey = await GaiaDeviceKey.load(
        file: File(p.join(dir.path, 'new_key.json')),
      );
      final again = GaiaRemoteClient(
        firestore: firestore,
        uid: 'u',
        deviceId: 'phone',
        key: newKey,
        clock: () => now,
      );
      await again.requestPairing(name: 'Pixel', platform: 'android');
      await settle();
      final fresh = beacon.devices.value.single;
      expect(beacon.refuses(fresh), isFalse);
      await beacon.trustDevice(fresh);
      expect(trust.keyOf('phone'), newKey.publicKey);
    });

    test('an empty signature is refused, not left pending', () async {
      await beacon.setUser('u');
      await pairPhone();
      await firestore
          .doc('users/u/${FirestoreCollections.gaiaCommands}/forged')
          .set({
            'id': 'forged',
            'type': 'abort',
            'fromDevice': 'phone',
            'targetDevice': 'laptop',
            'createdAt': now.millisecondsSinceEpoch,
            'signature': '',
            'status': 'pending',
          });
      await settle();
      expect(ran, isEmpty);
      expect(
        (await doc(FirestoreCollections.gaiaCommands, 'forged'))!['status'],
        'rejected',
      );
    });

    test('a command dated more than ten minutes ahead is refused', () async {
      await beacon.setUser('u');
      await pairPhone();
      final ahead = GaiaRemoteClient(
        firestore: firestore,
        uid: 'u',
        deviceId: 'phone',
        key: phoneKey,
        clock: () => now.add(const Duration(minutes: 11)),
      );
      final id = await ahead.send(
        GaiaRemoteCommandType.abort,
        target: 'laptop',
      );
      await settle();
      expect(ran, isEmpty);
      expect(
        (await doc(FirestoreCollections.gaiaCommands, id))!['status'],
        'rejected',
      );
    });

    test(
      'sendAndSettle gives back why it failed and deletes the command',
      () async {
        await beacon.setUser('u');
        final done = phone.sendAndSettle(
          GaiaRemoteCommandType.abort,
          target: 'laptop',
        );
        await settle();
        expect(await done, contains('not paired'));
        await settle();
        final left = await firestore
            .collection('users/u/${FirestoreCollections.gaiaCommands}')
            .get();
        expect(left.docs, isEmpty);
      },
    );

    test('a command older than ten minutes is refused', () async {
      await beacon.setUser('u');
      await pairPhone();
      final sent = now;
      now = now.add(const Duration(minutes: 11));
      final old = await phoneKey.sign(
        GaiaRemoteCommand(
          id: 'old',
          type: GaiaRemoteCommandType.abort,
          fromDevice: 'phone',
          targetDevice: 'laptop',
          createdAt: sent.millisecondsSinceEpoch,
        ),
      );
      await firestore
          .doc('users/u/${FirestoreCollections.gaiaCommands}/old')
          .set(old.toFirestore());
      await settle();
      expect(ran, isEmpty);
      expect(
        (await doc(FirestoreCollections.gaiaCommands, 'old'))!['error'],
        contains('too late'),
      );
    });
  });

  group('live text (§8.1)', () {
    GaiaMessage reply(
      String text, {
      List<GaiaPart>? parts,
      bool done = false,
    }) => GaiaMessage(
      id: 'r',
      chatId: 'c',
      seq: 1,
      role: GaiaMessageRole.assistant,
      parts: parts ?? [GaiaTextPart(text)],
      status: done ? GaiaMessageStatus.complete : GaiaMessageStatus.streaming,
      createdAt: now,
      updatedAt: now,
    );

    test('nothing is written while nobody watches', () async {
      await beacon.setUser('u');
      beacon.onMessage(reply('Hello'));
      await settle();
      expect(await doc(FirestoreCollections.gaiaLive, 'c'), isNull);
    });

    test(
      'a watcher who arrives mid-run gets what there is at once, then at '
      'most a write a second, and the document goes when the reply ends',
      () async {
        await beacon.setUser('u');
        beacon.onMessage(reply('Hel'));
        final stop = phone.watch('c');
        await settle();
        expect((await doc(FirestoreCollections.gaiaLive, 'c'))!['text'], 'Hel');

        beacon.onMessage(reply('Hello'));
        await settle();
        // Under a second since the last write: held back.
        expect((await doc(FirestoreCollections.gaiaLive, 'c'))!['text'], 'Hel');
        now = now.add(const Duration(seconds: 2));
        beacon.onMessage(reply('Hello there'));
        await settle();
        expect(
          (await doc(FirestoreCollections.gaiaLive, 'c'))!['text'],
          'Hello there',
        );

        beacon.onMessage(reply('Hello there.', done: true));
        await settle();
        expect(await doc(FirestoreCollections.gaiaLive, 'c'), isNull);
        stop();
      },
    );

    test('an open card goes to the watcher at once, however recent the '
        'last write, and comes off once decided', () async {
      await beacon.setUser('u');
      final stop = phone.watch('c');
      await settle();
      beacon.onMessage(reply('Checking'));
      await settle();
      const card = GaiaCardPart(
        id: 'k',
        kind: GaiaCardKind.permission,
        tool: 'Bash',
        input: {'command': 'ls'},
      );
      beacon.onMessage(
        reply('', parts: const [GaiaTextPart('Checking'), card]),
      );
      await settle();
      var live = GaiaLive.fromFirestore(
        'c',
        (await doc(FirestoreCollections.gaiaLive, 'c'))!,
      );
      expect(live.cards.single.id, 'k');
      expect(live.cards.single.tool, 'Bash');

      beacon.onMessage(
        reply(
          '',
          parts: [
            const GaiaTextPart('Checking'),
            card.decided(GaiaCardState.accepted),
          ],
        ),
      );
      await settle();
      live = GaiaLive.fromFirestore(
        'c',
        (await doc(FirestoreCollections.gaiaLive, 'c'))!,
      );
      expect(live.cards, isEmpty);
      stop();
    });

    test('past the day\'s write budget text stops, but a card still goes to '
        'the watcher, and comes off once decided', () async {
      await beacon.setUser('u');
      final stop = phone.watch('c');
      await settle();
      // A change of cards is written at once, so this spends the budget.
      for (var i = 0; !beacon.livePaused; i++) {
        beacon.onMessage(
          reply(
            '',
            parts: [
              const GaiaTextPart('Busy'),
              if (i.isOdd)
                GaiaCardPart(
                  id: 'spend$i',
                  kind: GaiaCardKind.permission,
                  tool: 'Bash',
                  input: const {'command': 'ls'},
                ),
            ],
          ),
        );
      }
      // Finish on a write with no card open.
      beacon.onMessage(reply('Busy'));
      await settle();
      expect(
        (await doc(FirestoreCollections.gaiaBeacons, 'laptop'))!['livePaused'],
        isTrue,
      );
      Future<GaiaLive> live() async => GaiaLive.fromFirestore(
        'c',
        (await doc(FirestoreCollections.gaiaLive, 'c'))!,
      );
      final before = await live();
      expect(before.cards, isEmpty);

      now = now.add(const Duration(seconds: 2));
      beacon.onMessage(reply('Busy, still'));
      await settle();
      expect((await live()).text, before.text);

      const card = GaiaCardPart(
        id: 'k',
        kind: GaiaCardKind.question,
        question: 'Which list?',
      );
      beacon.onMessage(
        reply('', parts: const [GaiaTextPart('Busy, still'), card]),
      );
      await settle();
      expect((await live()).cards.single.id, 'k');

      beacon.onMessage(
        reply(
          '',
          parts: [
            const GaiaTextPart('Busy, still'),
            card.decided(GaiaCardState.accepted),
          ],
        ),
      );
      await settle();
      expect((await live()).cards, isEmpty);
      stop();
    });

    test('the status line counts tool calls and names the current tool, '
        'never what it ran', () {
      final message = reply(
        '',
        parts: const [
          GaiaTextPart('Looking.'),
          GaiaActivityPart(['Read', 'Grep']),
          GaiaTextPart('Now the fix.'),
          GaiaActivityPart(['Edit', 'Bash']),
        ],
      );
      expect(
        gaiaLiveStatus(message, now.add(const Duration(minutes: 12))),
        'Working · 4 tool calls · 12 min · Bash',
      );
      expect(gaiaLiveStatus(reply('Writing'), now), '');
    });
  });

  group('run lease (§8)', () {
    test('one device holds a chat at a time, until it lets go or the lease '
        'runs out', () async {
      await beacon.setUser('u');
      final desktop = GaiaBeaconService(
        firestore: firestore,
        deviceId: 'desktop',
        name: 'DESKTOP',
        adapters: const [],
        trust: trust,
        commandLog: commandLog,
        clock: () => now,
      );
      await desktop.setUser('u');
      await settle();

      expect(await beacon.takeLease('c'), isNull);
      expect(await desktop.takeLease('c'), 'LAPTOP');
      // Its own again: fine.
      expect(await beacon.takeLease('c'), isNull);

      // The run ends: the lease goes with it.
      beacon.setRuns(const []);
      await settle();
      expect(await desktop.takeLease('c'), isNull);

      // A holder that dies leaves a lease that runs out.
      now = now.add(const Duration(minutes: 4));
      expect(await beacon.takeLease('c'), isNull);
      await desktop.dispose();
    });

    test(
      'a lease another device took while this one slept stays its own',
      () async {
        await beacon.setUser('u');
        final desktop = GaiaBeaconService(
          firestore: firestore,
          deviceId: 'desktop',
          name: 'DESKTOP',
          adapters: const [],
          trust: trust,
          commandLog: commandLog,
          clock: () => now,
        );
        await desktop.setUser('u');
        await settle();
        final lease = firestore
            .collection('users/u/${FirestoreCollections.gaiaLeases}')
            .doc('c');

        expect(await beacon.takeLease('c'), isNull);
        // Renewed while it's still this desktop's.
        final taken = (await lease.get()).data()!['expiresAt'] as int;
        now = now.add(const Duration(minutes: 1));
        await beacon.renewLeases();
        expect((await lease.get()).data()!['expiresAt'], greaterThan(taken));

        now = now.add(const Duration(minutes: 4));
        expect(await desktop.takeLease('c'), isNull);
        await beacon.renewLeases();
        expect((await lease.get()).data()!['deviceId'], 'desktop');

        // And it no longer counts as held: its end leaves the other's alone.
        beacon.setRuns(const []);
        await settle();
        expect((await lease.get()).data()!['deviceId'], 'desktop');
        await desktop.dispose();
      },
    );

    test('signed out, every run goes ahead', () async {
      expect(await beacon.takeLease('c'), isNull);
    });
  });

  test('the phone sends to the beacon whose session ran the chat last, '
      'while it is online', () {
    GaiaBeacon at(String id, int beat) =>
        GaiaBeacon(deviceId: id, name: id, heartbeatAt: beat);
    final t = now.millisecondsSinceEpoch;
    final beacons = [at('a', t), at('b', t), at('c', 0)];
    expect(gaiaBeaconFor({'b': 4, 'a': 2}, beacons, now)!.deviceId, 'b');
    expect(gaiaBeaconFor({'c': 9, 'a': 2}, beacons, now)!.deviceId, 'a');
    expect(gaiaBeaconFor({}, [at('c', 0)], now), isNull);
  });

  group('push notifications (§14)', () {
    GaiaMessage reply({
      List<GaiaPart> parts = const [GaiaTextPart('All done.\nMore.')],
      GaiaMessageStatus status = GaiaMessageStatus.complete,
    }) => GaiaMessage(
      id: 'r',
      chatId: 'c',
      seq: 1,
      role: GaiaMessageRole.assistant,
      parts: parts,
      status: status,
      createdAt: now,
      updatedAt: now,
    );

    Future<List<Map<String, dynamic>>> notes() async => [
      for (final doc
          in (await firestore
                  .collection('users/u/${FirestoreCollections.gaiaNotify}')
                  .get())
              .docs)
        doc.data(),
    ];

    test('only a chat a phone drove notifies it: once for a card, once '
        'when the reply ends', () async {
      await beacon.setUser('u');
      beacon.onMessage(reply());
      await settle();
      expect(await notes(), isEmpty);

      await pairPhone();
      await phone.send(
        GaiaRemoteCommandType.prompt,
        target: 'laptop',
        chatId: 'c',
        payload: {'text': 'Hi'},
      );
      await settle();
      const card = GaiaCardPart(
        id: 'k',
        kind: GaiaCardKind.question,
        question: 'Tea or coffee?',
      );
      final asking = reply(
        parts: const [card],
        status: GaiaMessageStatus.streaming,
      );
      beacon
        ..onMessage(asking)
        ..onMessage(asking);
      await settle();
      beacon
        ..onMessage(reply())
        ..onMessage(reply());
      await settle();
      final sent = await notes();
      expect(sent.map((n) => n['kind']), unorderedEquals(['question', 'done']));
      expect(
        sent.firstWhere((n) => n['kind'] == 'question')['text'],
        'Tea or coffee?',
      );
      final done = sent.firstWhere((n) => n['kind'] == 'done');
      expect(done['text'], 'All done.');
      expect(done['toDevice'], 'phone');
    });

    test(
      'a chat this desktop then sends to no longer notifies the phone',
      () async {
        await beacon.setUser('u');
        await pairPhone();
        await phone.send(
          GaiaRemoteCommandType.prompt,
          target: 'laptop',
          chatId: 'c',
          payload: {'text': 'Hi'},
        );
        await settle();
        beacon
          ..onLocalRun('c')
          ..onMessage(reply());
        await settle();
        expect(await notes(), isEmpty);
      },
    );

    test('nothing is sent while the phone watches the chat', () async {
      await beacon.setUser('u');
      await pairPhone();
      await phone.send(
        GaiaRemoteCommandType.prompt,
        target: 'laptop',
        chatId: 'c',
        payload: {'text': 'Hi'},
      );
      final stop = phone.watch('c');
      await settle();
      beacon.onMessage(reply());
      await settle();
      expect(await notes(), isEmpty);
      stop();
    });

    test(
      'a card the phone saw and left is notified when it leaves, once',
      () async {
        await beacon.setUser('u');
        await pairPhone();
        await phone.send(
          GaiaRemoteCommandType.prompt,
          target: 'laptop',
          chatId: 'c',
          payload: {'text': 'Hi'},
        );
        final stop = phone.watch('c');
        await settle();
        const card = GaiaCardPart(
          id: 'k',
          kind: GaiaCardKind.question,
          question: 'Tea or coffee?',
        );
        final asking = reply(
          parts: const [card],
          status: GaiaMessageStatus.streaming,
        );
        beacon.onMessage(asking);
        await settle();
        expect(await notes(), isEmpty);

        stop();
        await settle();
        beacon.onMessage(asking);
        await settle();
        expect((await notes()).single['kind'], 'question');
      },
    );

    test('a reply that ended while its watcher was dying notifies once the '
        'watch runs out, unless the watcher renewed or left', () async {
      await beacon.setUser('u');
      await pairPhone();
      await phone.send(
        GaiaRemoteCommandType.prompt,
        target: 'laptop',
        chatId: 'c',
        payload: {'text': 'Hi'},
      );
      await settle();
      final watch = firestore.doc(
        'users/u/${FirestoreCollections.gaiaWatch}/phone',
      );
      Future<void> watchFor(Duration time) async {
        await watch.set({
          'chatId': 'c',
          'expiresAt': now.add(time).millisecondsSinceEpoch,
        });
        await settle();
      }

      GaiaMessage ended(String id) => GaiaMessage(
        id: id,
        chatId: 'c',
        seq: 2,
        role: GaiaMessageRole.assistant,
        parts: const [GaiaTextPart('Done.')],
        status: GaiaMessageStatus.complete,
        createdAt: now,
        updatedAt: now,
      );

      // It never renews: it was dying, so it never saw the reply.
      await watchFor(kGaiaWatchFor);
      beacon.onMessage(ended('dying'));
      await settle();
      beacon.notifyLapsedWatchers();
      await settle();
      expect(await notes(), isEmpty, reason: 'its watch is still good');
      now = now.add(kGaiaWatchFor + const Duration(seconds: 1));
      beacon
        ..notifyLapsedWatchers()
        ..notifyLapsedWatchers();
      await settle();
      expect((await notes()).single['kind'], 'done');

      // It renews: it's alive, and saw it.
      await watchFor(kGaiaWatchFor);
      beacon.onMessage(ended('renewed'));
      await settle();
      await watchFor(kGaiaWatchFor * 2);
      now = now.add(kGaiaWatchFor * 3);
      beacon.notifyLapsedWatchers();
      await settle();
      expect(await notes(), hasLength(1));

      // It leaves cleanly once the reply is in: it saw that too.
      await watchFor(kGaiaWatchFor);
      beacon.onMessage(ended('left'));
      await settle();
      await watch.delete();
      await settle();
      now = now.add(kGaiaWatchFor * 2);
      beacon.notifyLapsedWatchers();
      await settle();
      expect(await notes(), hasLength(1));
    });

    test('a card whose watcher died is notified once its watch runs out, '
        'once', () async {
      await beacon.setUser('u');
      await pairPhone();
      await phone.send(
        GaiaRemoteCommandType.prompt,
        target: 'laptop',
        chatId: 'c',
        payload: {'text': 'Hi'},
      );
      addTearDown(phone.watch('c'));
      await settle();
      beacon.onMessage(
        reply(
          parts: const [
            GaiaCardPart(
              id: 'k',
              kind: GaiaCardKind.question,
              question: 'Tea or coffee?',
            ),
          ],
          status: GaiaMessageStatus.streaming,
        ),
      );
      await settle();
      beacon.notifyLapsedWatchers();
      await settle();
      expect(await notes(), isEmpty, reason: 'its watch is still good');

      now = now.add(kGaiaWatchFor + const Duration(seconds: 1));
      beacon.notifyLapsedWatchers();
      beacon.notifyLapsedWatchers();
      await settle();
      expect((await notes()).single['kind'], 'question');
    });
  });

  group('power (§12)', () {
    test('a countdown runs out into the action, unless cancelled', () {
      fakeAsync((async) {
        final done = <String>[];
        final power = GaiaPower(
          stateFile: () async => File(p.join(dir.path, 'mode.json')),
          execute: (kind) async => done.add(kind),
        );
        power.startCountdown('sleep');
        async.elapse(const Duration(seconds: 20));
        expect(power.cancelCountdown(), isTrue);
        async.elapse(const Duration(seconds: 20));
        expect(done, isEmpty);
        power.startCountdown('shutdown');
        async.elapse(const Duration(seconds: 31));
        expect(done, ['shutdown']);
        expect(power.countdown.value, isNull);
        expect(power.cancelCountdown(), isFalse);
      });
    });

    test('beacon mode sets the lid to do nothing and puts it back: when '
        'turned off, at quit, and at the start after a crash', () async {
      var lid = 1;
      GaiaPower make() => GaiaPower(
        stateFile: () async => File(p.join(dir.path, 'mode.json')),
        readLidAc: () async => lid,
        writeLidAc: (value) async => lid = value,
        dryRun: false,
      );
      final power = make();
      await power.setBeaconMode(true);
      expect(lid, 0);
      await power.setBeaconMode(false);
      expect(lid, 1);

      await power.setBeaconMode(true);
      await power.shutdown();
      expect(lid, 1);
      // On again at the next start.
      final next = make();
      await next.restore();
      expect(next.beaconMode.value, isTrue);
      expect(lid, 0);

      // A crash with beacon mode on: the next start keeps the original.
      final afterCrash = make();
      await afterCrash.restore();
      await afterCrash.setBeaconMode(false);
      expect(lid, 1);
    });

    test("powercfg's AC index is read from its output", () {
      expect(
        gaiaParseLidAc(
          '    Current AC Power Setting Index: 0x00000001\n'
          '    Current DC Power Setting Index: 0x00000002\n',
        ),
        1,
      );
      expect(gaiaParseLidAc('no lid here'), isNull);
    });
  });
}
