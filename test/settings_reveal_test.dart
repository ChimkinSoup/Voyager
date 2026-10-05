import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/features/settings/settings_reveal.dart';

/// Stands in for a Settings section that answers a reveal request, as the
/// weather tile and the backup tiles do: on mount if the request is already
/// up, and whenever it goes up later.
class _Section extends StatefulWidget {
  const _Section({required this.request, required this.onShown});

  final ValueNotifier<bool> request;
  final VoidCallback onShown;

  @override
  State<_Section> createState() => _SectionState();
}

class _SectionState extends State<_Section> {
  @override
  void initState() {
    super.initState();
    if (widget.request.value) _reveal();
    widget.request.addListener(_onRequest);
  }

  @override
  void dispose() {
    widget.request.removeListener(_onRequest);
    super.dispose();
  }

  void _onRequest() {
    if (widget.request.value) _reveal();
  }

  void _reveal() => revealSettingsSection(
    context,
    clearRequest: () => widget.request.value = false,
    onShown: widget.onShown,
  );

  @override
  Widget build(BuildContext context) =>
      const SizedBox(height: 100, child: Text('section'));
}

/// Two tabs, the second a kept-alive list with the section below the fold,
/// like Settings' Data and Pages tabs.
class _Tabs extends StatefulWidget {
  const _Tabs({required this.request, required this.onShown});

  final ValueNotifier<bool> request;
  final VoidCallback onShown;

  @override
  State<_Tabs> createState() => _TabsState();
}

class _TabsState extends State<_Tabs> with SingleTickerProviderStateMixin {
  late final TabController tabs = TabController(length: 2, vsync: this);

  @override
  void dispose() {
    tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: TabBarView(
        controller: tabs,
        children: [
          const Text('first tab'),
          _KeepAlive(
            child: ListView(
              children: [
                // Below the fold but within the list's cache extent: the list
                // builds lazily, like Settings' KeepAliveScrollView.
                const SizedBox(height: 700),
                _Section(request: widget.request, onShown: widget.onShown),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _KeepAlive extends StatefulWidget {
  const _KeepAlive({required this.child});

  final Widget child;

  @override
  State<_KeepAlive> createState() => _KeepAliveState();
}

class _KeepAliveState extends State<_KeepAlive>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}

void main() {
  late ValueNotifier<bool> request;
  late List<double> shownAtTabPage;

  setUp(() {
    request = ValueNotifier(false);
    shownAtTabPage = [];
  });

  Future<_TabsState> pumpTabs(WidgetTester tester) async {
    late _TabsState state;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => _Tabs(
            request: request,
            onShown: () => shownAtTabPage.add(state.tabs.animation!.value),
          ),
        ),
      ),
    );
    state = tester.state<_TabsState>(find.byType(_Tabs));
    return state;
  }

  void expectRevealed(WidgetTester tester) {
    expect(tester.takeException(), isNull);
    expect(request.value, isFalse);
    // On screen, and the tab had settled on the section's page by the time
    // the section was shown (a focus then scrolls nothing but the list).
    final rect = tester.getRect(find.text('section'));
    expect(rect.top, greaterThanOrEqualTo(0));
    expect(rect.bottom, lessThanOrEqualTo(600));
    expect(shownAtTabPage, [1.0]);
  }

  testWidgets('a section built mid tab animation is revealed after it', (
    tester,
  ) async {
    final state = await pumpTabs(tester);
    request.value = true;
    state.tabs.animateTo(1);
    await tester.pumpAndSettle();
    expectRevealed(tester);
  });

  testWidgets('a kept-alive section is revealed after the tab animation', (
    tester,
  ) async {
    final state = await pumpTabs(tester);
    // Visit the section's tab and come back, so it stays mounted off screen.
    state.tabs.animateTo(1);
    await tester.pumpAndSettle();
    state.tabs.animateTo(0);
    await tester.pumpAndSettle();

    state.tabs.animateTo(1);
    request.value = true;
    await tester.pumpAndSettle();
    expectRevealed(tester);
  });
}
