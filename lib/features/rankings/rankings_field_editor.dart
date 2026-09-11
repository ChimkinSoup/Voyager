import 'dart:async';

import 'package:flutter/material.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/core/widgets/tag_highlighted_text_field.dart';
import 'package:voyager/domain/models/ranking_models.dart';
import 'package:voyager/domain/rankings/ranking_queries.dart';
import 'package:voyager/features/rankings/rankings_score_input.dart';
import 'package:voyager/features/rankings/rankings_score_stars.dart';

/// One template field on one entry: its number and stars, and its notes when
/// the template leaves them on.
///
/// An unscored field draws the scale's midpoint faded rather than an empty
/// strip — that is the "default" §4.3 describes, shown without being written.
/// Nothing is stored until the number is used, which is what keeps the field's
/// own sort able to tell an untouched entry from a middling one.
class RankingFieldEditor extends StatefulWidget {
  const RankingFieldEditor({
    super.key,
    required this.field,
    required this.value,
    required this.precision,
    required this.onChanged,
    required this.accentColor,
    this.readOnly = false,
    this.showTopDivider = false,
  });

  final RankingTemplateField field;
  final RankingFieldValue value;

  /// The step this field moves on — the overall's while it inherits, its own
  /// once it does not (§3.2).
  final RankingScorePrecision precision;

  final ValueChanged<RankingFieldValue> onChanged;
  final Color accentColor;
  final bool readOnly;

  /// Hairline between this field and the one above it inside the template band.
  final bool showTopDivider;

  @override
  State<RankingFieldEditor> createState() => _RankingFieldEditorState();
}

class _RankingFieldEditorState extends State<RankingFieldEditor>
    with RankingScoreHold<RankingFieldEditor> {
  static const _saveDebounce = Duration(milliseconds: 400);

  /// How much of the category accent field scores keep (stars and number).
  static const _fieldScoreAccentBlend = 0.85;

  late final TextEditingController _notesController;
  late final FocusNode _notesFocusNode;
  Timer? _saveTimer;

  @override
  double? get storedScore => widget.value.score;

  @override
  void initState() {
    super.initState();
    _notesController = TextEditingController(text: widget.value.notes);
    _notesFocusNode = FocusNode();
  }

  @override
  void didUpdateWidget(RankingFieldEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Only when the panel is pointed at a different entry: rewriting the text
    // while the user is typing into it would fight the caret.
    if (oldWidget.field.id != widget.field.id) {
      _saveTimer?.cancel();
      _notesController.text = widget.value.notes;
    }
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _notesController.dispose();
    _notesFocusNode.dispose();
    super.dispose();
  }

  void _scheduleNotesSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(_saveDebounce, () {
      if (!mounted) return;
      widget.onChanged(widget.value.copyWith(notes: _notesController.text));
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // The held score stands in for the stored one everywhere the row draws
    // itself, so scrolling a roller fills the stars beside it as it goes.
    final score = shownScore;
    final scored = score != null;
    // Criterion scores sit below the headline overall row: same accent family,
    // softened so they read secondary. highlightWash is slate on cream (it
    // lifts *toward* darker there), so on light we blend toward surface
    // instead.
    final fieldScoreAccent = Color.lerp(
      _fieldScoreBlendTarget(context),
      widget.accentColor,
      _fieldScoreAccentBlend,
    )!;
    // The strip behind an unscored field shows where the scale's middle is,
    // faded, so the field has a shape before it has an answer.
    final shown =
        score ??
        rankingFieldMidpoint(
          widget.field.scoreMax,
          precision: widget.precision,
        );

    // Fields are separated by a rule rather than boxed (§9.4). The whole
    // template sits in one lifted band on the panel; hairlines inside it mark
    // where one criterion ends and the next begins.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.showTopDivider) _divider(),
        Padding(
          padding: EdgeInsets.fromLTRB(2, widget.showTopDivider ? 8 : 2, 2, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.field.label,
                      style: theme.textTheme.labelMedium?.copyWith(
                        fontStyle: FontStyle.italic,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  RankingScoreNumber(
                    value: score,
                    scoreMax: widget.field.scoreMax,
                    precision: widget.precision,
                    label: widget.field.label,
                    accentColor: fieldScoreAccent,
                    onDraftChanged: holdDraft,
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                    onChanged: holdingWrites(
                      widget.readOnly
                          ? null
                          : (score) => widget.onChanged(
                              score == null
                                  ? widget.value.copyWith(clearScore: true)
                                  : widget.value.copyWith(score: score),
                            ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Opacity(
                    opacity: scored ? 1 : 0.45,
                    child: RankingStars(
                      value: shown,
                      scoreMax: widget.field.scoreMax,
                      size: widget.field.scoreMax > 5 ? 13 : 16,
                      accentColor: fieldScoreAccent,
                      semanticLabel: scored
                          ? '${widget.field.label} '
                                '${formatRankingScore(score)}'
                          : '${widget.field.label} not scored',
                    ),
                  ),
                ],
              ),
              if (widget.field.notesEnabled) ...[
                const SizedBox(height: 6),
                TagHighlightedTextField(
                  controller: _notesController,
                  focusNode: _notesFocusNode,
                  onChanged: (_) => _scheduleNotesSave(),
                  hintText: 'Notes',
                  accentColor: widget.accentColor,
                  readOnly: widget.readOnly,
                  style: theme.textTheme.bodySmall,
                  minLines: 1,
                  maxLines: 4,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _divider() => Divider(
    height: 1,
    thickness: 1,
    color: widget.accentColor.withValues(alpha: 0.22),
  );

  /// What field scores are blended toward before the accent mix.
  ///
  /// [VoyagerColors.highlightWash] is white on dark (lightens) but slate on
  /// cream (darkens), so the light theme needs a paler surface step instead.
  Color _fieldScoreBlendTarget(BuildContext context) {
    final theme = Theme.of(context);
    if (theme.brightness == Brightness.dark) {
      return VoyagerColors.of(context).highlightWash;
    }
    return Color.lerp(
      theme.scaffoldBackgroundColor,
      theme.colorScheme.surface,
      0.5,
    )!;
  }
}

/// One lifted band for every template field on an entry.
///
/// Title, overall score, and notes stay on the panel scaffold; the criteria
/// block is framed by a hairline while its fill stays translucent so the page
/// backdrop shows through.
class RankingTemplateFieldsBand extends StatelessWidget {
  const RankingTemplateFieldsBand({
    super.key,
    required this.accent,
    required this.child,
  });

  final Color accent;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = Color.lerp(
      theme.scaffoldBackgroundColor,
      theme.colorScheme.surface,
      0.55,
    )!;
    final fill = Color.alphaBlend(
      accent.withValues(alpha: 0.10),
      base,
    ).withValues(alpha: 0.40);
    final border = Color.lerp(
      theme.colorScheme.outlineVariant,
      accent,
      0.7,
    )!.withValues(alpha: 0.45);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: border),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 4),
        child: child,
      ),
    );
  }
}
