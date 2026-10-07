import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/theme/palette_color.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/core/widgets/color_picker_field.dart';
import 'package:voyager/core/widgets/contextual_popover.dart';
import 'package:voyager/core/widgets/ctrl_enter_to_submit_scope.dart';
import 'package:voyager/core/widgets/date_selector_popover.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/glass_surface.dart';
import 'package:voyager/core/widgets/selector_pill.dart';
import 'package:voyager/core/widgets/voyager_text_field.dart';
import 'package:voyager/domain/models/finance_models.dart';
import 'package:voyager/core/layout/touch_target.dart';
import 'package:voyager/core/widgets/voyager_scroll_view.dart';
import 'package:voyager/features/finance/finance_allocate_modal.dart';
import 'package:voyager/features/finance/finance_amount_formatter.dart';
import 'package:voyager/features/finance/finance_soft_delete.dart';
import 'package:voyager/features/finance/finance_transaction_modal.dart'
    show kIncomeGreen;

/// Opens the add / edit savings goal modal.
Future<void> showGoalModal(
  BuildContext context,
  WidgetRef ref, {
  SavingsGoal? existing,
}) async {
  // Captured out here, not inside the sheet: the sheet builds its own
  // ProviderScope, and that container is disposed the moment the sheet is
  // dismissed — which can happen while a save is still in flight, when the
  // invalidate still has to land.
  final container = ProviderScope.containerOf(context, listen: false);
  await showVoyagerModal<void>(
    context: context,
    enableDrag: false,
    builder: (ctx) => ProviderScope(
      parent: container,
      child: _GoalModal(container: container, existing: existing),
    ),
  );
}

class _GoalModal extends ConsumerStatefulWidget {
  const _GoalModal({required this.container, this.existing});

  /// The app-level container, which outlives this sheet. See [showGoalModal].
  final ProviderContainer container;

  final SavingsGoal? existing;

  @override
  ConsumerState<_GoalModal> createState() => _GoalModalState();
}

class _GoalModalState extends ConsumerState<_GoalModal> {
  late final TextEditingController _nameController;
  late final TextEditingController _targetController;
  late final TextEditingController _noteController;
  final _targetFocusNode = FocusNode();
  final _noteFocusNode = FocusNode();
  DateTime? _targetDate;
  late int _colorValue;
  bool _datePopoverOpen = false;
  bool _saving = false;

  /// Set when a write throws, so the sheet says what went wrong instead of
  /// silently sitting there with Save disabled forever.
  String? _saveError;

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
  }

  @override
  void dispose() {
    _nameController.dispose();
    _targetController.dispose();
    _noteController.dispose();
    _targetFocusNode.dispose();
    _noteFocusNode.dispose();
    super.dispose();
  }

  int? get _parsedTarget => parseAmountCents(_targetController.text);

  /// Why Save is unavailable, for the target field to show. Null while the
  /// field is empty: an untouched field isn't an error yet.
  String? get _targetError {
    if (_targetController.text.trim().isEmpty) return null;
    if (_parsedTarget != null) return null;
    return amountInputError(_targetController.text) ??
        r'Enter a target over $0.00';
  }

  bool get _canSave =>
      _nameController.text.trim().isNotEmpty &&
      _parsedTarget != null &&
      !_saving;

  Future<void> _pickDate(BuildContext buttonContext) async {
    final accent = paletteColor(_colorValue, context);
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
        _targetDate = DateTime(
          range.start.year,
          range.start.month,
          range.start.day,
        );
      }
    });
  }

  Future<void> _save() async {
    final target = _parsedTarget;
    if (target == null || !_canSave) return;
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
      // Re-read rather than trusting [existing], as the asset sheet does: a
      // pull can land while this sheet is open, and a version built from the
      // snapshot could fall behind the row on disk and lose to the older copy.
      final onDisk = existing == null
          ? null
          : (await repo.listSavingsGoals(
              includeDeleted: true,
            )).where((g) => g.id == existing.id).firstOrNull;
      final base = onDisk ?? existing;
      await repo.upsertSavingsGoal(
        SavingsGoal(
          id: existing?.id ?? newId(),
          createdAt: base?.createdAt ?? now,
          updatedAt: now,
          version: base == null ? 0 : base.version + 1,
          // Deleted while the sheet was open stays deleted.
          deletedAt: base?.deletedAt,
          name: _nameController.text.trim(),
          targetCents: target,
          colorValue: _colorValue,
          note: _noteController.text.trim().isEmpty
              ? null
              : _noteController.text.trim(),
          targetDate: _targetDate,
        ),
      );
      // Through the container, not `ref`: the invalidate has to land even
      // when the sheet was dismissed mid-write.
      container.invalidate(savingsGoalsProvider);
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
    // burn two version numbers on one logical delete — and run the per-child
    // allocation tombstone loop twice.
    if (existing == null || _saving) return;
    setState(() {
      _saving = true;
      _saveError = null;
    });
    // The root overlay, resolved before the sheet closes: the undo offer has
    // to outlive the sheet that raised it, as the category sheet's does
    // (BUG-127).
    final overlay = Overlay.of(context, rootOverlay: true);
    final deleted = await deleteGoalWithUndo(
      overlay: overlay,
      container: widget.container,
      repo: ref.read(financeRepositoryProvider),
      goal: existing,
    );
    if (!mounted) return;
    if (!deleted) {
      // The helper has already said so in its own toast.
      setState(() => _saving = false);
      return;
    }
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = paletteColor(_colorValue, context);
    final viewInsets = MediaQuery.of(context).viewInsets.bottom;

    final sheet = Padding(
      padding: EdgeInsets.only(bottom: viewInsets),
      child: VoyagerScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
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
              // Focused when editing too: the sheet used to open with
              // nothing focused, so typing went nowhere (BUG-117).
              VoyagerTextField(
                controller: _nameController,
                autofocus: true,
                accentColor: accent,
                decoration: const InputDecoration(
                  labelText: 'Goal',
                  hintText: 'Japan trip',
                ),
                onSubmitted: (_) => _targetFocusNode.requestFocus(),
              ),
              const SizedBox(height: 16),
              // Scoped to the field and the button below: rebuilding the
              // whole sheet per keystroke also made its heavy GlassSurface
              // re-blur a window-sized backdrop for every character.
              ListenableBuilder(
                listenable: _targetController,
                builder: (context, _) => VoyagerTextField(
                  controller: _targetController,
                  focusNode: _targetFocusNode,
                  accentColor: accent,
                  cursorColor: accent,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  inputFormatters: [
                    AmountInputFormatter(),
                    // Bounded so a long paste can't reach the range where
                    // double.parse returns Infinity.
                    LengthLimitingTextInputFormatter(12),
                  ],
                  decoration: InputDecoration(
                    labelText: 'Target amount',
                    prefixText: r'$ ',
                    errorText: _targetError,
                  ),
                  onSubmitted: (_) => _noteFocusNode.requestFocus(),
                ),
              ),
              const SizedBox(height: 16),
              VoyagerTextField(
                controller: _noteController,
                focusNode: _noteFocusNode,
                accentColor: accent,
                decoration: const InputDecoration(
                  labelText: 'Note',
                  hintText: 'Flights and hotel',
                ),
                onSubmitted: (_) => _save(),
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
              if (widget.existing != null) ...[
                const SizedBox(height: 20),
                Text(
                  'Allocations',
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 8),
                _AllocationHistory(
                  goal: widget.existing!,
                  container: widget.container,
                ),
              ],
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
              ListenableBuilder(
                listenable: Listenable.merge([
                  _nameController,
                  _targetController,
                ]),
                builder: (context, _) => GlassButton(
                  onPressed: _canSave ? _save : null,
                  label: widget.existing == null ? 'Add' : 'Save',
                  color: accent,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return CtrlEnterToSubmitScope(onSubmit: _save, child: sheet);
  }
}

/// Every allocation into [goal], newest first: date, note and amount, with
/// post-dated ones marked Upcoming. Tap one to edit it (BUG-126).
class _AllocationHistory extends ConsumerWidget {
  const _AllocationHistory({required this.goal, required this.container});

  final SavingsGoal goal;

  /// The app-level container. The undo toast can outlive the sheet this list
  /// sits in, and the sheet's own scope is disposed with it.
  final ProviderContainer container;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final allocations = [
      for (final a
          in ref.watch(goalAllocationsProvider.settled).valueOrNull ??
              const <GoalAllocation>[])
        if (a.goalId == goal.id) a,
    ];
    if (allocations.isEmpty) {
      return Text(
        'Nothing added or withdrawn yet.',
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      );
    }
    final now = DateTime.now();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final allocation in allocations)
          _AllocationRow(
            goal: goal,
            allocation: allocation,
            upcoming: !isGoalAllocationSettled(allocation, now),
            container: container,
          ),
      ],
    );
  }
}

class _AllocationRow extends ConsumerWidget {
  const _AllocationRow({
    required this.goal,
    required this.allocation,
    required this.upcoming,
    required this.container,
  });

  final SavingsGoal goal;
  final GoalAllocation allocation;
  final bool upcoming;
  final ProviderContainer container;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final incoming = allocation.amountCents >= 0;
    final color = incoming ? kIncomeGreen : theme.colorScheme.primary;
    final date = DateFormat('MMM d, yyyy').format(allocation.allocatedAt);
    final subtitle = [
      date,
      if (upcoming) 'Upcoming',
      if (allocation.note != null) allocation.note!,
    ].join(' · ');
    final amount = formatCents(allocation.amountCents, signed: true);

    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => showAllocateModal(
        context,
        ref,
        goal: goal,
        existing: allocation,
        container: container,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          children: [
            Icon(
              incoming
                  ? PhosphorIconsRegular.arrowDown
                  : PhosphorIconsRegular.arrowUp,
              size: 16,
              color: color,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    incoming ? 'Added' : 'Withdrawn',
                    style: theme.textTheme.labelMedium,
                  ),
                  Text(
                    subtitle,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            Text(
              amount,
              style: theme.textTheme.labelMedium?.copyWith(
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              onPressed: () => deleteAllocationWithUndo(
                overlay: Overlay.of(context, rootOverlay: true),
                container: container,
                repo: ref.read(financeRepositoryProvider),
                allocation: allocation,
                title: '$amount on $date',
              ),
              icon: Icon(
                PhosphorIconsRegular.trash,
                size: 16,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              tooltip: 'Delete',
              padding: EdgeInsets.zero,
              constraints: kMinTouchTarget,
            ),
          ],
        ),
      ),
    );
  }
}
