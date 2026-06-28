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
    return Stack(
      fit: StackFit.expand,
      children: [
        for (var i = 0; i < children.length; i++)
          Positioned.fill(
            child: IgnorePointer(
              ignoring: i != currentIndex,
              child: AnimatedOpacity(
                opacity: i == currentIndex ? 1 : 0,
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeInOut,
                child: TickerMode(
                  enabled: i == currentIndex,
                  child: children[i],
                ),
              ),
            ),
          ),
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
