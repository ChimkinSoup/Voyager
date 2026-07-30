import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

/// Small badge marking why a row inside the notification popover is
/// contributing to the nav-rail bell's badge — a filled seal for important,
/// a filled dot for urgent (semi-important). Mirrors the styling used by
/// [NotificationBell] so the popover visually explains the bell's state.
class NotificationUrgencyDot extends StatelessWidget {
  const NotificationUrgencyDot({
    super.key,
    required this.important,
    required this.accent,
    this.size = 15,
  });

  final bool important;
  final Color accent;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Icon(
      important ? PhosphorIconsFill.seal : PhosphorIconsFill.circle,
      size: size,
      color: accent,
    );
  }
}
