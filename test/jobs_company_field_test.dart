// Cover for the company combobox: it opens on focus with the companies you
// have actually applied to, narrows as you type, and Enter fills the field.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/domain/models/job_models.dart';
import 'package:voyager/features/jobs/jobs_company_field.dart';

JobCompany company(String name) {
  final now = utcNow();
  return JobCompany(id: newId(), name: name, createdAt: now, updatedAt: now);
}

/// The suggestion list is an [OverlayEntry], so it is only reachable once the
/// field is inside a real Overlay — which [MaterialApp] provides.
Future<TextEditingController> pumpField(
  WidgetTester tester, {
  required List<JobCompany> companies,
  List<String> recentKeys = const [],
}) async {
  tester.view.physicalSize = const Size(800, 600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final controller = TextEditingController();
  addTearDown(controller.dispose);

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: JobsCompanyField(
            controller: controller,
            companies: companies,
            recentKeys: recentKeys,
            onChanged: (_) {},
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return controller;
}

Future<void> focusField(WidgetTester tester) async {
  await tester.tap(find.byType(TextField));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('with nothing applied to yet there is no dropdown at all', (
    tester,
  ) async {
    // The seeded catalogue is present but has never been used, so focusing the
    // field offers nothing.
    await pumpField(
      tester,
      companies: [company('Tesla'), company('Google'), company('Temu')],
    );
    await focusField(tester);

    expect(find.text('Tesla'), findsNothing);
    expect(find.text('Google'), findsNothing);
  });

  testWidgets('focusing shows the most recently used companies', (
    tester,
  ) async {
    await pumpField(
      tester,
      companies: [company('Tesla'), company('Google'), company('Temu')],
      recentKeys: const ['temu', 'google', 'tesla'],
    );
    await focusField(tester);

    // In recency order, not alphabetical.
    final listed = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data)
        .whereType<String>()
        .where((t) => ['Tesla', 'Google', 'Temu'].contains(t))
        .toList();
    expect(listed, ['Temu', 'Google', 'Tesla']);
  });

  testWidgets('typing narrows the list to the matches', (tester) async {
    await pumpField(
      tester,
      companies: [company('Tesla'), company('Google'), company('Temu')],
      recentKeys: const ['tesla', 'google', 'temu'],
    );
    await focusField(tester);

    await tester.enterText(find.byType(TextField), 'T');
    await tester.pumpAndSettle();
    expect(find.text('Tesla'), findsOneWidget);
    expect(find.text('Temu'), findsOneWidget);
    expect(find.text('Google'), findsNothing);

    await tester.enterText(find.byType(TextField), 'Tes');
    await tester.pumpAndSettle();
    expect(find.text('Tesla'), findsOneWidget);
    expect(find.text('Temu'), findsNothing);
  });

  testWidgets('Enter fills the field with the highlighted company', (
    tester,
  ) async {
    final controller = await pumpField(
      tester,
      companies: [company('Tesla'), company('Google'), company('Temu')],
      recentKeys: const ['tesla', 'google', 'temu'],
    );
    await focusField(tester);

    await tester.enterText(find.byType(TextField), 'Tes');
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(controller.text, 'Tesla');
    // Filled, so the list has nothing left to offer and closes.
    expect(find.text('Tesla'), findsOneWidget);
  });

  testWidgets('the arrows move the highlight before Enter takes it', (
    tester,
  ) async {
    final controller = await pumpField(
      tester,
      companies: [company('Tesla'), company('Temu')],
      recentKeys: const ['tesla', 'temu'],
    );
    await focusField(tester);

    await tester.enterText(find.byType(TextField), 'T');
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(controller.text, 'Temu');
  });

  testWidgets('a company never applied to is still reachable by typing', (
    tester,
  ) async {
    // The seeded catalogue is not offered unprompted, but it is still there to
    // be found — that is the whole point of keeping it.
    final controller = await pumpField(
      tester,
      companies: [company('Tesla'), company('Stripe')],
      recentKeys: const ['tesla'],
    );
    await focusField(tester);

    await tester.enterText(find.byType(TextField), 'Str');
    await tester.pumpAndSettle();
    expect(find.text('Stripe'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(controller.text, 'Stripe');
  });

  // Run on every platform: the bug this covers only bites on desktop, where
  // [TextField]'s default `onTapOutside` unfocuses on pointer-*down*. The
  // focus listener then tore the overlay down a frame before the click's
  // pointer-up could land on it, so the dropdown could only ever be driven
  // with the keyboard. On mobile the same test passes either way, which is
  // exactly why it has to name the platform rather than take the default.
  testWidgets('clicking a suggestion fills the field', (tester) async {
    final controller = await pumpField(
      tester,
      companies: [company('Tesla'), company('Temu')],
      recentKeys: const ['tesla', 'temu'],
    );
    await focusField(tester);

    await tester.enterText(find.byType(TextField), 'T');
    await tester.pumpAndSettle();
    expect(find.text('Temu'), findsOneWidget);

    // Down, frames, then up — a real click, not the same-frame down/up
    // `tester.tap` sends. Two frames is the minimum that reproduces it: the
    // unfocus lands on pointer-down, the focus listener asks for the
    // teardown in a post-frame callback, and the overlay is not actually
    // gone until the frame after that. A tap with fewer frames inside it
    // passes whether or not the fix is in.
    final click = await tester.startGesture(
      tester.getCenter(find.text('Temu')),
    );
    await tester.pump(const Duration(milliseconds: 60));
    await tester.pump(const Duration(milliseconds: 60));
    await click.up();
    await tester.pumpAndSettle();

    expect(controller.text, 'Temu');
    expect(
      controller.selection,
      const TextSelection.collapsed(offset: 'Temu'.length),
    );
    // And the list is gone: the choice is made.
    expect(find.text('Tesla'), findsNothing);
  }, variant: TargetPlatformVariant.all());

  testWidgets('an open list follows recents that change underneath it', (
    tester,
  ) async {
    final companies = [company('Tesla'), company('Temu')];
    final recents = ValueNotifier<List<String>>(const ['tesla']);
    addTearDown(recents.dispose);
    final controller = TextEditingController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ValueListenableBuilder<List<String>>(
            valueListenable: recents,
            builder: (context, keys, _) => JobsCompanyField(
              controller: controller,
              companies: companies,
              recentKeys: keys,
              onChanged: (_) {},
            ),
          ),
        ),
      ),
    );
    await focusField(tester);
    expect(find.text('Tesla'), findsOneWidget);
    expect(find.text('Temu'), findsNothing);

    recents.value = const ['temu', 'tesla'];
    await tester.pump();
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('Temu'), findsOneWidget, reason: 'refreshed, not stale');
    expect(find.text('Tesla'), findsOneWidget);
  });
}
