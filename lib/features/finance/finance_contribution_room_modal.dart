import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/layout/touch_target.dart';
import 'package:voyager/core/theme/palette_color.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/core/widgets/ctrl_enter_to_submit_scope.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/glass_surface.dart';
import 'package:voyager/core/widgets/voyager_scroll_view.dart';
import 'package:voyager/core/widgets/voyager_text_field.dart';
import 'package:voyager/domain/models/contribution_room_models.dart';
import 'package:voyager/domain/models/finance_models.dart';
import 'package:voyager/domain/repositories/repositories.dart';

/// Opens the contribution-room sheet for [asset]: create or join a room when
/// the asset has none, otherwise edit its room or leave it.
Future<void> showContributionRoomModal(
  BuildContext context,
  WidgetRef ref, {
  required Asset asset,
}) async {
  // Captured out here, not inside the sheet: see showAssetModal.
  final container = ProviderScope.containerOf(context, listen: false);
  await showVoyagerSheet<void>(
    context: context,
    builder: (ctx) => ProviderScope(
      parent: container,
      child: _ContributionRoomModal(container: container, asset: asset),
    ),
  );
}

/// Points [assetId] at [roomId], or detaches it when [roomId] is null.
///
/// Re-reads the asset first: the caller's copy can predate a rename saved
/// from the asset sheet, and writing it back would undo that.
Future<void> setAssetContributionRoom(
  FinanceRepository repo,
  String assetId,
  String? roomId,
) async {
  final asset = (await repo.listAssets())
      .where((a) => a.id == assetId)
      .firstOrNull;
  if (asset == null || asset.contributionRoomId == roomId) return;
  await repo.upsertAsset(
    asset.copyWith(
      contributionRoomId: roomId,
      clearContributionRoomId: roomId == null,
      updatedAt: utcNow(),
      version: asset.version + 1,
    ),
  );
}

enum _Mode { create, join }

class _ContributionRoomModal extends ConsumerStatefulWidget {
  const _ContributionRoomModal({required this.container, required this.asset});

  final ProviderContainer container;
  final Asset asset;

  @override
  ConsumerState<_ContributionRoomModal> createState() =>
      _ContributionRoomModalState();
}

class _ContributionRoomModalState
    extends ConsumerState<_ContributionRoomModal> {
  final _nameController = TextEditingController();
  final _limitController = TextEditingController();
  final _remainingController = TextEditingController();
  final _limitFocusNode = FocusNode();
  final _remainingFocusNode = FocusNode();
  _Mode _mode = _Mode.create;
  String? _joinRoomId;
  bool _saving = false;
  String? _saveError;

  /// The room being edited, and the figures its fields were seeded with —
  /// an edit only rewrites a limit or the baseline the user actually changed.
  ContributionRoom? _seededRoom;
  int? _seededLimit;
  int? _seededRemaining;

  /// Minted once, so a retried create doesn't make a second room.
  final _newRoomId = newId();

  @override
  void initState() {
    super.initState();
    _nameController.addListener(_rebuild);
    _limitController.addListener(_rebuild);
    _remainingController.addListener(_rebuild);
  }

  @override
  void dispose() {
    _nameController.dispose();
    _limitController.dispose();
    _remainingController.dispose();
    _limitFocusNode.dispose();
    _remainingFocusNode.dispose();
    super.dispose();
  }

  void _rebuild() => setState(() {});

  int? get _limit {
    final cents = parseSignedAmountCents(_limitController.text);
    return cents == null || cents < 0 ? null : cents;
  }

  int? get _remaining => parseSignedAmountCents(_remainingController.text);

  bool get _editing => widget.asset.contributionRoomId != null;

  bool get _canSave {
    if (_saving) return false;
    if (!_editing && _mode == _Mode.join) return _joinRoomId != null;
    return _nameController.text.trim().isNotEmpty &&
        _limit != null &&
        _remaining != null;
  }

  void _seed(ContributionRoom room, List<AssetRoomEvent> events) {
    final now = DateTime.now();
    _seededRoom = room;
    _seededLimit = room.annualLimitFor(now.year);
    _seededRemaining = roomYearSummary(room, events, now: now).remainingCents;
    // Deferred a frame: the controllers' listeners call setState.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _nameController.text = room.name;
      _limitController.text = (_seededLimit! / 100).toStringAsFixed(2);
      _remainingController.text = (_seededRemaining! / 100).toStringAsFixed(2);
    });
  }

  Future<void> _run(Future<void> Function(FinanceRepository repo) write) async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _saveError = null;
    });
    final repo = ref.read(financeRepositoryProvider);
    final container = widget.container;
    try {
      await write(repo);
      container.invalidate(contributionRoomsProvider);
      container.invalidate(assetsProvider);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _saveError = 'Could not save: $e';
      });
    }
  }

  Future<void> _save() async {
    if (!_canSave) return;
    final now = DateTime.now();
    final assetId = widget.asset.id;

    if (!_editing && _mode == _Mode.join) {
      final roomId = _joinRoomId!;
      return _run((repo) => setAssetContributionRoom(repo, assetId, roomId));
    }

    final name = _nameController.text.trim();
    final limit = _limit!;
    final remaining = _remaining!;
    final seeded = _seededRoom;

    if (seeded == null) {
      return _run((repo) async {
        final stamp = utcNow();
        await repo.upsertContributionRoom(
          ContributionRoom(
            id: _newRoomId,
            createdAt: stamp,
            updatedAt: stamp,
            name: name,
            baselineRemainingCents: remaining,
            baselineAsOf: now,
            annualLimits: [AnnualLimit(fromYear: now.year, cents: limit)],
          ),
        );
        await setAssetContributionRoom(repo, assetId, _newRoomId);
      });
    }

    return _run((repo) async {
      final current =
          (await repo.listContributionRooms())
              .where((r) => r.id == seeded.id)
              .firstOrNull ??
          seeded;
      await repo.upsertContributionRoom(
        current.copyWith(
          name: name,
          // A changed limit applies from this year on; years that have
          // already rolled keep the limit they rolled with.
          annualLimits: limit == _seededLimit
              ? null
              : current.annualLimitsFrom(now.year, limit),
          // A changed remaining figure becomes the new starting point, as on
          // the day tracking began.
          baselineRemainingCents: remaining == _seededRemaining
              ? null
              : remaining,
          baselineAsOf: remaining == _seededRemaining ? null : now,
          updatedAt: utcNow(),
          version: current.version + 1,
        ),
      );
    });
  }

  Future<void> _detach() =>
      _run((repo) => setAssetContributionRoom(repo, widget.asset.id, null));

  Future<void> _deleteRoom() async {
    final room = _seededRoom;
    if (room == null) return;
    await _run((repo) => repo.softDeleteContributionRoom(room.id));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = paletteColor(widget.asset.colorValue, context);
    final viewInsets = MediaQuery.of(context).viewInsets.bottom;
    final rooms = ref.watch(contributionRoomsProvider).valueOrNull;
    final events = ref.watch(assetRoomEventsProvider).valueOrNull;
    final now = DateTime.now();

    if (_editing && _seededRoom == null && rooms != null && events != null) {
      final room = rooms
          .where((r) => r.id == widget.asset.contributionRoomId)
          .firstOrNull;
      if (room != null) _seed(room, events);
    }

    final showCreateFields = _editing || _mode == _Mode.create;

    final sheet = Padding(
      padding: EdgeInsets.only(bottom: viewInsets),
      child: VoyagerScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (voyagerSheetDrags(VoyagerSheetKind.sheet))
                const VoyagerSheetHandle(),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _editing ? 'Contribution room' : 'Track contribution room',
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  if (_editing && _seededRoom != null)
                    IconButton(
                      onPressed: _saving ? null : _deleteRoom,
                      icon: Icon(
                        PhosphorIconsRegular.trash,
                        size: 18,
                        color: theme.colorScheme.error,
                      ),
                      tooltip: 'Delete room',
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
              Text(
                'For accounts with a yearly contribution cap, like a TFSA. '
                'Room is shared by every asset in it.',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 16),
              if (!_editing) ...[
                SegmentedButton<_Mode>(
                  showSelectedIcon: false,
                  style: SegmentedButton.styleFrom(
                    selectedBackgroundColor: accent.withValues(alpha: 0.18),
                    selectedForegroundColor: accent,
                  ),
                  segments: [
                    const ButtonSegment(
                      value: _Mode.create,
                      label: Text('New room'),
                    ),
                    ButtonSegment(
                      value: _Mode.join,
                      label: const Text('Join existing'),
                      enabled: rooms != null && rooms.isNotEmpty,
                    ),
                  ],
                  selected: {_mode},
                  onSelectionChanged: (set) {
                    if (set.isNotEmpty) setState(() => _mode = set.first);
                  },
                ),
                const SizedBox(height: 16),
              ],
              if (showCreateFields) ...[
                VoyagerTextField(
                  controller: _nameController,
                  autofocus: !_editing,
                  accentColor: accent,
                  decoration: const InputDecoration(
                    labelText: 'Room name',
                    hintText: 'TFSA',
                  ),
                  onSubmitted: (_) => _limitFocusNode.requestFocus(),
                ),
                const SizedBox(height: 16),
                VoyagerTextField(
                  controller: _limitController,
                  focusNode: _limitFocusNode,
                  accentColor: accent,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                    LengthLimitingTextInputFormatter(12),
                  ],
                  decoration: InputDecoration(
                    labelText: _editing
                        ? 'Annual limit from ${now.year} on'
                        : 'Annual limit',
                    prefixText: r'$ ',
                    hintText: '7000.00',
                    helperText: 'Added every Jan 1',
                  ),
                  onSubmitted: (_) => _remainingFocusNode.requestFocus(),
                ),
                const SizedBox(height: 16),
                VoyagerTextField(
                  controller: _remainingController,
                  focusNode: _remainingFocusNode,
                  accentColor: accent,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                    signed: true,
                  ),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9.\-]')),
                    LengthLimitingTextInputFormatter(13),
                  ],
                  decoration: const InputDecoration(
                    labelText: 'Room remaining right now',
                    prefixText: r'$ ',
                    helperText:
                        'What your tax account shows today, carry-forward '
                        'included',
                  ),
                  onSubmitted: (_) => _save(),
                ),
              ] else ...[
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final room in rooms ?? const <ContributionRoom>[])
                      ChoiceChip(
                        label: Text(room.name),
                        selected: room.id == _joinRoomId,
                        selectedColor: accent.withValues(alpha: 0.18),
                        onSelected: (_) =>
                            setState(() => _joinRoomId = room.id),
                      ),
                  ],
                ),
              ],
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
                label: _editing ? 'Save' : 'Track',
                color: accent,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              if (_editing) ...[
                const SizedBox(height: 8),
                TextButton(
                  onPressed: _saving ? null : _detach,
                  child: Text('Remove ${widget.asset.name} from this room'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
    return CtrlEnterToSubmitScope(onSubmit: _save, child: sheet);
  }
}
