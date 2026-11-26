import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:super_clipboard/super_clipboard.dart';
import 'package:voyager/core/media/widgets/media_image.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/domain/models/media_models.dart';
import 'package:voyager/features/gaia/companion/gaia_button.dart';
import 'package:voyager/features/gaia/companion/gaia_style.dart';
import 'package:voyager/features/gaia/companion/gaia_toast.dart';

/// One picture in Gaia's lightbox: a chat's attachment, or a study sample.
abstract class GaiaLightboxPicture {
  /// Shown in the caption.
  String get name;

  /// Its pixels, to fit it to the screen before it has loaded.
  Size get size;

  /// The picture, filling a box of [size]'s shape.
  Widget build(BuildContext context);

  /// Its bytes and format, for Copy and Save; null while they aren't on this
  /// device.
  Future<({Uint8List bytes, MediaImageFormat? format})?> read();

  /// The file name Save suggests, without its extension.
  String get saveName;
}

/// Opens Gaia's lightbox on [images], starting at [initial], each named by
/// its `[image N]`. [imageFile] resolves each to its file, as in the chat.
Future<void> showGaiaLightbox(
  BuildContext context, {
  required List<GaiaImagePart> images,
  required int initial,
  required Future<String?> Function(String mediaId) imageFile,
}) => showGaiaPictures(
  context,
  pictures: [for (final image in images) _ChatPicture(image, imageFile)],
  initial: initial,
);

/// Opens Gaia's lightbox on [pictures]: the picture over a blurred,
/// darkened chat, a frosted toolbar and filmstrip, and arrows either side.
Future<void> showGaiaPictures(
  BuildContext context, {
  required List<GaiaLightboxPicture> pictures,
  required int initial,
}) => showGeneralDialog<void>(
  context: context,
  barrierColor: Colors.transparent,
  barrierLabel: 'Close',
  transitionDuration: GaiaMotion.move,
  pageBuilder: (context, animation, _) =>
      _Lightbox(pictures: pictures, initial: initial, animation: animation),
);

class _ChatPicture implements GaiaLightboxPicture {
  _ChatPicture(this.image, this.imageFile);

  final GaiaImagePart image;
  final Future<String?> Function(String mediaId) imageFile;

  @override
  String get name => gaiaImageToken(image.label);

  @override
  Size get size => Size(
    image.width.clamp(1, 1 << 20).toDouble(),
    image.height.clamp(1, 1 << 20).toDouble(),
  );

  late final ImageProvider _provider = MediaAssetImage(image.mediaId, _bytes);

  Future<Uint8List?> _bytes() async {
    final path = await imageFile(image.mediaId);
    return path == null ? null : File(path).readAsBytes();
  }

  @override
  Widget build(BuildContext context) => Image(
    image: _provider,
    fit: BoxFit.cover,
    gaplessPlayback: true,
    // Not on this device yet.
    errorBuilder: (context, _, _) =>
        const Icon(Icons.image_outlined, color: GaiaInk.faint, size: 48),
  );

  @override
  Future<({Uint8List bytes, MediaImageFormat? format})?> read() async {
    final path = await imageFile(image.mediaId);
    if (path == null) return null;
    return (
      bytes: await File(path).readAsBytes(),
      format: MediaImageFormat.fromPath(path),
    );
  }

  @override
  String get saveName => 'gaia_image_${image.label}';
}

class _Lightbox extends StatefulWidget {
  const _Lightbox({
    required this.pictures,
    required this.initial,
    required this.animation,
  });

  final List<GaiaLightboxPicture> pictures;
  final int initial;

  /// Its route's: the backdrop fades in, the picture grows in.
  final Animation<double> animation;

  @override
  State<_Lightbox> createState() => _LightboxState();
}

class _LightboxState extends State<_Lightbox>
    with SingleTickerProviderStateMixin {
  List<GaiaLightboxPicture> get _pictures => widget.pictures;
  late var _index = widget.initial;
  final _transform = TransformationController();

  /// Eases the zoom to where a button, key or double click sends it.
  late final _zoom = AnimationController(vsync: this, duration: GaiaMotion.move)
    ..addListener(_onZoom);
  Matrix4Tween? _zoomTween;

  /// The viewer's size, to zoom about its centre.
  var _viewport = Size.zero;
  Offset? _doubleTapAt;
  var _barHovered = false;

  static const _maxScale = 8.0;

  @override
  void dispose() {
    _zoom.dispose();
    _transform.dispose();
    super.dispose();
  }

  double get _scale => _transform.value.getMaxScaleOnAxis();

  void _onZoom() {
    final tween = _zoomTween;
    if (tween == null) return;
    _transform.value = tween.evaluate(
      CurvedAnimation(parent: _zoom, curve: GaiaMotion.travel),
    );
  }

  void _animateTo(Matrix4 target) {
    _zoomTween = Matrix4Tween(begin: _transform.value.clone(), end: target);
    _zoom.forward(from: 0);
  }

  /// [factor] times the zoom, about [at] in the viewer (its centre when
  /// null), held between fitting and [_maxScale].
  void _zoomBy(double factor, {Offset? at}) {
    final scale = _scale;
    final target = (scale * factor).clamp(1.0, _maxScale);
    if (target <= 1.001) {
      _animateTo(Matrix4.identity());
      return;
    }
    final f = target / scale;
    final c = at ?? _viewport.center(Offset.zero);
    _animateTo(
      Matrix4.translationValues(c.dx, c.dy, 0)
        ..multiply(Matrix4.diagonal3Values(f, f, 1))
        ..multiply(Matrix4.translationValues(-c.dx, -c.dy, 0))
        ..multiply(_transform.value),
    );
  }

  void _go(int index) {
    if (index < 0 || index >= _pictures.length || index == _index) return;
    _zoom.stop();
    _transform.value = Matrix4.identity();
    setState(() => _index = index);
  }

  void _close() => Navigator.of(context).maybePop();

  void _toast(String title, String body, GaiaToastMark mark) =>
      showGaiaToast(context, title: title, body: body, mark: mark);

  /// The picture showing, its bytes and format; a toast instead when they
  /// aren't on this device.
  Future<({Uint8List bytes, MediaImageFormat? format})?> _read() async {
    final file = await _pictures[_index].read();
    if (file == null && mounted) {
      _toast(
        'Not here yet',
        'This image is not on this device yet.',
        GaiaToastMark.error,
      );
    }
    return file;
  }

  Future<void> _copy() async {
    final clipboard = SystemClipboard.instance;
    if (clipboard == null) {
      _toast(
        'Not copied',
        'Copying images is not supported here.',
        GaiaToastMark.error,
      );
      return;
    }
    final file = await _read();
    if (file == null) return;
    // In the picture's own format, not converted.
    final item = DataWriterItem()
      ..add(
        file.format == MediaImageFormat.png
            ? Formats.png(file.bytes)
            : Formats.jpeg(file.bytes),
      );
    await clipboard.write([item]);
    if (mounted) {
      _toast('Copied', 'The image is on the clipboard.', GaiaToastMark.done);
    }
  }

  Future<void> _save() async {
    final picture = _pictures[_index];
    final file = await _read();
    if (file == null) return;
    final extension = file.format?.extension ?? 'jpg';
    // saveFile rather than getDirectoryPath: see the export tile in
    // settings_page.dart for why the latter takes the process down on Windows.
    final path = await FilePicker.platform.saveFile(
      dialogTitle: 'Save image',
      fileName: '${picture.saveName}.$extension',
      type: FileType.custom,
      allowedExtensions: [extension],
    );
    if (path == null) return;
    await File(path).writeAsBytes(file.bytes);
    if (mounted) _toast('Saved', path, GaiaToastMark.done);
  }

  @override
  Widget build(BuildContext context) {
    final picture = _pictures[_index];
    final curved = CurvedAnimation(
      parent: widget.animation,
      curve: GaiaMotion.curve,
    );
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): _close,
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
            _go(_index - 1),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
            _go(_index + 1),
        const SingleActivator(LogicalKeyboardKey.equal): () => _zoomBy(1.5),
        const SingleActivator(LogicalKeyboardKey.add): () => _zoomBy(1.5),
        const SingleActivator(LogicalKeyboardKey.numpadAdd): () => _zoomBy(1.5),
        const SingleActivator(LogicalKeyboardKey.minus): () => _zoomBy(1 / 1.5),
        const SingleActivator(LogicalKeyboardKey.numpadSubtract): () =>
            _zoomBy(1 / 1.5),
        const SingleActivator(LogicalKeyboardKey.digit0): () =>
            _animateTo(Matrix4.identity()),
      },
      child: Focus(
        autofocus: true,
        child: Material(
          type: MaterialType.transparency,
          child: Stack(
            children: [
              // The chat, blurred and darkened behind.
              Positioned.fill(
                child: FadeTransition(
                  opacity: curved,
                  child: BackdropFilter(
                    filter: ui.ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                    child: ColoredBox(
                      color: Colors.black.withValues(alpha: 0.72),
                    ),
                  ),
                ),
              ),
              Positioned.fill(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(72, 64, 72, 104),
                  child: ScaleTransition(
                    scale: Tween(begin: 0.94, end: 1.0).animate(curved),
                    child: FadeTransition(
                      opacity: curved,
                      child: _viewer(picture),
                    ),
                  ),
                ),
              ),
              Positioned(top: 14, left: 16, child: _caption(picture)),
              Positioned(top: 14, right: 16, child: _toolbar()),
              Positioned(
                left: 14,
                top: 0,
                bottom: 40,
                child: Center(
                  child: _arrow(Icons.chevron_left, 'Previous', _index - 1),
                ),
              ),
              Positioned(
                right: 14,
                top: 0,
                bottom: 40,
                child: Center(
                  child: _arrow(Icons.chevron_right, 'Next', _index + 1),
                ),
              ),
              if (_pictures.length > 1)
                Positioned(
                  left: 16,
                  right: 16,
                  bottom: 16,
                  child: Center(child: _filmstrip()),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _viewer(GaiaLightboxPicture picture) => LayoutBuilder(
    builder: (context, constraints) {
      final area = constraints.biggest;
      _viewport = area;
      final fitted = applyBoxFit(BoxFit.contain, picture.size, area);
      final rect = Alignment.center.inscribe(
        fitted.destination,
        Offset.zero & area,
      );
      return GestureDetector(
        // A click beside the picture, not on it, closes.
        onTapUp: (details) {
          if (!rect.contains(_transform.toScene(details.localPosition))) {
            _close();
          }
        },
        onDoubleTapDown: (details) => _doubleTapAt = details.localPosition,
        onDoubleTap: () {
          if (_scale > 1.01) {
            _animateTo(Matrix4.identity());
          } else {
            _zoomBy(2.5, at: _doubleTapAt);
          }
        },
        child: InteractiveViewer(
          transformationController: _transform,
          maxScale: _maxScale,
          clipBehavior: Clip.none,
          child: SizedBox.fromSize(
            size: area,
            child: Stack(
              children: [
                Positioned.fromRect(
                  rect: rect,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(GaiaRadius.row),
                      boxShadow: const [
                        BoxShadow(
                          color: Color(0x99000000),
                          offset: Offset(0, 16),
                          blurRadius: 48,
                          spreadRadius: -12,
                        ),
                      ],
                    ),
                    position: DecorationPosition.background,
                    child: Container(
                      clipBehavior: Clip.antiAlias,
                      foregroundDecoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(GaiaRadius.row),
                        border: Border.all(color: GaiaInk.hairline),
                      ),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(GaiaRadius.row),
                      ),
                      child: KeyedSubtree(
                        key: ValueKey(_index),
                        child: picture.build(context),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );

  Widget _caption(GaiaLightboxPicture picture) => GaiaGlowRing(
    radius: 18,
    hovered: false,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: picture.name,
              style: const TextStyle(color: GaiaInk.bright),
            ),
            TextSpan(
              text:
                  '   ${picture.size.width.round()} × '
                  '${picture.size.height.round()}   '
                  '${_index + 1} of ${_pictures.length}',
              style: const TextStyle(color: GaiaInk.muted),
            ),
          ],
        ),
        style: GaiaType.row,
      ),
    ),
  );

  Widget _toolbar() => MouseRegion(
    onEnter: (_) => setState(() => _barHovered = true),
    onExit: (_) => setState(() => _barHovered = false),
    child: GaiaGlowRing(
      radius: 20,
      hovered: _barHovered,
      child: Padding(
        padding: const EdgeInsets.all(2),
        child: AnimatedBuilder(
          animation: _transform,
          builder: (context, _) => Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              GaiaButton(
                icon: Icons.remove,
                tooltip: 'Zoom out (-)',
                onPressed: _scale > 1.001 ? () => _zoomBy(1 / 1.5) : null,
              ),
              SizedBox(
                width: 48,
                child: Text(
                  '${(_scale * 100).round()}%',
                  textAlign: TextAlign.center,
                  style: GaiaType.label.copyWith(color: GaiaInk.dim),
                ),
              ),
              GaiaButton(
                icon: Icons.add,
                tooltip: 'Zoom in (+)',
                onPressed: _scale < _maxScale - 0.001
                    ? () => _zoomBy(1.5)
                    : null,
              ),
              GaiaButton(
                icon: Icons.fit_screen_outlined,
                tooltip: 'Fit (0)',
                onPressed: _scale > 1.001
                    ? () => _animateTo(Matrix4.identity())
                    : null,
              ),
              Container(
                width: 1,
                height: 18,
                margin: const EdgeInsets.symmetric(horizontal: 4),
                color: GaiaInk.hairline,
              ),
              GaiaButton(
                icon: Icons.content_copy,
                tooltip: 'Copy',
                onPressed: _copy,
              ),
              GaiaButton(
                icon: Icons.download_outlined,
                tooltip: 'Save',
                onPressed: _save,
              ),
              GaiaButton(
                icon: Icons.close,
                tooltip: 'Close (Esc)',
                onPressed: _close,
              ),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _arrow(IconData icon, String tooltip, int to) {
    final shown = to >= 0 && to < _pictures.length;
    return AnimatedOpacity(
      duration: GaiaMotion.quick,
      opacity: shown ? 1 : 0,
      child: IgnorePointer(
        ignoring: !shown,
        child: GaiaGlowRing(
          radius: 22,
          hovered: false,
          child: GaiaButton(
            icon: icon,
            size: 44,
            radius: 22,
            tooltip: tooltip,
            onPressed: () => _go(to),
          ),
        ),
      ),
    );
  }

  Widget _filmstrip() => GaiaGlowRing(
    radius: GaiaRadius.panel,
    hovered: false,
    child: Padding(
      padding: const EdgeInsets.all(6),
      // A long chat's pictures scroll rather than overflow.
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (i, picture) in _pictures.indexed)
              Padding(
                padding: EdgeInsets.only(left: i == 0 ? 0 : 6),
                child: GaiaLightboxThumb(
                  picture: picture,
                  width: 60,
                  height: 42,
                  picked: i == _index,
                  dimmed: i != _index,
                  onTap: () => _go(i),
                ),
              ),
          ],
        ),
      ),
    ),
  );
}

/// A picture, small, cropped to fill its box: in the lightbox's filmstrip,
/// where the one showing has the accent's edge, and the study's row.
class GaiaLightboxThumb extends StatefulWidget {
  const GaiaLightboxThumb({
    super.key,
    required this.picture,
    required this.width,
    required this.height,
    required this.onTap,
    this.picked = false,
    this.dimmed = false,
  });

  final GaiaLightboxPicture picture;
  final double width, height;
  final VoidCallback onTap;
  final bool picked, dimmed;

  @override
  State<GaiaLightboxThumb> createState() => _ThumbState();
}

class _ThumbState extends State<GaiaLightboxThumb> {
  var _hovered = false;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedOpacity(
          duration: GaiaMotion.quick,
          opacity: widget.dimmed && !_hovered ? 0.55 : 1,
          child: AnimatedContainer(
            duration: GaiaMotion.quick,
            width: widget.width,
            height: widget.height,
            clipBehavior: Clip.antiAlias,
            foregroundDecoration: BoxDecoration(
              borderRadius: BorderRadius.circular(GaiaRadius.chip),
              border: Border.all(
                color: widget.picked
                    ? accent
                    : _hovered
                    ? Colors.white.withValues(alpha: 0.3)
                    : GaiaInk.hairline,
                width: widget.picked ? 2 : 1,
              ),
            ),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(GaiaRadius.chip),
            ),
            child: FittedBox(
              fit: BoxFit.cover,
              child: SizedBox.fromSize(
                size: widget.picture.size,
                child: widget.picture.build(context),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
