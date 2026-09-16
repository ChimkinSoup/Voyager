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
import 'package:voyager/domain/models/contribution_room_models.dart';
import 'package:voyager/domain/models/finance_models.dart';
import 'package:voyager/domain/services/finance_analytics.dart';
import 'package:voyager/features/finance/finance_contribution_room_modal.dart';
import 'package:voyager/features/finance/finance_room_bar.dart';
import 'package:voyager/features/finance/finance_room_history.dart';
import 'package:voyager/core/layout/touch_target.dart';
import 'package:voyager/core/widgets/voyager_scroll_view.dart';

/// Opens the add / edit asset modal. Saving records a **new valuation** rather
/// than overwriting the old one, so the net-worth graph keeps its history.
Future<void> showAssetModal(
  BuildContext context,
  WidgetRef ref, {
  Asset? existing,
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
      child: _AssetModal(container: container, existing: existing),
    ),
  );
}

class _AssetModal extends ConsumerStatefulWidget {
  const _AssetModal({required this.container, this.existing});

  /// The app-level container, which outlives this sheet. See [showAssetModal].
  final ProviderContainer container;

  final Asset? existing;

  @override
  ConsumerState<_AssetModal> createState() => _AssetModalState();
}

class _AssetModalState extends ConsumerState<_AssetModal> {
  late final TextEditingController _nameController;
  late final TextEditingController _valueController;
  late final TextEditingController _noteController;
  final _valueFocusNode = FocusNode();
  final _noteFocusNode = FocusNode();
  late DateTime _asOf;
  late int _colorValue;
  bool _datePopoverOpen = false;
  bool _saving = false;
  bool _seededValue = false;

  /// Set when a write throws, so the sheet says what went wrong instead of
  /// silently sitting there with Save disabled forever.
  String? _saveError;

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
  }

  @override
  void dispose() {
    _nameController.dispose();
    _valueController.dispose();
    _noteController.dispose();
    _valueFocusNode.dispose();
    _noteFocusNode.dispose();
    super.dispose();
  }

  /// Parses the value field. Unlike transactions, assets accept a leading `-`
  /// so a debt can be tracked as a negative holding.
  int? get _parsedCents => parseSignedAmountCents(_valueController.text);

  /// Why the value can't be used, for the field to show. Null while the field
  /// is empty — an empty value is allowed when editing (see [_canSave]).
  String? get _valueError {
    if (_valueController.text.trim().isEmpty) return null;
    return _parsedCents == null ? 'Enter a number, e.g. 1250.00' : null;
  }

  /// A valuation is only required for a brand-new asset. An existing one can
  /// have no valuation at all — its only one deleted, or a partial sync — and
  /// requiring a figure there would make renaming or recolouring it
  /// impossible without inventing a value.
  bool get _canSave =>
      _nameController.text.trim().isNotEmpty &&
      (widget.existing != null
          ? _valueError == null
          : _parsedCents != null) &&
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
    if (!_canSave) return;
    final cents = _parsedCents;
    setState(() {
      _saving = true;
      _saveError = null;
    });

    final now = utcNow();
    // Read before the first await: `ref` throws once this sheet is disposed.
    final repo = ref.read(financeRepositoryProvider);
    final container = widget.container;
    final existing = widget.existing;
    final assetId = existing?.id ?? newId();

    try {
      // Re-read rather than trusting [existing]: the room sheet can attach or
      // detach this asset while this sheet is open, and writing the stale copy
      // back would quietly undo that.
      final onDisk = existing == null
          ? null
          : (await repo.listAssets()).where((a) => a.id == assetId).firstOrNull;
      final base = onDisk ?? existing;
      await repo.upsertAsset(
        Asset(
          id: assetId,
          createdAt: base?.createdAt ?? now,
          updatedAt: now,
          version: base == null ? 0 : base.version + 1,
          name: _nameController.text.trim(),
          colorValue: _colorValue,
          note: _noteController.text.trim().isEmpty
              ? null
              : _noteController.text.trim(),
          contributionRoomId: base?.contributionRoomId,
        ),
      );

      // No figure typed: this was a rename/recolour of an existing asset, so
      // its valuation history is left exactly as it was.
      if (cents != null) {
        // Re-valuing on a date that already has a valuation replaces that
        // day's entry; any other date appends a new point to the history.
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
      }

      // Through the container, not `ref`: the invalidates have to land even
      // when the sheet was dismissed mid-write.
      container.invalidate(assetsProvider);
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

  Future<void> _delete() async {
    final existing = widget.existing;
    // _saving also guards the delete: the icon is only disabled by it, so two
    // taps inside the await window would otherwise write two tombstones and
    // burn two version numbers on one logical delete — and run the per-child
    // valuation tombstone loop twice.
    if (existing == null || _saving) return;
    setState(() {
      _saving = true;
      _saveError = null;
    });
    final repo = ref.read(financeRepositoryProvider);
    final container = widget.container;
    try {
      await repo.softDeleteAsset(existing.id);
      container.invalidate(assetsProvider);
      container.invalidate(assetValuationsProvider);
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
    final accent = paletteColor(_colorValue, context);
    final existing = widget.existing;
    final viewInsets = MediaQuery.of(context).viewInsets.bottom;

    // Seed the value field with the asset's current worth the first time the
    // valuations load, so editing starts from the latest figure.
    final valuations = ref.watch(assetValuationsProvider).valueOrNull;
    if (!_seededValue && existing != null && valuations != null) {
      _seededValue = true;
      final latest = latestValuation(valuations, existing.id);
      if (latest != null) {
        // Deferred a frame: setting .text here synchronously would fire the
        // controller's listener (which calls setState) while this build is
        // still in progress.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _valueController.text = (latest.valueCents / 100).toStringAsFixed(2);
        });
      }
    }

    final sheet = Padding(
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
                onSubmitted: (_) => _valueFocusNode.requestFocus(),
              ),
              const SizedBox(height: 16),
              // Only the parts that read the typed text rebuild as it is
              // typed. A `setState` listener on the controllers rebuilt the
              // whole sheet instead — ~570 widgets per character, each of
              // which also made the sheet's heavy GlassSurface re-blur a
              // window-sized backdrop.
              ListenableBuilder(
                listenable: _valueController,
                builder: (context, _) => VoyagerTextField(
                  controller: _valueController,
                  focusNode: _valueFocusNode,
                  accentColor: accent,
                  cursorColor: accent,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                    signed: true,
                  ),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9.\-]')),
                    // Bounded so a long paste can't reach the range where
                    // double.parse returns Infinity.
                    LengthLimitingTextInputFormatter(13),
                  ],
                  decoration: InputDecoration(
                    labelText: 'Current value',
                    prefixText: r'$ ',
                    hintText: 'Use a minus sign for a debt',
                    errorText: _valueError,
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
                  hintText: 'Brokerage account',
                ),
                onSubmitted: (_) => _save(),
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
              // Only true when there is a figure to record — an existing
              // asset can now be saved with the value field left empty, which
              // touches no valuation at all.
              if (existing != null)
                ListenableBuilder(
                  listenable: _valueController,
                  builder: (context, _) => _parsedCents == null
                      ? const SizedBox.shrink()
                      : Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(
                            'Saving records a new valuation on this date, '
                            'keeping past values in the net-worth history.',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                ),
              if (existing != null) ...[
                const SizedBox(height: 20),
                _RoomSection(assetId: existing.id, container: widget.container),
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
                  _valueController,
                ]),
                builder: (context, _) => GlassButton(
                  onPressed: _canSave ? _save : null,
                  label: existing == null ? 'Add' : 'Save',
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

/// The asset's contribution room: its shared bar and this year's history, or
/// a way to start tracking one.
///
/// Reads the asset live by id: tracking or leaving a room from the sheet
/// stacked above this one has to show up here without reopening.
class _RoomSection extends ConsumerWidget {
  const _RoomSection({required this.assetId, required this.container});

  final String assetId;
  final ProviderContainer container;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final asset = (ref.watch(assetsProvider).valueOrNull ?? const <Asset>[])
        .where((a) => a.id == assetId)
        .firstOrNull;
    if (asset == null) return const SizedBox.shrink();
    final rooms = ref.watch(contributionRoomsProvider).valueOrNull ?? const [];
    final events = ref.watch(assetRoomEventsProvider).valueOrNull ?? const [];
    final room = rooms
        .where((r) => r.id == asset.contributionRoomId)
        .firstOrNull;
    final labelStyle = theme.textTheme.labelLarge?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    if (room == null) {
      return Row(
        children: [
          Text('Contribution room', style: labelStyle),
          const Spacer(),
          TextButton(
            onPressed: () => showContributionRoomModal(context, ref, asset: asset),
            child: const Text('Track…'),
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Contribution room · ${room.name}',
                style: labelStyle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            TextButton(
              onPressed: () =>
                  showContributionRoomModal(context, ref, asset: asset),
              child: const Text('Edit room'),
            ),
          ],
        ),
        ContributionRoomBar(
          summary: roomYearSummary(room, events, now: DateTime.now()),
          color: paletteColor(asset.colorValue, context),
        ),
        const SizedBox(height: 8),
        RoomEventHistory(asset: asset, container: container),
      ],
    );
  }
}
