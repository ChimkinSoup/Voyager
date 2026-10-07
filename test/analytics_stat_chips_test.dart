// The Analytics stat chips: "Dream Today" follows the Dream Logged tracker's
// rule (a blank, abandoned dream doesn't count), and at the minimum window
// size every chip shows its whole value.

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/domain/models/dream_models.dart';
import 'package:voyager/features/analytics/analytics_page.dart';

import 'fakes/fake_weather_api_client.dart';

DreamEntry _dream(String id, {required String title, required String body}) {
  final now = DateTime.now();
  return DreamEntry(
    id: id,
    createdAt: now.toUtc(),
    updatedAt: now.toUtc(),
    version: 1,
    title: title,
    body: body,
    entryDate: DateTime(now.year, now.month, now.day, 7).toUtc(),
  );
}

Future<void> _pumpAnalytics(
  WidgetTester tester, {
  required List<DreamEntry> dreams,
  double width = 1400,
}) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final db = AppDatabase.inMemory();
  addTearDown(db.close);
  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      syncRepositoryProvider.overrideWithValue(InMemorySyncRepository()),
      weatherApiClientProvider.overrideWithValue(FakeWeatherApiClient()),
      journalsProvider.overrideWith((ref) async => []),
      todoListStatsProvider.overrideWith(
        (ref) async => {'list': (active: 2, completed: 0)},
      ),
      allDreamEntriesProvider.overrideWith((ref) async => dreams),
    ],
  );
  addTearDown(container.dispose);
  final settings = await container.read(settingsProvider.future);
  await container
      .read(settingsProvider.notifier)
      .saveSettings(settings.copyWith(showDreamStatistics: true));
  await container.read(allJournalEntriesProvider.future);
  await container.read(trackersProvider.future);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: VoyagerTheme.dark(),
        home: const Scaffold(body: AnalyticsPage()),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

String _dreamToday(WidgetTester tester) {
  final chip = find
      .ancestor(of: find.text('Dream Today'), matching: find.byType(Column))
      .first;
  final texts = tester
      .widgetList<Text>(find.descendant(of: chip, matching: find.byType(Text)))
      .map((t) => t.data)
      .toList();
  return texts.last!;
}

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  testWidgets(
    'a blank dream today is not a dream logged today',
    semanticsEnabled: false,
    (tester) async {
      await _pumpAnalytics(
        tester,
        dreams: [_dream('blank', title: '', body: '  ')],
      );
      expect(_dreamToday(tester), 'No');
    },
  );

  testWidgets(
    'a real dream today is a dream logged today',
    semanticsEnabled: false,
    (tester) async {
      await _pumpAnalytics(
        tester,
        dreams: [_dream('real', title: 'Flying', body: '')],
      );
      expect(_dreamToday(tester), 'Yes');
    },
  );

  testWidgets(
    'at the minimum window width the chips show whole values',
    semanticsEnabled: false,
    (tester) async {
      await _pumpAnalytics(tester, dreams: const [], width: 720);
      for (final value in ['0 days', '2 open']) {
        final paragraph = tester.renderObject<RenderParagraph>(
          find.text(value),
        );
        expect(paragraph.didExceedMaxLines, isFalse, reason: value);
      }
    },
  );
}
