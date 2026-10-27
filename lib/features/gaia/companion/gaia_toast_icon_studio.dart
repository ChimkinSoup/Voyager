import 'package:flutter/material.dart';
import 'package:voyager/features/gaia/companion/gaia_button.dart';
import 'package:voyager/features/gaia/companion/gaia_toast.dart';

/// Sample title and body for each mark's toast.
(String, String) _sample(GaiaToastMark mark) => switch (mark) {
  GaiaToastMark.done => ('Gaia is done', 'Your reply is ready.'),
  GaiaToastMark.question => (
    'Gaia has a question',
    'Which would you rather I do?',
  ),
  GaiaToastMark.error => (
    'Gaia ran into an error',
    'The agent stopped unexpectedly.',
  ),
  GaiaToastMark.info => (
    'An update from Gaia',
    'The chat is ready to pick up.',
  ),
};

/// Gaia's toast marks side by side, to replay their arrival.
class GaiaToastIconStudio extends StatefulWidget {
  const GaiaToastIconStudio({super.key});

  @override
  State<GaiaToastIconStudio> createState() => _GaiaToastIconStudioState();
}

class _GaiaToastIconStudioState extends State<GaiaToastIconStudio> {
  var _replay = 0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'White light, gold orbits, and a clear mark. Each settles after arrival.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 12),
        for (final mark in GaiaToastMark.values)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: Color.lerp(theme.colorScheme.surface, Colors.black, 0.5),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
              ),
              child: Row(
                children: [
                  GaiaToastOrbIcon(key: ValueKey((mark, _replay)), mark: mark),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _sample(mark).$1,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _sample(mark).$2,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: Colors.white.withValues(alpha: 0.85),
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        IntrinsicWidth(
          child: GaiaButton(
            label: 'Replay arrival',
            icon: Icons.replay,
            onPressed: () => setState(() => _replay++),
          ),
        ),
      ],
    );
  }
}
