import 'dart:math' as math;
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
import 'package:voyager/features/photo_series/photo_align_editor.dart';
import 'package:voyager/features/photo_series/photo_check_in_dialog.dart';
import 'package:voyager/features/photo_series/photo_series_compare.dart';
import 'package:voyager/features/photo_series/photo_series_dialogs.dart';
import 'package:voyager/features/photo_series/photo_series_page.dart';
import 'package:voyager/features/photo_series/photo_series_playback.dart';
import 'package:voyager/features/photo_series/photo_series_providers.dart';
import 'package:voyager/features/photo_series/photo_series_service.dart';
import 'package:voyager/features/photo_series/photo_series_viewer.dart';
import 'package:voyager/features/photo_series/vault_activity.dart';
import 'package:voyager/features/photo_series/vault_image_cache.dart';
import 'package:voyager/features/shell/reveal_request.dart';

/// "Week of Oct 13, 2026", "October 2026"…
String photoPeriodLabel(DateTime start, TrackerCadence cadence) =>
    switch (cadence) {
      TrackerCadence.daily => DateFormat.yMMMEd().format(start),
      TrackerCadence.weekly => 'Week of ${DateFormat.yMMMd().format(start)}',
      TrackerCadence.monthly => DateFormat.yMMMM().format(start),
      TrackerCadence.yearly => DateFormat.y().format(start),
    };

/// The grid's group [day] falls in: its month, or its year for a monthly
/// series. A group per period held one check-in, so the grid read as one
/// tile per row (§7.1) — and a year holds one of a yearly series, so it is
/// all one group.
DateTime _gridGroupStart(DateTime day, TrackerCadence cadence) =>
    switch (cadence) {
      TrackerCadence.daily ||
      TrackerCadence.weekly => DateTime(day.year, day.month),
      TrackerCadence.monthly => DateTime(day.year),
      TrackerCadence.yearly => DateTime(0),
    };

/// "October 2026", or "2026": a [_gridGroupStart]'s label. None for a
/// yearly series' one group: each tile's date says its year.
String? _gridGroupLabel(DateTime start, TrackerCadence cadence) =>
    switch (cadence) {
      TrackerCadence.daily ||
      TrackerCadence.weekly => DateFormat.yMMMM().format(start),
      TrackerCadence.monthly => DateFormat.y().format(start),
      TrackerCadence.yearly => null,
    };

enum _PhotoSeriesView { grid, playback, compare }

/// One series (PHOTO_SERIES_HLD.md §4): its stats, its period strip and its
/// check-ins as a grid, played back or compared, with the unlock card above
/// the grid while the vault is locked.
class PhotoSeriesDetail extends ConsumerStatefulWidget {
  const PhotoSeriesDetail({super.key, required this.seriesId});

  final String seriesId;

  @override
  ConsumerState<PhotoSeriesDetail> createState() => _PhotoSeriesDetailState();
}

class _PhotoSeriesDetailState extends ConsumerState<PhotoSeriesDetail> {
  final _unlockFocus = FocusNode();

  /// Each group in the grid, and each check-in's tile, for the strip to
  /// scroll to.
  final _groupKeys = <DateTime, GlobalKey>{};
  final _tileKeys = <String, GlobalKey>{};

  /// Playback and Compare need the vault; locking drops back to the grid.
  var _view = _PhotoSeriesView.grid;

  /// The strip's latest tap: an older one's scroll stops where a newer
  /// one starts, rather than pulling the grid back to its own period.
  var _scrollTurn = 0;

  /// Starts the check-in a notification tap asked for (§13.1) — unless the
  /// vault is locked, when the detail is as far as it goes.
  void _takeCheckInRequest(PhotoSeries series, List<PhotoSeriesAngle> angles) {
    if (!mounted || ref.read(photoSeriesCheckInRequestProvider) != series.id) {
      return;
    }
    ref.read(photoSeriesCheckInRequestProvider.notifier).state = null;
    if (ref.read(secureVaultSessionProvider) != null) _checkIn(series, angles);
  }

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
    if (form.name != series.name ||
        form.cadence != series.cadence ||
        form.reminder != series.reminder) {
      await service.updateSeries(
        series
            .copyWith(name: form.name, cadence: form.cadence)
            .withReminder(form.reminder),
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
    // Nothing while one is open: a notification tap mid-check-in asks for
    // another.
    await showPhotoCheckInDialog(context, series: series, angles: angles);
  }

  /// Scrolls the grid to [period]'s newest check-in in [groups].
  Future<void> _scrollToPeriod(
    List<_GridGroup> groups,
    TrackerCadence cadence,
    DateTime period,
  ) async {
    if (_view != _PhotoSeriesView.grid) {
      setState(() => _view = _PhotoSeriesView.grid);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _scrollToPeriod(groups, cadence, period);
      });
      return;
    }
    final found = [
      for (final group in groups)
        for (final entry in group.entries)
          if (photoPeriodStart(entry.checkIn.takenOn, cadence) == period)
            (group: group, entry: entry),
    ].firstOrNull;
    if (found == null) return;
    final (:group, :entry) = found;
    final turn = ++_scrollTurn;
    final groupKey = _groupKeys[group.start];
    if (groupKey?.currentContext case final target?) {
      await Scrollable.ensureVisible(
        target,
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOut,
      );
    }
    // A group far down the grid hasn't been laid out yet, so where it sits
    // is an estimate until the scroll gets near it: again until it holds.
    for (var i = 0; i < 20; i++) {
      if (turn != _scrollTurn) return;
      final target = groupKey?.currentContext;
      if (target == null || !target.mounted) return;
      final position = Scrollable.of(target).position;
      final before = position.pixels;
      await Scrollable.ensureVisible(target);
      await WidgetsBinding.instance.endOfFrame;
      if (position.pixels == before) break;
    }
    // Down to the tile, when the group is taller than the page.
    if (turn != _scrollTurn) return;
    final tile = _tileKeys[entry.checkIn.id]?.currentContext;
    if (tile != null && tile.mounted) {
      await Scrollable.ensureVisible(
        tile,
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOut,
        alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
      );
    }
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
    ref.listen(secureVaultSessionProvider, (_, session) {
      if (session == null) setState(() => _view = _PhotoSeriesView.grid);
    });
    final unlocked = ref.watch(
      secureVaultSessionProvider.select((s) => s != null),
    );
    final angles = [
      for (final angle in snapshot.angles)
        if (angle.seriesId == series.id) angle,
    ];
    // Watched, not listened to: one made before the detail opened — the tap
    // that opened it — waits here for the series to load.
    if (ref.watch(photoSeriesCheckInRequestProvider) == series.id) {
      Future.microtask(() => _takeCheckInRequest(series, angles));
    }
    final stats = photoSeriesStats(
      series: series,
      checkIns: snapshot.checkIns,
      images: snapshot.images,
      now: ref.watch(photoSeriesTodayProvider),
    );
    final groups = _groups(series, snapshot, angles);
    final theme = Theme.of(context);
    final view = unlocked ? _view : _PhotoSeriesView.grid;
    final header = [
      _StatsRow(series: series, stats: stats),
      const SizedBox(height: 14),
      PhotoPeriodStrip(
        stats: stats,
        cadence: series.cadence,
        onTap: (period) => _scrollToPeriod(groups, series.cadence, period),
      ),
      const SizedBox(height: 16),
      Align(
        alignment: Alignment.centerLeft,
        child: SegmentedButton<_PhotoSeriesView>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(
              value: _PhotoSeriesView.grid,
              icon: Icon(PhosphorIconsRegular.squaresFour, size: 16),
              label: Text('Grid'),
            ),
            ButtonSegment(
              value: _PhotoSeriesView.playback,
              icon: Icon(PhosphorIconsRegular.playCircle, size: 16),
              label: Text('Playback'),
            ),
            ButtonSegment(
              value: _PhotoSeriesView.compare,
              icon: Icon(PhosphorIconsRegular.columns, size: 16),
              label: Text('Compare'),
            ),
          ],
          selected: {view},
          // Not disabled while locked: picking Playback or Compare points
          // at the unlock card instead.
          onSelectionChanged: (selected) {
            final picked = selected.single;
            if (picked != _PhotoSeriesView.grid && !_requireUnlocked()) {
              return;
            }
            setState(() => _view = picked);
          },
        ),
      ),
      const SizedBox(height: 16),
    ];
    // Oldest first, as Playback and Compare walk them.
    final entries = [
      for (final group in groups.reversed) ...group.entries.reversed,
    ];
    final referenceImageIds = {
      for (final angle in angles)
        if (photoReferenceFrame(angle, photoFramesOf(entries, angle.id))
            case final reference?)
          reference.image.id,
    };

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
        body: view != _PhotoSeriesView.grid
            // Fills the page; on one too short for the header and the
            // controls, it scrolls rather than squeezing them.
            ? LayoutBuilder(
                builder: (context, box) => SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(24, 4, 24, 16),
                  child: SizedBox(
                    height: math.max(box.maxHeight - 20, 640),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ...header,
                        Expanded(
                          child: view == _PhotoSeriesView.playback
                              ? PhotoSeriesPlayback(
                                  series: series,
                                  angles: angles,
                                  entries: entries,
                                )
                              : PhotoSeriesCompare(
                                  angles: angles,
                                  entries: entries,
                                ),
                        ),
                      ],
                    ),
                  ),
                ),
              )
            : CustomScrollView(
                slivers: [
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(24, 4, 24, 0),
                    sliver: SliverList.list(
                      children: [
                        ...header,
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
                      key: _groupKeys.putIfAbsent(group.start, GlobalKey.new),
                      padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
                      sliver: SliverList.list(
                        children: [
                          if (_gridGroupLabel(group.start, series.cadence)
                              case final label?) ...[
                            Text(label, style: theme.textTheme.labelLarge),
                            const SizedBox(height: 8),
                          ],
                          Wrap(
                            spacing: 10,
                            runSpacing: 10,
                            children: [
                              for (final entry in group.entries)
                                _CheckInTile(
                                  key: _tileKeys.putIfAbsent(
                                    entry.checkIn.id,
                                    GlobalKey.new,
                                  ),
                                  series: series,
                                  angles: angles,
                                  entry: entry,
                                  onOpen: () => _openViewer(series, entry),
                                  onAlign: (angle, image) =>
                                      _align(entries, angle, image),
                                  referenceImageIds: referenceImageIds,
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

  void _align(
    List<PhotoViewerEntry> entries,
    PhotoSeriesAngle angle,
    PhotoCheckInImage image,
  ) {
    if (!_requireUnlocked()) return;
    showPhotoAlignEditor(
      context,
      angle: angle,
      frames: photoFramesOf(entries, angle.id),
      image: image,
    );
  }

  void _openViewer(PhotoSeries series, PhotoViewerEntry entry) {
    showPhotoSeriesViewer(
      context,
      initialCheckInId: entry.checkIn.id,
      contents: (snapshot) {
        final current = snapshot.series
            .where((s) => s.id == series.id)
            .firstOrNull;
        if (current == null) return (entries: const [], angles: const []);
        final angles = [
          for (final angle in snapshot.angles)
            if (angle.seriesId == current.id) angle,
        ];
        // Oldest first, so right is later.
        return (
          entries: [
            for (final group in _groups(current, snapshot, angles).reversed)
              ...group.entries.reversed,
          ],
          angles: angles,
        );
      },
    );
  }
}

class _GridGroup {
  _GridGroup(this.start);

  /// Its month, or year, or none: [_gridGroupStart].
  final DateTime start;
  final entries = <PhotoViewerEntry>[];
}

/// [series]' check-ins with a photo, newest first, grouped by
/// [_gridGroupStart].
List<_GridGroup> _groups(
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
  final groups = <_GridGroup>[];
  for (final checkIn in checkIns) {
    final start = _gridGroupStart(checkIn.takenOn, series.cadence);
    if (groups.isEmpty || groups.last.start != start) {
      groups.add(_GridGroup(start));
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
    // The app turns tooltips off everywhere, but a mark is named only by its
    // tooltip: nothing else says which period it is or how it went.
    return TooltipVisibility(
      visible: true,
      child: SizedBox(
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
    super.key,
    required this.series,
    required this.angles,
    required this.entry,
    required this.onOpen,
    required this.onAlign,
    required this.referenceImageIds,
    required this.requireUnlocked,
  });

  final PhotoSeries series;
  final List<PhotoSeriesAngle> angles;
  final PhotoViewerEntry entry;
  final VoidCallback onOpen;
  final void Function(PhotoSeriesAngle angle, PhotoCheckInImage image) onAlign;

  /// Each angle's reference photo (§10).
  final Set<String> referenceImageIds;
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
    final present = [
      for (final angle in widget.angles)
        if (images[angle.id] case final image?) (angle: angle, image: image),
    ];

    /// One item for a series of one angle, else one per angle this
    /// check-in has a photo of.
    ContextMenuItem perAngle(
      String label,
      IconData icon,
      bool Function(PhotoCheckInImage image) enabled,
      void Function(PhotoSeriesAngle angle, PhotoCheckInImage image) onTap,
    ) => widget.angles.length == 1
        ? ContextMenuItem(
            label: label,
            icon: icon,
            enabled: enabled(present.single.image),
            onTap: enabled(present.single.image)
                ? () => onTap(present.single.angle, present.single.image)
                : null,
          )
        : ContextMenuItem(
            label: label,
            icon: icon,
            children: [
              for (final (:angle, :image) in present)
                ContextMenuItem(
                  label: angle.name,
                  enabled: enabled(image),
                  onTap: enabled(image) ? () => onTap(angle, image) : null,
                ),
            ],
          );

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
      perAngle(
        'Align',
        PhosphorIconsRegular.frameCorners,
        (_) => true,
        widget.onAlign,
      ),
      perAngle(
        'Use as reference',
        PhosphorIconsRegular.pushPin,
        (image) => !widget.referenceImageIds.contains(image.id),
        (_, image) {
          if (!widget.requireUnlocked()) return;
          ref.read(photoSeriesServiceProvider).setReference(image);
        },
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
        ? VaultPhoto(
            blobId: images[shown.id]!.blobId,
            thumb: true,
            // Why a photo is missing isn't blurred with it.
            framePhoto: revealed
                ? null
                : (photo) => Stack(
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
                      Center(
                        child: Icon(
                          PhosphorIconsRegular.eye,
                          color: Colors.white.withValues(alpha: 0.8),
                        ),
                      ),
                    ],
                  ),
          )
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
                    child: photo,
                  ),
                ),
                // Inset from the hover fill, which reaches the tile's edges.
                Padding(
                  padding: const EdgeInsets.fromLTRB(6, 4, 6, 4),
                  // The dots below the date when they don't fit beside it,
                  // as with many angles.
                  child: Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    runSpacing: 3,
                    children: [
                      Text(
                        DateFormat.yMMMd().format(_checkIn.takenOn),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall,
                      ),
                      Wrap(
                        crossAxisAlignment: WrapCrossAlignment.center,
                        runSpacing: 3,
                        children: [
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
