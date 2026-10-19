import 'dart:io';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/core/widgets/confirm_dialog.dart';
import 'package:voyager/domain/models/photo_series_models.dart';
import 'package:voyager/features/notifications/secure_vault_session.dart';
import 'package:voyager/features/photo_series/photo_align_editor.dart';
import 'package:voyager/features/photo_series/photo_frame.dart';
import 'package:voyager/features/photo_series/photo_series_playback.dart';
import 'package:voyager/features/photo_series/photo_series_providers.dart';
import 'package:voyager/features/photo_series/vault_activity.dart';
import 'package:voyager/features/photo_series/vault_image_cache.dart';

/// Whether check-ins are taken with the camera (PHOTO_SERIES_HLD.md §9):
/// Android only in v1. Windows imports files. Tests turn it on.
bool photoCaptureSupported = Platform.isAndroid;

/// The ghost's opacity until the user moves the slider (§18).
const _kDefaultGhostOpacity = 0.35;
const _kMaxGhostOpacity = 0.7;

/// [angleId]'s photos in [snapshot], oldest first — as the grid orders
/// check-ins, by date and then by when they were made.
List<PhotoFrameEntry> photoAngleFrames(
  PhotoSeriesSnapshot snapshot,
  String angleId,
) {
  final checkIns = {
    for (final checkIn in snapshot.checkIns) checkIn.id: checkIn,
  };
  return [
    for (final image in snapshot.images)
      if (image.angleId == angleId)
        if (checkIns[image.checkInId] case final checkIn?)
          (checkIn: checkIn, image: image),
  ]..sort((a, b) {
    final byDate = a.checkIn.takenOn.compareTo(b.checkIn.takenOn);
    return byDate != 0
        ? byDate
        : a.checkIn.createdAt.compareTo(b.checkIn.createdAt);
  });
}

/// The photo a capture of [angle] is lined up against (§9): the angle's
/// latest, or its reference with [reference]. Null while it has none.
/// [frames] are the angle's photos, oldest first.
PhotoFrameEntry? photoGhostFrame(
  PhotoSeriesAngle angle,
  List<PhotoFrameEntry> frames, {
  required bool reference,
}) => reference ? photoReferenceFrame(angle, frames) : frames.lastOrNull;

/// [file]'s bytes, with the file deleted first thing: the camera writes each
/// capture to a temp file, and no plain photo may stay on disk (§6.3).
Future<Uint8List> takeCapturedPhoto(XFile file) async {
  try {
    return await file.readAsBytes();
  } finally {
    try {
      await File(file.path).delete();
    } on PathNotFoundException {
      // Already gone, which is all that's wanted.
    }
  }
}

/// The capture screen (§9), one step per angle of [angles]: a photo taken,
/// retaken or skipped for each, over a ghost of an earlier one. Comes back
/// with the photos by angle id — still plain, in memory only — or null when
/// closed, or when the vault locks.
Future<Map<String, Uint8List>?> showPhotoCaptureScreen(
  BuildContext context, {
  required List<PhotoSeriesAngle> angles,
}) => Navigator.of(context, rootNavigator: true).push(
  MaterialPageRoute(
    fullscreenDialog: true,
    builder: (_) => _CaptureScreen(angles: angles),
  ),
);

class _CaptureScreen extends ConsumerStatefulWidget {
  const _CaptureScreen({required this.angles});

  final List<PhotoSeriesAngle> angles;

  @override
  ConsumerState<_CaptureScreen> createState() => _CaptureScreenState();
}

class _CaptureScreenState extends ConsumerState<_CaptureScreen>
    with WidgetsBindingObserver {
  final _taken = <String, Uint8List>{};
  var _step = 0;

  /// The photo just taken, waiting on Retake or Use.
  Uint8List? _shot;

  List<CameraDescription> _cameras = const [];
  CameraController? _controller;
  CameraDescription? _lastCamera;

  /// The camera was given up for the background, or the user sent to
  /// Settings to allow it, or it had failed when the app left: to be opened
  /// again on return.
  bool _released = false;
  bool _denied = false;
  String? _error;
  bool _shooting = false;

  bool _ghostShown = true;
  bool _ghostReference = false;
  double _ghostOpacity = _kDefaultGhostOpacity;

  PhotoSeriesAngle get _angle => widget.angles[_step];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _open(null);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    super.dispose();
  }

  /// Gives up the camera in the background, as Android expects, and takes it
  /// back on return — also after a trip to Settings to allow it.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = _controller;
    // Hidden, not inactive: the permission prompt makes the app inactive
    // while the camera is starting, and only leaving the app hides it.
    if (state == AppLifecycleState.hidden) {
      if (controller == null) {
        // Denied or failed: tried again on return, however the user went to
        // Settings. Not while starting, which carries on by itself.
        if (_denied || _error != null) _released = true;
        return;
      }
      _controller = null;
      _released = true;
      controller.dispose();
      setState(() {});
    } else if (state == AppLifecycleState.resumed && _released) {
      _released = false;
      _open(_lastCamera);
    }
  }

  void _openSettings() {
    _released = true;
    // Opens this app's settings page; nothing to do with location.
    Geolocator.openAppSettings();
  }

  /// Starts [camera], or the first back camera without one.
  Future<void> _open(CameraDescription? camera) async {
    CameraController? controller;
    try {
      if (_cameras.isEmpty) _cameras = await availableCameras();
      if (_cameras.isEmpty) {
        if (mounted) setState(() => _error = 'This device has no camera.');
        return;
      }
      // Left while finding the cameras, too early for the hidden event to
      // give anything up: started on return instead.
      if (WidgetsBinding.instance.lifecycleState
          case AppLifecycleState.hidden || AppLifecycleState.paused) {
        _released = true;
        return;
      }
      camera ??= _cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => _cameras.first,
      );
      _lastCamera = camera;
      controller = CameraController(
        camera,
        ResolutionPreset.veryHigh,
        enableAudio: false,
      );
      _controller = controller;
      await controller.initialize();
      if (!mounted || _controller != controller) return;
      setState(() {
        _denied = false;
        _error = null;
      });
    } on CameraException catch (error) {
      // Given up for the background while starting: the return reopens it.
      if (!mounted || _controller != controller) return;
      controller?.dispose();
      _controller = null;
      setState(() {
        // CameraAccessDenied, …WithoutPrompt, …Restricted.
        _denied = error.code.startsWith('CameraAccess');
        _error = _denied ? null : 'The camera could not start.';
      });
    }
  }

  Future<void> _switchCamera() async {
    final controller = _controller;
    if (controller == null || _shooting) return;
    final facing = controller.description.lensDirection;
    final other = _cameras.where((c) => c.lensDirection != facing).firstOrNull;
    if (other == null) return;
    try {
      await controller.setDescription(other);
      _lastCamera = other;
    } on CameraException {
      _failed('The camera could not be switched.');
    }
    if (mounted) setState(() {});
  }

  void _failed(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _shoot() async {
    final controller = _controller;
    if (controller == null || _shooting) return;
    setState(() => _shooting = true);
    try {
      final file = await controller.takePicture();
      // Read and gone even if the screen has closed meanwhile.
      final bytes = await takeCapturedPhoto(file);
      if (mounted) setState(() => _shot = bytes);
    } on CameraException {
      _failed('The photo could not be taken.');
    } on FileSystemException {
      _failed('The photo could not be taken.');
    } finally {
      if (mounted) setState(() => _shooting = false);
    }
  }

  bool get _hasPhotos => _taken.isNotEmpty || _shot != null;

  /// Close and the back gesture: asks first when there are photos to lose.
  Future<void> _close() async {
    if (_hasPhotos &&
        !await showConfirmDialog(
          context,
          title: 'Discard photos?',
          message: 'The photos taken so far are not kept.',
          confirmLabel: 'Discard',
        )) {
      return;
    }
    if (mounted) Navigator.pop(context);
  }

  /// To the next angle, keeping [_shot] for this one when there is one; past
  /// the last, back with everything taken.
  void _next({required bool keep}) {
    final shot = _shot;
    if (keep && shot != null) _taken[_angle.id] = shot;
    if (_step == widget.angles.length - 1) {
      // Every angle skipped is as good as closed.
      Navigator.pop(context, _taken.isEmpty ? null : _taken);
      return;
    }
    setState(() {
      _shot = null;
      _step++;
    });
  }

  @override
  Widget build(BuildContext context) {
    // A lock takes the photos with it: nothing could be sealed any more.
    ref.listen(secureVaultSessionProvider, (_, session) {
      final route = ModalRoute.of(context);
      if (session != null || route == null || !route.isActive) return;
      // With the Discard prompt, when it's up.
      Navigator.of(context)
        ..popUntil((r) => r == route)
        ..pop();
    });
    final snapshot = ref.watch(photoSeriesSnapshotProvider).valueOrNull;
    final frames = snapshot == null
        ? const <PhotoFrameEntry>[]
        : photoAngleFrames(snapshot, _angle.id);
    final hasReference =
        frames.length > 1 &&
        photoReferenceFrame(_angle, frames) != frames.lastOrNull;
    final ghost = photoGhostFrame(
      _angle,
      frames,
      reference: _ghostReference && hasReference,
    );
    final shot = _shot;
    final steps = widget.angles.length;
    final dark = ThemeData.dark();
    return VaultActivity(
      child: PopScope(
        canPop: !_hasPhotos,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _close();
        },
        child: Theme(
          data: dark,
          child: Scaffold(
            backgroundColor: Colors.black,
            body: SafeArea(
              child: Column(
                children: [
                  Row(
                    children: [
                      IconButton(
                        tooltip: 'Close',
                        onPressed: _close,
                        icon: const Icon(PhosphorIconsRegular.x),
                      ),
                      Expanded(
                        child: Text(
                          steps == 1
                              ? _angle.name
                              : '${_angle.name} · ${_step + 1} of $steps',
                          textAlign: TextAlign.center,
                          style: dark.textTheme.titleMedium,
                        ),
                      ),
                      TextButton(
                        onPressed: shot == null
                            ? () => _next(keep: false)
                            : null,
                        child: const Text('Skip'),
                      ),
                    ],
                  ),
                  Expanded(
                    child: Center(
                      child: shot != null
                          ? PlainPhotoPreview(bytes: shot)
                          : _viewfinder(ghost),
                    ),
                  ),
                  if (shot == null && ghost != null && _ghostShown)
                    _GhostControls(
                      opacity: _ghostOpacity,
                      reference: _ghostReference && hasReference,
                      hasReference: hasReference,
                      onOpacity: (value) =>
                          setState(() => _ghostOpacity = value),
                      onReference: (value) =>
                          setState(() => _ghostReference = value),
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
                    child: shot != null
                        ? Row(
                            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                            children: [
                              OutlinedButton.icon(
                                onPressed: () => setState(() => _shot = null),
                                icon: const Icon(
                                  PhosphorIconsRegular.arrowCounterClockwise,
                                ),
                                label: const Text('Retake'),
                              ),
                              FilledButton.icon(
                                onPressed: () => _next(keep: true),
                                icon: const Icon(PhosphorIconsRegular.check),
                                label: const Text('Use photo'),
                              ),
                            ],
                          )
                        : Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              IconButton(
                                tooltip: _ghostShown
                                    ? 'Hide ghost'
                                    : 'Show ghost',
                                onPressed: ghost == null
                                    ? null
                                    : () => setState(
                                        () => _ghostShown = !_ghostShown,
                                      ),
                                icon: Icon(
                                  _ghostShown
                                      ? PhosphorIconsFill.ghost
                                      : PhosphorIconsRegular.ghost,
                                ),
                              ),
                              _Shutter(
                                onPressed:
                                    _controller?.value.isInitialized == true &&
                                        !_shooting
                                    ? _shoot
                                    : null,
                              ),
                              IconButton(
                                tooltip: 'Switch camera',
                                onPressed: _cameras.length > 1 && !_shooting
                                    ? _switchCamera
                                    : null,
                                icon: const Icon(
                                  PhosphorIconsRegular.cameraRotate,
                                ),
                              ),
                            ],
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

  Widget _viewfinder(PhotoFrameEntry? ghost) {
    final controller = _controller;
    if (_denied) {
      return Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Voyager needs the camera to take check-in photos. Allow it in '
              'Settings, then come back.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _openSettings,
              child: const Text('Open settings'),
            ),
          ],
        ),
      );
    }
    if (_error case final error?) return Text(error);
    if (controller == null || !controller.value.isInitialized) {
      return const CircularProgressIndicator();
    }
    final mirrored =
        controller.description.lensDirection == CameraLensDirection.front;
    return Stack(
      children: [
        CameraPreview(controller),
        Positioned.fill(
          child: IgnorePointer(
            child: ghost == null
                ? const CustomPaint(painter: _ThirdsPainter())
                : _ghostShown
                ? Opacity(
                    opacity: _ghostOpacity,
                    // The front camera's preview is mirrored; so is its ghost,
                    // though the photo taken isn't (§9).
                    child: Transform.flip(
                      flipX: mirrored,
                      child: _Ghost(
                        frame: ghost,
                        aspect: _angle.frameAspect ?? kDefaultPhotoFrameAspect,
                      ),
                    ),
                  )
                : null,
          ),
        ),
      ],
    );
  }
}

/// An earlier photo where the aligned series draws it. A photo taken now is
/// fitted inside the angle's frame with no transform (§10), so the frame is
/// laid out around the preview the same way, and clipped to it.
class _Ghost extends StatelessWidget {
  const _Ghost({required this.frame, required this.aspect});

  final PhotoFrameEntry frame;
  final double aspect;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final preview = box.biggest;
      final size = aspect > preview.aspectRatio
          ? Size(preview.height * aspect, preview.height)
          : Size(preview.width, preview.width / aspect);
      return ClipRect(
        child: OverflowBox(
          minWidth: size.width,
          maxWidth: size.width,
          minHeight: size.height,
          maxHeight: size.height,
          child: AlignedPhotoFrame(
            aspect: aspect,
            image: frame.image,
            child: VaultPhoto(
              key: ValueKey(frame.image.blobId),
              blobId: frame.image.blobId,
              thumb: false,
              fit: BoxFit.contain,
              // Until the full image is here.
              placeholder: VaultPhoto(
                blobId: frame.image.blobId,
                thumb: true,
                fit: BoxFit.contain,
                placeholder: const SizedBox.shrink(),
              ),
            ),
          ),
        ),
      );
    },
  );
}

class _GhostControls extends StatelessWidget {
  const _GhostControls({
    required this.opacity,
    required this.reference,
    required this.hasReference,
    required this.onOpacity,
    required this.onReference,
  });

  final double opacity;
  final bool reference;
  final bool hasReference;
  final ValueChanged<double> onOpacity;
  final ValueChanged<bool> onReference;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16),
    child: Row(
      children: [
        Expanded(
          child: Slider(
            value: opacity,
            max: _kMaxGhostOpacity,
            label: '${(opacity * 100).round()}%',
            divisions: 14,
            onChanged: onOpacity,
          ),
        ),
        // The latest photo and the reference are one and the same until
        // another is chosen, or taken.
        if (hasReference)
          SegmentedButton<bool>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: false, label: Text('Latest')),
              ButtonSegment(value: true, label: Text('Reference')),
            ],
            selected: {reference},
            onSelectionChanged: (selected) => onReference(selected.single),
          ),
      ],
    ),
  );
}

class _Shutter extends StatelessWidget {
  const _Shutter({required this.onPressed});

  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: 'Take photo',
    child: GestureDetector(
      onTap: onPressed,
      child: Container(
        width: 72,
        height: 72,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 4),
        ),
        padding: const EdgeInsets.all(5),
        child: DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: onPressed == null ? Colors.white38 : Colors.white,
          ),
        ),
      ),
    ),
  );
}

/// A faint rule-of-thirds grid, for an angle's first photo (§9).
class _ThirdsPainter extends CustomPainter {
  const _ThirdsPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white24
      ..strokeWidth = 1;
    for (final t in const [1 / 3, 2 / 3]) {
      canvas
        ..drawLine(
          Offset(size.width * t, 0),
          Offset(size.width * t, size.height),
          paint,
        )
        ..drawLine(
          Offset(0, size.height * t),
          Offset(size.width, size.height * t),
          paint,
        );
    }
  }

  @override
  bool shouldRepaint(_ThirdsPainter oldDelegate) => false;
}
