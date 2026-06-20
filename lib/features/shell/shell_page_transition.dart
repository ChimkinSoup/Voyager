import 'package:go_router/go_router.dart';
import 'package:flutter/material.dart';

/// Keeps all shell branches mounted and switches instantly.
class ShellBranchContainer extends StatelessWidget {
  const ShellBranchContainer({
    super.key,
    required this.currentIndex,
    required this.children,
  });

  final int currentIndex;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return IndexedStack(
      index: currentIndex,
      sizing: StackFit.expand,
      children: [
        for (var i = 0; i < children.length; i++)
          TickerMode(enabled: i == currentIndex, child: children[i]),
      ],
    );
  }
}

ShellNavigationContainerBuilder shellBranchContainerBuilder =
    (
      BuildContext context,
      StatefulNavigationShell navigationShell,
      List<Widget> children,
    ) {
      return ShellBranchContainer(
        currentIndex: navigationShell.currentIndex,
        children: children,
      );
    };
