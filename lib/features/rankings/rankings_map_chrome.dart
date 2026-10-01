import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';
import 'package:vector_map_tiles/vector_map_tiles.dart';
import 'package:vector_tile_renderer/vector_tile_renderer.dart' as vtr;
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/theme/app_fonts.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/features/rankings/rankings_map_style.dart';
import 'package:voyager/features/rankings/rankings_providers.dart';

/// The base style every map is recoloured from — see [voyagerMapStyle].
final _baseStyleProvider = FutureProvider<Map<String, dynamic>>(
  (ref) async =>
      jsonDecode(await rootBundle.loadString('assets/rankings_map_style.json'))
          as Map<String, dynamic>,
);

/// The closest any rankings map zooms. The tile layer draws nothing past its
/// own maximum, so a map allowed further would show only its background.
const rankingsMapMaxZoom = 20.0;

/// Geoapify's vector tiles, drawn in the app's own colours and font: land in
/// the theme's surface, everything on it a shade toward the theme's ink, water
/// and major roads leaning toward the accent, and every label in the app font. Vector rather
/// than raster because a raster tile arrives with its colours and lettering
/// already painted in.
///
/// The names of places to eat and drink are not in the tiles: they are drawn
/// over them here, so one under a pin, or under the title a pin carries, can
/// be left out, and one can be lit and pressed — see [RankingsTileLayerState].
///
/// Draws nothing without a key — the caller shows the unavailable state.
class RankingsTileLayer extends ConsumerStatefulWidget {
  const RankingsTileLayer({super.key, this.pins = const []});

  /// The map's pins and the title each carries under it, which the names
  /// make way for.
  final List<({LatLng point, String title})> pins;

  @override
  ConsumerState<RankingsTileLayer> createState() => RankingsTileLayerState();
}

/// The zoom a place to eat or drink's name first shows at — the style's
/// `poi_food_major` — and with it the title under a pin.
const rankingsMapNameZoom = 15;

/// A pin's title: how wide it may run before it wraps, how many lines it
/// may take, and how far under the pin's point it starts.
const rankingsMapTitleWidth = 96.0;
const rankingsMapTitleLines = 2;
const rankingsMapTitleDrop = 17.0;

/// Drawn without a box, so it is ringed in the land's colour to stand off
/// the roads it crosses.
TextStyle rankingsMapTitleStyle(ThemeData theme) =>
    theme.textTheme.labelSmall!.copyWith(
      color: theme.colorScheme.onSurface,
      fontWeight: FontWeight.w700,
      height: 1.15,
      shadows: [
        for (final offset in const [
          Offset(-1, -1),
          Offset(1, -1),
          Offset(-1, 1),
          Offset(1, 1),
        ])
          Shadow(color: theme.colorScheme.surface, offset: offset),
      ],
    );

/// One name drawn over the tiles: its label, and the corner of the layout
/// the label's own offsets are from, in the world's pixels at the zoom the
/// label was laid out for.
typedef _Name = ({vtr.PlacedLabel label, Offset corner});

class RankingsTileLayerState extends ConsumerState<RankingsTileLayer> {
  final _controller = VectorTileController();

  /// The names laid out for the tiles last on screen, and the whole zoom
  /// those were drawn at. Kept while the next are fetched, as the tiles are.
  ({int zoom, List<_Name> names})? _names;

  /// Which tiles [_names] was last asked for.
  String? _asked;

  /// What the last build drew, for [nameAt]: the camera, and the names left
  /// once the pins had taken their room.
  MapCamera? _camera;
  List<_Name> _drawn = const [];

  /// The name under the mouse — see [light].
  _Name? _lit;

  /// The size of each of the pins' titles, by its text.
  final _titleSizes = <String, Size>{};

  /// The name drawn over [point] and the place it names, or null.
  ({String text, LatLng point})? nameAt(LatLng point) {
    final name = _drawnAt(point);
    return name == null
        ? null
        : (
            text: name.label.text,
            point: _camera!.unprojectAtZoom(
              name.corner + name.label.at,
              _names!.zoom.toDouble(),
            ),
          );
  }

  /// Draws the name over [point] in the accent, to show it can be pressed,
  /// and no other. Whether there is one.
  bool light(LatLng? point) {
    final name = point == null ? null : _drawnAt(point);
    if (name != _lit) setState(() => _lit = name);
    return name != null;
  }

  _Name? _drawnAt(LatLng point) {
    final camera = _camera;
    final names = _names;
    if (camera == null || names == null) return null;
    final at = camera.projectAtZoom(point, names.zoom.toDouble());
    for (final name in _drawn) {
      if (name.label.bounds.shift(name.corner).contains(at)) return name;
    }
    return null;
  }

  /// Fetches the names of the tiles from ([left], [top]) to ([right],
  /// [bottom]) at [zoom], unless they are the ones last asked for.
  Future<void> _ask(
    Object theme,
    int zoom,
    int left,
    int top,
    int right,
    int bottom,
  ) async {
    final asked = '${identityHashCode(theme)}/$zoom/$left/$top/$right/$bottom';
    if (asked == _asked) return;
    _asked = asked;
    // The tile layer under this one is built, or rebuilt for a new theme,
    // after this is called, and only then does the controller answer for it.
    await null;
    final names = <_Name>[];
    final seen = <List<vtr.PlacedLabel>>[];
    for (var x = left; x <= right; x++) {
      for (var y = top; y <= bottom; y++) {
        final tile = TileIdentity(zoom, x, y);
        if (!tile.isValid()) continue;
        final cut = await _controller.overlaidLabels(tile);
        // Every tile cut from one source tile answers with the same list.
        if (cut == null || seen.any((list) => identical(list, cut.labels))) {
          continue;
        }
        seen.add(cut.labels);
        final corner = Offset(x * 256, y * 256) - cut.origin;
        names.addAll([
          for (final label in cut.labels) (label: label, corner: corner),
        ]);
      }
    }
    if (!mounted || asked != _asked) return;
    setState(() => _names = (zoom: zoom, names: names));
  }

  /// What [camera] shows, in the world's pixels at [zoom].
  Rect _viewAt(MapCamera camera, int zoom) {
    final scale = math.pow(2, camera.zoom - zoom);
    return Rect.fromCenter(
      center: camera.projectAtZoom(camera.center, zoom.toDouble()),
      width: camera.size.width / scale,
      height: camera.size.height / scale,
    );
  }

  /// The names of [names] on screen that no pin of the map sits on and no
  /// pin's title runs over.
  List<_Name> _clearOfPins(
    BuildContext context,
    MapCamera camera,
    ({int zoom, List<_Name> names}) names,
  ) {
    final zoom = names.zoom.toDouble();
    // The names are laid out at a whole zoom and stretched to the camera's.
    final scale = math.pow(2, camera.zoom - zoom).toDouble();
    final view = _viewAt(camera, names.zoom);
    final style = rankingsMapTitleStyle(Theme.of(context));
    final scaler = MediaQuery.textScalerOf(context);
    final pins = <({Offset at, Rect title})>[];
    for (final pin in widget.pins) {
      final at = camera.projectAtZoom(pin.point, zoom);
      if (!view.inflate(rankingsMapTitleWidth / scale).contains(at)) continue;
      final size = pin.title.isEmpty || camera.zoom < rankingsMapNameZoom
          ? Size.zero
          : _titleSizes.putIfAbsent(pin.title, () {
              final painter = TextPainter(
                text: TextSpan(text: pin.title, style: style),
                textAlign: TextAlign.center,
                textDirection: TextDirection.ltr,
                textScaler: scaler,
                maxLines: rankingsMapTitleLines,
                ellipsis: '…',
              )..layout(maxWidth: rankingsMapTitleWidth);
              final size = painter.size;
              painter.dispose();
              return size;
            });
      pins.add((
        at: at,
        title: Rect.fromLTWH(
          at.dx - size.width / scale / 2,
          at.dy + rankingsMapTitleDrop / scale,
          size.width / scale,
          size.height / scale,
        ),
      ));
    }
    // A name is centred on its place, and so is the pin of an entry made of
    // it: the pin's own disc is the room the pin takes.
    final disc = RankingsMapPin.size / 2 / scale;
    return [
      for (final name in names.names)
        if (name.label.bounds.shift(name.corner) case final box
            when box.overlaps(view) &&
                !pins.any(
                  (pin) =>
                      (name.corner + name.label.at - pin.at).distance < disc ||
                      pin.title.overlaps(box),
                ))
          name,
    ];
  }

  @override
  void didUpdateWidget(RankingsTileLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    _titleSizes.clear();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _titleSizes.clear();
  }

  /// The theme last built and the colours it was built from. Reading a style
  /// parses all of its layers, which is not work to repeat on every rebuild.
  ({Color land, Color ink, Color accent, vtr.Theme theme})? _built;

  vtr.Theme _themeFor(Map<String, dynamic> base, ColorScheme scheme) {
    final built = _built;
    if (built != null &&
        built.land == scheme.surface &&
        built.ink == scheme.onSurface &&
        built.accent == scheme.primary) {
      return built.theme;
    }
    final theme = vtr.ThemeReader().read(
      voyagerMapStyle(
        base,
        land: scheme.surface,
        ink: scheme.onSurface,
        accent: scheme.primary,
        fontFamily: AppFonts.family,
      ),
    );
    _built = (
      land: scheme.surface,
      ink: scheme.onSurface,
      accent: scheme.primary,
      theme: theme,
    );
    return theme;
  }

  @override
  Widget build(BuildContext context) {
    final client = ref.watch(geoapifyClientProvider);
    final base = ref.watch(_baseStyleProvider).valueOrNull;
    if (client == null || base == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final theme = _themeFor(base, scheme);
    final camera = _camera = MapCamera.of(context);

    // The zoom the tiles on screen are drawn at, and so lay their names out
    // at.
    final zoom = camera.zoom.round();
    if (zoom < rankingsMapNameZoom) {
      _asked = null;
      _names = null;
    } else {
      final view = _viewAt(camera, zoom);
      unawaited(
        _ask(
          theme,
          zoom,
          view.left ~/ 256,
          view.top ~/ 256,
          view.right ~/ 256,
          view.bottom ~/ 256,
        ),
      );
    }
    final names = _names;
    _drawn = names == null ? const [] : _clearOfPins(context, camera, names);

    return Stack(
      fit: StackFit.expand,
      children: [
        _tiles(theme, client.apiKey),
        if (names != null)
          MobileLayerTransformer(
            child: IgnorePointer(
              child: CustomPaint(
                size: Size.infinite,
                painter: _NamesPainter(
                  names: _drawn,
                  lit: _lit,
                  litColor: scheme.primary,
                  scale: math.pow(2, camera.zoom - names.zoom).toDouble(),
                  origin: camera.pixelOrigin,
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _tiles(vtr.Theme theme, String apiKey) {
    return VectorTileLayer(
      controller: _controller,
      theme: theme,
      tileProviders: TileProviders({
        'default':
            ref.watch(rankingMapTileProviderProvider) ??
            NetworkVectorTileProvider(
              urlTemplate:
                  'https://maps.geoapify.com/v1/tile/vector/{z}/{x}/{y}.pbf'
                  '?apiKey=$apiKey',
              maximumZoom: 14,
            ),
      }),
      // Viewed tiles are kept on disk, so a revisited area draws offline and
      // spends no credits. A month: a street map does not go stale between
      // visits.
      fileCacheTtl: const Duration(days: 30),
      // Rendered tiles are stored per palette, so each theme fills it anew.
      fileCacheMaximumSizeInBytes: 200 * 1024 * 1024,
      // Tiles in flight is twice this. At the default 4, a fresh screen
      // queued behind the network and its last tile took 2.5–5 s to appear;
      // at 16, under 1 s.
      concurrency: 16,
      maximumZoom: rankingsMapMaxZoom,
    );
  }
}

/// Draws [names] where the tiles would have, and [lit] in [litColor].
class _NamesPainter extends CustomPainter {
  const _NamesPainter({
    required this.names,
    required this.lit,
    required this.litColor,
    required this.scale,
    required this.origin,
  });

  final List<_Name> names;
  final _Name? lit;
  final Color litColor;

  /// From the pixels the names were laid out in to the camera's, and the
  /// camera's corner in those.
  final double scale;
  final Offset origin;

  @override
  void paint(Canvas canvas, Size size) {
    for (final name in names) {
      final at = (name.corner + name.label.corner) * scale - origin;
      canvas
        ..save()
        ..translate(at.dx, at.dy)
        ..scale(scale);
      if (name == lit) {
        // The painter carries the map's own colour; only its shape is kept.
        canvas.saveLayer(
          null,
          Paint()..colorFilter = ColorFilter.mode(litColor, BlendMode.srcIn),
        );
      }
      name.label.painter.paint(canvas, Offset.zero);
      if (name == lit) canvas.restore();
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_NamesPainter old) =>
      old.names != names ||
      old.lit != lit ||
      old.litColor != litColor ||
      old.scale != scale ||
      old.origin != origin;
}

/// The credit the tile and data providers require, always on the map.
class RankingsMapAttribution extends StatelessWidget {
  const RankingsMapAttribution({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withValues(alpha: 0.75),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        'Powered by Geoapify · © OpenMapTiles · © OpenStreetMap contributors',
        style: theme.textTheme.labelSmall?.copyWith(
          fontSize: 9,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// What the map shows in place of itself when there is no Geoapify key.
class RankingsMapUnavailable extends StatelessWidget {
  const RankingsMapUnavailable({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Text(
        'Map unavailable — no Geoapify key',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// One pin: solid in [color] with the score on it once ranked, hollow with no
/// number while unranked.
class RankingsMapPin extends StatelessWidget {
  const RankingsMapPin({
    super.key,
    required this.color,
    this.score,
    this.selected = false,
  });

  /// The square a pin is laid out in, ring included.
  static const size = 40.0;

  final Color color;

  /// The formatted overall score, or null for an unranked entry.
  final String? score;

  /// The entry open in the panel: raised and ringed.
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ranked = score != null;
    return Center(
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: selected ? size : size - 10,
        height: selected ? size : size - 10,
        padding: EdgeInsets.all(selected ? 3 : 0),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: selected ? Border.all(color: color, width: 2) : null,
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: ranked ? color : theme.colorScheme.surface,
            border: ranked ? null : Border.all(color: color, width: 2.5),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: selected ? 0.35 : 0.2),
                blurRadius: selected ? 8 : 3,
                offset: const Offset(0, 1),
              ),
            ],
          ),
          child: Center(
            child: ranked
                ? Text(
                    score!,
                    maxLines: 1,
                    style: theme.textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: onColorLabel(color),
                    ),
                  )
                : null,
          ),
        ),
      ),
    );
  }
}
