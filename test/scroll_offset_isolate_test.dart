import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/widgets/scroll_offset_isolate.dart';
import 'package:voyager/core/widgets/voyager_scroll_view.dart';

/// The app's own physics, so an out-of-range offset settles the way it does in
/// the app — [BouncingScrollPhysics] springs it back over a few hundred
/// milliseconds instead of snapping, which is what made the leak visible.
class _BouncingBehavior extends ScrollBehavior {
  const _BouncingBehavior();

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) =>
      const BouncingScrollPhysics(
        decelerationRate: ScrollDecelerationRate.fast,
        parent: RangeMaintainingScrollPhysics(),
      );

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) => child;
}

/// The shape [_HeatmapBucket] has in `analytics_page.dart`: a plain [Column]
/// while it holds one row, a nested [ReorderableListView] once it holds two.
/// Deleting a row and undoing walks it across that boundary, mounting the
/// nested list fresh.
class _Bucket extends StatelessWidget {
  const _Bucket({required this.ids, required this.isolate});

  final List<String> ids;
  final bool isolate;

  Widget _row(int i) => Padding(
    key: ValueKey(ids[i]),
    padding: const EdgeInsets.only(bottom: 6),
    child: SizedBox(height: 70, child: Text(ids[i])),
  );

  @override
  Widget build(BuildContext context) {
    if (ids.length <= 1) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [for (var i = 0; i < ids.length; i++) _row(i)],
      );
    }
    final list = ReorderableListView(
      primary: false,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      buildDefaultDragHandles: false,
      onReorderItem: (_, _) {},
      children: [for (var i = 0; i < ids.length; i++) _row(i)],
    );
    return isolate ? ScrollOffsetIsolate(child: list) : list;
  }
}

class _Page extends StatefulWidget {
  const _Page({super.key, required this.isolate});

  final bool isolate;

  @override
  State<_Page> createState() => _PageState();
}

class _PageState extends State<_Page> {
  var _ids = const ['Test Bool', 'LeetCode'];

  void delete() => setState(() => _ids = const ['LeetCode']);
  void undo() => setState(() => _ids = const ['Test Bool', 'LeetCode']);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      scrollBehavior: const _BouncingBehavior(),
      home: Scaffold(
        // The page key the shell needs to restore this list's offset is also
        // the only [PageStorageKey] above the nested list, so both resolve to
        // one identifier.
        body: ListView(
          key: const PageStorageKey<String>('analyticsList'),
          // Matches KeepAliveScrollView, which the analytics page uses.
          // ignore: deprecated_member_use
          cacheExtent: double.infinity,
          children: [
            const SizedBox(height: 300, child: Text('macro')),
            _Bucket(ids: _ids, isolate: widget.isolate),
            const SizedBox(height: 600, child: Text('filler')),
          ],
        ),
      ),
    );
  }
}

/// Largest offset the nested list reaches while it settles after mounting.
Future<double> _peakNestedOffset(
  WidgetTester tester,
  GlobalKey<_PageState> key,
) async {
  final outer = tester
      .state<ScrollableState>(find.byType(Scrollable).first)
      .position;
  outer.jumpTo(250);
  await tester.pumpAndSettle();

  key.currentState!.delete();
  await tester.pumpAndSettle();
  key.currentState!.undo();

  var peak = 0.0;
  for (var frame = 0; frame < 25; frame++) {
    await tester.pump(const Duration(milliseconds: 16));
    final scrollables = find.byType(Scrollable);
    if (scrollables.evaluate().length > 1) {
      final nested = tester
          .state<ScrollableState>(scrollables.at(1))
          .position
          .pixels;
      if (nested.abs() > peak) peak = nested.abs();
    }
  }
  await tester.pumpAndSettle();
  return peak;
}

/// The manage sheets' shape: one dialog route whose tab switch mounts exactly
/// one pane at a time, each pane a keyless scroll view, and no
/// [PageStorageKey] anywhere between them and the route.
class _PaneBody extends StatelessWidget {
  const _PaneBody({required this.label, required this.isolate});

  final String label;
  final bool isolate;

  @override
  Widget build(BuildContext context) {
    final Widget pane = VoyagerScrollView(
      child: Column(
        children: [
          for (var i = 0; i < 20; i++)
            SizedBox(height: 40, child: Text('$label $i')),
        ],
      ),
    );
    return isolate ? ScrollOffsetIsolate(child: pane) : pane;
  }
}

class _SettingsPane extends StatelessWidget {
  const _SettingsPane({required this.isolate});

  final bool isolate;

  @override
  Widget build(BuildContext context) =>
      _PaneBody(label: 'settings', isolate: isolate);
}

class _TemplatePane extends StatelessWidget {
  const _TemplatePane({required this.isolate});

  final bool isolate;

  @override
  Widget build(BuildContext context) =>
      _PaneBody(label: 'template', isolate: isolate);
}

class _Panes extends StatefulWidget {
  const _Panes({super.key, required this.isolate});

  final bool isolate;

  @override
  State<_Panes> createState() => _PanesState();
}

class _PanesState extends State<_Panes> {
  var _second = false;

  void swap() => setState(() => _second = true);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      scrollBehavior: const _BouncingBehavior(),
      home: Scaffold(
        body: SizedBox(
          height: 300,
          child: _second
              ? _TemplatePane(isolate: widget.isolate)
              : _SettingsPane(isolate: widget.isolate),
        ),
      ),
    );
  }
}

/// Offset the arriving pane opens on.
Future<double> _arrivingPaneOffset(
  WidgetTester tester,
  GlobalKey<_PanesState> key,
) async {
  tester
      .state<ScrollableState>(find.byType(Scrollable).first)
      .position
      .jumpTo(200);
  await tester.pumpAndSettle();

  key.currentState!.swap();
  await tester.pump();
  return tester
      .state<ScrollableState>(find.byType(Scrollable).first)
      .position
      .pixels;
}

void main() {
  testWidgets(
    'without the isolate a remounted nested list adopts the page offset',
    (tester) async {
      final key = GlobalKey<_PageState>();
      await tester.pumpWidget(_Page(key: key, isolate: false));
      await tester.pumpAndSettle();

      // The page saved 250 under the shared identifier, and the nested list
      // restores it even though its own extent is zero — so its rows start off
      // the top of their own viewport and slide down into place.
      expect(await _peakNestedOffset(tester, key), 250.0);
    },
    semanticsEnabled: false,
  );

  testWidgets(
    'ScrollOffsetIsolate keeps a remounted nested list at zero',
    (tester) async {
      final key = GlobalKey<_PageState>();
      await tester.pumpWidget(_Page(key: key, isolate: true));
      await tester.pumpAndSettle();

      expect(await _peakNestedOffset(tester, key), 0.0);
    },
    semanticsEnabled: false,
  );

  testWidgets('the page keeps its own offset either way', (tester) async {
    final key = GlobalKey<_PageState>();
    await tester.pumpWidget(_Page(key: key, isolate: true));
    await tester.pumpAndSettle();
    await _peakNestedOffset(tester, key);

    final outer = tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position;
    expect(outer.pixels, 250.0);
  }, semanticsEnabled: false);

  // The condition on the whole failure mode, and the reason the dialog routes
  // are not exposed to it: [PageStorageBucket.writeState] discards the offset
  // outright when [PageStorage._allKeys] comes back empty, so a scrollable with
  // no [PageStorageKey] between it and its route never saves one — and there is
  // nothing for the next scrollable to pick up.
  testWidgets(
    'with no PageStorageKey above them, panes save nothing to leak',
    (tester) async {
      final key = GlobalKey<_PanesState>();
      await tester.pumpWidget(_Panes(key: key, isolate: false));
      await tester.pumpAndSettle();

      expect(await _arrivingPaneOffset(tester, key), 0.0);
    },
    semanticsEnabled: false,
  );
}
