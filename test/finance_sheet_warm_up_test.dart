// The warm-up paints the real transaction sheet into an offscreen snapshot at
// startup. It must build the whole form without errors, leave nothing mounted,
// and never take focus — its amount field autofocuses, and a focused field
// would take the platform's text input from the app.

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/features/finance/finance_sheet_warm_up.dart';

import 'fakes/fake_weather_api_client.dart';

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  testWidgets('warms up the sheet offscreen without taking focus', (
    tester,
  ) async {
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
    // Loaded long before the warm-up runs in the app.
    await container.read(settingsProvider.future);
    await container.read(transactionsProvider.future);

    final appField = FocusNode();
    addTearDown(appField.dispose);
    late BuildContext appContext;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: VoyagerTheme.dark(),
          home: Builder(
            builder: (context) {
              appContext = context;
              return Scaffold(
                body: TextField(focusNode: appField, autofocus: true),
              );
            },
          ),
        ),
      ),
    );
    await tester.pump();
    expect(appField.hasFocus, isTrue);

    await tester.runAsync(() => warmUpFinanceSheet(appContext));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(appField.hasFocus, isTrue);
    expect(tester.testTextInput.isVisible, isTrue);
    expect(find.text('New transaction'), findsNothing);
  });

  // The app draws frames while the snapshot is awaited. An autofocusing field
  // schedules a post-frame lookup of its own GlobalKey, which resolves through
  // the app's BuildOwner — not the warm-up's — and threw there.
  testWidgets('survives an app frame while the snapshot is pending', (
    tester,
  ) async {
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
    await container.read(settingsProvider.future);
    await container.read(transactionsProvider.future);

    late BuildContext appContext;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: VoyagerTheme.dark(),
          home: Builder(
            builder: (context) {
              appContext = context;
              return const Scaffold();
            },
          ),
        ),
      ),
    );

    // Not awaited: it builds the sheet synchronously, then parks on the
    // snapshot. In the app that rasterizes on the GPU for a while and frames
    // go by; here it can resolve at once, and [WidgetTester.pump] flushes
    // microtasks before drawing — so draw the frame directly.
    final warmUp = warmUpFinanceSheet(appContext);
    tester.binding
      ..handleBeginFrame(Duration.zero)
      ..handleDrawFrame();
    expect(tester.takeException(), isNull);

    await tester.runAsync(() => warmUp);
  });
}
