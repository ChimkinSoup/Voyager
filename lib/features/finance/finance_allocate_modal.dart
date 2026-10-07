import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/theme/palette_color.dart';
import 'package:voyager/core/utils/ids.dart';
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
import 'package:voyager/features/finance/finance_amount_formatter.dart';

/// Opens the "allocate funds into a goal" modal, or edits [existing], one of
/// [goal]'s allocations.
///
/// A caller inside another sheet passes the app-level [container]: the one
/// found from its context is that sheet's own, disposed with it.
Future<void> showAllocateModal(
  BuildContext context,
  WidgetRef ref, {
  required SavingsGoal goal,
  GoalAllocation? existing,
  ProviderContainer? container,
}) async {
  // Captured out here, not inside the sheet: the sheet builds its own
  // ProviderScope, and that container is disposed the moment the sheet is
  // dismissed — which can happen while a save is still in flight, when the
  // invalidate still has to land.
  final appContainer =
      container ?? ProviderScope.containerOf(context, listen: false);
  await showVoyagerModal<void>(
    context: context,
    enableDrag: false,
    builder: (ctx) => ProviderScope(
      parent: appContainer,
      child: _AllocateModal(
        container: appContainer,
        goal: goal,
        existing: existing,
      ),
    ),
  );
}

class _AllocateModal extends ConsumerStatefulWidget {
  const _AllocateModal({
    required this.container,
    required this.goal,
    this.existing,
  });

  /// The app-level container, which outlives this sheet. See
  /// [showAllocateModal].
  final ProviderContainer container;

  final SavingsGoal goal;
  final GoalAllocation? existing;

  @override
  ConsumerState<_AllocateModal> createState() => _AllocateModalState();
}

class _AllocateModalState extends ConsumerState<_AllocateModal> {
  late final TextEditingController _amountController;
  late final TextEditingController _noteController;
  final _noteFocusNode = FocusNode();
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
    final existing = widget.existing;
    _amountController = TextEditingController(
      text: existing == null
          ? ''
          : (existing.amountCents.abs() / 100).toStringAsFixed(2),
    );
    _noteController = TextEditingController(text: existing?.note ?? '');
    _withdrawing = (existing?.amountCents ?? 0) < 0;
    final at = existing?.allocatedAt ?? DateTime.now();
    _date = DateTime(at.year, at.month, at.day);
  }

  @override
  void dispose() {
    _amountController.dispose();
    _noteController.dispose();
    _noteFocusNode.dispose();
    super.dispose();
  }

  int? get _parsedCents => parseAmountCents(_amountController.text);

  /// The goal's allocations other than the one being edited.
  List<GoalAllocation> get _others => [
    for (final a
        in ref.read(goalAllocationsProvider.settled).valueOrNull ??
            const <GoalAllocation>[])
      if (a.goalId == widget.goal.id && a.id != widget.existing?.id) a,
  ];

  /// Set when saving would leave the goal holding less than nothing on the
  /// allocation's day or on any later day, post-dated allocations included:
  /// a withdrawal can take out only what is in it (BUG-125).
  String? get _overdrawnError {
    final cents = _parsedCents;
    if (cents == null) return null;
    final goalId = widget.goal.id;
    final others = _others;
    final now = utcNow();
    final after = [
      ...others,
      GoalAllocation(
        id: '',
        createdAt: now,
        updatedAt: now,
        goalId: goalId,
        amountCents: _withdrawing ? -cents : cents,
        allocatedAt: _date,
      ),
    ];
    // The balance only moves on days something is allocated, so those are
    // the days to check.
    final days = {
      _date,
      for (final a in others)
        if (DateTime(
          a.allocatedAt.year,
          a.allocatedAt.month,
          a.allocatedAt.day,
        ).isAfter(_date))
          DateTime(a.allocatedAt.year, a.allocatedAt.month, a.allocatedAt.day),
    }.toList()..sort();
    for (final day in days) {
      final balance = goalAllocatedCents(after, goalId, asOf: day);
      final without = goalAllocatedCents(others, goalId, asOf: day);
      // Already below $0.00 without this one: not this one's doing.
      if (balance >= 0 || balance >= without) continue;
      if (day == _date && _withdrawing) {
        return 'This goal holds ${formatNetCents(without)}';
      }
      return 'That leaves this goal at ${formatNetCents(balance)} on '
          '${DateFormat('MMM d, yyyy').format(day)}';
    }
    return null;
  }

  /// Why Save is unavailable, for the amount field to show. Null while the
  /// field is empty: an untouched field isn't an error yet.
  String? get _amountError {
    if (_amountController.text.trim().isEmpty) return null;
    if (_parsedCents != null) return _overdrawnError;
    return amountInputError(_amountController.text) ??
        r'Enter an amount over $0.00';
  }

  bool get _canSave =>
      _parsedCents != null && _overdrawnError == null && !_saving;

  Future<void> _pickDate(BuildContext buttonContext) async {
    final accent = paletteColor(widget.goal.colorValue, context);
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
    final existing = widget.existing;
    try {
      // Versioned off disk, as the goal sheet does: a pull can land while
      // this sheet is open.
      final onDisk = existing == null
          ? null
          : (await repo.listGoalAllocations(
              goalId: existing.goalId,
              includeDeleted: true,
            )).where((a) => a.id == existing.id).firstOrNull;
      final base = onDisk ?? existing;
      await repo.upsertGoalAllocation(
        GoalAllocation(
          id: existing?.id ?? newId(),
          createdAt: base?.createdAt ?? now,
          updatedAt: now,
          version: base == null ? 0 : base.version + 1,
          // Deleted while the sheet was open stays deleted.
          deletedAt: base?.deletedAt,
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
    final accent = paletteColor(widget.goal.colorValue, context);
    final allocations =
        ref.watch(goalAllocationsProvider.settled).valueOrNull ?? const [];
    final allocated = goalAllocatedCents(
      allocations,
      widget.goal.id,
      asOf: DateTime.now(),
    );
    final remaining = widget.goal.targetCents - allocated;
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
              // Inside the fields' tap region, as the transaction sheet's
              // toggle is: a click on it no longer unfocuses Amount, so
              // "click Withdraw, type the amount" works (BUG-117).
              TextFieldTapRegion(
                child: SegmentedButton<bool>(
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
                    if (set.isNotEmpty) {
                      setState(() => _withdrawing = set.first);
                    }
                  },
                ),
              ),
              const SizedBox(height: 16),
              // Scoped to the amount field and the button below: rebuilding
              // the whole sheet per keystroke also made its heavy GlassSurface
              // re-blur a window-sized backdrop for every character.
              ListenableBuilder(
                listenable: _amountController,
                builder: (context, _) => VoyagerTextField(
                  controller: _amountController,
                  autofocus: true,
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
                  style: theme.textTheme.headlineSmall?.copyWith(
                    color: accent,
                    fontWeight: FontWeight.w600,
                  ),
                  decoration: InputDecoration(
                    labelText: 'Amount',
                    prefixText: r'$ ',
                    errorText: _amountError,
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
                  hintText: 'From October paycheck',
                ),
                onSubmitted: (_) => _save(),
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
              ListenableBuilder(
                listenable: _amountController,
                builder: (context, _) => GlassButton(
                  onPressed: _canSave ? _save : null,
                  label: widget.existing != null
                      ? 'Save'
                      : _withdrawing
                      ? 'Withdraw'
                      : 'Add funds',
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
