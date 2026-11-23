import 'dart:async';

import 'package:flutter/material.dart';
import 'package:voyager/features/gaia/companion/gaia_button.dart';
import 'package:voyager/features/gaia/companion/gaia_controller.dart';
import 'package:voyager/features/gaia/companion/gaia_settings_panel.dart';
import 'package:voyager/features/gaia/companion/gaia_style.dart';
import 'package:voyager/features/gaia/companion/gaia_toast.dart';
import 'package:voyager/features/gaia/gaia_pipe.dart';
import 'package:voyager/features/gaia/remote/gaia_remote.dart';

/// The online dot: a soft green beside the ink, as the page's is green.
const _online = Color(0xFF8FD9A8);

/// The settings panel's Status tab (GAIA_SETTINGS_HLD.md §4), as the desktop
/// Gaia page's (GAIA_HLD.md §12.2): every desktop's heartbeat, this desktop's
/// beacon mode, and the devices that asked to pair, with Pair, Revoke and
/// Decline or Remove. It updates live from the main instance's `status`
/// events, which come only while this tab shows (§3.3).
class GaiaStatusTab extends StatefulWidget {
  const GaiaStatusTab({super.key, required this.controller});

  final GaiaController controller;

  @override
  State<GaiaStatusTab> createState() => _GaiaStatusTabState();
}

class _GaiaStatusTabState extends State<GaiaStatusTab> {
  /// Redraws "online" and "last seen" as time passes: each second while a
  /// sleep or shutdown counts down, else every 30 s, as the page does.
  Timer? _tick;
  Duration? _period;

  void _keepTime(GaiaStatus? status) {
    final now = DateTime.now();
    final period =
        (status?.beacons ?? const []).any(
          (b) => b.power != null && b.onlineAt(now),
        )
        ? const Duration(seconds: 1)
        : const Duration(seconds: 30);
    if (period == _period) return;
    _period = period;
    _tick?.cancel();
    _tick = Timer.periodic(period, (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action, String failed) async {
    try {
      await action();
    } on GaiaPipeException catch (error) {
      if (mounted) {
        showGaiaToast(
          context,
          mark: GaiaToastMark.error,
          title: failed,
          body: error.message,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final status = controller.status;
    _keepTime(status);
    final now = DateTime.now();
    return GaiaPanelScroll(
      key: const PageStorageKey('gaia panel status'),
      slivers: [
        if (status == null)
          const SliverToBoxAdapter(child: SizedBox.shrink())
        else if (!status.signedIn)
          const SliverToBoxAdapter(
            child: GaiaPanelNote(
              'Sign in to Voyager to see your desktops and pair devices.',
            ),
          )
        else
          SliverList.list(
            children: [
              const GaiaPanelHeading('Desktops'),
              if (status.beacons.isEmpty)
                const GaiaPanelNote(
                  'No desktop has Gaia running under this account yet.',
                ),
              for (final beacon in status.beacons)
                _BeaconRow(
                  key: ValueKey('beacon ${beacon.deviceId}'),
                  beacon: beacon,
                  here: beacon.deviceId == status.thisDevice,
                  now: now,
                ),
              if (status.beaconMode case final on?) ...[
                const GaiaPanelHeading('This desktop'),
                GaiaPanelSwitch(
                  title: 'Beacon mode',
                  subtitle:
                      'Stays awake so a paired phone can run Gaia here, with '
                      'the display allowed to turn off. While plugged in, '
                      'closing the lid does nothing; on battery it still '
                      'sleeps.',
                  value: on,
                  onChanged: (on) => _run(
                    () => controller.setBeaconMode(on),
                    "Couldn't change beacon mode",
                  ),
                ),
              ],
              const GaiaPanelHeading('Paired devices'),
              const GaiaPanelNote(
                'A phone pairs to send this desktop messages. Trust one only '
                'when the code it shows matches.',
              ),
              if (status.devices.isEmpty) const GaiaPanelNote('None yet.'),
              for (final (:device, :trusted, :refused) in status.devices)
                _DeviceRow(
                  key: ValueKey('device ${device.deviceId}'),
                  device: device,
                  trusted: trusted,
                  refused: refused,
                  onPair: () => _pair(device),
                  onRevoke: () => _run(
                    () => controller.revokeDevice(device),
                    "Couldn't revoke",
                  ),
                  onForget: () => _run(
                    () => controller.forgetDevice(device),
                    device.revoked ? "Couldn't remove" : "Couldn't decline",
                  ),
                ),
            ],
          ),
      ],
    );
  }

  /// Pairing trusts the key behind [device]'s code: the user checks the
  /// code matches what the device shows first, as on the page.
  Future<void> _pair(GaiaDevice device) async {
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
              child: SelectableText(
                device.code,
                style: Theme.of(context).textTheme.headlineMedium,
              ),
            ),
          ],
        ),
        actions: [
          GaiaButton(
            label: 'Cancel',
            onPressed: () => Navigator.of(context).pop(false),
            color: Theme.of(context).colorScheme.error,
          ),
          GaiaButton(
            label: 'They match',
            onPressed: () => Navigator.of(context).pop(true),
          ),
        ],
      ),
    );
    if (ok == true) {
      await _run(() => widget.controller.pairDevice(device), "Couldn't pair");
    }
  }
}

/// A Gaia row: hover fill, a leading icon, a title over a status line, and
/// [actions] at the right.
class _StatusRow extends StatefulWidget {
  const _StatusRow({
    required this.leading,
    required this.title,
    required this.status,
    this.actions = const [],
  });

  final Widget leading;
  final String title;
  final String status;
  final List<Widget> actions;

  @override
  State<_StatusRow> createState() => _StatusRowState();
}

class _StatusRowState extends State<_StatusRow> {
  var _hovered = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
    onEnter: (_) => setState(() => _hovered = true),
    onExit: (_) => setState(() => _hovered = false),
    child: AnimatedContainer(
      duration: GaiaMotion.quick,
      margin: const EdgeInsets.only(bottom: 2),
      padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
      decoration: BoxDecoration(
        color: _hovered ? GaiaInk.hover : GaiaInk.hover.withValues(alpha: 0),
        borderRadius: BorderRadius.circular(GaiaRadius.row),
      ),
      child: Row(
        children: [
          SizedBox(width: 18, child: Center(child: widget.leading)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.title,
                  overflow: TextOverflow.ellipsis,
                  style: GaiaType.row.copyWith(
                    color: _hovered ? GaiaInk.bright : GaiaInk.dim,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  widget.status,
                  style: GaiaType.label.copyWith(
                    color: GaiaInk.muted,
                    fontWeight: FontWeight.w400,
                  ),
                ),
              ],
            ),
          ),
          for (final action in widget.actions) ...[
            const SizedBox(width: 6),
            action,
          ],
        ],
      ),
    ),
  );
}

class _BeaconRow extends StatelessWidget {
  const _BeaconRow({
    super.key,
    required this.beacon,
    required this.here,
    required this.now,
  });

  final GaiaBeacon beacon;

  /// This desktop's own.
  final bool here;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
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
    return _StatusRow(
      leading: Container(
        width: 9,
        height: 9,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: online ? _online : GaiaInk.faint,
        ),
      ),
      title: here ? '${beacon.name} (this desktop)' : beacon.name,
      status: status,
    );
  }
}

class _DeviceRow extends StatelessWidget {
  const _DeviceRow({
    super.key,
    required this.device,
    required this.trusted,
    required this.refused,
    required this.onPair,
    required this.onRevoke,
    required this.onForget,
  });

  final GaiaDevice device;
  final bool trusted;
  final bool refused;
  final VoidCallback onPair;
  final VoidCallback onRevoke;
  final VoidCallback onForget;

  @override
  Widget build(BuildContext context) {
    final refused = !device.revoked && this.refused;
    final status = device.revoked
        ? 'Revoked'
        : trusted
        ? 'Paired with this desktop'
        : refused
        ? "This desktop turned down this device's key. Remove the request, "
              'and pair again from the device for a new one.'
        : 'Not paired with this desktop · code ${device.code}';
    return _StatusRow(
      leading: Icon(
        device.platform == 'android'
            ? Icons.smartphone_outlined
            : Icons.computer_outlined,
        size: 18,
        color: GaiaInk.muted,
      ),
      title: device.name,
      status: status,
      actions: [
        if (!device.revoked && !trusted && !refused)
          GaiaButton(label: 'Pair', size: 30, padding: 10, onPressed: onPair),
        if (!device.revoked && trusted)
          GaiaButton(
            label: 'Revoke',
            size: 30,
            padding: 10,
            onPressed: onRevoke,
          ),
        if (device.revoked || !trusted)
          Tooltip(
            message: device.revoked ? 'Remove' : 'Decline',
            child: GaiaButton(icon: Icons.close, size: 30, onPressed: onForget),
          ),
      ],
    );
  }
}
