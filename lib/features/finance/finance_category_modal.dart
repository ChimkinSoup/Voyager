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

/// Opens the add / edit category modal — a named, colored grouping of tags.
Future<void> showCategoryModal(
  BuildContext context,
  WidgetRef ref, {
  FinanceCategory? existing,
}) async {
  await showVoyagerSheet<void>(
    context: context,
    builder: (ctx) => ProviderScope(
      parent: ProviderScope.containerOf(context),
      child: _CategoryModal(existing: existing),
    ),
  );
}

class _CategoryModal extends ConsumerStatefulWidget {
  const _CategoryModal({this.existing});

  final FinanceCategory? existing;

  @override
  ConsumerState<_CategoryModal> createState() => _CategoryModalState();
}

class _CategoryModalState extends ConsumerState<_CategoryModal> {
  late final TextEditingController _nameController;
  late Set<String> _selectedTags;
  late int _colorValue;
  bool _saving = false;

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
    setState(() => _saving = true);
    final now = utcNow();
    final existing = widget.existing;

    await ref.read(financeRepositoryProvider).upsertCategory(
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
    ref.invalidate(financeCategoriesProvider);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _delete() async {
    final existing = widget.existing;
    if (existing == null) return;
    await ref.read(financeRepositoryProvider).softDeleteCategory(existing.id);
    ref.invalidate(financeCategoriesProvider);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = Color(_colorValue);
    final tags = _knownTags();
    final viewInsets = MediaQuery.of(context).viewInsets.bottom;

    return Padding(
      padding: EdgeInsets.only(bottom: viewInsets),
      child: SingleChildScrollView(
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
