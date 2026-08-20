// A pinned reminder in the global inbox edits in place: clicking the row swaps
// its display Text for a TextField holding the same string. The two have to
// paint that string on exactly the same pixels, or the words jump out from
// under the click that opened them.
//
// InputDecorator and RenderEditable both inset a field's glyphs past its
// content padding — the M3 input gap on the left, the caret strip taken out of
// the width the text *wraps* at on the right — so a Text padded by the field's
// own content padding sits 4px left of it and wraps 3px late. These pin both.
//
// Both run at each of the two densities the app sees — `compact` on desktop,
// `standard` on mobile — because how far the decorator lifts its text above
// the content padding, and how much it takes off its own height, is a
// multiple of exactly that.

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

/// Long enough to wrap several times at [_kWrapWidth], so a wrap width that
/// differs between the two states shows up as a different line count.
const _longNote =
    'Water the plants on the balcony before the weekend, and check whether '
    'the basil needs repotting again this month or it can wait';

/// Window width at which this note's fourth line break falls inside the strip
/// RenderEditable keeps clear for the caret — the 3px window where the field
/// wraps one word earlier than a Text laid out at the same padding, and the
/// note grows a whole extra line on the way into the editor.
const double _kWrapWidth = 418;

Future<void> _pumpInbox(
  WidgetTester tester,
  String noteText,
  VisualDensity density,
) async {
  tester.view.physicalSize = const Size(_kWrapWidth, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final db = AppDatabase.inMemory();
  addTearDown(db.close);

  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      syncRepositoryProvider.overrideWithValue(InMemorySyncRepository()),
      // The popover's sections reach for the sync service, which builds the
      // real weather client and with it Firebase.
      weatherApiClientProvider.overrideWithValue(FakeWeatherApiClient()),
    ],
  );
  addTearDown(container.dispose);

  final now = utcNow();
  await container
      .read(notificationRepositoryProvider)
      .upsertPinnedNote(
        PinnedNote(id: newId(), text: noteText, createdAt: now, updatedAt: now),
      );

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: VoyagerTheme.dark().copyWith(visualDensity: density),
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

/// Top-left of the reminder's text while the row is showing it.
Offset _displayTextOrigin(WidgetTester tester, String noteText) =>
    tester.renderObject<RenderBox>(find.text(noteText)).localToGlobal(
      Offset.zero,
    );

/// Top-left of the same text once the row has become a field.
Offset _editTextOrigin(WidgetTester tester) => tester
    .renderObject<RenderBox>(find.byType(EditableText).last)
    .localToGlobal(Offset.zero);

Size _displayTextSize(WidgetTester tester, String noteText) =>
    tester.renderObject<RenderBox>(find.text(noteText)).size;

Size _editTextSize(WidgetTester tester) =>
    tester.renderObject<RenderBox>(find.byType(EditableText).last).size;

Future<void> _openEditor(WidgetTester tester, String noteText) async {
  await tester.tap(find.text(noteText));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
}

void main() {
  for (final density in const [VisualDensity.compact, VisualDensity.standard]) {
    final label = density == VisualDensity.compact ? 'compact' : 'standard';

    testWidgets('$label: a reminder stays put when the row is clicked', (
      tester,
    ) async {
      const note = 'Water the plants';
      await _pumpInbox(tester, note, density);

      final before = _displayTextOrigin(tester, note);
      await _openEditor(tester, note);

      expect(_editTextOrigin(tester), before);
    });

    testWidgets('$label: a reminder long enough to wrap keeps its lines', (
      tester,
    ) async {
      await _pumpInbox(tester, _longNote, density);

      final before = _displayTextOrigin(tester, _longNote);
      final beforeSize = _displayTextSize(tester, _longNote);
      // The window is narrow enough that this note really is wrapping.
      expect(beforeSize.height, greaterThan(30));

      await _openEditor(tester, _longNote);

      expect(_editTextOrigin(tester), before);
      expect(_editTextSize(tester).height, beforeSize.height);
    });
  }
}
