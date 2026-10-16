// A pinned reminder's hover highlight is the box the editor takes over on
// click — not the taller row the delete X sets — and every pixel that lights
// up has to open the editor, including the inset around the text itself.

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/domain/models/notification_models.dart';
import 'package:voyager/features/notifications/notification_inbox_popover.dart';

import 'fakes/fake_weather_api_client.dart';

const _note = 'Water the plants';

Future<void> _pumpInbox(
  WidgetTester tester, {
  List<String> notes = const [_note],
}) async {
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
  for (final text in notes) {
    await container
        .read(notificationRepositoryProvider)
        .upsertPinnedNote(
          PinnedNote(id: newId(), text: text, createdAt: now, updatedAt: now),
        );
  }

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

/// The box the hover highlight paints: the text's [AnimatedContainer].
final Finder _highlight = find
    .ancestor(of: find.text(_note), matching: find.byType(AnimatedContainer))
    .first;

void main() {
  testWidgets('the highlight is the size of the field it opens', (
    tester,
  ) async {
    await _pumpInbox(tester);

    final highlight = tester.getRect(_highlight);
    await tester.tap(find.text(_note));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    final field = tester.getRect(find.byType(TextField).last);
    expect(highlight.left, moreOrLessEquals(field.left, epsilon: 0.5));
    expect(highlight.right, moreOrLessEquals(field.right, epsilon: 0.5));
    expect(highlight.top, moreOrLessEquals(field.top, epsilon: 0.5));
    expect(highlight.bottom, moreOrLessEquals(field.bottom, epsilon: 0.5));
  });

  testWidgets('consecutive reminders\' highlights meet with no gap', (
    tester,
  ) async {
    await _pumpInbox(tester, notes: const [_note, 'Call the dentist']);

    Rect highlightOf(String text) => tester.getRect(
      find
          .ancestor(
            of: find.text(text),
            matching: find.byType(AnimatedContainer),
          )
          .first,
    );
    final rects = [highlightOf(_note), highlightOf('Call the dentist')]
      ..sort((a, b) => a.top.compareTo(b.top));
    expect(rects[1].top, moreOrLessEquals(rects[0].bottom, epsilon: 0.5));
  });

  testWidgets('the delete X still works in the shorter row', (tester) async {
    await _pumpInbox(tester);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.text(_note)));
    await tester.pump(const Duration(milliseconds: 200));

    final x = tester.getCenter(find.byIcon(PhosphorIconsRegular.x));
    await mouse.moveTo(x);
    await mouse.down(x);
    await mouse.up();
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 80));
    }

    expect(find.text(_note), findsNothing);
  });

  testWidgets(
    'a reminder opens from the top of its highlight, above the text',
    (tester) async {
      await _pumpInbox(tester);

      final row = tester.getRect(_highlight);
      final text = tester.getRect(find.text(_note));
      expect(text.top, greaterThan(row.top));

      await tester.tapAt(Offset(text.left, row.top + 1));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.byType(EditableText), findsNWidgets(2));
    },
  );

  testWidgets('and from the bottom of its highlight, below the text', (
    tester,
  ) async {
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
