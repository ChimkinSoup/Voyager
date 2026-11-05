// Ending every flash at once (`stopFlashes` on voyager/gaia_border), against
// the real runner's native flashes: each case counts the flash windows Windows
// shows. The last drives a real os_drag on a WinForms probe, stopped partway,
// so needs an unlocked session with the display on, and moves the cursor.
//
//   flutter test integration_test/gaia_flash_stop_test.dart -d windows
//
// Close any running Voyager first: the build replaces its exe.

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:voyager/features/gaia/host/gaia_flash.dart';
import 'package:voyager/features/gaia/host/gaia_os_control.dart';
import 'package:win32/win32.dart';

const _channel = MethodChannel('voyager/gaia_border');
const _accent = 0x7C9EFF;

/// This process's flash windows: all of them, and those showing.
({int all, int visible}) _flashWindows() {
  final name = 'VoyagerGaiaFlash'.toNativeUtf16();
  var all = 0, visible = 0;
  try {
    var hwnd = 0;
    while ((hwnd = FindWindowEx(0, hwnd, name, nullptr)) != 0) {
      all++;
      if (IsWindowVisible(hwnd) != 0) visible++;
    }
  } finally {
    free(name);
  }
  return (all: all, visible: visible);
}

Future<void> _play(Map<String, Object?> flash) => _channel.invokeMethod<void>(
  'flash',
  {'style': 'astral', ...flash, 'accent': _accent},
);

Future<void> _stop() => _channel.invokeMethod<void>('stopFlashes');

Future<void> _waitFor(
  bool Function() done,
  String what, {
  Duration within = const Duration(seconds: 5),
}) async {
  final until = DateTime.now().add(within);
  while (!done()) {
    if (DateTime.now().isAfter(until)) fail('Timed out waiting for $what');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

/// One of each kind, long enough to still be playing when stopped.
Future<void> _playEveryKind(String style) async {
  for (final flash in <Map<String, Object?>>[
    {'kind': 'click', 'x': 300, 'y': 300, 'label': 'Save'},
    {'kind': 'double', 'x': 380, 'y': 300},
    {'kind': 'right', 'x': 460, 'y': 300},
    {'kind': 'scroll', 'x': 300, 'y': 420, 'direction': 'down', 'amount': 9},
    {
      'kind': 'type',
      'left': 200,
      'top': 500,
      'right': 500,
      'bottom': 530,
      'ms': 4000,
      'label': 'Subject',
    },
    {
      'kind': 'key',
      'left': 100,
      'top': 100,
      'right': 900,
      'bottom': 700,
      'label': 'Ctrl+S',
    },
    {
      'kind': 'window',
      'left': 120,
      'top': 120,
      'right': 880,
      'bottom': 680,
      'label': 'Notepad',
    },
    {
      'kind': 'mark',
      'x': 600,
      'y': 300,
      'left': 580,
      'top': 290,
      'right': 620,
      'bottom': 310,
      'label': 'OK',
    },
    {'kind': 'mark', 'x': 650, 'y': 400},
    {
      'kind': 'drag',
      'x': 200,
      'y': 200,
      'to_x': 800,
      'to_y': 600,
      'ms': 4000,
      'label': 'Level',
    },
  ]) {
    await _play({...flash, 'style': style});
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUp(_stop);

  for (final style in ['classic', 'astral', 'echo', 'glide']) {
    testWidgets('one call ends every kind playing at once ($style)', (
      tester,
    ) async {
      await _playEveryKind(style);
      expect(_flashWindows().visible, greaterThanOrEqualTo(10));
      await _stop();
      expect(_flashWindows().visible, 0);
      // Nothing comes back: the timer that drew them is off.
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(_flashWindows().visible, 0);
    });
  }

  testWidgets('stopping with nothing playing is harmless', (tester) async {
    await _stop();
    await _stop();
    expect(_flashWindows().visible, 0);
  });

  testWidgets('flashes play again after a stop, and end on their own', (
    tester,
  ) async {
    await _play({
      'kind': 'drag',
      'x': 200,
      'y': 200,
      'to_x': 600,
      'to_y': 400,
      'ms': 2000,
    });
    await _stop();
    expect(_flashWindows().visible, 0);
    await _play({'kind': 'click', 'x': 300, 'y': 300, 'label': 'Again'});
    expect(_flashWindows().visible, 2);
    // A click's 580 ms, then hidden a few a frame.
    await _waitFor(
      () => _flashWindows().visible == 0,
      'the click to end',
      within: const Duration(seconds: 2),
    );
  });

  testWidgets('finished windows still waiting to hide are hidden too', (
    tester,
  ) async {
    // Ten that end together, so their hiding spreads over a few frames.
    for (var i = 0; i < 10; i++) {
      await _play({
        'kind': 'click',
        'x': 200 + i * 60,
        'y': 300,
        'label': 'C$i',
      });
    }
    await _waitFor(
      () => _flashWindows().visible < 20,
      'the clicks to start hiding',
      within: const Duration(seconds: 2),
    );
    await _stop();
    expect(_flashWindows().visible, 0);
  });

  testWidgets('stopping and playing over and over reuses the windows', (
    tester,
  ) async {
    for (var i = 0; i < 30; i++) {
      await _playEveryKind('astral');
      await _stop();
      expect(_flashWindows().visible, 0, reason: 'round $i');
    }
    // The pool keeps 16; any more are destroyed once released.
    expect(_flashWindows().all, lessThanOrEqualTo(16));
  });

  testWidgets("gaiaStopFlashes, as Gaia calls it, ends them", (tester) async {
    gaiaFlash({
      'kind': 'drag',
      'x': 200,
      'y': 200,
      'to_x': 700,
      'to_y': 500,
      'ms': 3000,
      'label': 'Level',
    }, _accent);
    await _waitFor(() => _flashWindows().visible > 0, 'the drag to show');
    gaiaStopFlashes();
    await _waitFor(
      () => _flashWindows().visible == 0,
      'the stop',
      within: const Duration(milliseconds: 500),
    );
  });

  group('a real os_drag (needs the display on)', () {
    const probe = r'''
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
Add-Type -AssemblyName System.Windows.Forms
$form = New-Object Windows.Forms.Form
$form.Text = 'Gaia flash stop probe'
$form.Width = 600; $form.Height = 200; $form.StartPosition = 'Manual'
$form.Left = 150; $form.Top = 150; $form.TopMost = $true
$track = New-Object Windows.Forms.TrackBar
$track.AccessibleName = 'Level'; $track.Left = 10; $track.Top = 10; $track.Width = 500
$track.Minimum = 0; $track.Maximum = 100; $track.Value = 50; $track.TickStyle = 'None'
$form.Controls.Add($track)
$timer = New-Object Windows.Forms.Timer
$timer.Interval = 50
$timer.Add_Tick({ [Console]::Out.WriteLine('VALUE:' + $track.Value + ':BUTTONS:' + [Windows.Forms.Control]::MouseButtons); [Console]::Out.Flush() })
$timer.Start()
$form.Add_Shown({ $form.Activate(); [Console]::Out.WriteLine('SHOWN'); [Console]::Out.Flush() })
[Windows.Forms.Application]::Run($form)
''';

    late List<String> lines;
    late List<Map<String, Object?>> played;
    late GaiaOsControl control;
    late Process process;

    /// An empty spot in the probe, below its trackbar.
    late ({int x, int y}) blank;

    int value() => int.parse(
      lines.lastWhere((line) => line.startsWith('VALUE:')).split(':')[1],
    );
    String buttons() =>
        lines.lastWhere((line) => line.startsWith('VALUE:')).split(':')[3];

    Future<Map<String, Object?>> act(
      String tool,
      Map<String, Object?> args,
    ) async {
      await control.plan('chat', 'card', tool, args);
      return control.run('card', once: true, check: () async {});
    }

    /// The probe, in front in a session, and where its trackbar ends: the
    /// screen's scale is whatever this machine's is.
    Future<({int x, int y})> startProbe() async {
      // One left by a run that crashed would make the title ambiguous.
      final title = 'Gaia flash stop probe'.toNativeUtf16();
      try {
        var stray = 0;
        while ((stray = FindWindow(nullptr, title)) != 0) {
          PostMessage(stray, WM_CLOSE, 0, 0);
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
      } finally {
        free(title);
      }
      // Started from a windowed app, PowerShell gets a console of its own,
      // which mustn't be what's in front.
      process = await Process.start('powershell', [
        '-NoProfile',
        '-STA',
        '-WindowStyle',
        'Hidden',
        '-Command',
        probe,
      ]);
      addTearDown(process.kill);
      lines = [];
      process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(lines.add);
      await _waitFor(
        () => lines.contains('SHOWN'),
        'the probe',
        within: const Duration(seconds: 15),
      );
      played = [];
      control = GaiaOsControl(
        companionPid: () => -1,
        exclusions: () => const [],
        vaultUnlocked: () => false,
        flash: (flash) {
          played.add(flash);
          gaiaFlash(flash, _accent);
        },
        stopFlashes: gaiaStopFlashes,
      );
      addTearDown(control.endTurn);
      control.session(
        'chat',
        auto: true,
        onUserStop: () {},
        needsWindow: false,
      );
      final focused = await act('os_focus', {
        'window': 'Gaia flash stop probe',
      });
      expect(focused['stopped'], isNull);
      // The trackbar's rect, from its card label: "[left,top wxh]".
      final card = await control.plan('chat', 'peek', 'os_click', {
        'name': 'Level',
      });
      control.drop('peek');
      final label = ((card['steps']! as List).single as Map)['label'] as String;
      final m = RegExp(r'\[(-?\d+),(-?\d+) (\d+)x(\d+)\]').firstMatch(label)!;
      final (left, top, width, height) = (
        int.parse(m[1]!),
        int.parse(m[2]!),
        int.parse(m[3]!),
        int.parse(m[4]!),
      );
      await _waitFor(() => lines.any((l) => l.startsWith('VALUE:')), 'values');
      // Only the drag's own, from here.
      played.clear();
      blank = (x: left + width ~/ 4, y: top + height + 30);
      return (x: left + width - 5, y: top + height ~/ 2);
    }

    /// Closes the probe while the test still runs: focus coming back to this
    /// window after the test has ended trips over its disposed FocusManager.
    Future<void> closeProbe(WidgetTester tester) async {
      control.endTurn();
      process.kill();
      await process.exitCode;
      await tester.pump(const Duration(milliseconds: 300));
    }

    testWidgets('stopped partway, its trail ends at once, and it lets go '
        'where it started', (tester) async {
      final end = await startProbe();
      // Once the button is down and it has moved a little, stop.
      var trailShowing = false;
      final watch = Timer.periodic(const Duration(milliseconds: 5), (timer) {
        if (GetAsyncKeyState(VK_LBUTTON) & 0x8000 == 0) return;
        timer.cancel();
        Timer(const Duration(milliseconds: 80), () {
          trailShowing = _flashWindows().visible > 0;
          control.stop('The user pressed Esc.');
        });
      });
      final result = await act('os_drag', {
        'from': {'name': 'Level'},
        'to': {'x': end.x, 'y': end.y},
      });
      watch.cancel();
      expect(
        result['stopped'],
        'The user pressed Esc.',
        reason: 'The drag never got the button down: $result',
      );
      expect(played.map((f) => f['kind']), ['drag']);
      expect(trailShowing, isTrue);
      // Gone well before the 910 ms the trail would have played.
      final stoppedAt = DateTime.now();
      await _waitFor(
        () => _flashWindows().visible == 0,
        'the trail to end',
        within: const Duration(milliseconds: 300),
      );
      expect(
        DateTime.now().difference(stoppedAt),
        lessThan(const Duration(milliseconds: 300)),
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(GetAsyncKeyState(VK_LBUTTON) & 0x8000, 0);
      expect(buttons(), 'None');
      expect(value(), inInclusiveRange(40, 60));
      await closeProbe(tester);
    });

    testWidgets('stopped once the user has the mouse, it lets go where they '
        'have it and leaves the cursor there', (tester) async {
      final end = await startProbe();
      final watch = Timer.periodic(const Duration(milliseconds: 5), (timer) {
        if (GetAsyncKeyState(VK_LBUTTON) & 0x8000 == 0) return;
        timer.cancel();
        Timer(const Duration(milliseconds: 80), () {
          // The user's hand, then their Esc.
          SetCursorPos(blank.x, blank.y);
          control.stop('The user pressed Esc.');
        });
      });
      final result = await act('os_drag', {
        'from': {'name': 'Level'},
        'to': {'x': end.x, 'y': end.y},
      });
      watch.cancel();
      expect(result['stopped'], 'The user pressed Esc.');
      final point = calloc<POINT>();
      GetCursorPos(point);
      final at = (x: point.ref.x, y: point.ref.y);
      free(point);
      expect(at, blank, reason: 'The cursor was taken back from the user.');
      await _waitFor(
        () => _flashWindows().visible == 0,
        'the trail to end',
        within: const Duration(milliseconds: 300),
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(GetAsyncKeyState(VK_LBUTTON) & 0x8000, 0);
      expect(buttons(), 'None');
      await closeProbe(tester);
    });

    testWidgets('finished, it lands and its trail plays out on its own', (
      tester,
    ) async {
      final end = await startProbe();
      final started = DateTime.now();
      final result = await act('os_drag', {
        'from': {'name': 'Level'},
        'to': {'x': end.x, 'y': end.y},
      });
      expect(result['stopped'], isNull);
      expect(played.single['kind'], 'drag');
      expect(played.single['ms'], 330);
      // Still playing after the button comes up, as the orb, grown on the
      // way, holds a moment before it fades.
      expect(_flashWindows().visible, greaterThan(0));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(_flashWindows().visible, greaterThan(0));
      await _waitFor(
        () => _flashWindows().visible == 0,
        'the trail to play out',
        within: const Duration(seconds: 2),
      );
      debugPrint(
        '[probe] drag and trail took ${DateTime.now().difference(started)}',
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(value(), greaterThan(80));
      expect(buttons(), 'None');
      await closeProbe(tester);
    });
  });
}
