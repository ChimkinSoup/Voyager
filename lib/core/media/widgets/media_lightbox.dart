import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:super_clipboard/super_clipboard.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/media/widgets/media_image.dart';
import 'package:voyager/core/widgets/confirm_dialog.dart';
import 'package:voyager/domain/models/media_models.dart';

/// Opens the full-screen viewer on [assets], starting at [initialIndex].
///
/// Order is the caller's — the parent's image order — so swiping matches what
/// the user was just looking at rather than whatever order the rows came back
/// from the database in.
///
/// [onRemove] adds the trash action, for the surfaces where the viewer is the
/// only place an image can be taken off its parent — the journal's fan, whose
/// thumbnails are too small to carry a control of their own. The callback
/// detaches the asset from the parent; the confirmation is asked here, so
/// every surface asks it in the same words.
Future<void> showMediaLightbox(
  BuildContext context, {
  required List<MediaAsset> assets,
  int initialIndex = 0,
  Future<void> Function(MediaAsset asset)? onRemove,
  double viewportFraction = 1.0,
  List<String>? captions,
}) {
  if (assets.isEmpty) return Future<void>.value();
  assert(
    captions == null || captions.length == assets.length,
    'captions must line up one-for-one with assets',
  );
  _openLightboxes++;
  return Navigator.of(context, rootNavigator: true).push(
    PageRouteBuilder<void>(
      opaque: false,
      barrierColor: Colors.black87,
      barrierDismissible: true,
      barrierLabel: 'Close image',
      pageBuilder: (_, _, _) => _MediaLightbox(
        assets: assets,
        initialIndex: initialIndex,
        onRemove: onRemove,
        viewportFraction: viewportFraction,
        captions: captions,
      ),
      transitionsBuilder: (_, animation, _, child) =>
          FadeTransition(opacity: animation, child: child),
      transitionDuration: const Duration(milliseconds: 160),
    ),
  ).whenComplete(() => _openLightboxes--);
}

int _openLightboxes = 0;

/// Whether a viewer is on screen anywhere in the app.
///
/// The viewer is pushed on the *root* navigator, while the pages that open it
/// live inside a shell branch's own navigator. Their route therefore stays
/// the current one *of that branch*, and the route being non-opaque leaves
/// their [TickerMode] enabled too — so neither of the tests a
/// [HardwareKeyboard] handler uses to ask "am I the thing on screen" notices
/// the viewer covering it. Those handlers fire regardless of focus, so the
/// ones whose keys would act on the page underneath — flipping or grading a
/// study card, say — consult this as well.
bool get mediaLightboxIsOpen => _openLightboxes > 0;

class _MediaLightbox extends ConsumerStatefulWidget {
  const _MediaLightbox({
    required this.assets,
    required this.initialIndex,
    this.onRemove,
    this.viewportFraction = 1.0,
    this.captions,
  });

  final List<MediaAsset> assets;
  final int initialIndex;
  final Future<void> Function(MediaAsset asset)? onRemove;

  /// One line under each image, in step with [assets] — where a picture came
  /// from, for the surfaces that gather several owners' galleries into one
  /// run and would otherwise leave you guessing which entry you are looking
  /// at. Null everywhere the viewer shows a single owner's images.
  final List<String>? captions;

  /// Below 1 the neighbouring pages show at the edges — the "peek" a gallery
  /// wants so you can see there is more either side. Left at 1 everywhere the
  /// viewer is opened on a handful of images that already have a strip or a
  /// fan behind it.
  final double viewportFraction;

  @override
  ConsumerState<_MediaLightbox> createState() => _MediaLightboxState();
}

class _MediaLightboxState extends ConsumerState<_MediaLightbox> {
  late final PageController _pageController;
  late int _index;

  /// The viewer's own copy of the list, so a removal can drop the image and
  /// leave the viewer standing on the next one. The parent reloads its own
  /// rows off the media service's notification.
  late List<MediaAsset> _assets;

  /// Kept in step with [_assets] index for index, so a removal takes the
  /// caption with the picture it belonged to.
  late List<String>? _captions;

  /// One controller per page, so zooming one image and swiping away does not
  /// carry that zoom onto the next.
  final _transformControllers = <int, TransformationController>{};

  /// The swipe this viewer is running on the [PageView]'s behalf.
  ///
  /// The [InteractiveViewer] over each page hit-tests opaquely and its scale
  /// recognizer takes the gesture arena the moment a pointer moves, so the
  /// `PageView`'s own drag recognizer never sees a swipe. On desktop it would
  /// not see a mouse one in any case: `Scrollable` only accepts the drag
  /// devices its `ScrollBehavior` lists, and Material's list holds no mouse.
  ///
  /// Rather than fight the arena for a gesture the viewer has already won,
  /// its interaction callbacks are forwarded into a [Drag] on the page
  /// position — the very object [Scrollable] would have created — so the page
  /// still follows the pointer, snaps, and flings on its own physics.
  Drag? _pageDrag;

  @override
  void initState() {
    super.initState();
    _assets = [...widget.assets];
    _captions = widget.captions == null ? null : [...widget.captions!];
    _index = widget.initialIndex.clamp(0, _assets.length - 1);
    _pageController = PageController(
      initialPage: _index,
      viewportFraction: widget.viewportFraction,
    );
  }

  @override
  void dispose() {
    _pageDrag?.cancel();
    _pageController.dispose();
    for (final controller in _transformControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  MediaAsset get _current => _assets[_index];

  TransformationController _controllerFor(int index) {
    return _transformControllers.putIfAbsent(
      index,
      TransformationController.new,
    );
  }

  void _zoomBy(double factor) {
    final controller = _controllerFor(_index);
    final current = controller.value.getMaxScaleOnAxis();
    final target = (current * factor).clamp(1.0, 8.0);
    // Scaled about the centre rather than about the last pointer position:
    // the buttons have no pointer, and anchoring to the origin would walk the
    // image off-screen as it grew.
    controller.value = Matrix4.identity()..scaleByDouble(
      target,
      target,
      target,
      1,
    );
  }

  /// Whether the page at [index] is magnified, and so owns its own drag.
  bool _isZoomed(int index) {
    return _controllerFor(index).value.getMaxScaleOnAxis() > 1.001;
  }

  void _onInteractionStart(int index, ScaleStartDetails details) {
    // A magnified page keeps the gesture for itself: dragging a zoomed image
    // walks around it rather than turning the page. With a single image there
    // is no page to turn to at all.
    if (_assets.length < 2 ||
        _isZoomed(index) ||
        !_pageController.hasClients ||
        _pageDrag != null) {
      return;
    }
    _pageDrag = _pageController.position.drag(
      DragStartDetails(
        globalPosition: details.focalPoint,
        localPosition: details.localFocalPoint,
      ),
      () => _pageDrag = null,
    );
  }

  void _onInteractionUpdate(ScaleUpdateDetails details) {
    final drag = _pageDrag;
    if (drag == null) return;
    // A second finger means the gesture was a pinch all along. The page is
    // handed back where it stood so the viewer can scale instead.
    if (details.pointerCount > 1) {
      _pageDrag = null;
      drag.cancel();
      return;
    }
    // Only the horizontal component: the pages lie along one axis, and a
    // diagonal drag should not drift the page by its vertical part.
    final dx = details.focalPointDelta.dx;
    drag.update(
      DragUpdateDetails(
        globalPosition: details.focalPoint,
        localPosition: details.localFocalPoint,
        delta: Offset(dx, 0),
        primaryDelta: dx,
      ),
    );
  }

  void _onInteractionEnd(ScaleEndDetails details) {
    final drag = _pageDrag;
    if (drag == null) return;
    _pageDrag = null;
    // Handing the velocity on is what makes a flick carry to the next image
    // while a slow drag that stopped short falls back to the one it left.
    final dx = details.velocity.pixelsPerSecond.dx;
    drag.end(
      DragEndDetails(
        velocity: Velocity(pixelsPerSecond: Offset(dx, 0)),
        primaryVelocity: dx,
      ),
    );
    _keepPagesTouchable();
  }

  /// Lets a pointer through to the pages while the [PageView] is settling.
  ///
  /// `Scrollable` wraps its viewport in an `IgnorePointer` for the whole of a
  /// ballistic or driven activity, so from the moment a swipe is released
  /// until the incoming image has finished sliding into place nothing in the
  /// viewer is hit-testable — the picture is on screen, under the pointer, and
  /// deaf. The blocking is a property of the activity rather than a setting,
  /// but the flag it drives is a plain field on the scroll context, so it can
  /// simply be turned back off after the activity has begun. Doing so leaves
  /// the settle running and the `InteractiveViewer` reachable, and grabbing it
  /// starts a fresh drag that supersedes the animation mid-flight.
  ///
  /// Must be called *after* whatever started the activity: `beginActivity`
  /// sets the flag itself. It never has to be undone — the position settling
  /// back to idle sets the flag to false again on its own, and a drag that
  /// interrupts the settle is a drag the pointer is already inside.
  void _keepPagesTouchable() {
    if (!_pageController.hasClients) return;
    _pageController.position.context.setIgnorePointer(false);
  }

  Future<Uint8List?> _currentBytes() {
    return ref.read(mediaServiceProvider).bytesFor(_current);
  }

  Future<void> _copyImage() async {
    final messenger = ScaffoldMessenger.of(context);
    final bytes = await _currentBytes();
    if (bytes == null) {
      messenger.showSnackBar(
        const SnackBar(content: Text('This image is not on this device yet.')),
      );
      return;
    }
    final clipboard = SystemClipboard.instance;
    if (clipboard == null) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Copying images is not supported here.')),
      );
      return;
    }
    final item = DataWriterItem();
    // Written in the asset's own format rather than converted: the receiving
    // application gets exactly the bytes on disk.
    if (_current.mimeType == MediaImageFormat.png.mimeType) {
      item.add(Formats.png(bytes));
    } else {
      item.add(Formats.jpeg(bytes));
    }
    await clipboard.write([item]);
    messenger.showSnackBar(const SnackBar(content: Text('Image copied.')));
  }

  Future<void> _saveAs() async {
    final messenger = ScaffoldMessenger.of(context);
    final bytes = await _currentBytes();
    if (bytes == null) {
      messenger.showSnackBar(
        const SnackBar(content: Text('This image is not on this device yet.')),
      );
      return;
    }
    final format = MediaImageFormat.fromMimeType(_current.mimeType);
    final extension = format?.extension ?? 'jpg';
    // saveFile rather than getDirectoryPath — see the export tile in
    // settings_page.dart for why the latter takes the process down on Windows.
    final targetPath = await FilePicker.platform.saveFile(
      dialogTitle: 'Save image',
      fileName: 'voyager_image_${_current.contentHash.substring(0, 8)}'
          '.$extension',
      type: FileType.custom,
      allowedExtensions: [extension],
    );
    if (targetPath == null) return;
    await File(targetPath).writeAsBytes(bytes);
    messenger.showSnackBar(SnackBar(content: Text('Saved to $targetPath')));
  }

  Future<void> _remove() async {
    final onRemove = widget.onRemove;
    if (onRemove == null) return;
    final asset = _current;
    final confirmed = await showConfirmDialog(
      context,
      title: 'Remove image',
      message:
          'The image is removed from this item. It is kept for 30 days before '
          'being deleted for good.',
      confirmLabel: 'Remove',
    );
    if (!confirmed || !mounted) return;
    await onRemove(asset);
    if (!mounted) return;
    final index = _assets.indexOf(asset);
    if (index < 0) return;
    if (_assets.length == 1) {
      Navigator.of(context).maybePop();
      return;
    }
    setState(() {
      _assets = [..._assets]..removeAt(index);
      _captions = _captions == null
          ? null
          : ([..._captions!]..removeAt(index));
      // Stand on the image that took its place, or on the new last one when
      // the removed image was itself last.
      _index = index.clamp(0, _assets.length - 1);
    });
    // The controller is what the PageView actually reads: without this it
    // keeps showing the page at the old index, which is now a different
    // image than [_index] names.
    _pageController.jumpToPage(_index);
  }

  @override
  Widget build(BuildContext context) {
    final assets = _assets;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(context).maybePop(),
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () {
          _pageController.previousPage(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
          );
          _keepPagesTouchable();
        },
        const SingleActivator(LogicalKeyboardKey.arrowRight): () {
          _pageController.nextPage(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
          );
          _keepPagesTouchable();
        },
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: Stack(
            children: [
              PageView.builder(
                controller: _pageController,
                itemCount: assets.length,
                // Builds the pages on either side of this one a whole swipe
                // early, so their bytes are off disk and decoded before the
                // slide starts. Without it the incoming page is created as
                // the animation begins and only resolves its image after it
                // has finished — the picture appearing in an empty frame
                // rather than sliding in.
                allowImplicitScrolling: true,
                onPageChanged: (index) => setState(() => _index = index),
                itemBuilder: (context, index) {
                  final caption = _captions?[index];
                  // The dismiss target lives *inside* the viewer rather than
                  // in a `Positioned.fill` under the `PageView`. An
                  // `InteractiveViewer` wraps its content in a
                  // `GestureDetector` with `HitTestBehavior.opaque` — needed
                  // so a pan that leaves the child still tracks — which means
                  // it swallows every pointer across the whole screen and
                  // nothing beneath it can ever be tapped.
                  final page = InteractiveViewer(
                    transformationController: _controllerFor(index),
                    minScale: 1,
                    maxScale: 8,
                    // At 1x the viewer's own pan is clamped to nothing — the
                    // picture already fits its boundary — so these hand the
                    // otherwise wasted drag to the page position. Left on
                    // rather than gated so a zoomed page still pans.
                    onInteractionStart: (details) =>
                        _onInteractionStart(index, details),
                    onInteractionUpdate: _onInteractionUpdate,
                    onInteractionEnd: _onInteractionEnd,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => Navigator.of(context).maybePop(),
                      child: Center(
                        child: Padding(
                          padding: const EdgeInsets.all(48),
                          // Taps that land on the picture itself are absorbed
                          // here: the nested recognizer wins the arena over
                          // the one above, so only the surrounding dead space
                          // closes the viewer. A pan still reaches the
                          // `InteractiveViewer`, which claims the arena the
                          // moment the pointer moves.
                          child: GestureDetector(
                            onTap: () {},
                            child: MediaImage(
                              asset: assets[index],
                              fit: BoxFit.contain,
                              borderRadius: BorderRadius.zero,
                              // The viewer above zooms to 8x, so this is the
                              // one place that needs every ingest pixel.
                              decodeFullResolution: true,
                            ),
                          ),
                        ),
                      ),
                    ),
                  );

                  if (caption == null) return page;
                  // Outside the [InteractiveViewer] rather than inside it: a
                  // caption is a label on the picture, not part of it, and
                  // zooming in to read a detail should not blow the words up
                  // with it.
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(child: page),
                      Padding(
                        // Clears the page counter, which sits 24 off the
                        // bottom across the whole viewer.
                        padding: EdgeInsets.fromLTRB(
                          24,
                          0,
                          24,
                          assets.length > 1 ? 56 : 24,
                        ),
                        child: Text(
                          caption,
                          textAlign: TextAlign.center,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
              Positioned(
                top: 16,
                right: 16,
                child: _LightboxActions(
                  onZoomIn: () => _zoomBy(1.4),
                  onZoomOut: () => _zoomBy(1 / 1.4),
                  onCopy: _copyImage,
                  onSave: _saveAs,
                  onRemove: widget.onRemove == null ? null : _remove,
                  onClose: () => Navigator.of(context).maybePop(),
                ),
              ),
              if (assets.length > 1)
                Positioned(
                  bottom: 24,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        '${_index + 1} / ${assets.length}',
                        style: const TextStyle(color: Colors.white),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LightboxActions extends StatelessWidget {
  const _LightboxActions({
    required this.onZoomIn,
    required this.onZoomOut,
    required this.onCopy,
    required this.onSave,
    required this.onRemove,
    required this.onClose,
  });

  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;
  final Future<void> Function() onCopy;
  final Future<void> Function() onSave;

  /// Null on the surfaces that own removal themselves, where the viewer is
  /// read-only.
  final Future<void> Function()? onRemove;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _LightboxAction(
            icon: PhosphorIconsRegular.magnifyingGlassMinus,
            tooltip: 'Zoom out',
            onPressed: onZoomOut,
          ),
          _LightboxAction(
            icon: PhosphorIconsRegular.magnifyingGlassPlus,
            tooltip: 'Zoom in',
            onPressed: onZoomIn,
          ),
          _LightboxAction(
            icon: PhosphorIconsRegular.copy,
            tooltip: 'Copy image',
            onPressed: () => onCopy(),
          ),
          _LightboxAction(
            icon: PhosphorIconsRegular.downloadSimple,
            tooltip: 'Save as…',
            onPressed: () => onSave(),
          ),
          if (onRemove != null)
            _LightboxAction(
              icon: PhosphorIconsRegular.trash,
              tooltip: 'Remove image',
              onPressed: () => onRemove!(),
            ),
          _LightboxAction(
            icon: PhosphorIconsRegular.x,
            tooltip: 'Close',
            onPressed: onClose,
          ),
        ],
      ),
    );
  }
}

class _LightboxAction extends StatelessWidget {
  const _LightboxAction({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(icon, color: Colors.white),
      tooltip: tooltip,
      onPressed: onPressed,
      // Explicit rather than the default overlay, which resolves against the
      // theme's `onSurfaceVariant` at 8% — invisible on the black chrome
      // these buttons sit on, so the row gave no hover feedback at all.
      style: IconButton.styleFrom(
        hoverColor: Colors.white.withValues(alpha: 0.18),
        focusColor: Colors.white.withValues(alpha: 0.18),
        highlightColor: Colors.white.withValues(alpha: 0.28),
      ),
    );
  }
}
