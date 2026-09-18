import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/features/hotkeys/floaters/floater_controller.dart';

/// A floater's icon, in the accent color. Clicking it opens the app on the
/// floater's page, with the capture carried over.
class FloaterAppIcon extends ConsumerWidget {
  const FloaterAppIcon(this.icon, {super.key, required this.size});

  final IconData icon;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Semantics(
      button: true,
      label: 'Open in app',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => unawaited(ref.read(floaterControllerProvider).openApp()),
          child: Icon(
            icon,
            size: size,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
      ),
    );
  }
}
