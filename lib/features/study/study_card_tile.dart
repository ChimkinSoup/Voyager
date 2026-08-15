import 'package:flutter/material.dart';
import 'package:voyager/core/theme/srs_mastery_color.dart';
import 'package:voyager/core/widgets/context_menu.dart';
import 'package:voyager/core/widgets/search_highlight_text.dart';
import 'package:voyager/domain/models/study_models.dart';
import 'package:voyager/domain/services/study_srs_engine.dart';
import 'package:voyager/features/study/study_actions.dart';
import 'package:voyager/features/study/study_flip_card.dart';
import 'package:voyager/features/study/study_rich_text.dart';

/// This card's mastery color, drawn as the border around its tile in the deck
/// grid. The bands themselves live in [srsMasteryColor], shared with the
/// LeetCode Review Deck's grid.
Color studyMasteryColor(StudyCard card, ColorScheme scheme) => srsMasteryColor(
  reviewCount: card.reviewCount,
  interval: card.interval,
  scheme: scheme,
);

/// Whether [card]'s only hit for [keywords] is on its back. The grid shows
/// fronts, so a back-only hit would otherwise render as a tile with nothing
/// in it resembling the query — those tiles start turned around instead.
bool studyCardMatchesBackOnly(StudyCard card, List<String> keywords) {
  bool matches(String text) {
    final lower = text.toLowerCase();
    return keywords.any(
      (k) => k.trim().isNotEmpty && lower.contains(k.trim().toLowerCase()),
    );
  }

  return !matches(card.frontText) && matches(card.backText);
}

/// One card in the Deck Workbench's grid: a miniature flashcard that flips on
/// tap, ringed in its SRS mastery color, with the days until its next review
/// counted down along the bottom of the front face.
///
/// Which face it rests on is the caller's to own ([showBack]/[onFlipped]) —
/// the grid recycles tiles as they scroll, and a flip the user performed has
/// to outlive the widget that was showing it.
class StudyCardTile extends StatelessWidget {
  const StudyCardTile({
    super.key,
    required this.card,
    required this.showBack,
    required this.onFlipped,
    required this.multiSelectEnabled,
    required this.selected,
    required this.onToggleSelected,
    required this.onLongPress,
    required this.onEdit,
    required this.onReverse,
    required this.onResetProgress,
    required this.onDelete,
    this.keywords = const [],
    this.now,
  });

  final StudyCard card;

  /// Which face the tile shows right now.
  final bool showBack;

  /// Fires with the face the tile came to rest on once a tap-flip finishes.
  final ValueChanged<bool> onFlipped;

  final bool multiSelectEnabled;
  final bool selected;
  final ValueChanged<bool> onToggleSelected;
  final VoidCallback onLongPress;

  final VoidCallback onEdit;
  final VoidCallback onReverse;
  final VoidCallback onResetProgress;
  final VoidCallback onDelete;

  /// The workbench's active search terms, highlighted in the preview.
  final List<String> keywords;

  /// Overrides "today" for the review countdown. Tests only.
  final DateTime? now;

  /// Windows long text onto the match, except when the card holds LaTeX:
  /// [StudyRichText] pairs `$` delimiters, and a cut between a pair would
  /// render the source verbatim instead of as math.
  String _preview(String text) =>
      text.contains(r'$') ? text : searchSnippet(text, keywords: keywords);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mastery = studyMasteryColor(card, theme.colorScheme);
    return ContextMenuRegion(
      itemsBuilder: () => studyCardMenuItems(
        card: card,
        onEdit: onEdit,
        onReverse: onReverse,
        onResetProgress: onResetProgress,
        onDelete: onDelete,
      ),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: multiSelectEnabled ? () => onToggleSelected(!selected) : null,
        onLongPress: onLongPress,
        child: Stack(
          children: [
            StudyFlipCard(
              // In multi-select a tap belongs to the checkbox, not the flip.
              tapEnabled: !multiSelectEnabled,
              initiallyShowingBack: showBack,
              onFlipChanged: onFlipped,
              front: _face(
                context,
                text: card.frontText,
                mastery: mastery,
                // The countdown is a property of the question you're about to
                // be asked, so it only belongs on the side that asks it.
                daysUntilDue: studyDaysUntilDue(card, now: now),
              ),
              back: _face(
                context,
                text: card.backText,
                mastery: mastery,
                textColor: theme.colorScheme.primary,
              ),
            ),
            if (multiSelectEnabled)
              Positioned(
                top: 2,
                left: 2,
                child: Checkbox(
                  value: selected,
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  onChanged: (v) => onToggleSelected(v ?? false),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// One side of the miniature card. Both faces carry the mastery border, so
  /// a flipped card still reports how well it's known.
  Widget _face(
    BuildContext context, {
    required String text,
    required Color mastery,
    Color? textColor,
    int? daysUntilDue,
  }) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      // The card idiom's own hairline outline, recolored — that outline is
      // where a card now reports its mastery, in place of the roster's dot.
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: mastery, width: 1.5),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 10, 10, 6),
        child: Column(
          children: [
            Expanded(
              child: Center(
                child: StudyRichText(
                  _preview(text),
                  keywords: keywords,
                  textAlign: TextAlign.center,
                  maxLines: 5,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(color: textColor),
                ),
              ),
            ),
            // Reserved on both faces so the text block doesn't shift as the
            // card turns over.
            SizedBox(
              height: 14,
              child: daysUntilDue == null
                  ? null
                  : Text(
                      '$daysUntilDue',
                      style: theme.textTheme.labelSmall?.copyWith(
                        fontSize: 10,
                        height: 1.2,
                        color: daysUntilDue == 0
                            ? theme.colorScheme.error.withValues(alpha: 0.55)
                            : theme.colorScheme.onSurface.withValues(
                                alpha: 0.3,
                              ),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
