import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/core/platform/platform_info.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/voyager_text_field.dart';
import 'package:voyager/features/gaia/host/gaia_host.dart';
import 'package:voyager/features/gaia/page/gaia_providers.dart';
import 'package:voyager/features/gaia/page/gaia_remote_chat.dart';
import 'package:voyager/features/gaia/remote/gaia_device_keys.dart';
import 'package:voyager/features/gaia/remote/gaia_remote.dart';
import 'package:voyager/features/gaia/remote/gaia_remote_client.dart';

/// The Gaia page's Status tab (GAIA_HLD.md §12.2, §17): each desktop's
/// heartbeat, and the paired devices. A desktop trusts a device once the
/// user checks its pairing code there, and revokes it; the phone asks to
/// pair, shows its code, and sends Abort and Rearm.
class GaiaStatusTab extends ConsumerWidget {
  const GaiaStatusTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final beacons = ref.watch(gaiaBeaconsProvider).valueOrNull ?? const [];
    final devices = ref.watch(gaiaDevicesProvider).valueOrNull ?? const [];
    final now = ref.watch(gaiaClockProvider).valueOrNull ?? DateTime.now();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _Label('Desktops'),
        if (beacons.isEmpty)
          Text(
            'No desktop has Gaia running under this account yet.',
            style: muted,
          ),
        for (final beacon in beacons) _BeaconRow(beacon: beacon, now: now),
        const SizedBox(height: 20),
        if (isWindows) ...[
          const _Label('This desktop'),
          const _ThisDesktop(),
          const SizedBox(height: 20),
          const _Label('Paired devices'),
          Text(
            'A phone pairs to send this desktop messages. Trust one only '
            'when the code it shows matches.',
            style: muted,
          ),
          const SizedBox(height: 8),
          if (devices.isEmpty) Text('None yet.', style: muted),
          for (final device in devices) _DeviceRow(device: device),
        ] else
          const _ThisPhone(),
      ],
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(text, style: Theme.of(context).textTheme.titleSmall),
  );
}

class _BeaconRow extends ConsumerWidget {
  const _BeaconRow({required this.beacon, required this.now});

  final GaiaBeacon beacon;
  final DateTime now;

  /// Sends [type] here, and says so if it didn't run.
  Future<void> _send(
    BuildContext context,
    GaiaRemoteClient client,
    GaiaRemoteCommandType type,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final error = await client.sendAndSettle(type, target: beacon.deviceId);
      if (error != null) {
        messenger.showSnackBar(SnackBar(content: Text(error)));
      }
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text("Couldn't send: $error")));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    // A countdown ticks by the second; the rest moves with the 30 s clock.
    final now = beacon.power == null
        ? this.now
        : ref.watch(gaiaTickProvider).valueOrNull ?? this.now;
    final online = beacon.onlineAt(now);
    final runs = beacon.runs.length;
    final status = [
      if (!online)
        beacon.heartbeatAt == 0
            ? 'Offline'
            : 'Offline · last seen '
                  '${gaiaWhen(DateTime.fromMillisecondsSinceEpoch(beacon.heartbeatAt))}'
      else ...[
        'Online',
        if (runs == 1) '1 run' else if (runs > 1) '$runs runs',
        if (beacon.aborted) 'Aborted',
        if (beacon.beaconMode)
          beacon.onBattery
              ? 'Beacon mode, on battery: sleeps if the lid closes'
              : 'Beacon mode',
        if (beacon.power case final power?)
          '${power.kind == 'sleep' ? 'Sleeping' : 'Shutting down'} in '
              '${((power.at - now.millisecondsSinceEpoch) / 1000).ceil().clamp(0, 30)} s',
        if (beacon.livePaused) 'Live view paused for today',
      ],
    ].join(' · ');
    final client = ref.watch(gaiaRemoteClientProvider).valueOrNull;
    // Only a desktop that trusts this phone takes its commands.
    final paired =
        (ref.watch(gaiaDevicesProvider).valueOrNull ?? const [])
            .where(
              (d) =>
                  d.deviceId == client?.deviceId &&
                  d.publicKey == client?.key.publicKey &&
                  !d.revoked,
            )
            .firstOrNull
            ?.trustedBy
            .containsKey(beacon.deviceId) ??
        false;
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        PhosphorIconsFill.circle,
        size: 10,
        color: online ? Colors.greenAccent : theme.colorScheme.outline,
      ),
      title: Text(beacon.name),
      subtitle: Text(status),
      trailing: !isWindows && online && paired && client != null
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                GlassButton(
                  dense: true,
                  label: beacon.aborted ? 'Rearm' : 'Abort',
                  icon: Icon(
                    beacon.aborted
                        ? PhosphorIconsRegular.play
                        : PhosphorIconsRegular.hand,
                    size: 13,
                  ),
                  onPressed: () => unawaited(
                    _send(
                      context,
                      client,
                      beacon.aborted
                          ? GaiaRemoteCommandType.rearm
                          : GaiaRemoteCommandType.abort,
                    ),
                  ),
                ),
                PopupMenuButton<GaiaRemoteCommandType>(
                  tooltip: 'Power',
                  icon: const Icon(PhosphorIconsRegular.power, size: 18),
                  onSelected: (type) => _power(context, client, type),
                  itemBuilder: (_) => [
                    if (beacon.power != null)
                      const PopupMenuItem(
                        value: GaiaRemoteCommandType.cancelPower,
                        child: Text('Cancel'),
                      )
                    else ...const [
                      PopupMenuItem(
                        value: GaiaRemoteCommandType.sleep,
                        child: Text('Sleep'),
                      ),
                      PopupMenuItem(
                        value: GaiaRemoteCommandType.shutdown,
                        child: Text('Shut down'),
                      ),
                    ],
                  ],
                ),
              ],
            )
          : null,
    );
  }

  /// Sleep and shut down are one-way (§12.2): the phone can't wake the
  /// desktop again, which it says before sending.
  Future<void> _power(
    BuildContext context,
    GaiaRemoteClient client,
    GaiaRemoteCommandType type,
  ) async {
    if (type != GaiaRemoteCommandType.cancelPower) {
      final verb = type == GaiaRemoteCommandType.sleep
          ? 'Put ${beacon.name} to sleep'
          : 'Shut ${beacon.name} down';
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('$verb?'),
          content: Text(
            'It goes in 30 seconds, and can be cancelled until then. This '
            "phone can't wake it again: Gaia's chats won't run there until "
            'someone does.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(
                type == GaiaRemoteCommandType.sleep ? 'Sleep' : 'Shut down',
              ),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    if (context.mounted) await _send(context, client, type);
  }
}

/// This desktop's beacon mode (§12.1): awake for remote runs, the lid's
/// AC action set to do nothing until it's turned off.
class _ThisDesktop extends StatelessWidget {
  const _ThisDesktop();

  @override
  Widget build(BuildContext context) {
    final power = GaiaHost.instance.power;
    if (power == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return ValueListenableBuilder(
      valueListenable: power.beaconMode,
      builder: (context, on, _) => SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Beacon mode'),
        subtitle: Text(
          'Stays awake so a paired phone can run Gaia here, with the display '
          'allowed to turn off. While plugged in, closing the lid does '
          'nothing; on battery it still sleeps.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        value: on,
        onChanged: (on) => unawaited(power.setBeaconMode(on)),
      ),
    );
  }
}

class _DeviceRow extends ConsumerWidget {
  const _DeviceRow({required this.device});

  final GaiaDevice device;

  Future<void> _trust(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Pair ${device.name}?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              "Check that ${device.name}'s Gaia page shows this code. "
              "If it doesn't, someone else asked: don't pair.",
            ),
            const SizedBox(height: 16),
            Center(
              child: Text(
                device.code,
                style: Theme.of(context).textTheme.headlineMedium,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('They match'),
          ),
        ],
      ),
    );
    if (ok == true) await GaiaHost.instance.beacon?.trustDevice(device);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final beacon = GaiaHost.instance.beacon;
    final trusted = beacon?.trusts(device) ?? false;
    final refused = !device.revoked && (beacon?.refuses(device) ?? false);
    final status = device.revoked
        ? 'Revoked'
        : trusted
        ? 'Paired with this desktop'
        : refused
        ? "This desktop turned down this device's key. Remove the request, "
              'and pair again from the device for a new one.'
        : 'Not paired with this desktop · code ${device.code}';
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        device.platform == 'android'
            ? PhosphorIconsRegular.deviceMobile
            : PhosphorIconsRegular.desktop,
        size: 18,
      ),
      title: Text(device.name),
      subtitle: Text(status),
      trailing: beacon == null
          ? null
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!device.revoked && !trusted && !refused)
                  GlassButton(
                    dense: true,
                    label: 'Pair',
                    onPressed: () => _trust(context),
                  ),
                if (!device.revoked && trusted)
                  GlassButton(
                    dense: true,
                    label: 'Revoke',
                    onPressed: () => beacon.revokeDevice(device),
                  ),
                if (device.revoked || !trusted)
                  IconButton(
                    tooltip: device.revoked ? 'Remove' : 'Decline',
                    icon: const Icon(PhosphorIconsRegular.x, size: 16),
                    onPressed: () => beacon.forgetDevice(device),
                  ),
              ],
            ),
    );
  }
}

/// The phone's own pairing: ask, then show the code each desktop checks.
class _ThisPhone extends ConsumerStatefulWidget {
  const _ThisPhone();

  @override
  ConsumerState<_ThisPhone> createState() => _ThisPhoneState();
}

class _ThisPhoneState extends ConsumerState<_ThisPhone> {
  final _name = TextEditingController(text: 'Phone');
  var _busy = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _pair({required bool newKey}) async {
    setState(() => _busy = true);
    try {
      if (newKey) {
        await GaiaDeviceKey.reset();
        ref.invalidate(gaiaDeviceKeyProvider);
      }
      final client = await ref.read(gaiaRemoteClientProvider.future);
      await client?.requestPairing(
        name: _name.text.trim().isEmpty ? 'Phone' : _name.text.trim(),
        platform: Platform.operatingSystem,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final client = ref.watch(gaiaRemoteClientProvider).valueOrNull;
    final devices = ref.watch(gaiaDevicesProvider).valueOrNull ?? const [];
    final beacons = ref.watch(gaiaBeaconsProvider).valueOrNull ?? const [];
    if (client == null) {
      return Text('Sign in to pair this phone.', style: muted);
    }
    final me = devices
        .where((device) => device.deviceId == client.deviceId)
        .firstOrNull;
    final requested = me != null && me.publicKey == client.key.publicKey;
    final trustedBy = [
      for (final beacon in beacons)
        if (me?.trustedBy.containsKey(beacon.deviceId) ?? false) beacon.name,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _Label('This phone'),
        if (!requested || me.revoked) ...[
          Text(
            me?.revoked ?? false
                ? 'This phone was revoked. Pair it again to send messages '
                      'to your desktops.'
                : 'Pair this phone to send messages to Gaia on your '
                      'desktops, answer its cards and stop its runs.',
            style: muted,
          ),
          const SizedBox(height: 8),
          VoyagerTextField(
            controller: _name,
            decoration: const InputDecoration(
              labelText: 'Name for this phone',
              isDense: true,
            ),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: GlassButton(
              label: 'Pair',
              icon: const Icon(PhosphorIconsRegular.link, size: 13),
              onPressed: _busy
                  ? null
                  // With no request on file it may have been turned down or
                  // removed, and desktops remember that key: start afresh.
                  : () => _pair(newKey: me?.revoked ?? true),
            ),
          ),
        ] else ...[
          Text(
            'On each desktop, open the Gaia page, then Status, and pair '
            '${me.name} once it shows this code:',
            style: muted,
          ),
          const SizedBox(height: 12),
          Center(
            child: Text(
              client.pairingCode,
              style: theme.textTheme.headlineMedium,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            trustedBy.isEmpty
                ? 'Not paired with any desktop yet.'
                : 'Paired with ${trustedBy.join(', ')}.',
            style: muted,
          ),
        ],
      ],
    );
  }
}
