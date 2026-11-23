import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/companion/gaia_app.dart';
import 'package:voyager/features/gaia/companion/gaia_controller.dart';
import 'package:voyager/features/gaia/companion/gaia_settings_panel.dart';
import 'package:voyager/features/gaia/gaia_pipe.dart';
import 'package:voyager/features/gaia/remote/gaia_remote.dart';

import 'fakes/gaia_fakes.dart';

/// The settings panel's Status tab (GAIA_SETTINGS_HLD.md Phase 3): the
/// main instance sends `status` only while the tab shows, and the tab's
/// device actions and beacon mode go back through the pipe.
void main() {
  final key = base64Encode(List.filled(32, 7));
  final code = gaiaPairingCode(key);

  GaiaDevice device(
    String id,
    String name, {
    Map<String, int> trustedBy = const {},
    int? revokedAt,
  }) => GaiaDevice(
    deviceId: id,
    name: name,
    publicKey: key,
    platform: 'android',
    trustedBy: trustedBy,
    revokedAt: revokedAt,
  );

  GaiaStatus status({
    bool signedIn = true,
    bool? beaconMode = false,
    List<GaiaBeacon>? beacons,
    List<({GaiaDevice device, bool trusted, bool refused})>? devices,
  }) {
    final now = DateTime.now().millisecondsSinceEpoch;
    return GaiaStatus(
      signedIn: signedIn,
      thisDevice: 'laptop',
      beacons:
          beacons ??
          [
            GaiaBeacon(
              deviceId: 'laptop',
              name: 'LAPTOP',
              heartbeatAt: now,
              runs: const [(chatId: 'c1', title: 'Parser')],
            ),
            GaiaBeacon(
              deviceId: 'tower',
              name: 'TOWER',
              heartbeatAt: now - const Duration(hours: 2).inMilliseconds,
            ),
          ],
      devices:
          devices ??
          [
            (device: device('p1', 'Pixel'), trusted: false, refused: false),
            (
              device: device('p2', 'OnePlus', trustedBy: {'laptop': 1}),
              trusted: true,
              refused: false,
            ),
            (
              device: device('p3', 'Old phone', revokedAt: 1),
              trusted: false,
              refused: true,
            ),
          ],
      beaconMode: beaconMode,
    );
  }

  late List<(String, Map<String, Object?>)> requests;
  late GaiaStatus answer;
  late FakeGaiaPipe main;
  String? refusePair;

  List<Object?> watches() => [
    for (final (method, params) in requests)
      if (method == 'watchStatus') params['on'],
  ];

  Future<GaiaController> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1100, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (call) async => false,
    );
    requests = [];
    answer = status();
    refusePair = null;
    late FakeGaiaPipe companion;
    main = FakeGaiaPipe.main()
      ..onLaunch = (end, _) {
        companion = end;
      }
      ..onRequest = (method, params) async {
        requests.add((method, params));
        switch (method) {
          case 'hello':
            return {
              'aborted': false,
              'accent': 0xFF7C9EFF,
              'deviceId': 'laptop',
              'settings': GaiaSettings.initial().toJson(),
            };
          case 'chats':
          case 'messages':
          case 'drafts':
          case 'btws':
          case 'queue':
          case 'actions':
            return <Object?>[];
          case 'watchStatus':
            return params['on'] == true ? answer.toJson() : null;
          case 'pairDevice':
            if (refusePair case final why?) throw GaiaPipeException(why);
            return null;
        }
        return null;
      };
    await main.startCompanion();
    final controller = GaiaController(
      pipe: companion,
      window: FakeGaiaWindow(),
      runners: {kGaiaClaudeCodeAdapter: FakeClaudeRunner()},
      cliVersions: {kGaiaClaudeCodeAdapter: () async => (2, 1, 310)},
      exit: (_) {},
    );
    await tester.runAsync(() async {
      await controller.start();
      await controller.openWindow();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpWidget(GaiaApp(controller: controller));
    await tester.pump(const Duration(seconds: 1));
    return controller;
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<GaiaController> openStatus(WidgetTester tester) async {
    final controller = await pump(tester);
    await tester.runAsync(() => controller.openPanel(tab: GaiaPanelTab.status));
    await settle(tester);
    return controller;
  }

  testWidgets('it watches only while it shows', (tester) async {
    final controller = await pump(tester);
    expect(watches(), isEmpty);

    // Open at another tab: no watch.
    await tester.runAsync(
      () => controller.openPanel(tab: GaiaPanelTab.actions),
    );
    await settle(tester);
    expect(watches(), isEmpty);

    controller.showPanelTab(GaiaPanelTab.status);
    await settle(tester);
    expect(watches(), [true]);

    controller.showPanelTab(GaiaPanelTab.queue);
    await settle(tester);
    expect(watches(), [true, false]);

    controller.showPanelTab(GaiaPanelTab.status);
    await settle(tester);
    controller.closePanel();
    await settle(tester);
    expect(watches(), [true, false, true, false]);

    // Reopened at it, then the window hidden and shown again.
    await tester.runAsync(() => controller.openPanel());
    await settle(tester);
    expect(watches().last, isTrue);
    controller.onScreen.value = false;
    await settle(tester);
    expect(watches().last, isFalse);
    controller.onScreen.value = true;
    await settle(tester);
    expect(watches(), [true, false, true, false, true, false, true]);
    controller.closePanel();
    await settle(tester);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('desktops, this desktop and devices, as the page shows them, '
      'and updated live', (tester) async {
    final controller = await openStatus(tester);
    expect(find.text('LAPTOP (this desktop)'), findsOneWidget);
    expect(find.text('Online · 1 run'), findsOneWidget);
    expect(find.text('TOWER'), findsOneWidget);
    expect(find.textContaining('Offline · last seen '), findsOneWidget);
    expect(find.text('Beacon mode'), findsOneWidget);

    expect(
      find.text('Not paired with this desktop · code $code'),
      findsOneWidget,
    );
    expect(find.text('Paired with this desktop'), findsOneWidget);
    expect(find.text('Revoked'), findsOneWidget);
    expect(find.text('Pair'), findsOneWidget);
    expect(find.text('Revoke'), findsOneWidget);
    expect(find.byTooltip('Decline'), findsOneWidget);
    expect(find.byTooltip('Remove'), findsOneWidget);

    // A heartbeat and a new request arrive while it shows.
    final now = DateTime.now();
    main.notify(
      'status',
      status(
        beacons: [
          GaiaBeacon(
            deviceId: 'laptop',
            name: 'LAPTOP',
            heartbeatAt: now.millisecondsSinceEpoch,
            aborted: true,
            power: (
              kind: 'sleep',
              at: now.add(const Duration(seconds: 20)).millisecondsSinceEpoch,
            ),
          ),
        ],
        devices: [
          (device: device('p4', 'Tablet'), trusted: false, refused: false),
        ],
      ).toJson(),
    );
    await settle(tester);
    expect(find.textContaining('Online · Aborted · Sleeping in '), findsOne);
    expect(find.text('TOWER'), findsNothing);
    expect(find.text('Tablet'), findsOneWidget);
    expect(find.text('Pixel'), findsNothing);

    // Out of view, the last snapshot is let go and a late event is dropped.
    controller.showPanelTab(GaiaPanelTab.queue);
    await settle(tester);
    main.notify('status', status(devices: const []).toJson());
    await settle(tester);
    expect(controller.status, isNull);
  });

  testWidgets('Pair asks to check the code first; the rest go straight', (
    tester,
  ) async {
    await openStatus(tester);
    List<(String, Map<String, Object?>)> sent(String method) => [
      for (final request in requests)
        if (request.$1 == method) request,
    ];

    await tester.tap(find.text('Pair'));
    await tester.pumpAndSettle();
    expect(find.text('Pair Pixel?'), findsOneWidget);
    expect(find.text(code), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await settle(tester);
    expect(sent('pairDevice'), isEmpty);

    await tester.tap(find.text('Pair'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('They match'));
    await settle(tester);
    expect(sent('pairDevice').single.$2, {'deviceId': 'p1', 'publicKey': key});

    // Refused by the main instance: a toast says why.
    refusePair = 'That device asked again with a new code. Check it again.';
    await tester.tap(find.text('Pair'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('They match'));
    await settle(tester);
    expect(find.text("Couldn't pair"), findsOneWidget);
    expect(find.text(refusePair!), findsOneWidget);
    await tester.pump(const Duration(seconds: 10));

    await tester.tap(find.text('Revoke'));
    await settle(tester);
    expect(sent('revokeDevice').single.$2, {'deviceId': 'p2'});
    await tester.tap(find.byTooltip('Decline'));
    await settle(tester);
    await tester.tap(find.byTooltip('Remove'));
    await settle(tester);
    expect(
      [for (final r in sent('forgetDevice')) r.$2['deviceId']],
      ['p1', 'p3'],
    );

    await tester.tap(find.text('Beacon mode'));
    await settle(tester);
    expect(sent('setBeaconMode').single.$2, {'on': true});
  });

  testWidgets('signed out, it says so; with no beacon mode, no section', (
    tester,
  ) async {
    final controller = await pump(tester);
    answer = status(signedIn: false, beacons: const [], devices: const []);
    await tester.runAsync(() => controller.openPanel(tab: GaiaPanelTab.status));
    await settle(tester);
    expect(
      find.text('Sign in to Voyager to see your desktops and pair devices.'),
      findsOneWidget,
    );
    expect(find.text('Desktops'), findsNothing);

    main.notify(
      'status',
      status(beaconMode: null, beacons: const [], devices: const []).toJson(),
    );
    await settle(tester);
    expect(
      find.text('No desktop has Gaia running under this account yet.'),
      findsOneWidget,
    );
    expect(find.text('None yet.'), findsOneWidget);
    expect(find.text('This desktop'), findsNothing);
    expect(find.text('Beacon mode'), findsNothing);
  });

  test('GaiaStatus round-trips through JSON', () {
    final sent = status(beaconMode: true);
    final back = GaiaStatus.fromJson(jsonDecode(jsonEncode(sent.toJson())));
    expect(back.signedIn, isTrue);
    expect(back.thisDevice, 'laptop');
    expect(back.beaconMode, isTrue);
    expect([for (final b in back.beacons) b.name], ['LAPTOP', 'TOWER']);
    expect(back.beacons.first.runs.single.title, 'Parser');
    expect(
      [for (final d in back.devices) (d.device.name, d.trusted, d.refused)],
      [
        ('Pixel', false, false),
        ('OnePlus', true, false),
        ('Old phone', false, true),
      ],
    );
    expect(back.devices[1].device.trustedBy, {'laptop': 1});
    expect(back.devices[2].device.revoked, isTrue);
    expect(back.devices.first.device.code, code);
  });
}
