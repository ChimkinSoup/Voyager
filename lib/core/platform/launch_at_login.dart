import 'dart:io';

import 'package:win32/win32.dart';
import 'package:win32_registry/win32_registry.dart';

/// Launch argument that starts Voyager hidden in the tray. The Run entry
/// passes it, so a login brings the global hotkeys up without the window.
const kStartHiddenArg = '--hidden';

const _runKeyPath = r'Software\Microsoft\Windows\CurrentVersion\Run';

/// Where Task Manager and Settings → Startup apps record an entry turned off.
/// They leave the Run value in place and store a flag here under its name.
const _approvedKeyPath =
    r'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run';
const _valueName = 'Voyager';

/// The Run entry's command for this executable.
String get _command => '"${Platform.resolvedExecutable}" $kStartHiddenArg';

enum LaunchAtLogin {
  off,
  on,

  /// Windows starts a Voyager at login, but a build elsewhere on disk.
  /// Turning it on points the entry here.
  elsewhere,
}

LaunchAtLogin launchAtLoginState() {
  final key = Registry.openPath(RegistryHive.currentUser, path: _runKeyPath);
  final String? command;
  try {
    command = key.getStringValue(_valueName);
  } finally {
    key.close();
  }
  if (command == null || _disabledByWindows()) return LaunchAtLogin.off;
  return command == _command ? LaunchAtLogin.on : LaunchAtLogin.elsewhere;
}

void setLaunchAtLogin(bool enabled) {
  final key = Registry.openPath(
    RegistryHive.currentUser,
    path: _runKeyPath,
    desiredAccessRights: AccessRights.allAccess,
  );
  try {
    if (enabled) {
      key.createValue(RegistryValue.string(_valueName, _command));
    } else if (key.getStringValue(_valueName) != null) {
      key.deleteValue(_valueName);
    }
  } finally {
    key.close();
  }
  // Otherwise an entry turned off in Startup apps stays off, and one written
  // again later inherits the flag.
  _clearApproval();
}

/// The flag's first byte is odd when the entry is turned off.
bool _disabledByWindows() {
  final RegistryKey key;
  try {
    key = Registry.openPath(RegistryHive.currentUser, path: _approvedKeyPath);
  } on WindowsException {
    return false; // Created the first time an entry is toggled there.
  }
  try {
    final flag = key.getBinaryValue(_valueName);
    return flag != null && flag.isNotEmpty && flag.first.isOdd;
  } finally {
    key.close();
  }
}

void _clearApproval() {
  final RegistryKey key;
  try {
    key = Registry.openPath(
      RegistryHive.currentUser,
      path: _approvedKeyPath,
      desiredAccessRights: AccessRights.allAccess,
    );
  } on WindowsException {
    return;
  }
  try {
    if (key.getBinaryValue(_valueName) != null) key.deleteValue(_valueName);
  } finally {
    key.close();
  }
}
