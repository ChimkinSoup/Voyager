import 'dart:async';

import 'package:flutter/material.dart';
import 'package:voyager/core/platform/desktop_window.dart';
import 'package:voyager/core/widgets/desktop_window_title_bar.dart';

/// Wraps app content with an auto-hiding title bar on frameless desktop.
///
/// The title bar overlays the content from the top rather than pushing it
/// down, so app content always fills the full window.
class DesktopWindowFrame extends StatefulWidget {
  const DesktopWindowFrame({super.key, required this.child});

  final Widget child;

  @override
  State<DesktopWindowFrame> createState() => _DesktopWindowFrameState();
}

class _DesktopWindowFrameState extends State<DesktopWindowFrame>
    with SingleTickerProviderStateMixin {
  static const _hoverTriggerHeight = 10.0;
  static const _animDuration = Duration(milliseconds: 150);
  static const _hideDelay = Duration(milliseconds: 175);

  late final AnimationController _controller;
  late final Animation<double> _slideAnim;
  var _barVisible = false;
  Timer? _hideTimer;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: _animDuration);
    _slideAnim = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _reveal() {
    _hideTimer?.cancel();
    if (!_barVisible) {
      setState(() => _barVisible = true);
      _controller.forward();
    }
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(_hideDelay, () {
      if (!mounted) return;
      _controller.reverse().whenComplete(() {
        if (mounted) setState(() => _barVisible = false);
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!desktopWindowChromeActive) return widget.child;

    return Stack(
      children: [
        // Content always fills the full window — never displaced.
        Positioned.fill(child: widget.child),

        // Title bar slides in from above, overlapping content.
        Positioned(
          left: 0,
          right: 0,
          top: 0,
          child: AnimatedBuilder(
            animation: _slideAnim,
            builder: (context, child) {
              final offset = -(1.0 - _slideAnim.value) *
                  DesktopWindowTitleBar.height;
              return Transform.translate(
                offset: Offset(0, offset),
                child: child,
              );
            },
            child: MouseRegion(
              onEnter: (_) => _reveal(),
              onExit: (_) => _scheduleHide(),
              child: IgnorePointer(
                ignoring: !_barVisible,
                child: const DesktopWindowTitleBar(),
              ),
            ),
          ),
        ),

        // Invisible trigger strip — only present when bar is fully hidden.
        if (!_barVisible)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: _hoverTriggerHeight,
            child: MouseRegion(
              opaque: true,
              onEnter: (_) => _reveal(),
              child: const ColoredBox(color: Colors.transparent),
            ),
          ),
      ],
    );
  }
}
