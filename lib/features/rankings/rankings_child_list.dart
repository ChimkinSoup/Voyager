import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:intl/intl.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/media/media_service.dart';
import 'package:voyager/core/media/widgets/media_gallery_strip.dart';
import 'package:voyager/core/media/widgets/media_paste_scope.dart';
import 'package:voyager/core/soft_delete/restore_contract.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/theme/palette_color.dart';
import 'package:voyager/core/theme/voyager_list_item_surface.dart';
import 'package:voyager/core/widgets/context_menu.dart';
import 'package:voyager/core/widgets/contextual_popover.dart';
import 'package:voyager/core/widgets/ctrl_enter_to_submit_scope.dart';
import 'package:voyager/core/widgets/date_selector_popover.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/labeled_text_field.dart';
import 'package:voyager/core/widgets/selector_pill.dart';
import 'package:voyager/core/widgets/tag_highlighted_text_field.dart';
import 'package:voyager/core/widgets/voyager_dialog.dart';
import 'package:voyager/core/widgets/voyager_popup_menu_item.dart';
import 'package:voyager/core/widgets/voyager_scroll_view.dart';
import 'package:voyager/domain/models/media_models.dart';
import 'package:voyager/domain/models/ranking_models.dart';
import 'package:voyager/domain/rankings/ranking_queries.dart';
import 'package:voyager/features/rankings/rankings_actions.dart';
import 'package:voyager/features/rankings/rankings_count.dart';
import 'package:voyager/features/rankings/rankings_field_editor.dart';
import 'package:voyager/features/rankings/rankings_providers.dart';
import 'package:voyager/features/rankings/rankings_score_input.dart';
import 'package:voyager/features/rankings/rankings_score_stars.dart';
import 'package:voyager/core/widgets/scroll_offset_isolate.dart';

/// The flat list of units under one entry (§3.5), plus the box that adds one.
///
/// The saved order is the one the user dragged; the view sorts above it never
/// write it back, which is why the drag handles disappear while one is active —
/// dragging a row into a position the list is not actually keeping would be a
/// lie.
class RankingsChildList extends ConsumerStatefulWidget {
  const RankingsChildList({
    super.key,
    required this.parent,
    required this.category,
    required this.children,
    required this.scoredChildren,
    required this.onAverageFromChildren,
    this.readOnly = false,
  });

  final RankingParent parent;
  final RankingCategory category;
  final List<RankingChild> children;

  /// How many units carry an overall score, which is both what the average
  /// would be taken from and whether there is one to take (§9.2).
  final int scoredChildren;

  final Future<void> Function() onAverageFromChildren;

  final bool readOnly;

  @override
  ConsumerState<RankingsChildList> createState() => _RankingsChildListState();
}

class _RankingsChildListState extends ConsumerState<RankingsChildList> {
  final _addController = TextEditingController();
  final _addFocusNode = FocusNode();

  @override
  void dispose() {
    _addController.dispose();
    _addFocusNode.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final name = _addController.text.trim();
    if (name.isEmpty) return;
    _addController.clear();
    await RankingsActions(ref).createChild(
      parent: widget.parent,
      name: name,
      // Appended, never inserted: a new unit joins the end of the saved order
      // whatever the list is currently sorted by.
      sortOrder: rankingNextChildSortOrder(widget.children),
    );
    if (mounted) _addFocusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = paletteColor(widget.category.colorValue, context);
    final view = ref.watch(rankingChildSortProvider);
    final ordered = sortRankingChildrenForView(
      widget.children,
      sort: view.sort,
      sortFieldId: view.fieldId,
    );
    final label = widget.category.childUnitLabel;
    final isSavedOrder = view.sort == RankingChildSort.saved;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '${label}s',
                style: theme.textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            if (widget.scoredChildren > 0 && !widget.readOnly) ...[
              IconButton(
                onPressed: () => widget.onAverageFromChildren(),
                iconSize: 15,
                visualDensity: VisualDensity.compact,
                color: accent,
                // The count is the whole point of the tooltip: an icon that
                // silently overwrote the entry's own score would be the wrong
                // kind of one-tap.
                tooltip:
                    'Average from ${widget.scoredChildren} scored '
                    '${label.toLowerCase()}'
                    '${widget.scoredChildren == 1 ? '' : 's'}',
                icon: const Icon(PhosphorIconsRegular.calculator),
              ),
              const SizedBox(width: 2),
            ],
            Builder(
              builder: (buttonContext) => SelectorPill(
                label: _viewLabel(view),
                dense: true,
                accentColor: accent,
                isActive: !isSavedOrder,
                onTap: () => _pickView(buttonContext),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        if (ordered.isEmpty)
          // Exactly one row's height — a row's padding around a line of its
          // name's style — so the add box below stays put when the last unit
          // is deleted, rather than dropping the pixel the smaller text's
          // looser padding came to.
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text(
              'No ${label.toLowerCase()}s yet.',
              strutStyle: StrutStyle.fromTextStyle(
                theme.textTheme.bodyMedium!,
                forceStrutHeight: true,
              ),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          )
        else
          // Mounted only once a child exists, into a page that may already be
          // scrolled — see [ScrollOffsetIsolate].
          ScrollOffsetIsolate(
            child: ReorderableListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              buildDefaultDragHandles: false,
              itemCount: ordered.length,
              onReorderItem: (oldIndex, newIndex) {
                final ids = [for (final child in ordered) child.id];
                ids.insert(newIndex, ids.removeAt(oldIndex));
                RankingsActions(ref).reorderChildren(ids);
              },
              itemBuilder: (context, index) {
                final child = ordered[index];
                return _ChildRow(
                  key: ValueKey(child.id),
                  index: index,
                  child: child,
                  parent: widget.parent,
                  hasNext: rankingNextChild(child, widget.children) != null,
                  category: widget.category,
                  accent: accent,
                  draggable: isSavedOrder && !widget.readOnly,
                  readOnly: widget.readOnly,
                  showDivider: index < ordered.length - 1,
                );
              },
            ),
          ),
        if (!widget.readOnly) ...[
          const SizedBox(height: 8),
          LabeledTextField(
            label: 'Add $label',
            showLabel: false,
            controller: _addController,
            focusNode: _addFocusNode,
            accentColor: accent,
            // Not dense: this is the box the list is actually built through,
            // and at the child rows' new height it was the thinnest thing in
            // the panel (§8.3).
            //
            // [allowShortHeight] is what makes that padding the padding you
            // see. Left to stretch this box to Material's 48px minimum, the
            // decorator both re-centres the line *and* keeps its own
            // interactive adjustment, and the two together printed the text
            // 18px below the top border with 8 under it.
            allowShortHeight: true,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 14,
              vertical: 12,
            ),
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _add(),
          ),
        ],
      ],
    );
  }

  String _viewLabel(({RankingChildSort sort, String? fieldId}) view) {
    switch (view.sort) {
      case RankingChildSort.saved:
        return 'Manual';
      case RankingChildSort.name:
        return 'Name';
      case RankingChildSort.overallScore:
        return 'Score';
      case RankingChildSort.customField:
        return widget.category.childTemplate
                .where((field) => field.id == view.fieldId)
                .firstOrNull
                ?.label ??
            'Field';
    }
  }

  Future<void> _pickView(BuildContext buttonContext) async {
    final fields = widget.category.activeChildTemplate;
    final selected =
        await showVoyagerMenu<({RankingChildSort sort, String? fieldId})>(
          context: buttonContext,
          position: _menuPosition(buttonContext),
          accentColor: paletteColor(widget.category.colorValue, context),
          items:
              voyagerSelectMenuEntries<
                ({RankingChildSort sort, String? fieldId})
              >(
                context: buttonContext,
                items: [
                  (
                    value: (sort: RankingChildSort.saved, fieldId: null),
                    label: 'Manual order',
                  ),
                  (
                    value: (sort: RankingChildSort.name, fieldId: null),
                    label: 'Name',
                  ),
                  (
                    value: (sort: RankingChildSort.overallScore, fieldId: null),
                    label: 'Overall score',
                  ),
                  for (final field in fields)
                    (
                      value: (
                        sort: RankingChildSort.customField,
                        fieldId: field.id,
                      ),
                      label: field.label,
                    ),
                ],
                selected: ref.read(rankingChildSortProvider),
              ),
        );
    if (selected == null) return;
    ref.read(rankingChildSortProvider.notifier).state = selected;
  }

  RelativeRect _menuPosition(BuildContext buttonContext) {
    final button = buttonContext.findRenderObject() as RenderBox;
    final overlay =
        Navigator.of(buttonContext).overlay!.context.findRenderObject()
            as RenderBox;
    final topLeft = button.localToGlobal(Offset.zero, ancestor: overlay);
    return RelativeRect.fromLTRB(
      topLeft.dx,
      topLeft.dy + button.size.height,
      overlay.size.width - topLeft.dx - button.size.width,
      0,
    );
  }
}

/// One unit in the panel's list (§8.1).
///
/// Number only: a strip of stars per row turned a season of twenty into twenty
/// competing strips, all of them too small to aim at anyway. The score is set
/// in the unit's own editor, where the strip has room to be a control rather
/// than a decoration.
class _ChildRow extends ConsumerStatefulWidget {
  const _ChildRow({
    super.key,
    required this.index,
    required this.child,
    required this.parent,
    required this.hasNext,
    required this.category,
    required this.accent,
    required this.draggable,
    required this.readOnly,
    required this.showDivider,
  });

  final int index;
  final RankingChild child;

  /// Read for its bookmark only.
  final RankingParent parent;

  /// Whether a unit follows this one in the saved order, so Finished says
  /// when it will add one.
  final bool hasNext;
  final RankingCategory category;
  final Color accent;
  final bool draggable;
  final bool readOnly;

  /// Off on the last row: the hairline separates one unit from the next, and a
  /// trailing one would only rule the list off from the box that adds to it.
  final bool showDivider;

  @override
  ConsumerState<_ChildRow> createState() => _ChildRowState();
}

class _ChildRowState extends ConsumerState<_ChildRow>
    with RankingScoreHold<_ChildRow> {
  var _hovered = false;

  /// Held, so the number on the row tracks the roller instead of waiting for
  /// the commit, and keeps the commit until the save lands.
  @override
  double? get storedScore => widget.child.overallScore;

  /// Wide enough for the longest score a scale prints, so the numbers down the
  /// list stay in a column whether or not a unit has been scored.
  static const _scoreWidth = 26.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final child = widget.child;
    final score = shownScore;
    final scored = score != null;
    final hasImages =
        widget.category.imagesOnChild &&
        (ref
                .watch(rankingDocumentIdsWithImagesProvider.settled)
                .valueOrNull
                ?.contains(child.id) ??
            false);
    final bookmarked =
        widget.category.showsProgress &&
        widget.parent.progressChildId == child.id;

    return ContextMenuRegion(
      itemsBuilder: () => [
        if (!widget.readOnly && widget.category.showsProgress) ...[
          if (bookmarked) ...[
            ContextMenuItem(
              label: widget.hasNext
                  ? 'Finished, next ${widget.category.childUnitLabel.toLowerCase()}'
                  : 'Finished, add the next ${widget.category.childUnitLabel.toLowerCase()}',
              icon: PhosphorIconsRegular.skipForward,
              onTap: () => RankingsActions(
                ref,
              ).finishProgress(widget.parent.id, widget.category),
            ),
            ContextMenuItem(
              label: 'Clear where I stopped',
              icon: PhosphorIconsRegular.bookmarkSimple,
              onTap: () => RankingsActions(ref).clearProgress(widget.parent.id),
            ),
          ] else
            ContextMenuItem(
              label: 'Mark where I stopped…',
              icon: PhosphorIconsRegular.bookmarkSimple,
              // Marks the unit at its start, then opens it on the time box
              // for a time to go with it.
              onTap: () async {
                await RankingsActions(
                  ref,
                ).setProgress(widget.parent.id, child.id);
                if (!context.mounted) return;
                await showRankingChildEditor(
                  context,
                  child: child,
                  category: widget.category,
                  focusProgress: true,
                );
              },
            ),
        ],
        if (!widget.readOnly && scored)
          ContextMenuItem(
            label: 'Clear score',
            icon: PhosphorIconsRegular.eraser,
            onTap: () =>
                RankingsActions(ref).setChildOverallScore(child.id, null),
          ),
        if (!widget.readOnly)
          ContextMenuItem(
            label: 'Delete',
            icon: PhosphorIconsRegular.trash,
            isDestructive: true,
            onTap: () => confirmDeleteRankingChild(context, ref, child),
          ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // The hover region is the row itself, not the row plus the hairline
          // below it: the divider sits outside both the fill and the
          // [InkWell], so a pointer on it lit the row up without the ink
          // hover the row draws on top — one row, two highlights a pixel
          // apart.
          MouseRegion(
            onEnter: (_) => setState(() => _hovered = true),
            onExit: (_) => setState(() => _hovered = false),
            child: DecoratedBox(
              // Fill only. The hairline below is a widget of its own rather
              // than a bottom border here: a [BoxDecoration] refuses a
              // borderRadius alongside a border that is on one side only.
              decoration: BoxDecoration(
                color: _hovered
                    ? VoyagerListItemSurface.hoverColor(context)
                    // The bookmarked unit is tinted so it can be found by eye
                    // while scrolling a long season.
                    : bookmarked
                    ? widget.accent.withValues(alpha: 0.1)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Material(
                type: MaterialType.transparency,
                child: InkWell(
                  onTap: () => showRankingChildEditor(
                    context,
                    child: child,
                    category: widget.category,
                    readOnly: widget.readOnly,
                  ),
                  borderRadius: BorderRadius.circular(10),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(6, 6, 8, 6),
                    child: Row(
                      children: [
                        // The handle appears under the pointer and holds its
                        // width when it is not there, so arriving on a row
                        // never shifts the name beside it.
                        SizedBox(
                          width: 14,
                          child: widget.draggable && _hovered
                              ? ReorderableDragStartListener(
                                  index: widget.index,
                                  child: Icon(
                                    PhosphorIconsRegular.dotsSixVertical,
                                    size: 14,
                                    color: theme.colorScheme.onSurface
                                        .withValues(alpha: 0.35),
                                  ),
                                )
                              : null,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            child.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium,
                          ),
                        ),
                        if (bookmarked) ...[
                          const SizedBox(width: 6),
                          RankingProgressBadge(
                            seconds: widget.parent.progressSeconds,
                            accent: widget.accent,
                          ),
                        ],
                        if (hasImages) ...[
                          const SizedBox(width: 6),
                          Tooltip(
                            message: 'Has images',
                            child: Icon(
                              PhosphorIconsRegular.image,
                              size: 14,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                        if (widget.category.showsChildCount) ...[
                          const SizedBox(width: 6),
                          RankingCountSlot(
                            entryId: child.id,
                            hovered: _hovered,
                            accent: widget.accent,
                            onIncrement: widget.readOnly
                                ? null
                                : () => RankingsActions(ref).adjustCount(
                                    child.id,
                                    parentId: child.parentId,
                                    delta: 1,
                                  ),
                          ),
                        ],
                        const SizedBox(width: 8),
                        // A fixed slot, and a dash rather than nothing in it:
                        // the numbers down the list stay in a column, and an
                        // unscored unit says so instead of looking like a row
                        // that failed to draw (§8.1). Clicking it scores the
                        // unit without opening its editor.
                        RankingScoreNumber(
                          value: score,
                          scoreMax: widget.category.childScoreMax,
                          precision: widget.category.childScorePrecision,
                          label: child.name,
                          accentColor: widget.accent,
                          onDraftChanged: holdDraft,
                          width: _scoreWidth,
                          textAlign: TextAlign.right,
                          style: theme.textTheme.labelMedium?.copyWith(
                            fontWeight: scored ? FontWeight.w700 : null,
                          ),
                          onChanged: holdingWrites(
                            widget.readOnly
                                ? null
                                : (score) => RankingsActions(
                                    ref,
                                  ).setChildOverallScore(child.id, score),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (widget.showDivider)
            Divider(
              height: 1,
              thickness: 1,
              indent: 6,
              endIndent: 8,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.06),
            ),
        ],
      ),
    );
  }
}

/// The full editor for one unit — everything a parent's panel holds, minus the
/// things only a parent has (status, queue position, its own children).
Future<void> showRankingChildEditor(
  BuildContext context, {
  required RankingChild child,
  required RankingCategory category,
  bool readOnly = false,
  bool focusProgress = false,
}) {
  return showVoyagerDialog<void>(
    context: context,
    builder: (context) => _ChildEditorDialog(
      child: child,
      category: category,
      readOnly: readOnly,
      focusProgress: focusProgress,
    ),
  );
}

/// Where the user stopped in a unit: a bookmark and the time, or just the
/// bookmark when they stopped at its start.
class RankingProgressBadge extends StatelessWidget {
  const RankingProgressBadge({
    super.key,
    required this.seconds,
    required this.accent,
  });

  final int? seconds;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final seconds = this.seconds;
    return Tooltip(
      message: seconds == null
          ? 'Stopped here'
          : 'Stopped at ${formatRankingProgressTime(seconds)}',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(PhosphorIconsFill.bookmarkSimple, size: 13, color: accent),
          if (seconds != null) ...[
            const SizedBox(width: 3),
            Text(
              formatRankingProgressTime(seconds),
              // The count beside it's style, so the two sit on one baseline.
              style: theme.textTheme.labelMedium?.copyWith(
                color: accent,
                fontWeight: FontWeight.w600,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ChildEditorDialog extends ConsumerStatefulWidget {
  const _ChildEditorDialog({
    required this.child,
    required this.category,
    required this.readOnly,
    required this.focusProgress,
  });

  final RankingChild child;
  final RankingCategory category;
  final bool readOnly;

  /// Opens with the cursor in the progress time — the row's "Mark where I
  /// stopped".
  final bool focusProgress;

  @override
  ConsumerState<_ChildEditorDialog> createState() => _ChildEditorDialogState();
}

class _ChildEditorDialogState extends ConsumerState<_ChildEditorDialog> {
  static const _saveDebounce = Duration(milliseconds: 400);

  late RankingChild _current;
  late final TextEditingController _nameController;
  late final TextEditingController _notesController;
  late final FocusNode _notesFocusNode;
  Timer? _saveTimer;

  /// Resolved up front for [dispose]'s flush — see the entry panel's
  /// `_actions`.
  late final RankingsActions _actions;

  /// Resolved up front for the same reason: Cancel puts images back after the
  /// dialog has gone.
  late final MediaService _media;

  /// This unit's images attached here, by id, for Cancel to detach.
  final _attachedImages = <String>{};

  /// This unit's images removed here, as they stood, for Cancel to put back.
  final _removedImages = <String, MediaReference>{};

  /// Only this device's edits, so nothing a pull brings in is ever undone.
  /// Outlives the dialog on Cancel, to hear an attach that lands after it.
  late final StreamSubscription<({MediaReference reference, bool removed})>
  _imageEdits;

  bool _cancelling = false;

  late final TextEditingController _progressController;
  late final FocusNode _progressFocusNode;
  Timer? _progressTimer;

  /// The entry's bookmark as this dialog found it, for Cancel to put back —
  /// it lives on the entry, so reverting the unit alone would leave it.
  late final ({String? childId, int? seconds}) _openingProgress;

  /// The bookmark this dialog last wrote, null until it writes one — Cancel
  /// takes back only that, and only while it still stands.
  ({String? childId, int? seconds})? _writtenProgress;

  /// The net of the count taps made here, for Cancel to take back by tapping
  /// the other way — taps made elsewhere meanwhile stay.
  var _countTaps = 0;

  /// Taps still being written, which Cancel waits for: [_countTaps] only
  /// learns what a tap applied once its write lands.
  final _pendingCounts = <Future<void>>{};

  Future<void> _adjustCount(int delta) async {
    late final Future<void> write;
    write = () async {
      try {
        final made = await _actions.adjustCount(
          widget.child.id,
          parentId: widget.child.parentId,
          delta: delta,
        );
        // Added after the await, not with `+= await`: that reads the total
        // before waiting, and two quick taps would each add to the same stale
        // value.
        _countTaps += made;
      } finally {
        // A failed tap too, or Cancel would wait on it forever.
        _pendingCounts.remove(write);
      }
    }();
    _pendingCounts.add(write);
    await write;
  }

  ({String? childId, int? seconds}) _readProgress(
    T Function<T>(ProviderListenable<T> provider) read,
  ) => read(_progressProvider);

  ProviderListenable<({String? childId, int? seconds})> get _progressProvider =>
      rankingParentsProvider(widget.category.id).select((parents) {
        final parent = parents.valueOrNull
            ?.where((parent) => parent.id == widget.child.parentId)
            .firstOrNull;
        return (
          childId: parent?.progressChildId,
          seconds: parent?.progressSeconds,
        );
      });

  /// Keeps the time box on the bookmark as it moves under the dialog — off
  /// this unit by Finished or another device, or to another time — so the pill
  /// never writes back a time that no longer stands. A time being typed wins.
  void _followProgress(
    ({String? childId, int? seconds})? previous,
    ({String? childId, int? seconds}) next,
  ) {
    if (_progressTimer?.isActive ?? false) return;
    final seconds = next.childId == widget.child.id ? next.seconds : null;
    if (parseRankingProgressTime(_progressController.text)?.seconds ==
        seconds) {
      return;
    }
    _progressController.text = seconds == null
        ? ''
        : formatRankingProgressTime(seconds);
  }

  @override
  void initState() {
    super.initState();
    final container = ProviderScope.containerOf(context, listen: false);
    _actions = RankingsActions.detached(container);
    _media = container.read(mediaServiceProvider);
    _imageEdits = _media.referenceEdits.listen(_recordImageEdit);
    _current = widget.child;
    _nameController = TextEditingController(text: _current.name);
    _notesController = TextEditingController(text: _current.notes);
    _notesFocusNode = FocusNode();
    _openingProgress = _readProgress(ref.read);
    final openingSeconds = _openingProgress.childId == widget.child.id
        ? _openingProgress.seconds
        : null;
    _progressController = TextEditingController(
      text: openingSeconds == null
          ? ''
          : formatRankingProgressTime(openingSeconds),
    );
    _progressFocusNode = FocusNode();
    if (widget.focusProgress) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _progressFocusNode.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    unawaited(_commitText());
    if (_progressTimer?.isActive ?? false) {
      _progressTimer!.cancel();
      unawaited(_commitProgressTime());
    }
    if (!_cancelling) unawaited(_imageEdits.cancel());
    _nameController.dispose();
    _notesController.dispose();
    _notesFocusNode.dispose();
    _progressController.dispose();
    _progressFocusNode.dispose();
    super.dispose();
  }

  void _scheduleProgressSave() {
    _progressTimer?.cancel();
    _progressTimer = Timer(
      _saveDebounce,
      () => unawaited(_commitProgressTime()),
    );
  }

  /// Typing a time bookmarks this unit at it. Something that does not read as
  /// a time is left unsaved until it does.
  Future<void> _commitProgressTime() async {
    final parsed = parseRankingProgressTime(_progressController.text);
    if (parsed == null) return;
    _writtenProgress = (childId: widget.child.id, seconds: parsed.seconds);
    await _actions.setProgress(
      widget.child.parentId,
      widget.child.id,
      seconds: parsed.seconds,
    );
  }

  Future<void> _toggleProgress({required bool bookmarked}) async {
    _progressTimer?.cancel();
    if (bookmarked) {
      _progressController.clear();
      _writtenProgress = (childId: null, seconds: null);
      await _actions.clearProgress(widget.child.parentId);
    } else {
      // A time only half typed (`14:`) bookmarks the start rather than
      // leaving the tap to do nothing.
      if (parseRankingProgressTime(_progressController.text) == null) {
        _progressController.clear();
      }
      await _commitProgressTime();
    }
  }

  void _scheduleTextSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(_saveDebounce, () => unawaited(_commitText()));
  }

  Future<void> _commitText() async {
    final name = _nameController.text.trim();
    if (name == _current.name && _notesController.text == _current.notes) {
      return;
    }
    await _save(
      _current.copyWith(
        name: name.isEmpty ? _current.name : name,
        notes: _notesController.text,
      ),
    );
  }

  /// Editing the date a unit was added never moves it in the list: the saved
  /// order is the one the user dragged, and a date is a fact about the unit
  /// rather than a position (§3.5).
  Future<void> _pickCreatedAt(BuildContext pillContext, Color accent) async {
    final initial = _current.createdAt.toLocal();
    final picked = await showContextualPopover<DateTime>(
      context: context,
      buttonContext: pillContext,
      width: kDateSelectorPopoverSize.width,
      height: kDateSelectorPopoverSize.height,
      accentColor: accent,
      builder: (context) => DateSelectorPopover(
        initialStartDate: initial,
        initialEndDate: initial,
        singleDateMode: true,
        inlineMode: true,
        accentColor: accent,
        onDateSelected: (date) => Navigator.of(context).pop(date),
      ),
    );
    if (picked == null) return;
    await _save(
      _current.copyWith(
        createdAt: DateTime(picked.year, picked.month, picked.day).toUtc(),
      ),
    );
  }

  /// Writes only what changed since [_current] — the unit and its entry may
  /// both have moved on since this dialog opened, on this device or another.
  Future<void> _save(RankingChild next) async {
    // Nothing after Cancel's own write: a wheel's score is written as its
    // number is taken away, and Cancel pressed from the keyboard takes it away
    // without the pointer ever leaving it.
    if (_cancelling) return;
    final previous = _current;
    _current = next;
    await _actions.saveChild(next, previous: previous);
    if (mounted) setState(() {});
  }

  /// Every edit here is already written, so Cancel writes the unit back to how
  /// it opened. Only what this dialog changed is put back: anything another
  /// device wrote meanwhile stays. Pending text is dropped rather than flushed
  /// by [dispose].
  void _cancel() {
    _saveTimer?.cancel();
    _nameController.text = widget.child.name;
    _notesController.text = widget.child.notes;
    unawaited(_save(widget.child));
    _cancelling = true;
    _progressTimer?.cancel();
    final written = _writtenProgress;
    if (written != null) {
      unawaited(
        _actions.revertProgress(
          widget.child.parentId,
          from: written,
          to: _openingProgress,
        ),
      );
    }
    unawaited(
      // A tap that failed applied nothing, so it has nothing to take back —
      // the rest still are.
      Future.wait([
        for (final write in _pendingCounts) write.catchError((Object _) {}),
      ]).then((_) async {
        if (_countTaps != 0) {
          // Taking back a − is a +, and that isn't having it.
          await _actions.adjustCount(
            widget.child.id,
            parentId: widget.child.parentId,
            delta: -_countTaps,
            starts: false,
          );
        }
      }),
    );
    unawaited(_restoreImages());
    Navigator.pop(context);
  }

  /// An attach and a removal of the same image cancel out, so a removal taken
  /// back by the toast's Undo leaves nothing for Cancel to do.
  void _recordImageEdit(({MediaReference reference, bool removed}) edit) {
    final image = edit.reference;
    if (image.collection != FirestoreCollections.rankings ||
        image.documentId != widget.child.id) {
      return;
    }
    if (edit.removed) {
      if (!_attachedImages.remove(image.id)) _removedImages[image.id] = image;
    } else {
      if (_removedImages.remove(image.id) == null) {
        _attachedImages.add(image.id);
      }
    }
  }

  /// Waits out any attach still ingesting, so an image pasted just before
  /// Cancel is taken back too, then undoes this dialog's own image edits —
  /// the same pair the gallery's own undo uses, so a removed image returns to
  /// its old slot.
  Future<void> _restoreImages() async {
    await _media.attachesSettled();
    await _imageEdits.cancel();
    for (final id in _attachedImages) {
      await _media.removeReference(id);
    }
    for (final image in _removedImages.values) {
      try {
        await _media.restoreReference(image);
      } on RestoreSuperseded {
        // A pull already put it back.
      }
    }
  }

  /// Whether the entry's bookmark is on this unit, and the time to type it at.
  Widget _buildProgressRow(Color accent) {
    ref.listen(_progressProvider, _followProgress);
    final progress = _readProgress(ref.watch);
    final bookmarked = progress.childId == widget.child.id;
    return Row(
      children: [
        SelectorPill(
          label: 'Stopped here',
          icon: bookmarked
              ? PhosphorIconsFill.bookmarkSimple
              : PhosphorIconsRegular.bookmarkSimple,
          dense: true,
          accentColor: accent,
          isActive: bookmarked,
          fillWhenActive: true,
          onTap: widget.readOnly
              ? () {}
              : () => _toggleProgress(bookmarked: bookmarked),
        ),
        const SizedBox(width: 10),
        SizedBox(
          width: 88,
          // The field has no style of its own to take; a smaller body font
          // keeps `1:23:45` clear of the box's edges at this width. The
          // tighter line is for the caret, which takes its height from it:
          // at the font's own leading it reached up to the `At` label.
          child: Theme(
            data: Theme.of(context).copyWith(
              textTheme: Theme.of(context).textTheme.copyWith(
                bodyLarge: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(height: 1.25),
              ),
            ),
            child: LabeledTextField(
              label: 'At',
              hintText: '0:00',
              controller: _progressController,
              focusNode: _progressFocusNode,
              enabled: !widget.readOnly,
              accentColor: accent,
              // Explicit padding, not `dense`: dense loses its vertical
              // padding to the desktop's compact density, and the borders sat
              // on the text. 9 around the 15px line makes the box the dense
              // pill's 25px once the desktop's compact density has taken its
              // 8px back.
              allowShortHeight: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 9,
              ),
              keyboardType: TextInputType.datetime,
              inputFormatters: [
                TextInputFormatter.withFunction(
                  (oldValue, newValue) =>
                      rankingProgressTimeTyping.hasMatch(newValue.text)
                      ? newValue
                      : oldValue,
                ),
              ],
              onChanged: (_) => _scheduleProgressSave(),
              onSubmitted: (_) {
                _progressTimer?.cancel();
                unawaited(_commitProgressTime());
                final parsed = parseRankingProgressTime(
                  _progressController.text,
                );
                final seconds = parsed?.seconds;
                if (seconds != null) {
                  _progressController.text = formatRankingProgressTime(seconds);
                }
              },
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final accent = paletteColor(widget.category.colorValue, context);
    final fields = widget.category.activeChildTemplate;

    final takesImages = widget.category.imagesOnChild && !widget.readOnly;

    // A cap, not a fixed height: a unit with little to it gets a short
    // dialog instead of one padded out with empty space.
    final body = ConstrainedBox(
      constraints: const BoxConstraints.tightFor(
        width: 560,
      ).copyWith(maxHeight: 520),
      child: VoyagerScrollView(
        // Headroom for the name field's floating label, which rides half its
        // own height above the field and would otherwise be shaved off by the
        // scroll view's clip. Taken back out of the dialog's content padding.
        padding: const EdgeInsets.only(top: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            LabeledTextField(
              label: widget.category.childUnitLabel,
              controller: _nameController,
              enabled: !widget.readOnly,
              accentColor: accent,
              onChanged: (_) => _scheduleTextSave(),
            ),
            const SizedBox(height: 12),
            RankingOverallRow(
              value: _current.overallScore,
              scoreMax: widget.category.childScoreMax,
              precision: widget.category.childScorePrecision,
              accentColor: accent,
              label: 'Overall',
              semanticLabel: _current.overallScore == null
                  ? 'Not scored'
                  : 'Overall ${formatRankingScore(_current.overallScore!)}',
              onChanged: widget.readOnly
                  ? null
                  : (score) => _save(
                      score == null
                          ? _current.copyWith(clearOverallScore: true)
                          : _current.copyWith(overallScore: score),
                    ),
            ),
            if (widget.category.showsProgress) ...[
              const SizedBox(height: 12),
              _buildProgressRow(accent),
            ],
            if (widget.category.showsChildCount) ...[
              const SizedBox(height: 12),
              RankingCountStepper(
                entryId: widget.child.id,
                accent: accent,
                onAdjust: widget.readOnly ? null : _adjustCount,
              ),
            ],
            if (fields.isNotEmpty) ...[
              const SizedBox(height: 20),
              RankingTemplateFieldsBand(
                accent: accent,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final (index, field) in fields.indexed)
                      RankingFieldEditor(
                        key: ValueKey(field.id),
                        field: field,
                        showTopDivider: index > 0,
                        value:
                            _current.fieldValues[field.id] ??
                            const RankingFieldValue(),
                        precision: rankingFieldPrecision(
                          field,
                          overallPrecision: widget.category.childScorePrecision,
                        ),
                        accentColor: accent,
                        readOnly: widget.readOnly,
                        onChanged: (value) => _save(
                          _current.copyWith(
                            fieldValues: {
                              ..._current.fieldValues,
                              field.id: value,
                            },
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
            ] else
              // With no template the band that carried this gap is not built,
              // and the notes box ended up flush against the overall row's
              // stars. Keep the same breathing room either way.
              const SizedBox(height: 20),
            TagHighlightedTextField(
              controller: _notesController,
              focusNode: _notesFocusNode,
              onChanged: (_) => _scheduleTextSave(),
              label: 'Notes',
              accentColor: accent,
              readOnly: widget.readOnly,
              minLines: 3,
              maxLines: 10,
            ),
            if (widget.category.childUnitsEnabled &&
                widget.category.imagesOnChild) ...[
              const SizedBox(height: 14),
              MediaGalleryStrip(
                collection: FirestoreCollections.rankings,
                documentId: _current.id,
                accentColor: accent,
              ),
            ],
            // Same as the entry panel: the date sits last and speaks for
            // itself.
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerLeft,
              child: Builder(
                builder: (pillContext) => SelectorPill(
                  label: DateFormat.yMMMd().format(
                    _current.createdAt.toLocal(),
                  ),
                  dense: true,
                  accentColor: accent,
                  onTap: widget.readOnly
                      ? () {}
                      : () => _pickCreatedAt(pillContext, accent),
                ),
              ),
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );

    final dialog = AlertDialog(
      contentPadding: const EdgeInsets.fromLTRB(24, 10, 24, 0),
      // Ctrl+V anywhere in this editor attaches to this unit's gallery — the
      // name and notes fields have nothing to take from an image-only
      // clipboard, so there is nowhere else for it to land.
      content: takesImages
          ? MediaPasteScope(
              collection: FirestoreCollections.rankings,
              documentId: _current.id,
              child: body,
            )
          : body,
      actions: [
        if (!widget.readOnly)
          GlassButton(onPressed: _cancel, label: 'Cancel', dense: true),
        GlassButton(
          onPressed: () => Navigator.pop(context),
          label: 'Done',
          dense: true,
        ),
      ],
    );
    // Done, like the button: the pop is the flush, via dispose's _commitText.
    return CtrlEnterToSubmitScope(
      onSubmit: () => Navigator.pop(context),
      child: dialog,
    );
  }
}
