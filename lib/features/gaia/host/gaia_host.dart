import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:path/path.dart' as p;
import 'package:voyager/core/platform/app_data_directory.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/domain/repositories/repositories.dart';
import 'package:voyager/features/gaia/gaia_pipe.dart';
import 'package:voyager/features/gaia/host/gaia_chat_store.dart';
import 'package:win32/win32.dart';

/// Gaia's hotkeys (GAIA_HLD.md §15.1, §15.7). Fixed combos until the Gaia
/// page makes them rebindable (Phase 2).
enum GaiaHotkey { small, large, window, abort }

final _hotkeys = {
  GaiaHotkey.small: HotKey(
    key: PhysicalKeyboardKey.space,
    modifiers: [HotKeyModifier.control, HotKeyModifier.alt],
    scope: HotKeyScope.system,
  ),
  GaiaHotkey.large: HotKey(
    key: PhysicalKeyboardKey.space,
    modifiers: [
      HotKeyModifier.control,
      HotKeyModifier.alt,
      HotKeyModifier.shift,
    ],
    scope: HotKeyScope.system,
  ),
  // G, the Gaia window, is unbound by default.
  GaiaHotkey.abort: HotKey(
    key: PhysicalKeyboardKey.backspace,
    modifiers: [HotKeyModifier.control, HotKeyModifier.alt],
    scope: HotKeyScope.system,
  ),
};

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
/// `setLastTier {tier}`, `setTitle {chatId, title, from}`, `messages {chatId}`, `putMessage {message}`,
/// `rearm`, and the `runs {runs}`, `runDone {chatId, title,
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
  }) : _pipe = pipe ?? GaiaPipe(),
       _abortFlag = abortFlag ?? _defaultAbortFlag,
       _killCompanion = killCompanion ?? _killTree;

  static final instance = GaiaHost();

  final GaiaPipe _pipe;
  final Future<File> Function() _abortFlag;
  final Future<void> Function(int pid) _killCompanion;

  /// Chats in progress, for the tray and the Gaia page.
  final runs = ValueNotifier<List<GaiaRun>>(const []);

  final _attached = Completer<GaiaChatStore>();
  void Function(String chatId, String title, String body)? _toast;
  StreamSubscription<void>? _changes;
  StreamSubscription<GaiaSettings>? _settingsChanges;
  Timer? _changedSoon;
  var _settings = GaiaSettings.initial();

  var _started = false;
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
    if (registerHotkeys) {
      for (final MapEntry(key: action, value: hotkey) in _hotkeys.entries) {
        await hotKeyManager.register(
          hotkey,
          keyDownHandler: (_) => onHotkey(action),
        );
      }
    }
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
  }) {
    if (_attached.isCompleted) return;
    _toast = toast;
    _attached.complete(GaiaChatStore(repository, deviceId: deviceId));
    _changes = repository.watchChanges().listen((_) {
      _changedSoon ??= Timer(_changedDelay, () {
        _changedSoon = null;
        if (_pipe.connected) _pipe.notify('changed');
      });
    });
    _settingsChanges = repository.watchSettings().listen((settings) {
      _settings = settings;
      if (_pipe.connected) _pipe.notify('settings', settings.toJson());
    });
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

  /// Also the tray's and a second launch's way in.
  void onHotkey(GaiaHotkey hotkey) {
    if (hotkey == GaiaHotkey.abort) {
      unawaited(_abort());
      return;
    }
    _sendOrLaunch('hotkey', {'key': hotkey.name});
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
          params['sessionId']! as String,
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
}
