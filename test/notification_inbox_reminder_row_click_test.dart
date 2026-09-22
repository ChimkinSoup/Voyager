// A pinned reminder's row is highlighted as a whole on hover, so every pixel
// that lights up has to open the editor. The text is shorter than the row —
// the delete X sets its height — and the row's own padding sits outside that
// again, so a click target around the text alone left strips along the top and
// bottom that highlighted but swallowed the click.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/domain/models/notification_models.dart';
import 'package:voyager/features/notifications/notification_inbox_popover.dart';

import 'fakes/fake_weather_api_client.dart';

const _note = 'Water the plants';

Future<void> _pumpInbox(WidgetTester tester) async {
  tester.view.physicalSize = const Size(420, 1600);
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
  await container
      .read(notificationRepositoryProvider)
      .upsertPinnedNote(
        PinnedNote(id: newId(), text: _note, createdAt: now, updatedAt: now),
      );

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: VoyagerTheme.dark().copyWith(
          visualDensity: VisualDensity.compact,
        ),
        home: const Scaffold(body: NotificationInboxPopover()),
      ),
    ),
  );
  // Not pumpAndSettle: the popover keeps hover/opacity animations ticking
  // while the providers resolve.
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 80));
  }
}

/// The box the hover highlight paints: the row's [AnimatedContainer].
final Finder _highlight = find
    .ancestor(of: find.text(_note), matching: find.byType(AnimatedContainer))
    .first;

void main() {
  testWidgets('a reminder opens from the top of its row, above the text', (
    tester,
  ) async {
    await _pumpInbox(tester);

    final row = tester.getRect(_highlight);
    final text = tester.getRect(find.text(_note));
    // The strip this test is for only exists while the row is taller than the
    // text in it.
    expect(text.top, greaterThan(row.top));

    await tester.tapAt(Offset(text.left, row.top + 1));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.byType(EditableText), findsNWidgets(2));
  });

  testWidgets('and from the bottom of its row, below the text', (tester) async {
    await _pumpInbox(tester);

    final row = tester.getRect(_highlight);
    final text = tester.getRect(find.text(_note));
    expect(text.bottom, lessThan(row.bottom));

    await tester.tapAt(Offset(text.left, row.bottom - 1));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.byType(EditableText), findsNWidgets(2));
  });
}
