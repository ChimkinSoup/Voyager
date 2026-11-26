// BUG-394: on a phone the FPS HUD sat on the status bar and the inbox bell,
// and the cache-status card covered the bottom bar and ran off the right edge.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/dev/cache_status.dart';
import 'package:voyager/core/dev/dev_settings_controller.dart';
import 'package:voyager/core/dev/fps_monitor_controller.dart';
import 'package:voyager/features/dev/dev_cache_status_tile.dart';
import 'package:voyager/features/dev/dev_fps_counter_tile.dart';
import 'package:voyager/features/shell/shell_nav_theme.dart';

void main() {
  testWidgets('on a phone both dev overlays clear the bars', (tester) async {
    const statusBar = 40.0;
    const gestureBar = 24.0;
    tester.view.physicalSize = const Size(361, 794);
    tester.view.devicePixelRatio = 1.0;
    tester.view.padding = const FakeViewPadding(
      top: statusBar,
      bottom: gestureBar,
    );
    addTearDown(tester.view.reset);
    final dev = DevSettingsController(saveSettings: (_) async {})
      ..showFpsCounter = true
      ..showCacheStatus = true;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          devSettingsProvider.overrideWith((ref) => dev),
          // Not started: only the card's place is under test.
          fpsMonitorProvider.overrideWith((ref) => FpsMonitorController()),
          cacheStatusSnapshotProvider.overrideWithValue(
            const CacheStatusSnapshot(items: []),
          ),
        ],
        child: const MaterialApp(
          home: Stack(children: [CacheStatusOverlay(), FpsCounterOverlay()]),
        ),
      ),
    );
    await tester.pump();

    final fps = tester.getRect(find.byType(FpsCounterCard));
    expect(fps.top, greaterThanOrEqualTo(statusBar + shellCompactStripHeight));

    final cache = tester.getRect(
      find
          .ancestor(
            of: find.text('Cache status'),
            matching: find.byType(Material),
          )
          .first,
    );
    // ShellBottomNav: the item row, its padding and its 1px top border.
    const barTop = 794 - gestureBar - (shellNavItemHeight + 8) - 1;
    expect(cache.bottom, lessThanOrEqualTo(barTop));
    expect(cache.right, lessThanOrEqualTo(361));
  });
}
