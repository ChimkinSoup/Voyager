import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:voyager/domain/models/ranking_models.dart';
import 'package:voyager/domain/rankings/ranking_queries.dart';
import 'package:voyager/features/rankings/rankings_map_chrome.dart';
import 'package:voyager/features/rankings/rankings_providers.dart';

/// Finds the device once per run of the app, into
/// [rankingDevicePointProvider] — and only if it is already allowed to:
/// opening an entry never asks for permission. Saved, as the map's own Locate
/// is, for a later run to start from.
final _findDeviceProvider = FutureProvider<void>((ref) async {
  try {
    final permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever ||
        !await Geolocator.isLocationServiceEnabled()) {
      return;
    }
    await findRankingDevice(ref.read);
  } catch (_) {
    // Not found: the last run's fix, or the first location, stands in.
  }
});

/// A small map in the editor panel for a glance at where an entry is: every
/// one of its locations pinned, centred on the one nearest the device — for
/// a chain, the branch you would go to. It takes no drags or scrolls, so a
/// scroll over it still scrolls the panel; a press shows the location on the
/// big map.
///
/// Follows the entry as it changes — a location added, moved or removed — and
/// the device as it is found: whenever the nearest changes, so does the
/// centre.
class RankingLocationPreview extends ConsumerStatefulWidget {
  const RankingLocationPreview({
    super.key,
    required this.parent,
    required this.accent,
    this.onTap,
  });

  /// Has at least one location.
  final RankingParent parent;
  final Color accent;

  /// Shows the location the preview is centred on in the big map.
  final ValueChanged<RankingLocation>? onTap;

  static const height = 150.0;

  /// Also what the big map opens at from a press in list view, so it opens on
  /// the same streets.
  static const zoom = 17.0;

  @override
  ConsumerState<RankingLocationPreview> createState() =>
      _RankingLocationPreviewState();
}

class _RankingLocationPreviewState
    extends ConsumerState<RankingLocationPreview> {
  final _map = MapController();
  LatLng? _centre;

  @override
  void dispose() {
    _map.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    ref.watch(_findDeviceProvider);
    final device = ref.watch(rankingDeviceLocationProvider);

    final parent = widget.parent;
    LatLng at(RankingLocation location) =>
        LatLng(location.latitude, location.longitude);
    final points = [for (final location in parent.locations) at(location)];
    // The first in the entry's own order until the device is known.
    var nearest = parent.locations.first;
    if (device != null) {
      const distance = Distance();
      for (final location in parent.locations) {
        if (distance(device, at(location)) < distance(device, at(nearest))) {
          nearest = location;
        }
      }
    }
    // A location added, moved or removed, or the device found: the map is
    // already up, so it is moved rather than built again — to wherever the
    // last build of the frame left the centre.
    final centre = at(nearest);
    if (_centre != null && _centre != centre) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _map.move(_centre!, RankingLocationPreview.zoom);
      });
    }
    _centre = centre;

    final radius = BorderRadius.circular(12);
    final preview = SizedBox(
      height: RankingLocationPreview.height,
      child: DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          borderRadius: radius,
          border: Border.all(color: theme.dividerColor),
        ),
        child: ClipRRect(
          borderRadius: radius,
          child: Stack(
            fit: StackFit.expand,
            children: [
              IgnorePointer(
                child: FlutterMap(
                  mapController: _map,
                  options: MapOptions(
                    initialCenter: centre,
                    initialZoom: RankingLocationPreview.zoom,
                    maxZoom: rankingsMapMaxZoom,
                    backgroundColor: theme.colorScheme.surface,
                    interactionOptions: const InteractionOptions(
                      flags: InteractiveFlag.none,
                    ),
                  ),
                  children: [
                    RankingsTileLayer(
                      pins: [
                        for (final point in points) (point: point, title: ''),
                      ],
                    ),
                    MarkerLayer(
                      markers: [
                        for (final point in points)
                          Marker(
                            point: point,
                            width: RankingsMapPin.size,
                            height: RankingsMapPin.size,
                            child: RankingsMapPin(
                              color: widget.accent,
                              score: parent.isRanked
                                  ? formatRankingScore(parent.overallScore!)
                                  : null,
                              selected: point == centre,
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              if (points.length > 1 && device != null)
                Positioned(
                  left: 8,
                  top: 8,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surface.withValues(alpha: 0.92),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      'Nearest of ${points.length}',
                      style: theme.textTheme.labelSmall,
                    ),
                  ),
                ),
              const Positioned(
                left: 6,
                right: 6,
                bottom: 6,
                // Wraps rather than overflows at the panel's narrowest.
                child: Align(
                  alignment: Alignment.bottomLeft,
                  child: RankingsMapAttribution(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    final onTap = widget.onTap;
    if (onTap == null) return preview;
    return Tooltip(
      message: 'Open in the map',
      waitDuration: const Duration(milliseconds: 400),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(onTap: () => onTap(nearest), child: preview),
      ),
    );
  }
}
