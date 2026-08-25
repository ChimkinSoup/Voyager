import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/core/widgets/color_picker_field.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/glass_surface.dart';
import 'package:voyager/core/widgets/voyager_text_field.dart';
import 'package:voyager/domain/models/finance_models.dart';
import 'package:voyager/core/layout/touch_target.dart';
import 'package:voyager/core/widgets/voyager_scroll_view.dart';

/// Opens the add / edit category modal — a named, colored grouping of tags.
Future<void> showCategoryModal(
  BuildContext context,
  WidgetRef ref, {
  FinanceCategory? existing,
}) async {
  // Captured out here, not inside the sheet: the sheet builds its own
  // ProviderScope, and that container is disposed the moment the sheet is
  // dismissed — which can happen while a save is still in flight, when the
  // invalidate still has to land.
  final container = ProviderScope.containerOf(context, listen: false);
  await showVoyagerSheet<void>(
    context: context,
    builder: (ctx) => ProviderScope(
      parent: container,
      child: _CategoryModal(container: container, existing: existing),
    ),
  );
}

class _CategoryModal extends ConsumerStatefulWidget {
  const _CategoryModal({required this.container, this.existing});

  /// The app-level container, which outlives this sheet. See
  /// [showCategoryModal].
  final ProviderContainer container;

  final FinanceCategory? existing;

  @override
  ConsumerState<_CategoryModal> createState() => _CategoryModalState();
}

class _CategoryModalState extends ConsumerState<_CategoryModal> {
  late final TextEditingController _nameController;
  late Set<String> _selectedTags;
  late int _colorValue;
  bool _saving = false;

  /// Set when a write throws, so the sheet says what went wrong instead of
  /// silently sitting there with Save disabled forever.
  String? _saveError;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.existing?.name ?? '');
    _selectedTags = {...?widget.existing?.tags};
    _colorValue = widget.existing?.colorValue ?? 0xFF7C9EFF;
    _nameController.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  bool get _canSave => _nameController.text.trim().isNotEmpty && !_saving;

  /// Every tag the user has actually used, plus any with a stored color.
  List<String> _knownTags() {
    final transactions =
        ref.watch(transactionsProvider).valueOrNull ?? const [];
    final colors = ref.watch(tagColorsProvider).valueOrNull ?? const {};
    final tags = <String>{
      for (final t in transactions) ...t.tags,
      ...colors.keys,
      ..._selectedTags,
    };
    final sorted = tags.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return sorted;
  }

  Future<void> _save() async {
    if (!_canSave) return;
    setState(() {
      _saving = true;
      _saveError = null;
    });
    final now = utcNow();
    final existing = widget.existing;
    // Read before the first await: `ref` throws once this sheet is disposed.
    final repo = ref.read(financeRepositoryProvider);
    final container = widget.container;

    try {
      await repo.upsertCategory(
        FinanceCategory(
          id: existing?.id ?? newId(),
          createdAt: existing?.createdAt ?? now,
          updatedAt: now,
          version: existing == null ? 0 : existing.version + 1,
          name: _nameController.text.trim(),
          colorValue: _colorValue,
          tags: _selectedTags.toList()..sort(),
        ),
      );
      // Through the container, not `ref`: the invalidate has to land even
      // when the sheet was dismissed mid-write.
      container.invalidate(financeCategoriesProvider);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _saveError = 'Could not save: $e';
      });
    }
  }

  Future<void> _delete() async {
    final existing = widget.existing;
    // _saving also guards the delete: the icon is only disabled by it, so two
    // taps inside the await window would otherwise write two tombstones and
    // burn two version numbers on one logical delete.
    if (existing == null || _saving) return;
    setState(() {
      _saving = true;
      _saveError = null;
    });
    final repo = ref.read(financeRepositoryProvider);
    final container = widget.container;
    try {
      await repo.softDeleteCategory(existing.id);
      container.invalidate(financeCategoriesProvider);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _saveError = 'Could not delete: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = Color(_colorValue);
    final tags = _knownTags();
    final viewInsets = MediaQuery.of(context).viewInsets.bottom;

    return Padding(
      padding: EdgeInsets.only(bottom: viewInsets),
      child: VoyagerScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.onSurfaceVariant
                        .withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Row(
                children: [
                  Text(
                    widget.existing == null ? 'New category' : 'Edit category',
                    style: theme.textTheme.titleMedium,
                  ),
                  const Spacer(),
                  if (widget.existing != null)
                    IconButton(
                      onPressed: _saving ? null : _delete,
                      icon: Icon(
                        PhosphorIconsRegular.trash,
                        size: 18,
                        color: theme.colorScheme.error,
                      ),
                      tooltip: 'Delete',
                      padding: EdgeInsets.zero,
                      constraints: kMinTouchTarget,
                    ),
                  IconButton(
                    onPressed: Navigator.of(context).pop,
                    icon: const Icon(PhosphorIconsRegular.x, size: 18),
                    tooltip: 'Close',
                    padding: EdgeInsets.zero,
                    constraints: kMinTouchTarget,
                  ),
                ],
              ),
              const SizedBox(height: 12),
              VoyagerTextField(
                controller: _nameController,
                autofocus: widget.existing == null,
                accentColor: accent,
                decoration: const InputDecoration(
                  labelText: 'Category name',
                  hintText: 'Eating out',
                ),
              ),
              const SizedBox(height: 18),
              Text(
                'Tags in this category',
                style: theme.textTheme.labelMedium,
              ),
              const SizedBox(height: 8),
              if (tags.isEmpty)
                Text(
                  'No tags yet — tag a transaction first, then group them here.',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                )
              else
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final tag in tags)
                      FilterChip(
                        label: Text('#$tag',
                            style: const TextStyle(fontSize: 12)),
                        selected: _selectedTags.contains(tag),
                        visualDensity: VisualDensity.compact,
                        selectedColor: accent.withValues(alpha: 0.22),
                        checkmarkColor: accent,
                        onSelected: (selected) => setState(() {
                          if (selected) {
                            _selectedTags.add(tag);
                          } else {
                            _selectedTags.remove(tag);
                          }
                        }),
                      ),
                  ],
                ),
              const SizedBox(height: 18),
              ColorPickerField(
                label: 'Color',
                value: _colorValue,
                onChanged: (c) => setState(() => _colorValue = c),
                swatchRadius: 16,
              ),
              if (_saveError != null) ...[
                const SizedBox(height: 16),
                Text(
                  _saveError!,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ],
              const SizedBox(height: 24),
              GlassButton(
                onPressed: _canSave ? _save : null,
                label: widget.existing == null ? 'Add' : 'Save',
                color: accent,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
