import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:voyager/core/constants/leetcode_constants.dart';
import 'package:voyager/core/widgets/tag_chip.dart';
import 'package:voyager/domain/models/leetcode_models.dart';
import 'package:voyager/features/leetcode/leetcode_code_field.dart';
import 'package:voyager/features/leetcode/leetcode_track_modal.dart';

/// Opens the LeetCode problem's detail view with a small "camera zoom"
/// animation growing from [anchorRect] (the tapped card/row's on-screen
/// rect) to fill the screen. Closing reverses the same animation, leaving
/// the caller exactly where it was.
Future<void> openLeetCodeDetailView(
  BuildContext context,
  LeetCodeProblem problem,
  Rect anchorRect,
) {
  return Navigator.of(context, rootNavigator: true).push(
    PageRouteBuilder<void>(
      opaque: false,
      barrierColor: Colors.transparent,
      barrierDismissible: false,
      transitionDuration: Duration.zero,
      reverseTransitionDuration: Duration.zero,
      pageBuilder: (context, animation, secondaryAnimation) =>
          _LeetCodeDetailOverlay(problem: problem, anchorRect: anchorRect),
    ),
  );
}

class _LeetCodeDetailOverlay extends StatefulWidget {
  const _LeetCodeDetailOverlay({required this.problem, required this.anchorRect});

  final LeetCodeProblem problem;
  final Rect anchorRect;

  @override
  State<_LeetCodeDetailOverlay> createState() => _LeetCodeDetailOverlayState();
}

class _LeetCodeDetailOverlayState extends State<_LeetCodeDetailOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _controller.forward();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _close() async {
    await _controller.reverse();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final fullScreenRect = Offset.zero & size;

    return Material(
      color: Colors.black.withValues(alpha: 0.001),
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          final t = Curves.easeInOutCubic.transform(_controller.value);
          final rect = Rect.lerp(widget.anchorRect, fullScreenRect, t)!;
          return Stack(
            children: [
              Positioned.fill(
                child: IgnorePointer(
                  child: Container(color: Colors.black.withValues(alpha: 0.5 * t)),
                ),
              ),
              Positioned.fromRect(
                rect: rect,
                child: Opacity(
                  opacity: t,
                  child: child,
                ),
              ),
            ],
          );
        },
        child: _DetailCard(problem: widget.problem, onClose: _close),
      ),
    );
  }
}

class _DetailCard extends StatelessWidget {
  const _DetailCard({required this.problem, required this.onClose});

  final LeetCodeProblem problem;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surface,
      elevation: 8,
      borderRadius: BorderRadius.circular(20),
      clipBehavior: Clip.antiAlias,
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${problem.questionFrontendId ?? ''} ${problem.title}'.trim(),
                      style: theme.textTheme.titleLarge,
                    ),
                  ),
                  Consumer(
                    builder: (context, ref, _) => IconButton(
                      onPressed: () async {
                        final saved = await showLeetCodeTrackModal(
                          context,
                          ref,
                          existing: problem,
                        );
                        // The card above still shows the pre-edit snapshot,
                        // so close it too once saved rather than leave stale
                        // data on screen — the dashboard behind it already
                        // has the fresh data via the invalidated provider.
                        if (saved) onClose();
                      },
                      icon: const Icon(PhosphorIconsRegular.pencilSimple, size: 20),
                      tooltip: 'Edit',
                    ),
                  ),
                  IconButton(
                    onPressed: onClose,
                    icon: const Icon(PhosphorIconsRegular.x, size: 20),
                    tooltip: 'Close',
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
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
              if (problem.tags.isNotEmpty) ...[
                const SizedBox(height: 12),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [for (final tag in problem.tags) TagChip(tag: tag)],
                ),
              ],
              if (problem.algorithm.isNotEmpty) ...[
                const SizedBox(height: 20),
                Text('Algorithm', style: theme.textTheme.labelLarge),
                const SizedBox(height: 6),
                Text(problem.algorithm, style: theme.textTheme.bodyMedium),
              ],
              if (problem.timeComplexity != null || problem.spaceComplexity != null) ...[
                const SizedBox(height: 16),
                Row(
                  children: [
                    if (problem.timeComplexity != null)
                      Expanded(
                        child: _ComplexityTile(
                          label: 'Time',
                          value: problem.timeComplexity!,
                        ),
                      ),
                    if (problem.spaceComplexity != null)
                      Expanded(
                        child: _ComplexityTile(
                          label: 'Space',
                          value: problem.spaceComplexity!,
                        ),
                      ),
                  ],
                ),
              ],
              if (problem.explanation.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text('Explanation', style: theme.textTheme.labelLarge),
                const SizedBox(height: 6),
                Text(problem.explanation, style: theme.textTheme.bodyMedium),
              ],
              if (problem.code.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text('Code', style: theme.textTheme.labelLarge),
                const SizedBox(height: 6),
                LeetCodeCodeView(code: problem.code, language: problem.codeLanguage),
              ],
              if (problem.notes != null && problem.notes!.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text('Notes', style: theme.textTheme.labelLarge),
                const SizedBox(height: 6),
                Text(problem.notes!, style: theme.textTheme.bodyMedium),
              ],
              if (problem.leetcodeUrl != null) ...[
                const SizedBox(height: 20),
                OutlinedButton.icon(
                  onPressed: () => launchUrl(Uri.parse(problem.leetcodeUrl!)),
                  icon: const Icon(PhosphorIconsRegular.arrowSquareOut, size: 16),
                  label: const Text('Open on LeetCode'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ComplexityTile extends StatelessWidget {
  const _ComplexityTile({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        Text(value, style: theme.textTheme.bodyMedium),
      ],
    );
  }
}
