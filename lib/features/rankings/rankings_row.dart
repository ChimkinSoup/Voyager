import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/core/media/widgets/media_fan_stack.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/theme/palette_color.dart';
import 'package:voyager/core/theme/voyager_list_item_surface.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/core/widgets/context_menu.dart';
import 'package:voyager/domain/models/ranking_models.dart';
import 'package:voyager/domain/rankings/ranking_queries.dart';
import 'package:voyager/features/rankings/rankings_media_grid.dart';
import 'package:voyager/features/rankings/rankings_score_stars.dart';

/// The most cards a fan draws before it stops fanning and counts (§7.5).
const rankingsFanCap = 5;

/// The most tags a row prints before the rest become a `+N` (§6.2).
const rankingsRowTagCap = 2;

/// The width the `#N` slot holds open, so every title in the ranked section
/// starts at the same x whether or not its row prints a number (§6.3).
const _rankSlotWidth = 30.0;

/// Below this the row drops its image fan and status chip.
const _roomyRowWidth = 320.0;

/// One entry in either section of the list.
///
/// The row is the same in both; what changes is which of its trailing pieces
/// are there — a status chip while unranked, a live score strip once ranked.
class RankingsRow extends ConsumerStatefulWidget {
  const RankingsRow({
    super.key,
    required this.parent,
    required this.category,
    required this.children,
    required this.isSelected,
    required this.onTap,
    required this.onToggleStar,
    required this.onScoreChanged,
    required this.onTagTapped,
    required this.menuItems,
    this.rank,
    this.showRankSlot = false,
    this.readOnly = false,
  });

  final RankingParent parent;
  final RankingCategory category;
  final List<RankingChild> children;
  final bool isSelected;
  final VoidCallback onTap;
  final VoidCallback onToggleStar;

  /// Null clears the score; anything else sets it (§6.1, §6.2).
  final ValueChanged<double?> onScoreChanged;

  /// Sets the category's tag filter to the chip that was clicked. Idempotent
  /// by design: a second click on the active tag leaves it on, because a chip
  /// that toggled would make the row the user is aiming at disappear under the
  /// pointer. Clearing lives in the filter popover.
  final ValueChanged<String> onTagTapped;

  /// Built when the menu is actually opened rather than on every rebuild of
  /// the list — see [ContextMenuRegion.itemsBuilder].
  final ValueGetter<List<ContextMenuItem>> menuItems;

  /// This row's density rank, or null for a row whose score tier already
  /// stated one further up (§6.3).
  final int? rank;

  /// Whether the row holds the rank column open at all. Off in the queue and
  /// under every sort but overall score, where a rank would mean nothing.
  final bool showRankSlot;

  /// An archived category is readable but not editable (§7.4), so the star,
  /// the quick-rate and the row menu all go quiet.
  final bool readOnly;

  @override
  ConsumerState<RankingsRow> createState() => _RankingsRowState();
}

class _RankingsRowState extends ConsumerState<RankingsRow> {
  var _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final parent = widget.parent;
    final category = widget.category;
    final accent = paletteColor(category.colorValue, context);
    final progress = rankingChildProgress(widget.children);

    final row = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      // Squeezed beside the open edit panel in a narrow window, the row keeps
      // the star, title and score and lets the image fan and status chip go:
      // with them it overflowed.
      child: LayoutBuilder(
        builder: (context, constraints) {
          final roomy = constraints.maxWidth >= _roomyRowWidth;
          return Row(
        children: [
          if (widget.showRankSlot)
            SizedBox(
              width: _rankSlotWidth,
              child: Text(
                widget.rank == null ? '' : '#${widget.rank}',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          _StarButton(
            starred: parent.starred,
            accent: accent,
            onPressed: widget.readOnly ? null : widget.onToggleStar,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  parent.title.isEmpty ? 'Untitled' : parent.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: parent.title.isEmpty
                        ? theme.colorScheme.onSurfaceVariant
                        : null,
                  ),
                ),
                const SizedBox(height: 2),
                _Subtitle(
                  parent: parent,
                  category: category,
                  accent: accent,
                  progress: progress,
                  onTagTapped: widget.onTagTapped,
                ),
              ],
            ),
          ),
          if (roomy && category.imagesOnParent) ...[
            const SizedBox(width: 12),
            MediaFanStack(
              collection: FirestoreCollections.rankings,
              documentId: parent.id,
              accentColor: accent,
              thumbnailSize: 34,
              maxVisible: rankingsFanCap,
              onTap: () => showRankingsMediaGrid(
                context,
                ref,
                documentId: parent.id,
                title: parent.title.isEmpty ? 'Images' : parent.title,
              ),
            ),
          ],
          const SizedBox(width: 12),
          // The number is on both sides of the split: a queued entry shows a
          // dash next to its chip, so it can be scored without being opened.
          RankingQuickRate(
            value: parent.overallScore,
            scoreMax: category.parentScoreMax,
            precision: category.parentScorePrecision,
            label: parent.title.isEmpty ? 'Entry' : parent.title,
            accentColor: accent,
            onChanged: widget.readOnly ? null : widget.onScoreChanged,
          ),
          if (roomy && !parent.isRanked) ...[
            const SizedBox(width: 8),
            _StatusChip(status: parent.status, accent: accent),
          ],
        ],
          );
        },
      ),
    );

    return ContextMenuRegion(
      itemsBuilder: widget.menuItems,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
        child: MouseRegion(
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            curve: Curves.easeOut,
            decoration: _decoration(context, accent),
            child: Material(
              type: MaterialType.transparency,
              child: InkWell(
                onTap: widget.onTap,
                borderRadius: BorderRadius.circular(14),
                child: row,
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The list's shared resting and hover surface, with one departure: the
  /// selected row is outlined in the category's colour rather than the neutral
  /// one, so the row the panel is open on is marked by the same accent every
  /// other piece of chrome on this page carries (§7.1).
  BoxDecoration _decoration(BuildContext context, Color accent) {
    final base = VoyagerListItemSurface.decoration(
      context,
      selected: widget.isSelected,
      hovered: _hovered,
      borderRadius: 14,
    );
    if (!widget.isSelected) return base;
    return base.copyWith(
      border: Border.all(color: accent.withValues(alpha: 0.7)),
    );
  }
}

/// The line under the title, and it does exactly one job.
///
/// Tags when there are any, condensed progress when there are not, nothing
/// when neither applies. The old three-part line — unit count, progress, and
/// the creation date — read as a row of numbers with no ranking in it, and
/// chips added to that would have been a fourth thing competing. The date is
/// gone from the list entirely; it is still in the panel and still sortable.
///
/// Progress does not disappear when tags win: it moves into the tooltip
/// (§6.3), which is where a number you only occasionally want belongs.
class _Subtitle extends StatelessWidget {
  const _Subtitle({
    required this.parent,
    required this.category,
    required this.accent,
    required this.progress,
    required this.onTagTapped,
  });

  final RankingParent parent;
  final RankingCategory category;
  final Color accent;
  final ({int scored, int total}) progress;
  final ValueChanged<String> onTagTapped;

  bool get _hasProgress => category.childUnitsEnabled && progress.total > 0;

  String get _progressLabel => '${progress.scored}/${progress.total} scored';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    if (parent.tags.isEmpty) {
      if (!_hasProgress) return const SizedBox.shrink();
      return Text(
        _progressLabel,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: style,
      );
    }

    final shown = parent.tags.take(rankingsRowTagCap).toList();
    final overflow = parent.tags.length - shown.length;

    final strip = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final tag in shown) ...[
          // Flexible, so a tag wider than its share of the line is cut short
          // instead of pushing the strip past the row's edge.
          Flexible(
            child: _RowTagChip(
              tag: tag,
              accent: accent,
              onTap: () => onTagTapped(tag),
            ),
          ),
          const SizedBox(width: 4),
        ],
        if (overflow > 0)
          Tooltip(
            message: parent.tags.skip(rankingsRowTagCap).join(' · '),
            child: Text(
              '+$overflow',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );

    // The tooltip wraps the whole strip rather than each chip: the chips are
    // already the thing being pointed at, and progress is what the row would
    // have said had the tags not taken the line.
    return Align(
      alignment: Alignment.centerLeft,
      child: _hasProgress
          ? Tooltip(message: _progressLabel, child: strip)
          : strip,
    );
  }
}

/// A structured tag on a list row.
///
/// The category's accent at low alpha, in the same family as the row's status
/// chip — not the per-tag colours finance gives its tags, which on this page
/// would be a second colour system arguing with the category's own.
class _RowTagChip extends StatelessWidget {
  const _RowTagChip({
    required this.tag,
    required this.accent,
    required this.onTap,
  });

  final String tag;
  final Color accent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        // The row underneath opens the panel; a chip is a filter. Nothing is
        // returned to the row's [InkWell] because this one consumes the tap.
        onTap: onTap,
        borderRadius: BorderRadius.circular(VoyagerTheme.fieldRadius),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
          decoration: BoxDecoration(
            color: accent.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(VoyagerTheme.fieldRadius),
          ),
          child: Text(
            tag,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(color: accent),
          ),
        ),
      ),
    );
  }
}

class _StarButton extends StatelessWidget {
  const _StarButton({
    required this.starred,
    required this.accent,
    required this.onPressed,
  });

  final bool starred;
  final Color accent;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return IconButton(
      onPressed: onPressed,
      visualDensity: VisualDensity.compact,
      iconSize: 16,
      tooltip: starred ? 'Unpin' : 'Pin to top',
      icon: Icon(
        starred ? PhosphorIconsFill.star : PhosphorIconsRegular.star,
        color: starred
            ? accent
            : theme.colorScheme.onSurface.withValues(alpha: 0.28),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status, required this.accent});

  final RankingStatus status;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final inProgress = status == RankingStatus.inProgress;
    final color = inProgress ? accent : theme.colorScheme.onSurfaceVariant;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(VoyagerTheme.fieldRadius),
      ),
      child: Text(
        inProgress ? 'In progress' : 'Queued',
        style: theme.textTheme.labelSmall?.copyWith(color: color),
      ),
    );
  }
}
