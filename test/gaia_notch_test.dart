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

  testWidgets('two first options sit side by side; three are listed', (
    tester,
  ) async {
    await loadRealFonts(tester);
    tester.view.physicalSize = const Size(600, 500);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    Future<void> open(int count) async {
      await tester.pumpWidget(
        MaterialApp(
          // A new notch for each count, closed.
          key: ValueKey(count),
          theme: VoyagerTheme.dark(accent: const Color(0xFF3B82F6)),
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomRight,
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: GaiaNotch(
                  items: [
                    GaiaNotchItem<int>(
                      options: [
                        for (var i = 0; i < count; i++)
                          GaiaNotchOption(
                            value: i,
                            label: 'Personal account $i',
                            detail: '23% used',
                          ),
                      ],
                      value: 0,
                      onChanged: (_) {},
                    ),
                    GaiaNotchItem<int>(
                      options: const [
                        GaiaNotchOption(value: 0, label: 'Quick'),
                      ],
                      value: 0,
                      onChanged: (_) {},
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await settle(tester);
      await tester.tap(find.textContaining('Quick', findRichText: true).first);
      await settle(tester);
    }

    Rect row(int index) => tester.getRect(
      find.textContaining('account $index', findRichText: true).last,
    );

    await open(2);
    expect(row(0).top, moreOrLessEquals(row(1).top, epsilon: 0.5));

    await open(3);
    expect(row(0).top, lessThan(row(1).top));
    expect(row(1).top, lessThan(row(2).top));
    expect(row(0).left, greaterThanOrEqualTo(0));
    expect(tester.takeException(), isNull);
  });

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

  testWidgets(
    'the rising selection lands exactly as its row looks',
    (tester) async {
      await pump(tester);
      await tester.tap(
        find.textContaining('standard', findRichText: true).last,
      );
      await tester.pump();
      Finder inShell(String text) => find.descendant(
        of: find.byType(CompositedTransformFollower),
        matching: find.textContaining(text, findRichText: true),
      );
      Finder hiddenRow() => find.descendant(
        of: find.descendant(
          of: find.byType(CompositedTransformFollower),
          matching: find.byType(Expanded),
        ),
        matching: find.textContaining('standard', findRichText: true),
      );
      await tester.pump(const Duration(milliseconds: 100));
      final early = tester.getRect(hiddenRow());
      await tester.pump(const Duration(milliseconds: 280));

      // Nearly landed: the copy is the row's text, at the row's size. The
      // first in the shell is the trigger's own, keeping the bar's size.
      final copy = tester.renderObject<RenderBox>(inShell('standard').at(1));
      final real = tester.renderObject<RenderBox>(hiddenRow());
      expect(copy.size, real.size);
      expect(
        copy.getTransformTo(null).getMaxScaleOnAxis(),
        closeTo(real.getTransformTo(null).getMaxScaleOnAxis(), 0.01),
      );

      // ...and the row it lands on has been in its place all along.
      expect(
        tester.getRect(hiddenRow()),
        rectMoreOrLessEquals(early, epsilon: 0.1),
      );
      await settle(tester);
      expect(
        tester.getRect(hiddenRow()),
        rectMoreOrLessEquals(early, epsilon: 0.1),
      );
    },
    variant: const TargetPlatformVariant({TargetPlatform.windows}),
  );

  testWidgets('the selected dot rises with its row', (tester) async {
    await pump(tester);
    await tester.tap(find.textContaining('standard', findRichText: true).last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    // In the trigger the flight flies from, not the row, which is hidden.
    final trigger = find
        .ancestor(
          of: find
              .descendant(
                of: find.byType(CompositedTransformFollower),
                matching: find.textContaining('standard', findRichText: true),
              )
              .first,
          matching: find.byType(GestureDetector),
        )
        .first;
    expect(tester.renderObject(trigger), paints..circle(radius: 3));
  });

  group('two items', () {
    late String account;
    late _Tier tier;
    late bool twoAccounts;
    late List<Object?> picks;

    Future<void> pumpBoth(
      WidgetTester tester, {
      void Function(_Tier tier, void Function(void Function()) setState)?
      onTier,
    }) async {
      await loadRealFonts(tester);
      account = 'alpha';
      tier = _Tier.standard;
      twoAccounts = true;
      picks = [];
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
                          if (twoAccounts)
                            GaiaNotchItem<String>(
                              options: [
                                for (final name in ['alpha', 'beta'])
                                  GaiaNotchOption(value: name, label: name),
                              ],
                              value: account,
                              onChanged: (name) {
                                picks.add(name);
                                setState(() => account = name);
                              },
                            ),
                          GaiaNotchItem<_Tier>(
                            options: [
                              for (final tier in _Tier.values)
                                GaiaNotchOption(
                                  value: tier,
                                  label: tier.name,
                                  detail: 'model ${tier.index}',
                                ),
                            ],
                            value: tier,
                            onChanged: (picked) {
                              picks.add(picked);
                              setState(() => tier = picked);
                              onTier?.call(picked, setState);
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

    Finder row(String text) => find.descendant(
      of: find.descendant(
        of: find.byType(CompositedTransformFollower),
        matching: find.byType(Expanded),
      ),
      matching: find.textContaining(text, findRichText: true),
    );

    testWidgets('either trigger opens the same panel of both', (tester) async {
      await pumpBoth(tester);
      final bar = shell(tester);

      await tester.tap(find.textContaining('alpha', findRichText: true).first);
      await settle(tester);
      final fromAccount = shell(tester);
      final rectsFromAccount = [
        for (final text in ['alpha', 'beta', 'quick', 'standard', 'deep'])
          tester.getRect(row(text)),
      ];
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      expect(shell(tester), bar);

      await tester.tap(
        find.textContaining('standard', findRichText: true).last,
      );
      await settle(tester);
      expect(shell(tester), fromAccount);
      for (final (index, text) in [
        'alpha',
        'beta',
        'quick',
        'standard',
        'deep',
      ].indexed) {
        expect(
          tester.getRect(row(text)),
          rectMoreOrLessEquals(rectsFromAccount[index], epsilon: 0.1),
        );
      }
      // Accounts above tiers.
      expect(rectsFromAccount[1].bottom, lessThan(rectsFromAccount[2].top));
    });

    testWidgets('a pick from the other section closes and lands in its own '
        'trigger', (tester) async {
      await pumpBoth(tester);
      await tester.tap(find.textContaining('alpha', findRichText: true).first);
      await settle(tester);
      await tester.tap(row('deep'));
      await settle(tester);
      expect(picks, [_Tier.deep]);
      expect(account, 'alpha');
      expect(shell(tester).height, 24);
      expect(field.hasPrimaryFocus, isTrue);
    });

    testWidgets('the clicked item has the focus; the keys cross sections', (
      tester,
    ) async {
      await pumpBoth(tester);
      await tester.tap(find.textContaining('alpha', findRichText: true).first);
      await settle(tester);
      // alpha, then beta, then the first tier.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await settle(tester);
      expect(picks, [_Tier.quick]);

      await tester.tap(find.textContaining('quick', findRichText: true).last);
      await settle(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await settle(tester);
      expect(picks, [_Tier.quick, 'beta']);
    });

    testWidgets('an item going as the panel closes leaves just the bar', (
      tester,
    ) async {
      await pumpBoth(
        tester,
        onTier: (tier, setState) => setState(() => twoAccounts = false),
      );
      await tester.tap(find.textContaining('alpha', findRichText: true).first);
      await settle(tester);
      await tester.tap(row('deep'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      expect(tester.takeException(), isNull);
      await settle(tester);
      expect(picks, [_Tier.deep]);
      expect(shell(tester).height, 24);
      expect(
        find.descendant(
          of: find.byType(CompositedTransformFollower),
          matching: find.byType(GaiaGlowRing),
        ),
        findsNothing,
      );
      expect(field.hasPrimaryFocus, isTrue);
      // And it still opens.
      await tester.tap(find.textContaining('deep', findRichText: true).last);
      await settle(tester);
      expect(row('quick'), findsOneWidget);
    });

    testWidgets(
      'never narrower than the capsule; the accounts share a row',
      (tester) async {
        await pumpBoth(tester);
        final bar = shell(tester);
        final left = tester.getBottomLeft(find.byType(GaiaNotch)).dx;
        await tester.tap(
          find.textContaining('alpha', findRichText: true).first,
        );
        await settle(tester);
        expect(shell(tester).width, greaterThanOrEqualTo(bar.width));
        expect(
          tester.getBottomLeft(find.byType(AnimatedSize).last).dx,
          lessThanOrEqualTo(left + 1),
        );
        expect(
          tester.getCenter(row('alpha')).dy,
          moreOrLessEquals(tester.getCenter(row('beta')).dy, epsilon: 0.1),
        );
        await tester.tap(row('beta'));
        await settle(tester);
        expect(picks, ['beta']);
      },
      variant: const TargetPlatformVariant({TargetPlatform.windows}),
    );
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
