import 'dart:ui' show Image;

import 'package:executor_lib/executor_lib.dart';
import 'package:vector_tile_renderer/vector_tile_renderer.dart';

import '../../vector_map_tiles.dart';
import 'atlas_image_cache.dart';
import 'cache.dart';
import 'byte_storage.dart';
import 'image_loading_cache.dart';
import 'memory_cache.dart';
import 'storage_cache.dart';
import 'text_cache.dart';
import 'vector_tile_loading_cache.dart';

class Caches {
  final Executor executor;
  late final ByteStorage _storage;
  late final StorageCache storageCache;
  late final VectorTileLoadingCache vectorTileCache;
  late final MemoryCache memoryVectorTileCache;
  late final MemoryTileDataCache memoryTileDataCache;
  late final TextCache textCache;
  late final List<String> providerSources;
  late final AtlasImageCache? atlasImageCache;
  late final ImageLoadingCache imageLoadingCache;

  /// VOYAGER PATCH: the tiles raster mode has drawn, as images. Upstream kept
  /// a drawn tile only on disk, so one that left the screen and came back —
  /// a pan there and back, a zoom out and in again — was read and decoded
  /// from its PNG each time. Each is 512x512, about 1 MB. One cache for
  /// every layer, keyed by theme and tile, so two maps open at once — or a
  /// change of theme — share the one budget.
  static final renderedTileCache =
      Cache<String, Image>(maxSize: 180, sizer: Sizer(), copier: ImageCopier());

  Caches(
      {required TileProviders providers,
      required this.executor,
      required Theme theme,
      required SpriteStyle? sprites,
      required Duration ttl,
      required int memoryTileCacheMaxSize,
      required int memoryTileDataCacheMaxSize,
      required int maxSizeInBytes,
      required int maxTextCacheSize,
      required ByteStorage cacheStorage}) {
    _storage = cacheStorage;
    final vectorProviders = providers.tileProviderBySource.entries.where((e) =>
        e.value.type == TileProviderType.vector ||
        e.value.type == TileProviderType.raster_dem);
    providerSources = vectorProviders.map((e) => e.key).toList();
    storageCache = StorageCache(_storage, ttl, maxSizeInBytes);
    memoryVectorTileCache = MemoryCache(maxSizeBytes: memoryTileCacheMaxSize);
    memoryTileDataCache =
        MemoryTileDataCache(maxSize: memoryTileDataCacheMaxSize);
    final tileProviders = _createTileProviders(theme, vectorProviders);
    vectorTileCache = VectorTileLoadingCache(
        storageCache,
        memoryVectorTileCache,
        memoryTileDataCache,
        tileProviders,
        executor,
        theme);
    textCache = TextCache(maxSize: maxTextCacheSize);
    atlasImageCache = sprites == null
        ? null
        : AtlasImageCache(theme, sprites.atlasProvider, storageCache);
    imageLoadingCache =
        ImageLoadingCache(delegate: storageCache, providers: providers);
  }

  Future<void> applyConstraints() => storageCache.applyConstraints();

  void dispose() {
    vectorTileCache.dispose();
    memoryVectorTileCache.dispose();
    atlasImageCache?.dispose();
    imageLoadingCache.dispose();
  }

  void didHaveMemoryPressure() {
    memoryVectorTileCache.didHaveMemoryPressure();
    memoryTileDataCache.didHaveMemoryPressure();
    textCache.didHaveMemoryPressure();
    imageLoadingCache.memoryCache.didHaveMemoryPressure();
    renderedTileCache.didHaveMemoryPressure();
  }

  void clearMemoryCaches() {
    memoryVectorTileCache.clear();
    memoryTileDataCache.clear();
    textCache.clear();
    imageLoadingCache.memoryCache.clear();
    renderedTileCache.clear();
  }

  String stats() {
    final cacheStats = <String>[];
    cacheStats.add(
        'Storage cache hit ratio:           ${storageCache.hitRatio.asPct()}%');
    cacheStats.add(
        'Vector tile cache hit ratio:       ${memoryVectorTileCache.hitRatio.asPct()}% size: ${memoryVectorTileCache.size}');
    cacheStats.add(
        'Tile data cache hit ratio:         ${memoryTileDataCache.hitRatio.asPct()}% size: ${memoryTileDataCache.size}');
    cacheStats.add(
        'Text cache hit ratio:              ${textCache.hitRatio.asPct()}% size: ${textCache.size}');
    cacheStats.add(
        'Image cache hit ratio:             ${imageLoadingCache.memoryCache.hitRatio.asPct()}% size: ${imageLoadingCache.memoryCache.size}');
    return cacheStats.join('\n');
  }

  TileProviders _createTileProviders(Theme theme,
      Iterable<MapEntry<String, VectorTileProvider>> vectorProviders) {
    final sources = theme.tileSources;
    return TileProviders(
        Map.fromEntries(vectorProviders.where((e) => sources.contains(e.key))));
  }
}

extension _PctExtension on double {
  double asPct() => (this * 1000).roundToDouble() / 10;
}
