@Tags(['manual'])
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/features/gaia/host/gaia_os_control.dart';
import 'package:voyager/features/gaia/host/gaia_window_context.dart';
import 'package:win32/win32.dart';

/// Real input against a real foreground window (GAIA_HLD.md §15.6, §19): a
/// probe-owned WinForms window, so nothing else can be typed into. Unlocked
/// sessions only; it moves the cursor and takes the foreground for a few
/// seconds. Run it by path:
///   flutter test --run-skipped test/tool/gaia_os_control_live_test.dart
void main() {
  // What runner.exe.manifest gives the app. flutter_tester has no such manifest,
  // so Windows would scale UI Automation's bounds, the cursor and hit tests, but
  // not the DWM frame.
  setUpAll(() {
    expect(
      SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2),
      isNot(0),
    );
  });

  const probe = r'''
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
Add-Type -AssemblyName System.Windows.Forms
$form = New-Object Windows.Forms.Form
$form.Text = 'Gaia control probe'
$form.Width = 500; $form.Height = 320; $form.TopMost = $false
$form.StartPosition = 'CenterScreen'
$edit = New-Object Windows.Forms.TextBox
$edit.Name = 'Notes'; $edit.AccessibleName = 'Notes'
$edit.Left = 10; $edit.Top = 10; $edit.Width = 300; $edit.Multiline = $true; $edit.Height = 80
# A multiline TextBox ignores Ctrl+A by itself, so the chord's arrival is what's reported.
$edit.Add_KeyDown({ if ($_.Control -and $_.KeyCode -eq 'A') { $edit.SelectAll(); $_.SuppressKeyPress = $true; [Console]::Out.WriteLine('CTRL+A'); [Console]::Out.Flush() } })
$secret = New-Object Windows.Forms.TextBox
$secret.AccessibleName = 'Password'; $secret.UseSystemPasswordChar = $true
$secret.Left = 10; $secret.Top = 100; $secret.Width = 300
$button = New-Object Windows.Forms.Button
$button.Text = 'Save'; $button.Left = 10; $button.Top = 140
$button.Add_Click({ [Console]::Out.WriteLine('CLICKED'); [Console]::Out.Flush() })
$form.Controls.AddRange(@($edit, $secret, $button))
$timer = New-Object Windows.Forms.Timer
$timer.Interval = 200
$timer.Add_Tick({ [Console]::Out.WriteLine('TEXT:' + $edit.Text.Replace("`r`n", '|') + ':SECRET:' + $secret.Text); [Console]::Out.Flush() })
$timer.Start()
$other = New-Object Windows.Forms.Form
$other.Text = 'Gaia control other'
$other.Width = 200; $other.Height = 120; $other.StartPosition = 'Manual'
$other.Left = 0; $other.Top = 0
$form.Add_Shown({ $other.Show(); $form.Activate(); [Console]::Out.WriteLine('SHOWN'); [Console]::Out.Flush() })
[Windows.Forms.Application]::Run($form)
''';

  test(
    'finds real controls, and marks a sensitive one; sends nothing',
    () async {
      final process = await Process.start('powershell', [
        '-NoProfile',
        '-STA',
        '-Command',
        probe,
      ]);
      addTearDown(process.kill);
      var shown = false;
      process.stdout
          .transform(const SystemEncoding().decoder)
          .listen((chunk) => shown = shown || chunk.contains('SHOWN'));
      for (var i = 0; i < 100 && !shown; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(shown, isTrue);
      final hwnd = FindWindow(nullptr, 'Gaia control probe'.toNativeUtf16());
      expect(hwnd, isNot(0));
      List<GaiaControlMatch> matches(String name, {String? type}) =>
          gaiaScanWindow(
            hwnd,
            browser: false,
            text: false,
            find: (name: name, type: type),
          )!.matches;

      final save = matches('Save', type: 'Button').single;
      expect(save.type, 'Button');
      expect(save.sensitive, isFalse);
      expect(save.right - save.left, greaterThan(0));
      // UI Automation's bounds and the frame in the same pixels, whatever the
      // display's scale, or every click would be refused or land elsewhere.
      final frame = gaiaWindowFrame(hwnd);
      expect(
        save.left >= frame.left &&
            save.top >= frame.top &&
            save.right <= frame.left + frame.width &&
            save.bottom <= frame.top + frame.height,
        isTrue,
        reason: 'Save at ${save.left},${save.top}; window at $frame',
      );
      expect(matches('Save', type: 'Edit'), isEmpty);
      expect(matches('Notes').single.sensitive, isFalse);
      expect(matches('Password').single.sensitive, isTrue);
      expect(matches('Nothing like it'), isEmpty);
      // Only that it could be asked: what has focus is whatever the user is in.
      expect(gaiaFocusSensitive(hwnd, browser: false), isA<bool>());
    },
  );

  test(
    'clicks, types, chords and stops on a real window',
    () async {
      final process = await Process.start('powershell', [
        '-NoProfile',
        '-STA',
        '-Command',
        probe,
      ]);
      final lines = <String>[];
      process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(lines.add);
      addTearDown(process.kill);
      String lastText() =>
          lines.lastWhere((l) => l.startsWith('TEXT:'), orElse: () => '');
      Future<void> until(bool Function() done, String what) async {
        for (var i = 0; i < 100 && !done(); i++) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(
          done(),
          isTrue,
          reason: 'waiting for $what; last: ${jsonEncode(lastText())}',
        );
      }

      await until(() => lines.contains('SHOWN'), 'the window');
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final hwnd = FindWindow(nullptr, 'Gaia control probe'.toNativeUtf16());
      expect(hwnd, isNot(0));
      SetForegroundWindow(hwnd);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(
        GetForegroundWindow(),
        hwnd,
        reason: 'Windows kept the foreground elsewhere: nothing was sent.',
      );

      final control = GaiaOsControl(
        companionPid: () => -1,
        exclusions: () => const [],
        vaultUnlocked: () => false,
      );
      Future<void> check() async {}

      // A named control, clicked first; then text with a line break and an emoji.
      var card = await control.plan('chat', 'type', 'os_type', {
        'name': 'Notes',
        'text': 'hello\nworld 😀',
      });
      final typed = (card['steps']! as List).single as Map;
      expect(typed['resolved'], isTrue, reason: '${typed['label']}');
      var result = await control.run('type', once: true, check: check);
      expect(result['stopped'], isNull);
      await until(() => lastText().contains('hello|world 😀'), 'the text');

      // A chord: select all, and type over it.
      await control.plan('chat', 'steps', 'os_steps', {
        'steps': [
          {'action': 'key', 'keys': 'Ctrl+A'},
          {'action': 'type', 'text': 'replaced'},
        ],
      });
      result = await control.run('steps', once: true, check: check);
      expect(result['stopped'], isNull);
      await until(() => lastText().startsWith('TEXT:replaced:'), 'the chord');
      expect(lines, contains('CTRL+A'));

      // A click on a named button.
      await control.plan('chat', 'click', 'os_click', {
        'name': 'Save',
        'type': 'Button',
      });
      result = await control.run('click', once: true, check: check);
      expect(result['stopped'], isNull);
      await until(() => lines.contains('CLICKED'), 'the click');

      // Never into a sensitive field, by name or by focus.
      await expectLater(
        control.plan('chat', 'secret', 'os_type', {
          'name': 'Password',
          'text': 'hunter2',
        }),
        throwsA(anything),
      );
      await control.plan('chat', 'focus', 'os_click', {'name': 'Password'});
      await control.run('focus', once: true, check: check);
      await control.plan('chat', 'typed', 'os_type', {'text': 'hunter2'});
      result = await control.run('typed', once: true, check: check);
      expect(result['stopped'], contains('never types'));
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(lastText(), endsWith(':SECRET:'));

      // Stopped mid-text, as Abort does: fewer than all of it, and no keys down.
      await control.plan('chat', 'click2', 'os_click', {'name': 'Notes'});
      await control.run('click2', once: true, check: check);
      await control.plan('chat', 'long', 'os_type', {'text': 'y' * 1500});
      final running = control.run('long', once: true, check: check);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      control.stop('Gaia is aborted.');
      result = await running;
      expect(result['stopped'], 'Gaia is aborted.');
      await Future<void>.delayed(const Duration(milliseconds: 400));
      final ys = RegExp('y').allMatches(lastText()).length;
      expect(ys, inExclusiveRange(0, 1500), reason: 'stopped mid-text');
      expect(GetAsyncKeyState(VK_CONTROL) & 0x8000, 0);
      expect(GetAsyncKeyState(VK_SHIFT) & 0x8000, 0);
      expect(GetAsyncKeyState(VK_MENU) & 0x8000, 0);

      // Esc pressed mid-text, seen the way a real press is. Held longer than a
      // look (20 ms), and let go before the next step.
      void escape({required bool up}) {
        final input = calloc<INPUT>();
        input.ref.type = INPUT_KEYBOARD;
        input.ref.ki
          ..wVk = VK_ESCAPE
          ..dwFlags = up ? KEYEVENTF_KEYUP : 0;
        SendInput(1, input, sizeOf<INPUT>());
        free(input);
      }

      await control.plan('chat', 'esc', 'os_type', {'text': 'z' * 1500});
      final stopping = control.run('esc', once: true, check: check);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      escape(up: false);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      escape(up: true);
      result = await stopping;
      expect(result['stopped'], contains('Esc'));
      await Future<void>.delayed(const Duration(milliseconds: 400));
      final zs = RegExp('z').allMatches(lastText()).length;
      expect(zs, inExclusiveRange(0, 1500), reason: 'stopped mid-text');

      // Another window in front: the run stops, and sends nothing.
      await control.plan('chat', 'after', 'os_key', {'keys': 'A'});
      final other = FindWindow(nullptr, 'Gaia control other'.toNativeUtf16());
      expect(other, isNot(0));
      SetForegroundWindow(other);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(GetForegroundWindow(), other);
      final before = lastText();
      result = await control.run('after', once: true, check: check);
      expect(result['stopped'], contains('changed'));
      expect(result['ran'], 0);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(lastText(), before);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'brings the target up from behind Gaia, and then acts (BUG-337)',
    () async {
      final process = await Process.start('powershell', [
        '-NoProfile',
        '-STA',
        '-Command',
        probe,
      ]);
      final lines = <String>[];
      process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(lines.add);
      addTearDown(process.kill);
      Future<void> until(bool Function() done, String what) async {
        for (var i = 0; i < 100 && !done(); i++) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(done(), isTrue, reason: 'waiting for $what');
      }

      await until(() => lines.contains('SHOWN'), 'the window');
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final hwnd = FindWindow(nullptr, 'Gaia control probe'.toNativeUtf16());
      final gaia = FindWindow(nullptr, 'Gaia control other'.toNativeUtf16());
      expect(hwnd, isNot(0));
      expect(gaia, isNot(0));
      SetForegroundWindow(hwnd);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(GetForegroundWindow(), hwnd);

      // Planned with the target in front, so that it's the target; run with its
      // other window as Gaia, as if the user had just clicked Run on the card.
      var companion = -1;
      final control = GaiaOsControl(
        companionPid: () => companion,
        exclusions: () => const [],
        vaultUnlocked: () => false,
      );
      await control.plan('chat', 'click', 'os_click', {
        'name': 'Save',
        'type': 'Button',
      });
      SetForegroundWindow(gaia);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(GetForegroundWindow(), gaia);
      companion = process.pid;

      final result = await control.run('click', once: true, check: () async {});
      expect(result['stopped'], isNull);
      expect(result['ran'], 1);
      expect(GetForegroundWindow(), hwnd);
      await until(() => lines.contains('CLICKED'), 'the click');
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );
}
