import 'dart:async';
import 'dart:math';
import 'dart:ui';

import 'package:executor_lib/executor_lib.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart' hide Image;
import 'package:flutter_map/flutter_map.dart' hide TileProvider;
import 'package:vector_tile_renderer/vector_tile_renderer.dart' hide TileLayer;

import '../../vector_map_tiles.dart';
import '../cache/cache.dart';
import '../cache/vector_tile_loading_cache.dart';
import '../extensions.dart';
import '../grid/slippy_map_translator.dart';
import '../grid/tile_zoom.dart';
import '../rendering/tile_renderer.dart';
import '../stream/tile_supplier.dart';
import '../stream/tile_supplier_raster.dart';
import 'storage_image_cache.dart';

class TileLoader {
  final Theme _theme;
  late final Set<String> _themeSources;
  late String _sourcesKey;
  final SpriteStyle? _sprites;
  final Future<Image> Function()? _spriteAtlas;
  final TileProvider _provider;
  final VectorTileLoadingCache _vectorTiles;
  final RasterTileProvider _rasterTileProvider;
  final StorageImageCache _imageCache;
  final Cache<String, Image> _renderedCache;
  final TileOffset _tileOffset;
  final int _concurrency;
  final _scale = 2.0;
  late final ConcurrencyExecutor _jobQueue;

  /// VOYAGER PATCH: the label layouts of source tiles by tile and zoom drawn
  /// at, the latest used last — see [_labelsOf].
  final _labels = <String, Future<LabelLayout>>{};

  TileLoader(
      this._theme,
      this._sprites,
      this._spriteAtlas,
      this._provider,
      this._vectorTiles,
      this._rasterTileProvider,
      this._tileOffset,
      this._imageCache,
      this._renderedCache,
      this._concurrency) {
    _themeSources = _theme.tileSources;
    _sourcesKey = _theme.tileSources.toList().sorted().join(',');
    _jobQueue = ConcurrencyExecutor(
        delegate: ImmediateExecutor(),
        concurrencyLimit: _concurrency * 2,
        maxQueueSize: _maxOutstandingJobs);
  }

  Future<ImageInfo> loadTile(TileCoordinates coords, TileLayer options,
      bool Function() cancelled) async {
    final requestedTile =
        TileIdentity(coords.z.toInt(), coords.x.toInt(), coords.y.toInt());
    var requestZoom = requestedTile.z;
    if (_tileOffset.zoomOffset < 0) {
      requestZoom = max(
          1, min(requestZoom + _tileOffset.zoomOffset, _provider.maximumZoom));
    }
    // VOYAGER PATCH: a tile drawn or decoded earlier is served from memory.
    final renderedKey = '${_theme.id}-v${_theme.version}/$requestedTile';
    final rendered = _renderedCache.get(renderedKey);
    if (rendered != null) {
      return ImageInfo(image: rendered, scale: _scale);
    }
    final cached = await _imageCache.retrieve(requestedTile);
    if (cached != null) {
      _renderedCache.put(renderedKey, cached);
      return ImageInfo(image: cached, scale: _scale);
    }
    final job = _TileJob(requestedTile, requestZoom,
        options.tileDimension.toDouble(), cancelled);
    return _jobQueue.submit(Job<_TileJob, ImageInfo>(
        'render $requestedTile', _renderJob, job,
        deduplicationKey: 'render $requestedTile ${_theme.id}/$_sourcesKey'));
  }

  Future<ImageInfo> _renderJob(job) => _renderTile(
      job.requestedTile, job.requestZoom, job.tileSize, job.cancelled);

  Future<ImageInfo> _renderTile(TileIdentity requestedTile, int requestZoom,
      double tileSize, bool Function() cancelled) async {
    if (cancelled()) {
      throw CancellationException();
    }
    final tileRequest = TileRequest(
        tileId: requestedTile,
        tileSources: _themeSources,
        zoom: requestedTile.z.toDouble(),
        zoomDetail: requestedTile.z.toDouble(),
        cancelled: cancelled);
    final spriteAtlas = await _spriteAtlas?.call();
    final tileResponseFuture = _provider.provide(tileRequest);
    final rasterTile = await _rasterTileProvider
        .retrieve(requestedTile.normalize(), skipMissing: true);
    try {
      final tileResponse = await tileResponseFuture;
      final tileset = tileResponse.tileset;
      if (tileset == null) {
        throw 'No tile: $requestedTile';
      }
      final translator = SlippyMapTranslator(_provider.maximumZoom);
      final translation = translator.specificZoomTranslation(requestedTile,
          zoom: tileResponse.identity.z);
      // VOYAGER PATCH: a tile past the source's last zoom draws its part of
      // the labels laid out for the whole source tile it is cut from, so its
      // neighbours draw the rest of any that cross its edge.
      final source = translator.translate(requestedTile);
      final labels = source.isTranslated ? await _labelsOf(source) : null;

      final renderer = TileRenderer(
          theme: _theme,
          textPainterProvider: const DefaultTextPainterProvider(),
          tileState: TileState(
              zoom: requestedTile.z.toDouble(),
              zoomDetail: requestedTile.z.toDouble(),
              zoomScale: 0.0,
              rotation: 0.0),
          translation: translation,
          tileset: tileset,
          rasterTileset: rasterTile,
          spriteImage: spriteAtlas,
          sprites: _sprites,
          labels: labels,
          labelsOrigin: Offset(source.xOffset.toDouble(),
                  source.yOffset.toDouble()) *
              tileSize);

      final size = Size.square(tileSize * _scale);
      final rect = Offset.zero & size;
      // VOYAGER PATCH: drawn in steps, as many as the frame's budget has
      // room for and the rest in the frames after. A whole tile at the
      // source's own zoom is several frames of drawing.
      final recorder = PictureRecorder();
      final canvas = Canvas(recorder, rect);
      canvas.scale(_scale);
      final steps = renderer.renderInSteps(canvas, size / _scale).iterator;
      try {
        while (await _frameBudget.run(() {
          if (cancelled()) {
            throw CancellationException();
          }
          return _frameBudget.advance(steps);
        })) {}
      } catch (_) {
        recorder.endRecording().dispose();
        rethrow;
      }
      final picture = recorder.endRecording();
      final image =
          await picture.toImage(size.width.toInt(), size.height.toInt());
      _renderedCache.put(
          '${_theme.id}-v${_theme.version}/$requestedTile', image);
      // VOYAGER PATCH: not awaited. Upstream held the tile back until its PNG
      // was encoded and written.
      unawaited(_cache(translation.original, image));
      return ImageInfo(image: image, scale: _scale);
    } finally {
      rasterTile.dispose();
    }
  }

  /// VOYAGER PATCH: the layout of [source]'s source tile at the zoom of the
  /// tile asked for, made once and shared by every tile cut from it.
  Future<LabelLayout> _labelsOf(TileTranslation source) {
    final key = '${source.translated}@${source.original.z}';
    var layout = _labels.remove(key);
    if (layout == null) {
      final made = layout = _layOutLabels(source);
      // A layout that failed is asked for again rather than kept.
      made.then<void>((_) {}, onError: (_) {
        if (identical(_labels[key], made)) _labels.remove(key);
      });
    }
    _labels[key] = layout;
    if (_labels.length > _maxLabelLayouts) {
      _labels.remove(_labels.keys.first);
    }
    return layout;
  }

  /// VOYAGER PATCH: the labels left out of [tile] for the caller to draw
  /// over it — LabelLayout.overlaid, one list for every tile cut from the
  /// same source tile — and [tile]'s corner among them. Null for a tile at
  /// or under the source's last zoom, which has no layout. A tile served
  /// from the image cache was drawn from one on an earlier run, which is
  /// made again here: the same data lays out the same.
  Future<({List<PlacedLabel> labels, Offset origin})?> overlaidLabels(
      TileIdentity tile) async {
    final source = SlippyMapTranslator(_provider.maximumZoom).translate(tile);
    if (!source.isTranslated) {
      return null;
    }
    final LabelLayout layout;
    try {
      layout = await _labelsOf(source);
    } catch (_) {
      // The source tile is neither cached nor reachable.
      return null;
    }
    return (
      labels: layout.overlaid,
      origin:
          Offset(source.xOffset.toDouble(), source.yOffset.toDouble()) * 256
    );
  }

  Future<LabelLayout> _layOutLabels(TileTranslation source) async {
    final sources = <String, TileData>{};
    for (final name in _themeSources) {
      final data =
          await _vectorTiles.retrieveLabelLayers(name, source.translated);
      if (data == null) {
        throw 'No tile: ${source.translated}';
      }
      sources[name] = data;
    }
    return _frameBudget.run(() => LabelLayout(
        theme: _theme,
        sources: sources,
        zoom: source.original.z.toDouble(),
        scale: source.fraction.toDouble()));
  }

  Future<void> _cache(TileIdentity tile, Image image) async {
    Image cloned = image.clone();
    try {
      await _imageCache.put(tile, cloned);
    } catch (_) {
      // nothing to do
    } finally {
      cloned.dispose();
    }
  }
}

class _TileJob {
  final TileIdentity requestedTile;
  final int requestZoom;
  final double tileSize;
  final bool Function() cancelled;

  _TileJob(this.requestedTile, this.requestZoom, this.tileSize, this.cancelled);
}

int _maxOutstandingJobs = 100;

/// A wide window just past the source's last zoom shows about twenty source
/// tiles at once.
const _maxLabelLayouts = 32;

final _frameBudget = _FrameBudget();

/// VOYAGER PATCH: drawing a tile — every feature walked and every label laid
/// out — happens on the UI thread, and upstream drew each the moment its data
/// arrived, so a screenful arriving together drew back to back and the map
/// froze under a drag until the last was done. Tiles are drawn a piece at a
/// time here, and once [_perFrame] of a frame has gone on drawing them the
/// next piece waits for the frame after, so a pan keeps its frames while
/// tiles load.
class _FrameBudget {
  static const _perFrame = Duration(milliseconds: 8);

  final _sinceFrame = Stopwatch();
  Future<void> _last = Future.value();

  Future<T> run<T>(T Function() work) {
    final result = _last.then((_) async {
      if (!_sinceFrame.isRunning || _sinceFrame.elapsed >= _perFrame) {
        await SchedulerBinding.instance.endOfFrame;
        _sinceFrame
          ..reset()
          ..start();
      }
      return work();
    });
    _last = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  /// Takes [steps] on until the frame's budget is spent, from inside [run].
  /// Whether any are left.
  bool advance(Iterator<void> steps) {
    while (steps.moveNext()) {
      if (_sinceFrame.elapsed >= _perFrame) {
        return true;
      }
    }
    return false;
  }
}
