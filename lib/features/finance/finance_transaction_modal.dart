import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/text/list_text_editing.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/core/utils/journal_tags.dart';
import 'package:voyager/core/widgets/contextual_popover.dart';
import 'package:voyager/core/widgets/date_selector_popover.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/glass_surface.dart';
import 'package:voyager/core/widgets/selector_pill.dart';
import 'package:voyager/core/widgets/voyager_text_field.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/finance_models.dart';
import 'package:voyager/domain/repositories/repositories.dart';
import 'package:voyager/core/layout/touch_target.dart';
import 'package:voyager/core/tags/tag_suggestions.dart';
import 'package:voyager/core/widgets/voyager_scroll_view.dart';

/// The green used for money flowing in, across the finance feature. Chosen to
/// stay legible on both the light and dark surfaces.
const Color kIncomeGreen = Color(0xFF3BA776);

/// Opens the animated "log a transaction" modal. When [existing] is provided
/// the modal edits that transaction in place instead of creating a new one.
Future<void> showFinanceTransactionModal(
  BuildContext context,
  WidgetRef ref, {
  FinancialTransaction? existing,
}) async {
  // Captured out here, not inside the sheet: the sheet builds its own
  // ProviderScope, and that container is disposed the moment the sheet is
  // dismissed — which can happen while a save is still in flight, when the
  // invalidate still has to land or the ledger keeps showing pre-write data.
  final container = ProviderScope.containerOf(context, listen: false);
  await showVoyagerSheet<void>(
    context: context,
    builder: (ctx) => ProviderScope(
      parent: container,
      child: _TransactionModal(container: container, existing: existing),
    ),
  );
}

class _TransactionModal extends ConsumerStatefulWidget {
  const _TransactionModal({required this.container, this.existing});

  /// The app-level container, which outlives this sheet. See
  /// [showFinanceTransactionModal].
  final ProviderContainer container;

  final FinancialTransaction? existing;

  @override
  ConsumerState<_TransactionModal> createState() => _TransactionModalState();
}

class _TransactionModalState extends ConsumerState<_TransactionModal> {
  late TransactionType _type;
  late final TextEditingController _amountController;
  late final TextEditingController _noteController;
  late final TextEditingController _tagsController;
  late final FocusNode _noteFocusNode;
  var _lastNoteText = '';
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
    _type = existing?.type ?? TransactionType.expense;
    _amountController = TextEditingController(
      text: existing == null ? '' : (existing.amountCents / 100).toStringAsFixed(2),
    );
    _noteController = TextEditingController(text: existing?.note ?? '');
    _lastNoteText = _noteController.text;
    _noteFocusNode = FocusNode();
    _noteFocusNode.onKeyEvent = (node, event) {
      if (event is! KeyDownEvent) return KeyEventResult.ignored;
      if (event.logicalKey == LogicalKeyboardKey.tab) {
        final outdent = HardwareKeyboard.instance.isShiftPressed;
        if (handleListTab(controller: _noteController, outdent: outdent)) {
          // Keep _lastNoteText in sync for the next keystroke's diff.
          _handleNoteChanged(_noteController.text);
          return KeyEventResult.handled;
        }
      }
      if (event.logicalKey == LogicalKeyboardKey.backspace) {
        if (handleListBackspace(controller: _noteController)) {
          _handleNoteChanged(_noteController.text);
          return KeyEventResult.handled;
        }
      }
      return KeyEventResult.ignored;
    };
    _tagsController = TextEditingController(
      text: existing == null
          ? ''
          : existing.tags.map((t) => '#$t').join(' '),
    );
    final base = existing?.occurredAt ?? DateTime.now();
    _date = DateTime(base.year, base.month, base.day);
    _amountController.addListener(_onAmountChanged);
  }

  @override
  void dispose() {
    _amountController.dispose();
    _noteController.dispose();
    _noteFocusNode.dispose();
    _tagsController.dispose();
    super.dispose();
  }

  void _onAmountChanged() => setState(() {});

  void _handleNoteChanged(String value) {
    applyListEditing(controller: _noteController, previousText: _lastNoteText);
    _lastNoteText = _noteController.text;
  }

  int? get _parsedCents => parseAmountCents(_amountController.text);

  /// Why Save is unavailable, for the amount field to show. Null while the
  /// field is empty: an untouched field isn't an error yet.
  String? get _amountError {
    if (_amountController.text.trim().isEmpty) return null;
    return _parsedCents == null ? r'Enter an amount over $0.00' : null;
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

    final transaction = FinancialTransaction(
      id: existing?.id ?? newId(),
      createdAt: existing?.createdAt ?? now,
      updatedAt: now,
      version: existing == null ? 0 : existing.version + 1,
      type: _type,
      amountCents: cents,
      occurredAt: occurredAt,
      note: _noteController.text.trim().isEmpty
          ? null
          : _noteController.text.trim(),
      tags: tags,
    );

    final financeRepo = ref.read(financeRepositoryProvider);
    // Both reads happen before the first await: `ref` throws once this sheet
    // is disposed, and it can be dismissed while the write is in flight.
    final settingsRepo = ref.read(settingsRepositoryProvider);
    final container = widget.container;
    try {
      await financeRepo.upsertTransaction(transaction);
      await _persistTagColors(settingsRepo, tags);

      // Through the container, not `ref`: the invalidate has to land even
      // when the sheet was dismissed mid-write, or the ledger keeps showing
      // pre-write data until something else refreshes it.
      container.invalidate(transactionsProvider);
      container.invalidate(tagColorsProvider);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _saveError = 'Could not save: $e';
      });
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
    final canSave = _parsedCents != null && !_saving;
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
              // Handle
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
              // Header row
              Row(
                children: [
                  Text(
                    widget.existing == null
                        ? 'New transaction'
                        : 'Edit transaction',
                    style: theme.textTheme.titleMedium,
                  ),
                  const Spacer(),
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
                onSelectionChanged: (set) {
                  if (set.isNotEmpty) setState(() => _type = set.first);
                },
              ),
              const SizedBox(height: 16),
              // Amount
              VoyagerTextField(
                controller: _amountController,
                autofocus: widget.existing == null,
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
                onSubmitted: (_) => _save(),
              ),
              const SizedBox(height: 16),
              // Tags
              VoyagerTextField(
                controller: _tagsController,
                accentColor: accent,
                tagScope: TagScope.finance,
                decoration: const InputDecoration(
                  labelText: 'Tags',
                  hintText: '#groceries #travel',
                ),
              ),
              const SizedBox(height: 16),
              // Note
              VoyagerTextField(
                controller: _noteController,
                focusNode: _noteFocusNode,
                accentColor: accent,
                maxLines: 2,
                onChanged: _handleNoteChanged,
                decoration: const InputDecoration(
                  labelText: 'Note',
                  hintText: 'Dinner with friends',
                ),
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
                onPressed: canSave ? _save : null,
                label: widget.existing == null ? 'Add' : 'Save',
                color: amountColor,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatDate(DateTime d) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    if (d == today) return 'Today';
    if (d == today.subtract(const Duration(days: 1))) return 'Yesterday';
    return DateFormat('MMM d, yyyy').format(d);
  }
}
