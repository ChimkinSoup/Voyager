import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:path/path.dart' as p;
import 'package:voyager/core/platform/app_data_directory.dart';
import 'package:voyager/core/platform/windows_keyboard_workaround.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/adapters/claude_code/claude_code_runner.dart';
import 'package:voyager/features/gaia/adapters/codex/codex_runner.dart';
import 'package:voyager/features/gaia/companion/gaia_app.dart';
import 'package:voyager/features/gaia/companion/gaia_controller.dart';
import 'package:voyager/features/gaia/companion/gaia_debug.dart';
import 'package:voyager/features/gaia/companion/gaia_dev_pipe.dart';
import 'package:voyager/features/gaia/companion/gaia_sidebar.dart';
import 'package:voyager/features/gaia/companion/gaia_window.dart';
import 'package:voyager/features/gaia/gaia_pipe.dart';
import 'package:voyager/features/gaia/utility/claude_utility_runner.dart';
import 'package:voyager/features/gaia/utility/gaia_utility.dart';
import 'package:window_manager/window_manager.dart';

/// `voyager.exe --companion`, launched by the main instance (GAIA_HLD.md
/// §3.2). It never opens Voyager's database or Firebase: everything it
/// keeps goes to the main instance over the pipe.
///
/// [dev] is `flutter run -d windows -a --gaia-dev` (debug builds only): the
/// companion alone, talking to a [GaiaDevPipe] instead of the main instance,
/// so hot reload reaches Gaia's UI. See [_registerDevHotkeys].
Future<void> gaiaCompanionMain({bool dev = false}) async {
  WidgetsFlutterBinding.ensureInitialized();
  installWindowsKeyboardWorkaround();
  // The hotkeys that open it arrive with Ctrl and Alt still held.
  WindowsKeyboardReconciler.instance.install();
  final root = await appSupportRoot();
  // The companion's console isn't shown anywhere, so its debug output also
  // goes to a file, started afresh by each companion.
  final log = File(p.join(root.path, 'gaia', 'companion.log'));
  await log.parent.create(recursive: true);
  await log.writeAsString('');
  final console = debugPrint;
  debugPrint = (message, {wrapWidth}) {
    console(message, wrapWidth: wrapWidth);
    try {
      log.writeAsStringSync(
        '${DateTime.now().toIso8601String()} $message\n',
        mode: FileMode.append,
      );
    } on FileSystemException {
      // The console still has it.
    }
  };
  // A draft lives only as long as its companion.
  final drafts = Directory(p.join(root.path, 'gaia', 'drafts'));
  if (await drafts.exists()) await drafts.delete(recursive: true);
  final pipe = dev ? GaiaDevPipe() : GaiaPipe();
  final debug = GaiaDebug(file: File(p.join(root.path, 'gaia', 'debug.json')));
  await debug.load();
  final sidebar = GaiaSidebar(
    file: File(p.join(root.path, 'gaia', 'sidebar.json')),
  );
  await sidebar.load();
  final controller = GaiaController(
    debug: debug,
    sidebar: sidebar,
    pipe: pipe,
    window: GaiaWindow(),
    draftDirectory: drafts.path,
    // Gaia's own working directory, so the CLI never picks up an unrelated
    // project's instruction files (§5.1).
    runners: {
      kGaiaClaudeCodeAdapter: ClaudeCodeRunner(
        workingDirectory: p.join(root.path, 'gaia', 'ws'),
        instructionsFile: p.join(root.path, 'gaia', 'GAIA.md'),
      ),
      kGaiaCodexAdapter: CodexRunner(
        workingDirectory: p.join(root.path, 'gaia', 'ws'),
        codexHome: await defaultGaiaCodexHome(),
      ),
    },
    utility: GaiaUtility(
      ClaudeUtilityRunner(
        workingDirectory: p.join(root.path, 'gaia', 'utility'),
      ),
    ),
  );
  runApp(GaiaApp(controller: controller));
  // Before start, which can already show the window.
  windowManager.addListener(_DismissOnClose(controller));
  windowManager.addListener(_TrackFocus(controller));
  _escapeCancelsCrop(controller);
  await controller.start();
  if (pipe is GaiaDevPipe) {
    await _registerDevHotkeys(pipe);
    pipe.hotkey('window');
  }
}

/// Global, so they reach Gaia while it's hidden: Ctrl+Alt+1 small floater,
/// 2 large floater, 3 Gaia window, 4 Abort, 5 region screenshot, 6 screen
/// screenshot. Only in `--gaia-dev`, where no main instance owns Gaia's
/// real hotkeys.
Future<void> _registerDevHotkeys(GaiaDevPipe pipe) async {
  final actions = {
    PhysicalKeyboardKey.digit1: () => pipe.hotkey('small'),
    PhysicalKeyboardKey.digit2: () => pipe.hotkey('large'),
    PhysicalKeyboardKey.digit3: () => pipe.hotkey('window'),
    PhysicalKeyboardKey.digit4: pipe.abort,
    PhysicalKeyboardKey.digit5: () => pipe.capture('region'),
    PhysicalKeyboardKey.digit6: () => pipe.capture('screen'),
  };
  for (final MapEntry(key: key, value: action) in actions.entries) {
    await hotKeyManager.register(
      HotKey(
        key: key,
        modifiers: [HotKeyModifier.control, HotKeyModifier.alt],
        scope: HotKeyScope.system,
      ),
      keyDownHandler: (_) => action(),
    );
  }
  debugPrint(
    '[gaia] dev mode: Ctrl+Alt+1 small, 2 large, 3 window, 4 abort, '
    '5 region, 6 screen',
  );
}

/// Esc is system-wide while the crop overlay is up, so it cancels the crop
/// even when the overlay's own Esc can't: the overlay never got the focus,
/// or the keyboard state holds a modifier whose release went elsewhere, as
/// spamming the capture hotkey leaves it.
void _escapeCancelsCrop(GaiaController controller) {
  final escape = HotKey(
    key: PhysicalKeyboardKey.escape,
    // Never null: the Windows plugin reads the list unchecked and aborts.
    modifiers: [],
    scope: HotKeyScope.system,
  );
  var registered = false;
  controller.addListener(() async {
    final cropping = controller.cropping != null;
    if (cropping == registered) return;
    registered = cropping;
    try {
      if (cropping) {
        await hotKeyManager.register(
          escape,
          keyDownHandler: (_) => unawaited(controller.finishCrop(null)),
        );
      } else {
        await hotKeyManager.unregister(escape);
      }
    } catch (error) {
      debugPrint(
        '[gaia] crop Esc not ${cropping ? '' : 'un'}registered: $error',
      );
    }
  });
}

class _DismissOnClose with WindowListener {
  _DismissOnClose(this.controller);

  final GaiaController controller;

  @override
  void onWindowClose() => controller.dismiss();
}

/// Hiding and minimising blur too: window_manager reports focus from
/// `WM_NCACTIVATE`.
class _TrackFocus with WindowListener {
  _TrackFocus(this.controller);

  final GaiaController controller;

  @override
  void onWindowFocus() => controller.focused.value = true;

  @override
  void onWindowBlur() => controller.focused.value = false;

  // Minimised in window mode is still shown as far as the controller knows,
  // so muting the tickers is up to this.
  @override
  void onWindowMinimize() => controller.onScreen.value = false;

  @override
  void onWindowRestore() => controller.onScreen.value = true;

  @override
  void onWindowMaximize() => controller.onScreen.value = true;
}
