@Tags(['manual'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/features/gaia/host/gaia_clipboard.dart';
import 'package:voyager/features/gaia/host/gaia_os_control.dart';
import 'package:voyager/features/gaia/host/gaia_window_context.dart';
import 'package:win32/win32.dart';

/// `os_window`, `os_drag` and `os_clipboard` (GAIA_AUTONOMY_HLD.md §8.3–§8.5)
/// against real Win32: a probe-owned WinForms window and the real clipboard,
/// whose text is put back after. The clipboard and window tests need no
/// display; the drags need an unlocked session with the display on, and move
/// the cursor. Run it by path:
///   flutter test --run-skipped test/tool/gaia_more_tools_live_test.dart
void main() {
  setUpAll(() {
    expect(
      SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2),
      isNot(0),
    );
  });

  group('os_clipboard', () {
    String? saved;
    setUpAll(() async => saved = (await gaiaReadClipboard()).text);
    tearDownAll(() async {
      if (saved case final text?) await gaiaWriteClipboard(text);
    });

    /// Sets the clipboard from another process, as a password manager would,
    /// with [formats] beside the text, each a DWORD.
    Future<void> copyElsewhere(String text, Map<String, int> formats) async {
      final result = await Process.run('powershell', [
        '-NoProfile',
        '-STA',
        '-Command',
        [
          'Add-Type -AssemblyName System.Windows.Forms',
          r'$d = New-Object Windows.Forms.DataObject',
          "\$d.SetData([Windows.Forms.DataFormats]::UnicodeText, '$text')",
          for (final MapEntry(:key, :value) in formats.entries)
            "\$d.SetData('$key', \$false, (New-Object IO.MemoryStream(,"
                '[BitConverter]::GetBytes([uint32]$value))))',
          r'[Windows.Forms.Clipboard]::SetDataObject($d, $true)',
        ].join('; '),
      ]);
      expect(result.exitCode, 0, reason: '${result.stderr}');
    }

    test("Gaia's write reads back, and is kept out of history", () async {
      expect(await gaiaWriteClipboard('gaia probe ✓ π'), isTrue);
      final read = await gaiaReadClipboard();
      expect(read.text, 'gaia probe ✓ π');
      expect(read.private, isFalse);
      expect(read.ours, isTrue);
      expect(OpenClipboard(NULL), isNot(0));
      try {
        for (final format in [
          'CanIncludeInClipboardHistory',
          'CanUploadToCloudClipboard',
        ]) {
          final name = format.toNativeUtf16();
          final id = RegisterClipboardFormat(name);
          free(name);
          final handle = GetClipboardData(id);
          expect(handle, isNot(0), reason: format);
          final memory = Pointer.fromAddress(handle);
          expect(GlobalLock(memory).cast<Uint32>().value, 0, reason: format);
          GlobalUnlock(memory);
        }
      } finally {
        CloseClipboard();
      }
    });

    test('another app\'s plain copy reads', () async {
      await copyElsewhere('plain copy', const {});
      final read = await gaiaReadClipboard();
      expect(read.private, isFalse);
      expect(read.text, 'plain copy');
    });

    test("a password manager's copy is refused, by either marking", () async {
      await copyElsewhere('hunter2', const {
        'ExcludeClipboardContentFromMonitorProcessing': 0,
      });
      var read = await gaiaReadClipboard();
      expect(read.private, isTrue);
      expect(read.text, isNull);
      await copyElsewhere('hunter2', const {'CanIncludeInClipboardHistory': 0});
      read = await gaiaReadClipboard();
      expect(read.private, isTrue);
      expect(read.text, isNull);
      // Allowed in history is no marking.
      await copyElsewhere('fine', const {'CanIncludeInClipboardHistory': 1});
      expect((await gaiaReadClipboard()).text, 'fine');
    });
  });

  const probe = r'''
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
Add-Type -AssemblyName System.Windows.Forms
$form = New-Object Windows.Forms.Form
$form.Text = 'Gaia phase five probe'
$form.Width = 500; $form.Height = 200; $form.StartPosition = 'Manual'
$form.Left = 150; $form.Top = 150
$track = New-Object Windows.Forms.TrackBar
$track.AccessibleName = 'Level'; $track.Left = 10; $track.Top = 10; $track.Width = 400
$track.Minimum = 0; $track.Maximum = 100; $track.Value = 50; $track.TickStyle = 'None'
$form.Controls.Add($track)
$timer = New-Object Windows.Forms.Timer
$timer.Interval = 100
$timer.Add_Tick({ [Console]::Out.WriteLine('VALUE:' + $track.Value + ':BUTTONS:' + [Windows.Forms.Control]::MouseButtons); [Console]::Out.Flush() })
$timer.Start()
$form.Add_Shown({ [Console]::Out.WriteLine('SHOWN'); [Console]::Out.Flush() })
$form.Add_FormClosed({ [Console]::Out.WriteLine('CLOSED'); [Console]::Out.Flush() })
[Windows.Forms.Application]::Run($form)
''';

  late Process process;
  late List<String> lines;
  late GaiaOsControl control;

  Future<void> waitFor(bool Function() done, String what) async {
    final until = DateTime.now().add(const Duration(seconds: 10));
    while (!done()) {
      if (DateTime.now().isAfter(until)) fail('Timed out waiting for $what');
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  Future<void> startProbe() async {
    process = await Process.start('powershell', [
      '-NoProfile',
      '-STA',
      '-Command',
      probe,
    ]);
    lines = [];
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(lines.add);
    await waitFor(() => lines.contains('SHOWN'), 'the probe');
    control = GaiaOsControl(
      companionPid: () => -1,
      exclusions: () => const [],
      vaultUnlocked: () => false,
    );
  }

  int probeWindow() {
    final title = 'Gaia phase five probe'.toNativeUtf16();
    try {
      return FindWindow(nullptr, title);
    } finally {
      free(title);
    }
  }

  Future<Map<String, Object?>> act(
    String tool,
    Map<String, Object?> arguments,
  ) async {
    await control.plan('chat', 'card', tool, arguments);
    return control.run('card', once: true, check: () async {});
  }

  group('os_window', () {
    setUp(startProbe);
    tearDown(() => process.kill());

    test('moves, resizes, minimizes, maximizes, restores and closes a real '
        'window', () async {
      final hwnd = probeWindow();
      expect(hwnd, isNot(0));
      const name = 'Gaia phase five probe';
      var result = await act('os_window', {
        'window': name,
        'action': 'move',
        'left': 300,
        'top': 220,
        'width': 900,
        'height': 400,
      });
      expect(result['stopped'], isNull);
      await waitFor(() {
        final frame = gaiaWindowFrame(hwnd);
        return frame.left == 300 &&
            frame.top == 220 &&
            frame.width == 900 &&
            frame.height == 400;
      }, 'the move to 300,220 900x400, at ${gaiaWindowFrame(hwnd)}');

      result = await act('os_window', {'window': hwnd, 'action': 'minimize'});
      expect(result['stopped'], isNull);
      await waitFor(() => IsIconic(hwnd) != 0, 'minimized');

      result = await act('os_window', {'window': hwnd, 'action': 'maximize'});
      expect(result['stopped'], isNull);
      await waitFor(() => IsZoomed(hwnd) != 0, 'maximized');

      // A move out of maximized restores it first.
      result = await act('os_window', {
        'window': hwnd,
        'action': 'move',
        'left': 200,
        'top': 200,
      });
      expect(result['stopped'], isNull);
      await waitFor(
        () =>
            IsZoomed(hwnd) == 0 &&
            gaiaWindowFrame(hwnd).left == 200 &&
            gaiaWindowFrame(hwnd).top == 200,
        'restored and moved',
      );

      // Minimized from maximized, it comes back maximized: moved all the same.
      result = await act('os_window', {'window': hwnd, 'action': 'maximize'});
      await waitFor(() => IsZoomed(hwnd) != 0, 'maximized again');
      result = await act('os_window', {'window': hwnd, 'action': 'minimize'});
      await waitFor(() => IsIconic(hwnd) != 0, 'minimized from maximized');
      result = await act('os_window', {
        'window': hwnd,
        'action': 'move',
        'left': 250,
        'top': 240,
      });
      expect(result['stopped'], isNull);
      await waitFor(
        () =>
            IsZoomed(hwnd) == 0 &&
            IsIconic(hwnd) == 0 &&
            gaiaWindowFrame(hwnd).left == 250 &&
            gaiaWindowFrame(hwnd).top == 240,
        'restored from minimized and moved, at ${gaiaWindowFrame(hwnd)}',
      );

      result = await act('os_window', {'window': hwnd, 'action': 'close'});
      expect(result['stopped'], isNull);
      await waitFor(() => lines.contains('CLOSED'), 'the close');
    });
  });

  group('os_drag (needs the display on)', () {
    setUp(startProbe);
    tearDown(() {
      control.endTurn();
      process.kill();
    });

    /// The trackbar's rect, from its card label: "[left,top wxh]".
    Future<({int left, int top, int width, int height})> trackbar() async {
      final card = await control.plan('chat', 'peek', 'os_click', {
        'name': 'Level',
      });
      control.drop('peek');
      final label = ((card['steps']! as List).single as Map)['label'] as String;
      final m = RegExp(r'\[(-?\d+),(-?\d+) (\d+)x(\d+)\]').firstMatch(label)!;
      return (
        left: int.parse(m[1]!),
        top: int.parse(m[2]!),
        width: int.parse(m[3]!),
        height: int.parse(m[4]!),
      );
    }

    int value() => int.parse(
      lines.lastWhere((line) => line.startsWith('VALUE:')).split(':')[1],
    );
    String buttons() =>
        lines.lastWhere((line) => line.startsWith('VALUE:')).split(':')[3];

    Future<void> focusProbe() async {
      control.session(
        'chat',
        auto: true,
        onUserStop: () {},
        needsWindow: false,
      );
      final focused = await act('os_focus', {
        'window': 'Gaia phase five probe',
      });
      expect(focused['stopped'], isNull);
    }

    test('drags the thumb to the end and lets go', () async {
      await focusProbe();
      final bar = await trackbar();
      final result = await act('os_drag', {
        'from': {'name': 'Level'},
        'to': {'x': bar.left + bar.width - 5, 'y': bar.top + bar.height ~/ 2},
      });
      expect(result['stopped'], isNull);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(value(), greaterThan(80));
      expect(buttons(), 'None');
      expect(GetAsyncKeyState(VK_LBUTTON) & 0x8000, 0);
    });

    test('stopped mid-drag, no button stays down', () async {
      await focusProbe();
      final bar = await trackbar();
      // Once the button is down and the drag has moved a little.
      var held = false;
      final watch = Timer.periodic(const Duration(milliseconds: 5), (timer) {
        if (GetAsyncKeyState(VK_LBUTTON) & 0x8000 == 0) return;
        held = true;
        timer.cancel();
        Timer(
          const Duration(milliseconds: 100),
          () => control.stop('The user pressed Esc.'),
        );
      });
      final result = await act('os_drag', {
        'from': {'name': 'Level'},
        'to': {'x': bar.left + bar.width - 5, 'y': bar.top + bar.height ~/ 2},
      });
      watch.cancel();
      expect(held, isTrue);
      expect(result['stopped'], startsWith('The user pressed Esc. The drag'));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(buttons(), 'None');
      expect(GetAsyncKeyState(VK_LBUTTON) & 0x8000, 0);
      // Let go where it started: about where it was.
      expect(value(), inInclusiveRange(40, 60));
    });
  });
}
