import 'package:flutter/material.dart';

/// The header's offline icon, shown once the next tier's API stops
/// answering, as the shell's badge is once sync does. A click checks again.
class GaiaOfflineIcon extends StatelessWidget {
  const GaiaOfflineIcon({
    super.key,
    required this.cli,
    required this.retrying,
    required this.onRetry,
  });

  /// The CLI the next message runs on, for the tooltip.
  final String? cli;

  /// True while a check asked for by a click is out.
  final bool retrying;

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(right: 6),
    child: Tooltip(
      message:
          'Offline — ${cli ?? 'Gaia'} can\'t reach its servers. '
          'Click to check again.',
      child: InkWell(
        onTap: retrying ? null : onRetry,
        customBorder: const CircleBorder(),
        child: Padding(
          padding: const EdgeInsets.all(4),
          // Dimmed while the check is out, so a click visibly does
          // something even when the answer is "still offline".
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 120),
            opacity: retrying ? 0.4 : 1,
            child: Icon(
              Icons.wifi_off,
              size: 18,
              color: Theme.of(context).colorScheme.error,
            ),
          ),
        ),
      ),
    ),
  );
}
