import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/widgets/contextual_popover.dart';
import 'package:voyager/core/widgets/notification_urgency_dot.dart';
import 'package:voyager/domain/models/notification_models.dart';
import 'package:voyager/features/notifications/notification_inbox_popover.dart';

const _bellWidth = 68.0;
const _bellHeight = 56.0;

/// The nav rail's notification entry point: a tray icon that grows a dot when
/// something needs attention (muted = semi-important, accent = important) and
/// opens the unified notification popover on tap.
class NotificationBell extends ConsumerStatefulWidget {
  const NotificationBell({super.key, required this.accent});

  final Color accent;

  @override
  ConsumerState<NotificationBell> createState() => _NotificationBellState();
}

class _NotificationBellState extends ConsumerState<NotificationBell> {
  final GlobalKey _anchorKey = GlobalKey();
  bool _hovered = false;

  void _openPopover() {
    final box = _anchorKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final topLeft = box.localToGlobal(Offset.zero);
    showContextualPopoverAt<void>(
      context: context,
      targetRect: topLeft & box.size,
      // The bell is in the compact status strip too, where the window can be
      // narrower than the panel wants to be. Give up width rather than hang
      // off the edge of the screen — the popover is laid out at exactly the
      // width it is handed.
      width: math.min(
        kNotificationPopoverWidth,
        MediaQuery.sizeOf(context).width - 16,
      ),
      accentColor: widget.accent,
      builder: (ctx) => const NotificationInboxPopover(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final urgency = ref.watch(notificationBadgeStateProvider);
    final colorScheme = Theme.of(context).colorScheme;

    return Semantics(
      button: true,
      label: 'Notifications',
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          onTap: _openPopover,
          onHover: (hovered) {
            if (_hovered != hovered) setState(() => _hovered = hovered);
          },
          borderRadius: BorderRadius.circular(18),
          hoverColor: Colors.transparent,
          splashColor: Colors.transparent,
          highlightColor: Colors.transparent,
          child: Container(
            key: _anchorKey,
            width: _bellWidth,
            height: _bellHeight,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: _hovered
                  ? colorScheme.onSurface.withValues(alpha: 0.10)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(18),
            ),
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Icon(PhosphorIconsRegular.tray, size: 24, color: colorScheme.onSurface),
                if (urgency != null)
                  Positioned(
                    top: -1,
                    right: -1,
                    child: _GlowDot(
                      important: urgency == NotificationUrgency.important,
                      accent: widget.accent,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The bell's badge: the same dot the popover rows show, wrapped in a soft
/// accent glow. Only the bell carries the glow — the popover's per-row dots
/// are bare.
class _GlowDot extends StatelessWidget {
  const _GlowDot({required this.important, required this.accent});

  final bool important;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(color: accent, blurRadius: 12, spreadRadius: 3),
        ],
      ),
      child: NotificationUrgencyDot(
        important: important,
        accent: accent,
        size: 13,
      ),
    );
  }
}
