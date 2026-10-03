import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:vector_map_tiles/vector_map_tiles.dart';
import 'package:voyager/app/providers.dart';

/// The most tiles one area may hold. Each is a request against the Geoapify
/// key, so a download stays a city or so — about 120 km across.
const rankingOfflineMaxTiles = 5000;

/// Geoapify's vector tiles, over the network. Null without a key.
final rankingMapNetworkTilesProvider = Provider<VectorTileProvider?>((ref) {
  final client = ref.watch(geoapifyClientProvider);
  if (client == null) return null;
  return NetworkVectorTileProvider(
    urlTemplate:
        'https://maps.geoapify.com/v1/tile/vector/{z}/{x}/{y}.pbf'
        '?apiKey=${client.apiKey}',
    maximumZoom: 14,
  );
});

/// Where downloaded areas are kept: a folder each, holding `area.json` and
/// its tiles as `z/x/y.pbf`. Tests point it at a temporary folder.
final rankingOfflineMapsDirectoryProvider = FutureProvider<Directory>(
  (ref) async => Directory(
    p.join((await getApplicationSupportDirectory()).path, 'offline_maps'),
  ),
);

/// The areas downloaded for offline use, newest first.
final rankingOfflineAreasProvider =
    AsyncNotifierProvider<RankingOfflineAreas, List<RankingOfflineArea>>(
      RankingOfflineAreas.new,
    );

/// A part of the map kept on this device, every tile of it from zoom
/// [VectorTileProvider.minimumZoom] to [VectorTileProvider.maximumZoom].
class RankingOfflineArea {
  const RankingOfflineArea({
    required this.id,
    required this.name,
    required this.bounds,
    required this.tileCount,
    required this.byteSize,
  });

  factory RankingOfflineArea.fromJson(Map<String, dynamic> json) =>
      RankingOfflineArea(
        id: json['id'] as String,
        name: json['name'] as String,
        bounds: LatLngBounds.unsafe(
          north: (json['north'] as num).toDouble(),
          south: (json['south'] as num).toDouble(),
          east: (json['east'] as num).toDouble(),
          west: (json['west'] as num).toDouble(),
        ),
        tileCount: json['tileCount'] as int,
        byteSize: json['byteSize'] as int,
      );

  final String id;
  final String name;
  final LatLngBounds bounds;
  final int tileCount;
  final int byteSize;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'north': bounds.north,
    'south': bounds.south,
    'east': bounds.east,
    'west': bounds.west,
    'tileCount': tileCount,
    'byteSize': byteSize,
  };
}

/// The tiles at [zoom] that [bounds] touches, as inclusive x and y ranges.
({int left, int top, int right, int bottom}) _tileRange(
  LatLngBounds bounds,
  int zoom,
) {
  final n = 1 << zoom;
  int x(double longitude) =>
      ((longitude + 180) / 360 * n).floor().clamp(0, n - 1);
  int y(double latitude) {
    final r = latitude.clamp(-85.05112878, 85.05112878) * math.pi / 180;
    final mercator = math.log(math.tan(r) + 1 / math.cos(r)) / math.pi;
    return ((1 - mercator) / 2 * n).floor().clamp(0, n - 1);
  }

  return (
    left: x(bounds.west),
    top: y(bounds.north),
    right: x(bounds.east),
    bottom: y(bounds.south),
  );
}

/// Every tile [bounds] touches from [minZoom] to [maxZoom].
Iterable<TileIdentity> rankingOfflineTiles(
  LatLngBounds bounds,
  int minZoom,
  int maxZoom,
) sync* {
  for (var z = minZoom; z <= maxZoom; z++) {
    final range = _tileRange(bounds, z);
    for (var x = range.left; x <= range.right; x++) {
      for (var y = range.top; y <= range.bottom; y++) {
        yield TileIdentity(z, x, y);
      }
    }
  }
}

/// How many tiles [rankingOfflineTiles] yields, counted from each zoom's range
/// rather than by building them: a world view holds hundreds of millions.
int rankingOfflineTileCount(LatLngBounds bounds, int minZoom, int maxZoom) {
  var count = 0;
  for (var z = minZoom; z <= maxZoom; z++) {
    final range = _tileRange(bounds, z);
    count += (range.right - range.left + 1) * (range.bottom - range.top + 1);
  }
  return count;
}

class RankingOfflineAreas extends AsyncNotifier<List<RankingOfflineArea>> {
  late Directory _root;

  @override
  Future<List<RankingOfflineArea>> build() async {
    _root = await ref.watch(rankingOfflineMapsDirectoryProvider.future);
    if (!await _root.exists()) return [];
    final areas = <RankingOfflineArea>[];
    await for (final folder in _root.list()) {
      if (folder is! Directory) continue;
      final file = File(p.join(folder.path, 'area.json'));
      if (await file.exists()) {
        areas.add(
          RankingOfflineArea.fromJson(
            jsonDecode(await file.readAsString()) as Map<String, dynamic>,
          ),
        );
      } else {
        // A download the app closed on before it finished.
        await folder.delete(recursive: true);
      }
    }
    areas.sort((a, b) => b.id.compareTo(a.id));
    return areas;
  }

  File _tileFile(String areaId, TileIdentity tile) => File(
    p.join(_root.path, areaId, '${tile.z}', '${tile.x}', '${tile.y}.pbf'),
  );

  /// [tile] from a downloaded area, or null when none holds it.
  Future<Uint8List?> tile(TileIdentity tile) async {
    // Areas that failed to load (a half-written area.json, say) hold nothing,
    // rather than failing every tile, network ones included.
    final List<RankingOfflineArea> areas;
    try {
      areas = await future;
    } catch (_) {
      return null;
    }
    for (final area in areas) {
      final range = _tileRange(area.bounds, tile.z);
      if (tile.x < range.left ||
          tile.x > range.right ||
          tile.y < range.top ||
          tile.y > range.bottom) {
        continue;
      }
      final file = _tileFile(area.id, tile);
      if (await file.exists()) return file.readAsBytes();
    }
    return null;
  }

  /// Fetches every tile of [bounds] from [network] and keeps them as [name],
  /// reporting each tile done to [onProgress]. Stops, keeping nothing, once
  /// [cancelled] answers true or a tile fails.
  Future<void> download({
    required String name,
    required LatLngBounds bounds,
    required VectorTileProvider network,
    required void Function(int done) onProgress,
    required bool Function() cancelled,
  }) async {
    await future;
    final id = DateTime.now().toUtc().microsecondsSinceEpoch.toString();
    final tiles = rankingOfflineTiles(
      bounds,
      network.minimumZoom,
      network.maximumZoom,
    ).toList();
    var next = 0;
    var done = 0;
    var bytes = 0;
    Object? failure;
    StackTrace? failureTrace;

    Future<void> worker() async {
      while (next < tiles.length && failure == null && !cancelled()) {
        final tile = tiles[next++];
        try {
          final data = await network.provide(tile);
          final file = _tileFile(id, tile);
          await file.create(recursive: true);
          await file.writeAsBytes(data);
          bytes += data.length;
        } on ProviderException catch (error, trace) {
          // Nothing there — open sea — is not a failure.
          if (error.statusCode != 404 && error.statusCode != 204) {
            failure ??= error;
            failureTrace ??= trace;
          }
        } catch (error, trace) {
          failure ??= error;
          failureTrace ??= trace;
        }
        onProgress(++done);
      }
    }

    await Future.wait([for (var i = 0; i < 8; i++) worker()]);
    final folder = Directory(p.join(_root.path, id));
    if (failure != null || cancelled()) {
      if (await folder.exists()) await folder.delete(recursive: true);
      if (failure != null) Error.throwWithStackTrace(failure!, failureTrace!);
      return;
    }
    final area = RankingOfflineArea(
      id: id,
      name: name,
      bounds: bounds,
      tileCount: tiles.length,
      byteSize: bytes,
    );
    await folder.create(recursive: true);
    await File(
      p.join(folder.path, 'area.json'),
    ).writeAsString(jsonEncode(area.toJson()));
    state = AsyncData([area, ...await future]);
  }

  Future<void> delete(String id) async {
    final folder = Directory(p.join(_root.path, id));
    if (await folder.exists()) await folder.delete(recursive: true);
    state = AsyncData([
      for (final area in await future)
        if (area.id != id) area,
    ]);
  }
}

/// Tiles from a downloaded area where one holds them, else from [_network].
class RankingOfflineFirstTiles extends VectorTileProvider {
  RankingOfflineFirstTiles(this._network, this._areas);

  final VectorTileProvider _network;
  final RankingOfflineAreas _areas;

  @override
  Future<Uint8List> provide(TileIdentity tile) async =>
      await _areas.tile(tile) ?? await _network.provide(tile);

  @override
  int get maximumZoom => _network.maximumZoom;

  @override
  int get minimumZoom => _network.minimumZoom;

  @override
  TileOffset get tileOffset => _network.tileOffset;
}
