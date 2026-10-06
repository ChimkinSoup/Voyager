// BUG-077: the hour lines and labels are drawn above the Week view's event
// blocks, but a light label on a light block couldn't be read: only the half of
// "7 AM" above the block showed. Each label now gets an outline in the page
// background colour, which only shows where the label crosses a fill.

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/features/calendar/calendar_week_timeline.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'an hour label over an event block is outlined in the halo colour',
    () async {
      const size = Size(200, 200);
      const fill = Color(0xFF7C9EFF);
      const label = Color(0xFFC8CCD8);
      const halo = Color(0xFF000000);

      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawRect(Offset.zero & size, Paint()..color = fill);
      CalendarWeekTimeGridPainter(
        scrollOffset: 0,
        allDayShelfHeight: 0,
        borderedClipRects: const [Rect.fromLTWH(0, 0, 200, 200)],
        borderRadius: 0,
        lineColor: Colors.white,
        labelColor: label,
        labelHaloColor: halo,
        hourLabelBuilder: calendarWeekHourLabel,
        timelineScrollPadding: 100,
      ).paint(canvas, size);
      final image = await recorder.endRecording().toImage(200, 200);
      final bytes = (await image.toByteData())!;

      // The 12 AM label sits on y = 100, from x = 22.
      var haloPixels = 0;
      for (var y = 92; y <= 108; y++) {
        for (var x = 18; x <= 80; x++) {
          final i = (y * 200 + x) * 4;
          final r = bytes.getUint8(i), g = bytes.getUint8(i + 1);
          final b = bytes.getUint8(i + 2);
          if (r < 40 && g < 40 && b < 60) haloPixels++;
        }
      }
      expect(haloPixels, greaterThan(20));
    },
  );

  // The outline is the tone the page actually shows, not the scaffold colour
  // under the dark texture, which read as a black rim around the label.
  testWidgets('the outline matches the page background in both themes', (
    tester,
  ) async {
    Future<Color> toneFor(ThemeData theme) async {
      late Color tone;
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Builder(
            builder: (context) {
              tone = calendarWeekPageBackground(context);
              return const SizedBox();
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      return tone;
    }

    const accent = Color(0xFF7C9EFF);
    final dark = VoyagerTheme.dark(accent: accent);
    expect(
      await toneFor(dark),
      Color.lerp(dark.scaffoldBackgroundColor, accent, 0.08),
    );
    final light = VoyagerTheme.light(accent: accent);
    expect(await toneFor(light), light.scaffoldBackgroundColor);
  });
}
