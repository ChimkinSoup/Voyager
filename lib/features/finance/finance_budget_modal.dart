import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/core/utils/journal_tags.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/voyager_text_field.dart';
import 'package:voyager/domain/models/finance_models.dart';

/// Opens the add / edit tag-budget modal.
Future<void> showBudgetModal(
  BuildContext context,
  WidgetRef ref, {
  Budget? existing,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) => ProviderScope(
      parent: ProviderScope.containerOf(context),
      child: _BudgetModal(existing: existing),
    ),
  );
}

class _BudgetModal extends ConsumerStatefulWidget {
  const _BudgetModal({this.existing});

  final Budget? existing;

  @override
  ConsumerState<_BudgetModal> createState() => _BudgetModalState();
}

class _BudgetModalState extends ConsumerState<_BudgetModal> {
  late final TextEditingController _tagController;
  late final TextEditingController _limitController;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _tagController = TextEditingController(text: widget.existing?.tag ?? '');
    _limitController = TextEditingController(
      text: widget.existing == null
          ? ''
          : (widget.existing!.limitCents / 100).toStringAsFixed(2),
    );
    _tagController.addListener(_onChanged);
    _limitController.addListener(_onChanged);
  }

  @override
  void dispose() {
    _tagController.dispose();
    _limitController.dispose();
    super.dispose();
  }

  void _onChanged() => setState(() {});

  String get _tag => _tagController.text.replaceAll('#', '').trim();

  int? get _parsedLimit {
    final cleaned = _limitController.text.replaceAll(RegExp(r'[^0-9.]'), '');
    if (cleaned.isEmpty) return null;
    final value = double.tryParse(cleaned);
    if (value == null || value <= 0) return null;
    return (value * 100).round();
  }

  bool get _canSave => _tag.isNotEmpty && _parsedLimit != null && !_saving;

  Future<void> _save() async {
    final limit = _parsedLimit;
    if (limit == null || !_canSave) return;
    setState(() => _saving = true);

    final now = utcNow();
    final repo = ref.read(financeRepositoryProvider);
    // Reuse an existing budget for the same tag rather than creating a
    // duplicate that would double-count the same spending.
    final budgets = await repo.listBudgets();
    final match = budgets.cast<Budget?>().firstWhere(
          (b) => b != null && b.tag.toLowerCase() == _tag.toLowerCase(),
          orElse: () => null,
        );
    final target = widget.existing ?? match;

    await repo.upsertBudget(
      Budget(
        id: target?.id ?? newId(),
        createdAt: target?.createdAt ?? now,
        updatedAt: now,
        version: target == null ? 0 : target.version + 1,
        tag: _tag,
        limitCents: limit,
      ),
    );

    // Give a brand-new tag a stable color so its chip matches elsewhere.
    final settingsRepo = ref.read(settingsRepositoryProvider);
    final colors = await settingsRepo.getTagColors();
    if (!colors.containsKey(_tag)) {
      await settingsRepo.setTagColor(_tag, colorForTag(_tag));
      ref.invalidate(tagColorsProvider);
    }

    ref.invalidate(budgetsProvider);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _delete() async {
    final existing = widget.existing;
    if (existing == null) return;
    await ref.read(financeRepositoryProvider).softDeleteBudget(existing.id);
    ref.invalidate(budgetsProvider);
    if (mounted) Navigator.of(context).pop();
  }

  /// Tags worth suggesting: everything already used on a transaction, plus any
  /// tag that has a stored color.
  List<String> _knownTags() {
    final transactions = ref.watch(transactionsProvider).valueOrNull ?? const [];
    final colors = ref.watch(tagColorsProvider).valueOrNull ?? const {};
    final tags = <String>{
      for (final t in transactions) ...t.tags,
      ...colors.keys,
    };
    final sorted = tags.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return sorted;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    final limit = _parsedLimit;
    final suggestions = _knownTags();
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
                    widget.existing == null ? 'New budget' : 'Edit budget',
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
                      constraints: const BoxConstraints(),
                    ),
                  IconButton(
                    onPressed: Navigator.of(context).pop,
                    icon: const Icon(PhosphorIconsRegular.x, size: 18),
                    tooltip: 'Close',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              VoyagerTextField(
                controller: _tagController,
                autofocus: widget.existing == null,
                accentColor: accent,
                enabled: widget.existing == null,
                decoration: const InputDecoration(
                  labelText: 'Tag',
                  hintText: 'dining_out',
                ),
              ),
              if (widget.existing == null && suggestions.isNotEmpty) ...[
                const SizedBox(height: 10),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final tag in suggestions.take(12))
                      ActionChip(
                        label: Text('#$tag',
                            style: const TextStyle(fontSize: 12)),
                        visualDensity: VisualDensity.compact,
                        onPressed: () {
                          _tagController.text = tag;
                          _tagController.selection = TextSelection.collapsed(
                            offset: tag.length,
                          );
                        },
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 16),
              VoyagerTextField(
                controller: _limitController,
                accentColor: accent,
                cursorColor: accent,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                ],
                decoration: const InputDecoration(
                  labelText: 'Monthly limit',
                  prefixText: r'$ ',
                ),
                onSubmitted: (_) => _save(),
              ),
              if (limit != null && _tag.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  'Keep #$_tag under ${formatCents(limit)} this month.',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
              const SizedBox(height: 24),
              GlassButton(
                onPressed: _canSave ? _save : null,
                label: widget.existing == null ? 'Add' : 'Save',
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
