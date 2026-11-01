import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/features/settings/heat_watch_section.dart';
import 'package:voyager/features/shell/reveal_request.dart';

void main() {
  late ProviderContainer container;

  bool requested() => container.read(revealHeatWatchRequestProvider);

  Future<void> pumpSection(WidgetTester tester) => tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(body: ListView(children: const [HeatWatchSection()])),
      ),
    ),
  );

  /// The section's first load runs on another isolate.
  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 500)),
    );
    await tester.pump();
    await tester.pump();
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  }

  setUp(() => container = ProviderContainer());
  tearDown(() => container.dispose());

  testWidgets('answers a request made before it mounted', (tester) async {
    container.read(revealHeatWatchRequestProvider.notifier).state = true;
    await pumpSection(tester);
    await settle(tester);
    expect(requested(), isFalse);
    await unmount(tester);
  });

  testWidgets('answers a request made while mounted', (tester) async {
    await pumpSection(tester);
    await settle(tester);

    container.read(revealHeatWatchRequestProvider.notifier).state = true;
    await tester.pump();
    await tester.pump();
    expect(requested(), isFalse);
    await unmount(tester);
  });
}
