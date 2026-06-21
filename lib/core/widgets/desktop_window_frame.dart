import 'package:flutter/material.dart';
import 'package:voyager/core/platform/desktop_window.dart';
import 'package:voyager/core/widgets/desktop_window_title_bar.dart';

/// Wraps app content with a custom draggable title bar on frameless desktop.
class DesktopWindowFrame extends StatefulWidget {
  const DesktopWindowFrame({super.key, required this.child});

  final Widget child;

  @override
  State<DesktopWindowFrame> createState() => _DesktopWindowFrameState();
}

class _DesktopWindowFrameState extends State<DesktopWindowFrame> {
  static const _hoverTriggerHeight = 6.0;
  static const _animationDuration = Duration(milliseconds: 140);

  var _showTitleBar = false;

  void _setTitleBarVisible(bool visible) {
    if (_showTitleBar == visible) return;
    setState(() => _showTitleBar = visible);
  }

  @override
  Widget build(BuildContext context) {
    if (!desktopWindowChromeActive) return widget.child;

    return SizedBox.expand(
      child: Stack(
        clipBehavior: Clip.hardEdge,
        children: [
          Positioned.fill(child: widget.child),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: _hoverTriggerHeight,
            child: MouseRegion(
              opaque: false,
              onEnter: (_) => _setTitleBarVisible(true),
              child: const SizedBox.expand(),
            ),
          ),
          AnimatedPositioned(
            duration: _animationDuration,
            curve: Curves.easeOutCubic,
            top: _showTitleBar ? 0 : -DesktopWindowTitleBar.height,
            left: 0,
            right: 0,
            height: DesktopWindowTitleBar.height,
            child: MouseRegion(
              onEnter: (_) => _setTitleBarVisible(true),
              onExit: (_) => _setTitleBarVisible(false),
              child: IgnorePointer(
                ignoring: !_showTitleBar,
                child: AnimatedOpacity(
                  duration: _animationDuration,
                  curve: Curves.easeOut,
                  opacity: _showTitleBar ? 1 : 0,
                  child: const DesktopWindowTitleBar(),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
