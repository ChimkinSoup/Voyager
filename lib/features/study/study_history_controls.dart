import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

/// The back/forward pair a session shows in its header, next to the counter.
/// A null callback greys its button out, which is how a session says it has
/// nothing left in that direction — the keys ([StudyKeyboardShortcuts]) go
/// dead at exactly the same moment.
class StudyHistoryControls extends StatelessWidget {
  const StudyHistoryControls({super.key, this.onUndo, this.onRedo});

  final VoidCallback? onUndo;
  final VoidCallback? onRedo;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          onPressed: onUndo,
          tooltip: 'Previous card (U)',
          icon: const Icon(PhosphorIconsRegular.arrowUUpLeft),
        ),
        IconButton(
          onPressed: onRedo,
          tooltip: 'Redo (R)',
          icon: const Icon(PhosphorIconsRegular.arrowUUpRight),
        ),
      ],
    );
  }
}
