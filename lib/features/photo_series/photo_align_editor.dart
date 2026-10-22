import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/voyager_dialog.dart';
import 'package:voyager/domain/models/photo_series_models.dart';
import 'package:voyager/features/notifications/secure_vault_session.dart';
import 'package:voyager/features/photo_series/photo_frame.dart';
import 'package:voyager/features/photo_series/photo_series_playback.dart';
import 'package:voyager/features/photo_series/photo_series_providers.dart';
import 'package:voyager/features/photo_series/vault_activity.dart';
import 'package:voyager/features/photo_series/vault_image_cache.dart';

/// How far a photo can be zoomed, either way.
const _kMinAlignScale = 0.2;
const _kMaxAlignScale = 8.0;

/// How far it can be turned, either way: enough to straighten a tilted
/// shot. A photo on its side was turned at ingest.
const _kMaxAlignRotation = math.pi / 4;

/// How close to level the rotation slider snaps to 0.
const _kRotationSnap = math.pi / 180;

/// The frame [angle]'s alignment editor draws underneath (PHOTO_SERIES_HLD.md
/// §10): its chosen reference while that photo is among [frames], else its
/// first. [frames] are the angle's photos, oldest first.
PhotoFrameEntry? photoReferenceFrame(
  PhotoSeriesAngle angle,
  List<PhotoFrameEntry> frames,
) {
  if (frames.isEmpty) return null;
  for (final frame in frames) {
    if (frame.image.id == angle.referenceImageId) return frame;
  }
  return frames.first;
}

/// The alignment editor (§10): [image] over its angle's reference, moved,
/// zoomed and turned onto the frame. [frames] are the angle's photos, oldest
/// first. Saves on Done; closes unsaved if the vault locks.
Future<void> showPhotoAlignEditor(
  BuildContext context, {
  required PhotoSeriesAngle angle,
  required List<PhotoFrameEntry> frames,
  required PhotoCheckInImage image,
}) => showVoyagerDialog<void>(
  context: context,
  builder: (context) =>
      _AlignEditor(angle: angle, frames: frames, image: image),
);

class _AlignEditor extends ConsumerStatefulWidget {
  const _AlignEditor({
    required this.angle,
    required this.frames,
    required this.image,
  });

  final PhotoSeriesAngle angle;
  final List<PhotoFrameEntry> frames;
  final PhotoCheckInImage image;

  @override
  ConsumerState<_AlignEditor> createState() => _AlignEditorState();
}

class _AlignEditorState extends ConsumerState<_AlignEditor> {
  late PhotoCheckInImage _draft = widget.image;
  double _opacity = 0.5;
  bool _saving = false;

  /// The frame as last laid out, which gestures move the photo across.
  Size _frame = Size.zero;

  /// The gesture's scale and rotation so far, to apply each update's change.
  double _gestureScale = 1;
  double _gestureRotation = 0;

  int get _at =>
      widget.frames.indexWhere((frame) => frame.image.id == widget.image.id);

  PhotoCheckInImage? get _previous =>
      _at > 0 ? widget.frames[_at - 1].image : null;

  /// The photo underneath; none while aligning the reference itself.
  PhotoCheckInImage? get _reference {
    final reference = photoReferenceFrame(widget.angle, widget.frames)?.image;
    return reference?.id == widget.image.id ? null : reference;
  }

  bool get _changed =>
      _draft.alignScale != widget.image.alignScale ||
      _draft.alignRotation != widget.image.alignRotation ||
      _draft.alignDx != widget.image.alignDx ||
      _draft.alignDy != widget.image.alignDy;

  void _set({double? scale, double? rotation, Offset? offset}) {
    if (_frame.isEmpty) return;
    setState(() {
      _draft = _draft.copyWith(
        alignScale: scale,
        alignRotation: rotation,
        alignDx: offset == null ? null : offset.dx / _frame.width,
        alignDy: offset == null ? null : offset.dy / _frame.height,
      );
    });
  }

  /// The photo's centre, in pixels from the frame's.
  Offset get _offset =>
      Offset(_draft.alignDx * _frame.width, _draft.alignDy * _frame.height);

  /// Moves by [delta], then zooms by [zoom] and turns by [turn] about
  /// [focal] — a point in the frame, in pixels from its centre — so the
  /// part of the photo under it stays put.
  void _transform({
    Offset delta = Offset.zero,
    double zoom = 1,
    double turn = 0,
    Offset focal = Offset.zero,
  }) {
    final scale = (_draft.alignScale * zoom).clamp(
      _kMinAlignScale,
      _kMaxAlignScale,
    );
    final rotation = (_draft.alignRotation + turn).clamp(
      -_kMaxAlignRotation,
      _kMaxAlignRotation,
    );
    final k = scale / _draft.alignScale;
    final theta = rotation - _draft.alignRotation;
    final v = (_offset + delta - focal) * k;
    final turned = Offset(
      v.dx * math.cos(theta) - v.dy * math.sin(theta),
      v.dx * math.sin(theta) + v.dy * math.cos(theta),
    );
    _set(scale: scale, rotation: rotation, offset: focal + turned);
  }

  Offset _fromCentre(Offset local, Size stage) =>
      local - stage.center(Offset.zero);

  void _nudge(double dx, double dy) => _transform(delta: Offset(dx, dy));

  void _copyPrevious() {
    final previous = _previous;
    if (previous == null) return;
    setState(() {
      _draft = _draft.copyWith(
        alignScale: previous.alignScale,
        alignRotation: previous.alignRotation,
        alignDx: previous.alignDx,
        alignDy: previous.alignDy,
      );
    });
  }

  void _reset() => setState(() {
    _draft = _draft.copyWith(
      alignScale: 1,
      alignRotation: 0,
      alignDx: 0,
      alignDy: 0,
    );
  });

  Future<void> _done() async {
    if (_changed) {
      setState(() => _saving = true);
      try {
        await ref.read(photoSeriesServiceProvider).setAlignment(_draft);
      } finally {
        if (mounted) setState(() => _saving = false);
      }
    }
    // A lock mid-save has already closed this; popping again would close
    // the page under it.
    if (mounted && (ModalRoute.of(context)?.isCurrent ?? false)) {
      Navigator.pop(context);
    }
  }

  Widget _photo(PhotoCheckInImage image, double aspect) => AlignedPhotoFrame(
    aspect: aspect,
    image: image,
    child: VaultPhoto(
      key: ValueKey(image.blobId),
      blobId: image.blobId,
      thumb: false,
      fit: BoxFit.contain,
      // The thumbnail while the full image decodes or downloads.
      placeholder: VaultPhoto(
        blobId: image.blobId,
        thumb: true,
        fit: BoxFit.contain,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    ref.listen(secureVaultSessionProvider, (_, session) {
      // Not once Done has closed this: it would close the page under it.
      if (session == null && (ModalRoute.of(context)?.isCurrent ?? false)) {
        Navigator.of(context).maybePop();
      }
    });
    final theme = Theme.of(context);
    final aspect = widget.angle.frameAspect ?? kDefaultPhotoFrameAspect;
    final reference = _reference;
    final takenOn = _at < 0 ? null : widget.frames[_at].checkIn.takenOn;
    final stageHeight = math.min(
      460.0,
      MediaQuery.sizeOf(context).height * 0.5,
    );
    return VaultActivity(
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
              _nudge(-1, 0),
          const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
              _nudge(1, 0),
          const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
              _nudge(0, -1),
          const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
              _nudge(0, 1),
          const SingleActivator(
            LogicalKeyboardKey.arrowLeft,
            shift: true,
          ): () =>
              _nudge(-10, 0),
          const SingleActivator(
            LogicalKeyboardKey.arrowRight,
            shift: true,
          ): () =>
              _nudge(10, 0),
          const SingleActivator(LogicalKeyboardKey.arrowUp, shift: true): () =>
              _nudge(0, -10),
          const SingleActivator(
            LogicalKeyboardKey.arrowDown,
            shift: true,
          ): () =>
              _nudge(0, 10),
        },
        child: Focus(
          autofocus: true,
          child: AlertDialog(
            title: Text(
              takenOn == null
                  ? 'Align ${widget.angle.name}'
                  : 'Align ${widget.angle.name} · '
                        '${DateFormat.yMMMd().format(takenOn)}',
            ),
            content: SizedBox(
              width: 520,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Shrinks to what the dialog has left, so a short window
                  // keeps the sliders and buttons clear of it (BUG-303).
                  Flexible(
                    child: SizedBox(
                      height: stageHeight,
                      child: LayoutBuilder(
                        builder: (context, box) {
                          final stage = box.biggest;
                          _frame = stage.width / stage.height > aspect
                              ? Size(stage.height * aspect, stage.height)
                              : Size(stage.width, stage.width / aspect);
                          return Listener(
                            onPointerSignal: (event) {
                              if (event is PointerScrollEvent) {
                                _transform(
                                  zoom: math.exp(-event.scrollDelta.dy / 400),
                                  focal: _fromCentre(
                                    event.localPosition,
                                    stage,
                                  ),
                                );
                              }
                            },
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onScaleStart: (_) {
                                _gestureScale = 1;
                                _gestureRotation = 0;
                              },
                              onScaleUpdate: (details) {
                                _transform(
                                  delta: details.focalPointDelta,
                                  zoom: details.scale / _gestureScale,
                                  turn: details.rotation - _gestureRotation,
                                  focal: _fromCentre(
                                    details.localFocalPoint,
                                    stage,
                                  ),
                                );
                                _gestureScale = details.scale;
                                _gestureRotation = details.rotation;
                              },
                              child: Center(
                                child: SizedBox.fromSize(
                                  size: _frame,
                                  child: Stack(
                                    fit: StackFit.expand,
                                    children: [
                                      ColoredBox(
                                        color: theme.colorScheme.onSurface
                                            .withValues(alpha: 0.06),
                                      ),
                                      if (reference != null)
                                        _photo(reference, aspect),
                                      Opacity(
                                        opacity: reference == null
                                            ? 1
                                            : _opacity,
                                        child: _photo(_draft, aspect),
                                      ),
                                      IgnorePointer(
                                        child: DecoratedBox(
                                          decoration: BoxDecoration(
                                            border: Border.all(
                                              color: theme.colorScheme.primary
                                                  .withValues(alpha: 0.6),
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
                        },
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (reference != null)
                    _SliderRow(
                      label: 'Opacity',
                      value: _opacity,
                      min: 0,
                      max: 1,
                      readout: '${(_opacity * 100).round()}%',
                      onChanged: (value) => setState(() => _opacity = value),
                    ),
                  _SliderRow(
                    label: 'Rotation',
                    value: _draft.alignRotation,
                    min: -_kMaxAlignRotation,
                    max: _kMaxAlignRotation,
                    readout:
                        '${(_draft.alignRotation * 180 / math.pi).toStringAsFixed(1)}°',
                    onChanged: (value) => _set(
                      rotation: value.abs() < _kRotationSnap ? 0 : value,
                    ),
                  ),
                  // Logarithmic, so 50% and 200% sit evenly either side of
                  // 100%. About the photo's centre, as Rotation turns it, so
                  // it doesn't move a photo already placed.
                  _SliderRow(
                    label: 'Zoom',
                    value: math.log(_draft.alignScale),
                    min: math.log(_kMinAlignScale),
                    max: math.log(_kMaxAlignScale),
                    readout: '${(_draft.alignScale * 100).round()}%',
                    onChanged: (value) => _transform(
                      zoom: math.exp(value) / _draft.alignScale,
                      focal: _offset,
                    ),
                  ),
                  Text(
                    'Drag to move, scroll or pinch to zoom, arrow keys to '
                    'nudge (Shift for more).',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            actions: [
              GlassButton(
                onPressed: _previous == null || _saving ? null : _copyPrevious,
                label: 'Copy from previous',
                dense: true,
              ),
              GlassButton(
                onPressed: _saving ? null : _reset,
                label: 'Reset',
                dense: true,
              ),
              GlassButton(
                onPressed: _saving ? null : () => Navigator.pop(context),
                label: 'Cancel',
                dense: true,
              ),
              GlassButton(
                onPressed: _saving ? null : _done,
                label: _saving ? 'Saving…' : 'Done',
                dense: true,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SliderRow extends StatelessWidget {
  const _SliderRow({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.readout,
    required this.onChanged,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final String readout;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      SizedBox(width: 72, child: Text(label)),
      Expanded(
        // Unfocusable, so the arrow keys keep nudging the photo after a drag
        // here instead of moving the slider.
        child: ExcludeFocus(
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            onChanged: onChanged,
          ),
        ),
      ),
      SizedBox(width: 52, child: Text(readout, textAlign: TextAlign.end)),
    ],
  );
}
