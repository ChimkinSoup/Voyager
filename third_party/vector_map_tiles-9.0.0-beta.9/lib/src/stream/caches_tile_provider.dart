import 'dart:async';

import 'package:executor_lib/executor_lib.dart';
import 'package:vector_tile_renderer/vector_tile_renderer.dart';

import '../cache/caches.dart';
import 'tile_processor.dart';
import 'tile_supplier.dart';
import 'tileset_executor_preprocessor.dart';
import 'tileset_ui_preprocessor.dart';

class CachesTileProvider extends TileProvider {
  final Caches _caches;
  final TileProcessor _tileProcessor;
  final TilesetExecutorPreprocessor _preprocessor;
  final TilesetUiPreprocessor _uiPreprocessor;

  CachesTileProvider(this._caches, this._tileProcessor, this._preprocessor,
      this._uiPreprocessor);

  @override
  int get maximumZoom => _caches.vectorTileCache.maximumZoom;

  @override
  Future<TileResponse> provide(TileRequest request) =>
      _provide(request, localOnly: false);

  @override
  Future<TileResponse> provideLocalCopy(TileRequest request) =>
      _provide(request, localOnly: true);

  Future<TileResponse> _provide(TileRequest request,
      {required bool localOnly}) async {
    Map<String, TileData?> tileDataBySource =
        await _retrieve(request, localOnly: localOnly);
    if (tileDataBySource.values.any((t) => t == null)) {
      return TileResponse(identity: request.tileId, tileset: null);
    }
    Map<String, TileData> loadedDataBySource =
        tileDataBySource.map((key, value) => MapEntry(key, value!));
    Map<String, Tile> tileBySource =
        await _createTiles(request, loadedDataBySource);
    var tileset = await _preprocessor.preprocess(
        request.tileId,
        Tileset(tileBySource),
        request.clip,
        request.zoom.truncate(),
        request.cancelled);
    tileset = await _uiPreprocessor.preprocess(request.tileId, tileset,
        request.clip, request.zoom.truncate(), request.cancelled);
    return TileResponse(identity: request.tileId, tileset: tileset);
  }

  Future<Map<String, TileData?>> _retrieve(TileRequest request,
      {required bool localOnly}) async {
    Map<String, Future<TileData?>> futureBySource = {};
    for (final source in request.tileSources) {
      futureBySource[source] = _caches.vectorTileCache.retrieve(
          source, request.tileId,
          cachedOnly: localOnly, cancelled: request.cancelled);
    }
    return _awaitEach(request, futureBySource);
  }

  Future<Map<String, Tile>> _createTiles(
      TileRequest request, Map<String, TileData> tileDataBySource) async {
    final sourceToTileFuture = tileDataBySource.map((source, tileData) =>
        MapEntry(
            source,
            _tileProcessor.process(
                request, source, tileData, request.cancelled)));
    return _awaitEach(request, sourceToTileFuture);
  }

  /// VOYAGER PATCH: awaits [futures] in turn, checking for cancellation before
  /// each as upstream did. Upstream's check threw past the futures not yet
  /// awaited, which then failed unwatched with the executor's
  /// CancellationException, an uncaught error in the app's log (BUG-169).
  /// Those are dropped; any other error from them still surfaces.
  Future<Map<String, T>> _awaitEach<T>(
      TileRequest request, Map<String, Future<T>> futures) async {
    final result = <String, T>{};
    final entries = futures.entries.toList();
    for (var i = 0; i < entries.length; i++) {
      if (request.isCancelled) {
        for (final rest in entries.skip(i)) {
          unawaited(rest.value.then<void>((_) {},
              onError: (Object error, StackTrace stack) {
            if (error is! CancellationException) {
              Error.throwWithStackTrace(error, stack);
            }
          }));
        }
        request.testCancelled();
      }
      result[entries[i].key] = await entries[i].value;
    }
    return result;
  }
}
