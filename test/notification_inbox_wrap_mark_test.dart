// A pinned reminder can hold its own line breaks, and it also wraps when it
// runs out of room — and the two used to look identical. Flutter has no
// text-indent and a TextField's wrapped line can only be moved by putting a
// real newline in the note, so the distinction is painted instead: an elbow in
// the gutter beside every line the text spilled onto by itself.
//
// These read the pixels back, because a painter is the one thing the widget
// tree cannot be asked about: that the mark is there for a wrap, absent for a
// line the user broke, and on the same rows once the row becomes an editor.

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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

/// Wide enough for the popover, narrow enough that [_wrapped] runs out of room.
const double _kWindowWidth = 360;

const _wrapped = 'one two three four five six seven eight nine ten eleven';
const _broken = 'one two three\nfour five six';

final _boundary = GlobalKey();

Future<void> _pumpInbox(WidgetTester tester, String noteText) async {
  tester.view.physicalSize = const Size(_kWindowWidth, 1200);
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
        theme: VoyagerTheme.dark(),
        home: Scaffold(
          body: RepaintBoundary(
            key: _boundary,
            child: const NotificationInboxPopover(),
          ),
        ),
      ),
    ),
  );
  // Not pumpAndSettle: the popover keeps hover/opacity animations ticking
  // while the providers resolve.
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 80));
  }
}

/// The rows of the gutter strip — the 4px column the elbow is drawn in — that
/// hold something other than the row's own background.
///
/// Reading the y of each is what makes this a position test as well as a
/// presence one: the marks have to stay on the same lines when the row turns
/// into a field.
Future<Set<int>> _markedRows(WidgetTester tester, Rect textRect) async {
  final boundary =
      _boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  late final ui.Image image;
  late final ByteData bytes;
  await tester.runAsync(() async {
    image = await boundary.toImage();
    bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  });
  final rgba = bytes.buffer.asUint32List();

  // The strip sits between the row's left edge and the glyphs; the text's own
  // left tells us where the row starts without reaching into the widget.
  final left = (textRect.left - 9).round();
  final right = (textRect.left - 3).round();
  // Clear of the rounded corners the field's border draws while editing.
  final top = (textRect.top + 2).round();
  final bottom = (textRect.bottom - 2).round();

  final background = <int, int>{};
  for (var y = top; y < bottom; y++) {
    for (var x = left; x < right; x++) {
      final pixel = rgba[y * image.width + x];
      background[pixel] = (background[pixel] ?? 0) + 1;
    }
  }
  final commonest = background.entries
      .reduce((a, b) => a.value >= b.value ? a : b)
      .key;

  final marked = <int>{};
  for (var y = top; y < bottom; y++) {
    for (var x = left; x < right; x++) {
      if (rgba[y * image.width + x] != commonest) marked.add(y - top);
    }
  }
  image.dispose();
  return marked;
}

void main() {
  testWidgets('a line the text wrapped onto is marked in the gutter', (
    tester,
  ) async {
    await _pumpInbox(tester, _wrapped);

    final rect = tester.getRect(find.text(_wrapped));
    expect(rect.height, greaterThan(20), reason: 'the note has to be wrapping');
    expect(await _markedRows(tester, rect), isNotEmpty);
  });

  testWidgets('a line the user broke themselves is not', (tester) async {
    await _pumpInbox(tester, _broken);

    final rect = tester.getRect(find.text(_broken));
    expect(rect.height, greaterThan(20), reason: 'the note has to be two lines');
    expect(await _markedRows(tester, rect), isEmpty);
  });

  testWidgets('the marks do not move when the row becomes an editor', (
    tester,
  ) async {
    await _pumpInbox(tester, _wrapped);

    final rect = tester.getRect(find.text(_wrapped));
    final before = await _markedRows(tester, rect);
    expect(before, isNotEmpty, reason: 'nothing to compare otherwise');

    await tester.tap(find.text(_wrapped));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(await _markedRows(tester, rect), before);
  });
}
