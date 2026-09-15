// Shared by the narrow-window overflow sweeps — see
// narrow_window_overflow_test.dart and narrow_window_modal_overflow_test.dart.
//
// Laid out in the real Iosevka faces and at desktop density: the 1em test
// font is far wider than Iosevka and would flag rows that fit in the app,
// and Android density (the test default) is taller than what Windows gets.
// Run each test under TargetPlatformVariant.only(TargetPlatform.windows).
//
// An empty database hides the overflows that only long names cause. To sweep
// real data, point the tests at a *copy* of voyager.sqlite (they write), one
// file at a time so two don't share the database:
//   flutter test test/narrow_window_overflow_test.dart \
//     --concurrency=1 --dart-define=OVERFLOW_AUDIT_DB=C:/path/to/copy.sqlite

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/firebase_auth_repository.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';

import 'fakes/fake_weather_api_client.dart';

const _auditDbPath = String.fromEnvironment('OVERFLOW_AUDIT_DB');

/// The smallest window desktop_window.dart allows.
const minWindowSize = Size(720, 520);

Future<void> loadRealFonts(WidgetTester tester) async {
  await tester.runAsync(() async {
    Future<void> load(String family, List<String> paths) async {
      final loader = FontLoader(family);
      for (final path in paths) {
        final bytes = File(path).readAsBytesSync();
        loader.addFont(Future.value(ByteData.view(bytes.buffer)));
      }
      await loader.load();
    }

    await load('IosevkaAile', const [
      'assets/Iosevka-Thin/Iosevka-Aile-Light-01.ttf',
      'assets/Iosevka-Regular/Iosevka-Aile-01.ttf',
      'assets/Iosevka-Bold/Iosevka-Aile-Bold-01.ttf',
    ]);
    await load('IosevkaMono', const [
      'assets/Iosevka-Regular/Iosevka-Term-01.ttf',
    ]);
  });
}

/// A database for one pump: in memory, or the audit copy when one is given,
/// with [seed] written into it first. The dev-only row of instant view
/// switches is turned on, because it widens the calendar toolbar.
Future<(AppDatabase, ProviderContainer)> openHarnessContainer({
  Future<void> Function(AppDatabase db)? seed,
}) async {
  final db = _auditDbPath.isEmpty
      ? AppDatabase.inMemory()
      : AppDatabase(NativeDatabase(File(_auditDbPath)));
  await seed?.call(db);
  final settingsRepo = DriftSettingsRepository(db);
  await settingsRepo.saveSettings(
    (await settingsRepo.getSettings()).copyWith(
      devShowCalendarInstantViewSwitch: true,
    ),
  );
  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      authRepositoryProvider.overrideWithValue(InMemoryAuthRepository()),
      syncRepositoryProvider.overrideWithValue(InMemorySyncRepository()),
      weatherApiClientProvider.overrideWithValue(FakeWeatherApiClient()),
    ],
  );
  await container.read(settingsProvider.future);
  return (db, container);
}

/// Runs [body] with every RenderFlex overflow it causes collected (with the
/// widget's source line) instead of reported; other errors still surface.
Future<Set<String>> collectOverflows(Future<void> Function() body) async {
  final overflows = <String>{};
  final previousOnError = FlutterError.onError;
  FlutterError.onError = (details) {
    final message = details.exceptionAsString();
    if (message.contains('overflowed')) {
      final source = RegExp(
        r'lib/[\w/]+\.dart:\d+',
      ).firstMatch(details.toString())?.group(0);
      overflows.add('${message.split('\n').first} ($source)');
    } else {
      previousOnError?.call(details);
    }
  };
  try {
    await body();
  } finally {
    FlutterError.onError = previousOnError;
  }
  return overflows;
}

/// Not pumpAndSettle: pages run continuous animations.
Future<void> settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pump(const Duration(milliseconds: 500));
}

/// Presses every [SegmentedButton] segment on screen, one after another, so
/// the views behind them are laid out too.
Future<void> visitSegments(WidgetTester tester) async {
  final segments = find.descendant(
    of: find.byWidgetPredicate((widget) => widget is SegmentedButton),
    matching: find.byType(TextButton),
  );
  for (var i = 0; i < segments.evaluate().length; i++) {
    await tester.tap(segments.at(i), warnIfMissed: false);
    await settle(tester);
  }
}
