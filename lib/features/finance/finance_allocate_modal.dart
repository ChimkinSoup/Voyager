import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/core/widgets/contextual_popover.dart';
import 'package:voyager/core/widgets/date_selector_popover.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/selector_pill.dart';
import 'package:voyager/core/widgets/voyager_text_field.dart';
import 'package:voyager/domain/models/finance_models.dart';
import 'package:voyager/core/layout/touch_target.dart';

/// Opens the "allocate funds into a goal" modal.
Future<void> showAllocateModal(
  BuildContext context,
  WidgetRef ref, {
  required SavingsGoal goal,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    useSafeArea: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) => ProviderScope(
      parent: ProviderScope.containerOf(context),
      child: _AllocateModal(goal: goal),
    ),
  );
}

class _AllocateModal extends ConsumerStatefulWidget {
  const _AllocateModal({required this.goal});

  final SavingsGoal goal;

  @override
  ConsumerState<_AllocateModal> createState() => _AllocateModalState();
}

class _AllocateModalState extends ConsumerState<_AllocateModal> {
  final _amountController = TextEditingController();
  final _noteController = TextEditingController();
  late DateTime _date;
  bool _withdrawing = false;
  bool _datePopoverOpen = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _date = DateTime(now.year, now.month, now.day);
    _amountController.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _amountController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  int? get _parsedCents {
    final cleaned = _amountController.text.replaceAll(RegExp(r'[^0-9.]'), '');
    if (cleaned.isEmpty) return null;
    final value = double.tryParse(cleaned);
    if (value == null || value <= 0) return null;
    return (value * 100).round();
  }

  bool get _canSave => _parsedCents != null && !_saving;

  Future<void> _pickDate(BuildContext buttonContext) async {
    final accent = Color(widget.goal.colorValue);
    setState(() => _datePopoverOpen = true);
    final range = await showContextualPopover<DateTimeRange>(
      context: context,
      buttonContext: buttonContext,
      width: 320,
      height: 380,
      accentColor: accent,
      builder: (_) => DateSelectorPopover(
        initialStartDate: _date,
        initialEndDate: _date,
        singleDateMode: true,
        accentColor: accent,
      ),
    );
    if (!mounted) return;
    setState(() {
      _datePopoverOpen = false;
      if (range != null) {
        _date = DateTime(range.start.year, range.start.month, range.start.day);
      }
    });
  }

  Future<void> _save() async {
    final cents = _parsedCents;
    if (cents == null || !_canSave) return;
    setState(() => _saving = true);

    final now = utcNow();
    await ref.read(financeRepositoryProvider).upsertGoalAllocation(
          GoalAllocation(
            id: newId(),
            createdAt: now,
            updatedAt: now,
            goalId: widget.goal.id,
            // Withdrawals are stored as negative allocations so the goal's
            // total is a simple sum over its history.
            amountCents: _withdrawing ? -cents : cents,
            allocatedAt: _date,
            note: _noteController.text.trim().isEmpty
                ? null
                : _noteController.text.trim(),
          ),
        );
    ref.invalidate(goalAllocationsProvider);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = Color(widget.goal.colorValue);
    final allocations =
        ref.watch(goalAllocationsProvider).valueOrNull ?? const [];
    final allocated = goalAllocatedCents(allocations, widget.goal.id);
    final remaining = widget.goal.targetCents - allocated;
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
                  Expanded(
                    child: Text(
                      widget.goal.name,
                      style: theme.textTheme.titleMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
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
              Text(
                remaining > 0
                    ? '${formatCents(remaining)} to go'
                    : 'Target reached',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 16),
              SegmentedButton<bool>(
                showSelectedIcon: false,
                style: SegmentedButton.styleFrom(
                  selectedBackgroundColor: accent.withValues(alpha: 0.18),
                  selectedForegroundColor: accent,
                ),
                segments: const [
                  ButtonSegment(
                    value: false,
                    icon: Icon(PhosphorIconsRegular.arrowDown, size: 16),
                    label: Text('Add'),
                  ),
                  ButtonSegment(
                    value: true,
                    icon: Icon(PhosphorIconsRegular.arrowUp, size: 16),
                    label: Text('Withdraw'),
                  ),
                ],
                selected: {_withdrawing},
                onSelectionChanged: (set) {
                  if (set.isNotEmpty) setState(() => _withdrawing = set.first);
                },
              ),
              const SizedBox(height: 16),
              VoyagerTextField(
                controller: _amountController,
                autofocus: true,
                accentColor: accent,
                cursorColor: accent,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                ],
                style: theme.textTheme.headlineSmall?.copyWith(
                  color: accent,
                  fontWeight: FontWeight.w600,
                ),
                decoration: const InputDecoration(
                  labelText: 'Amount',
                  prefixText: r'$ ',
                ),
                onSubmitted: (_) => _save(),
              ),
              const SizedBox(height: 16),
              VoyagerTextField(
                controller: _noteController,
                accentColor: accent,
                decoration: const InputDecoration(
                  labelText: 'Note',
                  hintText: 'From October paycheck',
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Text(
                    'Date',
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const Spacer(),
                  Builder(
                    builder: (buttonContext) => SelectorPill(
                      icon: PhosphorIconsRegular.calendar,
                      label: DateFormat('MMM d, yyyy').format(_date),
                      isActive: _datePopoverOpen,
                      accentColor: accent,
                      onTap: () => _pickDate(buttonContext),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              GlassButton(
                onPressed: _canSave ? _save : null,
                label: _withdrawing ? 'Withdraw' : 'Add funds',
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
