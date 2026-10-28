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
import 'package:voyager/features/gaia/host/gaia_capture.dart';
import 'package:voyager/features/gaia/host/gaia_chat_store.dart';
import 'package:voyager/features/gaia/host/gaia_media.dart';
import 'package:voyager/features/gaia/host/gaia_selection.dart';
import 'package:voyager/features/gaia/host/gaia_window_context.dart';
import 'package:voyager/features/hotkeys/floaters/floater_window.dart';
import 'package:voyager/features/hotkeys/hotkey_repeat.dart';
import 'package:win32/win32.dart';

/// Gaia's hotkeys (GAIA_HLD.md §15.1, §15.7), rebindable on the Gaia page:
/// each is the [GaiaKeybind] of the same name.
enum GaiaHotkey {
  small,
  large,
  window,
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
/// {chatId, adapter, sessionId, lastSeq}`, `setTier {chatId, tier}`,
/// `setLastTier {tier}`, `setTitle {chatId, title, from}`, `deleteChat
/// {chatId}` (returns `{mediaDeletedAt}`), `restoreChat {chatId,
/// mediaDeletedAt}`, `messages {chatId}`, `putMessage {message}`,
/// `attachImage {chatId, path}` (returns `{mediaId, path, mimeType, width,
/// height}`), `mediaFile {mediaId}` (a path, or null), `rearm`, and the `runs {runs}`, `runDone {chatId, title,
/// body}` and `drained` events. Main to companion: the `abort`, `stop
/// {chatId}` and `drain` requests, and the `hotkey {key}`, `openChat
/// {chatId}`, `accent {argb}`, `settings {..}` and `changed` events.
class GaiaHost {
  /// The app uses [instance]. Tests pass a fake [pipe], their own
  /// [abortFlag] file, and a [killCompanion] that kills nothing real.
  @visibleForTesting
  GaiaHost({
    GaiaPipe? pipe,
    Future<File> Function()? abortFlag,
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
  }) : _pipe = pipe ?? GaiaPipe(),
       _copySelection = copySelection ?? gaiaCopySelection,
       _abortFlag = abortFlag ?? _defaultAbortFlag,
       _killCompanion = killCompanion ?? _killTree,
       _captureDirectory = captureDirectory ?? _defaultCaptureDirectory,
       _captureScreenTo = captureScreen ?? gaiaCaptureScreen,
       _foregroundWindow = foregroundWindow ?? gaiaForegroundWindow,
       _readUia = readUia ?? gaiaReadUia;

  static final instance = GaiaHost();

  final GaiaPipe _pipe;
  final Future<File> Function() _abortFlag;
  final Future<void> Function(int pid) _killCompanion;
  final Future<Directory> Function() _captureDirectory;
  final Future<GaiaScreenCapture?> Function(String path) _captureScreenTo;
  final GaiaForegroundWindow? Function() _foregroundWindow;
  final Future<String?> Function(GaiaForegroundWindow window) _copySelection;
  final Future<GaiaWindowUia> Function(
    GaiaForegroundWindow window, {
    required bool selection,
  })
  _readUia;

  /// Chats in progress, for the tray and the Gaia page.
  final runs = ValueNotifier<List<GaiaRun>>(const []);

  final _attached = Completer<GaiaChatStore>();
  void Function(String chatId, String title, String body)? _toast;

  /// Where attached images go; null for none, where attaching fails.
  GaiaMedia? _media;
  StreamSubscription<void>? _changes;
  StreamSubscription<GaiaSettings>? _settingsChanges;
  Timer? _changedSoon;
  var _settings = GaiaSettings.initial();

  var _started = false;
  var _ownsHotkeys = false;

  /// Each hotkey's registered combo, as stored.
  final _registered = <GaiaHotkey, String>{};
  var _quitting = false;
  var _companionPid = 0;
  var _aborted = false;
  var _accent = 0xFF7C9EFF;

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
  }) {
    if (_attached.isCompleted) return;
    _toast = toast;
    _media = media;
    _attached.complete(GaiaChatStore(repository, deviceId: deviceId));
    _changes = repository.watchChanges().listen((_) {
      _changedSoon ??= Timer(_changedDelay, () {
        _changedSoon = null;
        if (_pipe.connected) _pipe.notify('changed');
      });
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
    }
    switch (hotkey) {
      case GaiaHotkey.region || GaiaHotkey.screen:
        unawaited(_captureScreen(hotkey));
      case GaiaHotkey.selection || GaiaHotkey.pickUp:
        // Which reads the window itself.
        unawaited(_captureSelection(hotkey, window));
        return;
      case GaiaHotkey.small || GaiaHotkey.large || GaiaHotkey.window:
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

  /// C and D (§15.1): the monitor under the cursor, captured here and now,
  /// while whatever the user wanted in the shot is still on screen; the
  /// companion crops (C) or attaches (D) it. Aborted, nothing is captured
  /// (§15.7).
  Future<void> _captureScreen(GaiaHotkey hotkey) async {
    if (_aborted) return _sendOrLaunch('refused', {'reason': 'aborted'});
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

  /// Opens [chatId] in the Gaia window: a notification clicked, or a chat
  /// picked on the Gaia page.
  void openChat(String chatId) => _sendOrLaunch('openChat', {'chatId': chatId});

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
    runs.value = const [];
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
  }

  /// The kill switch (§15.7), for runs. Persisted first, so a restart comes
  /// back aborted. A companion that doesn't confirm within a second is
  /// killed with its whole tree and relaunched aborted.
  Future<void> _abort() async {
    _aborted = true;
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
        };
      case 'chats':
        return [for (final chat in await store.chats()) chat.toJson()];
      case 'putChat':
        await store.createChat(GaiaChat.fromJson(_map(params['chat'])));
        return null;
      case 'setSession':
        await store.setSession(
          params['chatId']! as String,
          params['sessionId'] as String?,
          params['lastSeq']! as int,
          adapter: params['adapter'] as String? ?? kGaiaClaudeCodeAdapter,
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
      case 'deleteChat':
        final chatId = params['chatId']! as String;
        await store.deleteChat(chatId);
        // Deleted either way: its images just don't follow it if this fails.
        DateTime? at;
        try {
          at = await _media?.removeChat(chatId);
        } catch (error) {
          debugPrint('[gaia] images of $chatId not taken off: $error');
        }
        return {'mediaDeletedAt': at?.toIso8601String()};
      case 'restoreChat':
        final chatId = params['chatId']! as String;
        await store.restoreChat(chatId);
        if (params['mediaDeletedAt'] case final String at) {
          await _media?.restoreChat(chatId, DateTime.parse(at));
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
        await store.putMessage(GaiaMessage.fromJson(_map(params['message'])));
        return null;
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
      case 'detachImage':
        await _media?.detach(params['referenceId']! as String);
        return null;
      case 'mediaFile':
        return _media?.file(params['mediaId']! as String);
      case 'rearm':
        _aborted = false;
        final flag = await _abortFlag();
        if (await flag.exists()) await flag.delete();
        return null;
      default:
        throw GaiaPipeException('unknown method $method');
    }
  }

  static Map<String, Object?> _map(Object? value) =>
      (value! as Map).cast<String, Object?>();

  static Future<void> _killTree(int pid) =>
      Process.run('taskkill', ['/t', '/f', '/pid', '$pid']);

  static Future<File> _defaultAbortFlag() async =>
      File(p.join((await appDataDirectory()).path, 'gaia_aborted'));

  static Future<Directory> _defaultCaptureDirectory() async => Directory(
    p.join((await appSupportRoot()).path, 'gaia', 'captures'),
  ).create(recursive: true);
}
