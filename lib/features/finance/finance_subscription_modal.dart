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
import 'package:voyager/core/widgets/voyager_dropdown_button.dart';
import 'package:voyager/core/widgets/voyager_text_field.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/finance_models.dart';
import 'package:voyager/core/layout/touch_target.dart';
import 'package:voyager/core/widgets/voyager_scroll_view.dart';

/// Opens the add / edit subscription modal. When [existing] is provided the
/// modal edits that subscription in place.
Future<void> showSubscriptionModal(
  BuildContext context,
  WidgetRef ref, {
  Subscription? existing,
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
      child: _SubscriptionModal(container: container, existing: existing),
    ),
  );
}

class _SubscriptionModal extends ConsumerStatefulWidget {
  const _SubscriptionModal({required this.container, this.existing});

  /// The app-level container, which outlives this sheet. See
  /// [showSubscriptionModal].
  final ProviderContainer container;

  final Subscription? existing;

  @override
  ConsumerState<_SubscriptionModal> createState() => _SubscriptionModalState();
}

class _SubscriptionModalState extends ConsumerState<_SubscriptionModal> {
  late final TextEditingController _nameController;
  late final TextEditingController _amountController;
  late final TextEditingController _noteController;
  late BillingPeriod _period;
  late DateTime _dueDate;
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
    _amountController = TextEditingController(
      text: existing == null
          ? ''
          : (existing.amountCents / 100).toStringAsFixed(2),
    );
    _noteController = TextEditingController(text: existing?.note ?? '');
    _period = existing?.period ?? BillingPeriod.monthly;
    final base = existing?.anchorDueDate ?? DateTime.now();
    _dueDate = DateTime(base.year, base.month, base.day);
    _colorValue = existing?.colorValue ?? 0xFF7C9EFF;
    _amountController.addListener(_onFieldChanged);
    _nameController.addListener(_onFieldChanged);
  }

  @override
  void dispose() {
    _nameController.dispose();
    _amountController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  void _onFieldChanged() => setState(() {});

  int? get _parsedCents => parseAmountCents(_amountController.text);

  /// Why Save is unavailable, for the amount field to show. Null while the
  /// field is empty: an untouched field isn't an error yet.
  String? get _amountError {
    if (_amountController.text.trim().isEmpty) return null;
    return _parsedCents == null ? r'Enter an amount over $0.00' : null;
  }

  bool get _canSave =>
      _parsedCents != null &&
      _nameController.text.trim().isNotEmpty &&
      !_saving;

  Future<void> _pickDate(BuildContext buttonContext) async {
    final accent = Color(_colorValue);
    setState(() => _datePopoverOpen = true);
    final range = await showContextualPopover<DateTimeRange>(
      context: context,
      buttonContext: buttonContext,
      width: 320,
      height: 380,
      accentColor: accent,
      builder: (_) => DateSelectorPopover(
        initialStartDate: _dueDate,
        initialEndDate: _dueDate,
        singleDateMode: true,
        accentColor: accent,
      ),
    );
    if (!mounted) return;
    setState(() {
      _datePopoverOpen = false;
      if (range != null) {
        _dueDate =
            DateTime(range.start.year, range.start.month, range.start.day);
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
    final existing = widget.existing;
    final subscription = Subscription(
      id: existing?.id ?? newId(),
      createdAt: existing?.createdAt ?? now,
      updatedAt: now,
      version: existing == null ? 0 : existing.version + 1,
      name: _nameController.text.trim(),
      amountCents: cents,
      period: _period,
      anchorDueDate: _dueDate,
      colorValue: _colorValue,
      note: _noteController.text.trim().isEmpty
          ? null
          : _noteController.text.trim(),
    );

    // Read before the first await: `ref` throws once this sheet is disposed.
    final repo = ref.read(financeRepositoryProvider);
    final container = widget.container;
    try {
      await repo.upsertSubscription(subscription);
      // Through the container, not `ref`: the invalidate has to land even
      // when the sheet was dismissed mid-write.
      container.invalidate(subscriptionsProvider);
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
      await repo.softDeleteSubscription(existing.id);
      container.invalidate(subscriptionsProvider);
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
    final cents = _parsedCents;
    // What the radar will actually show for this anchor, so the editor and
    // the radar can't disagree.
    final nextDue = nextDueDate(_dueDate, _period, DateTime.now());
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
                    widget.existing == null
                        ? 'New subscription'
                        : 'Edit subscription',
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
                  labelText: 'Name',
                  hintText: 'Netflix',
                ),
              ),
              const SizedBox(height: 16),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: VoyagerTextField(
                      controller: _amountController,
                      accentColor: accent,
                      cursorColor: accent,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                        // Bounded so a long paste can't reach the range where
                        // double.parse returns Infinity.
                        LengthLimitingTextInputFormatter(12),
                      ],
                      decoration: InputDecoration(
                        labelText: 'Amount',
                        prefixText: r'$ ',
                        errorText: _amountError,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: VoyagerDropdownButtonFormField<BillingPeriod>(
                      initialValue: _period,
                      accentColor: accent,
                      decoration: const InputDecoration(labelText: 'Billing'),
                      items: [
                        for (final p in BillingPeriod.values)
                          DropdownMenuItem(
                            value: p,
                            child: Text(
                              billingPeriodLabel(p),
                              style: const TextStyle(fontSize: 13),
                            ),
                          ),
                      ],
                      onChanged: (p) {
                        if (p != null) setState(() => _period = p);
                      },
                    ),
                  ),
                ],
              ),
              if (cents != null) ...[
                const SizedBox(height: 6),
                Text(
                  '${formatCents(annualCentsFor(cents, _period))} per year',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
              const SizedBox(height: 16),
              VoyagerTextField(
                controller: _noteController,
                accentColor: accent,
                decoration: const InputDecoration(
                  labelText: 'Note',
                  hintText: 'Family plan',
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Text(
                    // This pill edits `anchorDueDate` — the date the cadence
                    // is measured from, which nextDue() rolls forward. It is
                    // not itself the next occurrence, and calling it "Next
                    // due" made the editor contradict the radar for every
                    // bill older than one billing cycle.
                    widget.existing == null ? 'First due' : 'Recurs on',
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const Spacer(),
                  Builder(
                    builder: (buttonContext) => SelectorPill(
                      icon: PhosphorIconsRegular.calendar,
                      label: DateFormat('MMM d, yyyy').format(_dueDate),
                      isActive: _datePopoverOpen,
                      accentColor: accent,
                      onTap: () => _pickDate(buttonContext),
                    ),
                  ),
                ],
              ),
              if (nextDue != _dueDate) ...[
                const SizedBox(height: 6),
                Text(
                  'Next due ${DateFormat('MMM d, yyyy').format(nextDue)}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
              const SizedBox(height: 16),
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
