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
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/glass_surface.dart';
import 'package:voyager/core/widgets/selector_pill.dart';
import 'package:voyager/core/widgets/voyager_text_field.dart';
import 'package:voyager/domain/models/finance_models.dart';
import 'package:voyager/core/layout/touch_target.dart';
import 'package:voyager/core/widgets/voyager_scroll_view.dart';

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
  await showVoyagerSheet<void>(
    context: context,
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

  int? get _parsedTarget => parseAmountCents(_targetController.text);

  /// Why Save is unavailable, for the target field to show. Null while the
  /// field is empty: an untouched field isn't an error yet.
  String? get _targetError {
    if (_targetController.text.trim().isEmpty) return null;
    return _parsedTarget == null ? r'Enter a target over $0.00' : null;
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
      await repo.upsertSavingsGoal(
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
    final repo = ref.read(financeRepositoryProvider);
    final container = widget.container;
    try {
      await repo.softDeleteSavingsGoal(existing.id);
      container.invalidate(savingsGoalsProvider);
      container.invalidate(goalAllocationsProvider);
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
                  // Bounded so a long paste can't reach the range where
                  // double.parse returns Infinity.
                  LengthLimitingTextInputFormatter(12),
                ],
                decoration: InputDecoration(
                  labelText: 'Target amount',
                  prefixText: r'$ ',
                  errorText: _targetError,
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
