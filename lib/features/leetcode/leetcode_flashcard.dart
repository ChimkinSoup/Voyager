import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/constants/leetcode_constants.dart';
import 'package:voyager/core/widgets/paper_texture.dart';
import 'package:voyager/core/widgets/tag_chip.dart';
import 'package:voyager/domain/models/leetcode_models.dart';
import 'package:voyager/features/leetcode/leetcode_code_field.dart';
import 'package:voyager/features/leetcode/leetcode_detail_view.dart';
import 'package:voyager/features/leetcode/leetcode_examples.dart';
import 'package:voyager/features/leetcode/leetcode_inline_code.dart';
import 'package:voyager/core/widgets/voyager_scroll_view.dart';
import 'package:voyager/features/study/study_flip_card.dart';

/// A flip flashcard for the Review Deck. Tapping the card flips it between
/// front (ID/title/difficulty/description/tags) and back (algorithm/complexity/
/// explanation/code). Tapping the ID/title specifically — on either face — opens
/// the detail view instead of flipping.
///
/// The flip itself is [StudyFlipCard]'s, so a Study or Cram session can drive
/// this card from the space bar through a [StudyFlipController] and gets the
/// reduced-motion crossfade for free.
class LeetCodeFlashcard extends StatefulWidget {
  const LeetCodeFlashcard({
    super.key,
    required this.problem,
    this.controller,
    this.onFlipChanged,
    this.notifyFlipOnStart = false,
  });

  final LeetCodeProblem problem;
  final StudyFlipController? controller;
  final ValueChanged<bool>? onFlipChanged;

  /// See [StudyFlipCard.notifyFlipOnStart] — on for a session, so a grading
  /// key pressed while the card is still turning still registers.
  final bool notifyFlipOnStart;

  @override
  State<LeetCodeFlashcard> createState() => _LeetCodeFlashcardState();
}

class _LeetCodeFlashcardState extends State<LeetCodeFlashcard> {
  final _titleKey = GlobalKey();

  void _openDetail() {
    final box = _titleKey.currentContext?.findRenderObject() as RenderBox?;
    final rect = box == null
        ? Offset.zero & MediaQuery.sizeOf(context)
        : box.localToGlobal(Offset.zero) & box.size;
    openLeetCodeDetailView(context, widget.problem, rect);
  }

  @override
  Widget build(BuildContext context) {
    return StudyFlipCard(
      controller: widget.controller,
      onFlipChanged: widget.onFlipChanged,
      notifyFlipOnStart: widget.notifyFlipOnStart,
      front: _CardFront(
        problem: widget.problem,
        titleKey: _titleKey,
        onTitleTap: _openDetail,
      ),
      back: _CardBack(
        problem: widget.problem,
        titleKey: _titleKey,
        onTitleTap: _openDetail,
      ),
    );
  }
}

const _cardRadius = BorderRadius.all(Radius.circular(24));

Widget _glassContainer({
  required ThemeData theme,
  required FragmentProgram? paperProgram,
  required Widget child,

  /// The caller's `MediaQuery.highContrast` — the app's stand-in for
  /// "prefers-reduced-transparency", handled the same way [GlassSurface] does.
  required bool nearSolid,
}) {
  final shadow = BoxShadow(
    color: Colors.black.withValues(alpha: 0.35),
    blurRadius: 24,
    spreadRadius: 2,
    offset: const Offset(0, 8),
  );

  // Dark theme: the original translucent glass-over-blur look, unchanged —
  // it already reads fine against a dark backdrop. Under high contrast the
  // blur comes off and the fill goes near-solid, so the card separates from
  // the petals by its own surface rather than by frosting them.
  if (theme.brightness == Brightness.dark) {
    return Container(
      decoration: BoxDecoration(borderRadius: _cardRadius, boxShadow: [shadow]),
      child: ClipRRect(
        borderRadius: _cardRadius,
        child: BackdropFilter(
          filter: nearSolid
              ? ImageFilter.blur(sigmaX: 0, sigmaY: 0)
              : ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: Container(
            decoration: BoxDecoration(
              color: nearSolid
                  ? theme.colorScheme.surface.withValues(alpha: 0.97)
                  : Colors.white.withValues(alpha: 0.06),
              borderRadius: _cardRadius,
              border: Border.all(
                color: Colors.white.withValues(alpha: nearSolid ? 0.5 : 0.22),
              ),
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
          border: Border.all(
            color: const Color(0xFF8C8578).withValues(alpha: 0.2),
          ),
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
    final settings = ref.watch(settingsProvider).valueOrNull;
    final description = problem.description?.trim();
    final hasDescription =
        description != null &&
        description.isNotEmpty &&
        !(settings?.leetCodeHideDescription ?? false);
    // The examples' size, and the base the statement is scaled up from — same
    // colour and leading, so the two still read as one block rather than two
    // differently-weighted ones.
    final bodyStyle = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurface.withValues(alpha: 0.72),
      height: 1.45,
    );
    // The statement is the question. It's what the card is asking, and it was
    // set at the same size as the worked examples underneath it — which are
    // reference material you scan, not prose you read. Only the statement
    // grows; the examples keep [bodyStyle] so the difference in size is the
    // difference in what they're for.
    final statementStyle = bodyStyle?.copyWith(
      fontSize: (bodyStyle.fontSize ?? 12) * 1.25,
      color: theme.colorScheme.onSurface.withValues(alpha: 0.85),
    );
    // Each hidden block takes its separator with it, so a card missing its
    // title does not open on 16 points of nothing.
    final blocks = <Widget>[];
    void addBlock(Widget block) {
      if (blocks.isNotEmpty) blocks.add(const SizedBox(height: 16));
      blocks.add(block);
    }

    if (!(settings?.leetCodeHideQuestionName ?? false)) {
      addBlock(
        GestureDetector(
          key: titleKey,
          behavior: HitTestBehavior.opaque,
          onTap: onTitleTap,
          child: Text(
            '${problem.questionFrontendId ?? ''} ${problem.title}'.trim(),
            textAlign: TextAlign.center,
            style: theme.textTheme.headlineMedium,
          ),
        ),
      );
    }
    if (hasDescription) {
      addBlock(
        LeetCodeProseText(
          description,
          textAlign: TextAlign.start,
          style: statementStyle,
          language: problem.codeLanguage,
        ),
      );
    }
    if (problem.examples.isNotEmpty &&
        !(settings?.leetCodeHideExamples ?? false)) {
      addBlock(
        Align(
          alignment: Alignment.centerLeft,
          child: LeetCodeExamplesView(
            examples: problem.examples,
            bodyStyle: bodyStyle,
          ),
        ),
      );
    }

    return _glassContainer(
      theme: theme,
      nearSolid: MediaQuery.maybeOf(context)?.highContrast ?? false,
      paperProgram: ref.watch(paperShaderProvider).valueOrNull,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!(settings?.leetCodeHideDifficulty ?? false)) ...[
            Align(
              alignment: Alignment.centerRight,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: colorForLeetCodeDifficulty(
                    problem.difficulty,
                  ).withValues(alpha: 0.16),
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
            const SizedBox(height: 8),
          ],
          Expanded(
            child: VoyagerScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: blocks,
              ),
            ),
          ),
          if (problem.tags.isNotEmpty &&
              !(settings?.leetCodeHideTags ?? false)) ...[
            const SizedBox(height: 12),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 6,
              runSpacing: 6,
              children: [for (final tag in problem.tags) TagChip(tag: tag)],
            ),
          ],
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
    final settings = ref.watch(settingsProvider).valueOrNull;
    return _glassContainer(
      theme: theme,
      nearSolid: MediaQuery.maybeOf(context)?.highContrast ?? false,
      paperProgram: ref.watch(paperShaderProvider).valueOrNull,
      child: VoyagerScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!(settings?.leetCodeHideQuestionName ?? false))
              GestureDetector(
                key: titleKey,
                behavior: HitTestBehavior.opaque,
                onTap: onTitleTap,
                child: Text(
                  '${problem.questionFrontendId ?? ''} ${problem.title}'.trim(),
                  style: theme.textTheme.titleMedium,
                ),
              ),
            for (var i = 0; i < problem.solutions.length; i++)
              _BackSolution(
                solution: problem.solutions[i],
                // Nothing to tell apart when there's only one, so it goes
                // unlabelled — the back reads as a single write-up rather than
                // as a list of length one.
                number: problem.solutions.length > 1 ? i + 1 : null,
                hideComplexity: settings?.leetCodeHideComplexity ?? false,
                hideCode: settings?.leetCodeHideCode ?? false,
              ),
          ],
        ),
      ),
    );
  }
}

/// One solution as it appears on the back of the card: approach, what it
/// costs, the walkthrough, the code. Notes are the one field left off — they
/// live in the detail view, where there's room to read them.
class _BackSolution extends StatelessWidget {
  const _BackSolution({
    required this.solution,
    required this.number,
    required this.hideComplexity,
    required this.hideCode,
  });

  final LeetCodeSolution solution;
  final int? number;
  final bool hideComplexity;
  final bool hideCode;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final language = solution.codeLanguage;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (number != null) ...[
          const SizedBox(height: 16),
          Text(
            'Solution $number',
            style: theme.textTheme.titleSmall?.copyWith(
              color: theme.colorScheme.primary,
            ),
          ),
        ],
        if (solution.algorithm.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text('Algorithm', style: theme.textTheme.labelLarge),
          const SizedBox(height: 4),
          LeetCodeProseText(
            solution.algorithm,
            style: theme.textTheme.bodyMedium,
            language: language,
          ),
        ],
        if (!hideComplexity &&
            (solution.timeComplexity != null ||
                solution.spaceComplexity != null)) ...[
          const SizedBox(height: 12),
          Row(
            children: [
              if (solution.timeComplexity != null)
                Expanded(
                  child: LeetCodeProseText(
                    'Time: ${solution.timeComplexity}',
                    style: theme.textTheme.bodySmall,
                    language: language,
                  ),
                ),
              if (solution.spaceComplexity != null)
                Expanded(
                  child: LeetCodeProseText(
                    'Space: ${solution.spaceComplexity}',
                    style: theme.textTheme.bodySmall,
                    language: language,
                  ),
                ),
            ],
          ),
        ],
        if (solution.explanation.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text('Explanation', style: theme.textTheme.labelLarge),
          const SizedBox(height: 4),
          LeetCodeProseText(
            solution.explanation,
            style: theme.textTheme.bodyMedium,
            language: language,
          ),
        ],
        if (solution.code.isNotEmpty && !hideCode) ...[
          const SizedBox(height: 12),
          Text('Code', style: theme.textTheme.labelLarge),
          const SizedBox(height: 4),
          LeetCodeCodeView(code: solution.code, language: language),
        ],
      ],
    );
  }
}
