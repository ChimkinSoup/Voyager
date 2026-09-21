import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/core/utils/journal_tags.dart';
import 'package:voyager/core/widgets/ctrl_enter_to_submit_scope.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/features/finance/finance_soft_delete.dart';
import 'package:voyager/core/widgets/glass_surface.dart';
import 'package:voyager/core/widgets/voyager_text_field.dart';
import 'package:voyager/domain/models/finance_models.dart';
import 'package:voyager/core/layout/touch_target.dart';
import 'package:voyager/core/tags/tag_suggestions.dart';
import 'package:voyager/core/widgets/voyager_scroll_view.dart';

/// Opens the add / edit tag-budget modal.
Future<void> showBudgetModal(
  BuildContext context,
  WidgetRef ref, {
  Budget? existing,
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
      child: _BudgetModal(container: container, existing: existing),
    ),
  );
}

class _BudgetModal extends ConsumerStatefulWidget {
  const _BudgetModal({required this.container, this.existing});

  /// The app-level container, which outlives this sheet. See
  /// [showBudgetModal].
  final ProviderContainer container;

  final Budget? existing;

  @override
  ConsumerState<_BudgetModal> createState() => _BudgetModalState();
}

class _BudgetModalState extends ConsumerState<_BudgetModal> {
  late final TextEditingController _tagController;
  late final TextEditingController _limitController;
  final _limitFocusNode = FocusNode();
  bool _saving = false;

  /// Set when a write throws, so the sheet says what went wrong instead of
  /// silently sitting there with Save disabled forever.
  String? _saveError;

  @override
  void initState() {
    super.initState();
    _tagController = TextEditingController(text: widget.existing?.tag ?? '');
    _limitController = TextEditingController(
      text: widget.existing == null
          ? ''
          : (widget.existing!.limitCents / 100).toStringAsFixed(2),
    );
  }

  @override
  void dispose() {
    _tagController.dispose();
    _limitController.dispose();
    _limitFocusNode.dispose();
    super.dispose();
  }

  String get _tag => _tagController.text.replaceAll('#', '').trim();

  int? get _parsedLimit => parseAmountCents(_limitController.text);

  /// Why Save is unavailable, for the limit field to show. Null while the
  /// field is empty: an untouched field isn't an error yet. A zero limit is
  /// rejected rather than saved, because budgetStatus reads one as "on track"
  /// unconditionally — a budget that can never be exceeded.
  String? get _limitError {
    if (_limitController.text.trim().isEmpty) return null;
    if (_parsedLimit != null) return null;
    return amountOverMaxError(_limitController.text) ??
        r'Enter a limit over $0.00';
  }

  bool get _canSave => _tag.isNotEmpty && _parsedLimit != null && !_saving;

  Future<void> _save() async {
    final limit = _parsedLimit;
    if (limit == null || !_canSave) return;
    setState(() {
      _saving = true;
      _saveError = null;
    });

    final now = utcNow();
    // Both reads happen before the first await: `ref` throws once this sheet
    // is disposed, and it can be dismissed while the write is in flight.
    final repo = ref.read(financeRepositoryProvider);
    final settingsRepo = ref.read(settingsRepositoryProvider);
    final container = widget.container;
    final tag = _tag;

    try {
      // Reuse an existing budget for the same tag rather than creating a
      // duplicate that would double-count the same spending.
      final budgets = await repo.listBudgets();
      final match = budgets.cast<Budget?>().firstWhere(
        (b) => b != null && b.tag.toLowerCase() == tag.toLowerCase(),
        orElse: () => null,
      );
      final target = widget.existing ?? match;

      await repo.upsertBudget(
        Budget(
          id: target?.id ?? newId(),
          createdAt: target?.createdAt ?? now,
          updatedAt: now,
          version: target == null ? 0 : target.version + 1,
          tag: tag,
          limitCents: limit,
        ),
      );

      // Give a brand-new tag a stable color so its chip matches elsewhere.
      final colors = await settingsRepo.getTagColors();
      if (!colors.containsKey(tag)) {
        await settingsRepo.setTagColor(tag, colorForTag(tag));
        container.invalidate(tagColorsProvider);
      }

      // Through the container, not `ref`: the invalidate has to land even
      // when the sheet was dismissed mid-write.
      container.invalidate(budgetsProvider);
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
    // to outlive the sheet that raised it. Shares one path with the panel's
    // right-click Delete so both offer the same undo.
    final overlay = Overlay.of(context, rootOverlay: true);
    final deleted = await deleteBudgetWithUndo(
      overlay: overlay,
      container: widget.container,
      repo: ref.read(financeRepositoryProvider),
      budget: existing,
    );
    if (!mounted) return;
    if (!deleted) {
      // The helper has already said so in its own toast.
      setState(() => _saving = false);
      return;
    }
    Navigator.of(context).pop();
  }

  /// Tags worth suggesting: everything already used on a live transaction,
  /// most-used first. Narrowed to what's been typed so far where the chip row
  /// is drawn, so it completes like the `#` popup does elsewhere.
  ///
  /// Live transactions only — see `_CategoryModalState._knownTags` for why a
  /// stored tag color is not evidence the tag still exists. A brand-new tag
  /// is still reachable by typing it.
  ///
  /// Ranked here and narrowed where it is drawn: `ref.watch` belongs to this
  /// widget's own build, not to the chip row's builder below, which reruns on
  /// its own as the tag is typed.
  List<String> _usedTags() {
    final transactions =
        ref.watch(transactionsProvider).valueOrNull ?? const [];
    return rankTagsByUsage(transactions.map((t) => t.tags));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    final usedTags = widget.existing == null ? _usedTags() : const <String>[];
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
                    widget.existing == null ? 'New budget' : 'Edit budget',
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
                controller: _tagController,
                autofocus: widget.existing == null,
                accentColor: accent,
                enabled: widget.existing == null,
                decoration: const InputDecoration(
                  labelText: 'Tag',
                  hintText: 'dining_out',
                ),
                onSubmitted: (_) => _limitFocusNode.requestFocus(),
              ),
              // Each piece below watches only the field it reads. A
              // `setState` listener on the controllers rebuilt the whole sheet
              // per keystroke, which also made its heavy GlassSurface re-blur
              // a window-sized backdrop for every character.
              if (widget.existing == null)
                ListenableBuilder(
                  listenable: _tagController,
                  builder: (context, _) {
                    final suggestions = filterTagSuggestions(
                      usedTags,
                      _tag,
                      limit: 12,
                    );
                    if (suggestions.isEmpty) return const SizedBox.shrink();
                    return Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final tag in suggestions)
                            ActionChip(
                              label: Text(
                                '#$tag',
                                style: const TextStyle(fontSize: 12),
                              ),
                              visualDensity: VisualDensity.compact,
                              onPressed: () {
                                _tagController.text = tag;
                                _tagController.selection =
                                    TextSelection.collapsed(offset: tag.length);
                              },
                            ),
                        ],
                      ),
                    );
                  },
                ),
              const SizedBox(height: 16),
              ListenableBuilder(
                listenable: _limitController,
                builder: (context, _) => VoyagerTextField(
                  controller: _limitController,
                  focusNode: _limitFocusNode,
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
                    labelText: 'Monthly limit',
                    prefixText: r'$ ',
                    errorText: _limitError,
                  ),
                  onSubmitted: (_) => _save(),
                ),
              ),
              ListenableBuilder(
                listenable: Listenable.merge([
                  _tagController,
                  _limitController,
                ]),
                builder: (context, _) {
                  final limit = _parsedLimit;
                  if (limit == null || _tag.isEmpty) {
                    return const SizedBox.shrink();
                  }
                  return Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      'Keep #$_tag under ${formatCents(limit)} this month.',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  );
                },
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
                  _tagController,
                  _limitController,
                ]),
                builder: (context, _) => GlassButton(
                  onPressed: _canSave ? _save : null,
                  label: widget.existing == null ? 'Add' : 'Save',
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
