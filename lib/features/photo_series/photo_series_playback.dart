import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/secure_vault/vault_media_service.dart';
import 'package:voyager/domain/models/photo_series_models.dart';
import 'package:voyager/domain/photo_series/photo_series_periods.dart';
import 'package:voyager/features/notifications/secure_vault_session.dart';
import 'package:voyager/features/photo_series/photo_frame.dart';
import 'package:voyager/features/photo_series/photo_series_providers.dart';
import 'package:voyager/features/photo_series/photo_series_viewer.dart';

/// One check-in's photo of the angle on screen, as Playback and Compare walk
/// them.
typedef PhotoFrameEntry = ({PhotoCheckIn checkIn, PhotoCheckInImage image});

/// [entries]' photos of [angleId], in [entries]' order; check-ins without
/// one are skipped.
List<PhotoFrameEntry> photoFramesOf(
  List<PhotoViewerEntry> entries,
  String angleId,
) => [
  for (final entry in entries)
    if (entry.images[angleId] case final image?)
      (checkIn: entry.checkIn, image: image),
];

/// The angles with at least one photo among [entries], in the series' order.
List<PhotoSeriesAngle> photoAnglesWithFrames(
  List<PhotoSeriesAngle> angles,
  List<PhotoViewerEntry> entries,
) => [
  for (final angle in angles)
    if (entries.any((entry) => entry.images.containsKey(angle.id))) angle,
];

enum PhotoLoopMode { once, loop, pingPong }

/// Stop-motion through one angle's photos (PHOTO_SERIES_HLD.md §11).
/// [entries] are the series' check-ins, oldest first.
class PhotoSeriesPlayback extends ConsumerStatefulWidget {
  const PhotoSeriesPlayback({
    super.key,
    required this.series,
    required this.angles,
    required this.entries,
  });

  final PhotoSeries series;
  final List<PhotoSeriesAngle> angles;
  final List<PhotoViewerEntry> entries;

  @override
  ConsumerState<PhotoSeriesPlayback> createState() =>
      _PhotoSeriesPlaybackState();
}

class _PhotoSeriesPlaybackState extends ConsumerState<PhotoSeriesPlayback>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_tick);
  late int _fps = widget.series.playbackFps.clamp(1, 30);
  PhotoLoopMode _loop = PhotoLoopMode.loop;
  bool _dateStamp = true;
  String? _angleId;
  int _index = 0;

  /// 1 forward, -1 back: ping-pong's way through the frames.
  int _direction = 1;
  Duration _lastStep = Duration.zero;

  /// The frame last drawn, held — as its own copy, which the window can't
  /// let go of — while the playhead's own isn't ready.
  int? _shown;
  ui.Image? _held;

  /// The window's image [_held] was copied from, so a thumbnail replaced by
  /// its full image is picked up.
  ui.Image? _heldFrom;

  _FrameWindow? _window;
  String? _windowKey;

  /// The angle's frames, worked out again only when the check-ins or the
  /// angle change, not with every frame played; and their image ids, which
  /// say whether a new list holds anything new.
  List<PhotoFrameEntry> _frames = const [];
  String _framesIds = '';
  Object? _framesSource;
  String? _framesAngle;

  @override
  void dispose() {
    _ticker.dispose();
    _window?.dispose();
    _held?.dispose();
    super.dispose();
  }

  void _updateFrames(PhotoSeriesAngle angle) {
    if (identical(widget.entries, _framesSource) && angle.id == _framesAngle) {
      return;
    }
    _framesSource = widget.entries;
    _framesAngle = angle.id;
    _frames = photoFramesOf(widget.entries, angle.id);
    _framesIds = [for (final frame in _frames) frame.image.id].join('|');
  }

  void _focus() => _window?.focus(
    _index,
    direction: _direction,
    wrap: _loop == PhotoLoopMode.loop,
  );

  void _hold(int? index, ui.Image? image) {
    _held?.dispose();
    _shown = index;
    _heldFrom = image;
    _held = image?.clone();
  }

  /// A fresh window whenever what it decodes changes: the frames, the size
  /// they're drawn at, or the vault session.
  void _ensureWindow(
    List<PhotoFrameEntry> frames,
    Size target,
    SecureVaultSession session,
  ) {
    final key =
        '${session.vaultId}|${identityHashCode(session)}|$target|$_framesIds';
    if (key == _windowKey) return;
    _windowKey = key;
    _window?.dispose();
    _hold(null, null);
    _window = _FrameWindow(
      media: ref.read(vaultMediaServiceProvider.notifier),
      session: session,
      frames: frames,
      target: target,
      onReady: () {
        if (mounted) setState(() {});
      },
    );
    _focus();
  }

  /// Where the playhead goes after [_index], with the direction it then
  /// faces. Null when [PhotoLoopMode.once] has reached the end.
  (int, int)? _next(int count) {
    final next = _index + _direction;
    if (next >= 0 && next < count) return (next, _direction);
    return switch (_loop) {
      PhotoLoopMode.once => null,
      PhotoLoopMode.loop => (0, 1),
      PhotoLoopMode.pingPong => (_index - _direction, -_direction),
    };
  }

  void _tick(Duration elapsed) {
    final window = _window;
    if (window == null) return;
    if (elapsed - _lastStep < Duration(microseconds: 1000000 ~/ _fps)) return;
    final next = _next(window.frames.length);
    if (next == null) {
      _pause();
      return;
    }
    // Waits on a frame still decoding rather than skipping it.
    if (!window.isSettled(next.$1)) return;
    _lastStep = elapsed;
    setState(() {
      _index = next.$1;
      _direction = next.$2;
    });
    _focus();
  }

  void _play() {
    final window = _window;
    if (window == null || window.frames.length < 2) return;
    if (_loop == PhotoLoopMode.once && _index == window.frames.length - 1) {
      _index = 0;
      _direction = 1;
      _focus();
    }
    _lastStep = Duration.zero;
    _ticker.start();
    setState(() {});
  }

  void _pause() {
    if (!_ticker.isActive) return;
    _ticker.stop();
    setState(() {});
  }

  void _togglePlay() => _ticker.isActive ? _pause() : _play();

  void _seek(int index) {
    final window = _window;
    if (window == null) return;
    _pause();
    setState(() {
      _index = index.clamp(0, window.frames.length - 1);
      _direction = 1;
    });
    _focus();
  }

  void _setAngle(String angleId) {
    _pause();
    setState(() {
      _angleId = angleId;
      _index = 0;
      _direction = 1;
    });
  }

  void _saveFps(double value) {
    final fps = value.round();
    if (fps == widget.series.playbackFps) return;
    ref
        .read(photoSeriesServiceProvider)
        .updateSeries(widget.series.copyWith(playbackFps: fps));
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(secureVaultSessionProvider);
    // A download landing may bring a frame that wasn't here.
    ref.listen(vaultMediaServiceProvider, (_, _) => _window?.retry());
    final shownAngles = photoAnglesWithFrames(widget.angles, widget.entries);
    if (session == null || shownAngles.isEmpty) {
      return const Center(child: Text('No photos to play yet.'));
    }
    final angle = shownAngles.firstWhere(
      (a) => a.id == _angleId,
      orElse: () => shownAngles.first,
    );
    _updateFrames(angle);
    final frames = _frames;
    // Here rather than with the window, which is made at layout: everything
    // built before then reads the playhead too.
    if (_index >= frames.length) _index = frames.length - 1;
    final aspect = angle.frameAspect ?? kDefaultPhotoFrameAspect;
    final theme = Theme.of(context);
    final playing = _ticker.isActive;

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.space): _togglePlay,
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
            _seek(_index - 1),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
            _seek(_index + 1),
      },
      child: Focus(
        autofocus: true,
        child: Column(
          children: [
            if (shownAngles.length > 1)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Wrap(
                  spacing: 6,
                  children: [
                    for (final shown in shownAngles)
                      ChoiceChip(
                        label: Text(shown.name),
                        selected: shown.id == angle.id,
                        onSelected: (_) => _setAngle(shown.id),
                      ),
                  ],
                ),
              ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, box) {
                  final frame = box.maxWidth / box.maxHeight > aspect
                      ? Size(box.maxHeight * aspect, box.maxHeight)
                      : Size(box.maxWidth, box.maxWidth / aspect);
                  final ratio = MediaQuery.devicePixelRatioOf(context);
                  // Coarse steps, so a window resize doesn't decode anew
                  // with every pixel.
                  Size bucket(Size s) => Size(
                    (s.width * ratio / 256).ceil() * 256,
                    (s.height * ratio / 256).ceil() * 256,
                  );
                  _ensureWindow(frames, bucket(frame), session);
                  final window = _window!;
                  final current = window[_index];
                  if (current != null && !identical(current, _heldFrom)) {
                    _hold(_index, current);
                  }
                  final shown = _shown;
                  return Center(
                    child: AspectRatio(
                      aspectRatio: aspect,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          ColoredBox(
                            color: theme.colorScheme.onSurface.withValues(
                              alpha: 0.06,
                            ),
                          ),
                          if (shown != null)
                            AlignedPhotoFrame(
                              aspect: aspect,
                              image: frames[shown].image,
                              child: RawImage(
                                image: _held,
                                fit: BoxFit.contain,
                                filterQuality: FilterQuality.medium,
                              ),
                            )
                          else if (window.isSettled(_index))
                            const Center(
                              child: Icon(PhosphorIconsRegular.imageBroken),
                            )
                          else
                            const Center(child: CircularProgressIndicator()),
                          if (_dateStamp && shown != null)
                            Positioned(
                              left: 10,
                              bottom: 10,
                              child: _Stamp(
                                date: frames[shown].checkIn.takenOn,
                                first: frames.first.checkIn.takenOn,
                              ),
                            ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 10),
            _Scrubber(
              dates: [for (final frame in frames) frame.checkIn.takenOn],
              index: _index,
              onSeek: _seek,
            ),
            const SizedBox(height: 6),
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 12,
              runSpacing: 6,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: 'Previous frame (←)',
                      icon: const Icon(PhosphorIconsRegular.skipBack),
                      onPressed: _index > 0 ? () => _seek(_index - 1) : null,
                    ),
                    IconButton.filledTonal(
                      tooltip: playing ? 'Pause (Space)' : 'Play (Space)',
                      icon: Icon(
                        playing
                            ? PhosphorIconsFill.pause
                            : PhosphorIconsFill.play,
                      ),
                      onPressed: frames.length > 1 ? _togglePlay : null,
                    ),
                    IconButton(
                      tooltip: 'Next frame (→)',
                      icon: const Icon(PhosphorIconsRegular.skipForward),
                      onPressed: _index < frames.length - 1
                          ? () => _seek(_index + 1)
                          : null,
                    ),
                  ],
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 160,
                      child: Slider(
                        min: 1,
                        max: 30,
                        divisions: 29,
                        value: _fps.toDouble(),
                        label: '$_fps fps',
                        onChanged: (value) =>
                            setState(() => _fps = value.round()),
                        onChangeEnd: _saveFps,
                      ),
                    ),
                    Text('$_fps fps', style: theme.textTheme.bodySmall),
                  ],
                ),
                SegmentedButton<PhotoLoopMode>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(
                      value: PhotoLoopMode.once,
                      label: Text('Once'),
                    ),
                    ButtonSegment(
                      value: PhotoLoopMode.loop,
                      label: Text('Loop'),
                    ),
                    ButtonSegment(
                      value: PhotoLoopMode.pingPong,
                      label: Text('Ping-pong'),
                    ),
                  ],
                  selected: {_loop},
                  onSelectionChanged: (selected) {
                    setState(() {
                      _loop = selected.single;
                      if (_loop != PhotoLoopMode.pingPong) _direction = 1;
                    });
                    _focus();
                  },
                ),
                IconButton(
                  tooltip: _dateStamp ? 'Hide date stamp' : 'Show date stamp',
                  isSelected: _dateStamp,
                  icon: const Icon(PhosphorIconsRegular.calendarBlank),
                  selectedIcon: const Icon(PhosphorIconsFill.calendarBlank),
                  onPressed: () => setState(() => _dateStamp = !_dateStamp),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// The frame's date, and how long after the first frame it was taken.
class _Stamp extends StatelessWidget {
  const _Stamp({required this.date, required this.first});

  final DateTime date;
  final DateTime first;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: 0.5),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Text(
        '${DateFormat.yMMMd().format(date)}  '
        '+${photoElapsedLabel(first, date)}',
        style: const TextStyle(color: Colors.white, fontSize: 12),
      ),
    ),
  );
}

/// A track with a tick per frame and the playhead on [index]. Clicking or
/// dragging seeks; hovering names the frame under the pointer.
class _Scrubber extends StatefulWidget {
  const _Scrubber({
    required this.dates,
    required this.index,
    required this.onSeek,
  });

  final List<DateTime> dates;
  final int index;
  final ValueChanged<int> onSeek;

  @override
  State<_Scrubber> createState() => _ScrubberState();
}

class _ScrubberState extends State<_Scrubber> {
  static const _inset = 8.0;
  int? _hover;

  int _indexAt(double x, double width) {
    final last = widget.dates.length - 1;
    if (last <= 0) return 0;
    final t = ((x - _inset) / (width - 2 * _inset)).clamp(0.0, 1.0);
    return (t * last).round();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final shown = _hover ?? widget.index;
    return Column(
      children: [
        Text(
          '${DateFormat.yMMMd().format(widget.dates[shown])} · '
          '${shown + 1} / ${widget.dates.length}',
          style: theme.textTheme.bodySmall?.copyWith(
            color: _hover == null ? null : theme.colorScheme.primary,
          ),
        ),
        LayoutBuilder(
          builder: (context, box) {
            void seek(Offset local) =>
                widget.onSeek(_indexAt(local.dx, box.maxWidth));
            return MouseRegion(
              cursor: SystemMouseCursors.click,
              onHover: (event) => setState(
                () => _hover = _indexAt(event.localPosition.dx, box.maxWidth),
              ),
              onExit: (_) => setState(() => _hover = null),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (details) => seek(details.localPosition),
                onHorizontalDragStart: (details) => seek(details.localPosition),
                onHorizontalDragUpdate: (details) =>
                    seek(details.localPosition),
                child: SizedBox(
                  height: 28,
                  width: double.infinity,
                  child: CustomPaint(
                    painter: _ScrubberPainter(
                      count: widget.dates.length,
                      index: widget.index,
                      hover: _hover,
                      inset: _inset,
                      track: theme.colorScheme.onSurface.withValues(
                        alpha: 0.25,
                      ),
                      accent: theme.colorScheme.primary,
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}

class _ScrubberPainter extends CustomPainter {
  _ScrubberPainter({
    required this.count,
    required this.index,
    required this.hover,
    required this.inset,
    required this.track,
    required this.accent,
  });

  final int count;
  final int index;
  final int? hover;
  final double inset;
  final Color track;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height / 2;
    final width = size.width - 2 * inset;
    double xOf(int i) => inset + (count <= 1 ? 0 : width * i / (count - 1));
    final line = Paint()
      ..color = track
      ..strokeWidth = 2;
    canvas.drawLine(Offset(inset, y), Offset(inset + width, y), line);
    final tick = Paint()
      ..color = track
      ..strokeWidth = 1;
    for (var i = 0; i < count; i++) {
      canvas.drawLine(Offset(xOf(i), y - 5), Offset(xOf(i), y + 5), tick);
    }
    if (hover case final hover?) {
      canvas.drawCircle(
        Offset(xOf(hover), y),
        5,
        Paint()..color = accent.withValues(alpha: 0.35),
      );
    }
    canvas.drawCircle(Offset(xOf(index), y), 6, Paint()..color = accent);
  }

  @override
  bool shouldRepaint(_ScrubberPainter old) =>
      old.count != count ||
      old.index != index ||
      old.hover != hover ||
      old.track != track ||
      old.accent != accent;
}

/// The frames around the playhead, decrypted and decoded at the size they're
/// drawn (§11): 30 ahead in the direction of play and 10 behind, filled in
/// the background. Everything else is let go, so a long daily series costs
/// about 40 frames of memory.
class _FrameWindow {
  _FrameWindow({
    required this.media,
    required this.session,
    required this.frames,
    required this.target,
    required this.onReady,
  });

  static const _ahead = 30;
  static const _behind = 10;
  static const _parallel = 2;

  final VaultMediaService media;
  final SecureVaultSession session;
  final List<PhotoFrameEntry> frames;

  /// The frame's size on screen, in physical pixels.
  final Size target;
  final VoidCallback onReady;

  final _images = <int, ui.Image>{};

  /// Frames that won't open — not here, or not under this vault. Playback
  /// steps past them rather than waiting forever.
  final _failed = <int>{};
  final _loading = <int>{};

  /// Frames showing their thumbnail, and those of them to try again for the
  /// full image.
  final _thumbOnly = <int>{};
  final _upgrade = <int>{};
  var _wanted = <int>[];
  bool _disposed = false;

  ui.Image? operator [](int index) => _images[index];

  /// Whether playback can move onto [index]: decoded, or never will be.
  bool isSettled(int index) =>
      _images.containsKey(index) || _failed.contains(index);

  /// Centres the window on [index], facing [direction]. With [wrap], what's
  /// ahead runs on past the last frame to the first, as a loop plays.
  void focus(int index, {required int direction, bool wrap = false}) {
    final n = frames.length;
    _wanted = {
      index,
      for (var i = 1; i <= _ahead; i++)
        wrap ? (index + direction * i) % n : index + direction * i,
      for (var i = 1; i <= _behind; i++) index - direction * i,
    }.where((i) => i >= 0 && i < n).toList();
    final keep = _wanted.toSet();
    _images.removeWhere((i, image) {
      if (keep.contains(i)) return false;
      image.dispose();
      return true;
    });
    _thumbOnly.removeWhere((i) => !keep.contains(i));
    _upgrade.removeWhere((i) => !keep.contains(i));
    _pump();
  }

  /// Tries again what isn't fully here: frames that wouldn't open, and ones
  /// showing their thumbnail, whose full image may since have arrived.
  void retry() {
    _failed.clear();
    _upgrade.addAll(_thumbOnly);
    _pump();
  }

  /// Starts the nearest wanted frames, a couple at a time.
  void _pump() {
    for (final index in _wanted) {
      if (_loading.length >= _parallel) return;
      if ((isSettled(index) && !_upgrade.contains(index)) ||
          _loading.contains(index)) {
        continue;
      }
      _loading.add(index);
      _load(index).whenComplete(() {
        _loading.remove(index);
        if (!_disposed) _pump();
      });
    }
  }

  Future<void> _load(int index) async {
    final image = frames[index].image;
    final upgrading = _upgrade.remove(index);
    ui.Image? decoded;
    var thumb = false;
    try {
      final blob = await media.repository.getBlob(image.blobId);
      // An upgrade waits for the full image to be here rather than fetching
      // it again on every download notice.
      if (blob != null && !_disposed && (!upgrading || blob.hasLocalBytes)) {
        var bytes = await media.open(blob, session.key, thumb: false);
        // The thumbnail stands in for a full image not yet downloaded.
        if (bytes == null && !upgrading) {
          bytes = await media.open(blob, session.key, thumb: true);
          thumb = true;
        }
        if (bytes != null && !_disposed) {
          decoded = await _decode(bytes, blob, image.alignScale);
        }
      }
    } catch (error) {
      debugPrint('[vault media] could not play ${image.blobId}: $error');
    }
    if (_disposed || !_wanted.contains(index)) {
      decoded?.dispose();
      return;
    }
    if (decoded == null) {
      // An upgrade that didn't happen keeps its thumbnail.
      if (!upgrading) {
        _failed.add(index);
        onReady();
      }
      return;
    }
    _images.remove(index)?.dispose();
    _images[index] = decoded;
    thumb ? _thumbOnly.add(index) : _thumbOnly.remove(index);
    onReady();
  }

  /// Decodes no larger than the photo is drawn: fitted inside the frame,
  /// then zoomed by its alignment.
  Future<ui.Image> _decode(
    Uint8List bytes,
    VaultBlob blob,
    double scale,
  ) async {
    final zoom = math.max(1.0, scale);
    final wide =
        blob.height == 0 ||
        blob.width / blob.height > target.width / target.height;
    final codec = await ui.instantiateImageCodec(
      bytes,
      targetWidth: wide ? (target.width * zoom).round() : null,
      targetHeight: wide ? null : (target.height * zoom).round(),
      allowUpscaling: false,
    );
    final frame = await codec.getNextFrame();
    codec.dispose();
    return frame.image;
  }

  void dispose() {
    _disposed = true;
    for (final image in _images.values) {
      image.dispose();
    }
    _images.clear();
  }
}
