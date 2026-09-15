import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/core/media/widgets/media_gallery_strip.dart';
import 'package:voyager/core/media/widgets/media_paste_scope.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/theme/palette_color.dart';
import 'package:voyager/core/widgets/contextual_popover.dart';
import 'package:voyager/core/widgets/date_selector_popover.dart';
import 'package:voyager/core/widgets/edit_side_panel_host.dart';
import 'package:voyager/core/widgets/labeled_text_field.dart';
import 'package:voyager/core/widgets/selector_pill.dart';
import 'package:voyager/core/widgets/tag_highlighted_text_field.dart';
import 'package:voyager/core/widgets/voyager_scroll_view.dart';
import 'package:voyager/domain/models/ranking_models.dart';
import 'package:voyager/domain/rankings/ranking_queries.dart';
import 'package:voyager/features/rankings/rankings_actions.dart';
import 'package:voyager/features/rankings/rankings_child_list.dart';
import 'package:voyager/features/rankings/rankings_field_editor.dart';
import 'package:voyager/features/rankings/rankings_score_stars.dart';
import 'package:voyager/features/rankings/rankings_tags_field.dart';

/// Default editor panel width — see [EditSidePanelMetrics.defaultWidth].
const rankingsEditPanelWidth = EditSidePanelMetrics.defaultWidth;

/// Editor for one entry, in the todo and Jobs side-panel idiom.
///
/// Text autosaves on a debounce; everything picked from a control saves at
/// once. Every route goes through [RankingsActions.saveParent], which is what
/// applies the two rules an edit can trip — the queued → in-progress promotion
/// and the star clearing on a section crossing — so no control here has to
/// remember them.
class RankingsEditPanel extends ConsumerStatefulWidget {
  const RankingsEditPanel({
    super.key,
    required this.parent,
    required this.category,
    required this.children,
    required this.tagSuggestions,
    required this.onClose,
    this.readOnly = false,
  });

  final RankingParent parent;
  final RankingCategory category;
  final List<RankingChild> children;

  /// The category's structured tags, most-used first (§5.2). Passed in rather
  /// than derived here: the page already holds every parent, and the panel
  /// only ever sees one of them.
  final List<String> tagSuggestions;

  final VoidCallback onClose;

  /// An archived category is readable but not editable (§7.4).
  final bool readOnly;

  @override
  ConsumerState<RankingsEditPanel> createState() => _RankingsEditPanelState();
}

class _RankingsEditPanelState extends ConsumerState<RankingsEditPanel> {
  static const _saveDebounce = Duration(milliseconds: 400);

  late final TextEditingController _titleController;
  late final TextEditingController _notesController;
  late final FocusNode _notesFocusNode;
  Timer? _saveTimer;

  /// The last version this panel wrote, which is what the next save diffs
  /// against. Held separately from `widget.parent` because the provider
  /// refresh that carries a save back lands a frame or two later, and diffing
  /// against a stale copy would re-apply the in-progress promotion.
  late RankingParent _current;

  /// Resolved while the panel is alive. `dispose` flushes pending text, and by
  /// then the panel's `ref` throws, so the flush used to fail silently and the
  /// last 400ms of typing was lost on every close.
  late final RankingsActions _actions;

  /// Saves started and not yet finished. While any are, a rebuild can carry a
  /// reload started by an *earlier* save, and adopting it would drop the edits
  /// still on their way to disk — see [didUpdateWidget].
  var _savesInFlight = 0;

  @override
  void initState() {
    super.initState();
    _actions = RankingsActions.detached(
      ProviderScope.containerOf(context, listen: false),
    );
    _current = widget.parent;
    _titleController = TextEditingController(text: _current.title);
    _notesController = TextEditingController(text: _current.notes);
    _notesFocusNode = FocusNode();
  }

  @override
  void didUpdateWidget(RankingsEditPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.parent.id == widget.parent.id) {
      // Same entry: keep whatever the user is typing, but take everything the
      // list or the quick-rate may have changed underneath — unless a save is
      // still out and this copy predates it.
      if (_savesInFlight == 0 || widget.parent.version >= _current.version) {
        _current = widget.parent;
      }
      return;
    }
    // A different entry: flush the old one's pending text before the
    // controllers are pointed at new writing.
    _saveTimer?.cancel();
    unawaited(_commitText());
    _current = widget.parent;
    _titleController.text = _current.title;
    _notesController.text = _current.notes;
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    // Fire-and-forget: dispose cannot be async, and the repository write does
    // not need this widget to still exist.
    unawaited(_commitText());
    _titleController.dispose();
    _notesController.dispose();
    _notesFocusNode.dispose();
    super.dispose();
  }

  void _scheduleTextSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(_saveDebounce, () => unawaited(_commitText()));
  }

  Future<void> _commitText() async {
    final title = _titleController.text.trim();
    if (title == _current.title && _notesController.text == _current.notes) {
      return;
    }
    await _save(
      _current.copyWith(
        // A blank title is refused rather than stored: it is the one thing an
        // entry is required to have, and a row with nothing to click is worse
        // than a title the user has to finish deleting.
        title: title.isEmpty ? _current.title : title,
        notes: _notesController.text,
      ),
    );
  }

  /// [rebuild] is off for a save whose control already shows what it wrote —
  /// the tag field holds its own list until the page's re-read brings the
  /// entry back, and that re-read rebuilds this panel anyway. Rebuilding for
  /// the save as well drew the whole panel twice for one chip.
  Future<void> _save(RankingParent next, {bool rebuild = true}) async {
    final previous = _current;
    _current = next;
    _savesInFlight++;
    final RankingParent? saved;
    try {
      saved = await _actions.saveParent(next, previous: previous);
    } finally {
      _savesInFlight--;
    }
    // Only the last save's result is adopted: an earlier one finishing while a
    // later is still out would put back the row without the later edit.
    if (!mounted || saved == null || _savesInFlight > 0) return;
    if (!rebuild) {
      _current = saved;
      return;
    }
    setState(() => _current = saved!);
  }

  Future<void> _pickCreatedAt(BuildContext pillContext) async {
    final initial = _current.createdAt.toLocal();
    final picked = await showContextualPopover<DateTime>(
      context: context,
      buttonContext: pillContext,
      // Both are needed: the calendar hangs its grid off an Expanded, so a
      // popover left to size itself gives that grid no height at all.
      width: 320,
      height: 380,
      accentColor: _accent,
      builder: (context) => DateSelectorPopover(
        initialStartDate: initial,
        initialEndDate: initial,
        singleDateMode: true,
        inlineMode: true,
        accentColor: _accent,
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

  Color get _accent => paletteColor(widget.category.colorValue, context);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = _accent;
    final category = widget.category;
    final fields = category.activeParentTemplate;
    final scoredChildren = widget.children
        .where((child) => child.overallScore != null)
        .length;

    final panel = Container(
      // No fill of its own (§9.1): the panel is a column of the same page, and
      // a surface behind it made the list look like the thing being framed.
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _PanelHeader(onClose: widget.onClose),
          Expanded(
            child: VoyagerScrollView(
              // The top inset clears the title's floating label, which rides
              // half its own height above the field. The scroll view clips
              // anything above its viewport, and at the panel's old 4 the
              // ascenders of 'Title' were being shaved off.
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  LabeledTextField(
                    label: 'Title',
                    controller: _titleController,
                    enabled: !widget.readOnly,
                    accentColor: accent,
                    // Shorter than the 18 a field defaults to: the panel opens
                    // on this box, and the slack above and below one line of
                    // title was the tallest thing in the editor. The box drops
                    // under Material's 48px minimum doing it, so it also has
                    // to opt out of the stretch that would otherwise re-centre
                    // its text away from the padding — see [allowShortHeight].
                    allowShortHeight: true,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 14,
                    ),
                    onChanged: (_) => _scheduleTextSave(),
                  ),
                  const SizedBox(height: 12),
                  RankingOverallRow(
                    value: _current.overallScore,
                    scoreMax: category.parentScoreMax,
                    precision: category.parentScorePrecision,
                    accentColor: accent,
                    label: 'Overall',
                    semanticLabel: _current.overallScore == null
                        ? 'Not scored'
                        : 'Overall '
                              '${formatRankingScore(_current.overallScore!)}',
                    onChanged: widget.readOnly
                        ? null
                        : (score) => _save(
                            score == null
                                ? _current.copyWith(clearOverallScore: true)
                                : _current.copyWith(overallScore: score),
                          ),
                  ),
                  const SizedBox(height: 12),
                  RankingTagsField(
                    tags: _current.tags,
                    suggestions: widget.tagSuggestions,
                    accentColor: accent,
                    enabled: !widget.readOnly,
                    onChanged: (tags) =>
                        _save(_current.copyWith(tags: tags), rebuild: false),
                    onChipRemoved: (tag, index) => offerRankingTagUndo(
                      context,
                      ref,
                      parentId: _current.id,
                      tag: tag,
                      index: index,
                    ),
                  ),
                  if (!_current.isRanked) ...[
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        for (final status in RankingStatus.values) ...[
                          SelectorPill(
                            label: status == RankingStatus.inProgress
                                ? 'In progress'
                                : 'Queued',
                            dense: true,
                            accentColor: accent,
                            isActive: _current.status == status,
                            // Filled rather than outlined: these two are a
                            // one-of-two choice, and a border alone read as
                            // "focused" more than as "picked".
                            fillWhenActive: true,
                            onTap: widget.readOnly
                                ? () {}
                                : () => _save(
                                    _current.copyWith(status: status),
                                  ),
                          ),
                          const SizedBox(width: 6),
                        ],
                      ],
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
                                overallPrecision: category.parentScorePrecision,
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
                    // With no template the band that carried this gap is not
                    // built, and the notes box ended up flush against the
                    // overall row's stars. Keep the same breathing room
                    // either way.
                    const SizedBox(height: 20),
                  TagHighlightedTextField(
                    controller: _notesController,
                    focusNode: _notesFocusNode,
                    onChanged: (_) => _scheduleTextSave(),
                    label: 'Notes',
                    accentColor: accent,
                    readOnly: widget.readOnly,
                    style: theme.textTheme.bodySmall,
                    minLines: 4,
                    maxLines: 14,
                  ),
                  if (category.imagesOnParent) ...[
                    const SizedBox(height: 16),
                    MediaGalleryStrip(
                      collection: FirestoreCollections.rankings,
                      documentId: _current.id,
                      accentColor: accent,
                    ),
                  ],
                  if (category.childUnitsEnabled) ...[
                    const SizedBox(height: 20),
                    const Divider(height: 1),
                    const SizedBox(height: 12),
                    RankingsChildList(
                      parent: _current,
                      category: category,
                      children: widget.children,
                      readOnly: widget.readOnly,
                      scoredChildren: scoredChildren,
                      onAverageFromChildren: () async {
                        final average = rankingAverageFromChildren(
                          widget.children,
                          scoreMax: category.parentScoreMax,
                          precision: category.parentScorePrecision,
                        );
                        if (average == null) return;
                        await _save(_current.copyWith(overallScore: average));
                      },
                    ),
                  ],
                  // Last thing in the panel, and unlabelled: the date an entry
                  // was started is the least of what this screen holds, and a
                  // lone date capsule needs no word in front of it.
                  const SizedBox(height: 20),
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
                            : () => _pickCreatedAt(pillContext),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );

    // Ctrl+V anywhere in the panel attaches to the entry's own gallery: the
    // title and notes fields cannot take an image, so an image-only clipboard
    // has no other target here. A child's pictures are pasted in the child's
    // own editor, which carries its own scope.
    return category.imagesOnParent && !widget.readOnly
        ? MediaPasteScope(
            collection: FirestoreCollections.rankings,
            documentId: _current.id,
            child: panel,
          )
        : panel;
  }
}

/// Close, and nothing else (§9.1).
///
/// The trash that used to sit opposite it is gone: deleting an entry belongs
/// with the rest of what you can do to one, in the row's context menu, rather
/// than one mis-aim away from the close button.
class _PanelHeader extends StatelessWidget {
  const _PanelHeader({required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      child: Row(
        children: [
          const Spacer(),
          IconButton(
            onPressed: onClose,
            tooltip: 'Close',
            iconSize: 16,
            visualDensity: VisualDensity.compact,
            icon: const Icon(PhosphorIconsRegular.x),
          ),
        ],
      ),
    );
  }
}
