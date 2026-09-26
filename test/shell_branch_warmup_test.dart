// The shell warms every branch a few seconds after mounting, so a first visit
// doesn't pay for the page's build, its catch-up rebuild and its shaders on
// the switch's first frame. Branches in `mountLater` aren't built until then,
// or until visited, whichever comes first.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:voyager/core/motion/voyager_crossfade.dart';
import 'package:voyager/features/shell/shell_page_transition.dart';

/// Records its page's lifecycle: `init <name>` once, then `<name> on` and
/// `<name> off` as its [TickerMode] flips.
class _Probe extends StatefulWidget {
  const _Probe(this.name, this.log);

  final String name;
  final List<String> log;

  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  bool? _enabled;

  @override
  void initState() {
    super.initState();
    widget.log.add('init ${widget.name}');
  }

  @override
  Widget build(BuildContext context) {
    final enabled = TickerMode.valuesOf(context).enabled;
    if (enabled != _enabled) {
      _enabled = enabled;
      widget.log.add('${widget.name} ${enabled ? 'on' : 'off'}');
    }
    return Text(widget.name);
  }
}

Future<(StatefulNavigationShell Function(), List<String>)> _pumpShell(
  WidgetTester tester,
) async {
  final log = <String>[];
  late StatefulNavigationShell shell;
  StatefulShellBranch branch(String name) => StatefulShellBranch(
    preload: true,
    routes: [
      GoRoute(path: '/$name', builder: (_, _) => _Probe(name, log)),
    ],
  );
  final router = GoRouter(
    initialLocation: '/a',
    routes: [
      StatefulShellRoute(
        builder: (_, _, navigationShell) {
          shell = navigationShell;
          return navigationShell;
        },
        navigatorContainerBuilder: shellBranchContainerBuilder(
          mountLater: {2},
          // `d` stands for a page hidden from the rail.
          shouldWarm: (i) => i != 3,
        ),
        branches: [branch('a'), branch('b'), branch('c'), branch('d')],
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(MaterialApp.router(routerConfig: router));
  return (() => shell, log);
}

double _opacityOf(WidgetTester tester, String name) => tester
    .widget<VoyagerFade>(
      find
          .ancestor(
            of: find.text(name, skipOffstage: false),
            matching: find.byType(VoyagerFade),
          )
          .first,
    )
    .opacity;

void main() {
  testWidgets('a mountLater branch waits, the rest are built with the shell', (
    tester,
  ) async {
    final (_, log) = await _pumpShell(tester);

    expect(log, containsAll(['init a', 'init b', 'init d']));
    expect(log, isNot(contains('init c')));
  });

  testWidgets('the warm-up shows each branch unseen, once, then hides it', (
    tester,
  ) async {
    final (_, log) = await _pumpShell(tester);
    log.clear();

    // The first warm frame: `b` in sight, drawn but invisible.
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(log, ['b on']);
    expect(_opacityOf(tester, 'b'), 1 / 255);

    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(log, ['b on', 'b off', 'init c', 'c on', 'c off']);
    expect(_opacityOf(tester, 'b'), 0);
    expect(_opacityOf(tester, 'c'), 0);
    // Skipped by shouldWarm, and `a` is on screen already.
    expect(log.where((e) => e.startsWith('d') || e.startsWith('a')), isEmpty);
  });

  testWidgets('visiting a mountLater branch builds it at once', (
    tester,
  ) async {
    final (shell, log) = await _pumpShell(tester);

    shell().goBranch(2);
    await tester.pumpAndSettle();

    expect(log, contains('init c'));
    expect(find.text('c'), findsOneWidget);
    expect(_opacityOf(tester, 'c'), 1);
  });
}
