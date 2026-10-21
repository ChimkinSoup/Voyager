import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/core/utils/calendar_days.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/voyager_popup_menu_item.dart';
import 'package:voyager/domain/models/photo_series_models.dart';
import 'package:voyager/domain/photo_series/photo_series_periods.dart';
import 'package:voyager/features/notifications/secure_vault_session.dart';
import 'package:voyager/features/photo_series/photo_frame.dart';
import 'package:voyager/features/photo_series/photo_series_playback.dart';
import 'package:voyager/features/photo_series/photo_series_service.dart';
import 'package:voyager/features/photo_series/photo_series_viewer.dart';
import 'package:voyager/features/photo_series/vault_image_cache.dart';

enum PhotoCompareMode { sideBySide, slider, overlay }

/// The frame among [frames] taken nearest [date], the earlier on a tie.
PhotoFrameEntry nearestPhotoFrame(List<PhotoFrameEntry> frames, DateTime date) {
  var best = frames.first;
  for (final frame in frames) {
    if (calendarDaysBetween(frame.checkIn.takenOn, date).abs() <
        calendarDaysBetween(best.checkIn.takenOn, date).abs()) {
      best = frame;
    }
  }
  return best;
}

/// [months] before [date], on the same day of the month where it has one
/// and its last day where it doesn't.
DateTime _monthsBefore(DateTime date, int months) {
  final lastDay = DateTime(date.year, date.month - months + 1, 0).day;
  return DateTime(date.year, date.month - months, math.min(date.day, lastDay));
}

/// Two check-ins of one angle, side by side, wiped or overlaid
/// (PHOTO_SERIES_HLD.md §12). [entries] are the series' check-ins, oldest
/// first.
class PhotoSeriesCompare extends ConsumerStatefulWidget {
  const PhotoSeriesCompare({
    super.key,
    required this.angles,
    required this.entries,
  });

  final List<PhotoSeriesAngle> angles;
  final List<PhotoViewerEntry> entries;

  @override
  ConsumerState<PhotoSeriesCompare> createState() => _PhotoSeriesCompareState();
}

class _PhotoSeriesCompareState extends ConsumerState<PhotoSeriesCompare> {
  String? _angleId;

  /// The check-ins picked for each side; null for the default, first vs.
  /// latest.
  String? _aId;
  String? _bId;
  PhotoCompareMode _mode = PhotoCompareMode.sideBySide;
  double _divider = 0.5;
  double _opacity = 0.5;

  /// Notes opened so far, by check-in id.
  final _notes = <String, Future<String?>>{};

  /// [id]'s frame among [frames]; for a check-in without this angle, the
  /// nearest one that has it; [fallback] with no pick at all.
  PhotoFrameEntry _side(
    List<PhotoFrameEntry> frames,
    String? id,
    PhotoFrameEntry fallback,
  ) {
    if (id == null) return fallback;
    for (final frame in frames) {
      if (frame.checkIn.id == id) return frame;
    }
    final picked = widget.entries
        .where((e) => e.checkIn.id == id)
        .firstOrNull
        ?.checkIn;
    return picked == null
        ? fallback
        : nearestPhotoFrame(frames, picked.takenOn);
  }

  void _nudge(double by) {
    setState(() => _divider = (_divider + by).clamp(0.0, 1.0));
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(secureVaultSessionProvider);
    final shownAngles = photoAnglesWithFrames(widget.angles, widget.entries);
    if (session == null || shownAngles.isEmpty) {
      return const Center(child: Text('No photos to compare yet.'));
    }
    final angle = shownAngles.firstWhere(
      (a) => a.id == _angleId,
      orElse: () => shownAngles.first,
    );
    final frames = photoFramesOf(widget.entries, angle.id);
    final a = _side(frames, _aId, frames.first);
    final b = _side(frames, _bId, frames.last);
    final aspect = angle.frameAspect ?? kDefaultPhotoFrameAspect;
    final theme = Theme.of(context);
    final caption = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
    );

    Widget photo(PhotoFrameEntry side) => AlignedPhotoFrame(
      aspect: aspect,
      image: side.image,
      child: VaultPhoto(
        key: ValueKey(side.image.blobId),
        blobId: side.image.blobId,
        thumb: false,
        fit: BoxFit.contain,
        // The thumbnail while the full image decodes or downloads.
        placeholder: VaultPhoto(
          blobId: side.image.blobId,
          thumb: true,
          fit: BoxFit.contain,
        ),
      ),
    );

    Widget note(PhotoFrameEntry side) => !side.checkIn.hasNote
        ? const SizedBox.shrink()
        : FutureBuilder<String?>(
            future: _notes.putIfAbsent(
              side.checkIn.id,
              () => PhotoSeriesService.openNote(session, side.checkIn),
            ),
            builder: (context, snapshot) => Text(
              snapshot.data ?? '',
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
          );

    // Looked for among the frames before B only, so none lands on B itself.
    final earlier = frames.sublist(0, frames.indexOf(b));
    PhotoFrameEntry? before(int months) => earlier.isEmpty
        ? null
        : nearestPhotoFrame(earlier, _monthsBefore(b.checkIn.takenOn, months));
    final quickPicks = <(String, PhotoFrameEntry?)>[
      ('First', frames.first),
      ('Previous', earlier.lastOrNull),
      ('~1 month ago', before(1)),
      ('~1 year ago', before(12)),
    ];

    final Widget images = switch (_mode) {
      PhotoCompareMode.sideBySide => LayoutBuilder(
        builder: (context, box) {
          final pair = [
            Expanded(child: Center(child: photo(a))),
            const SizedBox(width: 12, height: 12),
            Expanded(child: Center(child: photo(b))),
          ];
          // Whichever way round draws the photos larger: stacked only pays
          // when the room is tall (BUG-303).
          double width(double w, double h) => math.min(w, h * aspect);
          return width(box.maxWidth, (box.maxHeight - 12) / 2) >
                  width((box.maxWidth - 12) / 2, box.maxHeight)
              ? Column(children: pair)
              : Row(children: pair);
        },
      ),
      PhotoCompareMode.slider => Center(
        child: AspectRatio(
          aspectRatio: aspect,
          child: LayoutBuilder(
            builder: (context, box) {
              void drag(Offset local) => setState(
                () => _divider = (local.dx / box.maxWidth).clamp(0.0, 1.0),
              );
              return MouseRegion(
                cursor: SystemMouseCursors.resizeColumn,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (details) => drag(details.localPosition),
                  onHorizontalDragUpdate: (details) =>
                      drag(details.localPosition),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      photo(a),
                      ClipRect(clipper: _RightOf(_divider), child: photo(b)),
                      Positioned(
                        left: _divider * box.maxWidth - 1,
                        top: 0,
                        bottom: 0,
                        width: 2,
                        child: const ColoredBox(color: Colors.white),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
      PhotoCompareMode.overlay => Center(
        child: AspectRatio(
          aspectRatio: aspect,
          child: Stack(
            fit: StackFit.expand,
            children: [
              photo(a),
              Opacity(opacity: _opacity, child: photo(b)),
            ],
          ),
        ),
      ),
    };

    return CallbackShortcuts(
      // Only while there's a divider to move, so other modes leave the keys
      // alone.
      bindings: {
        if (_mode == PhotoCompareMode.slider) ...{
          const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
              _nudge(-0.02),
          const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
              _nudge(0.02),
          const SingleActivator(
            LogicalKeyboardKey.arrowLeft,
            shift: true,
          ): () =>
              _nudge(-0.1),
          const SingleActivator(
            LogicalKeyboardKey.arrowRight,
            shift: true,
          ): () =>
              _nudge(0.1),
        },
      },
      child: Focus(
        autofocus: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // How to look: the mode (and its opacity), then which angle.
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              alignment: WrapAlignment.spaceBetween,
              spacing: 16,
              runSpacing: 8,
              children: [
                Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    SegmentedButton<PhotoCompareMode>(
                      showSelectedIcon: false,
                      segments: const [
                        ButtonSegment(
                          value: PhotoCompareMode.sideBySide,
                          label: Text('Side by side'),
                        ),
                        ButtonSegment(
                          value: PhotoCompareMode.slider,
                          label: Text('Slider'),
                        ),
                        ButtonSegment(
                          value: PhotoCompareMode.overlay,
                          label: Text('Overlay'),
                        ),
                      ],
                      selected: {_mode},
                      onSelectionChanged: (selected) =>
                          setState(() => _mode = selected.single),
                    ),
                    // Named and read out, as Playback's fps (BUG-298). Its
                    // room kept in every mode, so the slider, taller than
                    // the mode buttons, doesn't push the rows below down
                    // when Overlay brings it.
                    Visibility(
                      visible: _mode == PhotoCompareMode.overlay,
                      maintainSize: true,
                      maintainAnimation: true,
                      maintainState: true,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('B over A', style: theme.textTheme.bodySmall),
                          SizedBox(
                            width: 180,
                            child: Slider(
                              value: _opacity,
                              semanticFormatterCallback: (value) =>
                                  'B ${(value * 100).round()}%',
                              onChanged: (value) =>
                                  setState(() => _opacity = value),
                            ),
                          ),
                          SizedBox(
                            width: 36,
                            child: Text(
                              '${(_opacity * 100).round()}%',
                              style: theme.textTheme.bodySmall,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                if (shownAngles.length > 1)
                  Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      Text('Angle', style: caption),
                      for (final shown in shownAngles)
                        ChoiceChip(
                          label: Text(shown.name),
                          selected: shown.id == angle.id,
                          onSelected: (_) =>
                              setState(() => _angleId = shown.id),
                        ),
                    ],
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Divider(height: 1, color: VoyagerColors.of(context).hairline),
            const SizedBox(height: 12),
            // What to look at: A on the left with its shortcuts under it,
            // B on the right, the time between them in the middle.
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _CheckInPicker(
                        label: 'A',
                        frames: frames,
                        selected: a,
                        onSelected: (id) => setState(() => _aId = id),
                      ),
                      const SizedBox(height: 6),
                      Wrap(
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(right: 2),
                            child: Text('Set A to', style: caption),
                          ),
                          for (final (label, target) in quickPicks)
                            GlassButton(
                              onPressed: target == null
                                  ? null
                                  : () => setState(
                                      () => _aId = target.checkIn.id,
                                    ),
                              label: label,
                              dense: true,
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        PhosphorIconsRegular.arrowsLeftRight,
                        size: 14,
                        color: caption?.color,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        photoElapsedLabel(a.checkIn.takenOn, b.checkIn.takenOn),
                        style: caption,
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: Align(
                    alignment: Alignment.topRight,
                    child: _CheckInPicker(
                      label: 'B',
                      frames: frames,
                      selected: b,
                      onSelected: (id) => setState(() => _bId = id),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(child: images),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: note(a)),
                const SizedBox(width: 16),
                Expanded(
                  child: Align(alignment: Alignment.topRight, child: note(b)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Clips to the part of the box right of [fraction] of its width.
class _RightOf extends CustomClipper<Rect> {
  const _RightOf(this.fraction);

  final double fraction;

  @override
  Rect getClip(Size size) =>
      Rect.fromLTRB(size.width * fraction, 0, size.width, size.height);

  @override
  bool shouldReclip(_RightOf old) => old.fraction != fraction;
}

/// One side's check-in, picked from a menu of [frames], newest first.
class _CheckInPicker extends StatelessWidget {
  const _CheckInPicker({
    required this.label,
    required this.frames,
    required this.selected,
    required this.onSelected,
  });

  final String label;
  final List<PhotoFrameEntry> frames;
  final PhotoFrameEntry selected;
  final ValueChanged<String> onSelected;

  /// Opens as a Voyager menu, whose rows round off at its corners, rather
  /// than Material's, whose hover ran past them.
  Future<void> _open(BuildContext context) async {
    final button = context.findRenderObject()! as RenderBox;
    final overlay =
        Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox;
    final rect =
        button.localToGlobal(Offset.zero, ancestor: overlay) & button.size;
    final date = DateFormat.yMMMd();
    final picked = await showVoyagerMenu<String>(
      context: context,
      // Hung from the picker's outer edge, so A's opens rightward and B's
      // leftward, both inside the page.
      position: rect.center.dx < overlay.size.width / 2
          ? RelativeRect.fromLTRB(rect.left, rect.bottom + 4, 0, 0)
          : RelativeRect.fromLTRB(
              0,
              rect.bottom + 4,
              overlay.size.width - rect.right,
              0,
            ),
      constraints: BoxConstraints(
        minWidth: rect.width,
        maxWidth: math.max(rect.width, 200),
      ),
      items: voyagerSelectMenuEntries<String>(
        context: context,
        items: [
          for (final frame in frames.reversed)
            (
              value: frame.checkIn.id,
              label: date.format(frame.checkIn.takenOn),
            ),
        ],
        selected: selected.checkIn.id,
      ),
    );
    if (picked != null) onSelected(picked);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final date = DateFormat.yMMMd();
    final radius = BorderRadius.circular(VoyagerTheme.fieldRadius);
    return Semantics(
      button: true,
      label: 'Check-in $label',
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: radius,
          onTap: () => _open(context),
          child: Ink(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.05),
              border: Border.all(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.25),
              ),
              borderRadius: radius,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: label,
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            color: theme.colorScheme.primary,
                          ),
                        ),
                        TextSpan(
                          text: ' · ${date.format(selected.checkIn.takenOn)}',
                        ),
                      ],
                    ),
                    style: theme.textTheme.labelLarge,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                const Icon(PhosphorIconsRegular.caretDown, size: 14),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
