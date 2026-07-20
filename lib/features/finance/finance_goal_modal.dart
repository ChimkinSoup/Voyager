import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/core/widgets/color_picker_field.dart';
import 'package:voyager/core/widgets/contextual_popover.dart';
import 'package:voyager/core/widgets/date_selector_popover.dart';
import 'package:voyager/core/widgets/selector_pill.dart';
import 'package:voyager/core/widgets/voyager_text_field.dart';
import 'package:voyager/domain/models/finance_models.dart';

/// Opens the add / edit savings goal modal.
Future<void> showGoalModal(
  BuildContext context,
  WidgetRef ref, {
  SavingsGoal? existing,
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
      child: _GoalModal(existing: existing),
    ),
  );
}

class _GoalModal extends ConsumerStatefulWidget {
  const _GoalModal({this.existing});

  final SavingsGoal? existing;

  @override
  ConsumerState<_GoalModal> createState() => _GoalModalState();
}

class _GoalModalState extends ConsumerState<_GoalModal> {
  late final TextEditingController _nameController;
  late final TextEditingController _targetController;
  late final TextEditingController _noteController;
  DateTime? _targetDate;
  late int _colorValue;
  bool _datePopoverOpen = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _nameController = TextEditingController(text: existing?.name ?? '');
    _targetController = TextEditingController(
      text: existing == null
          ? ''
          : (existing.targetCents / 100).toStringAsFixed(2),
    );
    _noteController = TextEditingController(text: existing?.note ?? '');
    _targetDate = existing?.targetDate;
    _colorValue = existing?.colorValue ?? 0xFF7C9EFF;
    _nameController.addListener(() => setState(() {}));
    _targetController.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _nameController.dispose();
    _targetController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  int? get _parsedTarget {
    final cleaned = _targetController.text.replaceAll(RegExp(r'[^0-9.]'), '');
    if (cleaned.isEmpty) return null;
    final value = double.tryParse(cleaned);
    if (value == null || value <= 0) return null;
    return (value * 100).round();
  }

  bool get _canSave =>
      _nameController.text.trim().isNotEmpty &&
      _parsedTarget != null &&
      !_saving;

  Future<void> _pickDate(BuildContext buttonContext) async {
    final accent = Color(_colorValue);
    final initial = _targetDate ?? DateTime.now();
    setState(() => _datePopoverOpen = true);
    final range = await showContextualPopover<DateTimeRange>(
      context: context,
      buttonContext: buttonContext,
      width: 320,
      height: 380,
      accentColor: accent,
      builder: (_) => DateSelectorPopover(
        initialStartDate: initial,
        initialEndDate: initial,
        singleDateMode: true,
        accentColor: accent,
      ),
    );
    if (!mounted) return;
    setState(() {
      _datePopoverOpen = false;
      if (range != null) {
        _targetDate =
            DateTime(range.start.year, range.start.month, range.start.day);
      }
    });
  }

  Future<void> _save() async {
    final target = _parsedTarget;
    if (target == null || !_canSave) return;
    setState(() => _saving = true);

    final now = utcNow();
    final existing = widget.existing;
    await ref.read(financeRepositoryProvider).upsertSavingsGoal(
          SavingsGoal(
            id: existing?.id ?? newId(),
            createdAt: existing?.createdAt ?? now,
            updatedAt: now,
            version: existing == null ? 0 : existing.version + 1,
            name: _nameController.text.trim(),
            targetCents: target,
            colorValue: _colorValue,
            note: _noteController.text.trim().isEmpty
                ? null
                : _noteController.text.trim(),
            targetDate: _targetDate,
          ),
        );
    ref.invalidate(savingsGoalsProvider);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _delete() async {
    final existing = widget.existing;
    if (existing == null) return;
    await ref
        .read(financeRepositoryProvider)
        .softDeleteSavingsGoal(existing.id);
    ref.invalidate(savingsGoalsProvider);
    ref.invalidate(goalAllocationsProvider);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = Color(_colorValue);
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
                    widget.existing == null ? 'New goal' : 'Edit goal',
                    style: theme.textTheme.titleMedium,
                  ),
                  const Spacer(),
                  if (widget.existing != null)
                    IconButton(
                      onPressed: _saving ? null : _delete,
                      icon: const Icon(PhosphorIconsRegular.trash, size: 18),
                      tooltip: 'Delete',
                    ),
                  IconButton(
                    onPressed: Navigator.of(context).pop,
                    icon: const Icon(PhosphorIconsRegular.x, size: 18),
                    tooltip: 'Close',
                  ),
                ],
              ),
              const SizedBox(height: 12),
              VoyagerTextField(
                controller: _nameController,
                autofocus: widget.existing == null,
                accentColor: accent,
                decoration: const InputDecoration(
                  labelText: 'Goal',
                  hintText: 'Japan trip',
                ),
              ),
              const SizedBox(height: 16),
              VoyagerTextField(
                controller: _targetController,
                accentColor: accent,
                cursorColor: accent,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                ],
                decoration: const InputDecoration(
                  labelText: 'Target amount',
                  prefixText: r'$ ',
                ),
              ),
              const SizedBox(height: 16),
              VoyagerTextField(
                controller: _noteController,
                accentColor: accent,
                decoration: const InputDecoration(
                  labelText: 'Note',
                  hintText: 'Flights and hotel',
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Text(
                    'Target date',
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const Spacer(),
                  if (_targetDate != null)
                    IconButton(
                      icon: const Icon(PhosphorIconsRegular.x, size: 14),
                      visualDensity: VisualDensity.compact,
                      tooltip: 'Clear date',
                      onPressed: () => setState(() => _targetDate = null),
                    ),
                  Builder(
                    builder: (buttonContext) => SelectorPill(
                      icon: PhosphorIconsRegular.calendar,
                      label: _targetDate == null
                          ? 'Optional'
                          : DateFormat('MMM d, yyyy').format(_targetDate!),
                      isActive: _datePopoverOpen,
                      accentColor: accent,
                      onTap: () => _pickDate(buttonContext),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              ColorPickerField(
                label: 'Ring color',
                value: _colorValue,
                onChanged: (c) => setState(() => _colorValue = c),
                swatchRadius: 16,
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _canSave ? _save : null,
                style: FilledButton.styleFrom(
                  backgroundColor: accent,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                child: Text(widget.existing == null ? 'Add' : 'Save'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
