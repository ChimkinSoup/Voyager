import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/reminders/reminder_engine.dart';
import 'package:voyager/core/reminders/reminder_labels.dart';
import 'package:voyager/core/reminders/reminder_os_notifier.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/core/widgets/confirm_dialog.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/prompt_name_dialog.dart';
import 'package:voyager/domain/models/reminder_models.dart';

/// Settings → Devices (`SCHEDULED_REMINDERS_HLD.md` §7): the installations
/// reminders can be aimed at, and whether this one may show notifications.
class DevicesSettingsSection extends ConsumerWidget {
  const DevicesSettingsSection({super.key});

  Future<void> _rename(
    BuildContext context,
    WidgetRef ref,
    DeviceRegistration device,
  ) async {
    final name = await showPromptNameDialog(
      context,
      title: 'Rename device',
      initial: device.displayName,
    );
    final trimmed = name?.trim();
    if (trimmed == null || trimmed.isEmpty || trimmed == device.displayName) {
      return;
    }
    final now = utcNow();
    await ref
        .read(reminderRepositoryProvider)
        .upsertDevice(
          device.copyWith(
            displayName: trimmed,
            updatedAt: now,
            version: device.version + 1,
          ),
        );
    ref.invalidate(deviceRegistrationsProvider);
  }

  Future<void> _remove(
    BuildContext context,
    WidgetRef ref,
    DeviceRegistration device,
  ) async {
    final confirmed = await showConfirmDialog(
      context,
      title: 'Remove device?',
      message:
          '"${device.displayName}" will stop showing reminders until it is '
          'added back from its own Settings.',
      confirmLabel: 'Remove',
    );
    if (!confirmed) return;
    final now = utcNow();
    await ref
        .read(reminderRepositoryProvider)
        .upsertDevice(
          device.copyWith(
            deletedAt: now,
            updatedAt: now,
            version: device.version + 1,
          ),
        );
    ref.invalidate(deviceRegistrationsProvider);
  }

  Future<void> _addBack(WidgetRef ref, DeviceRegistration device) async {
    final now = utcNow();
    await ref
        .read(reminderRepositoryProvider)
        .upsertDevice(
          device.copyWith(
            clearDeletedAt: true,
            lastSeenAt: now,
            updatedAt: now,
            version: device.version + 1,
          ),
        );
    ref.invalidate(deviceRegistrationsProvider);
    ref.invalidate(thisDeviceRegistrationProvider);
  }

  static IconData _platformIcon(DevicePlatform platform) => switch (platform) {
    DevicePlatform.android ||
    DevicePlatform.ios => PhosphorIconsRegular.deviceMobile,
    DevicePlatform.web => PhosphorIconsRegular.globe,
    _ => PhosphorIconsRegular.desktop,
  };

  static String _platformName(DevicePlatform platform) => switch (platform) {
    DevicePlatform.android => 'Android',
    DevicePlatform.ios => 'iOS',
    DevicePlatform.windows => 'Windows',
    DevicePlatform.macos => 'macOS',
    DevicePlatform.linux => 'Linux',
    DevicePlatform.web => 'Web',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final devices =
        ref.watch(deviceRegistrationsProvider).valueOrNull ??
        const <DeviceRegistration>[];
    final thisDevice = ref.watch(thisDeviceRegistrationProvider).valueOrNull;
    final thisDeviceId = ref.watch(deviceIdProvider);
    final now = DateTime.now();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Devices', style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Text(
            'Scheduled reminders go to every device unless a reminder picks '
            'specific ones in its editor, in the Inbox.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        if (thisDevice?.deletedAt != null)
          ListTile(
            leading: Icon(
              PhosphorIconsRegular.warning,
              color: theme.colorScheme.error,
            ),
            title: const Text('This device was removed'),
            subtitle: const Text(
              'It shows no reminders until it is added back',
            ),
            trailing: GlassButton(
              dense: true,
              label: 'Add back',
              onPressed: () => unawaited(_addBack(ref, thisDevice!)),
            ),
          ),
        if (devices.isEmpty)
          const ListTile(
            title: Text('No devices yet'),
            subtitle: Text('A device appears here once it has signed in'),
          ),
        for (final device in devices)
          ListTile(
            leading: Icon(_platformIcon(device.platform)),
            title: Text(
              device.id == thisDeviceId
                  ? '${device.displayName} · This device'
                  : device.displayName,
            ),
            subtitle: Text(
              '${_platformName(device.platform)} · last seen '
              '${reminderWhenLabel(device.lastSeenAt, now)}',
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: 'Rename',
                  icon: const Icon(PhosphorIconsRegular.pencilSimple, size: 18),
                  onPressed: () => unawaited(_rename(context, ref, device)),
                ),
                // This device is removed from another one: removing yourself
                // from here would only silence the screen you are looking at.
                if (device.id != thisDeviceId)
                  IconButton(
                    tooltip: 'Remove',
                    icon: const Icon(PhosphorIconsRegular.trash, size: 18),
                    onPressed: () => unawaited(_remove(context, ref, device)),
                  ),
              ],
            ),
          ),
        const _NotificationPermissionTile(),
      ],
    );
  }
}

class _NotificationPermissionTile extends ConsumerStatefulWidget {
  const _NotificationPermissionTile();

  @override
  ConsumerState<_NotificationPermissionTile> createState() =>
      _NotificationPermissionTileState();
}

class _NotificationPermissionTileState
    extends ConsumerState<_NotificationPermissionTile>
    with WidgetsBindingObserver {
  ReminderPermission? _permission;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_check());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Back from the system settings page, where the answer may have changed.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_check());
  }

  Future<void> _check() async {
    final permission = await ref.read(reminderOsNotifierProvider).permission();
    if (mounted) setState(() => _permission = permission);
  }

  @override
  Widget build(BuildContext context) {
    final permission = _permission;
    if (permission == null || permission == ReminderPermission.unsupported) {
      return const SizedBox.shrink();
    }
    final denied = permission == ReminderPermission.denied;
    return ListTile(
      leading: Icon(
        denied ? PhosphorIconsRegular.bellSlash : PhosphorIconsRegular.bell,
      ),
      title: Text(
        denied ? 'Notifications are off' : 'Notifications are allowed',
      ),
      subtitle: Text(
        denied
            ? 'Reminders still show inside the app, but not as system '
                  'notifications'
            : 'Due reminders also show as system notifications',
      ),
      trailing: denied
          ? GlassButton(
              dense: true,
              label: 'Open settings',
              onPressed: () => unawaited(
                ref.read(reminderOsNotifierProvider).openSystemSettings(),
              ),
            )
          : null,
    );
  }
}
