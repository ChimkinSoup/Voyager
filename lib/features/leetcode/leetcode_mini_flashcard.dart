import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/core/constants/leetcode_constants.dart';
import 'package:voyager/core/theme/srs_mastery_color.dart';
import 'package:voyager/core/widgets/context_menu.dart';
import 'package:voyager/core/widgets/search_highlight_text.dart';
import 'package:voyager/core/widgets/tag_chip.dart';
import 'package:voyager/domain/models/leetcode_models.dart';
import 'package:voyager/domain/services/leetcode_srs_engine.dart';
import 'package:voyager/features/leetcode/leetcode_actions.dart';
import 'package:voyager/features/leetcode/leetcode_detail_view.dart';
import 'package:voyager/features/leetcode/leetcode_inline_code.dart';
import 'package:voyager/features/study/study_flip_card.dart';

/// What the grid's search matches on the tile's front face: everything the
/// front actually shows.
String leetCodeFrontSearchText(LeetCodeProblem problem) => [
  problem.questionFrontendId ?? '',
  problem.title,
  problem.description ?? '',
  ...problem.tags,
].join(' ');

/// …and on its back. Every solution counts, not just the one the tile has room
/// to preview: searching for the approach you wrote down should find the
/// problem you wrote it on, and the back says how many others are behind it.
///
/// Code and notes are deliberately out — they appear on no face at all, so
/// matching them would turn up tiles with nothing in them resembling the
/// query.
String leetCodeBackSearchText(LeetCodeProblem problem) => [
  for (final solution in problem.solutions) ...[
    solution.algorithm,
    solution.timeComplexity ?? '',
    solution.spaceComplexity ?? '',
    solution.explanation,
  ],
].join(' ');

/// Whether [problem]'s only hit for [keywords] is on its back. The grid shows
/// fronts, so those tiles start turned around instead.
bool leetCodeMatchesBackOnly(LeetCodeProblem problem, List<String> keywords) {
  bool matches(String text) {
    final lower = text.toLowerCase();
    return keywords.any(
      (k) => k.trim().isNotEmpty && lower.contains(k.trim().toLowerCase()),
    );
  }

  return !matches(leetCodeFrontSearchText(problem)) &&
      matches(leetCodeBackSearchText(problem));
}

/// One problem in the Review Deck's grid: a miniature version of the
/// full-size flashcard that flips on tap, ringed in its SRS mastery color,
/// with the days until its next review counted down in the corner.
///
/// Which face it rests on is the caller's to own ([showBack]/[onFlipped]) —
/// the grid recycles tiles as they scroll, and a flip the user performed has
/// to outlive the widget that was showing it.
class LeetCodeMiniFlashcard extends ConsumerStatefulWidget {
  const LeetCodeMiniFlashcard({
    super.key,
    required this.problem,
    required this.showBack,
    required this.onFlipped,
    this.keywords = const [],
    this.now,
  });

  final LeetCodeProblem problem;

  /// Which face the tile shows right now.
  final bool showBack;

  /// Fires with the face the tile came to rest on once a tap-flip finishes.
  final ValueChanged<bool> onFlipped;

  /// The deck's active search terms, highlighted in the preview.
  final List<String> keywords;

  /// Overrides "today" for the review countdown. Tests only.
  final DateTime? now;

  @override
  ConsumerState<LeetCodeMiniFlashcard> createState() =>
      _LeetCodeMiniFlashcardState();
}

class _LeetCodeMiniFlashcardState extends ConsumerState<LeetCodeMiniFlashcard> {
  final _tileKey = GlobalKey<ContextMenuRegionState>();

  /// The detail view zooms out of whatever was tapped, so the tile hands it
  /// its own on-screen rect.
  void _openDetail() {
    final box = _tileKey.currentContext?.findRenderObject() as RenderBox?;
    final rect = box == null
        ? Offset.zero & MediaQuery.sizeOf(context)
        : box.localToGlobal(Offset.zero) & box.size;
    openLeetCodeDetailView(context, widget.problem, rect);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final problem = widget.problem;
    final mastery = srsMasteryColor(
      reviewCount: problem.reviewCount,
      interval: problem.interval,
      scheme: theme.colorScheme,
    );

    return ContextMenuRegion(
      key: _tileKey,
      itemsBuilder: () => leetCodeProblemMenuItems(
        context: context,
        ref: ref,
        problem: problem,
        onOpenDetail: _openDetail,
      ),
      child: SizedBox.expand(
        child: StudyFlipCard(
          initiallyShowingBack: widget.showBack,
          onFlipChanged: widget.onFlipped,
          front: _front(context, mastery),
          back: _back(context, mastery),
        ),
      ),
    );
  }

  /// The shell both faces share, so the tile keeps its ring and its shape as
  /// it turns over.
  Widget _face(BuildContext context, Color mastery, Widget child) {
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      // The card idiom's own hairline outline, recolored — that outline is
      // where a problem reports how well it's known.
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: mastery, width: 1.5),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
        child: child,
      ),
    );
  }

  Widget _front(BuildContext context, Color mastery) {
    final theme = Theme.of(context);
    final problem = widget.problem;
    final difficultyColor = colorForLeetCodeDifficulty(problem.difficulty);
    final daysUntilDue = leetCodeDaysUntilDue(problem, now: widget.now);
    final description = problem.description?.trim();
    final hasDescription = description != null && description.isNotEmpty;

    return _face(
      context,
      mastery,
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  problem.questionFrontendId == null
                      ? ''
                      : '#${problem.questionFrontendId}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
                  ),
                ),
              ),
              // Difficulty is a permanent property of the problem, so it sits
              // in the same corner as on the full-size card — the ring around
              // the tile is the part that changes as you study.
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: difficultyColor.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(5),
                ),
                child: Text(
                  labelForLeetCodeDifficulty(problem.difficulty),
                  style: theme.textTheme.labelSmall?.copyWith(
                    fontSize: 9,
                    height: 1.2,
                    color: difficultyColor,
                  ),
                ),
              ),
            ],
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 4),
                Center(
                  child: searchHighlightedText(
                    problem.title,
                    style:
                        theme.textTheme.titleMedium ??
                        const TextStyle(fontSize: 16),
                    keywords: widget.keywords,
                    maxLines: hasDescription ? 2 : 4,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (hasDescription) ...[
                  const SizedBox(height: 6),
                  Expanded(
                    child: LeetCodeProseText(
                      description,
                      style:
                          theme.textTheme.labelSmall?.copyWith(
                            fontSize: 10,
                            height: 1.3,
                            color: theme.colorScheme.onSurface.withValues(
                              alpha: 0.55,
                            ),
                          ) ??
                          const TextStyle(fontSize: 10),
                      language: problem.codeLanguage,
                      keywords: widget.keywords,
                      tagPills: true,
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ] else
                  const Spacer(),
              ],
            ),
          ),
          _footer(
            context,
            daysUntilDue: daysUntilDue,
            child: problem.tags.isEmpty
                ? const SizedBox.shrink()
                : ClipRect(
                    child: Wrap(
                      spacing: 4,
                      runSpacing: 4,
                      clipBehavior: Clip.hardEdge,
                      children: [
                        for (final tag in problem.tags.take(2))
                          TagChip(tag: tag),
                        if (problem.tags.length > 2)
                          Text(
                            '+${problem.tags.length - 2}',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.onSurface.withValues(
                                alpha: 0.4,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _back(BuildContext context, Color mastery) {
    final theme = Theme.of(context);
    final problem = widget.problem;
    // The tile previews the first solution only — at this size a second one
    // would be a few illegible words rather than a second answer. The count
    // in the footer is what says the others are there; the card opens onto
    // all of them.
    final solution = problem.primarySolution;
    // The approach is the answer to the question the front asks; the
    // explanation stands in when no approach was written down.
    final body = (solution?.algorithm ?? '').trim().isNotEmpty
        ? solution!.algorithm
        : solution?.explanation ?? '';
    final otherSolutions = problem.solutions.length - 1;
    final complexity = [
      if (solution?.timeComplexity != null) 'T ${solution!.timeComplexity}',
      if (solution?.spaceComplexity != null) 'S ${solution!.spaceComplexity}',
    ].join('  ·  ');

    return _face(
      context,
      mastery,
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Center(
              child: body.trim().isEmpty
                  ? Text(
                      'No approach written',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.35,
                        ),
                      ),
                    )
                  : LeetCodeProseText(
                      searchSnippet(body, keywords: widget.keywords),
                      style:
                          theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.primary,
                          ) ??
                          const TextStyle(fontSize: 12),
                      language: solution?.codeLanguage ?? problem.codeLanguage,
                      keywords: widget.keywords,
                      tagPills: true,
                      maxLines: 6,
                      overflow: TextOverflow.ellipsis,
                    ),
            ),
          ),
          _footer(
            context,
            // The countdown belongs to the side that asks the question, same
            // as on a study card.
            daysUntilDue: null,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    complexity,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontSize: 10,
                      color: theme.colorScheme.onSurface.withValues(
                        alpha: 0.45,
                      ),
                    ),
                  ),
                ),
                if (otherSolutions > 0)
                  Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: Semantics(
                      // "+2 more" alone doesn't say more of what.
                      label:
                          '$otherSolutions more '
                          'solution${otherSolutions == 1 ? '' : 's'}',
                      excludeSemantics: true,
                      child: Text(
                        '+$otherSolutions more',
                        maxLines: 1,
                        style: theme.textTheme.labelSmall?.copyWith(
                          fontSize: 10,
                          color: theme.colorScheme.primary.withValues(
                            alpha: 0.7,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// The strip along the bottom of a face. Its height is fixed and identical
  /// on both, so the text block above doesn't shift as the tile turns over.
  Widget _footer(
    BuildContext context, {
    required Widget child,
    required int? daysUntilDue,
  }) {
    final theme = Theme.of(context);
    return SizedBox(
      height: 20,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(child: child),
          if (daysUntilDue != null) ...[
            const SizedBox(width: 4),
            Semantics(
              // On its own the number reads as "3"; say what it counts.
              label: daysUntilDue == 0
                  ? 'Due today'
                  : 'Due in $daysUntilDue day${daysUntilDue == 1 ? '' : 's'}',
              excludeSemantics: true,
              child: Text(
                '$daysUntilDue',
                style: theme.textTheme.labelSmall?.copyWith(
                  fontSize: 10,
                  height: 1.2,
                  color: daysUntilDue == 0
                      ? theme.colorScheme.error.withValues(alpha: 0.55)
                      : theme.colorScheme.onSurface.withValues(alpha: 0.45),
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
