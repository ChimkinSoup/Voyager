import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/companion/gaia_card_view.dart';
import 'package:voyager/features/gaia/companion/gaia_control_showcase.dart';
import 'package:voyager/features/gaia/host/gaia_flash.dart';

/// The debug menu's section for what Gaia plays on screen while in control.
void main() {
  const channel = MethodChannel('voyager/gaia_border');
  late List<MethodCall> calls;

  Iterable<Map> flashes() =>
      calls.where((c) => c.method == 'flash').map((c) => c.arguments as Map);

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 3200);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    calls = [];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call);
      return null;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: GaiaControlShowcase(clientOrigin: () => (x: 1000, y: 500)),
          ),
        ),
      ),
    );
  }

  Future<void> tapLabel(WidgetTester tester, String label) async {
    await tester.tap(find.text(label));
    await tester.pump();
  }

  final windows = TargetPlatformVariant.only(TargetPlatform.windows);

  testWidgets('live flashes default to Astral and Trace + Bloom', (
    tester,
  ) async {
    await pump(tester);
    expect(
      tester
          .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Trace + Bloom'))
          .selected,
      isTrue,
    );
    gaiaFlash({'kind': 'click', 'x': 50, 'y': 80}, 0xFF7C9EFF);
    gaiaFlash({'kind': 'mark', 'x': 50, 'y': 80}, 0xFF7C9EFF);
    await tester.pump();
    expect(flashes().every((flash) => flash['style'] == 'astral'), isTrue);
    expect(flashes().first['click_variant'], 'traceBloom');
    calls.clear();
    gaiaFlash({'kind': 'click', 'style': 'classic'}, 0xFF7C9EFF);
    await tester.pump();
    expect(flashes().single['style'], 'classic');
  }, variant: windows);

  testWidgets(
    'click studies affect only single click and compare all three',
    (tester) async {
      await pump(tester);
      await tapLabel(tester, 'Astral');
      for (final entry in {
        'Trace': 'trace',
        'Bloom': 'bloom',
        'Trace + Bloom': 'traceBloom',
      }.entries) {
        await tapLabel(tester, entry.key);
        calls.clear();
        await tapLabel(tester, 'Click');
        expect(flashes().single['click_variant'], entry.value);
        calls.clear();
        await tapLabel(tester, 'Double click');
        expect(flashes().single.containsKey('click_variant'), isFalse);
      }
      calls.clear();
      await tapLabel(tester, 'Play click studies');
      await tester.pump(const Duration(seconds: 7));
      expect(flashes().map((f) => f['click_variant']), [
        'trace',
        'bloom',
        'traceBloom',
      ]);
      expect(flashes().every((f) => f['kind'] == 'click'), isTrue);
    },
    variant: windows,
  );

  testWidgets(
    'every set styles effects, card markers and the control border',
    (tester) async {
      await pump(tester);
      for (final name in ['Astral', 'Echo', 'Glide', 'Current']) {
        await tapLabel(tester, name);
        calls.clear();
        await tapLabel(tester, 'Play all');
        await tester.pump(const Duration(seconds: 30));
        final style = name == 'Current' ? 'classic' : name.toLowerCase();
        expect(flashes(), hasLength(15));
        expect(flashes().every((f) => f['style'] == style), isTrue);

        calls.clear();
        await tapLabel(tester, 'Open the card');
        await tester.pump(const Duration(seconds: 2));
        expect(flashes(), hasLength(5));
        expect(flashes().every((f) => f['style'] == style), isTrue);
        await tapLabel(tester, 'Next step');
        expect(flashes().last['style'], style);

        await tester.tap(find.byType(Switch));
        await tester.pump();
        expect(
          (calls.lastWhere((c) => c.method == 'show').arguments
              as Map)['style'],
          style,
        );
        await tester.tap(find.byType(Switch));
        await tester.pump();
      }
    },
    variant: windows,
  );

  testWidgets(
    'switching sets cancels playback and refreshes an active border',
    (tester) async {
      await pump(tester);
      await tapLabel(tester, 'Current');
      await tester.tap(find.byType(Switch));
      await tapLabel(tester, 'Play all');
      calls.clear();
      await tapLabel(tester, 'Astral');
      await tester.pump(const Duration(seconds: 30));
      expect(flashes(), isEmpty);
      expect((calls.single.arguments as Map)['style'], 'astral');
    },
    variant: windows,
  );

  testWidgets('a click lands on the control, in physical screen pixels', (
    tester,
  ) async {
    await pump(tester);
    await tapLabel(tester, 'Click');
    final flash = flashes().single;
    expect(flash['kind'], 'click');
    expect(flash['label'], 'Mark as read');
    final centre =
        tester.getCenter(find.text('Mark as read')) * 2 +
        const Offset(1000, 500);
    expect((flash['x'] as int).toDouble(), closeTo(centre.dx, 2));
    expect((flash['y'] as int).toDouble(), closeTo(centre.dy, 2));
  }, variant: windows);

  testWidgets('Play all plays every kind of flash', (tester) async {
    await pump(tester);
    await tapLabel(tester, 'Play all');
    await tester.pump(const Duration(seconds: 30));
    expect(flashes().map((f) => f['kind']).toSet(), {
      'click',
      'double',
      'right',
      'scroll',
      'type',
      'key',
      'window',
      'mark',
    });
    expect(
      flashes().where((f) => f['kind'] == 'scroll').map((f) => f['direction']),
      containsAll(['up', 'down', 'left', 'right']),
    );
  }, variant: windows);

  testWidgets('the border goes off with the section', (tester) async {
    await pump(tester);
    await tester.tap(find.byType(Switch));
    await tester.pump();
    final shown = calls.singleWhere((c) => c.method == 'show');
    expect((shown.arguments as Map)['label'], contains('Gaia is in control'));

    calls.clear();
    await tester.pumpWidget(const SizedBox());
    expect(calls.single.method, 'show');
    expect(calls.single.arguments, isNull);
  }, variant: windows);

  testWidgets("the notch's button turns only this border off", (tester) async {
    await pump(tester);
    await tester.tap(find.byType(Switch));
    await tester.pump();
    calls.clear();
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(const MethodCall('revoke')),
      (_) {},
    );
    await tester.pump();
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
    expect(calls.single.arguments, isNull);
  }, variant: windows);

  testWidgets('a card built again, as scrolled back into view, does not '
      'pulse again', (tester) async {
    await pump(tester);
    const card = GaiaCardPart(
      id: 'pulse-once',
      kind: GaiaCardKind.control,
      state: GaiaCardState.open,
      tool: 'os_click',
      input: {
        'window': 'Notepad: "notes.txt"',
        'app': 'Notepad',
        'steps': [
          {
            'label': 'Click Save',
            'resolved': true,
            'flash': {'kind': 'mark', 'left': 10, 'top': 10},
          },
        ],
      },
    );
    Widget view() => const MaterialApp(
      home: Scaffold(body: GaiaCardView(card: card, waiting: true)),
    );
    await tester.pumpWidget(view());
    await tester.pump(const Duration(seconds: 1));
    expect(flashes(), hasLength(1));
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(view());
    await tester.pump(const Duration(seconds: 1));
    expect(flashes(), hasLength(1));
  }, variant: windows);

  testWidgets('the card pulses its markers in order when opened', (
    tester,
  ) async {
    await pump(tester);
    expect(find.byType(GaiaCardView), findsNothing);
    await tapLabel(tester, 'Open the card');
    await tester.pump(const Duration(seconds: 2));
    expect(flashes().map((f) => f['kind']), [
      'mark',
      'mark',
      'mark',
      'scroll',
      'key',
    ]);
    expect(flashes().first.containsKey('left'), isTrue);

    // Opened again, it pulses again.
    calls.clear();
    await tapLabel(tester, 'Open the card');
    await tester.pump(const Duration(seconds: 2));
    expect(flashes(), hasLength(5));
  }, variant: windows);

  testWidgets('hovering a step shows its marker, until it has run', (
    tester,
  ) async {
    await pump(tester);
    await tapLabel(tester, 'Open the card');
    await tester.pump(const Duration(seconds: 2));
    calls.clear();

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.text('Press Ctrl+S')));
    await tester.pump();
    expect(flashes().single['kind'], 'key');
    expect(flashes().single['label'], 'Ctrl+S');

    calls.clear();
    await tapLabel(tester, 'Next step');
    expect(flashes().single['kind'], 'click');
    calls.clear();
    await mouse.moveTo(
      tester.getCenter(find.textContaining('Click Button "Mark as read"')),
    );
    await tester.pump();
    expect(flashes(), isEmpty);
  }, variant: windows);

  testWidgets('Run all ticks every step and ends the card', (tester) async {
    await pump(tester);
    await tapLabel(tester, 'Open the card');
    await tester.pump(const Duration(seconds: 2));
    calls.clear();
    await tapLabel(tester, 'Run all');
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(flashes().map((f) => f['kind']), [
      'click',
      'click',
      'type',
      'scroll',
      'key',
    ]);
    expect(find.text('Ran all 5'), findsOneWidget);
    expect(find.text('Deny'), findsNothing);
  }, variant: windows);

  testWidgets('a step not on screen has no marker, and no Run all', (
    tester,
  ) async {
    await pump(tester);
    await tapLabel(tester, 'Open with a step not on screen');
    await tester.pump(const Duration(seconds: 2));
    expect(flashes(), hasLength(5));
    expect(find.textContaining('not on screen yet'), findsOneWidget);
    expect(find.text('Run all'), findsNothing);
    expect(find.text('Next step'), findsOneWidget);
  }, variant: windows);

  testWidgets('Deny ends the card', (tester) async {
    await pump(tester);
    await tapLabel(tester, 'Open the card');
    await tester.pump(const Duration(seconds: 2));
    await tapLabel(tester, 'Deny');
    expect(find.textContaining('Declined after 0 of 5'), findsOneWidget);
  }, variant: windows);
}
