// A sheet's frosted fill is a coloured DecoratedBox sitting between the
// BottomSheet's Material and whatever the sheet shows. A ListTile inks on the
// nearest Material, so without one of its own inside the fill every row's
// hover and splash paint underneath it — and Flutter asserts on each tile.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/widgets/glass_surface.dart';

void main() {
  testWidgets('a ListTile in a Voyager sheet inks above the frosted fill', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showVoyagerSheet<void>(
                context: context,
                builder: (_) =>
                    ListTile(title: const Text('Deck'), onTap: () {}),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(find.text('Deck'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
