import 'package:flutter/material.dart';
import 'package:voyager/core/motion/motion.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/domain/models/study_models.dart';
import 'package:voyager/domain/services/study_srs_engine.dart';

/// Height every grading button shares, so the four read as one uniform bar
/// regardless of how wide their labels happen to be.
const double _kGradeButtonHeight = 56;

/// Matches [StudyFlipCard]'s default flip duration: the buttons finish
/// brightening exactly as the card lands on its back, and finish dimming as
/// it lands back on its front.
const Duration _kGradeRevealDuration = Duration(milliseconds: 350);

/// The Fail/Hard/Good/Easy bar under a review card, with each button's
/// resulting interval previewed above it. Takes the raw SRS state rather than
/// a card so both the Study session (a [StudyCard]) and the LeetCode Review
/// Deck's session (a problem) can use the same bar.
class StudyGradingRow extends StatefulWidget {
  const StudyGradingRow({
    super.key,
    required this.interval,
    required this.ease,
    required this.enabled,
    required this.snapDim,
    required this.onGrade,
  });

  /// The item's current SRS state, which the previews project forward from.
  final double interval;
  final double ease;

  final bool enabled;

  /// Whether going disabled should jump straight to the greyed-out look
  /// rather than fading there — for when the card behind it snaps rather
  /// than turns, so the two don't disagree.
  final bool snapDim;
  final ValueChanged<StudyGrade> onGrade;

  @override
  State<StudyGradingRow> createState() => _StudyGradingRowState();
}

class _StudyGradingRowState extends State<StudyGradingRow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _reveal;
  bool _reduced = false;

  @override
  void initState() {
    super.initState();
    _reveal = AnimationController(
      vsync: this,
      duration: _kGradeRevealDuration,
      value: widget.enabled ? 1 : 0,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduced = VoyagerMotion.reduced(context);
    _reveal.duration = _reduced
        ? VoyagerMotion.crossfade
        : _kGradeRevealDuration;
  }

  @override
  void didUpdateWidget(covariant StudyGradingRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.enabled == oldWidget.enabled) return;
    if (widget.enabled) {
      _reveal.forward();
    } else if (widget.snapDim) {
      _reveal.value = 0;
    } else {
      _reveal.reverse();
    }
  }

  @override
  void dispose() {
    _reveal.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final curve = _reduced ? Curves.easeOut : VoyagerSpring.moveCurve;

    Widget button(String label, StudyGrade grade, Color color, double t) {
      final result = applyStudyGrade(
        interval: widget.interval,
        ease: widget.ease,
        grade: grade,
      );
      return Expanded(
        child: Column(
          children: [
            Text(
              formatStudyInterval(result.interval),
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
            const SizedBox(height: 4),
            // The button is held in its enabled rendering and dimmed from the
            // outside instead of letting [GlassButton] switch looks, so the
            // greyed-out and live states are ends of one continuous fade
            // rather than two states it snaps between. Pointer and focus are
            // gated separately — until then it must not hover, click, or tab.
            ExcludeFocus(
              excluding: !widget.enabled,
              child: IgnorePointer(
                ignoring: !widget.enabled,
                child: GlassButton(
                  onPressed: () => widget.onGrade(grade),
                  label: label,
                  color: color,
                  height: _kGradeButtonHeight,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  // Same three values GlassButton itself moves between its
                  // disabled and enabled looks, interpolated instead.
                  textColor: Colors.black87.withValues(
                    alpha: 0.4 + 0.47 * t,
                  ),
                  glassOpacity: 0.03 + 0.03 * t,
                  borderOpacity: 0.12 + 0.10 * t,
                ),
              ),
            ),
          ],
        ),
      );
    }

    return AnimatedBuilder(
      animation: _reveal,
      builder: (context, _) {
        final t = curve.transform(_reveal.value);
        return Row(
          children: [
            button('Fail', StudyGrade.fail, theme.colorScheme.error, t),
            const SizedBox(width: 10),
            button('Hard', StudyGrade.hard, const Color(0xFFE0A63A), t),
            const SizedBox(width: 10),
            button('Good', StudyGrade.good, const Color(0xFF5C8BE0), t),
            const SizedBox(width: 10),
            button('Easy', StudyGrade.easy, const Color(0xFF4CAF7D), t),
          ],
        );
      },
    );
  }
}
