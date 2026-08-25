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
import 'package:voyager/core/widgets/glass_surface.dart';
import 'package:voyager/core/widgets/selector_pill.dart';
import 'package:voyager/core/widgets/voyager_text_field.dart';
import 'package:voyager/domain/models/finance_models.dart';
import 'package:voyager/core/layout/touch_target.dart';
import 'package:voyager/core/widgets/voyager_scroll_view.dart';

/// Opens the "allocate funds into a goal" modal.
Future<void> showAllocateModal(
  BuildContext context,
  WidgetRef ref, {
  required SavingsGoal goal,
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
      child: _AllocateModal(container: container, goal: goal),
    ),
  );
}

class _AllocateModal extends ConsumerStatefulWidget {
  const _AllocateModal({required this.container, required this.goal});

  /// The app-level container, which outlives this sheet. See
  /// [showAllocateModal].
  final ProviderContainer container;

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

  /// Set when a write throws, so the sheet says what went wrong instead of
  /// silently sitting there with the button disabled forever.
  String? _saveError;

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

  int? get _parsedCents => parseAmountCents(_amountController.text);

  /// Why Save is unavailable, for the amount field to show. Null while the
  /// field is empty: an untouched field isn't an error yet.
  String? get _amountError {
    if (_amountController.text.trim().isEmpty) return null;
    return _parsedCents == null ? r'Enter an amount over $0.00' : null;
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
    setState(() {
      _saving = true;
      _saveError = null;
    });

    final now = utcNow();
    // Read before the first await: `ref` throws once this sheet is disposed.
    final repo = ref.read(financeRepositoryProvider);
    final container = widget.container;
    try {
      await repo.upsertGoalAllocation(
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
      // Through the container, not `ref`: the invalidate has to land even
      // when the sheet was dismissed mid-write.
      container.invalidate(goalAllocationsProvider);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _saveError = 'Could not save: $e';
      });
    }
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
                  // Bounded so a long paste can't reach the range where
                  // double.parse returns Infinity.
                  LengthLimitingTextInputFormatter(12),
                ],
                style: theme.textTheme.headlineSmall?.copyWith(
                  color: accent,
                  fontWeight: FontWeight.w600,
                ),
                decoration: InputDecoration(
                  labelText: 'Amount',
                  prefixText: r'$ ',
                  errorText: _amountError,
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
