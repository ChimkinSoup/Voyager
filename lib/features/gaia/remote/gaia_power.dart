import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:voyager/core/platform/app_data_directory.dart';
import 'package:voyager/core/platform/dev_profile.dart';
import 'package:win32/win32.dart';

/// How long a remote sleep or shutdown waits, cancellable, before it goes
/// (§12.2).
const kGaiaPowerCountdown = Duration(seconds: 30);

/// A sleep or shutdown counting down: which, and when it goes.
typedef GaiaPowerCountdown = ({String kind, DateTime at});

/// Remote power and beacon mode on a desktop (GAIA_HLD.md §12.1, §12.2).
///
/// A `sleep` or `shutdown` command counts down [kGaiaPowerCountdown] first:
/// the desktop's tray and the phone can cancel it. Beacon mode keeps the
/// system awake with the display allowed off, and sets the lid's AC action
/// to "do nothing", remembering the original to put back when it's turned
/// off or Voyager quits, and on the next start after a crash. On battery
/// the lid still sleeps the laptop: there's no override for that.
///
/// A dev profile does none of it for real: it logs what it would do, so QA
/// never sleeps, shuts down, or changes the power plan of the machine it
/// runs on.
class GaiaPower {
  GaiaPower({
    Future<File> Function()? stateFile,
    Future<void> Function(String kind)? execute,
    Future<int?> Function()? readLidAc,
    Future<void> Function(int value)? writeLidAc,
    bool Function()? onBattery,
    bool? dryRun,
  }) : _stateFile = stateFile ?? _defaultStateFile,
       _dryRun = dryRun ?? devProfile != null,
       _executeOverride = execute,
       _readLidAc = readLidAc ?? _queryLidAc,
       _writeLidAc = writeLidAc ?? _setLidAc,
       _onBattery = onBattery ?? _systemOnBattery;

  final Future<File> Function() _stateFile;
  final bool _dryRun;
  final Future<void> Function(String kind)? _executeOverride;
  final Future<int?> Function() _readLidAc;
  final Future<void> Function(int value) _writeLidAc;
  final bool Function() _onBattery;

  /// The countdown in progress; null for none.
  final countdown = ValueNotifier<GaiaPowerCountdown?>(null);
  Timer? _timer;

  /// Beacon mode, as last set.
  final beaconMode = ValueNotifier<bool>(false);

  /// The lid's AC action before beacon mode changed it; null when it
  /// hasn't.
  int? _savedLidAc;

  bool get onBattery => _onBattery();

  /// Counts down to [kind] (`sleep` or `shutdown`), over any countdown
  /// already going.
  void startCountdown(String kind) {
    _timer?.cancel();
    countdown.value = (kind: kind, at: DateTime.now().add(kGaiaPowerCountdown));
    _timer = Timer(kGaiaPowerCountdown, () {
      countdown.value = null;
      unawaited(_execute(kind));
    });
  }

  /// False when nothing was counting down.
  bool cancelCountdown() {
    if (countdown.value == null) return false;
    _timer?.cancel();
    countdown.value = null;
    return true;
  }

  Future<void> _execute(String kind) async {
    if (_executeOverride case final execute?) return execute(kind);
    if (_dryRun) {
      debugPrint('[gaia] power: would $kind now (dev profile, not done)');
      return;
    }
    switch (kind) {
      case 'sleep':
        // SetSuspendState(hibernate: false, force: false, wakeEvents: off).
        final suspend = DynamicLibrary.open('powrprof.dll')
            .lookupFunction<
              Uint8 Function(Uint8, Uint8, Uint8),
              int Function(int, int, int)
            >('SetSuspendState');
        suspend(0, 0, 0);
      case 'shutdown':
        await Process.run('shutdown', ['/s', '/t', '0']);
    }
  }

  // Beacon mode.

  /// At start: beacon mode as it was left, and the lid put back if a crash
  /// left it changed with beacon mode off.
  Future<void> restore() async {
    final state = await _readState();
    _savedLidAc = state.savedLidAc;
    if (state.on) {
      await setBeaconMode(true);
    } else if (_savedLidAc != null) {
      await _putLidBack();
    }
  }

  Future<void> setBeaconMode(bool on) async {
    if (on) {
      SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED);
      if (_savedLidAc == null) {
        final current = await _readLidAc();
        if (current != null && current != 0) {
          _savedLidAc = current;
          await _writeState(on: true);
          await _setLid(0);
        }
      }
    } else {
      SetThreadExecutionState(ES_CONTINUOUS);
      await _putLidBack();
    }
    beaconMode.value = on;
    await _writeState(on: on);
  }

  /// On quit: the lid as it was, beacon mode kept for the next start.
  Future<void> shutdown() async {
    cancelCountdown();
    if (beaconMode.value) {
      await _putLidBack();
      await _writeState(on: true);
    }
  }

  Future<void> _putLidBack() async {
    final saved = _savedLidAc;
    if (saved == null) return;
    await _setLid(saved);
    _savedLidAc = null;
  }

  Future<void> _setLid(int value) async {
    if (_dryRun) {
      debugPrint('[gaia] power: would set the AC lid action to $value');
      return;
    }
    await _writeLidAc(value);
  }

  Future<({bool on, int? savedLidAc})> _readState() async {
    try {
      final file = await _stateFile();
      if (!await file.exists()) return (on: false, savedLidAc: null);
      final json = (jsonDecode(await file.readAsString()) as Map)
          .cast<String, Object?>();
      return (
        on: json['on'] == true,
        savedLidAc: (json['savedLidAc'] as num?)?.toInt(),
      );
    } on FormatException {
      return (on: false, savedLidAc: null);
    }
  }

  Future<void> _writeState({required bool on}) async {
    final file = await _stateFile();
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode({'on': on, 'savedLidAc': _savedLidAc}));
  }

  static Future<File> _defaultStateFile() async =>
      File(p.join((await appDataDirectory()).path, 'gaia_beacon_mode.json'));

  /// `powercfg`'s current AC index for the lid close action. `/qh`, since
  /// Windows can hide the setting, and `/q` then leaves it out.
  static Future<int?> _queryLidAc() async {
    final result = await Process.run('powercfg', [
      '/qh',
      'SCHEME_CURRENT',
      'SUB_BUTTONS',
      'LIDACTION',
    ]);
    return gaiaParseLidAc('${result.stdout}');
  }

  static Future<void> _setLidAc(int value) async {
    await Process.run('powercfg', [
      '/setacvalueindex',
      'SCHEME_CURRENT',
      'SUB_BUTTONS',
      'LIDACTION',
      '$value',
    ]);
    await Process.run('powercfg', ['/setactive', 'SCHEME_CURRENT']);
  }

  static bool _systemOnBattery() {
    final status = calloc<SYSTEM_POWER_STATUS>();
    try {
      if (GetSystemPowerStatus(status) == 0) return false;
      return status.ref.ACLineStatus == 0;
    } finally {
      calloc.free(status);
    }
  }
}

/// The AC index in `powercfg /q … LIDACTION`'s output; null when it has
/// none, as on a desktop without a lid.
int? gaiaParseLidAc(String output) {
  final match = RegExp(
    r'Current AC Power Setting Index:\s*0x([0-9a-fA-F]+)',
  ).firstMatch(output);
  return match == null ? null : int.parse(match.group(1)!, radix: 16);
}
