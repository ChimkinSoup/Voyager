// Switching views must not remount or rebuild the pages being switched
// between. The crossfades used to add and drop their Opacity / Transform
// wrappers at the start and end of a switch, which changed the widget type
// above each page and rebuilt it from scratch on those two frames.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/motion/motion.dart';
import 'package:voyager/features/shell/shell_page_transition.dart';

class _Counts {
  int inits = 0;
  int builds = 0;
}

class _Page extends StatefulWidget {
  const _Page(this.counts);

  final _Counts counts;

  @override
  State<_Page> createState() => _PageState();
}

class _PageState extends State<_Page> {
  @override
  void initState() {
    super.initState();
    widget.counts.inits++;
  }

  @override
  Widget build(BuildContext context) {
    widget.counts.builds++;
    return const SizedBox.expand();
  }
}

void main() {
  final a = _Counts();
  final b = _Counts();
  final pages = [_Page(a), _Page(b)];

  setUp(() {
    a
      ..inits = 0
      ..builds = 0;
    b
      ..inits = 0
      ..builds = 0;
  });

  Future<void> switchThereAndBack(
    WidgetTester tester,
    Widget Function(int index) at,
  ) async {
    await tester.pumpWidget(
      Directionality(textDirection: TextDirection.ltr, child: at(0)),
    );
    for (final index in [1, 0]) {
      await tester.pumpWidget(
        Directionality(textDirection: TextDirection.ltr, child: at(index)),
      );
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();
    }
  }

  testWidgets('VoyagerCrossfadeIndex keeps both pages mounted and unbuilt', (
    tester,
  ) async {
    await switchThereAndBack(
      tester,
      (index) => VoyagerCrossfadeIndex(
        index: index,
        fadeIncoming: false,
        children: pages,
      ),
    );

    expect((a.inits, b.inits), (1, 1));
    expect((a.builds, b.builds), (1, 1));
  });

  testWidgets('ShellBranchContainer keeps both branches mounted and unbuilt', (
    tester,
  ) async {
    await switchThereAndBack(
      tester,
      (index) => ShellBranchContainer(currentIndex: index, children: pages),
    );

    expect((a.inits, b.inits), (1, 1));
    expect((a.builds, b.builds), (1, 1));
  });
}
