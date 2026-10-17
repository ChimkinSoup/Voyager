// Secure Notes in the inbox popover (SECURE_NOTES_HLD.md, Phases 4 and 5):
// the hidden way in, what locks the vault, and the clipboard clear.

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/secure_vault/secure_clipboard.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/core/vim/vim_session.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/features/notifications/notification_inbox_popover.dart';
import 'package:voyager/features/notifications/secure_vault_session.dart';

import 'fakes/fake_weather_api_client.dart';

const _password = 'correct horse';

Future<ProviderContainer> _pumpInbox(WidgetTester tester) async {
  tester.view.physicalSize = const Size(600, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final db = AppDatabase.inMemory();
  addTearDown(db.close);
  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      syncRepositoryProvider.overrideWithValue(InMemorySyncRepository()),
      weatherApiClientProvider.overrideWithValue(FakeWeatherApiClient()),
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: VoyagerTheme.dark(),
        home: const Scaffold(body: NotificationInboxPopover()),
      ),
    ),
  );
  await _settle(tester);
  return container;
}

/// Not pumpAndSettle: the popover keeps animations ticking.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 80));
  }
}

/// Creates the vault (real key derivation, off the fake clock) and unlocks
/// it, as the setup dialog would.
Future<void> _unlock(WidgetTester tester, ProviderContainer container) async {
  final service = container.read(secureVaultServiceProvider);
  await tester.runAsync(() async {
    final key = await service.create(_password);
    final header = await service.localHeader();
    container
        .read(secureVaultSessionProvider.notifier)
        .unlock(key, header!.vaultId);
  });
  container.invalidate(secureVaultHeaderProvider);
  await _settle(tester);
}

Future<void> _hold(WidgetTester tester, Duration duration) async {
  final gesture = await tester.startGesture(
    tester.getCenter(find.text('Inbox')),
  );
  await tester.pump(duration);
  await gesture.up();
  await _settle(tester);
}

void main() {
  testWidgets('holding the Inbox title opens the vault prompt', (tester) async {
    await _pumpInbox(tester);

    await _hold(tester, const Duration(milliseconds: 1000));
    expect(find.text('Create secure vault'), findsNothing);

    await _hold(tester, const Duration(milliseconds: 1600));
    expect(find.text('Create secure vault'), findsOneWidget);
  });

  testWidgets('with a vault, the hold asks to unlock — and again, locks', (
    tester,
  ) async {
    final container = await _pumpInbox(tester);
    await _unlock(tester, container);
    expect(find.text('Secure notes'), findsOneWidget);

    await _hold(tester, const Duration(milliseconds: 1600));
    expect(container.read(secureVaultSessionProvider), isNull);
    expect(find.text('Secure notes'), findsNothing);

    await _hold(tester, const Duration(milliseconds: 1600));
    expect(find.text('Unlock'), findsWidgets);
  });

  testWidgets('the unlock prompt tells of notes a reset elsewhere dropped', (
    tester,
  ) async {
    final container = await _pumpInbox(tester);
    await _unlock(tester, container);
    await _hold(tester, const Duration(milliseconds: 1600));
    await tester.runAsync(
      () => container
          .read(notificationRepositoryProvider)
          .setLostSecureNoteCount(2),
    );

    await _hold(tester, const Duration(milliseconds: 1600));
    expect(
      find.text(
        "The vault was reset on another device, so 2 notes made on this "
        "device weren't kept.",
      ),
      findsOneWidget,
    );
  });

  testWidgets('the Inbox title gives nothing away', (tester) async {
    final semantics = tester.ensureSemantics();
    await _pumpInbox(tester);

    final data = tester.getSemantics(find.text('Inbox')).getSemanticsData();
    expect(data.hasAction(SemanticsAction.longPress), isFalse);

    final mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
      pointer: 1,
    );
    await mouse.addPointer(location: tester.getCenter(find.text('Inbox')));
    await tester.pump();
    expect(
      RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1),
      SystemMouseCursors.basic,
    );
    await mouse.removePointer();
    semantics.dispose();
  });

  testWidgets('unlocked notes are shown, and sealed on disk', (tester) async {
    final container = await _pumpInbox(tester);
    await _unlock(tester, container);

    final input = find.byWidgetPredicate(
      (widget) =>
          widget is TextField &&
          widget.decoration?.hintText == 'Type a secure note…',
    );
    await tester.enterText(input, 'the pin is 4821');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await _settle(tester);
    await tester.runAsync(() async {
      await container.read(secureNoteTextsProvider.future);
    });
    await _settle(tester);

    expect(find.text('the pin is 4821'), findsOneWidget);
    final stored = await tester.runAsync(
      () => container.read(notificationRepositoryProvider).listSecureNotes(),
    );
    expect(stored, hasLength(1));
    expect(stored!.single.ciphertext, isNot(contains('4821')));
  });

  testWidgets('closing the inbox locks the vault and empties Vim registers', (
    tester,
  ) async {
    final container = await _pumpInbox(tester);
    await _unlock(tester, container);
    VimRegister.write('the pin is 4821', asLines: true);
    VimSearchMemory.pattern = '4821';

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: SizedBox()),
      ),
    );
    await tester.pump();

    expect(container.read(secureVaultSessionProvider), isNull);
    expect(VimRegister.text, isEmpty);
    expect(VimRegister.linewise, isFalse);
    expect(VimSearchMemory.pattern, isEmpty);
  });

  testWidgets('five idle minutes lock the vault; activity holds it off', (
    tester,
  ) async {
    final container = await _pumpInbox(tester);
    await _unlock(tester, container);

    await tester.pump(const Duration(minutes: 4));
    await tester.sendKeyEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump(const Duration(minutes: 4));
    expect(container.read(secureVaultSessionProvider), isNotNull);

    await tester.pump(const Duration(minutes: 1, seconds: 1));
    expect(container.read(secureVaultSessionProvider), isNull);
  });

  group('clipboard', () {
    late String? clipboard;

    setUp(() {
      SecureClipboard.useWin32 = false;
      clipboard = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            switch (call.method) {
              case 'Clipboard.setData':
                clipboard = (call.arguments as Map)['text'] as String?;
                return null;
              case 'Clipboard.getData':
                return clipboard == null ? null : {'text': clipboard};
            }
            return null;
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    testWidgets('a copied note is cleared after 30 seconds', (tester) async {
      await SecureClipboard.copy('the pin is 4821');
      expect(clipboard, 'the pin is 4821');

      await tester.pump(const Duration(seconds: 29));
      expect(clipboard, 'the pin is 4821');
      await tester.pump(const Duration(seconds: 2));
      expect(clipboard, isEmpty);
    });

    testWidgets('something copied since is left alone', (tester) async {
      await SecureClipboard.copy('the pin is 4821');
      await Clipboard.setData(const ClipboardData(text: 'shopping list'));

      await tester.pump(const Duration(seconds: 31));
      expect(clipboard, 'shopping list');
    });

    group('on Android', () {
      const channel = MethodChannel('voyager/secure_clipboard');
      late List<MethodCall> calls;

      setUp(() {
        SecureClipboard.useAndroid = true;
        calls = [];
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              calls.add(call);
              if (call.method == 'copy') clipboard = call.arguments as String;
              return null;
            });
      });

      tearDown(() {
        SecureClipboard.useAndroid = false;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });

      testWidgets('copies through the sensitive channel', (tester) async {
        await SecureClipboard.copy('the pin is 4821');
        expect(calls.single.method, 'copy');
        expect(clipboard, 'the pin is 4821');

        await tester.pump(const Duration(seconds: 31));
        expect(calls.last.method, 'clear');
      });

      testWidgets("clears when the clipboard can't be read", (tester) async {
        await SecureClipboard.copy('the pin is 4821');
        clipboard = null; // What a backgrounded app reads.

        await tester.pump(const Duration(seconds: 31));
        expect(calls.last.method, 'clear');
      });

      testWidgets('leaves something copied since alone', (tester) async {
        await SecureClipboard.copy('the pin is 4821');
        clipboard = 'shopping list';

        await tester.pump(const Duration(seconds: 31));
        expect(calls.map((call) => call.method), ['copy']);
      });
    });
  });
}
