import 'dart:ui';

import 'package:vector_tile_renderer/vector_tile_renderer.dart';

import 'cache/caches.dart';
import 'tile_identity.dart';

/// A controller for programmatic access to [VectorTileLayer] cache operations.
///
/// Create an instance and pass it to [VectorTileLayer.controller].
/// Use [clearMemoryCaches] to clear all in-memory caches on demand.
abstract class VectorTileController {
  /// Creates a [VectorTileController].
  factory VectorTileController() = _VectorTileControllerImpl;

  /// Clears all in-memory caches without adjusting their max sizes.
  ///
  /// If the controller is not attached to a widget, this is a no-op.
  void clearMemoryCaches();

  /// VOYAGER PATCH: the labels a raster mode layer left out of [tile] for
  /// the caller to draw over it — those of theme layers whose metadata sets
  /// `overlay` — in the pixels of a 256 pixel tile, with [tile]'s corner
  /// among them as `origin`. Every tile cut from one source tile answers
  /// with the same list. Null before the layer is built, or for a tile whose
  /// data is neither cached nor reachable.
  Future<({List<PlacedLabel> labels, Offset origin})?> overlaidLabels(
      TileIdentity tile);
}

typedef _OverlaidLabels = Future<({List<PlacedLabel> labels, Offset origin})?>
    Function(TileIdentity tile);

class _VectorTileControllerImpl implements VectorTileController {
  Caches? _caches;
  _OverlaidLabels? _overlaidLabels;

  @override
  Future<({List<PlacedLabel> labels, Offset origin})?> overlaidLabels(
          TileIdentity tile) async =>
      _overlaidLabels?.call(tile);

  @override
  void clearMemoryCaches() {
    _caches?.clearMemoryCaches();
  }

  void attach(Caches caches) {
    assert(_caches == null, 'VectorTileController is already attached');
    _caches = caches;
  }

  void detach() {
    _caches = null;
    _overlaidLabels = null;
  }
}

/// Attaches the [controller] to the given [caches].
///
/// This is package-internal and not exported from the library barrel file.
void attachController(VectorTileController? controller, Caches caches) {
  (controller as _VectorTileControllerImpl?)?.attach(caches);
}

/// VOYAGER PATCH: points the [controller]'s labels at a tile loader's.
void attachLabels(
    VectorTileController? controller,
    Future<({List<PlacedLabel> labels, Offset origin})?> Function(
            TileIdentity tile)
        overlaidLabels) {
  (controller as _VectorTileControllerImpl?)?._overlaidLabels = overlaidLabels;
}

/// Detaches the [controller] from its caches.
///
/// This is package-internal and not exported from the library barrel file.
void detachController(VectorTileController? controller) {
  (controller as _VectorTileControllerImpl?)?.detach();
}
