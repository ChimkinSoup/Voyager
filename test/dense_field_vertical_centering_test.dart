import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/core/vim/vim_enabled_scope.dart';
import 'package:voyager/core/vim/vim_text_overlay.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/labeled_text_field.dart';
import 'package:voyager/core/widgets/notched_field_border.dart';

/// A single-line field paired with a taller button — the "Add subtask" row of
/// the todo editor, both quote rows of the custom-quotes dialog — is stretched
/// to the button's height by its `IntrinsicHeight` + `stretch` row.
///
/// [InputDecorator] does not re-centre when that happens: it sizes itself to
/// the height it is handed but positions its children inside the shorter
/// content box it computed for itself, so the text ends up hard against the
/// top border with every spare pixel below it. The slack only exists on a
/// desktop's [VisualDensity.compact], which takes 8px off the decorator's
/// content box and nothing off the button next to it — hence the explicit
/// density here, since the test binding otherwise reports Android's standard
/// density and the row comes out coincidentally even.
const _contentPadding = EdgeInsets.symmetric(horizontal: 15, vertical: 8);

/// Paragraph origin of the one [RenderEditable] under [root].
Offset _editableOrigin(RenderObject root) {
  RenderEditable? found;
  void walk(RenderObject node) {
    if (node is RenderEditable) found ??= node;
    node.visitChildren(walk);
  }

  walk(root);
  return found!.localToGlobal(Offset.zero);
}

void main() {
  late TextEditingController controller;
  late FocusNode focusNode;

  setUp(() {
    controller = TextEditingController(text: 'Quote');
    focusNode = FocusNode();
  });

  tearDown(() {
    controller.dispose();
    focusNode.dispose();
  });

  Future<void> pumpRow(WidgetTester tester, {required bool withButton}) async {
    final field = LabeledTextField(
      label: '',
      showLabel: false,
      hintText: 'Add a quote',
      controller: controller,
      focusNode: focusNode,
      dense: true,
      borderRadius: 12,
      contentPadding: _contentPadding,
    );
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: VoyagerTheme.dark().copyWith(
            visualDensity: VisualDensity.compact,
          ),
          home: VimEnabledScope(
            enabled: true,
            child: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 400,
                  child: withButton
                      ? IntrinsicHeight(
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Expanded(child: field),
                              const SizedBox(width: 8),
                              GlassButton(
                                dense: true,
                                onPressed: () {},
                                icon: const Icon(PhosphorIconsRegular.plus),
                              ),
                            ],
                          ),
                        )
                      : field,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  /// Distance from the field's border to the top and bottom of its glyphs.
  ({double top, double bottom}) textGaps(WidgetTester tester) {
    final border = tester.getRect(find.byType(NotchedFieldBorder));
    final text = tester.getRect(find.byType(EditableText));
    return (top: text.top - border.top, bottom: border.bottom - text.bottom);
  }

  testWidgets('a stretched single-line field keeps its text centred', (
    tester,
  ) async {
    await pumpRow(tester, withButton: false);
    final ownHeight = tester.getSize(find.byType(NotchedFieldBorder)).height;

    await pumpRow(tester, withButton: true);
    // The button is the taller of the two, so the row really is stretching the
    // field past the height it asked for. Without that there is no slack to
    // misplace and the centring below would hold on its own.
    expect(
      tester.getSize(find.byType(NotchedFieldBorder)).height,
      greaterThan(ownHeight),
    );

    final gaps = textGaps(tester);
    expect(
      gaps.top,
      closeTo(gaps.bottom, 0.5),
      reason: 'text sits ${gaps.top}px below the top border and '
          '${gaps.bottom}px above the bottom one',
    );
  });

  testWidgets('an unstretched field is left exactly as it was', (tester) async {
    await pumpRow(tester, withButton: false);

    final gaps = textGaps(tester);
    expect(gaps.top, closeTo(gaps.bottom, 0.5));
    // Nothing is stretching it, so the border still hugs the decorator rather
    // than the centring wrapper having grown the field.
    expect(
      tester.getRect(find.byType(NotchedFieldBorder)),
      tester.getRect(find.byType(InputDecorator)),
    );
  });

  testWidgets('the Vim overlay follows the re-centred glyphs', (tester) async {
    await pumpRow(tester, withButton: true);
    await tester.tap(find.byType(TextField));
    await tester.pump();

    final inInsert = _editableOrigin(
      tester.renderObject(find.byType(EditableText)),
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();

    // Esc widens the field's own caret into the block Vim paints with. If that
    // moved the glyphs, every character would jump the moment it came under
    // the block caret.
    final inNormal = _editableOrigin(
      tester.renderObject(find.byType(EditableText)),
    );
    expect(inNormal, inInsert);

    expect(find.byType(VimTextOverlay), findsOneWidget);
    final overlay = tester.getTopLeft(find.byType(VimTextOverlay));
    expect(
      overlay.dy,
      closeTo(inNormal.dy, 0.5),
      reason: 'the overlay repaints the character under the block caret, so a '
          'gap here reads as that character jumping up or down',
    );
    expect(overlay.dx, closeTo(inNormal.dx, 0.5));
  });
}
