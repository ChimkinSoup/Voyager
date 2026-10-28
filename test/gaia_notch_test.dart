import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/features/gaia/companion/gaia_button.dart';
import 'package:voyager/features/gaia/companion/gaia_notch.dart';

import 'narrow_window_harness.dart' show loadRealFonts;

enum _Tier { quick, standard, deep }

/// Past every animation but the ring's light, which never stops.
Future<void> settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  final field = FocusNode();
  late _Tier value;
  late List<_Tier> asked;

  /// [accept] false: the parent turns every change down. With [later], it
  /// answers once that completes.
  Future<void> pump(
    WidgetTester tester, {
    bool accept = true,
    Future<void>? later,
  }) async {
    await loadRealFonts(tester);
    value = _Tier.standard;
    asked = [];
    await tester.pumpWidget(
      MaterialApp(
        theme: VoyagerTheme.dark(accent: const Color(0xFF3B82F6)),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => Column(
              children: [
                TextField(focusNode: field, autofocus: true),
                const Spacer(),
                Align(
                  alignment: Alignment.bottomRight,
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: GaiaNotch(
                      items: [
                        GaiaNotchItem<_Tier>(
                          options: [
                            for (final tier in _Tier.values)
                              GaiaNotchOption(
                                value: tier,
                                label: tier.name,
                                detail: 'model ${tier.index}',
                              ),
                          ],
                          value: value,
                          onChanged: (tier) {
                            asked.add(tier);
                            if (later != null) return later;
                            if (accept) setState(() => value = tier);
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await settle(tester);
  }

  /// The visible shell: the overlay's, not the placeholder.
  Size shell(WidgetTester tester) => tester.getSize(
    find
        .descendant(
          of: find.byType(Overlay).first,
          matching: find.byType(AnimatedSize),
        )
        .last,
  );

  testWidgets('morphs into the options and back on a pick', (tester) async {
    await pump(tester);
    final closed = shell(tester);
    // 24 with its 1px border, compact in the row under the composer.
    expect(closed.height, 24);

    await tester.tap(find.textContaining('standard', findRichText: true).last);
    await settle(tester);
    final open = shell(tester);
    // Three options high, not the whole overlay.
    expect(open.height, inInclusiveRange(100, 160));
    expect(find.textContaining('deep', findRichText: true), findsOneWidget);
    // Grows from its bottom right corner (inside its border).
    final placeholder = tester.getBottomRight(find.byType(GaiaNotch));
    expect(
      tester.getBottomRight(find.byType(AnimatedSize).last),
      placeholder - const Offset(1, 1),
    );

    await tester.tap(find.textContaining('deep', findRichText: true));
    await settle(tester);
    expect(asked, [_Tier.deep]);
    expect(shell(tester).height, 24);
    expect(find.textContaining('deep', findRichText: true), findsWidgets);
    expect(field.hasPrimaryFocus, isTrue);
  });

  testWidgets('a turned-down change keeps the selection', (tester) async {
    await pump(tester, accept: false);
    await tester.tap(find.textContaining('standard', findRichText: true).last);
    await settle(tester);
    await tester.tap(find.textContaining('quick', findRichText: true));
    await settle(tester);
    expect(asked, [_Tier.quick]);
    expect(find.textContaining('quick', findRichText: true), findsNothing);
  });

  testWidgets('keys move, pick and close', (tester) async {
    await pump(tester);
    await tester.tap(find.textContaining('standard', findRichText: true).last);
    await settle(tester);
    // The selected option has the focus: Down twice wraps to the first.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await settle(tester);
    expect(asked, [_Tier.quick]);

    await tester.tap(find.textContaining('quick', findRichText: true).last);
    await settle(tester);
    // Opens again after a landing.
    expect(shell(tester).height, inInclusiveRange(100, 160));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    expect(asked, [_Tier.quick]);
    expect(shell(tester).height, 24);
    expect(field.hasPrimaryFocus, isTrue);
  });

  testWidgets('a click outside closes', (tester) async {
    await pump(tester);
    await tester.tap(find.textContaining('standard', findRichText: true).last);
    await settle(tester);
    await tester.tapAt(const Offset(20, 300));
    await settle(tester);
    expect(asked, isEmpty);
    expect(shell(tester).height, 24);
  });

  testWidgets('a pick answered later shows until answered', (tester) async {
    final answer = Completer<void>();
    await pump(tester, later: answer.future);
    await tester.tap(find.textContaining('standard', findRichText: true).last);
    await settle(tester);
    await tester.tap(find.textContaining('deep', findRichText: true));
    await settle(tester);
    expect(find.textContaining('deep', findRichText: true), findsWidgets);

    // Turned down: back to the selection.
    answer.complete();
    await settle(tester);
    expect(asked, [_Tier.deep]);
    expect(find.textContaining('deep', findRichText: true), findsNothing);
    expect(find.textContaining('standard', findRichText: true), findsWidgets);
  });

  testWidgets('the option leaving hides while it lands', (tester) async {
    await pump(tester);
    await tester.tap(find.textContaining('standard', findRichText: true).last);
    await settle(tester);
    await tester.tap(find.textContaining('deep', findRichText: true));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    final hidden = find.ancestor(
      of: find.textContaining('deep', findRichText: true),
      matching: find.byWidgetPredicate(
        (widget) => widget is Opacity && widget.opacity == 0,
      ),
    );
    expect(hidden, findsOneWidget);
  });

  testWidgets('closed, the shell sits in its place, not the overlay', (
    tester,
  ) async {
    await pump(tester);
    // In place, whatever it's in (as Gaia's composer) still has the cursor
    // while it's over the capsule.
    final inOverlay = find.descendant(
      of: find.byType(CompositedTransformFollower),
      matching: find.byType(GaiaGlowRing),
    );
    expect(inOverlay, findsNothing);

    await tester.tap(find.textContaining('standard', findRichText: true).last);
    await settle(tester);
    expect(inOverlay, findsOneWidget);
    expect(find.byType(GaiaGlowRing), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    expect(inOverlay, findsNothing);
    expect(find.byType(GaiaGlowRing), findsOneWidget);
  });

  testWidgets('the selection rises into its row as the notch opens', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.textContaining('standard', findRichText: true).last);
    await tester.pump();
    // Past the row's own entrance, still short of the flight's end.
    await tester.pump(const Duration(milliseconds: 300));
    Finder hidden(String text) => find.ancestor(
      // The row's text: only rows have one in an Expanded.
      of: find.descendant(
        of: find.descendant(
          of: find.byType(CompositedTransformFollower),
          matching: find.byType(Expanded),
        ),
        matching: find.textContaining(text, findRichText: true),
      ),
      matching: find.byWidgetPredicate(
        (widget) => widget is Opacity && widget.opacity == 0,
      ),
    );
    expect(hidden('standard'), findsOneWidget);
    await settle(tester);
    expect(hidden('standard'), findsNothing);
  });

  group('right-click menu', () {
    late List<String> picked;

    Future<void> pumpMenu(WidgetTester tester, {required Widget child}) async {
      picked = [];
      await tester.pumpWidget(
        MaterialApp(
          theme: VoyagerTheme.dark(accent: const Color(0xFF3B82F6)),
          home: Scaffold(body: Center(child: child)),
        ),
      );
    }

    Widget area() => Builder(
      builder: (context) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onSecondaryTapUp: (details) =>
            showGaiaMenu(context, details.globalPosition, [
              for (final label in ['Rename', 'Delete'])
                GaiaMenuItem(label: label, onPressed: () => picked.add(label)),
            ]),
        child: const SizedBox.square(key: Key('area'), dimension: 100),
      ),
    );

    testWidgets('runs the row picked, and closes', (tester) async {
      await pumpMenu(tester, child: area());
      await tester.tap(
        find.byKey(const Key('area')),
        buttons: kSecondaryButton,
      );
      await settle(tester);
      expect(find.byType(GaiaMenu), findsOneWidget);
      expect(find.byType(GaiaGlowRing), findsOneWidget);

      await tester.tap(find.text('Delete'));
      await settle(tester);
      expect(picked, ['Delete']);
      expect(find.byType(GaiaMenu), findsNothing);
    });

    testWidgets('Esc closes it; the arrows and Enter pick', (tester) async {
      await pumpMenu(tester, child: area());
      await tester.tap(
        find.byKey(const Key('area')),
        buttons: kSecondaryButton,
      );
      await settle(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      expect(find.byType(GaiaMenu), findsNothing);

      await tester.tap(
        find.byKey(const Key('area')),
        buttons: kSecondaryButton,
      );
      await settle(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await settle(tester);
      expect(picked, ['Delete']);
    });

    testWidgets("a text field's has its own buttons, and the Paste given", (
      tester,
    ) async {
      final text = TextEditingController(text: 'hello');
      var pasted = 0;
      await pumpMenu(
        tester,
        child: SizedBox(
          width: 200,
          child: TextField(
            controller: text,
            contextMenuBuilder: (context, state) =>
                gaiaTextMenu(context, state, onPaste: () => pasted++),
          ),
        ),
      );
      await tester.tap(find.byType(TextField), buttons: kSecondaryButton);
      await settle(tester);
      expect(find.byType(GaiaMenu), findsOneWidget);
      expect(find.text('Select all'), findsOneWidget);

      await tester.tap(find.text('Paste'));
      await settle(tester);
      expect(pasted, 1);
      expect(find.byType(GaiaMenu), findsNothing);
    });
  });
}
