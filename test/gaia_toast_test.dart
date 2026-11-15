import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/features/gaia/companion/gaia_sidebar.dart';
import 'package:voyager/features/gaia/companion/gaia_toast.dart';

void main() {
  testWidgets('a toast follows the sidebar coming and going', (tester) async {
    tester.view.physicalSize = const Size(1200, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final sidebar = GaiaSidebar();
    gaiaToastLeft = sidebar.edge;
    late BuildContext chat;
    await tester.pumpWidget(
      MaterialApp(
        home: GaiaSidebarLayout(
          sidebar: sidebar,
          side: const SizedBox.expand(),
          chat: (shown, toggle) => Builder(
            builder: (context) {
              chat = context;
              return const SizedBox.expand();
            },
          ),
        ),
      ),
    );
    showGaiaToast(chat, mark: GaiaToastMark.done, title: 'T', body: 'B');
    await tester.pump(const Duration(milliseconds: 300));
    final beside = tester.getCenter(find.text('T')).dx;

    // The sidebar's edge is set mid-layout; following it mustn't throw.
    sidebar.setOpen(false);
    await tester.pump();
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(tester.getCenter(find.text('T')).dx, lessThan(beside - 100));

    await tester.pump(const Duration(seconds: 30));
  });
}
