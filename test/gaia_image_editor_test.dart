import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/features/gaia/companion/gaia_image_editor.dart';
import 'package:voyager/features/gaia/companion/gaia_image_render.dart';

/// The annotation editor (GAIA_HLD.md §9.4).
void main() {
  /// Opens the editor on a 1x1 PNG; the future completes with what it
  /// returns.
  Future<Future<GaiaImageEdits?>> open(WidgetTester tester) async {
    final dir = Directory.systemTemp.createTempSync('gaia_editor_test');
    addTearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } on FileSystemException {
        // Still held open by the decode; the temp folder is the OS's.
      }
    });
    final image = File('${dir.path}/shot.png')
      ..writeAsBytesSync(
        base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
        ),
      );
    late Future<GaiaImageEdits?> result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => result = showGaiaImageEditor(
              context,
              path: image.path,
              label: 1,
              edits: GaiaImageEdits.none,
            ),
            child: const Text('Edit'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Edit'));
    // Until the image has decoded.
    for (var i = 0; i < 50; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
      if (find.byType(CircularProgressIndicator).evaluate().isEmpty) break;
    }
    await tester.pump(const Duration(milliseconds: 500));
    return result;
  }

  final canvas = find.byWidgetPredicate(
    (widget) =>
        widget is CustomPaint &&
        widget.painter.runtimeType.toString() == '_EditsPainter',
  );

  /// Opens the editor on [tool], runs [draw] from the canvas's centre, and
  /// returns the one mark's points in canvas pixels.
  Future<List<Offset>> drawWith(
    WidgetTester tester,
    String tool,
    Future<void> Function(Offset start) draw,
  ) async {
    final result = await open(tester);
    await tester.tap(find.byTooltip(tool));
    await tester.pump();
    // The 1x1 image fills the canvas's shorter side.
    final scale = tester.getSize(canvas).shortestSide;
    await draw(tester.getCenter(canvas));
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    return [
      for (final point in (await result)!.marks.single.points) point * scale,
    ];
  }

  /// Drags across the canvas with [tool] and Shift held, and returns the
  /// mark's two ends in canvas pixels.
  Future<(Offset, Offset)> shiftDrag(
    WidgetTester tester,
    String tool,
    Offset by,
  ) async {
    final points = await drawWith(tester, tool, (start) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.dragFrom(start, by);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    });
    return (points.first, points.last);
  }

  testWidgets('opens on the pen', (tester) async {
    await open(tester);

    bool selected(String tool) => tester
        .widget<IconButton>(
          find.ancestor(
            of: find.byTooltip(tool),
            matching: find.byType(IconButton),
          ),
        )
        .isSelected!;
    expect(selected('Pen'), isTrue);
    expect(selected('Arrow'), isFalse);
  });

  testWidgets('Shift keeps a line to 45° steps', (tester) async {
    final (from, to) = await shiftDrag(tester, 'Line', const Offset(100, 30));
    final delta = to - from;
    expect(delta.dy, closeTo(0, 0.01));
    expect(delta.dx, greaterThan(90));
  });

  testWidgets('Shift keeps a rectangle square', (tester) async {
    final (from, to) = await shiftDrag(
      tester,
      'Rectangle',
      const Offset(-120, 50),
    );
    final delta = to - from;
    expect(delta.dx, lessThan(0));
    expect(delta.dy.abs(), closeTo(delta.dx.abs(), 0.01));
  });

  testWidgets('Shift makes a pen stroke one 45° line', (tester) async {
    final points = await drawWith(tester, 'Pen', (start) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      final gesture = await tester.startGesture(start);
      for (final by in const [Offset(30, 25), Offset(30, 40), Offset(40, 30)]) {
        await gesture.moveBy(by);
        await tester.pump();
      }
      await gesture.up();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    });
    expect(points, hasLength(2));
    final delta = points.last - points.first;
    expect(delta.dx, closeTo(delta.dy, 0.01));
  });

  testWidgets('Shift mid-stroke keeps what the pen already drew', (
    tester,
  ) async {
    final points = await drawWith(tester, 'Highlighter', (start) async {
      final gesture = await tester.startGesture(start);
      for (final by in const [Offset(30, 0), Offset(10, 20), Offset(10, 20)]) {
        await gesture.moveBy(by);
        await tester.pump();
      }
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      for (final by in const [Offset(40, 5), Offset(40, -5)]) {
        await gesture.moveBy(by);
        await tester.pump();
      }
      await gesture.up();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    });
    // The freehand part, then one straight run to the right.
    expect(points.length, greaterThan(2));
    final run = points.last - points[points.length - 2];
    expect(run.dy, closeTo(0, 0.01));
    expect(run.dx, greaterThan(60));
  });

  /// Draws an 80x60 rectangle from the canvas's centre, drags it by its
  /// right edge with [tool], maybe undoes that, and returns the marks'
  /// corners from the centre in canvas pixels.
  Future<List<(Offset, Offset)>> dragRectangle(
    WidgetTester tester, {
    String tool = 'Move',
    bool undo = false,
  }) async {
    final result = await open(tester);
    await tester.tap(find.byTooltip('Rectangle'));
    await tester.pump();
    final scale = tester.getSize(canvas).shortestSide;
    final start = tester.getCenter(canvas);
    await tester.dragFrom(start, const Offset(80, 60));
    await tester.pump();
    await tester.tap(find.byTooltip(tool));
    await tester.pump();
    await tester.dragFrom(start + const Offset(80, 30), const Offset(-30, 20));
    await tester.pump();
    if (undo) {
      await tester.tap(find.byTooltip('Undo (Ctrl+Z)'));
      await tester.pump();
    }
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    // The 1x1 image's centre is the canvas's.
    final centre = Offset(scale / 2, scale / 2);
    return [
      for (final GaiaMark(:points) in (await result)!.marks)
        (points.first * scale - centre, points.last * scale - centre),
    ];
  }

  Future<(Offset, Offset)> moveRectangle(
    WidgetTester tester, {
    bool undo = false,
  }) async => (await dragRectangle(tester, undo: undo)).single;

  testWidgets('dragging a placed mark moves it', (tester) async {
    final (from, to) = await moveRectangle(tester);
    expect(from, offsetMoreOrLessEquals(const Offset(-30, 20)));
    expect(to, offsetMoreOrLessEquals(const Offset(50, 80)));
  });

  testWidgets('Undo puts a moved mark back', (tester) async {
    final (from, to) = await moveRectangle(tester, undo: true);
    expect(from, offsetMoreOrLessEquals(Offset.zero));
    expect(to, offsetMoreOrLessEquals(const Offset(80, 60)));
  });

  testWidgets('a drawing tool draws over a mark rather than moving it', (
    tester,
  ) async {
    final marks = await dragRectangle(tester, tool: 'Rectangle');
    expect(marks, hasLength(2));
    expect(marks.first.$1, offsetMoreOrLessEquals(Offset.zero));
  });
}
