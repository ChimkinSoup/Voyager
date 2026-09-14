// The Jobs toolbar's search field sits in a fixed 38px slot beside the Clear
// button. On desktop's compact density the field's border is shorter than
// that slot, and a TextField handed more height than it asked for pins its
// border to the top — so the buttons hung below it. The app theme carries the
// compact density, which the test binding would otherwise leave at standard.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/features/jobs/jobs_page.dart';

import 'fakes/fake_weather_api_client.dart';

/// Top and bottom of the outline the decorator actually strokes: its border
/// painter is laid out at the drawn height, not at the field's full slot.
({double top, double bottom}) _borderEdges(WidgetTester tester, Finder field) {
  final painter = tester.renderObject<RenderBox>(
    find.descendant(of: field, matching: find.byType(CustomPaint)).first,
  );
  final rect = painter.localToGlobal(Offset.zero) & painter.size;
  return (top: rect.top, bottom: rect.bottom);
}

void main() {
  testWidgets('the search field matches the Clear button', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final db = AppDatabase.inMemory();
    addTearDown(db.close);
    await DriftJobRepository(db).ensureSeeded();
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        syncRepositoryProvider.overrideWithValue(InMemorySyncRepository()),
        weatherApiClientProvider.overrideWithValue(FakeWeatherApiClient()),
      ],
    );
    addTearDown(container.dispose);
    await container.read(settingsProvider.future);
    await container.read(jobApplicationsProvider.future);
    await container.read(jobStagesProvider.future);
    await container.read(jobCompaniesProvider.future);
    await container.read(jobCategoriesProvider.future);
    await container.read(jobSeasonsProvider.future);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(theme: VoyagerTheme.dark(), home: const JobsPage()),
      ),
    );
    await tester.pumpAndSettle();

    final field = find.widgetWithText(
      TextField,
      'Search company, title, notes or status',
    );
    // A query is what brings the Clear button in.
    await tester.enterText(field, 'x');
    await tester.pumpAndSettle();

    final clear = tester.getRect(find.widgetWithText(GlassButton, 'Clear'));
    final border = _borderEdges(tester, field);
    expect((border.top + border.bottom) / 2, moreOrLessEquals(clear.center.dy));
    expect(border.bottom - border.top, moreOrLessEquals(clear.height));
  });
}
