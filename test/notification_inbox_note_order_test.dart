// The inbox's Reminders and Secure Notes: in the user's own order, dragged by
// a held press on a note, saved in settings and synced with them.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/sync/firestore_document_mapper.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/domain/models/notification_models.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/features/notifications/notification_inbox_popover.dart';
import 'package:voyager/features/notifications/secure_vault_session.dart';

import 'fakes/fake_weather_api_client.dart';

const _names = ['alpha', 'bravo', 'charlie'];

Future<ProviderContainer> _container(
  WidgetTester tester, {
  List<String> notes = _names,
  List<String> order = const [],
}) async {
  tester.view.physicalSize = const Size(380, 1200);
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
  final now = utcNow();
  for (var i = 0; i < notes.length; i++) {
    await container
        .read(notificationRepositoryProvider)
        .upsertPinnedNote(
          PinnedNote(
            id: notes[i],
            text: notes[i],
            // Distinct, so the fallback order is fixed.
            createdAt: now.add(Duration(seconds: i)),
            updatedAt: now,
          ),
        );
  }
  await container.read(settingsProvider.future);
  if (order.isNotEmpty) {
    await container
        .read(settingsProvider.notifier)
        .saveInboxNoteOrder(order, secure: false);
  }
  return container;
}

Future<void> _show(WidgetTester tester, ProviderContainer container) async {
  await container.read(pinnedNotesProvider.future);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: VoyagerTheme.dark(),
        home: const Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(width: 380, child: NotificationInboxPopover()),
          ),
        ),
      ),
    ),
  );
  await _settle(tester);
}

/// Not pumpAndSettle: the popover keeps animations ticking.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 80));
  }
}

/// Which of [names] are shown, top to bottom.
List<String> _shown(WidgetTester tester, [List<String> names = _names]) {
  return names.where((n) => find.text(n).evaluate().isNotEmpty).toList()..sort(
    (a, b) => tester
        .getCenter(find.text(a))
        .dy
        .compareTo(tester.getCenter(find.text(b)).dy),
  );
}

/// Holds [name] past the drag delay, then drags it to [dy] past the centre
/// of [target].
Future<void> _drag(
  WidgetTester tester,
  String name,
  String target, {
  required double dy,
}) async {
  final from = tester.getCenter(find.text(name));
  final to = tester.getCenter(find.text(target)) + Offset(0, dy);
  final gesture = await tester.startGesture(from);
  await tester.pump(const Duration(milliseconds: 300));
  for (var i = 1; i <= 10; i++) {
    await gesture.moveTo(Offset.lerp(from, to, i / 10)!);
    await tester.pump(const Duration(milliseconds: 16));
  }
  await gesture.up();
  await _settle(tester);
}

Future<AppSettings> _stored(ProviderContainer container) =>
    container.read(settingsRepositoryProvider).getSettings();

void main() {
  // The list keys each row by its index too, so without a key carrying it
  // across, a drop rebuilt every row it moved from scratch.
  testWidgets("a drop keeps every row's state", (tester) async {
    final container = await _container(tester);
    await _show(tester, container);
    State row(String name) => tester.state(
      find.ancestor(
        of: find.text(name),
        matching: find.byWidgetPredicate(
          (w) => w.runtimeType.toString() == '_PinnedNoteRow',
        ),
      ),
    );
    final before = {for (final n in _names) n: row(n)};

    await _drag(tester, 'alpha', 'charlie', dy: 12);

    expect(_shown(tester), ['bravo', 'charlie', 'alpha']);
    for (final n in _names) {
      expect(identical(row(n), before[n]), isTrue, reason: n);
    }
  });
  testWidgets('lists reminders by their saved position', (tester) async {
    final container = await _container(
      tester,
      order: ['bravo', 'charlie', 'alpha'],
    );
    await _show(tester, container);
    expect(_shown(tester), ['bravo', 'charlie', 'alpha']);
  });

  testWidgets('a reminder the saved order doesn\'t name goes last', (
    tester,
  ) async {
    final container = await _container(tester, order: ['charlie', 'alpha']);
    await _show(tester, container);
    expect(_shown(tester), ['charlie', 'alpha', 'bravo']);
  });

  testWidgets('a held drag moves a reminder and saves the order', (
    tester,
  ) async {
    final container = await _container(tester);
    final repo = container.read(notificationRepositoryProvider);
    Future<Map<String, int>> versions() async => {
      for (final n in await repo.listPinnedNotes()) n.id: n.version,
    };
    final before = await versions();
    await _show(tester, container);
    var publishes = 0;
    final sub = container.listen(settingsProvider, (_, _) => publishes++);
    addTearDown(sub.close);

    await _drag(tester, 'alpha', 'charlie', dy: 12);

    expect(_shown(tester), ['bravo', 'charlie', 'alpha']);
    expect((await _stored(container)).inboxPinnedNoteOrder, [
      'bravo',
      'charlie',
      'alpha',
    ]);
    // The notes themselves aren't rewritten — no version for a conflict to
    // trip over — and nothing else rebuilds for the drop.
    expect(await versions(), before);
    expect(publishes, 0);
    // A drag doesn't open the editor.
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('a click still edits a reminder', (tester) async {
    final container = await _container(tester);
    await _show(tester, container);
    await tester.tap(find.text('bravo'));
    await _settle(tester);
    expect(find.byType(TextField), findsNWidgets(2));
    expect((await _stored(container)).inboxPinnedNoteOrder, isEmpty);
  });

  testWidgets('an order pulled from another device shows at once', (
    tester,
  ) async {
    final container = await _container(tester);
    await _show(tester, container);
    expect(_shown(tester), _names);

    // What a pull does: write the merged row, then reload the settings.
    final repo = container.read(settingsRepositoryProvider);
    final stored = await repo.getSettings();
    await repo.saveSettings(
      stored.copyWith(inboxPinnedNoteOrder: const ['charlie', 'alpha']),
      recordLocalActivity: false,
    );
    container.invalidate(settingsProvider);
    await _settle(tester);

    expect(_shown(tester), ['charlie', 'alpha', 'bravo']);
  });

  testWidgets('secure notes are dragged into an order of their own', (
    tester,
  ) async {
    final container = await _container(tester, notes: const []);
    await _show(tester, container);
    final service = container.read(secureVaultServiceProvider);
    await tester.runAsync(() async {
      final key = await service.create('correct horse');
      final header = await service.localHeader();
      container
          .read(secureVaultSessionProvider.notifier)
          .unlock(key, header!.vaultId);
    });
    await _settle(tester);
    final input = find.byWidgetPredicate(
      (widget) =>
          widget is TextField &&
          widget.decoration?.hintText == 'Type a secure note…',
    );
    for (final name in _names) {
      await tester.enterText(input, name);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await _settle(tester);
      await tester.runAsync(
        () => container.read(secureNoteTextsProvider.future),
      );
      await _settle(tester);
    }
    expect(_shown(tester), _names);
    final ids = [
      for (final note in (await tester.runAsync(
        () => container.read(notificationRepositoryProvider).listSecureNotes(),
      ))!)
        note.id,
    ];

    await _drag(tester, 'charlie', 'alpha', dy: -12);

    expect(_shown(tester), ['charlie', 'alpha', 'bravo']);
    final stored = await _stored(container);
    expect(stored.inboxSecureNoteOrder, [ids[2], ids[0], ids[1]]);
    expect(stored.inboxPinnedNoteOrder, isEmpty);
  });

  test('both note orders sync with settings', () {
    final remote = settingsToFirestore(
      AppSettings(
        inboxPinnedNoteOrder: const ['b', 'a'],
        inboxSecureNoteOrder: const ['d', 'c'],
        updatedAt: utcNow(),
      ),
    );
    final merged = mergeSettingsFromRemote(remote, const AppSettings());
    expect(merged.inboxPinnedNoteOrder, ['b', 'a']);
    expect(merged.inboxSecureNoteOrder, ['d', 'c']);
  });
}
