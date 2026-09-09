import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:intl/intl.dart';
import 'package:voyager/core/media/widgets/media_gallery_strip.dart';
import 'package:voyager/core/media/widgets/media_paste_scope.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/theme/voyager_list_item_surface.dart';
import 'package:voyager/core/widgets/context_menu.dart';
import 'package:voyager/core/widgets/contextual_popover.dart';
import 'package:voyager/core/widgets/date_selector_popover.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/labeled_text_field.dart';
import 'package:voyager/core/widgets/selector_pill.dart';
import 'package:voyager/core/widgets/tag_highlighted_text_field.dart';
import 'package:voyager/core/widgets/voyager_dialog.dart';
import 'package:voyager/core/widgets/voyager_scroll_view.dart';
import 'package:voyager/domain/models/ranking_models.dart';
import 'package:voyager/domain/rankings/ranking_queries.dart';
import 'package:voyager/features/rankings/rankings_actions.dart';
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
      sortOrder: widget.children.isEmpty
          ? 0
          : widget.children
                    .map((child) => child.sortOrder)
                    .reduce((a, b) => a > b ? a : b) +
                1,
    );
    if (mounted) _addFocusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = Color(widget.category.colorValue);
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
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              'No ${label.toLowerCase()}s yet.',
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
                  category: widget.category,
                  parent: widget.parent,
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
    final selected = await showMenu<({RankingChildSort sort, String? fieldId})>(
      context: buttonContext,
      position: _menuPosition(buttonContext),
      items: [
        const PopupMenuItem(
          value: (sort: RankingChildSort.saved, fieldId: null),
          child: Text('Manual order'),
        ),
        const PopupMenuItem(
          value: (sort: RankingChildSort.name, fieldId: null),
          child: Text('Name'),
        ),
        const PopupMenuItem(
          value: (sort: RankingChildSort.overallScore, fieldId: null),
          child: Text('Overall score'),
        ),
        for (final field in fields)
          PopupMenuItem(
            value: (sort: RankingChildSort.customField, fieldId: field.id),
            child: Text(field.label),
          ),
      ],
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
    required this.category,
    required this.parent,
    required this.accent,
    required this.draggable,
    required this.readOnly,
    required this.showDivider,
  });

  final int index;
  final RankingChild child;
  final RankingCategory category;
  final RankingParent parent;
  final Color accent;
  final bool draggable;
  final bool readOnly;

  /// Off on the last row: the hairline separates one unit from the next, and a
  /// trailing one would only rule the list off from the box that adds to it.
  final bool showDivider;

  @override
  ConsumerState<_ChildRow> createState() => _ChildRowState();
}

class _ChildRowState extends ConsumerState<_ChildRow> {
  var _hovered = false;

  /// The score the open score popover is sitting on, so the number on the row
  /// tracks the roller instead of waiting for the commit.
  double? _draftScore;

  /// Wide enough for the longest score a scale prints, so the numbers down the
  /// list stay in a column whether or not a unit has been scored.
  static const _scoreWidth = 26.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final child = widget.child;
    final score = _draftScore ?? child.overallScore;
    final scored = score != null;

    return ContextMenuRegion(
      itemsBuilder: () => [
        if (!widget.readOnly && scored)
          ContextMenuItem(
            label: 'Clear score',
            icon: PhosphorIconsRegular.eraser,
            onTap: () => RankingsActions(ref).saveChild(
              child.copyWith(clearOverallScore: true),
              parent: widget.parent,
            ),
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
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Material(
                type: MaterialType.transparency,
                child: InkWell(
                  onTap: () => showRankingChildEditor(
                    context,
                    child: child,
                    parent: widget.parent,
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
                          onDraftChanged: (draft) =>
                              setState(() => _draftScore = draft),
                          width: _scoreWidth,
                          textAlign: TextAlign.right,
                          style: theme.textTheme.labelMedium?.copyWith(
                            fontWeight: scored ? FontWeight.w700 : null,
                          ),
                          onChanged: widget.readOnly
                              ? null
                              : (score) => RankingsActions(ref).saveChild(
                                  score == null
                                      ? child.copyWith(clearOverallScore: true)
                                      : child.copyWith(overallScore: score),
                                  parent: widget.parent,
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
  required RankingParent parent,
  required RankingCategory category,
  bool readOnly = false,
}) {
  return showVoyagerDialog<void>(
    context: context,
    builder: (context) => _ChildEditorDialog(
      child: child,
      parent: parent,
      category: category,
      readOnly: readOnly,
    ),
  );
}

class _ChildEditorDialog extends ConsumerStatefulWidget {
  const _ChildEditorDialog({
    required this.child,
    required this.parent,
    required this.category,
    required this.readOnly,
  });

  final RankingChild child;
  final RankingParent parent;
  final RankingCategory category;
  final bool readOnly;

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

  @override
  void initState() {
    super.initState();
    _current = widget.child;
    _nameController = TextEditingController(text: _current.name);
    _notesController = TextEditingController(text: _current.notes);
    _notesFocusNode = FocusNode();
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    unawaited(_commitText());
    _nameController.dispose();
    _notesController.dispose();
    _notesFocusNode.dispose();
    super.dispose();
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
      width: 320,
      height: 380,
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

  Future<void> _save(RankingChild next) async {
    _current = next;
    await RankingsActions(ref).saveChild(next, parent: widget.parent);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final accent = Color(widget.category.colorValue);
    final fields = widget.category.activeChildTemplate;

    final takesImages = widget.category.imagesOnChild && !widget.readOnly;

    final body = SizedBox(
      width: 460,
      height: 520,
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
            ],
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
                  label: DateFormat.yMMMd().format(_current.createdAt.toLocal()),
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

    return AlertDialog(
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
          GlassButton(
            onPressed: () async {
              final deleted = await confirmDeleteRankingChild(
                context,
                ref,
                _current,
              );
              if (deleted && context.mounted) Navigator.pop(context);
            },
            label: 'Delete',
            color: Theme.of(context).colorScheme.error,
            dense: true,
          ),
        GlassButton(
          onPressed: () => Navigator.pop(context),
          label: 'Done',
          dense: true,
        ),
      ],
    );
  }
}
