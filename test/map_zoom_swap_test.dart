// The vendored flutter_map holds a new zoom's tiles back until every one on
// screen has loaded, then swaps them in together (third_party/flutter_map,
// VOYAGER PATCH). These drive a real TileLayer through a zoom with tiles whose
// loading the test releases by hand.

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map/src/layer/tile_layer/tile.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

/// Tiles that load when the test says so.
class _GatedTiles extends TileProvider {
  final gates = <TileCoordinates, Completer<ImageInfo>>{};

  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) =>
      _GatedImage(coordinates, gates.putIfAbsent(coordinates, Completer.new));

  void release(Iterable<TileCoordinates> tiles, ui.Image image) {
    for (final tile in tiles) {
      final gate = gates[tile]!;
      if (!gate.isCompleted) gate.complete(ImageInfo(image: image.clone()));
    }
  }

  Iterable<TileCoordinates> requestedAt(int zoom) =>
      gates.keys.where((c) => c.z == zoom);
}

class _GatedImage extends ImageProvider<_GatedImage> {
  _GatedImage(this.coordinates, this.gate);

  final TileCoordinates coordinates;
  final Completer<ImageInfo> gate;

  @override
  Future<_GatedImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(_GatedImage key, ImageDecoderCallback _) =>
      OneFrameImageStreamCompleter(gate.future);

  @override
  bool operator ==(Object other) =>
      other is _GatedImage && other.coordinates == coordinates;

  @override
  int get hashCode => coordinates.hashCode;
}

/// The zooms of the loaded tiles on screen.
Set<int> _shownZooms(WidgetTester tester) => {
  for (final tile in tester.widgetList<Tile>(find.byType(Tile)))
    if (tile.tileImage.loadFinishedAt != null) tile.tileImage.coordinates.z,
};

void main() {
  testWidgets('a zoom swaps in all at once', (tester) async {
    final image = (await tester.runAsync(
      () => createTestImage(width: 256, height: 256),
    ))!;
    final tiles = _GatedTiles();
    final controller = MapController();
    const center = LatLng(43.4723, -80.5449);
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 600,
          height: 600,
          child: FlutterMap(
            mapController: controller,
            options: const MapOptions(initialCenter: center, initialZoom: 15),
            children: [TileLayer(tileProvider: tiles)],
          ),
        ),
      ),
    );
    await tester.pump();
    tiles.release(tiles.requestedAt(15), image);
    await tester.pump(const Duration(seconds: 1));
    expect(_shownZooms(tester), {15});

    controller.move(center, 16);
    await tester.pump();
    // On screen: the tiles of the new zoom the layer has put in place.
    final onScreen = [
      for (final tile in tester.widgetList<Tile>(find.byType(Tile)))
        if (tile.tileImage.coordinates.z == 16) tile.tileImage.coordinates,
    ];
    expect(onScreen.length, greaterThan(4));

    // All but two of the new zoom load; none of it shows while they are out.
    final late = onScreen.take(2);
    tiles.release(tiles.requestedAt(16).where((c) => !late.contains(c)), image);
    await tester.pump(const Duration(seconds: 1));
    expect(_shownZooms(tester), {15});

    // The last two load, and the whole zoom is shown — over the old one,
    // which stays beneath until pruned.
    tiles.release(late, image);
    await tester.pump();
    // Then they fade in.
    await tester.pump(const Duration(seconds: 1));
    final shown = {
      for (final tile in tester.widgetList<Tile>(find.byType(Tile)))
        if (tile.tileImage.readyToDisplay) tile.tileImage.coordinates,
    };
    expect(shown, containsAll(onScreen));
    image.dispose();
  });

  testWidgets('with nothing to stand in, tiles show as they load', (
    tester,
  ) async {
    final image = (await tester.runAsync(
      () => createTestImage(width: 256, height: 256),
    ))!;
    // The first test's tiles, still in the image cache, would load at once.
    imageCache.clear();
    final tiles = _GatedTiles();
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 600,
          height: 600,
          child: FlutterMap(
            options: const MapOptions(
              initialCenter: LatLng(43.4723, -80.5449),
              initialZoom: 15,
            ),
            children: [TileLayer(tileProvider: tiles)],
          ),
        ),
      ),
    );
    await tester.pump();
    final first = tester
        .widgetList<Tile>(find.byType(Tile))
        .first
        .tileImage
        .coordinates;
    tiles.release([first], image);
    await tester.pump();
    final loaded = tester
        .widgetList<Tile>(find.byType(Tile))
        .where((tile) => tile.tileImage.loadFinishedAt != null)
        .map((tile) => tile.tileImage.coordinates);
    expect(loaded, [first]);
    image.dispose();
  });
}
