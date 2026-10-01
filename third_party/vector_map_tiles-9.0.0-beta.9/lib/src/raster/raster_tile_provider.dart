import 'package:executor_lib/executor_lib.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:vector_tile_renderer/vector_tile_renderer.dart';

import '../../vector_map_tiles.dart';
import '../cache/caches.dart';
import '../stream/caches_tile_provider.dart';
import '../stream/delay_provider.dart';
import '../stream/tile_processor.dart';
import '../stream/tile_supplier_raster.dart';
import '../stream/tileset_executor_preprocessor.dart';
import '../stream/tileset_ui_preprocessor.dart';
import '../vector_tile_controller.dart';
import 'future_tile_provider.dart';
import 'storage_image_cache.dart';
import 'tile_loader.dart';

TileProvider createRasterTileProvider(
    Theme theme,
    SpriteStyle? sprites,
    Caches caches,
    RasterTileProvider rasterTileProvider,
    Executor executor,
    TileOffset tileOffset,
    Duration tileDelay,
    int concurrency,
    VectorTileController? controller) {
  final loader = createTileLoader(theme, sprites, caches, rasterTileProvider,
      executor, tileOffset, tileDelay, concurrency);
  // VOYAGER PATCH: the controller asks this loader for the labels it left
  // out of its tiles.
  attachLabels(controller, loader.overlaidLabels);
  return FutureTileProvider(loader: loader.loadTile);
}

TileLoader createTileLoader(
    Theme theme,
    SpriteStyle? sprites,
    Caches caches,
    RasterTileProvider rasterTileProvider,
    Executor executor,
    TileOffset tileOffset,
    Duration tileDelay,
    int concurrency) {
  final tileSupplier = DelayProvider(
          CachesTileProvider(
              caches,
              TileProcessor(executor),
              TilesetExecutorPreprocessor(TilesetPreprocessor(theme), executor),
              // VOYAGER PATCH: upstream made every feature's path here, as
              // the tile arrived: tens of milliseconds for a whole tile, all
              // at once. They are made as they are drawn instead, which the
              // loader spreads over frames.
              TilesetUiPreprocessor(TilesetPreprocessor(theme))),
          tileDelay)
      .orDelegate();
  return TileLoader(
      theme,
      sprites,
      caches.atlasImageCache?.retrieve,
      tileSupplier,
      caches.vectorTileCache,
      rasterTileProvider,
      tileOffset,
      StorageImageCache(theme, caches.storageCache),
      Caches.renderedTileCache,
      concurrency);
}
