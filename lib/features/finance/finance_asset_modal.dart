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
import 'package:voyager/core/widgets/selector_pill.dart';
import 'package:voyager/core/widgets/voyager_text_field.dart';
import 'package:voyager/domain/models/finance_models.dart';
import 'package:voyager/domain/services/finance_analytics.dart';
import 'package:voyager/core/layout/touch_target.dart';

/// Opens the add / edit asset modal. Saving records a **new valuation** rather
/// than overwriting the old one, so the net-worth graph keeps its history.
Future<void> showAssetModal(
  BuildContext context,
  WidgetRef ref, {
  Asset? existing,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    useSafeArea: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) => ProviderScope(
      parent: ProviderScope.containerOf(context),
      child: _AssetModal(existing: existing),
    ),
  );
}

class _AssetModal extends ConsumerStatefulWidget {
  const _AssetModal({this.existing});

  final Asset? existing;

  @override
  ConsumerState<_AssetModal> createState() => _AssetModalState();
}

class _AssetModalState extends ConsumerState<_AssetModal> {
  late final TextEditingController _nameController;
  late final TextEditingController _valueController;
  late final TextEditingController _noteController;
  late DateTime _asOf;
  late int _colorValue;
  bool _datePopoverOpen = false;
  bool _saving = false;
  bool _seededValue = false;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _nameController = TextEditingController(text: existing?.name ?? '');
    _valueController = TextEditingController();
    _noteController = TextEditingController(text: existing?.note ?? '');
    final now = DateTime.now();
    _asOf = DateTime(now.year, now.month, now.day);
    _colorValue = existing?.colorValue ?? 0xFF7C9EFF;
    _nameController.addListener(() => setState(() {}));
    _valueController.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _nameController.dispose();
    _valueController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  /// Parses the value field. Unlike transactions, assets accept a leading `-`
  /// so a debt can be tracked as a negative holding.
  int? get _parsedCents {
    final raw = _valueController.text.trim();
    if (raw.isEmpty) return null;
    final negative = raw.startsWith('-');
    final cleaned = raw.replaceAll(RegExp(r'[^0-9.]'), '');
    if (cleaned.isEmpty) return null;
    final value = double.tryParse(cleaned);
    if (value == null) return null;
    final cents = (value * 100).round();
    return negative ? -cents : cents;
  }

  bool get _canSave =>
      _nameController.text.trim().isNotEmpty &&
      _parsedCents != null &&
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
        initialStartDate: _asOf,
        initialEndDate: _asOf,
        singleDateMode: true,
        accentColor: accent,
      ),
    );
    if (!mounted) return;
    setState(() {
      _datePopoverOpen = false;
      if (range != null) {
        _asOf = DateTime(range.start.year, range.start.month, range.start.day);
      }
    });
  }

  Future<void> _save() async {
    final cents = _parsedCents;
    if (cents == null || !_canSave) return;
    setState(() => _saving = true);

    final now = utcNow();
    final repo = ref.read(financeRepositoryProvider);
    final existing = widget.existing;
    final assetId = existing?.id ?? newId();

    await repo.upsertAsset(
      Asset(
        id: assetId,
        createdAt: existing?.createdAt ?? now,
        updatedAt: now,
        version: existing == null ? 0 : existing.version + 1,
        name: _nameController.text.trim(),
        colorValue: _colorValue,
        note: _noteController.text.trim().isEmpty
            ? null
            : _noteController.text.trim(),
      ),
    );

    // Re-valuing on a date that already has a valuation replaces that day's
    // entry; any other date appends a new point to the history.
    final valuations = await repo.listAssetValuations(assetId: assetId);
    final sameDay = valuations.cast<AssetValuation?>().firstWhere(
          (v) =>
              v != null &&
              v.asOf.year == _asOf.year &&
              v.asOf.month == _asOf.month &&
              v.asOf.day == _asOf.day,
          orElse: () => null,
        );

    await repo.upsertAssetValuation(
      AssetValuation(
        id: sameDay?.id ?? newId(),
        createdAt: sameDay?.createdAt ?? now,
        updatedAt: now,
        version: sameDay == null ? 0 : sameDay.version + 1,
        assetId: assetId,
        valueCents: cents,
        asOf: _asOf,
      ),
    );

    ref.invalidate(assetsProvider);
    ref.invalidate(assetValuationsProvider);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _delete() async {
    final existing = widget.existing;
    if (existing == null) return;
    await ref.read(financeRepositoryProvider).softDeleteAsset(existing.id);
    ref.invalidate(assetsProvider);
    ref.invalidate(assetValuationsProvider);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = Color(_colorValue);
    final existing = widget.existing;
    final viewInsets = MediaQuery.of(context).viewInsets.bottom;

    // Seed the value field with the asset's current worth the first time the
    // valuations load, so editing starts from the latest figure.
    final valuations = ref.watch(assetValuationsProvider).valueOrNull;
    if (!_seededValue && existing != null && valuations != null) {
      final latest = latestValuation(valuations, existing.id);
      if (latest != null) {
        _valueController.text = (latest.valueCents / 100).toStringAsFixed(2);
      }
      _seededValue = true;
    }

    return Padding(
      padding: EdgeInsets.only(bottom: viewInsets),
      child: SingleChildScrollView(
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
                    existing == null ? 'New asset' : 'Update asset',
                    style: theme.textTheme.titleMedium,
                  ),
                  const Spacer(),
                  if (existing != null)
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
                autofocus: existing == null,
                accentColor: accent,
                decoration: const InputDecoration(
                  labelText: 'Asset name',
                  hintText: 'Index fund',
                ),
              ),
              const SizedBox(height: 16),
              VoyagerTextField(
                controller: _valueController,
                accentColor: accent,
                cursorColor: accent,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                  signed: true,
                ),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9.\-]')),
                ],
                decoration: const InputDecoration(
                  labelText: 'Current value',
                  prefixText: r'$ ',
                  hintText: 'Use a minus sign for a debt',
                ),
              ),
              const SizedBox(height: 16),
              VoyagerTextField(
                controller: _noteController,
                accentColor: accent,
                decoration: const InputDecoration(
                  labelText: 'Note',
                  hintText: 'Brokerage account',
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Text(
                    'Valued as of',
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const Spacer(),
                  Builder(
                    builder: (buttonContext) => SelectorPill(
                      icon: PhosphorIconsRegular.calendar,
                      label: DateFormat('MMM d, yyyy').format(_asOf),
                      isActive: _datePopoverOpen,
                      accentColor: accent,
                      onTap: () => _pickDate(buttonContext),
                    ),
                  ),
                ],
              ),
              if (existing != null) ...[
                const SizedBox(height: 6),
                Text(
                  'Saving records a new valuation on this date, keeping past '
                  'values in the net-worth history.',
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
              const SizedBox(height: 24),
              GlassButton(
                onPressed: _canSave ? _save : null,
                label: existing == null ? 'Add' : 'Save',
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
