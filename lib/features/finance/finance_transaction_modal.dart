import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/core/utils/journal_tags.dart';
import 'package:voyager/core/widgets/contextual_popover.dart';
import 'package:voyager/core/widgets/ctrl_enter_to_submit_scope.dart';
import 'package:voyager/core/widgets/date_selector_popover.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/glass_surface.dart';
import 'package:voyager/core/widgets/selector_pill.dart';
import 'package:voyager/core/widgets/voyager_text_field.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/finance_models.dart';
import 'package:voyager/domain/repositories/repositories.dart';
import 'package:voyager/domain/services/contribution_room_writer.dart';
import 'package:voyager/domain/services/finance_origins.dart';
import 'package:voyager/features/finance/finance_origin_field.dart';
import 'package:voyager/core/layout/touch_target.dart';
import 'package:voyager/core/tags/tag_suggestions.dart';
import 'package:voyager/core/widgets/voyager_scroll_view.dart';

/// The green used for money flowing in, across the finance feature. Chosen to
/// stay legible on both the light and dark surfaces.
const Color kIncomeGreen = Color(0xFF3BA776);

/// Fields a new transaction opens prefilled with.
///
/// Every one of them stays editable: a draft is a starting point the caller
/// happens to know (a bill's name and amount, say), not a commitment. Only
/// meaningful when no `existing` transaction is being edited.
class FinanceTransactionDraft {
  const FinanceTransactionDraft({
    this.type = TransactionType.expense,
    this.amountCents,
    this.origin,
    this.note,
    this.occurredAt,
    this.tags = const [],
  });

  final TransactionType type;
  final int? amountCents;
  final String? origin;
  final String? note;
  final DateTime? occurredAt;
  final List<String> tags;
}

/// Opens the animated "log a transaction" modal. When [existing] is provided
/// the modal edits that transaction in place instead of creating a new one;
/// [draft] prefills a new one.
///
/// [onSaved] runs after a successful write and before the sheet closes, for
/// the bookkeeping that only makes sense once the money is actually recorded —
/// advancing a bill's due date, say. It does not run when the sheet is
/// dismissed, and a throw from it is the caller's to handle.
///
/// [onDraft] receives the unsaved fields when the sheet closes without a save
/// (null when they are all empty), and null after a save.
Future<void> showFinanceTransactionModal(
  BuildContext context,
  WidgetRef ref, {
  FinancialTransaction? existing,
  FinanceTransactionDraft? draft,
  Future<void> Function()? onSaved,
  ValueChanged<FinanceTransactionDraft?>? onDraft,
}) async {
  // Captured out here, not inside the sheet: the sheet builds its own
  // ProviderScope, and that container is disposed the moment the sheet is
  // dismissed — which can happen while a save is still in flight, when the
  // invalidate still has to land or the ledger keeps showing pre-write data.
  final container = ProviderScope.containerOf(context, listen: false);
  await showVoyagerModal<void>(
    context: context,
    enableDrag: false,
    builder: (ctx) => ProviderScope(
      parent: container,
      child: _TransactionModal(
        container: container,
        existing: existing,
        draft: draft,
        onSaved: onSaved,
        onDraft: onDraft,
      ),
    ),
  );
}

/// The modal's form without its sheet, for the finance hotkey floater, which
/// is not a route: [onClose] stands in for the sheet's pop, after a save and
/// from the close button alike.
///
/// [onSaveErrorHeight] reports how tall the failed-save line is, zero when
/// there is none. The floater's window is sized to the form, and that line is
/// the one part of it whose height nothing can predict — the message carries
/// an exception string — so the window grows by what this reports instead of
/// the form scrolling inside it.
///
/// [leading] goes before the title.
Widget financeTransactionForm({
  required ProviderContainer container,
  required VoidCallback onClose,
  FinanceTransactionDraft? draft,
  Future<void> Function()? onSaved,
  ValueChanged<FinanceTransactionDraft?>? onDraft,
  ValueChanged<double>? onSaveErrorHeight,
  Widget? leading,
  bool autofocus = true,
}) {
  return _TransactionModal(
    container: container,
    draft: draft,
    onSaved: onSaved,
    onClose: onClose,
    onDraft: onDraft,
    onSaveErrorHeight: onSaveErrorHeight,
    leading: leading,
    autofocus: autofocus,
  );
}

class _TransactionModal extends ConsumerStatefulWidget {
  const _TransactionModal({
    required this.container,
    this.existing,
    this.draft,
    this.onSaved,
    this.onClose,
    this.onDraft,
    this.onSaveErrorHeight,
    this.leading,
    this.autofocus = true,
  });

  /// The app-level container, which outlives this sheet. See
  /// [showFinanceTransactionModal].
  final ProviderContainer container;

  final FinancialTransaction? existing;
  final FinanceTransactionDraft? draft;
  final Future<void> Function()? onSaved;
  final VoidCallback? onClose;
  final ValueChanged<FinanceTransactionDraft?>? onDraft;

  /// See [financeTransactionForm].
  final ValueChanged<double>? onSaveErrorHeight;

  /// See [financeTransactionForm].
  final Widget? leading;

  /// Whether a new transaction's amount field takes focus on mount.
  final bool autofocus;

  @override
  ConsumerState<_TransactionModal> createState() => _TransactionModalState();
}

class _TransactionModalState extends ConsumerState<_TransactionModal> {
  late TransactionType _type;
  late final TextEditingController _amountController;
  late final TextEditingController _originController;
  late final TextEditingController _noteController;
  late final TextEditingController _tagsController;
  final _originFocusNode = FocusNode();
  final _noteFocusNode = FocusNode();
  final _tagsFocusNode = FocusNode();
  late DateTime _date;
  bool _datePopoverOpen = false;
  bool _saving = false;

  /// Set when a write throws, so the sheet says what went wrong instead of
  /// silently sitting there with Save disabled forever.
  String? _saveError;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    // The draft only speaks for a *new* transaction; editing one, its own
    // values are the only sensible starting point.
    final draft = existing == null ? widget.draft : null;
    _type = existing?.type ?? draft?.type ?? TransactionType.expense;
    final amountCents = existing?.amountCents ?? draft?.amountCents;
    _amountController = TextEditingController(
      text: amountCents == null ? '' : (amountCents / 100).toStringAsFixed(2),
    );
    _originController = TextEditingController(
      text: existing?.origin ?? draft?.origin ?? '',
    );
    _noteController = TextEditingController(
      text: existing?.note ?? draft?.note ?? '',
    );
    _tagsController = TextEditingController(
      text: (existing?.tags ?? draft?.tags ?? const <String>[])
          .map((t) => '#$t')
          .join(' '),
    );
    final base = existing?.occurredAt ?? draft?.occurredAt ?? DateTime.now();
    _date = DateTime(base.year, base.month, base.day);
    _newId = newId();
  }

  /// Set once a save has written the transaction, so closing doesn't hand
  /// back a draft of money already recorded.
  var _saved = false;

  /// Completes when the save in flight has finished, either way; null when no
  /// save is running.
  Future<void>? _saveSettled;

  void _close() {
    final onClose = widget.onClose;
    if (onClose != null) {
      onClose();
    } else {
      Navigator.of(context).pop();
    }
  }

  FinanceTransactionDraft? _unsavedDraft() {
    if (_saved) return null;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final amountCents = _parsedCents;
    final origin = trimToNull(_originController.text);
    final note = trimToNull(_noteController.text);
    final tags = _parsedTags;
    // The date only counts when it was moved: an untouched "today" kept as a
    // draft would reopen tomorrow pinned to yesterday.
    final occurredAt = _date == today ? null : _date;
    if (_type == TransactionType.expense &&
        amountCents == null &&
        origin == null &&
        note == null &&
        tags.isEmpty &&
        occurredAt == null) {
      return null;
    }
    return FinanceTransactionDraft(
      type: _type,
      amountCents: amountCents,
      origin: origin,
      note: note,
      occurredAt: occurredAt,
      tags: tags,
    );
  }

  @override
  void dispose() {
    final onDraft = widget.onDraft;
    final saveSettled = _saveSettled;
    if (onDraft != null && saveSettled != null) {
      // Closed while a save is in flight: the fields are a draft only if the
      // write fails.
      final draft = _unsavedDraft();
      unawaited(saveSettled.then((_) => onDraft(_saved ? null : draft)));
    } else {
      onDraft?.call(_unsavedDraft());
    }
    _amountController.dispose();
    _originController.dispose();
    _originFocusNode.dispose();
    _noteController.dispose();
    _noteFocusNode.dispose();
    _tagsController.dispose();
    _tagsFocusNode.dispose();
    super.dispose();
  }

  /// Store and Source are separate vocabularies, so an origin typed for one
  /// type means nothing for the other: the switch clears it rather than
  /// carrying a store over as a source.
  void _setType(TransactionType type) {
    if (type == _type) return;
    setState(() {
      _type = type;
      _originController.clear();
    });
  }

  int? get _parsedCents => parseAmountCents(_amountController.text);

  /// Why Save is unavailable, for the amount field to show. Null while the
  /// field is empty: an untouched field isn't an error yet.
  String? get _amountError {
    if (_amountController.text.trim().isEmpty) return null;
    if (_parsedCents != null) return null;
    return amountOverMaxError(_amountController.text) ??
        r'Enter an amount over $0.00';
  }

  /// Parses the tags field into clean tag names (no leading `#`). Accepts both
  /// `#hashtag` and bare word styles, split on whitespace or commas.
  List<String> get _parsedTags {
    final raw = _tagsController.text.split(RegExp(r'[\s,]+'));
    final seen = <String>{};
    for (final token in raw) {
      final tag = token.replaceAll('#', '').trim();
      if (tag.isNotEmpty) seen.add(tag);
    }
    return seen.toList();
  }

  Future<void> _pickDate(BuildContext buttonContext) async {
    final accent = Theme.of(context).colorScheme.primary;
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

  /// The id a *new* transaction will be written under, minted once.
  ///
  /// Per sheet rather than per save attempt: [_save] can now fail after the
  /// write has already landed — [widget.onSaved] runs inside its try — and a
  /// fresh id on the retry would file the same expense twice.
  late final String _newId;

  Future<void> _save() async {
    final cents = _parsedCents;
    if (cents == null || _saving) return;
    setState(() {
      _saving = true;
      _saveError = null;
    });

    final now = utcNow();
    final tags = _parsedTags;
    final existing = widget.existing;
    // Preserve the time-of-day for a fresh entry so same-day transactions keep
    // a stable chronological order in the feed.
    final wall = DateTime.now();
    final occurredAt = DateTime(
      _date.year,
      _date.month,
      _date.day,
      existing?.occurredAt.hour ?? wall.hour,
      existing?.occurredAt.minute ?? wall.minute,
      existing?.occurredAt.second ?? wall.second,
    );

    final financeRepo = ref.read(financeRepositoryProvider);
    // Both reads happen before the first await: `ref` throws once this sheet
    // is disposed, and it can be dismissed while the write is in flight.
    final settingsRepo = ref.read(settingsRepositoryProvider);
    final container = widget.container;
    // Whether the ledger row is already on disk. Everything after it — the
    // tag colors, and a caller's bill advance — can fail on its own, and
    // reporting that as a failed save would send the user back to re-enter
    // money the ledger has already taken.
    var written = false;
    final settled = Completer<void>();
    _saveSettled = settled.future;
    try {
      // Re-read rather than trusting [existing] — see the goal sheet. Also
      // covers a retry of a new entry, whose first attempt is already on disk.
      final id = existing?.id ?? _newId;
      final base = await financeRepo.getTransaction(id) ?? existing;
      final transaction = FinancialTransaction(
        id: id,
        createdAt: base?.createdAt ?? now,
        updatedAt: now,
        version: base == null ? 0 : base.version + 1,
        deletedAt: base?.deletedAt,
        type: _type,
        amountCents: cents,
        occurredAt: occurredAt,
        origin: trimToNull(_originController.text),
        note: trimToNull(_noteController.text),
        tags: tags,
        // A room event attached or detached while the sheet was open.
        roomEventId: base?.roomEventId,
      );
      await financeRepo.upsertTransaction(transaction);
      written = true;
      _saved = true;
      if (transaction.roomEventId != null) {
        await syncRoomEventFromTransaction(financeRepo, transaction);
        container.invalidate(assetRoomEventsProvider);
      }
      await _persistTagColors(settingsRepo, tags);

      // Through the container, not `ref`: the invalidate has to land even
      // when the sheet was dismissed mid-write, or the ledger keeps showing
      // pre-write data until something else refreshes it.
      container.invalidate(transactionsProvider);
      container.invalidate(tagColorsProvider);
      // After the write, before the pop: a caller advancing a bill's due date
      // is recording a consequence of *this* save, and a failure there has to
      // land in this sheet's error line rather than on a dismissed one.
      await widget.onSaved?.call();
      if (mounted) _close();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        // The retry re-runs the whole save, but [_newId] is minted per sheet,
        // so the second attempt overwrites the row it already wrote rather
        // than filing the same expense twice.
        _saveError = written
            ? 'Saved, but the step after it failed: $e\n'
                  'Press ${widget.existing == null ? 'Add' : 'Save'} to retry '
                  'it — this will not log a second entry.'
            : 'Could not save: $e';
      });
    } finally {
      _saveSettled = null;
      settled.complete();
    }
  }

  Future<void> _persistTagColors(
    SettingsRepository settingsRepo,
    List<String> tags,
  ) async {
    final colors = await settingsRepo.getTagColors();
    for (final tag in tags) {
      if (!colors.containsKey(tag)) {
        await settingsRepo.setTagColor(tag, colorForTag(tag));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    final isDeposit = _type == TransactionType.deposit;
    final amountColor = isDeposit ? kIncomeGreen : accent;
    final viewInsets = MediaQuery.of(context).viewInsets.bottom;
    final linked = widget.existing?.roomEventId != null;

    final sheet = Padding(
      padding: EdgeInsets.only(bottom: viewInsets),
      child: VoyagerScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Header row
              Row(
                children: [
                  if (widget.leading case final leading?) ...[
                    leading,
                    const SizedBox(width: 8),
                  ],
                  Text(
                    widget.existing == null
                        ? 'New transaction'
                        : 'Edit transaction',
                    style: theme.textTheme.titleMedium,
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: _close,
                    icon: const Icon(PhosphorIconsRegular.x, size: 18),
                    tooltip: 'Close',
                    padding: EdgeInsets.zero,
                    constraints: kMinTouchTarget,
                  ),
                ],
              ),
              if (linked) ...[
                Text(
                  'Linked to a contribution room. Amount, date and note '
                  'changes update it too; update the asset for its value.',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 4),
              ],
              const SizedBox(height: 12),
              // Expense / Deposit toggle
              SegmentedButton<TransactionType>(
                showSelectedIcon: false,
                style: SegmentedButton.styleFrom(
                  selectedBackgroundColor: amountColor.withValues(alpha: 0.18),
                  selectedForegroundColor: amountColor,
                ),
                segments: const [
                  ButtonSegment(
                    value: TransactionType.expense,
                    icon: Icon(PhosphorIconsRegular.arrowUp, size: 16),
                    label: Text('Expense'),
                  ),
                  ButtonSegment(
                    value: TransactionType.deposit,
                    icon: Icon(PhosphorIconsRegular.arrowDown, size: 16),
                    label: Text('Deposit'),
                  ),
                ],
                selected: {_type},
                // Locked when linked: the type is what makes it a
                // contribution or a withdrawal.
                onSelectionChanged: linked
                    ? null
                    : (set) {
                        if (set.isNotEmpty) _setType(set.first);
                      },
              ),
              const SizedBox(height: 16),
              // Amount. Only this field and the save button read the typed
              // figure, so only they rebuild as it is typed: a `setState`
              // listener on the controller rebuilt the whole sheet per
              // keystroke, which also made its heavy GlassSurface re-blur a
              // window-sized backdrop for every character.
              ListenableBuilder(
                listenable: _amountController,
                builder: (context, _) => VoyagerTextField(
                  controller: _amountController,
                  autofocus: widget.autofocus && widget.existing == null,
                  accentColor: amountColor,
                  cursorColor: amountColor,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                    // Bounded so a long paste can't reach the range where
                    // double.parse returns Infinity.
                    LengthLimitingTextInputFormatter(12),
                  ],
                  style: theme.textTheme.headlineSmall?.copyWith(
                    color: amountColor,
                    fontWeight: FontWeight.w600,
                  ),
                  decoration: InputDecoration(
                    labelText: 'Amount',
                    prefixText: r'$ ',
                    errorText: _amountError,
                  ),
                  // Enter walks Amount → Store/Source → Note → Tags, and Enter
                  // in Tags saves.
                  onSubmitted: (_) => _originFocusNode.requestFocus(),
                ),
              ),
              const SizedBox(height: 16),
              // Store / Source
              FinanceOriginField(
                controller: _originController,
                focusNode: _originFocusNode,
                // Watched, so a row deleted or restored while the sheet is
                // open reaches the list without reopening it.
                origins: recentTransactionOrigins(
                  ref.watch(transactionsProvider).valueOrNull ?? const [],
                  _type,
                  DateTime.now(),
                ),
                label: isDeposit ? 'Source' : 'Store',
                hintText: isDeposit ? 'Employer' : 'Walmart',
                accentColor: accent,
                onSubmitted: (_) => _noteFocusNode.requestFocus(),
              ),
              const SizedBox(height: 16),
              // Note
              VoyagerTextField(
                controller: _noteController,
                focusNode: _noteFocusNode,
                accentColor: accent,
                decoration: InputDecoration(
                  labelText: 'Note',
                  hintText: isDeposit ? 'Paycheque' : 'Toothpaste',
                ),
                onSubmitted: (_) => _tagsFocusNode.requestFocus(),
              ),
              const SizedBox(height: 16),
              // Tags
              VoyagerTextField(
                controller: _tagsController,
                focusNode: _tagsFocusNode,
                accentColor: accent,
                tagScope: TagScope.finance,
                decoration: const InputDecoration(
                  labelText: 'Tags',
                  hintText: '#groceries #travel',
                ),
                // Only reached with the tag popup closed — an open popup takes
                // Enter for its suggestion. _save refuses an invalid form.
                onSubmitted: (_) => _save(),
              ),
              const SizedBox(height: 16),
              // Date
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
                      label: _formatDate(_date),
                      isActive: _datePopoverOpen,
                      accentColor: accent,
                      onTap: () => _pickDate(buttonContext),
                    ),
                  ),
                ],
              ),
              // Mounted even with no error, so its height is reported as
              // zero and the floater's window shrinks back by it.
              _reportSaveErrorHeight(
                _saveError == null
                    ? const SizedBox.shrink()
                    : Padding(
                        padding: const EdgeInsets.only(top: 16),
                        child: Text(
                          _saveError!,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.error,
                          ),
                        ),
                      ),
              ),
              const SizedBox(height: 24),
              ListenableBuilder(
                listenable: _amountController,
                builder: (context, _) => GlassButton(
                  onPressed: _parsedCents != null && !_saving ? _save : null,
                  label: widget.existing == null ? 'Add' : 'Save',
                  color: amountColor,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    // _save validates for itself, so it can go in unconditionally: a callback
    // gated on canSave is only as fresh as the last build.
    return CtrlEnterToSubmitScope(onSubmit: _save, child: sheet);
  }

  /// Wraps the failed-save line in its height report, for the floater; the
  /// sheet, which scrolls inside a window it doesn't own, wants none.
  Widget _reportSaveErrorHeight(Widget child) {
    final onHeight = widget.onSaveErrorHeight;
    return onHeight == null
        ? child
        : _ReportHeight(onHeight: onHeight, child: child);
  }

  String _formatDate(DateTime d) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    if (d == today) return 'Today';
    if (d == DateTime(today.year, today.month, today.day - 1)) {
      return 'Yesterday';
    }
    return DateFormat('MMM d, yyyy').format(d);
  }
}

/// Reports its child's height after every layout that changes it.
///
/// Measured in the render tree rather than from a build because the failed
/// save that grows it is a `setState` deep inside the form, and reported off
/// the frame rather than in a post-frame callback because the listener resizes
/// the OS window: Win32's `SetWindowPlacement` pumps the message loop, which
/// re-enters Flutter's frame, and that asserts from anywhere inside one.
class _ReportHeight extends SingleChildRenderObjectWidget {
  const _ReportHeight({required this.onHeight, required super.child});

  final ValueChanged<double> onHeight;

  @override
  _RenderReportHeight createRenderObject(BuildContext context) =>
      _RenderReportHeight(onHeight);

  @override
  void updateRenderObject(BuildContext context, _RenderReportHeight box) =>
      box.onHeight = onHeight;
}

class _RenderReportHeight extends RenderProxyBox {
  _RenderReportHeight(this.onHeight);

  ValueChanged<double> onHeight;
  double? _reported;

  @override
  void performLayout() {
    super.performLayout();
    if (size.height == _reported) return;
    _reported = size.height;
    Timer.run(() {
      if (attached) onHeight(size.height);
    });
  }
}
