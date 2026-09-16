import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/spellcheck/voyager_spell_check_service.dart';
import 'package:voyager/core/vim/vim_enabled_scope.dart';
import 'package:voyager/core/widgets/tag_highlighted_text_field.dart';

const _accent = Color(0xFF00FF00);

/// The app's scroll physics (`_NoScrollbarScrollBehavior` in voyager_app.dart).
class _AppScrollBehavior extends MaterialScrollBehavior {
  const _AppScrollBehavior();

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) =>
      const BouncingScrollPhysics(
        decelerationRate: ScrollDecelerationRate.fast,
        parent: RangeMaintainingScrollPhysics(),
      );
}

void main() {
  testWidgets(
    'dd near the bottom of a scrolled field paints the block caret on its '
    'line every frame',
    (tester) async {
      // Regression: overlays read the scroll offset in build, but a `dd` that
      // shortens the text clamps the field's offset during layout. For that
      // frame (and until something next rebuilt) the block caret painted a
      // line above the one it was on, then dropped back down.
      final controller = TextEditingController(
        text: List.generate(20, (i) => 'line $i').join('\n'),
      );
      final focusNode = FocusNode();
      final boundaryKey = GlobalKey();
      addTearDown(controller.dispose);
      addTearDown(focusNode.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            voyagerSpellCheckServiceProvider.overrideWithValue(
              VoyagerSpellCheckService()..updateDictionary({'line'}),
            ),
          ],
          child: MaterialApp(
            scrollBehavior: const _AppScrollBehavior(),
            home: VimEnabledScope(
              enabled: true,
              child: Scaffold(
                body: RepaintBoundary(
                  key: boundaryKey,
                  child: SizedBox(
                    height: 120,
                    child: TagHighlightedTextField(
                      controller: controller,
                      focusNode: focusNode,
                      expands: true,
                      accentColor: _accent,
                      useNotchedBorder: false,
                      decoration: const InputDecoration(
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byType(TextField));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyG, character: 'G');
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyK, character: 'k');
      await tester.pumpAndSettle();

      final editable = tester.renderObject<RenderEditable>(
        find.descendant(
          of: find.byType(EditableText),
          matching: find.byWidgetPredicate(
            (w) => w.runtimeType.toString() == '_Editable',
          ),
        ),
      );
      final boundary =
          boundaryKey.currentContext!.findRenderObject()! as RenderBox;

      /// Where the field itself puts the caret's top, in boundary pixels.
      double fieldCaretTop() {
        final rect = editable.getLocalRectForCaret(
          TextPosition(offset: controller.selection.baseOffset),
        );
        return boundary
            .globalToLocal(editable.localToGlobal(rect.topLeft))
            .dy;
      }

      /// First row of the painted block caret, read back from the last frame's
      /// layers rather than recomputed.
      Future<int> paintedCaretTop() async {
        final top = await tester.runAsync(() async {
          // The retained layer, not captureImage: that refuses a frame left
          // needing paint, which is exactly the frame that went wrong.
          final image = await (boundary.debugLayer! as OffsetLayer).toImage(
            Offset.zero & boundary.size,
          );
          final bytes = await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          );
          final width = image.width;
          for (var y = 0; y < image.height; y++) {
            for (var x = 0; x < width; x++) {
              final i = (y * width + x) * 4;
              if (bytes!.getUint8(i) == 0 &&
                  bytes.getUint8(i + 1) == 0xFF &&
                  bytes.getUint8(i + 2) == 0) {
                return y;
              }
            }
          }
          return -1;
        });
        return top!;
      }

      final position = tester
          .state<EditableTextState>(find.byType(EditableText))
          .widget
          .scrollController!
          .position;
      expect(position.pixels, position.maxScrollExtent);
      expect(position.pixels, greaterThan(0));
      // The readback agrees with the field before anything moves.
      expect(
        (await paintedCaretTop()).toDouble(),
        moreOrLessEquals(fieldCaretTop(), epsilon: 3),
      );

      // Twice: the first delete clamps the offset but leaves the field's
      // recorded scroll metrics behind, which is what the second one tripped
      // over.
      for (var delete = 0; delete < 2; delete++) {
        final pixelsBefore = position.pixels;
        await tester.sendKeyEvent(LogicalKeyboardKey.keyD, character: 'd');
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.keyD, character: 'd');
        for (var frame = 0; frame < 4; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
          expect(position.pixels, lessThan(pixelsBefore));
          expect(
            (await paintedCaretTop()).toDouble(),
            moreOrLessEquals(fieldCaretTop(), epsilon: 3),
            reason: 'block caret painted off its line on frame $frame of '
                'delete $delete',
          );
        }
      }
      expect(controller.text.split('\n'), hasLength(18));
    },
  );
}
