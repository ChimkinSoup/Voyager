import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:voyager/core/constants/leetcode_constants.dart';
import 'package:voyager/core/motion/motion.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/tag_chip.dart';
import 'package:voyager/core/widgets/voyager_scroll_view.dart';
import 'package:voyager/domain/models/leetcode_models.dart';
import 'package:voyager/features/leetcode/leetcode_code_field.dart';
import 'package:voyager/features/leetcode/leetcode_examples.dart';
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
  const _LeetCodeDetailOverlay({
    required this.problem,
    required this.anchorRect,
  });

  final LeetCodeProblem problem;
  final Rect anchorRect;

  @override
  State<_LeetCodeDetailOverlay> createState() => _LeetCodeDetailOverlayState();
}

/// Fraction of the open over which the card finishes fading in. The growing
/// transform is what performs the reveal; past this point the card is opaque,
/// so the middle of the animation is never a half-transparent screen.
const double _kCardFadeInFraction = 0.3;

class _LeetCodeDetailOverlayState extends State<_LeetCodeDetailOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
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
    // reverse() picks up the controller's live value, so closing part-way
    // through the open continues from what is on screen rather than jumping
    // to full size first. Guarded so a second Escape mid-close cannot leave
    // two reverses racing for the same pop.
    if (_closing) return;
    _closing = true;
    await _controller.reverse();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final fullScreenRect = Offset.zero & size;
    final reducedMotion = VoyagerMotion.reduced(context);

    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): _close},
      child: Focus(
        autofocus: true,
        child: PopScope(
          // The route's own pop is instant (transitionDuration is zero), so a
          // system back would make the card vanish instead of shrinking back
          // to the tile it came from. Route it through the same close.
          canPop: false,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) _close();
          },
          child: Material(
            color: Colors.black.withValues(alpha: 0.001),
            child: AnimatedBuilder(
              animation: _controller,
              builder: (context, child) {
                final raw = _controller.value.clamp(0.0, 1.0);
                final scrim = Positioned.fill(
                  child: IgnorePointer(
                    child: Container(
                      color: Colors.black.withValues(alpha: 0.5 * raw),
                    ),
                  ),
                );
                if (reducedMotion) {
                  // No zoom, no scale — a cross-fade in place, which is what
                  // reduced motion asks for in place of a large transform.
                  return Stack(
                    children: [
                      scrim,
                      Positioned.fill(
                        child: Opacity(opacity: raw, child: child),
                      ),
                    ],
                  );
                }
                final t = VoyagerSpring.moveCurve.transform(raw);
                final rect = Rect.lerp(widget.anchorRect, fullScreenRect, t)!;
                final scaleX = rect.width / fullScreenRect.width;
                final scaleY = rect.height / fullScreenRect.height;
                return Stack(
                  children: [
                    scrim,
                    // The card is always laid out at full-screen size and
                    // scaled via Transform (rather than resized via
                    // Positioned.fromRect) so its content never has to reflow
                    // into anchorRect's tiny starting dimensions, which caused
                    // RenderFlex overflows.
                    Positioned.fill(
                      child: Transform(
                        alignment: Alignment.topLeft,
                        transform: Matrix4.identity()
                          ..translate(rect.left, rect.top)
                          ..scale(scaleX, scaleY),
                        child: Opacity(
                          opacity: (t / _kCardFadeInFraction).clamp(0.0, 1.0),
                          child: child,
                        ),
                      ),
                    ),
                  ],
                );
              },
              child: _DetailCard(problem: widget.problem, onClose: _close),
            ),
          ),
        ),
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
        // Edit and close stay pinned as light overlays so they never scroll
        // away, the same way the track modal's close does; content runs under
        // them rather than behind a reserved header bar.
        child: Stack(
          children: [
            Positioned.fill(
              child: VoyagerScrollView(
                // Top inset clears the overlaid buttons on first paint; once
                // the user scrolls, content runs under them to the top edge.
                padding: const EdgeInsets.fromLTRB(20, 40, 20, 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${problem.questionFrontendId ?? ''} ${problem.title}'
                          .trim(),
                      style: theme.textTheme.titleLarge,
                    ),
                    const SizedBox(height: 4),
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
                          color: colorForLeetCodeDifficulty(problem.difficulty),
                        ),
                      ),
                    ),
                    if (problem.tags.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final tag in problem.tags) TagChip(tag: tag),
                        ],
                      ),
                    ],
                    if (problem.description != null &&
                        problem.description!.trim().isNotEmpty) ...[
                      const SizedBox(height: 20),
                      Text('Description', style: theme.textTheme.labelLarge),
                      const SizedBox(height: 6),
                      Text(
                        problem.description!,
                        style: theme.textTheme.bodyMedium,
                      ),
                    ],
                    if (problem.examples.isNotEmpty) ...[
                      const SizedBox(height: 20),
                      Text('Examples', style: theme.textTheme.labelLarge),
                      const SizedBox(height: 8),
                      LeetCodeExamplesView(examples: problem.examples),
                    ],
                    for (var i = 0; i < problem.solutions.length; i++)
                      _DetailSolution(
                        solution: problem.solutions[i],
                        number: problem.solutions.length > 1 ? i + 1 : null,
                      ),
                    if (problem.leetcodeUrl != null) ...[
                      const SizedBox(height: 20),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: GlassButton(
                          onPressed: () =>
                              launchUrl(Uri.parse(problem.leetcodeUrl!)),
                          icon: const Icon(
                            PhosphorIconsRegular.arrowSquareOut,
                            size: 16,
                          ),
                          label: 'Open on LeetCode',
                          dense: true,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            Positioned(
              top: 4,
              right: 4,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
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
                      icon: const Icon(
                        PhosphorIconsRegular.pencilSimple,
                        size: 20,
                      ),
                      visualDensity: VisualDensity.compact,
                      tooltip: 'Edit',
                    ),
                  ),
                  IconButton(
                    onPressed: onClose,
                    icon: const Icon(PhosphorIconsRegular.x, size: 20),
                    visualDensity: VisualDensity.compact,
                    tooltip: 'Close',
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One solution's full write-up, notes included — this is the view with the
/// room for them, so they're here rather than on the flashcard back.
///
/// [number] is null for a problem with a single solution: with nothing to
/// distinguish it from, a "Solution 1" heading would only be clutter.
class _DetailSolution extends StatelessWidget {
  const _DetailSolution({required this.solution, required this.number});

  final LeetCodeSolution solution;
  final int? number;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (number != null) ...[
          const SizedBox(height: 24),
          Text(
            'Solution $number',
            style: theme.textTheme.titleMedium?.copyWith(
              color: theme.colorScheme.primary,
            ),
          ),
        ],
        if (solution.algorithm.isNotEmpty) ...[
          const SizedBox(height: 20),
          Text('Algorithm', style: theme.textTheme.labelLarge),
          const SizedBox(height: 6),
          Text(solution.algorithm, style: theme.textTheme.bodyMedium),
        ],
        if (solution.timeComplexity != null ||
            solution.spaceComplexity != null) ...[
          const SizedBox(height: 16),
          Row(
            children: [
              if (solution.timeComplexity != null)
                Expanded(
                  child: _ComplexityTile(
                    label: 'Time',
                    value: solution.timeComplexity!,
                  ),
                ),
              if (solution.spaceComplexity != null)
                Expanded(
                  child: _ComplexityTile(
                    label: 'Space',
                    value: solution.spaceComplexity!,
                  ),
                ),
            ],
          ),
        ],
        if (solution.explanation.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text('Explanation', style: theme.textTheme.labelLarge),
          const SizedBox(height: 6),
          Text(solution.explanation, style: theme.textTheme.bodyMedium),
        ],
        if (solution.code.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text('Code', style: theme.textTheme.labelLarge),
          const SizedBox(height: 6),
          LeetCodeCodeView(
            code: solution.code,
            language: solution.codeLanguage,
          ),
        ],
        if (solution.notes != null && solution.notes!.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text('Notes', style: theme.textTheme.labelLarge),
          const SizedBox(height: 6),
          Text(solution.notes!, style: theme.textTheme.bodyMedium),
        ],
      ],
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
