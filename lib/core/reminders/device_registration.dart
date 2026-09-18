import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/domain/models/reminder_models.dart';
import 'package:voyager/domain/repositories/repositories.dart';

/// How stale [DeviceRegistration.lastSeenAt] may get before a launch or resume
/// refreshes it. Every refresh is a synced write, and "last seen an hour ago"
/// says everything the Devices list needs.
const Duration kDeviceLastSeenRefresh = Duration(hours: 1);

DevicePlatform currentDevicePlatform() {
  if (kIsWeb) return DevicePlatform.web;
  return switch (defaultTargetPlatform) {
    TargetPlatform.android => DevicePlatform.android,
    TargetPlatform.iOS => DevicePlatform.ios,
    TargetPlatform.windows => DevicePlatform.windows,
    TargetPlatform.macOS => DevicePlatform.macos,
    TargetPlatform.linux => DevicePlatform.linux,
    TargetPlatform.fuchsia => DevicePlatform.linux,
  };
}

/// A first guess at the device's name, which the user can rename in Settings.
/// Android reports no useful hostname, so it gets a plain label.
String defaultDeviceName() {
  final platform = currentDevicePlatform();
  if (platform == DevicePlatform.android) return 'Android device';
  try {
    final host = Platform.localHostname;
    if (host.isNotEmpty && host != 'localhost') return host;
  } catch (_) {}
  return switch (platform) {
    DevicePlatform.windows => 'Windows PC',
    DevicePlatform.macos => 'Mac',
    DevicePlatform.linux => 'Linux PC',
    DevicePlatform.ios => 'iPhone',
    DevicePlatform.web => 'Browser',
    DevicePlatform.android => 'Android device',
  };
}

/// Registers this installation, or refreshes its last-seen time
/// (`SCHEDULED_REMINDERS_HLD.md` §4.1).
///
/// Refresh runs after a pull, never before: the local row is then the merged
/// one, so a rename made on another device is carried forward rather than
/// overwritten. Creating the row needs no pull — [DeviceRegistration.id] is the
/// device id, which never syncs, so no local row means no remote one either.
/// With [createOnly] that is all this does, which is what a launch whose pull
/// never runs uses to still list itself in Settings → Devices.
///
/// A registration removed in Settings stays removed. This device then stops
/// delivering reminders until it is registered again from its own Settings
/// page — removing a device that is still in use has to mean something.
Future<void> registerThisDevice(
  ReminderRepository repository,
  String deviceId, {
  DateTime? now,
  bool createOnly = false,
}) async {
  final stamp = now ?? utcNow();
  final existing = await repository.getDevice(deviceId);
  if (existing == null) {
    await repository.upsertDevice(
      DeviceRegistration(
        id: deviceId,
        createdAt: stamp,
        updatedAt: stamp,
        displayName: defaultDeviceName(),
        platform: currentDevicePlatform(),
        lastSeenAt: stamp,
      ),
    );
    return;
  }
  if (createOnly) return;
  if (existing.deletedAt != null) return;
  if (stamp.difference(existing.lastSeenAt) < kDeviceLastSeenRefresh) return;
  await repository.upsertDevice(
    existing.copyWith(
      lastSeenAt: stamp,
      updatedAt: stamp,
      version: existing.version + 1,
    ),
  );
}
