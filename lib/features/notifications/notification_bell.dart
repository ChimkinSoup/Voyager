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
/// something needs attention (muted = semi-important, pulsing accent =
/// important) and opens the unified notification popover on tap.
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
      width: 380,
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
                    child: NotificationUrgencyDot(
                      important: urgency == NotificationUrgency.important,
                      accent: widget.accent,
                      size: 13,
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
