import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/core/constants/leetcode_constants.dart';
import 'package:voyager/core/widgets/context_menu.dart';
import 'package:voyager/core/widgets/tag_chip.dart';
import 'package:voyager/domain/models/leetcode_models.dart';
import 'package:voyager/features/leetcode/leetcode_actions.dart';
import 'package:voyager/features/leetcode/leetcode_detail_view.dart';

/// Chronological feed of tracked problems. Tapping a row opens the detail
/// view, zooming out from that row's on-screen position.
class LeetCodeRecentCompletions extends StatelessWidget {
  const LeetCodeRecentCompletions({super.key, required this.problems});

  final List<LeetCodeProblem> problems;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (problems.isEmpty) {
      return Center(
        child: Text(
          'No problems tracked yet',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }
    // Dashboard-only: the same question tracked twice is worth a quiet word
    // here, but not while the user is mid-review in the deck or a session.
    final duplicateCounts = leetCodeDuplicateCounts(problems);
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: problems.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final problem = problems[index];
        return _CompletionRow(
          problem: problem,
          duplicateCount: duplicateCounts[leetCodeIdentityKey(problem)],
        );
      },
    );
  }
}

class _CompletionRow extends ConsumerStatefulWidget {
  const _CompletionRow({required this.problem, this.duplicateCount});

  final LeetCodeProblem problem;

  /// How many tracked problems share this one's identity, or null when it is
  /// the only copy. Always at least 2 when set.
  final int? duplicateCount;

  @override
  ConsumerState<_CompletionRow> createState() => _CompletionRowState();
}

class _CompletionRowState extends ConsumerState<_CompletionRow> {
  final _key = GlobalKey();

  void _openDetail() {
    final box = _key.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final rect = box.localToGlobal(Offset.zero) & box.size;
    openLeetCodeDetailView(context, widget.problem, rect);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final problem = widget.problem;
    return ContextMenuRegion(
      // The review deck's card menu, verbatim — see
      // [leetCodeProblemMenuItems]. Built on right-click, since a feed can be
      // hundreds of rows long and none of these entries is looked at until one
      // of them is clicked.
      itemsBuilder: () => leetCodeProblemMenuItems(
        context: context,
        ref: ref,
        problem: problem,
        onOpenDetail: _openDetail,
      ),
      child: Material(
        key: _key,
        color: Colors.transparent,
        child: InkWell(
          onTap: _openDetail,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              problem.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodyLarge,
                            ),
                          ),
                          if (widget.duplicateCount != null) ...[
                            const SizedBox(width: 6),
                            _DuplicateMarker(count: widget.duplicateCount!),
                          ],
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: colorForLeetCodeDifficulty(
                                problem.difficulty,
                              ).withValues(alpha: 0.14),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              labelForLeetCodeDifficulty(problem.difficulty),
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: colorForLeetCodeDifficulty(
                                  problem.difficulty,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      if (problem.tags.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            for (final tag in problem.tags) TagChip(tag: tag),
                          ],
                        ),
                      ],
                    ],
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

/// The faint "you've tracked this one more than once" mark on a feed row.
///
/// Deliberately inert — no tap target. It carries the theme's error red at
/// low alpha so it reads as something to look at without shouting, and
/// explains itself on hover.
class _DuplicateMarker extends StatelessWidget {
  const _DuplicateMarker({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Tooltip(
      message: 'Tracked $count times — possible duplicate',
      child: Icon(
        PhosphorIconsRegular.copy,
        size: 13,
        color: theme.colorScheme.error.withValues(alpha: 0.45),
      ),
    );
  }
}
