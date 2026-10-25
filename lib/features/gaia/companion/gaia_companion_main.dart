import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:path/path.dart' as p;
import 'package:voyager/core/platform/app_data_directory.dart';
import 'package:voyager/core/platform/windows_keyboard_workaround.dart';
import 'package:voyager/features/gaia/adapters/claude_code/claude_code_runner.dart';
import 'package:voyager/features/gaia/companion/gaia_app.dart';
import 'package:voyager/features/gaia/companion/gaia_controller.dart';
import 'package:voyager/features/gaia/companion/gaia_dev_pipe.dart';
import 'package:voyager/features/gaia/companion/gaia_window.dart';
import 'package:voyager/features/gaia/gaia_pipe.dart';
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
  final pipe = dev ? GaiaDevPipe() : GaiaPipe();
  final controller = GaiaController(
    pipe: pipe,
    window: GaiaWindow(),
    // Gaia's own working directory, so the CLI never picks up an unrelated
    // project's instruction files (§5.1).
    runner: ClaudeCodeRunner(
      workingDirectory: p.join(root.path, 'gaia', 'ws'),
      instructionsFile: p.join(root.path, 'gaia', 'GAIA.md'),
    ),
  );
  runApp(GaiaApp(controller: controller));
  await controller.start();
  windowManager.addListener(_DismissOnClose(controller));
  if (pipe is GaiaDevPipe) {
    await _registerDevHotkeys(pipe);
    pipe.hotkey('window');
  }
}

/// Global, so they reach Gaia while it's hidden: Ctrl+Alt+1 small floater,
/// 2 large floater, 3 Gaia window, 4 Abort. Only in `--gaia-dev`, where no
/// main instance owns Gaia's real hotkeys.
Future<void> _registerDevHotkeys(GaiaDevPipe pipe) async {
  final actions = {
    PhysicalKeyboardKey.digit1: () => pipe.hotkey('small'),
    PhysicalKeyboardKey.digit2: () => pipe.hotkey('large'),
    PhysicalKeyboardKey.digit3: () => pipe.hotkey('window'),
    PhysicalKeyboardKey.digit4: pipe.abort,
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
  debugPrint('[gaia] dev mode: Ctrl+Alt+1 small, 2 large, 3 window, 4 abort');
}

class _DismissOnClose with WindowListener {
  _DismissOnClose(this.controller);

  final GaiaController controller;

  @override
  void onWindowClose() => controller.dismiss();
}
