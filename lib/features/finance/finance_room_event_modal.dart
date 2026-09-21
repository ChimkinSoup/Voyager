import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/layout/touch_target.dart';
import 'package:voyager/core/theme/palette_color.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/core/widgets/contextual_popover.dart';
import 'package:voyager/core/widgets/ctrl_enter_to_submit_scope.dart';
import 'package:voyager/core/widgets/date_selector_popover.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/glass_surface.dart';
import 'package:voyager/core/widgets/selector_pill.dart';
import 'package:voyager/core/widgets/voyager_scroll_view.dart';
import 'package:voyager/core/widgets/voyager_text_field.dart';
import 'package:voyager/domain/models/contribution_room_models.dart';
import 'package:voyager/domain/models/finance_models.dart';
import 'package:voyager/domain/services/contribution_room_writer.dart';
import 'package:voyager/domain/services/finance_analytics.dart';
import 'package:voyager/domain/services/finance_origins.dart';

/// Opens the Contribute / Withdraw sheet for [asset], or edits [existing].
Future<void> showRoomCashEventModal(
  BuildContext context,
  WidgetRef ref, {
  required Asset asset,
  required RoomEventKind kind,
  AssetRoomEvent? existing,
}) async {
  // Captured out here, not inside the sheet: see showAssetModal.
  final container = ProviderScope.containerOf(context, listen: false);
  await showVoyagerModal<void>(
    context: context,
    enableDrag: false,
    builder: (ctx) => ProviderScope(
      parent: container,
      child: _RoomCashEventModal(
        container: container,
        asset: asset,
        kind: existing?.kind ?? kind,
        existing: existing,
      ),
    ),
  );
}

/// Opens the Transfer sheet moving money out of [from], or edits the transfer
/// whose two legs are [existingLegs].
Future<void> showRoomTransferModal(
  BuildContext context,
  WidgetRef ref, {
  required Asset from,
  List<AssetRoomEvent> existingLegs = const [],
}) async {
  final container = ProviderScope.containerOf(context, listen: false);
  await showVoyagerModal<void>(
    context: context,
    enableDrag: false,
    builder: (ctx) => ProviderScope(
      parent: container,
      child: _RoomTransferModal(
        container: container,
        from: from,
        existingLegs: existingLegs,
      ),
    ),
  );
}

/// The asset's value at the end of [day], or 0 when it has never been valued.
int _valueOn(List<AssetValuation> valuations, String assetId, DateTime day) =>
    latestValuation(
      valuations,
      assetId,
      asOf: DateTime(day.year, day.month, day.day, 23, 59, 59),
    )?.valueCents ??
    0;

String _centsText(int cents) => (cents / 100).toStringAsFixed(2);

/// [day] at the wall-clock time of [keepTimeOf], or of now for a new entry —
/// the transaction sheet's rule, so same-day entries keep their order.
DateTime _withTime(DateTime day, DateTime? keepTimeOf) {
  final t = keepTimeOf ?? DateTime.now();
  return DateTime(day.year, day.month, day.day, t.hour, t.minute, t.second);
}

/// A value field the sheet fills in for the user until they type in it.
///
/// Tracks the difference between the two by a flag set around the sheet's
/// own writes, since a controller listener can't tell who changed the text.
class _TrackedValueField {
  _TrackedValueField() {
    controller.addListener(() {
      if (!_writing) edited = true;
    });
  }

  final controller = TextEditingController();
  bool edited = false;
  bool _writing = false;

  void propose(int cents) {
    if (edited) return;
    final text = _centsText(cents);
    if (controller.text == text) return;
    _writing = true;
    controller.text = text;
    _writing = false;
  }

  int? get parsed => parseSignedAmountCents(controller.text);

  void dispose() => controller.dispose();
}

class _SheetHeader extends StatelessWidget {
  const _SheetHeader({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Expanded(
          child: Text(
            title,
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
    );
  }
}

class _MutedLine extends StatelessWidget {
  const _MutedLine(this.text, {this.color});

  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      text,
      style: theme.textTheme.labelSmall?.copyWith(
        color: color ?? theme.colorScheme.onSurfaceVariant,
      ),
    );
  }
}

class _AmountField extends StatelessWidget {
  const _AmountField({
    required this.controller,
    required this.accent,
    required this.error,
    required this.onSubmitted,
  });

  final TextEditingController controller;
  final Color accent;
  final String? error;
  final ValueChanged<String> onSubmitted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return VoyagerTextField(
      controller: controller,
      autofocus: true,
      accentColor: accent,
      cursorColor: accent,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [
        FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
        // Bounded so a long paste can't reach the range where double.parse
        // returns Infinity.
        LengthLimitingTextInputFormatter(12),
      ],
      style: theme.textTheme.headlineSmall?.copyWith(
        color: accent,
        fontWeight: FontWeight.w600,
      ),
      decoration: InputDecoration(
        labelText: 'Amount',
        prefixText: r'$ ',
        errorText: error,
      ),
      onSubmitted: onSubmitted,
    );
  }
}

class _ValueField extends StatelessWidget {
  const _ValueField({
    required this.field,
    required this.label,
    required this.previousCents,
    required this.accent,
    this.caption,
  });

  final _TrackedValueField field;
  final String label;
  final int previousCents;
  final Color accent;

  /// Appended to the "Was $X" line under the field.
  final String? caption;

  @override
  Widget build(BuildContext context) {
    // Watches its own controller rather than having the sheet rebuild around
    // it: a `setState` listener on this field re-ran the whole sheet per
    // keystroke, which also made its heavy GlassSurface re-blur a
    // window-sized backdrop for every character.
    return ListenableBuilder(
      listenable: field.controller,
      builder: (context, _) {
        final invalid =
            field.controller.text.trim().isNotEmpty && field.parsed == null;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            VoyagerTextField(
              controller: field.controller,
              accentColor: accent,
              cursorColor: accent,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
                signed: true,
              ),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9.\-]')),
                LengthLimitingTextInputFormatter(13),
              ],
              decoration: InputDecoration(
                labelText: label,
                prefixText: r'$ ',
                errorText: invalid
                    ? amountOverMaxError(field.controller.text) ??
                          'Enter a number, e.g. 1250.00'
                    : null,
              ),
            ),
            const SizedBox(height: 6),
            _MutedLine(
              ['Was ${formatNetCents(previousCents)}', ?caption].join(' · '),
            ),
          ],
        );
      },
    );
  }
}

class _DateRow extends StatelessWidget {
  const _DateRow({
    required this.date,
    required this.active,
    required this.accent,
    required this.onTap,
  });

  final DateTime date;
  final bool active;
  final Color accent;
  final void Function(BuildContext buttonContext) onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
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
            label: DateFormat('MMM d, yyyy').format(date),
            isActive: active,
            accentColor: accent,
            onTap: () => onTap(buttonContext),
          ),
        ),
      ],
    );
  }
}

Future<DateTime?> _pickDay(
  BuildContext context,
  BuildContext buttonContext,
  DateTime initial,
  Color accent,
) async {
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
  if (range == null) return null;
  return DateTime(range.start.year, range.start.month, range.start.day);
}

// ---------------------------------------------------------------------------
// Contribute / Withdraw
// ---------------------------------------------------------------------------

class _RoomCashEventModal extends ConsumerStatefulWidget {
  const _RoomCashEventModal({
    required this.container,
    required this.asset,
    required this.kind,
    this.existing,
  });

  final ProviderContainer container;
  final Asset asset;
  final RoomEventKind kind;
  final AssetRoomEvent? existing;

  @override
  ConsumerState<_RoomCashEventModal> createState() =>
      _RoomCashEventModalState();
}

class _RoomCashEventModalState extends ConsumerState<_RoomCashEventModal> {
  late final TextEditingController _amountController;
  late final TextEditingController _noteController;
  final _value = _TrackedValueField();
  final _noteFocusNode = FocusNode();
  late DateTime _date;
  bool _datePopoverOpen = false;
  bool _saving = false;
  String? _saveError;

  /// Minted once per sheet so a retry overwrites rather than duplicates.
  final _eventId = newId();
  final _transactionId = newId();

  bool get _isContribution => widget.kind == RoomEventKind.contribution;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _amountController = TextEditingController(
      text: existing == null ? '' : _centsText(existing.amountCents),
    );
    _noteController = TextEditingController(text: existing?.note ?? '');
    final base = existing?.occurredAt ?? DateTime.now();
    _date = DateTime(base.year, base.month, base.day);
    _amountController.addListener(_onChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _onChanged();
    });
  }

  @override
  void dispose() {
    _amountController.dispose();
    _noteController.dispose();
    _value.dispose();
    _noteFocusNode.dispose();
    super.dispose();
  }

  int? get _parsedAmount => parseAmountCents(_amountController.text);

  int _previousValue() => _valueOn(
    ref.read(assetValuationsProvider).valueOrNull ?? const [],
    widget.asset.id,
    _date,
  );

  /// Previous value moved by how much this sheet changes the cash: the whole
  /// amount for a new entry, only the difference when editing one whose
  /// original amount the valuation already reflects.
  int _proposedValue() {
    final delta = (_parsedAmount ?? 0) - (widget.existing?.amountCents ?? 0);
    return _previousValue() + (_isContribution ? delta : -delta);
  }

  void _onChanged() {
    _value.propose(_proposedValue());
    setState(() {});
  }

  Future<void> _pickDate(BuildContext buttonContext) async {
    final accent = paletteColor(widget.asset.colorValue, context);
    setState(() => _datePopoverOpen = true);
    final day = await _pickDay(context, buttonContext, _date, accent);
    if (!mounted) return;
    setState(() {
      _datePopoverOpen = false;
      if (day != null) _date = day;
    });
    _onChanged();
  }

  bool get _canSave =>
      _parsedAmount != null && _value.parsed != null && !_saving;

  Future<void> _save() async {
    final amount = _parsedAmount;
    final value = _value.parsed;
    if (amount == null || value == null || _saving) return;
    setState(() {
      _saving = true;
      _saveError = null;
    });
    final repo = ref.read(financeRepositoryProvider);
    final previous = _previousValue();
    final container = widget.container;
    final existing = widget.existing;
    try {
      await saveRoomCashEvent(
        repo,
        asset: widget.asset,
        kind: widget.kind,
        amountCents: amount,
        occurredAt: _withTime(_date, existing?.occurredAt),
        note: trimToNull(_noteController.text),
        // An edit that leaves the value where it was has nothing to record;
        // a new entry always marks the cash move on the asset.
        valuationCents: existing != null && value == previous ? null : value,
        existing: existing,
        eventId: _eventId,
        transactionId: _transactionId,
      );
      container.invalidate(assetRoomEventsProvider);
      container.invalidate(transactionsProvider);
      container.invalidate(assetValuationsProvider);
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
    final accent = paletteColor(widget.asset.colorValue, context);
    final viewInsets = MediaQuery.of(context).viewInsets.bottom;
    // Listened so the proposal catches up once valuations load or a sync
    // lands while the sheet is open.
    ref.listen(assetValuationsProvider, (_, _) => _onChanged());
    final rooms = ref.watch(contributionRoomsProvider).valueOrNull ?? const [];
    final events = ref.watch(assetRoomEventsProvider).valueOrNull ?? const [];
    final roomId = widget.existing?.roomId ?? widget.asset.contributionRoomId;
    final room = rooms.where((r) => r.id == roomId).firstOrNull;
    final now = DateTime.now();
    final existing = widget.existing;

    String? roomLine;
    String? overWarning;
    if (room != null) {
      final summary = roomYearSummary(room, events, now: now);
      roomLine = summary.isOver
          ? '${room.name} is over by ${formatCents(-summary.remainingCents)}'
          : '${formatCents(summary.remainingCents)} of room left in '
                '${room.name} this year';
      final amount = _parsedAmount;
      if (_isContribution && amount != null) {
        // Asked of the year the contribution lands in, at the moment it
        // settles, so a post-dated one warns about the room it will use.
        final landsAfterToday = _date.isAfter(now);
        final projected = roomYearSummary(
          room,
          [
            for (final e in events)
              if (e.id != existing?.id) e,
            AssetRoomEvent(
              id: _eventId,
              createdAt: now,
              updatedAt: now,
              assetId: widget.asset.id,
              roomId: room.id,
              kind: RoomEventKind.contribution,
              amountCents: amount,
              occurredAt: _withTime(_date, existing?.occurredAt),
            ),
          ],
          now: landsAfterToday ? _date : now,
          year: math.max(_date.year, now.year),
        );
        if (projected.isOver) {
          overWarning =
              'This puts ${room.name} over by '
              '${formatCents(-projected.remainingCents)}.';
        }
      }
    }

    final title = existing != null
        ? (_isContribution ? 'Edit contribution' : 'Edit withdrawal')
        : _isContribution
        ? 'Contribute to ${widget.asset.name}'
        : 'Withdraw from ${widget.asset.name}';

    final sheet = Padding(
      padding: EdgeInsets.only(bottom: viewInsets),
      child: VoyagerScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _SheetHeader(title: title),
              if (roomLine != null) _MutedLine(roomLine),
              if (!_isContribution)
                const _MutedLine(
                  'Withdrawals give room back on Jan 1 next year.',
                ),
              const SizedBox(height: 16),
              _AmountField(
                controller: _amountController,
                accent: accent,
                error:
                    _amountController.text.trim().isNotEmpty &&
                        _parsedAmount == null
                    ? amountOverMaxError(_amountController.text) ??
                          r'Enter an amount over $0.00'
                    : null,
                onSubmitted: (_) => _noteFocusNode.requestFocus(),
              ),
              const SizedBox(height: 16),
              _ValueField(
                field: _value,
                label: 'New value of ${widget.asset.name}',
                previousCents: _previousValue(),
                accent: accent,
                caption:
                    'records the cash moving, not a market change. Update '
                    'the asset itself for gains or losses.',
              ),
              const SizedBox(height: 16),
              VoyagerTextField(
                controller: _noteController,
                focusNode: _noteFocusNode,
                accentColor: accent,
                decoration: const InputDecoration(labelText: 'Note'),
                onSubmitted: (_) => _save(),
              ),
              const SizedBox(height: 16),
              _DateRow(
                date: _date,
                active: _datePopoverOpen,
                accent: accent,
                onTap: _pickDate,
              ),
              if (overWarning != null) ...[
                const SizedBox(height: 16),
                _MutedLine(overWarning, color: theme.colorScheme.error),
              ],
              if (_saveError != null) ...[
                const SizedBox(height: 16),
                _MutedLine(_saveError!, color: theme.colorScheme.error),
              ],
              const SizedBox(height: 24),
              ListenableBuilder(
                listenable: _value.controller,
                builder: (context, _) => GlassButton(
                  onPressed: _canSave ? _save : null,
                  label: existing != null
                      ? 'Save'
                      : _isContribution
                      ? 'Contribute'
                      : 'Withdraw',
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

// ---------------------------------------------------------------------------
// Transfer
// ---------------------------------------------------------------------------

class _RoomTransferModal extends ConsumerStatefulWidget {
  const _RoomTransferModal({
    required this.container,
    required this.from,
    required this.existingLegs,
  });

  final ProviderContainer container;
  final Asset from;
  final List<AssetRoomEvent> existingLegs;

  @override
  ConsumerState<_RoomTransferModal> createState() => _RoomTransferModalState();
}

class _RoomTransferModalState extends ConsumerState<_RoomTransferModal> {
  late final TextEditingController _amountController;
  late final TextEditingController _noteController;
  final _fromValue = _TrackedValueField();
  final _toValue = _TrackedValueField();
  final _noteFocusNode = FocusNode();
  late DateTime _date;
  String? _toId;
  bool _datePopoverOpen = false;
  bool _saving = false;
  String? _saveError;

  final _groupId = newId();
  final _outLegId = newId();
  final _inLegId = newId();

  AssetRoomEvent? get _oldOut => widget.existingLegs
      .where((l) => l.kind == RoomEventKind.transferOut)
      .firstOrNull;
  AssetRoomEvent? get _oldIn => widget.existingLegs
      .where((l) => l.kind == RoomEventKind.transferIn)
      .firstOrNull;

  @override
  void initState() {
    super.initState();
    final old = _oldOut ?? _oldIn;
    _amountController = TextEditingController(
      text: old == null ? '' : _centsText(old.amountCents),
    );
    _noteController = TextEditingController(text: old?.note ?? '');
    final base = old?.occurredAt ?? DateTime.now();
    _date = DateTime(base.year, base.month, base.day);
    _toId = _oldIn?.assetId;
    _amountController.addListener(_onChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _onChanged();
    });
  }

  @override
  void dispose() {
    _amountController.dispose();
    _noteController.dispose();
    _fromValue.dispose();
    _toValue.dispose();
    _noteFocusNode.dispose();
    super.dispose();
  }

  int? get _parsedAmount => parseAmountCents(_amountController.text);

  List<Asset> _destinations() {
    final roomId = widget.from.contributionRoomId;
    if (roomId == null) return const [];
    return [
      for (final asset in roomMembers(
        ref.read(assetsProvider).valueOrNull ?? const [],
        roomId,
      ))
        if (asset.id != widget.from.id) asset,
    ];
  }

  int _previous(String assetId) => _valueOn(
    ref.read(assetValuationsProvider).valueOrNull ?? const [],
    assetId,
    _date,
  );

  void _onChanged() {
    final destinations = _destinations();
    if (_toId == null || !destinations.any((a) => a.id == _toId)) {
      _toId = destinations.firstOrNull?.id;
    }
    // As for a single entry: the whole amount when new, the difference when
    // editing a transfer the valuations already reflect.
    final delta = (_parsedAmount ?? 0) - (_oldOut?.amountCents ?? 0);
    _fromValue.propose(_previous(widget.from.id) - delta);
    final toId = _toId;
    if (toId != null) {
      // A changed destination never saw the original amount.
      final toDelta = toId == _oldIn?.assetId ? delta : (_parsedAmount ?? 0);
      _toValue.propose(_previous(toId) + toDelta);
    }
    setState(() {});
  }

  Future<void> _pickDate(BuildContext buttonContext) async {
    final accent = paletteColor(widget.from.colorValue, context);
    setState(() => _datePopoverOpen = true);
    final day = await _pickDay(context, buttonContext, _date, accent);
    if (!mounted) return;
    setState(() {
      _datePopoverOpen = false;
      if (day != null) _date = day;
    });
    _onChanged();
  }

  bool get _canSave =>
      _parsedAmount != null &&
      _toId != null &&
      _fromValue.parsed != null &&
      _toValue.parsed != null &&
      !_saving;

  Future<void> _save() async {
    final amount = _parsedAmount;
    final fromValue = _fromValue.parsed;
    final toValue = _toValue.parsed;
    final to = _destinations().where((a) => a.id == _toId).firstOrNull;
    if (amount == null ||
        fromValue == null ||
        toValue == null ||
        to == null ||
        _saving) {
      return;
    }
    setState(() {
      _saving = true;
      _saveError = null;
    });
    final repo = ref.read(financeRepositoryProvider);
    final editing = widget.existingLegs.isNotEmpty;
    final fromPrevious = _previous(widget.from.id);
    final toPrevious = _previous(to.id);
    final container = widget.container;
    try {
      await saveRoomTransfer(
        repo,
        from: widget.from,
        to: to,
        amountCents: amount,
        occurredAt: _withTime(_date, (_oldOut ?? _oldIn)?.occurredAt),
        note: trimToNull(_noteController.text),
        fromValuationCents: editing && fromValue == fromPrevious
            ? null
            : fromValue,
        toValuationCents: editing && toValue == toPrevious ? null : toValue,
        existingLegs: widget.existingLegs,
        transferGroupId: _groupId,
        outLegId: _outLegId,
        inLegId: _inLegId,
      );
      container.invalidate(assetRoomEventsProvider);
      container.invalidate(assetValuationsProvider);
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
    final accent = paletteColor(widget.from.colorValue, context);
    final viewInsets = MediaQuery.of(context).viewInsets.bottom;
    ref.listen(assetValuationsProvider, (_, _) => _onChanged());
    ref.listen(assetsProvider, (_, _) => _onChanged());
    final destinations = _destinations();
    final to = destinations.where((a) => a.id == _toId).firstOrNull;

    final sheet = Padding(
      padding: EdgeInsets.only(bottom: viewInsets),
      child: VoyagerScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _SheetHeader(
                title: widget.existingLegs.isEmpty
                    ? 'Transfer from ${widget.from.name}'
                    : 'Edit transfer',
              ),
              const _MutedLine(
                'Moves money between accounts sharing a room. Room and ledger '
                'are unchanged.',
              ),
              const SizedBox(height: 16),
              Text(
                'To',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 8),
              if (destinations.isEmpty)
                const _MutedLine('No other asset shares this room.')
              else
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final asset in destinations)
                      ChoiceChip(
                        label: Text(asset.name),
                        selected: asset.id == _toId,
                        selectedColor: accent.withValues(alpha: 0.18),
                        onSelected: (_) {
                          setState(() {
                            _toId = asset.id;
                            // The proposal belongs to the old destination.
                            _toValue.edited = false;
                          });
                          _onChanged();
                        },
                      ),
                  ],
                ),
              const SizedBox(height: 16),
              _AmountField(
                controller: _amountController,
                accent: accent,
                error:
                    _amountController.text.trim().isNotEmpty &&
                        _parsedAmount == null
                    ? amountOverMaxError(_amountController.text) ??
                          r'Enter an amount over $0.00'
                    : null,
                onSubmitted: (_) => _noteFocusNode.requestFocus(),
              ),
              const SizedBox(height: 16),
              _ValueField(
                field: _fromValue,
                label: 'New value of ${widget.from.name}',
                previousCents: _previous(widget.from.id),
                accent: accent,
              ),
              if (to != null) ...[
                const SizedBox(height: 16),
                _ValueField(
                  field: _toValue,
                  label: 'New value of ${to.name}',
                  previousCents: _previous(to.id),
                  accent: accent,
                ),
              ],
              const SizedBox(height: 16),
              VoyagerTextField(
                controller: _noteController,
                focusNode: _noteFocusNode,
                accentColor: accent,
                decoration: const InputDecoration(labelText: 'Note'),
                onSubmitted: (_) => _save(),
              ),
              const SizedBox(height: 16),
              _DateRow(
                date: _date,
                active: _datePopoverOpen,
                accent: accent,
                onTap: _pickDate,
              ),
              if (_saveError != null) ...[
                const SizedBox(height: 16),
                _MutedLine(_saveError!, color: theme.colorScheme.error),
              ],
              const SizedBox(height: 24),
              ListenableBuilder(
                listenable: Listenable.merge([
                  _fromValue.controller,
                  _toValue.controller,
                ]),
                builder: (context, _) => GlassButton(
                  onPressed: _canSave ? _save : null,
                  label: widget.existingLegs.isEmpty ? 'Transfer' : 'Save',
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
