import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/core/widgets/confirm_dialog.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/labeled_text_field.dart';
import 'package:voyager/core/widgets/voyager_dialog.dart';
import 'package:voyager/core/widgets/voyager_toast.dart';
import 'package:voyager/features/rankings/rankings_map_chrome.dart';
import 'package:voyager/features/rankings/rankings_offline_maps.dart';
import 'package:voyager/features/rankings/rankings_providers.dart';

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB'];
  var value = bytes / 1024;
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(value >= 10 ? 0 : 1)} ${units[unit]}';
}

/// Shows a map to frame an area on and asks for its name, then downloads it
/// for offline use. Opens where the Rankings map was last left. Needs a
/// Geoapify key.
Future<void> showRankingOfflineDownloadDialog(BuildContext context) =>
    showVoyagerDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _DownloadDialog(),
    );

class _DownloadDialog extends ConsumerStatefulWidget {
  const _DownloadDialog();

  @override
  ConsumerState<_DownloadDialog> createState() => _DownloadDialogState();
}

class _DownloadDialogState extends ConsumerState<_DownloadDialog> {
  final _name = TextEditingController();
  final _map = MapController();

  /// The area the map shows, which is what downloads. Null until the map
  /// has laid out.
  LatLngBounds? _bounds;

  /// Keeps [_bounds] on what the map shows when the dialog resizes, which
  /// moves no camera and so fires no `onPositionChanged`.
  late final StreamSubscription<MapEvent> _resizes;

  /// Where the device was last found, marked on the map.
  late LatLng? _device = _savedDevice;

  /// Whether the map has been dragged or scrolled: a fix found on opening
  /// then leaves it where it was taken.
  var _touched = false;

  /// Tiles done so far, or null before the download starts.
  int? _done;
  var _cancelled = false;
  String? _error;

  late final _network = ref.read(rankingMapNetworkTilesProvider)!;
  late final _viewport = ref.read(rankingMapViewportProvider);
  late final _savedDevice = ref.read(rankingDeviceLocationProvider);

  /// How close a map on the device opens: about a town.
  static const _townZoom = 13.0;

  int _tileCountOf(LatLngBounds bounds) => rankingOfflineTileCount(
    bounds,
    _network.minimumZoom,
    _network.maximumZoom,
  );

  @override
  void initState() {
    super.initState();
    _resizes = _map.mapEventStream
        .where((event) => event is MapEventNonRotatedSizeChange)
        .listen(
          (event) => setState(() => _bounds = event.camera.visibleBounds),
        );
    // Where the Rankings map was left, else the device as last found, else
    // the device found now if it may be without asking.
    if (_viewport == null && _savedDevice == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _locate(ask: false);
      });
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _resizes.cancel();
    _map.dispose();
    super.dispose();
  }

  void _zoomBy(double delta) =>
      _map.move(_map.camera.center, _map.camera.zoom + delta);

  /// Centres the map on the device: the fix the system already holds, then a
  /// fresh one. From the Locate button ([ask]) it may prompt for permission
  /// and says why it could not; on opening it does neither.
  Future<void> _locate({required bool ask}) async {
    final overlay = Overlay.of(context, rootOverlay: true);
    // The button's own press is not the user moving away from its answer.
    if (ask) _touched = false;
    String problem;
    try {
      var permission = await Geolocator.checkPermission();
      if (ask && permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (!await Geolocator.isLocationServiceEnabled()) {
        problem = 'Location is turned off on this device';
      } else if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        problem = "Voyager isn't allowed to use your location";
      } else {
        // Windows answers this only from a fix under an hour old, and throws
        // rather than return null when it has none.
        final recent = await Geolocator.getLastKnownPosition().onError(
          (_, _) => null,
        );
        if (recent != null) {
          _showDevice(LatLng(recent.latitude, recent.longitude));
        }
        _showDevice(await findRankingDevice(ref.read));
        return;
      }
    } catch (_) {
      problem = "Couldn't find your location";
    }
    if (ask) showVoyagerToastIn(overlay, message: problem);
  }

  /// Marks [point] and moves there, zoomed in to about a town unless closer
  /// already. Not once the map has been moved since, or the download has
  /// started: the framing is fixed then.
  void _showDevice(LatLng point) {
    if (!mounted) return;
    setState(() => _device = point);
    if (_touched || _done != null) return;
    _map.move(point, math.max(_map.camera.zoom, _townZoom));
  }

  /// Whether a name is given and the framed area is small enough.
  bool get _canDownload {
    final bounds = _bounds;
    return _name.text.trim().isNotEmpty &&
        bounds != null &&
        _tileCountOf(bounds) <= rankingOfflineMaxTiles;
  }

  Future<void> _download() async {
    if (!_canDownload) return;
    final name = _name.text.trim();
    final bounds = _bounds!;
    setState(() {
      _done = 0;
      _error = null;
    });
    try {
      await ref
          .read(rankingOfflineAreasProvider.notifier)
          .download(
            name: name,
            bounds: bounds,
            network: _network,
            onProgress: (done) {
              if (mounted) setState(() => _done = done);
            },
            cancelled: () => _cancelled,
          );
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _done = null;
        _error =
            'The download stopped partway. Check your connection and try '
            'again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final done = _done;
    final bounds = _bounds;
    final tileCount = bounds == null ? null : _tileCountOf(bounds);
    final tooBig = tileCount != null && tileCount > rankingOfflineMaxTiles;
    final viewport = _viewport;

    return AlertDialog(
      title: const Text('Download an area'),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Pan and zoom until the map shows the area to keep. It stays on '
              'this device, so it draws without a connection.',
              style: muted,
            ),
            const SizedBox(height: 12),
            // Gives way in a short window rather than pushing the name off.
            Flexible(
              child: SizedBox(
                height: 300,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      // Held still once the download starts: it is fetching
                      // what was framed.
                      IgnorePointer(
                        ignoring: done != null,
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            final minZoom = rankingsMapMinZoomAt(
                              constraints.maxWidth,
                            );
                            return FlutterMap(
                              mapController: _map,
                              options: MapOptions(
                                initialCenter: viewport != null
                                    ? LatLng(
                                        viewport.latitude,
                                        viewport.longitude,
                                      )
                                    : _savedDevice ?? const LatLng(20, 0),
                                initialZoom: math.max(
                                  minZoom,
                                  viewport?.zoom ??
                                      (_savedDevice != null ? _townZoom : 2),
                                ),
                                minZoom: minZoom,
                                maxZoom: rankingsMapMaxZoom,
                                backgroundColor: theme.colorScheme.surface,
                                onMapReady: () => setState(
                                  () => _bounds = _map.camera.visibleBounds,
                                ),
                                onPositionChanged: (camera, hasGesture) =>
                                    setState(() {
                                      _bounds = camera.visibleBounds;
                                      if (hasGesture) _touched = true;
                                    }),
                              ),
                              children: [
                                const RankingsTileLayer(),
                                if (_device case final point?)
                                  MarkerLayer(
                                    markers: [
                                      Marker(
                                        point: point,
                                        width: 16,
                                        height: 16,
                                        child: DecoratedBox(
                                          decoration: BoxDecoration(
                                            shape: BoxShape.circle,
                                            color: theme.colorScheme.primary,
                                            border: Border.all(
                                              color: Colors.white,
                                              width: 2.5,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                              ],
                            );
                          },
                        ),
                      ),
                      const Positioned(
                        right: 4,
                        bottom: 4,
                        child: RankingsMapAttribution(),
                      ),
                      Positioned(
                        right: 8,
                        top: 8,
                        child: IgnorePointer(
                          ignoring: done != null,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              RankingsMapButton(
                                tooltip: 'Zoom in',
                                icon: PhosphorIconsRegular.plus,
                                onPressed: () => _zoomBy(1),
                              ),
                              const SizedBox(height: 4),
                              RankingsMapButton(
                                tooltip: 'Zoom out',
                                icon: PhosphorIconsRegular.minus,
                                onPressed: () => _zoomBy(-1),
                              ),
                              const SizedBox(height: 4),
                              RankingsMapButton(
                                tooltip: 'Show my location',
                                icon: PhosphorIconsRegular.crosshair,
                                onPressed: () => _locate(ask: true),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            if (done == null) ...[
              LabeledTextField(
                label: 'Name',
                controller: _name,
                hintText: 'e.g. Downtown',
                autofocus: true,
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => _download(),
              ),
              const SizedBox(height: 8),
              if (tooBig)
                Text(
                  'Too large to download ($tileCount tiles, the most is '
                  '$rankingOfflineMaxTiles). Zoom in.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                )
              else if (tileCount != null)
                Text('$tileCount tiles', style: muted),
            ] else ...[
              LinearProgressIndicator(value: done / tileCount!),
              const SizedBox(height: 8),
              Text('$done of $tileCount tiles', style: muted),
            ],
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        GlassButton(
          dense: true,
          label: 'Cancel',
          onPressed: () {
            _cancelled = true;
            Navigator.of(context).pop();
          },
        ),
        if (done == null)
          GlassButton(
            dense: true,
            label: 'Download',
            onPressed: _canDownload ? _download : null,
          ),
      ],
    );
  }
}

/// How much the downloaded areas take up, opening their list.
class RankingOfflineMapsTile extends ConsumerWidget {
  const RankingOfflineMapsTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final areas = ref.watch(rankingOfflineAreasProvider).valueOrNull;
    final bytes = areas?.fold<int>(0, (sum, area) => sum + area.byteSize);
    return ListTile(
      title: const Text('Offline maps'),
      subtitle: Text(
        areas == null
            ? 'Measuring…'
            : areas.isEmpty
            ? 'None yet'
            : '${areas.length} ${areas.length == 1 ? 'area' : 'areas'}'
                  ' · ${_formatBytes(bytes!)}',
      ),
      trailing: const Icon(PhosphorIconsRegular.mapTrifold),
      onTap: () => showVoyagerDialog<void>(
        context: context,
        builder: (_) => const _OfflineMapsDialog(),
      ),
    );
  }
}

class _OfflineMapsDialog extends ConsumerStatefulWidget {
  const _OfflineMapsDialog();

  @override
  ConsumerState<_OfflineMapsDialog> createState() => _OfflineMapsDialogState();
}

class _OfflineMapsDialogState extends ConsumerState<_OfflineMapsDialog> {
  var _busy = false;

  Future<void> _delete(List<RankingOfflineArea> areas) async {
    final confirmed = await showConfirmDialog(
      context,
      title: areas.length == 1
          ? 'Delete offline map'
          : 'Delete all offline maps',
      message: areas.length == 1
          ? 'Removes "${areas.single.name}" from this device. Its map will '
                'need a connection again.'
          : 'Removes all ${areas.length} areas from this device. Their maps '
                'will need a connection again.',
      confirmLabel: areas.length == 1 ? 'Delete' : 'Delete all',
    );
    if (!confirmed || !mounted) return;
    setState(() => _busy = true);
    final notifier = ref.read(rankingOfflineAreasProvider.notifier);
    for (final area in areas) {
      await notifier.delete(area.id);
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final areas = ref.watch(rankingOfflineAreasProvider).valueOrNull;
    final bytes = areas?.fold<int>(0, (sum, area) => sum + area.byteSize);
    final hasKey = ref.watch(rankingMapNetworkTilesProvider) != null;

    return AlertDialog(
      title: const Text('Offline maps'),
      contentPadding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
      content: SizedBox(
        width: 480,
        height: 360,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Areas of the Rankings map kept on this device, so they draw '
              'without a connection.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (bytes != null && areas!.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                '${_formatBytes(bytes)} on disk',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: 12),
            Expanded(
              child: areas == null
                  ? const Center(child: CircularProgressIndicator())
                  : areas.isEmpty
                  ? Center(
                      child: Text(
                        'No offline maps.',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  : ListView(
                      children: [
                        for (final area in areas)
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(area.name),
                            subtitle: Text(
                              '${_formatBytes(area.byteSize)}'
                              ' · ${area.tileCount} tiles',
                            ),
                            trailing: IconButton(
                              tooltip: 'Delete',
                              icon: Icon(
                                PhosphorIconsRegular.trash,
                                color: theme.colorScheme.error,
                              ),
                              onPressed: _busy ? null : () => _delete([area]),
                            ),
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
      actions: [
        if (areas != null && areas.length > 1)
          GlassButton(
            dense: true,
            onPressed: _busy ? null : () => _delete(areas),
            label: 'Delete all',
            color: theme.colorScheme.error,
          ),
        GlassButton(
          dense: true,
          // Without a key there is no map to frame an area on.
          onPressed: _busy || !hasKey
              ? null
              : () => showRankingOfflineDownloadDialog(context),
          label: 'Download an area',
        ),
        GlassButton(
          dense: true,
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          label: 'Close',
        ),
      ],
    );
  }
}
