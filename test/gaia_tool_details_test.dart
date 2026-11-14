import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/adapters/gaia_agent_runner.dart';
import 'package:voyager/features/gaia/companion/gaia_activity_chip.dart';

/// What each tool call in a reply was called with: kept beside its name as
/// the reply streams, saved and synced with it, and shown only on a click.
void main() {
  test('a detail coming late lands on its own call, even after more text '
      'and tools', () {
    final builder = GaiaTurnBuilder();
    for (final event in [
      const GaiaToolUse('Bash', id: 'a'),
      const GaiaToolUse('WebSearch', id: 'b', detail: 'known at once'),
      const GaiaTextStart(),
      const GaiaTextDelta('Looking.'),
      const GaiaToolUse('Bash', id: 'c'),
    ]) {
      builder.apply(event);
    }
    expect(
      builder.apply(const GaiaToolDetails({'a': 'ls', 'c': 'pwd'})),
      isTrue,
    );
    // The same again changes nothing, and an unknown id is skipped.
    expect(
      builder.apply(const GaiaToolDetails({'a': 'ls', 'z': 'x'})),
      isFalse,
    );
    expect(builder.finished.map((part) => part.toJson()), [
      {
        'type': 'activity',
        'tools': ['Bash', 'WebSearch'],
        'details': ['ls', 'known at once'],
      },
      {'type': 'text', 'text': 'Looking.'},
      {
        'type': 'activity',
        'tools': ['Bash'],
        'details': ['pwd'],
      },
    ]);
  });

  test('details survive a round trip, and a part from before them reads as '
      'having none', () {
    const part = GaiaActivityPart(['Bash', 'Read'], details: ['ls', null]);
    final back = GaiaPart.fromJson(part.toJson()) as GaiaActivityPart;
    expect(back.tools, ['Bash', 'Read']);
    expect(back.details, ['ls', null]);

    final old =
        GaiaPart.fromJson({
              'type': 'activity',
              'tools': ['Bash'],
            })
            as GaiaActivityPart;
    expect(old.detailAt(0), isNull);
    expect(old.toJson(), {
      'type': 'activity',
      'tools': ['Bash'],
    });
  });

  Widget chip(GaiaActivityPart part) => MaterialApp(
    home: Scaffold(
      body: GaiaActivityChip(label: 'Used Bash ×2', part: part),
    ),
  );

  testWidgets('the commands are hidden until the chip is clicked', (
    tester,
  ) async {
    await tester.pumpWidget(
      chip(const GaiaActivityPart(['Bash', 'Bash'], details: ['ls', 'pwd'])),
    );
    expect(find.text('ls'), findsNothing);
    expect(find.byIcon(Icons.expand_more), findsOneWidget);

    await tester.tap(find.text('Used Bash ×2'));
    await tester.pump();
    expect(find.text('ls'), findsOneWidget);
    expect(find.text('pwd'), findsOneWidget);

    await tester.tap(find.text('Used Bash ×2'));
    await tester.pump();
    expect(find.text('ls'), findsNothing);
  });

  testWidgets('failed calls are counted on the chip, each with its reason '
      'once open', (tester) async {
    await tester.pumpWidget(
      chip(
        const GaiaActivityPart(
          ['Bash', 'Bash'],
          details: ['ls', 'rm x'],
          failures: [null, 'Exit code 1'],
        ),
      ),
    );
    expect(find.text('1 failed'), findsOneWidget);
    expect(find.text('Exit code 1'), findsNothing);
    await tester.tap(find.text('Used Bash ×2'));
    await tester.pump();
    expect(find.text('Exit code 1'), findsOneWidget);
    expect(find.byIcon(Icons.close), findsNWidgets(2));
  });

  testWidgets('a failure with no detail still opens', (tester) async {
    await tester.pumpWidget(
      chip(const GaiaActivityPart(['Bash'], failures: ['Failed'])),
    );
    expect(find.byIcon(Icons.expand_more), findsOneWidget);
  });

  test('a failure coming late lands on its own call, and round-trips', () {
    final builder = GaiaTurnBuilder()
      ..apply(const GaiaToolUse('Bash', id: 'a', detail: 'ls'))
      ..apply(const GaiaToolUse('Bash', id: 'b'));
    expect(builder.apply(const GaiaToolFailures({'b': 'Exit code 2'})), isTrue);
    final part = builder.parts.single as GaiaActivityPart;
    expect(part.toJson(), {
      'type': 'activity',
      'tools': ['Bash', 'Bash'],
      'details': ['ls', null],
      'failures': [null, 'Exit code 2'],
    });
    final back = GaiaPart.fromJson(part.toJson()) as GaiaActivityPart;
    expect(back.failures, [null, 'Exit code 2']);
  });

  testWidgets('a chip with no details has nothing to open', (tester) async {
    await tester.pumpWidget(chip(const GaiaActivityPart(['Bash', 'Bash'])));
    expect(find.byIcon(Icons.expand_more), findsNothing);
  });

  testWidgets('an open chip shows a detail that streams in after it opened', (
    tester,
  ) async {
    await tester.pumpWidget(
      chip(const GaiaActivityPart(['Bash', 'Bash'], details: ['ls'])),
    );
    await tester.tap(find.text('Used Bash ×2'));
    await tester.pump();
    await tester.pumpWidget(
      chip(const GaiaActivityPart(['Bash', 'Bash'], details: ['ls', 'pwd'])),
    );
    expect(find.text('pwd'), findsOneWidget);
  });

  test("a part's details stop at its budget; its names and failures don't", () {
    final big = 'x' * kGaiaToolDetailMax;
    final fit = kGaiaActivityDetailBudget ~/ kGaiaToolDetailMax;
    var part = const GaiaActivityPart([]);
    for (var i = 0; i < fit; i++) {
      part = part.adding('Bash', detail: big);
    }
    part = part
        .adding('Bash', detail: big, failure: 'Exit code 1')
        .withCall(0, detail: 'short');
    expect(part.tools, hasLength(fit + 1));
    expect(part.detailAt(fit), isNull);
    expect(part.failureAt(fit), 'Exit code 1');
    // Replacing a detail counts what it takes the place of.
    expect(part.detailAt(0), 'short');
    expect(part.withCall(fit, detail: big).detailAt(fit), big);
  });

  test("an os_clipboard write keeps no result, as its chip isn't a read's", () {
    final builder = GaiaTurnBuilder()
      ..apply(const GaiaToolUse('os_clipboard', id: 'read'))
      ..apply(const GaiaToolUse('os_clipboard', id: 'write'))
      ..apply(const GaiaToolUse('os_clipboard', id: 'codex', action: true));
    expect(
      builder.apply(const GaiaToolDetails({}, actions: {'write'})),
      isTrue,
    );
    expect(
      builder.apply(const GaiaToolDetails({}, actions: {'write'})),
      isFalse,
    );
    final part = builder.finished.single as GaiaActivityPart;
    expect([for (var i = 0; i < 3; i++) part.idAt(i)], ['read', null, null]);
  });
}
