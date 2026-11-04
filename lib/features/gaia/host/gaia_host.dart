import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:path/path.dart' as p;
import 'package:voyager/core/platform/app_data_directory.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/domain/repositories/repositories.dart';
import 'package:voyager/features/gaia/gaia_keybinds.dart';
import 'package:voyager/features/gaia/gaia_pipe.dart';
import 'package:voyager/features/gaia/gaia_text_settings.dart';
import 'package:voyager/features/gaia/host/gaia_capture.dart';
import 'package:voyager/features/gaia/host/gaia_chat_store.dart';
import 'package:voyager/features/gaia/host/gaia_executor.dart';
import 'package:voyager/features/gaia/host/gaia_flash.dart';
import 'package:voyager/features/gaia/host/gaia_media.dart';
import 'package:voyager/features/gaia/host/gaia_memories.dart';
import 'package:voyager/features/gaia/host/gaia_os_control.dart';
import 'package:voyager/features/gaia/host/gaia_os_reads.dart';
import 'package:voyager/features/gaia/host/gaia_selection.dart';
import 'package:voyager/features/gaia/host/gaia_voyager_reads.dart';
import 'package:voyager/features/gaia/host/gaia_window_context.dart';
import 'package:voyager/features/gaia/remote/gaia_beacon_service.dart';
import 'package:voyager/features/gaia/remote/gaia_power.dart';
import 'package:voyager/features/gaia/remote/gaia_remote.dart';
import 'package:voyager/features/gaia/usage/gaia_usage.dart';
import 'package:voyager/features/hotkeys/floaters/floater_window.dart';
import 'package:voyager/features/hotkeys/hotkey_repeat.dart';
import 'package:win32/win32.dart';

/// Gaia's hotkeys (GAIA_HLD.md §15.1, §15.7), rebindable on the Gaia page:
/// each is the [GaiaKeybind] of the same name.
enum GaiaHotkey {
  small,
  large,
  window,
  fullScreen,
  split,
  region,
  screen,
  selection,
  pickUp,
  abort,
}

/// A chat with a run in progress, as the companion reports it (§14).
typedef GaiaRun = ({String chatId, String title});

/// Leads a Gaia notification's source key; the chat id follows.
const kGaiaNotificationKeyPrefix = 'gaia:';

/// The main instance's half of Gaia (GAIA_HLD.md §3.2): launches the resident
/// companion and relaunches it if it dies, owns Gaia's hotkeys and the Abort
/// flag, and serves the companion's chats from the drift-backed
/// [GaiaRepository] the app [attach]es.
///
/// The pipe protocol, companion to main: `hello` (returns `{aborted, accent,
/// deviceId, settings}`), `chats`, `putChat {chat}` (a new chat), `setSession
/// {chatId, adapter, account, sessionId, lastSeq}`, `setTier {chatId, tier}`,
/// `setLastTier {tier}`, `setTitle {chatId, title, from}`, `setPinned {chatId,
/// pinned}`, `deleteChat {chatId}` (returns `{mediaDeletedAt}`), `restoreChat
/// {chatId, mediaDeletedAt}`, `messages {chatId}`, `putMessage {message}`,
/// `attachImage {chatId, path}` (returns `{mediaId, path, mimeType, width,
/// height}`), `mediaFile {mediaId}` (a path, or null), `voyagerRead {tool,
/// arguments}` (a `voyager_*` tool's text), `memoryIndex` (§11),
/// `memoryTool {chatId, tool, arguments}` (a `memory_*` tool's text),
/// `remember {chatId, text}`, `curated {chatId, seq, memories}`, `setSeeScreen
/// {chatId, on}`, `osRead {chatId, tool, arguments}` (an `os_*` tool's `{text,
/// image, mimeType}`), `setCanControl {chatId, on}`, `osPlan {chatId, cardId,
/// tool, arguments}`, `osRun {chatId, cardId, once}`, `osDrop {cardId}`,
/// `osStop {chatId}`, `osResume {chatId}`, `autoConsented` (a bool),
/// `setAuto {chatId, on, consented}`, `isAuto {chatId}` (a bool), `rearm`,
/// and the `runs {runs}`, `runDone {chatId, title,
/// body}` and `drained` events. Main to companion: the `abort`, `stop
/// {chatId}` and `drain` requests, and the `hotkey {key}`, `openChat
/// {chatId}`, `split {left, top, width, height}`, `accent {argb}`, `settings
/// {..}` and `changed` events.
class GaiaHost {
  /// The app uses [instance]. Tests pass a fake [pipe], their own
  /// [abortFlag] file, and a [killCompanion] that kills nothing real.
  @visibleForTesting
  GaiaHost({
    GaiaPipe? pipe,
    Future<File> Function()? abortFlag,
    Future<File> Function()? autoConsent,
    Future<void> Function(int pid)? killCompanion,
    Future<Directory> Function()? captureDirectory,
    Future<GaiaScreenCapture?> Function(String path)? captureScreen,
    GaiaForegroundWindow? Function()? foregroundWindow,
    Future<GaiaWindowUia> Function(
      GaiaForegroundWindow window, {
      required bool selection,
    })?
    readUia,
    Future<String?> Function(GaiaForegroundWindow window)? copySelection,
    ({int left, int top, int width, int height}) Function(
      int hwnd, {
      required bool below,
      required bool gaiaRight,
    })?
    splitWindows,
    GaiaCursorTarget? Function()? cursorTarget,
    Future<GaiaPointedControl?> Function(GaiaCursorTarget target)? readControl,
    Future<String?> Function(
      String path,
      GaiaCursorTarget target,
      GaiaScreenRect control,
    )?
    captureControl,
    GaiaOsReads? osReads,
    GaiaOsControl? osControl,
    Future<void> Function(String? label, int accent)? showBorder,
  }) : _pipe = pipe ?? GaiaPipe(),
       _osReadsOverride = osReads,
       _osControlOverride = osControl,
       _showBorder = showBorder ?? _showBorderWindows,
       _cursorTarget = cursorTarget ?? gaiaCursorTarget,
       _readControl = readControl ?? gaiaReadControl,
       _captureControl = captureControl ?? gaiaCaptureElement,
       _splitWindows = splitWindows ?? gaiaSplitWindows,
       _copySelection = copySelection ?? gaiaCopySelection,
       _abortFlag = abortFlag ?? _defaultAbortFlag,
       _autoConsent = autoConsent ?? _defaultAutoConsent,
       _killCompanion = killCompanion ?? _killTree,
       _captureDirectory = captureDirectory ?? _defaultCaptureDirectory,
       _captureScreenTo = captureScreen ?? gaiaCaptureScreen,
       _foregroundWindow = foregroundWindow ?? gaiaForegroundWindow,
       _readUia = readUia ?? gaiaReadUia;

  static final instance = GaiaHost();

  final GaiaPipe _pipe;
  final GaiaOsReads? _osReadsOverride;

  /// The `os_*` read tools (§15.6).
  late final _osReads =
      _osReadsOverride ??
      GaiaOsReads(
        companionPid: () => _companionPid,
        exclusions: () => _settings.contextExclusions,
        vaultUnlocked: () => _vaultUnlocked(),
      );

  final GaiaOsControl? _osControlOverride;

  /// The `os_*` action tools (§15.6).
  late final _osControl =
      _osControlOverride ??
      GaiaOsControl(
        companionPid: () => _companionPid,
        exclusions: () => _settings.contextExclusions,
        vaultUnlocked: () => _vaultUnlocked(),
        flash: (flash) => gaiaFlash(flash, _accent),
      );

  /// The "Gaia is in control" border (§15.6), with its label, in Gaia's accent;
  /// off for null.
  final Future<void> Function(String? label, int accent) _showBorder;

  static const _borderChannel = MethodChannel('voyager/gaia_border');

  static Future<void> _showBorderWindows(String? label, int accent) =>
      _borderChannel.invokeMethod<void>(
        'show',
        label == null ? null : {'label': label, 'accent': accent & 0xFFFFFF},
      );

  /// Whether the Secure Notes vault is unlocked. The `os_*` reads wait for
  /// [attach], so this is always the app's by then.
  bool Function() _vaultUnlocked = () => true;
  final Future<File> Function() _abortFlag;

  /// There once the user has confirmed Auto's notice on this device
  /// (GAIA_AUTONOMY_HLD.md §4).
  final Future<File> Function() _autoConsent;
  final Future<void> Function(int pid) _killCompanion;
  final Future<Directory> Function() _captureDirectory;
  final Future<GaiaScreenCapture?> Function(String path) _captureScreenTo;
  final GaiaForegroundWindow? Function() _foregroundWindow;
  final GaiaCursorTarget? Function() _cursorTarget;
  final Future<GaiaPointedControl?> Function(GaiaCursorTarget target)
  _readControl;
  final Future<String?> Function(
    String path,
    GaiaCursorTarget target,
    GaiaScreenRect control,
  )
  _captureControl;
  final Future<String?> Function(GaiaForegroundWindow window) _copySelection;
  final Future<GaiaWindowUia> Function(
    GaiaForegroundWindow window, {
    required bool selection,
  })
  _readUia;
  final ({int left, int top, int width, int height}) Function(
    int hwnd, {
    required bool below,
    required bool gaiaRight,
  })
  _splitWindows;

  /// Chats in progress, for the tray and the Gaia page.
  final runs = ValueNotifier<List<GaiaRun>>(const []);

  /// Each adapter's usage (§6.4), as the companion reports it.
  final usage = ValueNotifier<Map<String, GaiaAccountUsage>>(const {});

  final _attached = Completer<GaiaChatStore>();
  void Function(String chatId, String title, String body)? _toast;

  /// Where attached images go; null for none, where attaching fails.
  GaiaMedia? _media;

  /// The `voyager_*` read tools (§5.3); null for none, where they fail.
  GaiaVoyagerReads? _reads;

  /// Commits accepted proposals (§10); null for none, where they fail.
  GaiaExecutor? _executor;

  /// Gaia's memories (§11); null for none, where their tools fail.
  GaiaMemories? _memories;

  /// Remote use (§12.2): the heartbeat, commands, live text and leases;
  /// null for none, where every run is local.
  GaiaBeaconService? _beacon;
  GaiaBeaconService? get beacon => _beacon;
  Future<void> Function(String word)? _addWord;
  StreamSubscription<void>? _changes;
  StreamSubscription<GaiaSettings>? _settingsChanges;
  StreamSubscription<void>? _draftChanges;
  StreamSubscription<void>? _queueChanges;
  Timer? _changedSoon;
  var _settings = GaiaSettings.initial();

  var _started = false;
  var _ownsHotkeys = false;

  /// Each hotkey's registered combo, as stored.
  final _registered = <GaiaHotkey, String>{};
  var _quitting = false;
  var _companionPid = 0;
  var _aborted = false;

  /// The companion's crop overlay is up.
  var _cropping = false;
  var _accent = 0xFF7C9EFF;
  var _text = GaiaTextSettings.off;

  /// What a streaming message becomes when its companion goes away: aborted
  /// when Abort killed it, interrupted otherwise.
  var _lostRunStatus = GaiaMessageStatus.interrupted;

  /// Events a hotkey or a notification click sent while the companion
  /// wasn't connected, for when it is.
  final _pendingEvents = <(String, Map<String, Object?>)>[];
  Timer? _relaunch;
  var _backoff = _minBackoff;

  /// Set while [drain] waits for the companion's runs.
  Completer<void>? _drained;

  static const _launchDelay = Duration(seconds: 5);
  static const _minBackoff = Duration(seconds: 2);
  static const _maxBackoff = Duration(minutes: 1);

  /// How quickly writes are passed on to the companion: a streaming reply
  /// writes every second, and one notice covers a burst.
  static const _changedDelay = Duration(milliseconds: 250);

  /// [registerHotkeys] is false in a dev profile, which owns no hotkeys.
  /// [show] opens the Gaia window once the companion connects: a
  /// `--companion` launch that had to start Voyager first (main.cpp).
  Future<void> start({
    required bool registerHotkeys,
    required bool show,
  }) async {
    if (_started) return;
    _started = true;
    if (show) _pendingEvents.add(('hotkey', {'key': GaiaHotkey.window.name}));
    _aborted = await (await _abortFlag()).exists();
    // A crash between the flag and the revoke: Re-arm must find them off (§15.7).
    if (_aborted) unawaited(_revokeGrants());
    _pipe
      ..onRequest = _onRequest
      ..onEvent = _onEvent
      ..onConnected = _onConnected
      ..onDisconnected = _onDisconnected;
    _ownsHotkeys = registerHotkeys;
    await _applyHotkeys(_settings.keybinds);
    // Resident, but not on the startup path: a hotkey before then launches
    // it straight away.
    if (show) {
      await _launch();
    } else {
      _relaunch = Timer(_launchDelay, () => unawaited(_launch()));
    }
  }

  /// Gives the host the app's store once the providers exist. Until then
  /// the companion's requests wait. [toast] raises a Windows notification.
  void attach({
    required GaiaRepository repository,
    required String deviceId,
    required void Function(String chatId, String title, String body) toast,
    GaiaMedia? media,
    GaiaVoyagerReads? reads,
    GaiaExecutor? executor,
    GaiaMemories? memories,
    Future<void> Function(String word)? addWord,
    GaiaBeaconService? beacon,
    GaiaPower? power,
    bool Function()? vaultUnlocked,
  }) {
    if (_attached.isCompleted) return;
    if (vaultUnlocked != null) _vaultUnlocked = vaultUnlocked;
    _addWord = addWord;
    _beacon = beacon
      ?..onCommand = _runCommand
      ..setAborted(_aborted)
      ..onBatteryNow = power == null ? null : () => power.onBattery;
    _power = power
      ?..countdown.addListener(_onPowerCountdown)
      ..beaconMode.addListener(_onBeaconMode);
    if (power != null) unawaited(power.restore());
    _toast = toast;
    _media = media;
    _reads = reads;
    _executor = executor;
    _memories = memories;
    final store = GaiaChatStore(repository, deviceId: deviceId);
    _attached.complete(store);
    // The notch says when a turn is acting, and when it waits
    // (GAIA_AUTONOMY_HLD.md §4).
    _osControl.onSession = () => unawaited(_syncBorder(store));
    _borderChannel.setMethodCallHandler((call) async {
      if (call.method == 'revoke') await _revokeFromBorder();
    });
    // A grant left on before a restart still counts.
    unawaited(_syncBorder(store));
    _changes = repository.watchChanges().listen((_) {
      _changedSoon ??= Timer(_changedDelay, () {
        _changedSoon = null;
        if (_pipe.connected) _pipe.notify('changed');
        // A grant or title can change by sync or restore too.
        unawaited(_syncBorder(store));
      });
    });
    // Each save of the companion's comes back too, which it knows as its own.
    _draftChanges = repository.watchDrafts().listen((_) {
      if (_pipe.connected) _pipe.notify('drafts');
    });
    // The queue changes here, on the Gaia page and from other devices (§13).
    _queueChanges = repository.watchQueue().listen((_) {
      if (_pipe.connected) _pipe.notify('queue');
    });
    _settingsChanges = repository.watchSettings().listen((settings) {
      _settings = settings;
      unawaited(_applyHotkeys(settings.keybinds));
      if (_pipe.connected) _pipe.notify('settings', settings.toJson());
    });
  }

  /// Registers each hotkey's combo under [keybinds], replacing one that
  /// changed. A combo with no Ctrl, Alt or Win would take over plain typing
  /// everywhere, so it's left unregistered, as is one Windows refuses.
  Future<void> _applyHotkeys(Map<String, String> keybinds) async {
    if (!_ownsHotkeys) return;
    for (final hotkey in GaiaHotkey.values) {
      final combo = gaiaComboFor(
        GaiaKeybind.values.byName(hotkey.name),
        keybinds,
      );
      final registered = _registered[hotkey];
      if (combo == registered) continue;
      if (registered != null) {
        _registered.remove(hotkey);
        if (parseGaiaCombo(registered) case final old?) {
          await hotKeyManager.unregister(old.hotKey);
        }
      }
      final parsed = parseGaiaCombo(combo);
      if (parsed == null || !parsed.hasModifier) continue;
      try {
        await hotKeyManager.register(
          parsed.hotKey,
          keyDownHandler: onPressOnly((_) => onHotkey(hotkey, pressed: true)),
        );
        _registered[hotkey] = combo;
      } catch (error) {
        debugPrint('[gaia] hotkey $combo not registered: $error');
      }
    }
  }

  /// Lets the companion go: it exits once the pipe closes.
  Future<void> shutdown() async {
    _quitting = true;
    _relaunch?.cancel();
    _changedSoon?.cancel();
    unawaited(_changes?.cancel());
    unawaited(_settingsChanges?.cancel());
    unawaited(_draftChanges?.cancel());
    unawaited(_queueChanges?.cancel());
    await _power?.shutdown();
    await _beacon?.dispose();
    if (_started) await _pipe.close();
  }

  /// Before an update or a quit (§3.2): waits until the companion has no
  /// runs left. With runs going, the companion asks the user to wait for
  /// them or cancel them. A companion that doesn't answer is killed.
  Future<void> drain() async {
    _quitting = true;
    _relaunch?.cancel();
    if (!_pipe.connected) return;
    final drained = _drained = Completer<void>();
    // The quit came from the tray or a broadcast; the companion needs the
    // foreground to ask.
    AllowSetForegroundWindow(_companionPid);
    try {
      final reply = await _pipe
          .request('drain')
          .timeout(const Duration(seconds: 2));
      if ((reply! as Map)['running'] == 0) {
        _drained = null;
        return;
      }
    } catch (error) {
      _drained = null;
      debugPrint('[gaia] companion did not answer drain ($error), killing it');
      await _killCompanion(_companionPid);
      return;
    }
    // The companion says `drained` once its runs have finished or been
    // cancelled; a disconnect ends the wait too.
    await drained.future;
  }

  /// Voyager's accent, which Gaia's theme follows. Set on every app build;
  /// a change goes on to a connected companion.
  set accent(int argb) {
    if (argb == _accent) return;
    _accent = argb;
    if (_pipe.connected) _pipe.notify('accent', {'argb': argb});
    if (_attached.isCompleted) unawaited(_attached.future.then(_syncBorder));
  }

  /// The composer's share of Voyager's settings (§9.5). Set whenever they
  /// change; a change goes on to a connected companion.
  set text(GaiaTextSettings settings) {
    if (settings.sameAs(_text)) return;
    _text = settings;
    if (_pipe.connected) _pipe.notify('text', settings.toJson());
  }

  /// Also the tray's and a second launch's way in. [pressed] is the hotkey
  /// itself, which closes a Gaia window already in front; those only open.
  void onHotkey(GaiaHotkey hotkey, {bool pressed = false}) {
    if (hotkey == GaiaHotkey.abort) {
      unawaited(_abort());
      return;
    }
    // Any other summon ends pick-up mode; the companion drops its pill
    // when the summon arrives.
    if (_pickingUp && hotkey != GaiaHotkey.pickUp) {
      unawaited(_armPickUp(false, tell: false));
    }
    // Now, while the app the user summoned Gaia from is still in front.
    final window = _foregroundWindow();
    if (window != null && window.pid != _companionPid) {
      final summon = {'returnTo': _returnTo(window)};
      // Ahead of the hotkey's own event, which launches a companion that
      // isn't up.
      if (_pipe.connected) {
        _send('summon', summon);
      } else {
        _pendingEvents.add(('summon', summon));
      }
      if (!_aborted) unawaited(_sendPointedControl());
    }
    switch (hotkey) {
      case GaiaHotkey.region || GaiaHotkey.screen:
        unawaited(_captureScreen(hotkey));
      case GaiaHotkey.selection || GaiaHotkey.pickUp:
        // Which reads the window itself.
        unawaited(_captureSelection(hotkey, window));
        return;
      case GaiaHotkey.split:
        // Like the capture hotkeys (§15.7): it would move another app's window.
        if (_aborted) {
          _sendOrLaunch('refused', {'reason': 'aborted'});
          break;
        }
        // Only cancels the crop, as any hotkey does, so nothing is to move.
        if (_cropping) {
          _sendOrLaunch('hotkey', {'key': hotkey.name});
          break;
        }
        // Here, while the window to move is still the one in front. In Gaia,
        // it's the one under Gaia.
        final half = _splitWindows(
          window == null
              ? 0
              : window.pid == _companionPid
              ? window.hwnd
              : _returnTo(window),
          below: window != null && window.pid == _companionPid,
          gaiaRight: _settings.splitGaiaRight,
        );
        _sendOrLaunch('split', {
          'left': half.left,
          'top': half.top,
          'width': half.width,
          'height': half.height,
        });
      case GaiaHotkey.small ||
          GaiaHotkey.large ||
          GaiaHotkey.window ||
          GaiaHotkey.fullScreen:
        _sendOrLaunch('hotkey', {'key': hotkey.name, 'pressed': pressed});
      case GaiaHotkey.abort:
        break;
    }
    unawaited(_sendContext(window));
  }

  /// Where Gaia gives the foreground back to when it hides, for a summon
  /// from [window]. A floater closes as Gaia takes the focus, so for one,
  /// that's the app it was opened over.
  static int _returnTo(GaiaForegroundWindow window) =>
      window.pid == pid && FloaterWindow.instance.isBorrowed
      ? FloaterWindow.instance.previousForeground
      : window.hwnd;

  /// The summon's context (§15.4), after the summon itself, which never
  /// waits on UI Automation: the window, unless that's off or excluded,
  /// and its selection, for `$SELECTION` (§9.2). A summon from Gaia's own
  /// window keeps what the companion has. [uia] is a read already made.
  Future<void> _sendContext(
    GaiaForegroundWindow? window, {
    GaiaWindowUia? uia,
  }) async {
    // No window in front, as on a locked session, says nothing either.
    if (window == null || window.pid == _companionPid) return;
    bool excluded(GaiaForegroundWindow window, String? url) =>
        gaiaContextExcluded(
          _settings.contextExclusions,
          exe: window.exe,
          app: window.app,
          url: url,
        );
    if (excluded(window, null)) {
      return _sendOrLaunch('context', {'window': null, 'selection': null});
    }
    uia ??= await _readUia(window, selection: true);
    if (excluded(window, uia.url)) {
      return _sendOrLaunch('context', {'window': null, 'selection': null});
    }
    _sendOrLaunch('context', {
      'window': _settings.windowContext
          ? GaiaContextPart(
              app: window.app,
              title: window.title,
              url: uia.url,
            ).toJson()
          : null,
      'selection': uia.selection,
    });
  }

  /// Which [_sendPointedControl] is the latest: an older one still reading
  /// says nothing once a newer summon has come.
  var _pointedRead = 0;

  /// What `/this` would attach (§15.5), read on every summon and thrown away
  /// unless it's used: the control under the cursor, or why there isn't one.
  /// Goes by the window under the cursor, which may not be the one in front,
  /// so the exclusion list (§15.4) covers what's actually read. The summon
  /// never waits on it.
  Future<void> _sendPointedControl() async {
    final read = ++_pointedRead;
    void tell(Map<String, Object?> params) {
      if (read != _pointedRead || _aborted) {
        if (params['crop'] case final String crop) {
          File(crop).delete().ignore();
        }
        return;
      }
      if (_pipe.connected) {
        _pipe.notify('pointed', params);
      } else {
        _pendingEvents.add(('pointed', params));
      }
    }

    final target = _cursorTarget();
    if (target == null || target.window.pid == _companionPid) return tell({});
    final window = target.window;
    bool excluded(String? url) => gaiaContextExcluded(
      _settings.contextExclusions,
      exe: window.exe,
      app: window.app,
      url: url,
    );
    // Refused as the os_* tools refuse them (§15.6): Voyager's window with the
    // vault unlocked, and what can't be checked against the list.
    bool vaultOpen() => window.pid == pid && _vaultUnlocked();
    if (excluded(null)) return tell({'refused': 'excluded'});
    if (window.exe.isEmpty) return tell({'refused': 'unknown'});
    if (vaultOpen()) return tell({'refused': 'vault'});
    // Waking a page's tree and then the crop, which scans the whole window, can
    // each take a while: `/this` waits.
    tell({'reading': true});
    final control = await _readControl(target);
    if (control == null) return tell({});
    if (excluded(control.url)) return tell({'refused': 'excluded'});
    if (gaiaIsBrowser(window.exe) &&
        control.url == null &&
        _settings.contextExclusions.any((e) => e.contains('.'))) {
      return tell({'refused': 'unknown'});
    }
    if (control.sensitive) return tell({'refused': 'sensitive'});
    // Again: it may have been unlocked during the read.
    if (vaultOpen()) return tell({'refused': 'vault'});
    final dir = await _captureDirectory();
    final crop = await _captureControl(
      p.join(dir.path, 'control-${DateTime.now().microsecondsSinceEpoch}.bmp'),
      target,
      (
        left: control.left,
        top: control.top,
        width: control.width,
        height: control.height,
      ),
    );
    tell({
      'control': GaiaElementPart(
        controlType: control.type,
        name: control.name,
        value: control.value,
        app: window.app,
        left: control.left,
        top: control.top,
        width: control.width,
        height: control.height,
      ).toJson(),
      'crop': ?crop,
    });
    unawaited(_sweepCaptures(dir));
  }

  /// C and D (§15.1): the monitor under the cursor, captured here and now,
  /// while whatever the user wanted in the shot is still on screen; the
  /// companion crops (C) or attaches (D) it. Aborted, nothing is captured
  /// (§15.7), nor with the vault unlocked, whose windows it could show (§15.6).
  Future<void> _captureScreen(GaiaHotkey hotkey) async {
    if (_aborted) return _sendOrLaunch('refused', {'reason': 'aborted'});
    if (_vaultUnlocked()) return _sendOrLaunch('refused', {'reason': 'vault'});
    final dir = await _captureDirectory();
    final capture = await _captureScreenTo(
      p.join(dir.path, 'capture-${DateTime.now().microsecondsSinceEpoch}.bmp'),
    );
    if (capture == null) {
      debugPrint('[gaia] the screen could not be captured');
      return;
    }
    _sendOrLaunch('capture', {
      'kind': hotkey.name,
      'path': capture.path,
      'left': capture.left,
      'top': capture.top,
      'width': capture.width,
      'height': capture.height,
    });
    unawaited(_sweepCaptures(dir));
  }

  /// Pick-up mode is armed (§15.3): the next F takes the selection, and
  /// Esc cancels.
  var _pickingUp = false;
  static final _escape = HotKey(
    key: PhysicalKeyboardKey.escape,
    // Never null: the Windows plugin reads the list unchecked and aborts.
    modifiers: [],
    scope: HotKeyScope.system,
  );

  /// E (§15.2): the selection in the app the user is in, read through UI
  /// Automation, or else copied, for the companion to quote. F (§15.3)
  /// arms that for later, so the user can go and select something first.
  Future<void> _captureSelection(
    GaiaHotkey hotkey,
    GaiaForegroundWindow? window,
  ) async {
    if (_aborted) return _sendOrLaunch('refused', {'reason': 'aborted'});
    if (hotkey == GaiaHotkey.selection) {
      // Pressed again: over Gaia, which is already up, or while the last
      // press is still reading the selection.
      if (_selecting || (window != null && window.pid == _companionPid)) {
        return;
      }
      _selecting = true;
      try {
        return await _readSelection(window);
      } finally {
        _selecting = false;
      }
    }
    if (hotkey == GaiaHotkey.pickUp) {
      final arming = !_pickingUp;
      // Disarmed, the selection that follows takes the pill down.
      await _armPickUp(arming, tell: arming);
      if (arming) return;
    }
    await _readSelection(window);
  }

  /// E's read is in progress.
  var _selecting = false;

  Future<void> _readSelection(GaiaForegroundWindow? window) async {
    // Nothing to read in Gaia itself, or in an app on the exclusion list
    // (§15.4), which the user said is never read.
    bool excluded(String? url) => gaiaContextExcluded(
      _settings.contextExclusions,
      exe: window!.exe,
      app: window.app,
      url: url,
    );
    final ours =
        window == null || window.pid == _companionPid || excluded(null);
    final uia = ours
        ? (url: null, selection: null)
        : await _readUia(window, selection: true);
    final text = ours || excluded(uia.url)
        ? null
        : uia.selection ?? await _copySelection(window);
    _sendOrLaunch('selection', {
      'text': text,
      'source': ours ? null : gaiaSelectionSource(window),
    });
    // Which says nothing for Gaia itself, and clears it for an excluded app.
    await _sendContext(window, uia: uia);
  }

  /// Arms or disarms pick-up mode: the companion shows or drops its
  /// "selecting" indicator, unless [tell] is off, and Esc is Gaia's while
  /// it's armed.
  Future<void> _armPickUp(bool armed, {bool tell = true}) async {
    if (armed == _pickingUp) return;
    _pickingUp = armed;
    if (_ownsHotkeys) {
      try {
        if (armed) {
          await hotKeyManager.register(
            _escape,
            keyDownHandler: (_) => unawaited(_armPickUp(false)),
          );
        } else {
          await hotKeyManager.unregister(_escape);
        }
      } catch (error) {
        debugPrint(
          '[gaia] pick-up Esc not ${armed ? '' : 'un'}registered: '
          '$error',
        );
      }
    }
    if (tell) _sendOrLaunch('pickUp', {'armed': armed});
  }

  /// Captures the companion never took: one whose launch failed, or that
  /// it was killed before reading. A crop or attach reads its capture
  /// within seconds.
  static Future<void> _sweepCaptures(Directory dir) async {
    final cutoff = DateTime.now().subtract(const Duration(hours: 1));
    await for (final entity in dir.list()) {
      try {
        if (entity is File && (await entity.lastModified()).isBefore(cutoff)) {
          await entity.delete();
        }
      } on FileSystemException {
        // Being read, or gone already.
      }
    }
  }

  /// A task ticked or unticked on the Gaia page: through the store, one
  /// write at a time with the companion's, where it's attached. The
  /// companion takes it up with its next write, as a reply streams, or as it
  /// loads the chat.
  Future<void> toggleCheck(
    GaiaRepository repository,
    String messageId,
    int part,
    int task,
    bool flipped,
  ) async => _attached.isCompleted
      ? await (await _attached.future).toggleCheck(
          messageId,
          part,
          task,
          flipped,
        )
      : await gaiaToggleCheck(repository, messageId, part, task, flipped);

  /// Opens [chatId] in the Gaia window: a notification clicked, or a chat
  /// picked on the Gaia page.
  void openChat(String chatId) => _sendOrLaunch('openChat', {'chatId': chatId});

  /// Has the companion read [key]'s usage again (§6.4), if it's up: with none,
  /// there's no usage to correct.
  void recheckUsage(String key) {
    if (_pipe.connected) _pipe.notify('recheckUsage', {'key': key});
  }

  /// Stops [chatId]'s run: the tray's or the Gaia page's Stop.
  Future<void> stop(String chatId) async {
    if (!_pipe.connected) return;
    // Its callers (the tray, Gaia's run list) don't wait on it: a companion
    // that exits mid-request, or never answers, ends here.
    try {
      await _pipe
          .request('stop', {'chatId': chatId})
          .timeout(const Duration(seconds: 2));
    } catch (error) {
      debugPrint('[gaia] companion did not confirm stop ($error)');
    }
  }

  void _sendOrLaunch(String event, Map<String, Object?> params) {
    if (!_pipe.connected) {
      _pendingEvents.add((event, params));
      _relaunch?.cancel();
      _backoff = _minBackoff;
      unawaited(_launch());
      return;
    }
    _send(event, params);
  }

  void _send(String event, Map<String, Object?> params) {
    // The hotkey or click gave this process the right to set the foreground;
    // the companion needs it to bring its window up.
    AllowSetForegroundWindow(_companionPid);
    _pipe.notify(event, params);
  }

  Future<void> _launch() async {
    if (_quitting) return;
    _companionPid = await _pipe.startCompanion();
    if (_companionPid == 0) {
      debugPrint('[gaia] companion failed to launch');
      _scheduleRelaunch();
    }
  }

  void _scheduleRelaunch() {
    if (_quitting) return;
    _relaunch?.cancel();
    _relaunch = Timer(_backoff, () => unawaited(_launch()));
    _backoff = _backoff * 2 > _maxBackoff ? _maxBackoff : _backoff * 2;
  }

  void _onConnected() {
    _backoff = _minBackoff;
    _relaunch?.cancel();
  }

  /// Also a companion that exited before it connected.
  void _onDisconnected() {
    _osControl.stop('Gaia went away.');
    _osControl.endTurn();
    _cropping = false;
    runs.value = const [];
    usage.value = const {};
    // Its runs died with it: the phone stops showing them and their leases
    // go. Quitting, the beacon has already said it's offline.
    if (!_quitting) _beacon?.setRuns(const []);
    _drained?.complete();
    _drained = null;
    unawaited(_endStreaming());
    _scheduleRelaunch();
  }

  /// Messages the gone companion was streaming, marked as how it went.
  Future<void> _endStreaming() async {
    final status = _lostRunStatus;
    _lostRunStatus = GaiaMessageStatus.interrupted;
    final store = await _attached.future;
    await store.endStreaming(status);
    _beacon?.endAllLive();
  }

  /// The kill switch (§15.7), for runs. Persisted first, so a restart comes
  /// back aborted. A companion that doesn't confirm within a second is
  /// killed with its whole tree and relaunched aborted.
  Future<void> _abort() async {
    _aborted = true;
    // Synthetic input first: mid-sequence, with key-ups for anything held.
    _osControl.stop('Gaia is aborted.');
    _osControl.endTurn();
    _beacon?.setAborted(true);
    // And drain mode, everywhere (§13).
    if (_attached.isCompleted) {
      unawaited(_attached.future.then((store) => store.stopDraining()));
    }
    // And screen access, once there's a store if there isn't yet: Re-arm leaves
    // it off (§15.7).
    unawaited(_revokeGrants());
    // Capture stops too (§15.7).
    unawaited(_armPickUp(false));
    try {
      await (await _abortFlag()).writeAsString(
        DateTime.now().toIso8601String(),
      );
    } catch (error) {
      debugPrint('[gaia] abort flag not saved: $error');
    }
    if (!_pipe.connected) return;
    try {
      await _pipe.request('abort').timeout(const Duration(seconds: 1));
    } catch (error) {
      debugPrint('[gaia] companion did not confirm abort ($error), killing it');
      _lostRunStatus = GaiaMessageStatus.aborted;
      await _killCompanion(_companionPid);
    }
  }

  Future<void> _revokeGrants() async {
    final store = await _attached.future;
    await store.revokeGrants();
    await _syncBorder(store);
  }

  /// The border's button (§15.6): both grants off on every chat here, as Abort
  /// takes them, but agents keep running and Gaia isn't aborted.
  Future<void> _revokeFromBorder() async {
    _revoking = true;
    _osControl.stop('The user revoked screen access.');
    _osControl.endTurn();
    try {
      await _revokeGrants();
    } finally {
      _revoking = false;
    }
  }

  /// The border's button was pressed and the grants aren't all off yet: the
  /// writes queue, and nothing gets through meanwhile.
  var _revoking = false;

  var _borderSynced = false;
  String? _borderLabel;
  int? _borderAccent;

  /// The border shows while any chat here has *can control* on (§15.6), and
  /// names it, for finding the toggle again. A chat in Auto is named with its
  /// mode, and while a turn acts, how to stop it (GAIA_AUTONOMY_HLD.md §4).
  Future<void> _syncBorder(GaiaChatStore store) async {
    final chats = await store.controlledChats();
    final auto = chats.any((chat) => chat.auto);
    final named = switch (chats) {
      [] => null,
      [(:final title, auto: _)] when title.isNotEmpty => title,
      [_] => '',
      _ => '${chats.length} chats',
    };
    final acting = switch (_osControl.sessionChat) {
      null => '',
      _ when _osControl.sessionPaused => ' · Paused',
      _ => ' · Esc to stop',
    };
    final label = switch (named) {
      null => null,
      _ when auto =>
        ['Gaia · Auto', if (named.isNotEmpty) named].join(' · ') + acting,
      '' => 'Gaia is in control',
      _ => 'Gaia is in control: $named',
    };
    // Showing rebuilds its windows, and most changes don't touch it.
    if (_borderSynced &&
        label == _borderLabel &&
        (label == null || _accent == _borderAccent)) {
      return;
    }
    _borderSynced = true;
    _borderLabel = label;
    _borderAccent = _accent;
    // Not waited for: a chat's save doesn't hang on a window.
    unawaited(
      Future.sync(() => _showBorder(label, _accent)).catchError((Object error) {
        debugPrint('[gaia] border not shown: $error');
      }),
    );
  }

  void _onEvent(String event, Map<String, Object?> params) {
    switch (event) {
      case 'runs':
        runs.value = [
          for (final run in params['runs']! as List)
            if (run case {
              'chatId': final String chatId,
              'title': final String title,
            })
              (chatId: chatId, title: title),
        ];
        _beacon?.setRuns(runs.value);
        // A session lasts as long as its turn (GAIA_AUTONOMY_HLD.md §5.1).
        if (_osControl.sessionChat case final chatId? when !_running(chatId)) {
          _osControl.endTurn(chatId);
        }
      case 'usage':
        usage.value = {
          for (final MapEntry(:key, :value) in params.entries)
            key: GaiaAccountUsage.fromJson((value! as Map).cast()),
        };
      case 'localRun':
        _beacon?.onLocalRun(params['chatId']! as String);
      case 'runDone':
        _toast?.call(
          params['chatId']! as String,
          params['title']! as String,
          params['body']! as String,
        );
      case 'drained':
        _drained?.complete();
        _drained = null;
      case 'pickUpCancelled':
        unawaited(_armPickUp(false, tell: false));
      case 'cropping':
        _cropping = params['active'] == true;
    }
  }

  Future<Object?> _onRequest(String method, Map<String, Object?> params) async {
    final store = await _attached.future;
    switch (method) {
      case 'hello':
        // A companion that crashed or was killed mid-run left these behind.
        await _endStreaming();
        final pending = [..._pendingEvents];
        _pendingEvents.clear();
        if (pending.isNotEmpty) {
          // After the reply goes out.
          Timer.run(() {
            for (final (event, params) in pending) {
              _send(event, params);
            }
          });
        }
        return {
          'aborted': _aborted,
          'accent': _accent,
          'deviceId': store.deviceId,
          'settings': _settings.toJson(),
          'text': _text.toJson(),
        };
      case 'chats':
        return [for (final chat in await store.chats()) chat.toJson()];
      case 'putChat':
        await store.createChat(GaiaChat.fromJson(_map(params['chat'])));
        await _syncBorder(store);
        return null;
      case 'setSession':
        await store.setSession(
          params['chatId']! as String,
          params['sessionId'] as String?,
          params['lastSeq']! as int,
          adapter: params['adapter'] as String? ?? kGaiaClaudeCodeAdapter,
          account: params['account'] as String? ?? kGaiaDefaultAccountId,
        );
        return null;
      case 'setCurrentAccount':
        await store.setCurrentAccount(
          params['adapter']! as String,
          params['account']! as String,
        );
        return null;
      case 'setTier':
        if (gaiaTierFromName(params['tier']) case final tier?) {
          await store.setTier(params['chatId']! as String, tier);
        }
        return null;
      case 'setTitle':
        await store.setTitle(
          params['chatId']! as String,
          params['title']! as String,
          params['from']! as String,
        );
        return null;
      case 'setPinned':
        await store.setPinned(
          params['chatId']! as String,
          params['pinned']! as bool,
        );
        return null;
      case 'deleteChat':
        final chatId = params['chatId']! as String;
        _osControl.stop('The chat was deleted.', chatId: chatId);
        _osControl.endTurn(chatId);
        await store.deleteChat(chatId);
        await _syncBorder(store);
        await store.deleteDraft(chatId);
        // Deleted either way: its images just don't follow it if this fails.
        DateTime? at;
        try {
          await _media?.keepDraft(chatId, const {});
          at = await _media?.removeChat(chatId);
        } catch (error) {
          debugPrint('[gaia] images of $chatId not taken off: $error');
        }
        return {'mediaDeletedAt': at?.toIso8601String()};
      case 'restoreChat':
        final chatId = params['chatId']! as String;
        await store.restoreChat(chatId);
        await _syncBorder(store);
        if (params['mediaDeletedAt'] case final String at) {
          await _media?.restoreChat(chatId, DateTime.parse(at));
        }
        if (await store.restoreDraft(chatId) case final draft?) {
          await _media?.keepDraft(chatId, {
            for (final image in draft.images) image.mediaId,
          });
        }
        return null;
      case 'setLastTier':
        if (gaiaTierFromName(params['tier']) case final tier?) {
          await store.setLastTier(tier);
        }
        return null;
      case 'messages':
        return [
          for (final message in await store.messages(
            params['chatId']! as String,
          ))
            message.toJson(),
        ];
      case 'putMessage':
        final written = await store.putMessage(
          GaiaMessage.fromJson(_map(params['message'])),
        );
        // A reply another device watches streams to it (§8.1).
        if (written != null) _beacon?.onMessage(written);
        // The ticks as stored, which may be the Gaia page's.
        return written == null
            ? null
            : gaiaChecksToJson(gaiaChecksOf(written.parts));
      case 'toggleCheck':
        final written = await store.toggleCheck(
          params['messageId']! as String,
          params['part']! as int,
          params['task']! as int,
          params['flipped']! as bool,
        );
        return written == null
            ? null
            : gaiaChecksToJson(gaiaChecksOf(written.parts));
      case 'attachImage':
        final media = _media;
        if (media == null) throw GaiaPipeException('no media store');
        final image = await media.attach(
          params['chatId']! as String,
          params['path']! as String,
        );
        return {
          'mediaId': image.mediaId,
          'referenceId': image.referenceId,
          'path': image.path,
          'mimeType': image.mimeType,
          'width': image.width,
          'height': image.height,
        };
      case 'drafts':
        return [for (final draft in await store.drafts()) draft.toJson()];
      case 'putDraft':
        final draft = GaiaDraft.fromJson(_map(params['draft']));
        await store.putDraft(draft);
        await _media?.keepDraft(draft.id, {
          for (final image in draft.images) image.mediaId,
        });
        return null;
      case 'ingestImage':
        final media = _media;
        if (media == null) throw GaiaPipeException('no media store');
        return media.ingest(params['path']! as String);
      case 'detachImage':
        await _media?.detach(params['referenceId']! as String);
        return null;
      case 'mediaFile':
        return _media?.file(params['mediaId']! as String);
      case 'draftImageFile':
        return _media?.fileWhenHere(params['mediaId']! as String);
      case 'voyagerRead':
        final reads = _reads;
        if (reads == null) throw GaiaPipeException('Voyager data is not ready');
        try {
          return await reads.read(
            params['tool']! as String,
            _map(params['arguments']),
          );
        } on GaiaReadException catch (error) {
          // The pipe would carry it as `GaiaReadException: …`.
          throw GaiaPipeException(error.message);
        }
      case 'setSeeScreen':
        final on = params['on']! as bool;
        if (on && _aborted) throw GaiaPipeException('Gaia is aborted.');
        final chatId = params['chatId']! as String;
        // Off drops Auto, so its running session ends as setAuto's does.
        if (!on && _osControl.sessionChat == chatId) {
          _osControl.stop(
            'The user turned off "can see screen".',
            chatId: chatId,
          );
          _osControl.endTurn(chatId);
        }
        await store.setSeeScreen(chatId, on);
        // Off takes Auto with it, which the notch names.
        await _syncBorder(store);
        return null;
      case 'osRead':
        return _osRead(
          store,
          params['chatId']! as String,
          params['tool']! as String,
          _map(params['arguments']),
        );
      case 'setCanControl':
        final chatId = params['chatId']! as String;
        final on = params['on']! as bool;
        if (on && _aborted) throw GaiaPipeException('Gaia is aborted.');
        if (!on) {
          _osControl.stop('The user turned off "can control".', chatId: chatId);
          _osControl.endTurn(chatId);
        }
        await store.setCanControl(chatId, on);
        await _syncBorder(store);
        return null;
      case 'autoConsented':
        return (await _autoConsent()).exists();
      case 'setAuto':
        final chatId = params['chatId']! as String;
        final on = params['on']! as bool;
        if (on) {
          if (_aborted) throw GaiaPipeException('Gaia is aborted.');
          final consent = await _autoConsent();
          if (params['consented'] == true) {
            await consent.writeAsString(DateTime.now().toIso8601String());
          } else if (!await consent.exists()) {
            throw GaiaPipeException('Auto needs its notice confirmed first.');
          }
        } else {
          // Back to Ask, the turn's next action waits on a card.
          _osControl.stop(
            'The user switched this chat to Ask.',
            chatId: chatId,
          );
          _osControl.endTurn(chatId);
        }
        await store.setAuto(chatId, on);
        await _syncBorder(store);
        return null;
      case 'isAuto':
        // Read at each CLI prompt (GAIA_AUTONOMY_HLD.md §5.7), so taking it
        // back mid-turn applies to the next one.
        return !_aborted &&
            !_revoking &&
            await store.isAuto(params['chatId']! as String);
      case 'osPlan':
        final chatId = params['chatId']! as String;
        await _checkControl(store, chatId);
        final auto = await _auto(store, chatId);
        final tool = params['tool']! as String;
        try {
          _osControl.session(
            chatId,
            auto: auto,
            onUserStop: () => _userStopped(store, chatId),
            // These find their own window (GAIA_AUTONOMY_HLD.md §8).
            needsWindow: tool != 'os_open' && tool != 'os_focus',
          );
          return await _osControl.plan(
            chatId,
            params['cardId']! as String,
            tool,
            _map(params['arguments']),
          );
        } on GaiaReadException catch (error) {
          throw GaiaPipeException(error.message);
        }
      case 'osRun':
        final chatId = params['chatId']! as String;
        try {
          return await _osControl.run(
            params['cardId']! as String,
            once: params['once'] == true,
            check: () => _checkControl(store, chatId).catchError(
              (Object error) =>
                  throw GaiaReadException((error as GaiaPipeException).message),
              test: (error) => error is GaiaPipeException,
            ),
          );
        } on GaiaReadException catch (error) {
          throw GaiaPipeException(error.message);
        }
      case 'osDrop':
        _osControl.drop(params['cardId']! as String);
        return null;
      case 'osResume':
        _osControl.resume(params['chatId']! as String);
        return null;
      case 'osStop':
        _osControl.stop(
          'The user stopped the reply.',
          chatId: params['chatId']! as String,
          latch: true,
        );
        return null;
      case 'memoryIndex':
        return await _memories?.index() ?? '';
      case 'memoryTool':
        try {
          return await _memoriesOrThrow().tool(
            params['chatId']! as String,
            params['tool']! as String,
            _map(params['arguments']),
          );
        } on GaiaReadException catch (error) {
          throw GaiaPipeException(error.message);
        }
      case 'remember':
        // The user's own words, saved as they asked (§11). An active
        // memory steers every chat after it, so it's refused here while
        // aborted, whatever the companion did about Abort (§15.7).
        if (_aborted) {
          throw GaiaPipeException('Gaia is aborted. Rearm to save memories.');
        }
        try {
          final saved = await _memoriesOrThrow().save(
            params['text']! as String,
            chatId: params['chatId'] as String?,
            status: GaiaMemoryStatus.active,
            byUser: true,
          );
          return {'saved': saved != null};
        } on GaiaReadException catch (error) {
          throw GaiaPipeException(error.message);
        }
      case 'curated':
        if (_aborted) throw GaiaPipeException('Gaia is aborted.');
        await _memoriesOrThrow()
            .curated(params['chatId']! as String, params['seq']! as int, [
              for (final memory in params['memories']! as List)
                if (memory case {'text': final String text})
                  (text: text, tags: gaiaMemoryTags(memory['tags'])),
            ]);
        return null;
      case 'prepareProposal':
        try {
          return (await _executorOrThrow().prepare(
            params['cardId']! as String,
            params['tool']! as String,
            _map(params['arguments']),
          )).toJson();
        } on GaiaReadException catch (error) {
          throw GaiaPipeException(error.message);
        }
      case 'dropProposal':
        _executor?.drop(params['cardId']! as String);
        return null;
      case 'commitProposal':
        // Checked here, in the main instance, whatever the companion did
        // about Abort (§15.7).
        if (_aborted) throw GaiaPipeException('Gaia is aborted.');
        try {
          final committed = await _executorOrThrow().commit(
            params['cardId']! as String,
            params['token']! as String,
            _map(params['fields']),
          );
          return {'record': committed.record, 'text': committed.text};
        } on GaiaReadException catch (error) {
          throw GaiaPipeException(error.message);
        }
      case 'addWord':
        // The dictionary is Voyager's: added here, it syncs, and comes back
        // to the companion as `text`.
        await (_addWord ??
            (throw GaiaPipeException('Voyager data is not ready')))(
          params['word']! as String,
        );
        return null;
      case 'rearm':
        await _rearm();
        return null;
      case 'takeLease':
        return {
          'heldBy': await _beacon?.takeLease(params['chatId']! as String),
        };
      case 'releaseLease':
        await _beacon?.releaseLease(params['chatId']! as String);
        return null;
      case 'queue':
        return [
          for (final item
              in params['all'] == true
                  ? await store.allQueued()
                  : await store.queue(params['chatId'] as String?))
            item.toJson(),
        ];
      case 'enqueue':
        return (await store.enqueue(
          params['chatId'] as String?,
          params['text']! as String,
          front: params['front'] == true,
        )).toJson();
      case 'queuePop':
        return (await store.queuePop(params['chatId'] as String?))?.toJson();
      case 'setDrain':
        await store.setDrain(
          params['chatId']! as String,
          params['drain']! as bool,
        );
        return null;
      default:
        throw GaiaPipeException('unknown method $method');
    }
  }

  /// An `os_*` read (§15.6), checked here whatever the companion did: Abort and
  /// this device's grant, again once it's read, so taking the grant back or
  /// pressing Abort mid-read keeps what it got from the agent.
  Future<Map<String, Object?>> _osRead(
    GaiaChatStore store,
    String chatId,
    String tool,
    Map<String, Object?> arguments,
  ) async {
    Future<void> check() async {
      if (_aborted) throw GaiaPipeException('aborted: Gaia is aborted.');
      if (!await store.canSeeScreen(chatId) || _revoking) {
        throw GaiaPipeException(
          'The user hasn\'t turned on "can see screen" for this chat. They can, '
          'with the eye button under the composer.',
        );
      }
    }

    await check();
    final auto = await _auto(store, chatId);
    final GaiaOsAnswer answer;
    try {
      answer = await _osReads.read(
        tool,
        arguments,
        pinned: _osControl.session(
          chatId,
          auto: auto,
          onUserStop: () => _userStopped(store, chatId),
          needsWindow: tool != 'os_windows',
        ),
        // Read after session(), which may have started one.
        session: _osControl.sessionChat == chatId,
      );
    } on GaiaReadException catch (error) {
      throw GaiaPipeException(error.message);
    }
    await check();
    return {
      'text': answer.text,
      'image': answer.image,
      'mimeType': answer.mimeType,
    };
  }

  bool _running(String chatId) => runs.value.any((r) => r.chatId == chatId);

  /// Whether [chatId]'s `os_*` calls run in an Auto session. Only for a turn
  /// that's running: a call that outlives its turn must not start a session
  /// nothing would end. The caller goes straight on, with no await before it
  /// starts one, or the turn could end in between.
  Future<bool> _auto(GaiaChatStore store, String chatId) async =>
      await store.isAuto(chatId) && _running(chatId);

  /// Esc or a switch of window stopped [chatId]'s session (§5.3): its reply
  /// stops, and its queue doesn't carry on without the user.
  void _userStopped(GaiaChatStore store, String chatId) {
    unawaited(store.setDrain(chatId, false));
    unawaited(stop(chatId));
  }

  /// Whether [chatId] may send input now (§15.6), asked here before every step,
  /// whatever the companion did.
  Future<void> _checkControl(GaiaChatStore store, String chatId) async {
    if (_aborted) throw GaiaPipeException('aborted: Gaia is aborted.');
    if (!await store.canControl(chatId) || _revoking) {
      throw GaiaPipeException(
        'The user hasn\'t turned on "can control" for this chat. They can, with '
        'the hand button under the composer.',
      );
    }
  }

  Future<void> _rearm() async {
    _aborted = false;
    _beacon?.setAborted(false);
    final flag = await _abortFlag();
    if (await flag.exists()) await flag.delete();
  }

  /// A command from a paired device (§12.2), its signature checked and the
  /// command claimed by [_beacon]. Abort and Rearm are the main instance's
  /// own; the rest run in the companion, launched first if it's down.
  Future<Map<String, Object?>?> _runCommand(GaiaRemoteCommand command) async {
    switch (command.type) {
      case GaiaRemoteCommandType.abort:
        await _abort();
        return null;
      case GaiaRemoteCommandType.rearm:
        await _rearm();
        if (_pipe.connected) _pipe.notify('rearmed');
        return null;
      case GaiaRemoteCommandType.prompt ||
          GaiaRemoteCommandType.answer ||
          GaiaRemoteCommandType.cancel ||
          GaiaRemoteCommandType.queuePop:
        if (_aborted && command.type != GaiaRemoteCommandType.cancel) {
          throw GaiaRemoteException('Gaia is aborted. Rearm it first.');
        }
        await _companionUp();
        try {
          final result = await _pipe.request('remote', {
            'type': command.type.name,
            'chatId': command.chatId,
            'payload': command.payload,
            'fromDevice': command.fromDevice,
          });
          return (result as Map?)?.cast<String, Object?>();
        } on GaiaPipeException catch (error) {
          throw GaiaRemoteException(error.message);
        }
      case GaiaRemoteCommandType.sleep || GaiaRemoteCommandType.shutdown:
        final power =
            _power ?? (throw GaiaRemoteException('This desktop cannot.'));
        final kind = command.type.name;
        power.startCountdown(kind);
        _toast?.call(
          '',
          kind == 'sleep' ? 'Going to sleep in 30 s' : 'Shutting down in 30 s',
          'Asked from your phone. Cancel it from the tray icon.',
        );
        return {'at': power.countdown.value!.at.millisecondsSinceEpoch};
      case GaiaRemoteCommandType.cancelPower:
        if (!(_power?.cancelCountdown() ?? false)) {
          throw GaiaRemoteException('Nothing was counting down.');
        }
        return null;
    }
  }

  /// Remote power and beacon mode (§12.1, §12.2); null for none.
  GaiaPower? _power;
  GaiaPower? get power => _power;

  void _onPowerCountdown() {
    final countdown = _power?.countdown.value;
    _beacon?.setPower(
      countdown == null
          ? null
          : (kind: countdown.kind, at: countdown.at.millisecondsSinceEpoch),
    );
  }

  void _onBeaconMode() => _beacon?.setBeaconMode(
    on: _power?.beaconMode.value ?? false,
    onBattery: _power?.onBattery ?? false,
  );

  /// Launches the companion if it's down, and waits until it's connected.
  Future<void> _companionUp() async {
    if (_pipe.connected) return;
    _relaunch?.cancel();
    _backoff = _minBackoff;
    unawaited(_launch());
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (!_pipe.connected) {
      if (DateTime.now().isAfter(deadline)) {
        throw GaiaRemoteException('Gaia did not start on this desktop.');
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    // Its `hello` comes first.
    await Future<void>.delayed(const Duration(seconds: 1));
  }

  GaiaExecutor _executorOrThrow() =>
      _executor ?? (throw GaiaPipeException('Voyager data is not ready'));

  GaiaMemories _memoriesOrThrow() =>
      _memories ?? (throw GaiaPipeException('Voyager data is not ready'));

  /// Takes back what accepted proposal card [cardId] of [message] committed,
  /// for the Gaia page's action log (§17), and marks the card undone.
  /// Throws a [GaiaReadException] saying why it can't.
  Future<void> undoProposal(GaiaMessage message, String cardId) async {
    if (_aborted) throw GaiaReadException('Gaia is aborted.');
    final executor =
        _executor ?? (throw GaiaReadException('Voyager data is not ready.'));
    final card = message.parts
        .whereType<GaiaCardPart>()
        .where((card) => card.id == cardId)
        .firstOrNull;
    final committed = (card?.answer?['committed'] as Map?)
        ?.cast<String, Object?>();
    if (card == null ||
        card.state != GaiaCardState.accepted ||
        committed == null) {
      throw GaiaReadException('Nothing was saved to undo.');
    }
    if (card.answer!['undoneAt'] != null) {
      throw GaiaReadException('Undone already.');
    }
    await executor.undo(committed);
    final undone = card.decided(card.state, {
      ...card.answer!,
      'undoneAt': DateTime.now().toUtc().toIso8601String(),
    });
    await (await _attached.future).putMessage(
      message.copyWith(
        parts: [
          for (final part in message.parts)
            part is GaiaCardPart && part.id == cardId ? undone : part,
        ],
      ),
    );
  }

  static Map<String, Object?> _map(Object? value) =>
      (value! as Map).cast<String, Object?>();

  static Future<void> _killTree(int pid) =>
      Process.run('taskkill', ['/t', '/f', '/pid', '$pid']);

  static Future<File> _defaultAbortFlag() async =>
      File(p.join((await appDataDirectory()).path, 'gaia_aborted'));

  static Future<File> _defaultAutoConsent() async =>
      File(p.join((await appDataDirectory()).path, 'gaia_auto_consent'));

  static Future<Directory> _defaultCaptureDirectory() async => Directory(
    p.join((await appSupportRoot()).path, 'gaia', 'captures'),
  ).create(recursive: true);
}
