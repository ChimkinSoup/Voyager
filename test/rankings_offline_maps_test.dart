import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:path/path.dart' as p;
import 'package:vector_map_tiles/vector_map_tiles.dart';
import 'package:voyager/features/rankings/rankings_offline_maps.dart';

/// Answers every tile with three bytes, or fails once [offline].
class _FakeNetwork extends VectorTileProvider {
  var offline = false;
  var requests = 0;

  @override
  Future<Uint8List> provide(TileIdentity tile) async {
    requests++;
    if (offline) {
      throw ProviderException(message: 'offline', retryable: Retryable.retry);
    }
    return Uint8List.fromList([tile.z, tile.x % 256, tile.y % 256]);
  }

  @override
  int get maximumZoom => 14;

  @override
  int get minimumZoom => 1;

  @override
  TileOffset get tileOffset => TileOffset.DEFAULT;
}

void main() {
  // A few streets of Toronto.
  final bounds = LatLngBounds(
    const LatLng(43.64, -79.40),
    const LatLng(43.66, -79.37),
  );
  late Directory root;

  ProviderContainer container() => ProviderContainer(
    overrides: [
      rankingOfflineMapsDirectoryProvider.overrideWith((ref) async => root),
    ],
  );

  setUp(() => root = Directory.systemTemp.createTempSync('offline_maps'));
  tearDown(() => root.deleteSync(recursive: true));

  test('a downloaded area draws with the network gone', () async {
    final network = _FakeNetwork();
    final c = container();
    final areas = c.read(rankingOfflineAreasProvider.notifier);
    final tiles = rankingOfflineTiles(bounds, 1, 14).toList();
    var progress = 0;
    await areas.download(
      name: 'Downtown',
      bounds: bounds,
      network: network,
      onProgress: (done) => progress = done,
      cancelled: () => false,
    );
    expect(progress, tiles.length);
    final saved = c.read(rankingOfflineAreasProvider).value!.single;
    expect(saved.name, 'Downtown');
    expect(saved.byteSize, tiles.length * 3);

    network.offline = true;
    final provider = RankingOfflineFirstTiles(network, areas);
    final inside = tiles.last;
    expect(await provider.provide(inside), [
      inside.z,
      inside.x % 256,
      inside.y % 256,
    ]);
    // Outside the area it goes to the network, which fails.
    await expectLater(
      provider.provide(TileIdentity(14, 0, 0)),
      throwsA(isA<ProviderException>()),
    );

    // A fresh start reads the area back from disk.
    final again = container();
    final reloaded = await again.read(rankingOfflineAreasProvider.future);
    expect(reloaded.single.byteSize, saved.byteSize);
  });

  test('a failed or cancelled download keeps nothing', () async {
    final c = container();
    final areas = c.read(rankingOfflineAreasProvider.notifier);
    await expectLater(
      areas.download(
        name: 'Failed',
        bounds: bounds,
        network: _FakeNetwork()..offline = true,
        onProgress: (_) {},
        cancelled: () => false,
      ),
      throwsA(isA<ProviderException>()),
    );
    await areas.download(
      name: 'Cancelled',
      bounds: bounds,
      network: _FakeNetwork(),
      onProgress: (_) {},
      cancelled: () => true,
    );
    expect(c.read(rankingOfflineAreasProvider).value, isEmpty);
    expect(root.listSync(), isEmpty);
  });

  test('deleting an area removes its tiles', () async {
    final c = container();
    final areas = c.read(rankingOfflineAreasProvider.notifier);
    await areas.download(
      name: 'Downtown',
      bounds: bounds,
      network: _FakeNetwork(),
      onProgress: (_) {},
      cancelled: () => false,
    );
    final id = c.read(rankingOfflineAreasProvider).value!.single.id;
    await areas.delete(id);
    expect(c.read(rankingOfflineAreasProvider).value, isEmpty);
    expect(root.listSync(), isEmpty);
  });

  test('the tile count matches the tiles, and a world view counts at once', () {
    expect(
      rankingOfflineTileCount(bounds, 1, 14),
      rankingOfflineTiles(bounds, 1, 14).length,
    );
    final world = LatLngBounds(const LatLng(-85, -180), const LatLng(85, 180));
    expect(
      rankingOfflineTileCount(world, 1, 14),
      greaterThan(rankingOfflineMaxTiles),
    );
  });

  test('an area that will not load leaves tiles to the network', () async {
    File(p.join(root.path, '1', 'area.json'))
      ..createSync(recursive: true)
      ..writeAsStringSync('{"id": "1", "na');
    final c = container();
    final areas = c.read(rankingOfflineAreasProvider.notifier);
    final provider = RankingOfflineFirstTiles(_FakeNetwork(), areas);
    expect(await provider.provide(TileIdentity(14, 1, 2)), [14, 1, 2]);
  });
}
