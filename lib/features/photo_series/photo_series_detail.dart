import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/core/soft_delete/soft_delete_toast.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/core/widgets/confirm_dialog.dart';
import 'package:voyager/core/widgets/context_menu.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/photo_series_models.dart';
import 'package:voyager/domain/photo_series/photo_series_periods.dart';
import 'package:voyager/features/notifications/secure_vault_session.dart';
import 'package:voyager/features/photo_series/photo_check_in_dialog.dart';
import 'package:voyager/features/photo_series/photo_series_dialogs.dart';
import 'package:voyager/features/photo_series/photo_series_page.dart';
import 'package:voyager/features/photo_series/photo_series_providers.dart';
import 'package:voyager/features/photo_series/photo_series_service.dart';
import 'package:voyager/features/photo_series/photo_series_viewer.dart';
import 'package:voyager/features/photo_series/vault_activity.dart';
import 'package:voyager/features/photo_series/vault_image_cache.dart';

/// "Week of Oct 13, 2026", "October 2026"…
String photoPeriodLabel(DateTime start, TrackerCadence cadence) =>
    switch (cadence) {
      TrackerCadence.daily => DateFormat.yMMMEd().format(start),
      TrackerCadence.weekly => 'Week of ${DateFormat.yMMMd().format(start)}',
      TrackerCadence.monthly => DateFormat.yMMMM().format(start),
      TrackerCadence.yearly => DateFormat.y().format(start),
    };

/// One series (PHOTO_SERIES_HLD.md §4): its stats, its period strip and its
/// check-ins as a grid, with the unlock card above while the vault is
/// locked.
class PhotoSeriesDetail extends ConsumerStatefulWidget {
  const PhotoSeriesDetail({super.key, required this.seriesId});

  final String seriesId;

  @override
  ConsumerState<PhotoSeriesDetail> createState() => _PhotoSeriesDetailState();
}

class _PhotoSeriesDetailState extends ConsumerState<PhotoSeriesDetail> {
  final _unlockFocus = FocusNode();

  /// Each period's group in the grid, for the strip to scroll to.
  final _periodKeys = <DateTime, GlobalKey>{};

  @override
  void dispose() {
    _unlockFocus.dispose();
    super.dispose();
  }

  /// Whether the vault is open; when it isn't, points the user at the
  /// unlock card (§4.1).
  bool _requireUnlocked() {
    if (ref.read(secureVaultSessionProvider) != null) return true;
    _unlockFocus.requestFocus();
    return false;
  }

  Future<void> _edit(PhotoSeries series, List<PhotoSeriesAngle> angles) async {
    final form = await showPhotoSeriesDialog(
      context,
      series: series,
      angles: angles,
    );
    if (form == null) return;
    final service = ref.read(photoSeriesServiceProvider);
    if (form.name != series.name || form.cadence != series.cadence) {
      await service.updateSeries(
        series.copyWith(name: form.name, cadence: form.cadence),
      );
    }
    await service.saveAngles(series, form.angles);
  }

  Future<void> _delete(PhotoSeries series) async {
    final confirmed = await showConfirmDialog(
      context,
      title: 'Delete series',
      message:
          '"${series.name}" and all its check-ins go to the trash, where '
          'they are kept for 30 days.',
    );
    if (!confirmed || !mounted) return;
    await ref.read(photoSeriesServiceProvider).deleteSeries(series);
    if (mounted) Navigator.of(context).maybePop();
  }

  Future<void> _checkIn(
    PhotoSeries series,
    List<PhotoSeriesAngle> angles,
  ) async {
    if (!_requireUnlocked()) return;
    await showPhotoCheckInDialog(context, series: series, angles: angles);
  }

  void _scrollToPeriod(DateTime period) {
    final target = _periodKeys[period]?.currentContext;
    if (target == null) return;
    Scrollable.ensureVisible(
      target,
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = ref.watch(photoSeriesSnapshotProvider).valueOrNull;
    final series = snapshot?.series
        .where((s) => s.id == widget.seriesId)
        .firstOrNull;
    if (snapshot == null || series == null) {
      return Scaffold(
        appBar: AppBar(),
        body: Center(
          child: snapshot == null
              ? const CircularProgressIndicator()
              : const Text('This series was deleted.'),
        ),
      );
    }
    final unlocked = ref.watch(
      secureVaultSessionProvider.select((s) => s != null),
    );
    final angles = [
      for (final angle in snapshot.angles)
        if (angle.seriesId == series.id) angle,
    ];
    final stats = photoSeriesStats(
      series: series,
      checkIns: snapshot.checkIns,
      images: snapshot.images,
      now: ref.watch(photoSeriesTodayProvider),
    );
    final groups = _groups(series, snapshot, angles);
    final theme = Theme.of(context);

    return VaultActivity(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          scrolledUnderElevation: 0,
          title: Text(series.name),
          actions: [
            GlassButton(
              // Not disabled while locked: pressing it points at the
              // unlock card instead.
              onPressed: () => _checkIn(series, angles),
              icon: const Icon(PhosphorIconsRegular.camera, size: 13),
              label: 'Check in',
              dense: true,
            ),
            const SizedBox(width: 8),
            const PhotoVaultLockButton(),
            PopupMenuButton<String>(
              tooltip: 'More',
              icon: const Icon(PhosphorIconsRegular.dotsThreeVertical),
              onSelected: (choice) => switch (choice) {
                'edit' => _edit(series, angles),
                _ => _delete(series),
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'edit', child: Text('Edit series')),
                PopupMenuItem(value: 'delete', child: Text('Delete series')),
              ],
            ),
            const SizedBox(width: 8),
          ],
        ),
        body: CustomScrollView(
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(24, 4, 24, 0),
              sliver: SliverList.list(
                children: [
                  _StatsRow(series: series, stats: stats),
                  const SizedBox(height: 14),
                  PhotoPeriodStrip(
                    stats: stats,
                    cadence: series.cadence,
                    onTap: _scrollToPeriod,
                  ),
                  const SizedBox(height: 16),
                  if (!unlocked) ...[
                    PhotoVaultUnlockCard(focusNode: _unlockFocus),
                    const SizedBox(height: 16),
                  ],
                  if (groups.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 32),
                      child: Center(
                        child: Text(
                          'No check-ins yet.',
                          style: theme.textTheme.bodyMedium,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            for (final group in groups)
              SliverPadding(
                key: _periodKeys.putIfAbsent(group.period, GlobalKey.new),
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
                sliver: SliverList.list(
                  children: [
                    Text(
                      photoPeriodLabel(group.period, series.cadence),
                      style: theme.textTheme.labelLarge,
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        for (final entry in group.entries)
                          _CheckInTile(
                            series: series,
                            angles: angles,
                            entry: entry,
                            onOpen: () => _openViewer(groups, entry, angles),
                            requireUnlocked: _requireUnlocked,
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            const SliverToBoxAdapter(child: SizedBox(height: 24)),
          ],
        ),
      ),
    );
  }

  void _openViewer(
    List<_PeriodGroup> groups,
    PhotoViewerEntry entry,
    List<PhotoSeriesAngle> angles,
  ) {
    // Oldest first, so right is later.
    final entries = [
      for (final group in groups.reversed) ...group.entries.reversed,
    ];
    showPhotoSeriesViewer(
      context,
      entries: entries,
      angles: angles,
      initialIndex: entries.indexWhere((e) => e.checkIn.id == entry.checkIn.id),
    );
  }
}

class _PeriodGroup {
  _PeriodGroup(this.period);

  final DateTime period;
  final entries = <PhotoViewerEntry>[];
}

/// [series]' check-ins with a photo, newest first, grouped by period.
List<_PeriodGroup> _groups(
  PhotoSeries series,
  PhotoSeriesSnapshot snapshot,
  List<PhotoSeriesAngle> angles,
) {
  final angleIds = {for (final angle in angles) angle.id};
  final imagesByCheckIn = <String, Map<String, PhotoCheckInImage>>{};
  for (final image in snapshot.images) {
    if (!angleIds.contains(image.angleId)) continue;
    (imagesByCheckIn[image.checkInId] ??= {})[image.angleId] = image;
  }
  final checkIns =
      [
        for (final checkIn in snapshot.checkIns)
          if (checkIn.seriesId == series.id &&
              imagesByCheckIn.containsKey(checkIn.id))
            checkIn,
      ]..sort((a, b) {
        final byDate = b.takenOn.compareTo(a.takenOn);
        return byDate != 0 ? byDate : b.createdAt.compareTo(a.createdAt);
      });
  final groups = <_PeriodGroup>[];
  for (final checkIn in checkIns) {
    final period = photoPeriodStart(checkIn.takenOn, series.cadence);
    if (groups.isEmpty || groups.last.period != period) {
      groups.add(_PeriodGroup(period));
    }
    groups.last.entries.add((
      checkIn: checkIn,
      images: imagesByCheckIn[checkIn.id]!,
    ));
  }
  return groups;
}

class _StatsRow extends StatelessWidget {
  const _StatsRow({required this.series, required this.stats});

  final PhotoSeries series;
  final PhotoSeriesStats stats;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final date = DateFormat.yMMMd();
    Widget stat(String value, String label) => Padding(
      padding: const EdgeInsets.only(right: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(value, style: theme.textTheme.titleLarge),
          Text(label, style: theme.textTheme.bodySmall),
        ],
      ),
    );
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      runSpacing: 8,
      children: [
        stat(photoCadenceLabel(series.cadence), 'cadence'),
        stat('${stats.checkIns}', 'check-ins'),
        stat('${stats.photos}', 'photos'),
        stat('${stats.currentStreak}', 'current streak'),
        stat('${stats.bestStreak}', 'best streak'),
        stat('${stats.missed}', 'missed'),
        if (stats.first case final first?)
          stat(
            first == stats.latest
                ? date.format(first)
                : '${date.format(first)} – ${date.format(stats.latest!)}',
            'first – latest',
          ),
        PhotoPeriodBadge(done: stats.currentDone),
      ],
    );
  }
}

/// One mark per period from the first to now (§8): filled when done, hollow
/// in the error tint when missed, ringed in the accent for the current one.
class PhotoPeriodStrip extends StatelessWidget {
  const PhotoPeriodStrip({
    super.key,
    required this.stats,
    required this.cadence,
    required this.onTap,
  });

  final PhotoSeriesStats stats;
  final TrackerCadence cadence;
  final ValueChanged<DateTime> onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 22,
      // Reversed, so the current period is in view however many there are.
      child: LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          reverse: true,
          // At least as wide as the strip, so a few marks start at the left.
          child: ConstrainedBox(
            constraints: BoxConstraints(minWidth: constraints.maxWidth),
            child: Row(
              children: [
                for (final (i, period) in stats.periods.indexed)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Tooltip(
                      message:
                          '${photoPeriodLabel(period, cadence)} · '
                          '${switch (stats.states[i]) {
                            PhotoPeriodState.done => 'done',
                            PhotoPeriodState.missed => 'missed',
                            PhotoPeriodState.due => 'due',
                          }}',
                      child: InkWell(
                        onTap: stats.states[i] == PhotoPeriodState.done
                            ? () => onTap(period)
                            : null,
                        customBorder: const CircleBorder(),
                        child: _PeriodMark(
                          state: stats.states[i],
                          current: i == stats.periods.length - 1,
                          scheme: scheme,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PeriodMark extends StatelessWidget {
  const _PeriodMark({
    required this.state,
    required this.current,
    required this.scheme,
  });

  final PhotoPeriodState state;
  final bool current;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    final mark = Container(
      width: 12,
      height: 12,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: state == PhotoPeriodState.done ? scheme.primary : null,
        border: state == PhotoPeriodState.done
            ? null
            : Border.all(
                color: state == PhotoPeriodState.missed
                    ? scheme.error.withValues(alpha: 0.7)
                    : scheme.onSurface.withValues(alpha: 0.4),
                width: 1.5,
              ),
      ),
    );
    if (!current) return Padding(padding: const EdgeInsets.all(3), child: mark);
    return Container(
      padding: const EdgeInsets.all(1.5),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: scheme.tertiary, width: 1.5),
      ),
      child: mark,
    );
  }
}

class _CheckInTile extends ConsumerStatefulWidget {
  const _CheckInTile({
    required this.series,
    required this.angles,
    required this.entry,
    required this.onOpen,
    required this.requireUnlocked,
  });

  final PhotoSeries series;
  final List<PhotoSeriesAngle> angles;
  final PhotoViewerEntry entry;
  final VoidCallback onOpen;
  final bool Function() requireUnlocked;

  @override
  ConsumerState<_CheckInTile> createState() => _CheckInTileState();
}

class _CheckInTileState extends ConsumerState<_CheckInTile> {
  final _menu = GlobalKey<ContextMenuRegionState>();

  PhotoCheckIn get _checkIn => widget.entry.checkIn;

  /// First click reveals, the next opens the viewer (§7.1).
  void _tap() {
    if (!widget.requireUnlocked()) return;
    final revealed = ref.read(photoRevealedCheckInsProvider);
    if (!revealed.contains(_checkIn.id)) {
      ref.read(photoRevealedCheckInsProvider.notifier).state = {
        ...revealed,
        _checkIn.id,
      };
      return;
    }
    widget.onOpen();
  }

  Future<void> _editDate() async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final picked = await showDatePicker(
      context: context,
      // A camera clock ahead of ours can date a photo past today.
      initialDate: _checkIn.takenOn.isAfter(today) ? today : _checkIn.takenOn,
      firstDate: DateTime(1900),
      lastDate: today,
    );
    if (picked == null) return;
    await ref.read(photoSeriesServiceProvider).setDate(_checkIn, picked);
  }

  Future<void> _editNote() async {
    if (!widget.requireUnlocked()) return;
    final session = ref.read(secureVaultSessionProvider)!;
    final current = await PhotoSeriesService.openNote(session, _checkIn);
    if (!mounted) return;
    final text = await showPhotoNoteDialog(context, current ?? '');
    final now = ref.read(secureVaultSessionProvider);
    if (text == null || now == null) return;
    await ref.read(photoSeriesServiceProvider).setNote(now, _checkIn, text);
  }

  Future<void> _setPhoto(PhotoSeriesAngle angle) async {
    if (!widget.requireUnlocked()) return;
    await showPhotoCheckInDialog(
      context,
      series: widget.series,
      angles: [angle],
      checkIn: _checkIn,
    );
  }

  Future<void> _delete() async {
    final overlay = Overlay.of(context, rootOverlay: true);
    final container = ProviderScope.containerOf(context, listen: false);
    final service = ref.read(photoSeriesServiceProvider);
    final stamp = await service.deleteCheckIn(_checkIn);
    final id = _checkIn.id;
    showSoftDeleteUndoToast(
      overlay: overlay,
      message:
          'Deleted check-in from '
          '${DateFormat.yMMMd().format(_checkIn.takenOn)}',
      restore: () =>
          container.read(photoSeriesServiceProvider).restoreCheckIn(id, stamp),
    );
  }

  List<ContextMenuItem> _items() {
    final images = widget.entry.images;
    return [
      ContextMenuItem(
        label: 'Edit date',
        icon: PhosphorIconsRegular.calendarBlank,
        onTap: _editDate,
      ),
      ContextMenuItem(
        label: _checkIn.hasNote ? 'Edit note' : 'Add note',
        icon: PhosphorIconsRegular.note,
        onTap: _editNote,
      ),
      ContextMenuItem(
        label: 'Photo',
        icon: PhosphorIconsRegular.image,
        children: [
          for (final angle in widget.angles)
            ContextMenuItem(
              label: images.containsKey(angle.id)
                  ? 'Replace ${angle.name}'
                  : 'Add ${angle.name}',
              onTap: () => _setPhoto(angle),
            ),
        ],
      ),
      ContextMenuItem(
        label: 'Delete check-in',
        icon: PhosphorIconsRegular.trash,
        isDestructive: true,
        onTap: _delete,
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final unlocked = ref.watch(
      secureVaultSessionProvider.select((s) => s != null),
    );
    final revealed = ref.watch(
      photoRevealedCheckInsProvider.select((s) => s.contains(_checkIn.id)),
    );
    final images = widget.entry.images;
    final shown = widget.angles
        .where((angle) => images.containsKey(angle.id))
        .first;
    final photo = unlocked
        ? VaultPhoto(blobId: images[shown.id]!.blobId, thumb: true)
        : const _LockedPlaceholder();
    return ContextMenuRegion(
      key: _menu,
      itemsBuilder: _items,
      child: GestureDetector(
        onLongPressStart: (details) =>
            _menu.currentState?.openMenuAt(details.globalPosition),
        child: SizedBox(
          width: 150,
          child: InkWell(
            onTap: _tap,
            borderRadius: BorderRadius.circular(VoyagerTheme.fieldRadius),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(VoyagerTheme.fieldRadius),
                  child: AspectRatio(
                    aspectRatio: 3 / 4,
                    // Locked, the placeholder shows as it is: there's
                    // nothing under it to hide.
                    child: revealed || !unlocked
                        ? photo
                        : Stack(
                            fit: StackFit.expand,
                            children: [
                              ClipRect(
                                child: ImageFiltered(
                                  imageFilter: ui.ImageFilter.blur(
                                    sigmaX: 18,
                                    sigmaY: 18,
                                  ),
                                  child: photo,
                                ),
                              ),
                              if (unlocked)
                                Center(
                                  child: Icon(
                                    PhosphorIconsRegular.eye,
                                    color: Colors.white.withValues(alpha: 0.8),
                                  ),
                                ),
                            ],
                          ),
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        DateFormat.yMMMd().format(_checkIn.takenOn),
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                    if (_checkIn.hasNote)
                      Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: Icon(
                          PhosphorIconsRegular.note,
                          size: 12,
                          color: theme.colorScheme.onSurface.withValues(
                            alpha: 0.6,
                          ),
                        ),
                      ),
                    // Which angles this check-in has.
                    for (final angle in widget.angles)
                      Tooltip(
                        message: angle.name,
                        child: Container(
                          width: 6,
                          height: 6,
                          margin: const EdgeInsets.only(left: 3),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: images.containsKey(angle.id)
                                ? theme.colorScheme.primary
                                : theme.colorScheme.onSurface.withValues(
                                    alpha: 0.2,
                                  ),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _LockedPlaceholder extends StatelessWidget {
  const _LockedPlaceholder();

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    return ColoredBox(
      color: onSurface.withValues(alpha: 0.06),
      child: Icon(
        PhosphorIconsRegular.lockSimple,
        color: onSurface.withValues(alpha: 0.3),
      ),
    );
  }
}
