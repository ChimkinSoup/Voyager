import 'package:flutter/material.dart';
import 'package:voyager/core/constants/leetcode_constants.dart';
import 'package:voyager/core/widgets/tag_chip.dart';
import 'package:voyager/domain/models/leetcode_models.dart';
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
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: problems.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) => _CompletionRow(problem: problems[index]),
    );
  }
}

class _CompletionRow extends StatefulWidget {
  const _CompletionRow({required this.problem});

  final LeetCodeProblem problem;

  @override
  State<_CompletionRow> createState() => _CompletionRowState();
}

class _CompletionRowState extends State<_CompletionRow> {
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
    return Material(
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
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: colorForLeetCodeDifficulty(problem.difficulty)
                                .withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            labelForLeetCodeDifficulty(problem.difficulty),
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: colorForLeetCodeDifficulty(problem.difficulty),
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
    );
  }
}
