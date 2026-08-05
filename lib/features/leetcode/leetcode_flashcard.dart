import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/constants/leetcode_constants.dart';
import 'package:voyager/core/motion/motion.dart';
import 'package:voyager/core/widgets/paper_texture.dart';
import 'package:voyager/core/widgets/tag_chip.dart';
import 'package:voyager/domain/models/leetcode_models.dart';
import 'package:voyager/features/leetcode/leetcode_detail_view.dart';

/// A flip flashcard for the Review Deck. Tapping the card flips it between
/// front (ID/title/difficulty/tags) and back (algorithm/complexity/
/// explanation). Tapping the ID/title specifically — on either face — opens
/// the detail view instead of flipping.
class LeetCodeFlashcard extends StatefulWidget {
  const LeetCodeFlashcard({super.key, required this.problem});

  final LeetCodeProblem problem;

  @override
  State<LeetCodeFlashcard> createState() => _LeetCodeFlashcardState();
}

class _LeetCodeFlashcardState extends State<LeetCodeFlashcard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  final _titleKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _flip() {
    if (_controller.isAnimating) return;
    if (_controller.value == 0) {
      _controller.forward();
    } else {
      _controller.reverse();
    }
  }

  void _openDetail() {
    final box = _titleKey.currentContext?.findRenderObject() as RenderBox?;
    final rect = box == null
        ? Offset.zero & MediaQuery.sizeOf(context)
        : box.localToGlobal(Offset.zero) & box.size;
    openLeetCodeDetailView(context, widget.problem, rect);
  }

  @override
  Widget build(BuildContext context) {
    final reduced = VoyagerMotion.reduced(context);
    return GestureDetector(
      onTap: _flip,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          final v = _controller.value;
          final front = _CardFront(
            problem: widget.problem,
            titleKey: _titleKey,
            onTitleTap: _openDetail,
          );
          final back = _CardBack(
            problem: widget.problem,
            titleKey: _titleKey,
            onTitleTap: _openDetail,
          );
          if (reduced) {
            // No 3D rotation under reduced-motion — a plain crossfade instead.
            return Stack(
              alignment: Alignment.center,
              children: [
                Opacity(opacity: (1 - v * 2).clamp(0.0, 1.0), child: front),
                Opacity(
                  opacity: ((v - 0.5) * 2).clamp(0.0, 1.0),
                  child: back,
                ),
              ],
            );
          }
          final t = VoyagerSpring.moveCurve.transform(v);
          final angle = t * math.pi;
          final showBack = t >= 0.5;
          final transform = Matrix4.identity()
            ..setEntry(3, 2, 0.001)
            ..rotateY(angle);
          return Transform(
            alignment: Alignment.center,
            transform: transform,
            child: showBack
                ? Transform(
                    alignment: Alignment.center,
                    transform: Matrix4.identity()..rotateY(math.pi),
                    child: back,
                  )
                : front,
          );
        },
      ),
    );
  }
}

const _cardRadius = BorderRadius.all(Radius.circular(24));

Widget _glassContainer({
  required ThemeData theme,
  required FragmentProgram? paperProgram,
  required Widget child,
}) {
  final shadow = BoxShadow(
    color: Colors.black.withValues(alpha: 0.35),
    blurRadius: 24,
    spreadRadius: 2,
    offset: const Offset(0, 8),
  );

  // Dark theme: the original translucent glass-over-blur look, unchanged —
  // it already reads fine against a dark backdrop.
  if (theme.brightness == Brightness.dark) {
    return Container(
      decoration: BoxDecoration(borderRadius: _cardRadius, boxShadow: [shadow]),
      child: ClipRRect(
        borderRadius: _cardRadius,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.06),
              borderRadius: _cardRadius,
              border: Border.all(color: Colors.white.withValues(alpha: 0.22)),
            ),
            padding: const EdgeInsets.all(24),
            child: child,
          ),
        ),
      ),
    );
  }

  // Light theme: a blurred glass tint over bright, busy paper/petals just
  // smears into a flat grey mush (no dark backdrop for it to "frost"
  // against). A plain white paper card — the same grain shader as the app's
  // own background, tinted white instead of cream — reads as an actual card
  // instead.
  return Container(
    decoration: BoxDecoration(borderRadius: _cardRadius, boxShadow: [shadow]),
    child: ClipRRect(
      borderRadius: _cardRadius,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: _cardRadius,
          border: Border.all(color: const Color(0xFF8C8578).withValues(alpha: 0.2)),
        ),
        child: Stack(
          children: [
            Positioned.fill(
              child: PaperTexture(
                program: paperProgram,
                baseColor: Colors.white,
                speckColor: Color.lerp(
                  Colors.white,
                  const Color(0xFF8C8578),
                  0.35,
                )!,
              ),
            ),
            Padding(padding: const EdgeInsets.all(24), child: child),
          ],
        ),
      ),
    ),
  );
}

class _CardFront extends ConsumerWidget {
  const _CardFront({
    required this.problem,
    required this.titleKey,
    required this.onTitleTap,
  });

  final LeetCodeProblem problem;
  final GlobalKey titleKey;
  final VoidCallback onTitleTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return _glassContainer(
      theme: theme,
      paperProgram: ref.watch(paperShaderProvider).valueOrNull,
      child: Stack(
        children: [
          Positioned(
            top: 0,
            right: 0,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: colorForLeetCodeDifficulty(problem.difficulty)
                    .withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                labelForLeetCodeDifficulty(problem.difficulty),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: colorForLeetCodeDifficulty(problem.difficulty),
                ),
              ),
            ),
          ),
          Center(
            child: GestureDetector(
              key: titleKey,
              behavior: HitTestBehavior.opaque,
              onTap: onTitleTap,
              child: Text(
                '${problem.questionFrontendId ?? ''} ${problem.title}'.trim(),
                textAlign: TextAlign.center,
                style: theme.textTheme.headlineSmall,
              ),
            ),
          ),
          if (problem.tags.isNotEmpty)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Wrap(
                alignment: WrapAlignment.center,
                spacing: 6,
                runSpacing: 6,
                children: [for (final tag in problem.tags) TagChip(tag: tag)],
              ),
            ),
        ],
      ),
    );
  }
}

class _CardBack extends ConsumerWidget {
  const _CardBack({
    required this.problem,
    required this.titleKey,
    required this.onTitleTap,
  });

  final LeetCodeProblem problem;
  final GlobalKey titleKey;
  final VoidCallback onTitleTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return _glassContainer(
      theme: theme,
      paperProgram: ref.watch(paperShaderProvider).valueOrNull,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            GestureDetector(
              key: titleKey,
              behavior: HitTestBehavior.opaque,
              onTap: onTitleTap,
              child: Text(
                '${problem.questionFrontendId ?? ''} ${problem.title}'.trim(),
                style: theme.textTheme.titleMedium,
              ),
            ),
            if (problem.algorithm.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text('Algorithm', style: theme.textTheme.labelLarge),
              const SizedBox(height: 4),
              Text(problem.algorithm, style: theme.textTheme.bodyMedium),
            ],
            if (problem.timeComplexity != null || problem.spaceComplexity != null) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  if (problem.timeComplexity != null)
                    Expanded(
                      child: Text(
                        'Time: ${problem.timeComplexity}',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  if (problem.spaceComplexity != null)
                    Expanded(
                      child: Text(
                        'Space: ${problem.spaceComplexity}',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                ],
              ),
            ],
            if (problem.explanation.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text('Explanation', style: theme.textTheme.labelLarge),
              const SizedBox(height: 4),
              Text(problem.explanation, style: theme.textTheme.bodyMedium),
            ],
          ],
        ),
      ),
    );
  }
}
