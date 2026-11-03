import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/widgets/keep_alive_scroll.dart';

void main() {
  testWidgets('builds its semantics, with a child offset by the padding', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: KeepAliveScrollView(
            storageKey: const PageStorageKey('list'),
            padding: const EdgeInsets.all(20),
            children: [
              for (final label in ['First', 'Second'])
                Semantics(
                  container: true,
                  label: label,
                  child: const SizedBox(height: 100),
                ),
            ],
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.bySemanticsLabel('First'), findsOneWidget);
    expect(find.bySemanticsLabel('Second'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('keeps a child far off-screen laid out', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: KeepAliveScrollView(
            storageKey: const PageStorageKey('list'),
            children: [const SizedBox(height: 50000), const Text('Far below')],
          ),
        ),
      ),
    );

    expect(find.text('Far below', skipOffstage: false), findsOneWidget);
  });
}
