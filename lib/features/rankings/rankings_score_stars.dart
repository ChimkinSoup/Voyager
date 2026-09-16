import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/domain/models/ranking_models.dart';
import 'package:voyager/features/rankings/rankings_score_input.dart';

/// A row of stars that reads a score. Display only — the score is set from the
/// number beside it (`RANKINGS_SCORE_INPUT_HLD` §5).
///
/// Fractions are drawn by clipping a filled star over an outlined one rather
/// than by swapping in a half-star glyph: the two shapes are then guaranteed
/// to sit on the same baseline at any size, and a tenth of a star has no glyph
/// to swap to at all. The fill is honest — `8.3` fills 30% of the ninth star
/// and `8.4` fills 40%, with no minimum sliver propping up small fractions.
class RankingStars extends StatelessWidget {
  const RankingStars({
    super.key,
    required this.value,
    required this.scoreMax,
    this.size = 16,
    this.accentColor,
    this.semanticLabel,
  });

  /// Null draws an empty strip — "not scored" — rather than a zero.
  final double? value;

  final int scoreMax;
  final double size;
  final Color? accentColor;
  final String? semanticLabel;

  static const _gap = 1.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = accentColor ?? theme.colorScheme.primary;
    final shown = value ?? 0;
    final empty = theme.colorScheme.onSurface.withValues(alpha: 0.22);

    return Semantics(
      label: semanticLabel,
      child: SizedBox(
        height: size,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < scoreMax; i++)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: _gap),
                child: _Star(
                  fill: (shown - i).clamp(0.0, 1.0),
                  size: size,
                  filledColor: accent,
                  emptyColor: empty,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// One star, [fill] of it filled from the left.
class _Star extends StatelessWidget {
  const _Star({
    required this.fill,
    required this.size,
    required this.filledColor,
    required this.emptyColor,
  });

  final double fill;
  final double size;
  final Color filledColor;
  final Color emptyColor;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        children: [
          Icon(PhosphorIconsRegular.star, size: size, color: emptyColor),
          if (fill > 0)
            ClipRect(
              clipper: _LeftFractionClipper(fill),
              child: Icon(
                PhosphorIconsFill.star,
                size: size,
                color: filledColor,
              ),
            ),
        ],
      ),
    );
  }
}

class _LeftFractionClipper extends CustomClipper<Rect> {
  const _LeftFractionClipper(this.fraction);

  final double fraction;

  @override
  Rect getClip(Size size) =>
      Rect.fromLTWH(0, 0, size.width * fraction, size.height);

  @override
  bool shouldReclip(_LeftFractionClipper oldClipper) =>
      oldClipper.fraction != fraction;
}

/// The score on a list row: the number that opens the popover, and — once
/// there is a score — the strip that draws it.
///
/// An unranked row still carries the number, showing a dash, so an entry can
/// be scored straight from the list. It draws no strip: ten outlined stars on
/// every queued row is noise, and the row already says what it is with its
/// status chip.
class RankingQuickRate extends StatefulWidget {
  const RankingQuickRate({
    super.key,
    required this.value,
    required this.scoreMax,
    required this.precision,
    required this.label,
    required this.onChanged,
    this.accentColor,
  });

  final double? value;
  final int scoreMax;
  final RankingScorePrecision precision;
  final String label;

  /// Null on an archived category: the number still prints, it just does not
  /// open.
  final ValueChanged<double?>? onChanged;

  final Color? accentColor;

  /// Wide enough for the longest score a scale prints ('10', '8.5', '8.4'), so
  /// the numbers down the list stay in a column.
  static const _numberWidth = 30.0;

  @override
  State<RankingQuickRate> createState() => _RankingQuickRateState();
}

class _RankingQuickRateState extends State<RankingQuickRate>
    with RankingScoreHold<RankingQuickRate> {
  @override
  double? get storedScore => widget.value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // A ten-point strip has twice the stars in the same run of pixels, so they
    // are drawn smaller and lean on the number beside them.
    final starSize = widget.scoreMax > 5 ? 12.0 : 15.0;
    final shown = shownScore;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        RankingScoreNumber(
          value: shown,
          scoreMax: widget.scoreMax,
          precision: widget.precision,
          label: widget.label,
          onChanged: holdingWrites(widget.onChanged),
          onDraftChanged: holdDraft,
          accentColor: widget.accentColor,
          width: RankingQuickRate._numberWidth,
          textAlign: TextAlign.right,
          style: theme.textTheme.labelLarge?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        if (shown != null) ...[
          const SizedBox(width: 6),
          RankingStars(
            value: shown,
            scoreMax: widget.scoreMax,
            size: starSize,
            accentColor: widget.accentColor,
          ),
        ],
      ],
    );
  }
}

/// The overall score, given a row to itself: the number on the left, the strip
/// filling the rest of the row (`RANKINGS_UI` §9.3).
///
/// The strip's stars are one fixed size, so a five-point entry and a ten-point
/// one draw the same star and the shorter scale simply leaves whitespace after
/// it. A star that grew with the scale it belongs to — or with the width of
/// the panel it happens to be in — would make the same picture mean two
/// different things.
///
/// The number is the control: clicking it opens the popover, and long-press
/// clears it. A scored row and an unscored one are the same size, so scoring
/// never moves the stars.
class RankingOverallRow extends StatefulWidget {
  const RankingOverallRow({
    super.key,
    required this.value,
    required this.scoreMax,
    required this.precision,
    required this.accentColor,
    required this.label,
    this.onChanged,
    this.semanticLabel,
  });

  final double? value;
  final int scoreMax;
  final RankingScorePrecision precision;
  final Color accentColor;
  final String label;

  /// Null makes the whole row read-only.
  final ValueChanged<double?>? onChanged;

  final String? semanticLabel;

  /// Wide enough for the longest score a scale can print ('10', '8.5').
  static const _numberWidth = 40.0;

  /// One fixed star, not one sized from the space available: the editor panel
  /// is user-resizable, and a strip that grew with it made the same score draw
  /// at a different size on every drag. Ten stars at 20 (plus their 1px gaps)
  /// come to 220, which still fits the ~237 the row has left inside the
  /// narrowest the panel can be dragged to; a wider panel simply leaves
  /// whitespace after the strip, which is already what a five-point scale does.
  static const _starSize = 20.0;

  @override
  State<RankingOverallRow> createState() => _RankingOverallRowState();
}

class _RankingOverallRowState extends State<RankingOverallRow>
    with RankingScoreHold<RankingOverallRow> {
  @override
  double? get storedScore => widget.value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // The held score drives the number and the strip alike, so a roller being
    // scrolled is read off the stars behind it rather than only off the
    // popover.
    final shown = shownScore;

    return Row(
      children: [
        RankingScoreNumber(
          value: shown,
          scoreMax: widget.scoreMax,
          precision: widget.precision,
          label: widget.label,
          onChanged: holdingWrites(widget.onChanged),
          onDraftChanged: holdDraft,
          accentColor: widget.accentColor,
          width: RankingOverallRow._numberWidth,
          // Right-aligned inside a fixed slot: the strip stays in the same
          // column whatever the score is, and the number still sits against
          // the stars it belongs to instead of stranded at the far margin.
          textAlign: TextAlign.right,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Align(
            alignment: Alignment.centerLeft,
            child: RankingStars(
              value: shown,
              scoreMax: widget.scoreMax,
              size: RankingOverallRow._starSize,
              accentColor: widget.accentColor,
              semanticLabel: widget.semanticLabel,
            ),
          ),
        ),
      ],
    );
  }
}
