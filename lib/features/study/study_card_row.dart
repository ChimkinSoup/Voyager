import 'package:flutter/material.dart';
import 'package:voyager/domain/models/study_models.dart';
import 'package:voyager/features/study/study_flip_card.dart';
import 'package:voyager/features/study/study_rich_text.dart';

/// Color coding for the small SRS mastery dot on each card row: grey for a
/// never-reviewed card, amber while still in the sub-day "learning" phase,
/// blue once it holds a multi-day interval, green once it's comfortably
/// spaced out. Mirrors the interval bands most SRS tools use to communicate
/// progress at a glance.
Color studyMasteryColor(StudyCard card, ColorScheme scheme) {
  if (card.isNew) return scheme.onSurface.withValues(alpha: 0.25);
  if (card.isLearning) return const Color(0xFFE0A63A);
  if (card.interval < 21) return const Color(0xFF5C8BE0);
  return const Color(0xFF4CAF7D);
}

/// One row in the Deck Workbench's card roster: a tap-to-flip preview of the
/// card's front/back, an SRS mastery dot, and (in multi-select mode) a
/// checkbox that doesn't intercept taps meant for the flip preview.
class StudyCardRow extends StatelessWidget {
  const StudyCardRow({
    super.key,
    required this.card,
    required this.multiSelectEnabled,
    required this.selected,
    required this.onToggleSelected,
    required this.onLongPress,
  });

  final StudyCard card;
  final bool multiSelectEnabled;
  final bool selected;
  final ValueChanged<bool> onToggleSelected;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              if (multiSelectEnabled) ...[
                Checkbox(value: selected, onChanged: (v) => onToggleSelected(v ?? false)),
                const SizedBox(width: 4),
              ],
              Container(
                width: 8,
                height: 8,
                margin: const EdgeInsets.only(right: 12),
                decoration: BoxDecoration(
                  color: studyMasteryColor(card, theme.colorScheme),
                  shape: BoxShape.circle,
                ),
              ),
              Expanded(
                child: SizedBox(
                  height: 44,
                  child: StudyFlipCard(
                    front: Align(
                      alignment: Alignment.centerLeft,
                      child: StudyRichText(
                        card.frontText,
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                    back: Align(
                      alignment: Alignment.centerLeft,
                      child: StudyRichText(
                        card.backText,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.primary,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
