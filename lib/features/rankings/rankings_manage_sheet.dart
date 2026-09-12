import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/core/widgets/confirm_dialog.dart';
import 'package:voyager/core/widgets/ctrl_enter_to_submit_scope.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/labeled_text_field.dart';
import 'package:voyager/core/widgets/prompt_name_dialog.dart';
import 'package:voyager/core/widgets/selector_pill.dart';
import 'package:voyager/core/widgets/voyager_checkbox.dart';
import 'package:voyager/core/widgets/voyager_dialog.dart';
import 'package:voyager/core/widgets/voyager_scroll_view.dart';
import 'package:voyager/domain/models/ranking_models.dart';
import 'package:voyager/domain/rankings/ranking_queries.dart';
import 'package:voyager/features/rankings/rankings_actions.dart';
import 'package:voyager/features/rankings/rankings_category_dialog.dart';
import 'package:voyager/features/rankings/rankings_icons.dart';
import 'package:voyager/core/widgets/scroll_offset_isolate.dart';

/// Everything the page configures: the categories themselves, their scales and
/// switches, and their two field templates.
///
/// One sheet rather than a settings page because all of it is per-category —
/// there is no app-level rankings setting to put anywhere else.
/// [initialCategoryId] is the category the page is showing, so the sheet opens
/// on the one being looked at rather than always on the first in the list.
Future<void> showRankingsManageSheet(
  BuildContext context,
  WidgetRef ref, {
  String? initialCategoryId,
}) async {
  await showVoyagerDialog<void>(
    context: context,
    builder: (context) =>
        _RankingsManageDialog(initialCategoryId: initialCategoryId),
  );
  invalidateRankingProvidersFrom(ref);
}

enum _ManageTab { settings, parentTemplate, childTemplate }

class _RankingsManageDialog extends ConsumerStatefulWidget {
  const _RankingsManageDialog({this.initialCategoryId});

  final String? initialCategoryId;

  @override
  ConsumerState<_RankingsManageDialog> createState() =>
      _RankingsManageDialogState();
}

class _RankingsManageDialogState extends ConsumerState<_RankingsManageDialog> {
  late String? _selectedId = widget.initialCategoryId;
  var _tab = _ManageTab.settings;

  RankingsActions get _actions => RankingsActions(ref);

  @override
  Widget build(BuildContext context) {
    final categories =
        ref.watch(rankingCategoriesProvider).valueOrNull ??
        const <RankingCategory>[];
    final selected =
        categories
            .where((category) => category.id == _selectedId)
            .firstOrNull ??
        categories.firstOrNull;

    final dialog = AlertDialog(
      title: const Text('Manage rankings'),
      content: SizedBox(
        width: 720,
        height: 460,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: 200,
              child: _CategoryList(
                categories: categories,
                selectedId: selected?.id,
                onSelect: (id) => setState(() => _selectedId = id),
                onCreate: _createCategory,
                onReorder: _actions.reorderCategories,
              ),
            ),
            const VerticalDivider(width: 1),
            Expanded(
              child: selected == null
                  ? const Center(child: Text('No categories yet.'))
                  : _CategoryPane(
                      category: selected,
                      tab: _tab,
                      onTab: (tab) => setState(() => _tab = tab),
                    ),
            ),
          ],
        ),
      ),
      actions: [
        GlassButton(
          onPressed: () => Navigator.pop(context),
          label: 'Done',
          dense: true,
        ),
      ],
    );
    return CtrlEnterToSubmitScope(
      onSubmit: () => Navigator.pop(context),
      child: dialog,
    );
  }

  Future<void> _createCategory() async {
    final categories =
        ref.read(rankingCategoriesProvider).valueOrNull ??
        const <RankingCategory>[];
    final result = await showRankingCategoryDialog(context);
    if (result == null) return;
    final created = await _actions.createCategory(
      name: result.name,
      colorValue: result.color,
      iconKey: result.iconKey,
      sortOrder: categories.length,
    );
    if (mounted) setState(() => _selectedId = created.id);
  }
}

/// The categories, in the order the picker offers them (§2.2).
///
/// Reordering lives here and nowhere else now: it is a thing you do once, when
/// a list stops being the one you open first, and it was costing the page a
/// whole tier of chrome to keep a drag handle within reach every day.
class _CategoryList extends StatelessWidget {
  const _CategoryList({
    required this.categories,
    required this.selectedId,
    required this.onSelect,
    required this.onCreate,
    required this.onReorder,
  });

  final List<RankingCategory> categories;
  final String? selectedId;
  final ValueChanged<String> onSelect;
  final VoidCallback onCreate;
  final ValueChanged<List<String>> onReorder;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          // One dialog route holds this list and both right-hand panes, so
          // swapping panes would otherwise hand a remounted scrollable this
          // list's saved offset — see [ScrollOffsetIsolate].
          child: ScrollOffsetIsolate(
            child: ReorderableListView.builder(
              buildDefaultDragHandles: false,
              itemCount: categories.length,
              // onReorderItem, not onReorder: it already adjusts newIndex for
              // the removed row, which the deprecated callback leaves to the
              // caller to get right.
              onReorderItem: (oldIndex, newIndex) {
                final ids = [for (final c in categories) c.id];
                ids.insert(newIndex, ids.removeAt(oldIndex));
                onReorder(ids);
              },
              itemBuilder: (context, index) {
                final category = categories[index];
                final selected = category.id == selectedId;
                return ReorderableDelayedDragStartListener(
                  key: ValueKey(category.id),
                  index: index,
                  child: ListTile(
                    dense: true,
                    selected: selected,
                    selectedTileColor: Color(
                      category.colorValue,
                    ).withValues(alpha: 0.12),
                    leading: Icon(
                      rankingCategoryIcon(category.iconKey),
                      size: 18,
                      color: Color(category.colorValue),
                    ),
                    title: Text(
                      category.name,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium,
                    ),
                    subtitle: category.isArchived
                        ? Text('Archived', style: theme.textTheme.labelSmall)
                        : null,
                    onTap: () => onSelect(category.id),
                  ),
                );
              },
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
          child: Align(
            alignment: Alignment.centerLeft,
            child: GlassButton(
              dense: true,
              onPressed: onCreate,
              icon: const Icon(PhosphorIconsRegular.plus, size: 13),
              label: 'New category',
            ),
          ),
        ),
      ],
    );
  }
}

class _CategoryPane extends ConsumerWidget {
  const _CategoryPane({
    required this.category,
    required this.tab,
    required this.onTab,
  });

  final RankingCategory category;
  final _ManageTab tab;
  final ValueChanged<_ManageTab> onTab;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: SegmentedButton<_ManageTab>(
            showSelectedIcon: false,
            style: SegmentedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
            ),
            segments: [
              const ButtonSegment(
                value: _ManageTab.settings,
                label: Text('Settings'),
              ),
              const ButtonSegment(
                value: _ManageTab.parentTemplate,
                label: Text('Entry fields'),
              ),
              ButtonSegment(
                value: _ManageTab.childTemplate,
                label: Text('${category.childUnitLabel} fields'),
                enabled: category.childUnitsEnabled,
              ),
            ],
            selected: {tab},
            onSelectionChanged: (selection) => onTab(selection.first),
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: switch (tab) {
            _ManageTab.settings => _CategorySettings(category: category),
            _ManageTab.parentTemplate => _TemplateEditor(
              key: ValueKey('${category.id}-parent'),
              category: category,
              isParentTemplate: true,
            ),
            _ManageTab.childTemplate => _TemplateEditor(
              key: ValueKey('${category.id}-child'),
              category: category,
              isParentTemplate: false,
            ),
          },
        ),
      ],
    );
  }
}

class _CategorySettings extends ConsumerWidget {
  const _CategorySettings({required this.category});

  final RankingCategory category;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final actions = RankingsActions(ref);
    final accent = Color(category.colorValue);

    // Remounted by both the tab switch and picking another category, into
    // a route whose one page-storage slot the other panes also write —
    // see [ScrollOffsetIsolate].
    return ScrollOffsetIsolate(
      child: VoyagerScrollView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    category.name,
                    style: theme.textTheme.titleSmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                GlassButton(
                  dense: true,
                  color: accent,
                  onPressed: () async {
                    final result = await showRankingCategoryDialog(
                      context,
                      title: 'Edit category',
                      submitLabel: 'Save',
                      initialName: category.name,
                      initialColor: category.colorValue,
                      initialIconKey: category.iconKey,
                    );
                    if (result == null) return;
                    await actions.saveCategory(
                      category.copyWith(
                        name: result.name,
                        colorValue: result.color,
                        iconKey: result.iconKey,
                      ),
                    );
                  },
                  icon: const Icon(PhosphorIconsRegular.pencilSimple, size: 13),
                  label: 'Name, colour, icon',
                ),
              ],
            ),
            const SizedBox(height: 8),
            _Toggle(
              label: 'Child units',
              help: 'Episodes under a show, dishes at a restaurant.',
              value: category.childUnitsEnabled,
              accent: accent,
              onChanged: (value) => actions.saveCategory(
                category.copyWith(childUnitsEnabled: value),
              ),
            ),
            if (category.childUnitsEnabled) ...[
              const SizedBox(height: 8),
              _UnitLabelField(category: category),
            ],
            const Divider(height: 24),
            _Toggle(
              label: 'Images on entries',
              value: category.imagesOnParent,
              accent: accent,
              onChanged: (value) =>
                  actions.saveCategory(category.copyWith(imagesOnParent: value)),
            ),
            if (category.childUnitsEnabled)
              _Toggle(
                label: 'Images on ${category.childUnitLabel.toLowerCase()}s',
                value: category.imagesOnChild,
                accent: accent,
                onChanged: (value) =>
                    actions.saveCategory(category.copyWith(imagesOnChild: value)),
              ),
            const Divider(height: 24),
            _ScaleRow(
              label: 'Entry scale',
              scoreMax: category.parentScoreMax,
              accent: accent,
              onChanged: (value) =>
                  actions.saveCategory(category.copyWith(parentScoreMax: value)),
            ),
            _PrecisionRow(
              label: 'Entry step',
              help: 'Inherited by every entry field that has not opted out.',
              precision: category.parentScorePrecision,
              accent: accent,
              onChanged: (value) => _changeOverallPrecision(
                context,
                ref,
                category,
                isParent: true,
                precision: value,
              ),
            ),
            if (category.childUnitsEnabled) ...[
              const SizedBox(height: 8),
              _ScaleRow(
                label: '${category.childUnitLabel} scale',
                scoreMax: category.childScoreMax,
                accent: accent,
                onChanged: (value) =>
                    actions.saveCategory(category.copyWith(childScoreMax: value)),
              ),
              _PrecisionRow(
                label: '${category.childUnitLabel} step',
                precision: category.childScorePrecision,
                accent: accent,
                onChanged: (value) => _changeOverallPrecision(
                  context,
                  ref,
                  category,
                  isParent: false,
                  precision: value,
                ),
              ),
            ],
            const Divider(height: 24),
            Row(
              children: [
                GlassButton(
                  dense: true,
                  onPressed: () => actions.setCategoryArchived(
                    category,
                    archived: !category.isArchived,
                  ),
                  icon: Icon(
                    category.isArchived
                        ? PhosphorIconsRegular.arrowCounterClockwise
                        : PhosphorIconsRegular.archive,
                    size: 13,
                  ),
                  label: category.isArchived ? 'Unarchive' : 'Archive',
                ),
                const Spacer(),
                GlassButton(
                  dense: true,
                  color: theme.colorScheme.error,
                  onPressed: () async {
                    final entries = await ref
                        .read(rankingRepositoryProvider)
                        .listParents(category.id);
                    if (!context.mounted) return;
                    await confirmDeleteRankingCategory(
                      context,
                      ref,
                      category,
                      entryCount: entries.length,
                    );
                  },
                  icon: const Icon(PhosphorIconsRegular.trash, size: 13),
                  label: 'Delete',
                ),
              ],
            ),
            if (category.isArchived)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'Archived categories are hidden from the picker and open '
                  'read-only.',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The child-unit label gets its own field because it renames things all over
/// the page — the list's section header, the row's count, the fields tab.
class _UnitLabelField extends ConsumerStatefulWidget {
  const _UnitLabelField({required this.category});

  final RankingCategory category;

  @override
  ConsumerState<_UnitLabelField> createState() => _UnitLabelFieldState();
}

class _UnitLabelFieldState extends ConsumerState<_UnitLabelField> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.category.childUnitLabel);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final field = LabeledTextField(
      label: 'Unit name',
      controller: _controller,
      dense: true,
      // Taller than the dense default: this box sits alone under a toggle
      // rather than in a stack of compact fields, and 8px of vertical padding
      // reads as a slot rather than a field.
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      accentColor: Color(widget.category.colorValue),
      onSubmitted: _commit,
      onChanged: (_) {},
    );
    // Ctrl+Enter is Done, flushed: this box only commits on Enter, so closing
    // straight from it would drop the label being typed. Nearer than the
    // dialog's own scope, so it wins while the box has focus.
    return CtrlEnterToSubmitScope(
      onSubmit: () {
        _commit(_controller.text);
        Navigator.pop(context);
      },
      child: field,
    );
  }

  void _commit(String value) {
    final label = value.trim();
    if (label.isEmpty || label == widget.category.childUnitLabel) return;
    RankingsActions(
      ref,
    ).saveCategory(widget.category.copyWith(childUnitLabel: label));
  }
}

class _Toggle extends StatelessWidget {
  const _Toggle({
    required this.label,
    required this.value,
    required this.accent,
    required this.onChanged,
    this.help,
  });

  final String label;
  final String? help;
  final bool value;
  final Color accent;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: () => onChanged(!value),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            VoyagerCheckbox(
              value: value,
              onChanged: onChanged,
              accentColor: accent,
              celebrateOnComplete: false,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: theme.textTheme.bodyMedium),
                  if (help != null)
                    Text(
                      help!,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
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

class _ScaleRow extends StatelessWidget {
  const _ScaleRow({
    required this.label,
    required this.scoreMax,
    required this.accent,
    required this.onChanged,
  });

  final String label;
  final int scoreMax;
  final Color accent;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(child: Text(label, style: theme.textTheme.bodyMedium)),
          for (final option in rankingScoreMaxOptions) ...[
            SelectorPill(
              label: 'out of $option',
              dense: true,
              accentColor: accent,
              fillWhenActive: true,
              isActive: scoreMax == option,
              onTap: () => onChanged(option),
            ),
            const SizedBox(width: 6),
          ],
        ],
      ),
    );
  }
}

/// Add, rename, reorder, rescale, remove — and the orphan list that removing
/// feeds, which is the only way a field's stored values come back (§7.3).
class _TemplateEditor extends ConsumerWidget {
  const _TemplateEditor({
    super.key,
    required this.category,
    required this.isParentTemplate,
  });

  final RankingCategory category;
  final bool isParentTemplate;

  List<RankingTemplateField> get _all =>
      isParentTemplate ? category.parentTemplate : category.childTemplate;

  List<RankingTemplateField> get _active => [
    for (final field in _all)
      if (!field.isRemoved) field,
  ];

  List<RankingTemplateField> get _orphans => [
    for (final field in _all)
      if (field.isRemoved) field,
  ];

  /// The template is always written whole — active fields in their new order,
  /// then the orphans — so `sortOrder` is renumbered from the list itself and
  /// a removed field can never take a position in it.
  Future<void> _write(WidgetRef ref, List<RankingTemplateField> active) =>
      RankingsActions(ref).saveTemplate(
        category,
        isParentTemplate: isParentTemplate,
        fields: [...active, ..._orphans],
      );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final accent = Color(category.colorValue);
    final active = _active;
    final orphans = _orphans;
    final overallPrecision = isParentTemplate
        ? category.parentScorePrecision
        : category.childScorePrecision;
    final inheritLabel = isParentTemplate
        ? 'Same as overall'
        : 'Same as child overall';

    // One of the three panes the tab switch mounts one at a time, each
    // keyless — see [ScrollOffsetIsolate].
    return ScrollOffsetIsolate(
      child: VoyagerScrollView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Fields step in ${_precisionSentence(overallPrecision)} unless '
              'they opt out of the overall score.',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            if (active.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  'No fields. Entries still have an overall score and notes.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              )
            else
              // Mounted only once a field exists, into a pane that may already be
              // scrolled — see [ScrollOffsetIsolate].
              ScrollOffsetIsolate(
                child: ReorderableListView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  buildDefaultDragHandles: false,
                  itemCount: active.length,
                  onReorderItem: (oldIndex, newIndex) {
                    final next = [...active];
                    next.insert(newIndex, next.removeAt(oldIndex));
                    _write(ref, next);
                  },
                  itemBuilder: (context, index) => _FieldRow(
                    key: ValueKey(active[index].id),
                    index: index,
                    field: active[index],
                    accent: accent,
                    overallPrecision: overallPrecision,
                    inheritLabel: inheritLabel,
                    onPrecision: (inherit, precision) => _changeFieldPrecision(
                      context,
                      ref,
                      category,
                      active[index],
                      isParentTemplate: isParentTemplate,
                      inherit: inherit,
                      precision: precision,
                    ),
                    onRename: (label) => _write(ref, [
                      for (final field in active)
                        if (field.id == active[index].id)
                          field.copyWith(label: label)
                        else
                          field,
                    ]),
                    onToggleNotes: () => _write(ref, [
                      for (final field in active)
                        if (field.id == active[index].id)
                          field.copyWith(notesEnabled: !field.notesEnabled)
                        else
                          field,
                    ]),
                    onRescale: (scoreMax) =>
                        _rescale(context, ref, active[index], scoreMax),
                    // Removed rather than dropped: the field leaves the active
                    // list and joins the orphans, which is what keeps the values
                    // entries already hold restorable.
                    onRemove: () => RankingsActions(ref).saveTemplate(
                      category,
                      isParentTemplate: isParentTemplate,
                      fields: [
                        for (final field in active)
                          if (field.id != active[index].id) field,
                        ...orphans,
                        active[index].copyWith(removedAt: utcNow()),
                      ],
                    ),
                  ),
                ),
              ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: GlassButton(
                dense: true,
                color: accent,
                onPressed: () async {
                  final label = await showPromptNameDialog(
                    context,
                    title: 'New field',
                    label: 'Field name',
                  );
                  if (label == null || label.trim().isEmpty) return;
                  await _write(ref, [
                    ...active,
                    RankingTemplateField(
                      id: newId(),
                      label: label.trim(),
                      sortOrder: active.length,
                      scoreMax: isParentTemplate
                          ? category.parentScoreMax
                          : category.childScoreMax,
                    ),
                  ]);
                },
                icon: const Icon(PhosphorIconsRegular.plus, size: 13),
                label: 'Add field',
              ),
            ),
            if (orphans.isNotEmpty) ...[
              const Divider(height: 24),
              Text('Removed fields', style: theme.textTheme.labelMedium),
              const SizedBox(height: 2),
              Text(
                'Their scores and notes are still on the entries. Restore one to '
                'show it again.',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 6),
              for (final orphan in orphans)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          orphan.label,
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                      GlassButton(
                        dense: true,
                        onPressed: () => RankingsActions(ref).saveTemplate(
                          category,
                          isParentTemplate: isParentTemplate,
                          fields: [
                            ...active,
                            orphan.copyWith(clearRemovedAt: true),
                            for (final other in orphans)
                              if (other.id != orphan.id) other,
                          ],
                        ),
                        label: 'Restore',
                      ),
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _rescale(
    BuildContext context,
    WidgetRef ref,
    RankingTemplateField field,
    int scoreMax,
  ) async {
    if (field.scoreMax == scoreMax) return;
    final confirmed = await showConfirmDialog(
      context,
      title: 'Rescale "${field.label}"?',
      message: scoreMax < field.scoreMax
          ? 'Every score already recorded for this field will be halved and '
                'rounded to the nearest step. This cannot be undone exactly.'
          : 'Every score already recorded for this field will be doubled onto '
                'the new scale.',
      confirmLabel: 'Rescale',
    );
    if (!confirmed) return;
    await RankingsActions(ref).rescaleTemplateField(
      category,
      field,
      scoreMax: scoreMax,
      isParentTemplate: isParentTemplate,
    );
  }
}

class _FieldRow extends StatelessWidget {
  const _FieldRow({
    super.key,
    required this.index,
    required this.field,
    required this.accent,
    required this.overallPrecision,
    required this.inheritLabel,
    required this.onPrecision,
    required this.onRename,
    required this.onToggleNotes,
    required this.onRescale,
    required this.onRemove,
  });

  final int index;
  final RankingTemplateField field;
  final Color accent;

  /// What the field falls back to while it inherits, so the row can show the
  /// step it is actually on rather than the word "inherited".
  final RankingScorePrecision overallPrecision;

  /// "Same as overall" on a parent template, "Same as child overall" on a
  /// child one — the field itself has only the one flag (§3.2).
  final String inheritLabel;

  /// `(inherit, precision)`; [precision] is only read when inherit is false.
  final void Function(bool inherit, RankingScorePrecision? precision)
  onPrecision;

  final ValueChanged<String> onRename;
  final VoidCallback onToggleNotes;
  final ValueChanged<int> onRescale;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          ReorderableDragStartListener(
            index: index,
            child: Icon(
              PhosphorIconsRegular.dotsSixVertical,
              size: 14,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.35),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              field.label,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium,
            ),
          ),
          for (final option in rankingScoreMaxOptions) ...[
            SelectorPill(
              label: '$option',
              dense: true,
              accentColor: accent,
              fillWhenActive: true,
              isActive: field.scoreMax == option,
              onTap: () => onRescale(option),
            ),
            const SizedBox(width: 4),
          ],
          _FieldPrecisionButton(
            field: field,
            accent: accent,
            overallPrecision: overallPrecision,
            inheritLabel: inheritLabel,
            onPrecision: onPrecision,
          ),
          IconButton(
            onPressed: onToggleNotes,
            tooltip: field.notesEnabled ? 'Hide notes' : 'Show notes',
            iconSize: 14,
            visualDensity: VisualDensity.compact,
            color: field.notesEnabled ? accent : null,
            icon: const Icon(PhosphorIconsRegular.notePencil),
          ),
          IconButton(
            onPressed: () async {
              final label = await showPromptNameDialog(
                context,
                title: 'Rename field',
                initial: field.label,
                label: 'Field name',
              );
              if (label == null || label.trim().isEmpty) return;
              onRename(label.trim());
            },
            tooltip: 'Rename',
            iconSize: 14,
            visualDensity: VisualDensity.compact,
            icon: const Icon(PhosphorIconsRegular.pencilSimple),
          ),
          IconButton(
            onPressed: onRemove,
            tooltip: 'Remove from template',
            iconSize: 14,
            visualDensity: VisualDensity.compact,
            icon: const Icon(PhosphorIconsRegular.minus),
          ),
        ],
      ),
    );
  }
}

/// The step a surface's scores move on, as three pills.
class _PrecisionRow extends StatelessWidget {
  const _PrecisionRow({
    required this.label,
    required this.precision,
    required this.accent,
    required this.onChanged,
    this.help,
  });

  final String label;
  final String? help;
  final RankingScorePrecision precision;
  final Color accent;
  final ValueChanged<RankingScorePrecision> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: theme.textTheme.bodyMedium),
                if (help != null)
                  Text(
                    help!,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          for (final option in RankingScorePrecision.values) ...[
            SelectorPill(
              label: option.label,
              dense: true,
              accentColor: accent,
              fillWhenActive: true,
              isActive: precision == option,
              onTap: () => onChanged(option),
            ),
            const SizedBox(width: 6),
          ],
        ],
      ),
    );
  }
}

/// One template field's step: a checkbox that follows the overall, and the
/// three modes it can hold instead.
///
/// A menu rather than four more pills on the row: a field row already carries
/// its scale, its notes switch, a rename and a remove, and the step is the
/// thing on it that is almost always left alone.
class _FieldPrecisionButton extends StatelessWidget {
  const _FieldPrecisionButton({
    required this.field,
    required this.accent,
    required this.overallPrecision,
    required this.inheritLabel,
    required this.onPrecision,
  });

  final RankingTemplateField field;
  final Color accent;
  final RankingScorePrecision overallPrecision;
  final String inheritLabel;
  final void Function(bool inherit, RankingScorePrecision? precision)
  onPrecision;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final effective = rankingFieldPrecision(
      field,
      overallPrecision: overallPrecision,
    );
    return PopupMenuButton<RankingScorePrecision?>(
      tooltip: 'Step',
      // Null is the inherit case, which is why the value type is nullable —
      // "same as overall" is not one of the three modes, it is the absence of
      // a choice between them.
      onSelected: (value) => onPrecision(value == null, value),
      itemBuilder: (context) => [
        CheckedPopupMenuItem<RankingScorePrecision?>(
          value: null,
          checked: field.inheritPrecision,
          child: Text(inheritLabel),
        ),
        const PopupMenuDivider(),
        for (final option in RankingScorePrecision.values)
          CheckedPopupMenuItem<RankingScorePrecision?>(
            value: option,
            checked: !field.inheritPrecision && field.scorePrecision == option,
            child: Text(option.label),
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Text(
          effective.label,
          style: theme.textTheme.labelSmall?.copyWith(
            color: field.inheritPrecision
                ? theme.colorScheme.onSurfaceVariant
                : accent,
            fontWeight: field.inheritPrecision ? null : FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

String _precisionSentence(RankingScorePrecision precision) =>
    switch (precision) {
      RankingScorePrecision.integers => 'whole points',
      RankingScorePrecision.half => 'halves',
      RankingScorePrecision.tenths => 'tenths',
    };

/// Moves an overall score onto a new step, warning first when scores already
/// stored would have to be re-rounded to fit (§8.1).
///
/// The count covers the overall and every field inheriting from it, which is
/// why it is one warning rather than one per surface.
Future<void> _changeOverallPrecision(
  BuildContext context,
  WidgetRef ref,
  RankingCategory category, {
  required bool isParent,
  required RankingScorePrecision precision,
}) async {
  final current = isParent
      ? category.parentScorePrecision
      : category.childScorePrecision;
  if (current == precision) return;
  final next = isParent
      ? category.copyWith(parentScorePrecision: precision)
      : category.copyWith(childScorePrecision: precision);
  if (!await _confirmReround(context, ref, next, previous: category)) return;
  await RankingsActions(
    ref,
  ).setOverallPrecision(category, isParent: isParent, precision: precision);
}

/// The same warning for one field opting in or out of the overall's step.
Future<void> _changeFieldPrecision(
  BuildContext context,
  WidgetRef ref,
  RankingCategory category,
  RankingTemplateField field, {
  required bool isParentTemplate,
  required bool inherit,
  required RankingScorePrecision? precision,
}) async {
  final updated = field.copyWith(
    inheritPrecision: inherit,
    scorePrecision: precision,
    clearScorePrecision: inherit,
  );
  if (updated.inheritPrecision == field.inheritPrecision &&
      updated.scorePrecision == field.scorePrecision) {
    return;
  }
  final template = [
    for (final existing
        in isParentTemplate ? category.parentTemplate : category.childTemplate)
      if (existing.id == field.id) updated else existing,
  ];
  final next = isParentTemplate
      ? category.copyWith(parentTemplate: template)
      : category.copyWith(childTemplate: template);
  if (!await _confirmReround(context, ref, next, previous: category)) return;
  await RankingsActions(ref).setFieldPrecision(
    category,
    field,
    isParentTemplate: isParentTemplate,
    inherit: inherit,
    precision: precision,
  );
}

/// True when the change may go ahead: either nothing stored has to move, or
/// the user said so.
Future<bool> _confirmReround(
  BuildContext context,
  WidgetRef ref,
  RankingCategory next, {
  required RankingCategory previous,
}) async {
  final affected = await RankingsActions(
    ref,
  ).countScoresOffStep(next, previous: previous);
  if (affected == 0) return true;
  if (!context.mounted) return false;
  return showConfirmDialog(
    context,
    title: 'Re-round $affected ${affected == 1 ? 'score' : 'scores'}?',
    message:
        'Scores that do not sit on the new step will be rounded to the '
        'nearest one it allows. This cannot be undone exactly.',
    confirmLabel: 'Change step',
  );
}
