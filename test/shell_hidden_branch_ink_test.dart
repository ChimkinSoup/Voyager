// A branch that is switched away from must stop painting entirely — including
// Ink, which the nearest Material ancestor paints on the tile's behalf. A
// ListTile's fill is Ink, and the shell's Scaffold is the Material above the
// branches, so a fade that let Ink through left the old page's tiles drawn,
// contentless, behind every other page.

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/features/shell/shell_page_transition.dart';

final _key = GlobalKey();

Widget _app(int index) => RepaintBoundary(
  key: _key,
  child: MaterialApp(
    home: Scaffold(
      backgroundColor: const Color(0xFF000000),
      body: ShellBranchContainer(
        currentIndex: index,
        children: const [
          // Branch 0: a red tile in the top-left corner, drawn as Ink.
          Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 200,
              child: ListTile(tileColor: Color(0xFFFF0000)),
            ),
          ),
          SizedBox.expand(),
        ],
      ),
    ),
  ),
);

Future<int> _redAt(WidgetTester tester, int x, int y) async {
  final ro = _key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  late ByteData data;
  await tester.runAsync(() async {
    final img = await ro.toImage();
    data = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  });
  return data.getUint8(4 * (y * 800 + x));
}

void main() {
  testWidgets('a branch switched away from leaves no Ink behind', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_app(0));
    expect(await _redAt(tester, 20, 20), 255);

    await tester.pumpWidget(_app(1));
    await tester.pumpAndSettle();

    expect(await _redAt(tester, 20, 20), 0);
  });
}
