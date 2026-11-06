@Tags(['manual'])
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/features/gaia/host/gaia_clipboard.dart';
import 'package:voyager/features/gaia/host/gaia_os_control.dart';
import 'package:voyager/features/gaia/host/gaia_selection.dart';
import 'package:voyager/features/gaia/host/gaia_voyager_reads.dart';
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
$open = New-Object Windows.Forms.Button
$open.Text = 'Open dialog'; $open.Left = 100; $open.Top = 140; $open.Width = 120
$open.Add_Click({
  $dialog = New-Object Windows.Forms.Form
  $dialog.Text = 'Gaia control dialog'
  $dialog.Width = 300; $dialog.Height = 200; $dialog.StartPosition = 'CenterParent'
  $note = New-Object Windows.Forms.TextBox
  $note.AccessibleName = 'Dialog note'; $note.Left = 10; $note.Top = 10; $note.Width = 200
  $done = New-Object Windows.Forms.Button
  $done.Text = 'Done'; $done.Left = 10; $done.Top = 60
  $done.Add_Click({ [Console]::Out.WriteLine('DIALOG:' + $note.Text); [Console]::Out.Flush(); $dialog.Close() })
  $dialog.Controls.AddRange(@($note, $done))
  [void]$dialog.ShowDialog($form)
  [Console]::Out.WriteLine('DIALOG CLOSED'); [Console]::Out.Flush()
})
$form.Controls.AddRange(@($edit, $secret, $button, $open))
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
      await control.plan('chat', 'long', 'os_type', {'text': 'y' * 190});
      final running = control.run('long', once: true, check: check);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      control.stop('Gaia is aborted.');
      result = await running;
      expect(result['stopped'], 'Gaia is aborted.');
      await Future<void>.delayed(const Duration(milliseconds: 400));
      final ys = RegExp('y').allMatches(lastText()).length;
      expect(ys, inExclusiveRange(0, 190), reason: 'stopped mid-text');
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

      await control.plan('chat', 'esc', 'os_type', {'text': 'z' * 190});
      final stopping = control.run('esc', once: true, check: check);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      escape(up: false);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      escape(up: true);
      result = await stopping;
      expect(result['stopped'], contains('Esc'));
      await Future<void>.delayed(const Duration(milliseconds: 400));
      final zs = RegExp('z').allMatches(lastText()).length;
      expect(zs, inExclusiveRange(0, 190), reason: 'stopped mid-text');

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

  test(
    "pastes long text, and puts back the user's clipboard, still readable",
    () async {
      // The user's own clipboard, every format, as it was before the test.
      final users = gaiaSaveClipboard();
      expect(users, isNotNull);
      addTearDown(() => gaiaRestoreClipboard(users!));
      Future<void> copy(String text, {bool private = false}) async {
        final set = await Process.run('powershell', [
          '-NoProfile',
          '-STA',
          '-Command',
          'Add-Type -AssemblyName System.Windows.Forms; '
              r'$d = New-Object Windows.Forms.DataObject; '
              "\$d.SetText('$text'); "
              '${private ? r"$d.SetData('ExcludeClipboardContentFromMonitorProcessing', $false, (New-Object IO.MemoryStream(,[byte[]](0,0,0,0)))); " : ''}'
              r'[Windows.Forms.Clipboard]::SetDataObject($d, $true)',
        ]);
        expect(set.exitCode, 0, reason: '${set.stderr}');
      }

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
        expect(done(), isTrue, reason: 'waiting for $what');
      }

      await until(() => lines.contains('SHOWN'), 'the window');
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final hwnd = FindWindow(nullptr, 'Gaia control probe'.toNativeUtf16());
      expect(hwnd, isNot(0));
      final f24 = calloc<INPUT>(2);
      for (final i in [0, 1]) {
        f24[i].type = INPUT_KEYBOARD;
        f24[i].ki
          ..wVk = VK_F24
          ..dwFlags = i == 1 ? KEYEVENTF_KEYUP : 0;
      }
      SendInput(2, f24, sizeOf<INPUT>());
      free(f24);
      SetForegroundWindow(hwnd);
      await until(() => GetForegroundWindow() == hwnd, 'the foreground');

      final control = GaiaOsControl(
        companionPid: () => -1,
        exclusions: () => const [],
        vaultUnlocked: () => false,
      );
      final long = List.generate(6, (i) => 'line $i ${'p' * 100}').join('\n');
      for (final private in [false, true]) {
        await copy('gaia paste test copy', private: private);
        await control.plan('chat', 'paste', 'os_type', {
          'name': 'Notes',
          'text': long,
        });
        final took = Stopwatch()..start();
        final result = await control.run(
          'paste',
          once: true,
          check: () async {},
        );
        took.stop();
        expect(result['stopped'], isNull);
        // Typed, it would be about 20 s.
        expect(took.elapsed, lessThan(const Duration(seconds: 3)));
        await until(
          () => lastText().startsWith('TEXT:${long.replaceAll('\n', '|')}:'),
          'the pasted text',
        );
        final after = await gaiaReadClipboard();
        expect(after.private, private);
        expect(after.text, private ? isNull : 'gaia paste test copy');
        // ignore: avoid_print
        print(
          'pasted ${long.length} characters in ${took.elapsedMilliseconds} '
          'ms; private copy: $private',
        );
        // Cleared for the next round.
        await control.plan('chat', 'clear', 'os_steps', {
          'steps': [
            {'action': 'key', 'keys': 'Ctrl+A'},
            {'action': 'key', 'keys': 'Delete'},
          ],
        });
        await control.run('clear', once: true, check: () async {});
        await until(() => lastText().startsWith('TEXT::'), 'the clear');
      }
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );

  group('an Auto session (GAIA_AUTONOMY_HLD.md §5)', () {
    late List<String> lines;
    late int hwnd;
    late int other;
    late int stops;
    late GaiaOsControl control;

    void key(int vk, {required bool up}) {
      final input = calloc<INPUT>();
      input.ref.type = INPUT_KEYBOARD;
      input.ref.ki
        ..wVk = vk
        ..dwFlags = up ? KEYEVENTF_KEYUP : 0;
      SendInput(1, input, sizeOf<INPUT>());
      free(input);
    }

    Future<void> until(bool Function() done, String what) async {
      for (var i = 0; i < 100 && !done(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(done(), isTrue, reason: 'waiting for $what');
    }

    /// In front, as the user's click would put it: the tap gives this process
    /// the right.
    Future<void> toFront(int window) async {
      key(VK_F24, up: false);
      key(VK_F24, up: true);
      SetForegroundWindow(window);
      await until(() => GetForegroundWindow() == window, 'the foreground');
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }

    Future<Map<String, Object?>> act(
      String tool,
      Map<String, Object?> arguments,
    ) async {
      control.session('chat', auto: true, onUserStop: () => stops++);
      await control.plan('chat', 'card', tool, arguments);
      return control.run('card', once: true, check: () async {});
    }

    setUp(() async {
      lines = [];
      stops = 0;
      final process = await Process.start('powershell', [
        '-NoProfile',
        '-STA',
        '-Command',
        probe,
      ]);
      process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(lines.add);
      addTearDown(process.kill);
      await until(() => lines.contains('SHOWN'), 'the window');
      await Future<void>.delayed(const Duration(milliseconds: 300));
      hwnd = FindWindow(nullptr, 'Gaia control probe'.toNativeUtf16());
      other = FindWindow(nullptr, 'Gaia control other'.toNativeUtf16());
      expect(hwnd, isNot(0));
      expect(other, isNot(0));
      control = GaiaOsControl(
        companionPid: () => -1,
        exclusions: () => const [],
        vaultUnlocked: () => false,
      );
      addTearDown(control.endTurn);
      await toFront(hwnd);
    });

    test('Esc between calls stops the turn and refuses what follows', () async {
      expect((await act('os_click', {'name': 'Save'}))['stopped'], isNull);
      await until(() => lines.contains('CLICKED'), 'the click');
      await Future<void>.delayed(const Duration(milliseconds: 200));
      key(VK_ESCAPE, up: false);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      key(VK_ESCAPE, up: true);
      await until(() => stops == 1, 'the stop');
      await expectLater(
        act('os_type', {'name': 'Notes', 'text': 'late'}),
        throwsA(isA<GaiaReadException>()),
      );
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(lines.last, isNot(contains('late')));
    }, timeout: const Timeout(Duration(minutes: 1)));

    test('Alt+Tab mid-text stops the turn, with nothing sent to the new '
        'window', () async {
      await act('os_click', {'name': 'Notes'});
      control.session('chat', auto: true, onUserStop: () => stops++);
      await control.plan('chat', 'long', 'os_type', {'text': 'y' * 190});
      final running = control.run('long', once: true, check: () async {});
      // Past the pace after the click (§5.6), so the stop lands mid-text.
      await until(
        () => lines.any((l) => l.startsWith('TEXT:') && l.contains('y')),
        'the typing',
      );
      // At the pace of a hand.
      key(VK_MENU, up: false);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      key(VK_TAB, up: false);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      key(VK_TAB, up: true);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      key(VK_MENU, up: true);
      final result = await running;
      await until(() => stops == 1, 'the stop');
      expect(result['stopped'], isNotNull);
      expect(GetForegroundWindow(), isNot(hwnd));
      await Future<void>.delayed(const Duration(milliseconds: 400));
      final typed = RegExp('y').allMatches(
        lines.lastWhere((l) => l.startsWith('TEXT:')),
      ).length;
      expect(typed, inExclusiveRange(0, 190));
      await expectLater(
        act('os_key', {'keys': 'A'}),
        throwsA(isA<GaiaReadException>()),
      );
      for (final vk in const [VK_CONTROL, VK_MENU, VK_SHIFT, VK_TAB]) {
        expect(GetAsyncKeyState(vk) & 0x8000, 0);
      }
    }, timeout: const Timeout(Duration(minutes: 1)));

    test('a click on another window mid-text stops the turn', () async {
      await act('os_click', {'name': 'Notes'});
      control.session('chat', auto: true, onUserStop: () => stops++);
      await control.plan('chat', 'long', 'os_type', {'text': 'y' * 190});
      final running = control.run('long', once: true, check: () async {});
      await Future<void>.delayed(const Duration(milliseconds: 60));
      final frame = gaiaWindowFrame(other);
      SetCursorPos(frame.left + frame.width ~/ 2, frame.top + 60);
      // Only ever on the probe's own window.
      final at = calloc<POINT>()
        ..ref.x = frame.left + frame.width ~/ 2
        ..ref.y = frame.top + 60;
      final under = GetAncestor(WindowFromPoint(at.ref), GA_ROOT);
      free(at);
      expect(under, other, reason: 'nothing to click safely');
      void mouse(int flags) {
        final input = calloc<INPUT>();
        input.ref.type = INPUT_MOUSE;
        input.ref.mi.dwFlags = flags;
        SendInput(1, input, sizeOf<INPUT>());
        free(input);
      }

      // A hand moves there first; SetCursorPos alone isn't input.
      for (var i = 0; i < 5; i++) {
        mouse(MOUSEEVENTF_MOVE);
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
      mouse(MOUSEEVENTF_LEFTDOWN);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      mouse(MOUSEEVENTF_LEFTUP);
      final result = await running;
      await until(() => stops == 1, 'the stop');
      expect(result['stopped'], isNotNull);
      expect(GetForegroundWindow(), other);
      await expectLater(
        act('os_key', {'keys': 'A'}),
        throwsA(isA<GaiaReadException>()),
      );
    }, timeout: const Timeout(Duration(minutes: 1)));

    test('a dialog its click opened is adopted, acted in, and handed back; its '
        "own Esc doesn't stop it", () async {
      final opened = await act('os_click', {'name': 'Open dialog'});
      expect(opened['stopped'], isNull);
      final dialog = FindWindow(nullptr, 'Gaia control dialog'.toNativeUtf16());
      await until(
        () =>
            FindWindow(nullptr, 'Gaia control dialog'.toNativeUtf16()) != 0,
        'the dialog',
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(stops, 0, reason: 'dialog was $dialog');
      final typed = await act('os_type', {
        'name': 'Dialog note',
        'text': 'in the dialog',
      });
      expect(typed['stopped'], isNull);
      expect(typed['adopted'], contains('Gaia control dialog'));
      expect((await act('os_click', {'name': 'Done'}))['stopped'], isNull);
      await until(
        () => lines.contains('DIALOG:in the dialog'),
        'the text in the dialog',
      );
      await until(() => lines.contains('DIALOG CLOSED'), 'the dialog closing');
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(stops, 0);
      expect((await act('os_click', {'name': 'Save'}))['stopped'], isNull);
      await until(() => lines.contains('CLICKED'), 'the click back in the main');
      expect((await act('os_key', {'keys': 'Esc'}))['stopped'], isNull);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(stops, 0);
    }, timeout: const Timeout(Duration(minutes: 1)));

    test('from behind a Gaia in another process, with no click', () async {
      // Gaia's stand-in: a process of its own, in front, that this one has never
      // been handed the foreground by.
      final gaia = await Process.start('powershell', [
        '-NoProfile',
        '-STA',
        '-Command',
        r'''
Add-Type -AssemblyName System.Windows.Forms
$f = New-Object Windows.Forms.Form
$f.Text = 'Gaia control standin'; $f.Width = 300; $f.Height = 200
$f.Add_Shown({ [Console]::Out.WriteLine('SHOWN'); [Console]::Out.Flush() })
[Windows.Forms.Application]::Run($f)
''',
      ]);
      addTearDown(gaia.kill);
      var shown = false;
      gaia.stdout.transform(utf8.decoder).listen((c) => shown = true);
      await until(() => shown, 'the stand-in');
      final standin = FindWindow(
        nullptr,
        'Gaia control standin'.toNativeUtf16(),
      );
      await toFront(hwnd);
      await toFront(standin);
      SetWindowPos(hwnd, standin, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
      final auto = GaiaOsControl(
        companionPid: () => gaia.pid,
        exclusions: () => const [],
        vaultUnlocked: () => false,
      );
      addTearDown(auto.endTurn);
      final pin = auto.session('chat', auto: true, onUserStop: () => stops++);
      expect(pin?.title, 'Gaia control probe');
      await auto.plan('chat', 'click', 'os_click', {'name': 'Save'});
      final result = await auto.run('click', once: true, check: () async {});
      expect(result['stopped'], isNull);
      expect(GetForegroundWindow(), hwnd);
      await until(() => lines.contains('CLICKED'), 'the click');
      expect(stops, 0);
      for (final vk in const [VK_CONTROL, VK_MENU, VK_SHIFT, VK_F24]) {
        expect(GetAsyncKeyState(vk) & 0x8000, 0);
      }
    }, timeout: const Timeout(Duration(minutes: 1)));
  });
}
