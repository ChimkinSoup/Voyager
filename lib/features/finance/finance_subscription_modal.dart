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
import 'package:voyager/features/finance/finance_soft_delete.dart';
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
    kind: VoyagerSheetKind.editor,
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
  final _amountFocusNode = FocusNode();
  final _noteFocusNode = FocusNode();
  late BillingPeriod _period;
  late DateTime _dueDate;
  /// The anchor and cadence this sheet opened on, to tell an edited series
  /// from an untouched one (see [_retainedPaidThrough]).
  late final DateTime _initialDueDate;
  late final BillingPeriod _initialPeriod;
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
    _initialDueDate = _dueDate;
    _initialPeriod = _period;
    _colorValue = existing?.colorValue ?? 0xFF7C9EFF;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _amountController.dispose();
    _noteController.dispose();
    _amountFocusNode.dispose();
    _noteFocusNode.dispose();
    super.dispose();
  }

  int? get _parsedCents => parseAmountCents(_amountController.text);

  /// Why Save is unavailable, for the amount field to show. Null while the
  /// field is empty: an untouched field isn't an error yet.
  String? get _amountError {
    if (_amountController.text.trim().isEmpty) return null;
    return _parsedCents == null ? r'Enter an amount over $0.00' : null;
  }

  /// The recorded payment this bill keeps through the save, or null if the
  /// edit drops it.
  ///
  /// Rewriting the anchor or the cadence defines a new series, and a payment
  /// recorded against the old one would silently swallow a cycle of the new
  /// one — the picker and the radar would disagree again, which is the whole
  /// bug this field exists to remove. It also leaves re-picking the date as
  /// the way to undo a mis-clicked Log payment.
  DateTime? get _retainedPaidThrough {
    final existing = widget.existing;
    if (existing == null) return null;
    if (_dueDate != _initialDueDate || _period != _initialPeriod) return null;
    return existing.paidThroughDate;
  }

  bool get _canSave =>
      _parsedCents != null &&
      _nameController.text.trim().isNotEmpty &&
      !_saving;

  Future<void> _pickDate(BuildContext buttonContext) async {
    final accent = paletteColor(_colorValue, context);
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
      paidThroughDate: _retainedPaidThrough,
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
    // The root overlay, resolved before the sheet closes: the undo offer has
    // to outlive the sheet that raised it. Shares one path with the radar's
    // right-click Delete so both offer the same undo.
    final overlay = Overlay.of(context, rootOverlay: true);
    final deleted = await deleteSubscriptionWithUndo(
      overlay: overlay,
      container: widget.container,
      repo: ref.read(financeRepositoryProvider),
      subscription: existing,
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
    // What the radar will actually show for this anchor, so the editor and
    // the radar can't disagree.
    final nextDue = nextDueAfterPaid(
      anchor: _dueDate,
      period: _period,
      paidThrough: _retainedPaidThrough,
      from: DateTime.now(),
    );
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
              if (voyagerSheetDrags(VoyagerSheetKind.editor))
                const VoyagerSheetHandle(),
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
                onSubmitted: (_) => _amountFocusNode.requestFocus(),
              ),
              const SizedBox(height: 16),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    // Only the pieces that read the typed text rebuild as it
                    // is typed. A `setState` listener on the controllers
                    // rebuilt the whole sheet per keystroke, which also made
                    // its heavy GlassSurface re-blur a window-sized backdrop
                    // for every character.
                    child: ListenableBuilder(
                      listenable: _amountController,
                      builder: (context, _) => VoyagerTextField(
                        controller: _amountController,
                        focusNode: _amountFocusNode,
                        accentColor: accent,
                        cursorColor: accent,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        inputFormatters: [
                          FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                          // Bounded so a long paste can't reach the range
                          // where double.parse returns Infinity.
                          LengthLimitingTextInputFormatter(12),
                        ],
                        decoration: InputDecoration(
                          labelText: 'Amount',
                          prefixText: r'$ ',
                          errorText: _amountError,
                        ),
                        // Past the Billing dropdown: the chain is text only.
                        onSubmitted: (_) => _noteFocusNode.requestFocus(),
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
              ListenableBuilder(
                listenable: _amountController,
                builder: (context, _) {
                  final cents = _parsedCents;
                  if (cents == null) return const SizedBox.shrink();
                  return Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      '${formatCents(annualCentsFor(cents, _period))} per year',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  );
                },
              ),
              const SizedBox(height: 16),
              VoyagerTextField(
                controller: _noteController,
                focusNode: _noteFocusNode,
                accentColor: accent,
                decoration: const InputDecoration(
                  labelText: 'Note',
                  hintText: 'Family plan',
                ),
                onSubmitted: (_) => _save(),
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
              ListenableBuilder(
                listenable: Listenable.merge([
                  _nameController,
                  _amountController,
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
