import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/features/gaia/companion/gaia_settings_panel.dart';
import 'package:voyager/features/gaia/page/gaia_page.dart';

/// The desktop's Gaia page is a way into the Gaia window
/// (GAIA_SETTINGS_HLD.md §9); the phone's keeps its tabs.
void main() {
  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: VoyagerTheme.light(),
          home: const Scaffold(body: GaiaPage()),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets(
    'on Windows: Open in Gaia and a button per panel tab, no tabs',
    (tester) async {
      await pump(tester);
      expect(find.text('Open in Gaia'), findsOneWidget);
      for (final tab in GaiaPanelTab.values) {
        expect(find.text(tab.label), findsOneWidget);
      }
      expect(find.text('Chats'), findsNothing);
      expect(find.byType(SegmentedButton), findsNothing);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}
