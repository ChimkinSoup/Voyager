import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/core/platform/desktop_window.dart';
import 'package:window_manager/window_manager.dart';

/// Custom title bar for frameless desktop windows: drag region + window controls.
class DesktopWindowTitleBar extends StatefulWidget {
  const DesktopWindowTitleBar({super.key});

  static const height = 29.0;
  static const buttonWidth = 36.0;
  static const buttonHeight = 21.0;
  static const buttonRadius = 6.0;

  @override
  State<DesktopWindowTitleBar> createState() => _DesktopWindowTitleBarState();
}

class _DesktopWindowTitleBarState extends State<DesktopWindowTitleBar>
    with WindowListener {
  var _isMaximized = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _refreshMaximized();
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  Future<void> _refreshMaximized() async {
    final maximized = await windowManager.isMaximized();
    if (mounted) setState(() => _isMaximized = maximized);
  }

  Future<void> _toggleMaximize() async {
    if (_isMaximized) {
      await windowManager.unmaximize();
    } else {
      await windowManager.maximize();
    }
  }

  @override
  void onWindowMaximize() => setState(() => _isMaximized = true);

  @override
  void onWindowUnmaximize() => setState(() => _isMaximized = false);

  @override
  Widget build(BuildContext context) {
    if (!desktopWindowChromeActive) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final onSurface = theme.colorScheme.onSurface;

    return Material(
      color: theme.colorScheme.surface,
      child: SizedBox(
        height: DesktopWindowTitleBar.height,
        child: Row(
          children: [
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onDoubleTap: _toggleMaximize,
                child: DragToMoveArea(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Voyager',
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: onSurface.withValues(alpha: 0.72),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(left: 4, top: 4, bottom: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _WindowControlButton(
                    tooltip: 'Minimize',
                    icon: PhosphorIconsRegular.minus,
                    onPressed: windowManager.minimize,
                  ),
                  _WindowControlButton(
                    tooltip: _isMaximized ? 'Restore' : 'Maximize',
                    icon: _isMaximized
                        ? PhosphorIconsRegular.cards
                        : PhosphorIconsRegular.square,
                    onPressed: _toggleMaximize,
                  ),
                  _WindowControlButton(
                    tooltip: 'Close',
                    icon: PhosphorIconsRegular.x,
                    onPressed: windowManager.close,
                    isClose: true,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _WindowControlButton extends StatefulWidget {
  const _WindowControlButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.isClose = false,
  });

  final String tooltip;
  final IconData icon;
  final Future<void> Function() onPressed;
  final bool isClose;

  @override
  State<_WindowControlButton> createState() => _WindowControlButtonState();
}

class _WindowControlButtonState extends State<_WindowControlButton> {
  var _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Color? background;
    Color iconColor = theme.colorScheme.onSurface.withValues(alpha: 0.88);

    if (_hovered) {
      if (widget.isClose) {
        background = const Color(0xFFE81123);
        iconColor = Colors.white;
      } else {
        background = theme.colorScheme.onSurface.withValues(alpha: 0.08);
      }
    }

    final radius = BorderRadius.circular(DesktopWindowTitleBar.buttonRadius);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Semantics(
        button: true,
        label: widget.tooltip,
        child: MouseRegion(
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: ClipRRect(
            borderRadius: radius,
            child: Material(
              color: background ?? Colors.transparent,
              child: InkWell(
                onTap: () => widget.onPressed(),
                borderRadius: radius,
                hoverColor: Colors.transparent,
                splashColor: widget.isClose
                    ? Colors.white.withValues(alpha: 0.12)
                    : theme.colorScheme.onSurface.withValues(alpha: 0.12),
                child: SizedBox(
                  width: DesktopWindowTitleBar.buttonWidth,
                  height: DesktopWindowTitleBar.buttonHeight,
                  child: Icon(widget.icon, size: 12, color: iconColor),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
