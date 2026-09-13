// VOYAGER_SHEET_DISMISS_HLD.md: an `editor` sheet drags to dismiss on Android
// only, a `sheet` everywhere, and a grab handle shows exactly where the drag
// works. Flung for real rather than read off BottomSheet.enableDrag, so the
// test fails if the flag stops reaching the gesture.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/widgets/glass_surface.dart';

void main() {
  for (final (platform, kind, drags) in [
    (TargetPlatform.windows, VoyagerSheetKind.editor, false),
    (TargetPlatform.android, VoyagerSheetKind.editor, true),
    (TargetPlatform.windows, VoyagerSheetKind.sheet, true),
    (TargetPlatform.android, VoyagerSheetKind.sheet, true),
  ]) {
    testWidgets(
      '${kind.name} on ${platform.name} '
      '${drags ? 'drags away, with a handle' : 'stays put, without a handle'}',
      (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        try {
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: Builder(
                  builder: (context) => TextButton(
                    onPressed: () => showVoyagerSheet<void>(
                      context: context,
                      kind: kind,
                      builder: (_) => Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (voyagerSheetDrags(kind))
                            const VoyagerSheetHandle(),
                          const SizedBox(height: 300, child: Text('Body')),
                        ],
                      ),
                    ),
                    child: const Text('Open'),
                  ),
                ),
              ),
            ),
          );
          await tester.tap(find.text('Open'));
          await tester.pumpAndSettle();
          expect(
            find.byType(VoyagerSheetHandle),
            drags ? findsOneWidget : findsNothing,
          );

          await tester.fling(find.text('Body'), const Offset(0, 400), 2000);
          await tester.pumpAndSettle();
          expect(find.text('Body'), drags ? findsNothing : findsOneWidget);
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );
  }
}
