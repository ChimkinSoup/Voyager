import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_marker_cluster/flutter_map_marker_cluster.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/theme/palette_color.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/core/widgets/context_menu.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/labeled_text_field.dart';
import 'package:voyager/core/widgets/voyager_dialog.dart';
import 'package:voyager/core/widgets/voyager_toast.dart';
import 'package:voyager/domain/models/ranking_models.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/rankings/ranking_queries.dart';
import 'package:voyager/features/rankings/rankings_actions.dart';
import 'package:voyager/features/rankings/rankings_icons.dart';
import 'package:voyager/features/rankings/rankings_location_dialog.dart';
import 'package:voyager/features/rankings/rankings_locations_section.dart';
import 'package:voyager/features/rankings/rankings_map_chrome.dart';
import 'package:voyager/features/rankings/rankings_providers.dart';
import 'package:voyager/features/rankings/rankings_score_input.dart';

/// An entry together with the category it is drawn and scored under. The All
/// categories map mixes categories, so a pin cannot assume the page's one.
typedef RankingMapEntry = ({RankingParent parent, RankingCategory category});

/// Entries as pins: one per location, each carrying its entry's score.
///
/// The map is a second way of looking at what the list shows, so it is handed
/// entries the search box, the status chips and the filters have already been
/// through, and changing those never moves the camera — only **Fit** does.
class RankingsMapView extends ConsumerStatefulWidget {
  const RankingsMapView({
    super.key,
    required this.entries,
    required this.scope,
    required this.createIn,
    required this.selectedParentId,
    required this.onOpen,
    this.onShowList,
    this.loading = false,
  });

  /// Whether [entries] is still being read. A map opened before its entries
  /// arrive has nothing to fit yet, and fits once when they do.
  final bool loading;

  /// What the search and filters left. Those without a location draw no pin
  /// and are counted on the chip instead.
  final List<RankingMapEntry> entries;

  /// Every entry the map could be asked to add a location to, filtered or not.
  final List<RankingMapEntry> scope;

  /// The categories a right-click may create an entry in. Empty in an
  /// archived category, which takes the map's own menu away with it.
  final List<RankingCategory> createIn;

  final String? selectedParentId;
  final ValueChanged<String> onOpen;

  /// Switches to the list, from the `N without a location` chip. Null where
  /// there is no list to switch to.
  final VoidCallback? onShowList;

  @override
  ConsumerState<RankingsMapView> createState() => _RankingsMapViewState();
}

class _RankingsMapViewState extends ConsumerState<RankingsMapView>
    with TickerProviderStateMixin {
  static const _fitPadding = EdgeInsets.all(56);
  static const _fitMaxZoom = 16.0;

  /// A few streets around the device, for Locate and an empty map's opening.
  static const _locateZoom = 18.75;

  /// How long a fix stands in for the device when a map opens. Within it, a
  /// map marks where the device was found rather than find it again, which
  /// takes up to 15 seconds and writes settings: switching categories, or
  /// showing an entry on the map, would otherwise do both every time.
  static const _fixFresh = Duration(minutes: 10);

  /// How hard the map brakes after a push: it glides `speed / 6` pixels, so
  /// a gentle 800 px/s push travels ~130 px and a hard 3000 px/s one ~500.
  /// flutter_map's own fling always travels the map's short side, however
  /// soft the push, so it is switched off for this.
  static const _glideFriction = 0.0025;
  static const _glideId = 'glide';

  static const _flyId = 'fly';
  late final AnimationController _fly;

  /// The flight [_fly] is on: the camera at a point along it, from 0 to 1,
  /// and where it ends.
  ({
    ({LatLng center, double zoom}) Function(double t) at,
    LatLng center,
    double zoom,
  })?
  _flight;

  final _map = MapController();

  /// The tiles, which know the names of places to eat and drink they drew
  /// and where — see [_onTap].
  final _tiles = GlobalKey<RankingsTileLayerState>();

  /// Whether the mouse is over a name that a press makes an entry of.
  var _overName = false;

  /// The pointer dragging the map, tracked from its own event timestamps.
  VelocityTracker? _dragVelocity;
  int? _dragPointer;
  late final AnimationController _glide;
  ({Offset from, Offset direction, double zoom})? _glidePath;

  /// Where the device was last found, drawn as a dot.
  LatLng? _devicePoint;

  /// Whether the map or its buttons have been pressed or scrolled since it
  /// opened. The camera itself is no guide: the opening fit lands a frame
  /// after the map does.
  var _touched = false;

  /// Hosts the context menu for whatever was right-clicked: the map and its
  /// pins hand it their items and a position, since the gesture that opens it
  /// is the map's own rather than a region's.
  final _menuKey = GlobalKey<ContextMenuRegionState>();
  List<ContextMenuItem> _menuItems = const [];

  /// Resolved while mounted: writes started from a menu or a timer finish
  /// after the map may have been closed, when its own `ref` is dead.
  late final ProviderContainer _container;

  /// The pins, kept until the entries change. The cluster layer starts its
  /// clusters over when handed a new list, and then no longer knows the one
  /// it has open: a press on that would close it and open it again. The open
  /// entry is listened for rather than built in, so opening one keeps them.
  late List<Marker> _pins = _markers();

  /// When each pin's title shows, by its marker's key — see [planPinTitles] —
  /// and the entries and title style it was planned for.
  ({
    List<RankingMapEntry> entries,
    TextStyle style,
    TextScaler scaler,
    Map<String, double> from,
  })?
  _titles;
  late final _selected = ValueNotifier(widget.selectedParentId);

  Timer? _viewportSave;

  /// The viewport the camera has moved to and nothing has stored yet.
  RankingsMapViewport? _unsavedViewport;

  /// Whether the opening fit is still owed — the map was mounted while its
  /// entries were loading. See [didUpdateWidget].
  late bool _fitPending;

  /// Where the map opens: wherever it was left earlier in this run of the
  /// app, or else where the device was last found on an earlier one, or else
  /// fitted to the pins visible at that moment — the last two until the
  /// device is found afresh. Read once — a later change to the filters must
  /// not move the camera.
  late final List<LatLng> _initialPoints = _points;
  late final RankingsMapViewport? _initialViewport = ref.read(
    rankingMapViewportProvider,
  );

  /// Where the device was last found, in this run or an earlier one, if
  /// anywhere: marked on every map until it is found afresh.
  late final LatLng? _lastDevice = ref.read(rankingDeviceLocationProvider);
  late final LatLng? _savedDevice = _initialViewport != null
      ? null
      : _lastDevice;

  @override
  void initState() {
    super.initState();
    _container = ProviderScope.containerOf(context, listen: false);
    _devicePoint = _lastDevice;
    _fitPending =
        widget.loading && _initialViewport == null && _savedDevice == null;
    _glide = AnimationController.unbounded(vsync: this)
      ..addListener(_glideStep);
    _fly = AnimationController(vsync: this)..addListener(_flyStep);
    if (!_fitPending) _findDeviceOnOpen();
  }

  @override
  void didUpdateWidget(RankingsMapView oldWidget) {
    super.didUpdateWidget(oldWidget);
    _selected.value = widget.selectedParentId;
    if (!listEquals(oldWidget.entries, widget.entries)) _pins = _markers();
    // The entries arrived after the map did: fit them now, once. Anything
    // later that changes the pins is a filter, and filters leave the camera
    // where it is.
    if (_fitPending && !widget.loading) {
      _fitPending = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _fit();
      });
      _findDeviceOnOpen();
    }
  }

  /// Finds the device, if it may already be found and was not found in the
  /// last [_fixFresh], to mark it. The first map of a run also opens there; a
  /// later one stays where the last was left.
  void _findDeviceOnOpen() {
    // Without a key there is no map mounted for the controller to move.
    if (ref.read(geoapifyClientProvider) == null) return;
    final foundAt = ref.read(rankingDeviceFoundAtProvider);
    if (foundAt != null && DateTime.now().difference(foundAt) < _fixFresh) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _locate(ask: false);
    });
  }

  /// Centres the map on the device in two steps, the fix the system already
  /// holds and then a fresh one, which is saved for the next run to open on.
  /// Usually each agrees with where the map already is, and it does not
  /// visibly move. From the Locate button ([ask]) it may prompt for
  /// permission and says why it could not; opening a map it does neither.
  Future<void> _locate({required bool ask}) async {
    final overlay = Overlay.of(context, rootOverlay: true);
    var found = false;
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
          found = _showDevice(
            LatLng(recent.latitude, recent.longitude),
            ask: ask,
          );
        }
        _showDevice(await findRankingDevice(_container.read), ask: ask);
        return;
      }
    } catch (_) {
      problem = "Couldn't find your location";
    }
    if (ask && !found) showVoyagerToastIn(overlay, message: problem);
  }

  /// Marks the device at [point] and moves there, unless the map has been
  /// touched since it was asked to, or opened where the last was left.
  /// Whether it moved. The Locate button flies there; opening the map jumps.
  bool _showDevice(LatLng point, {required bool ask}) {
    if (!mounted) return false;
    setState(() => _devicePoint = point);
    _container.read(rankingDevicePointProvider.notifier).state = point;
    if (_touched || (!ask && _initialViewport != null)) return false;
    if (!ask) {
      _map.move(point, _locateZoom);
      return true;
    }
    // A fresh fix arriving mid-flight keeps the zoom the flight was headed to.
    final zoom = _fly.isAnimating ? _flight!.zoom : _map.camera.zoom;
    _flyTo(point, zoom > _locateZoom ? zoom : _locateZoom);
    return true;
  }

  /// Takes the camera to [center] at [zoom] along van Wijk and Nuij's smooth
  /// zoom-and-pan, the path d3's interpolateZoom follows. A hop nearby is a
  /// brief, unhurried slide; a long way zooms out, crosses quickly and zooms
  /// back in, taking a little longer.
  void _flyTo(LatLng center, double zoom) {
    final camera = _map.camera;
    // Positions in world pixels at zoom 0, and the view's width in them.
    final from = camera.projectAtZoom(camera.center, 0);
    final delta = camera.projectAtZoom(center, 0) - from;
    final width = camera.nonRotatedSize.width;
    final w0 = width / math.pow(2, camera.zoom);
    final w1 = width / math.pow(2, zoom);
    final d = delta.distance;
    // The path's length, and the share of [delta] travelled and view width
    // at a distance s along it.
    final double length;
    final ({double u, double w}) Function(double s) along;
    if (d < 1e-12) {
      length = math.log(w1 / w0) / math.sqrt2;
      along = (s) => (u: 0, w: w0 * math.exp(math.sqrt2 * s));
    } else {
      final r0 = -_asinh((w1 * w1 - w0 * w0 + 4 * d * d) / (4 * w0 * d));
      final r1 = -_asinh((w1 * w1 - w0 * w0 - 4 * d * d) / (4 * w1 * d));
      length = (r1 - r0) / math.sqrt2;
      along = (s) => (
        u: w0 / (2 * d) * (_cosh(r0) * _tanh(math.sqrt2 * s + r0) - _sinh(r0)),
        w: w0 * _cosh(r0) / _cosh(math.sqrt2 * s + r0),
      );
    }
    if (length.abs() < 1e-3) {
      _map.move(center, zoom);
      return;
    }
    _flight = (
      at: (t) {
        final step = along(Curves.easeInOut.transform(t) * length);
        return (
          center: camera.unprojectAtZoom(from + delta * step.u, 0),
          zoom: math.log(width / step.w) / math.ln2,
        );
      },
      center: center,
      zoom: zoom,
    );
    // The length grows with the log of the distance, so a far flight lasts
    // a little longer but crosses each screen much faster.
    _fly
      ..duration = Duration(
        milliseconds: (300 + 120 * length.abs()).clamp(300, 2200).round(),
      )
      ..forward(from: 0);
  }

  void _flyStep() {
    final flight = _flight;
    if (flight == null) return;
    // Lands exactly where it was sent, whatever the rounding along the way.
    final at = _fly.value == 1
        ? (center: flight.center, zoom: flight.zoom)
        : flight.at(_fly.value);
    _map.move(at.center, at.zoom, id: _flyId);
  }

  List<LatLng> get _points => [
    for (final entry in widget.entries)
      for (final location in entry.parent.locations)
        LatLng(location.latitude, location.longitude),
  ];

  MapOptions _options(BuildContext context, double minZoom) => MapOptions(
    // While entries are loading, the pins so far are some categories' and not
    // others': the fit owed once they arrive is the only one.
    initialCameraFit:
        _fitPending ||
            _initialPoints.isEmpty ||
            _initialViewport != null ||
            _savedDevice != null
        ? null
        : CameraFit.coordinates(
            coordinates: _initialPoints,
            padding: _fitPadding,
            maxZoom: _fitMaxZoom,
          ),
    initialCenter: _initialViewport != null
        ? LatLng(_initialViewport.latitude, _initialViewport.longitude)
        : _savedDevice ?? const LatLng(20, 0),
    initialZoom: math.max(
      minZoom,
      _initialViewport?.zoom ?? (_savedDevice != null ? _locateZoom : 2),
    ),
    minZoom: minZoom,
    maxZoom: rankingsMapMaxZoom,
    // The style's own land colour, so a tile still loading is not a hole.
    backgroundColor: Theme.of(context).colorScheme.surface,
    interactionOptions: const InteractionOptions(
      flags: InteractiveFlag.all & ~InteractiveFlag.flingAnimation,
    ),
    onMapEvent: _onMapEvent,
    onPositionChanged: (camera, _) => _scheduleViewportSave(camera),
    onTap: (_, point) => _onTap(point),
    onSecondaryTap: (position, point) => _openMapMenu(position.global, point),
    onLongPress: (position, point) => _openMapMenu(position.global, point),
  );

  @override
  void dispose() {
    _viewportSave?.cancel();
    // A move still inside the debounce is stored rather than dropped — after
    // this frame, as a provider cannot be written while the tree is torn down.
    if (_unsavedViewport != null) Future.microtask(_saveViewport);
    _glide.dispose();
    _fly.dispose();
    _selected.dispose();
    _map.dispose();
    super.dispose();
  }

  void _onPointerDown(PointerDownEvent event) {
    _touched = true;
    _glide.stop();
    _fly.stop();
    // A second finger is a pinch, which ends as one and never glides.
    if (_dragPointer != null) return;
    _dragPointer = event.pointer;
    _dragVelocity = VelocityTracker.withKind(event.kind)
      ..addPosition(event.timeStamp, event.position);
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (event.pointer == _dragPointer) {
      _dragVelocity?.addPosition(event.timeStamp, event.position);
    }
  }

  void _onPointerEnd(PointerEvent event) {
    if (event.pointer == _dragPointer) _dragPointer = null;
  }

  void _onMapEvent(MapEvent event) {
    switch (event.source) {
      case MapEventSource.dragEnd:
        _startGlide(event.camera);
      case MapEventSource.mapController:
        // The zoom buttons, Fit and a focused location take the camera over.
        if (event is! MapEventMove || event.id != _glideId) _glide.stop();
        if (event is! MapEventMove || event.id != _flyId) _fly.stop();
      default:
        _glide.stop();
        _fly.stop();
    }
  }

  void _startGlide(MapCamera camera) {
    // The finger's velocity on screen; the camera centre travels against it,
    // turned into the map's own frame the way flutter_map turns a drag.
    final finger = _dragVelocity?.getVelocity().pixelsPerSecond ?? Offset.zero;
    final speed = finger.distance;
    // flutter_map's own threshold for a fling.
    if (speed < 800) return;
    final cos = math.cos(camera.rotationRad);
    final sin = math.sin(camera.rotationRad);
    final away = -finger / speed;
    _glidePath = (
      from: camera.projectAtZoom(camera.center),
      direction: Offset(
        cos * away.dx + sin * away.dy,
        cos * away.dy - sin * away.dx,
      ),
      zoom: camera.zoom,
    );
    _glide
      ..value = 0
      ..animateWith(
        FrictionSimulation(
          _glideFriction,
          0,
          speed.clamp(0, kMaxFlingVelocity).toDouble(),
        ),
      );
  }

  void _glideStep() {
    final path = _glidePath;
    if (path == null) return;
    _map.move(
      _map.camera.unprojectAtZoom(
        path.from + path.direction * _glide.value,
        path.zoom,
      ),
      path.zoom,
      id: _glideId,
    );
  }

  void _scheduleViewportSave(MapCamera camera) {
    _unsavedViewport = (
      latitude: camera.center.latitude,
      longitude: camera.center.longitude,
      zoom: camera.zoom,
    );
    _viewportSave?.cancel();
    _viewportSave = Timer(const Duration(milliseconds: 800), _saveViewport);
  }

  /// Remembers where the map is for the rest of this run. Not stored: the
  /// next launch opens on the device again.
  void _saveViewport() {
    final viewport = _unsavedViewport;
    if (viewport == null) return;
    _unsavedViewport = null;
    _container.read(rankingMapViewportProvider.notifier).state = viewport;
  }

  void _fit() {
    final points = _points;
    if (points.isEmpty) return;
    _map.fitCamera(
      CameraFit.coordinates(
        coordinates: points,
        padding: _fitPadding,
        maxZoom: _fitMaxZoom,
      ),
    );
  }

  /// Centres the map on [point], zoomed in at least as far as a fit would.
  void _focus(LatLng point) {
    final zoom = _map.camera.zoom;
    _map.move(point, zoom < _fitMaxZoom ? _fitMaxZoom : zoom);
  }

  void _zoomBy(double delta) =>
      _map.move(_map.camera.center, _map.camera.zoom + delta);

  void _showMenu(Offset globalPosition, List<ContextMenuItem> items) {
    if (items.isEmpty) return;
    _menuItems = items;
    _menuKey.currentState?.openMenuAt(globalPosition);
  }

  // ------------------------------------------------------------ the empty map

  void _openMapMenu(Offset globalPosition, LatLng point) {
    if (widget.createIn.isEmpty) return;
    _showMenu(globalPosition, [
      ContextMenuItem(
        label: 'New entry here',
        icon: PhosphorIconsRegular.plus,
        onTap: () => _newEntryAt(point),
      ),
      if (widget.scope.isNotEmpty)
        ContextMenuItem(
          label: 'Add this location to an existing entry…',
          icon: PhosphorIconsRegular.mapPinPlus,
          onTap: () => _addToExisting(point),
        ),
    ]);
  }

  /// A press on the name of a place to eat or drink starts an entry there,
  /// under that name. Anywhere else on the map it does nothing.
  void _onTap(LatLng point) {
    if (widget.createIn.isEmpty) return;
    final name = _tiles.currentState?.nameAt(point);
    if (name != null) unawaited(_newEntryAt(name.point, title: name.text));
  }

  /// Lights the pressable name under the mouse at [position], if any; null
  /// once the mouse has left the map.
  void _onHover(Offset? position) {
    if (widget.createIn.isEmpty) return;
    final over =
        _tiles.currentState?.light(
          position == null ? null : _map.camera.screenOffsetToLatLng(position),
        ) ??
        false;
    if (over != _overName) setState(() => _overName = over);
  }

  Future<void> _newEntryAt(LatLng point, {String title = ''}) async {
    final actions = RankingsActions.detached(_container);
    final category = widget.createIn.length == 1
        ? widget.createIn.single
        : await _pickCategory(context, widget.createIn);
    if (category == null || !mounted) return;
    final pick = await showRankingLocationDialog(
      context,
      accent: paletteColor(category.colorValue, context),
      heading: 'New ${category.name} entry',
      initialPoint: point,
      near: _map.camera.center,
      withTitle: true,
      initialTitle: title,
    );
    if (pick == null) return;
    final created = await actions.createParentAt(
      categoryId: category.id,
      title: pick.title,
      latitude: pick.latitude,
      longitude: pick.longitude,
      address: pick.address,
    );
    if (!mounted) return;
    _focus(LatLng(pick.latitude, pick.longitude));
    widget.onOpen(created.id);
  }

  Future<void> _addToExisting(LatLng point) async {
    final actions = RankingsActions.detached(_container);
    final client = ref.read(geoapifyClientProvider);
    final overlay = Overlay.of(context, rootOverlay: true);
    final entry = await _pickEntry(context, widget.scope);
    if (entry == null) return;
    var address = '';
    // The address lookup alone can take seconds, with nothing on the map yet.
    final toast = client == null
        ? null
        : showVoyagerToastIn(overlay, message: 'Adding location…');
    try {
      address =
          await client?.reverseGeocode(point.latitude, point.longitude) ?? '';
    } catch (_) {
      // Offline or timed out: the point is what is stored, and it is already
      // right.
    }
    final added = await actions.addLocation(
      entry.parent.id,
      latitude: point.latitude,
      longitude: point.longitude,
      address: address,
    );
    if (mounted) _focus(point);
    if (!added) {
      if (toast != null) {
        toast.update(
          message: 'This entry already has a location here',
          icon: PhosphorIconsRegular.info,
          dwell: const Duration(seconds: 4),
        );
      } else {
        showVoyagerToastIn(
          overlay,
          message: 'This entry already has a location here',
        );
      }
    } else {
      toast?.dismiss();
    }
  }

  // ------------------------------------------------------------------- a pin

  void _openPinMenu(
    BuildContext pinContext,
    Offset globalPosition,
    RankingMapEntry entry,
    RankingLocation location,
  ) {
    final parent = entry.parent;
    final category = entry.category;
    final actions = RankingsActions.detached(_container);
    final accent = paletteColor(category.colorValue, context);
    _showMenu(globalPosition, [
      ContextMenuItem(
        label: 'Open',
        icon: PhosphorIconsRegular.arrowSquareOut,
        onTap: () => widget.onOpen(parent.id),
      ),
      if (!category.isArchived) ...[
        ContextMenuItem(
          label: 'Rate…',
          icon: PhosphorIconsRegular.star,
          onTap: () async {
            if (!pinContext.mounted) return;
            final outcome = await showRankingScorePopover(
              context: context,
              anchorContext: pinContext,
              value: parent.overallScore,
              scoreMax: category.parentScoreMax,
              precision: category.parentScorePrecision,
              label: parent.title.isEmpty ? 'Entry' : parent.title,
              accentColor: accent,
            );
            if (outcome == null || outcome.cancelled) return;
            await actions.setOverallScore(parent.id, outcome.score);
          },
        ),
        ContextMenuItem(
          label: 'Edit location…',
          icon: PhosphorIconsRegular.mapPin,
          onTap: () async {
            final moved = await editRankingLocation(
              context,
              accent: accent,
              location: location,
              siblings: parent.locations,
            );
            if (moved != null) await actions.updateLocation(parent.id, moved);
          },
        ),
        ContextMenuItem(
          label: 'Remove this location',
          icon: PhosphorIconsRegular.trash,
          isDestructive: true,
          onTap: () => removeRankingLocationWithUndo(
            context,
            ref,
            parentId: parent.id,
            location: location,
          ),
        ),
      ],
    ]);
  }

  List<Marker> _markers() => [
    for (final entry in widget.entries)
      for (final location in entry.parent.locations)
        Marker(
          key: ValueKey('${entry.parent.id}/${location.id}'),
          point: LatLng(location.latitude, location.longitude),
          width: RankingsMapPin.size,
          height: RankingsMapPin.size,
          child: _Pin(
            entry: entry,
            location: location,
            selected: _selected,
            onOpen: () => widget.onOpen(entry.parent.id),
            onMenu: (pinContext, position) =>
                _openPinMenu(pinContext, position, entry, location),
          ),
        ),
  ];

  Map<String, double> _titlesFrom(ThemeData theme, TextScaler scaler) {
    final style = rankingsMapTitleStyle(theme);
    final titles = _titles;
    if (titles != null &&
        identical(titles.entries, widget.entries) &&
        titles.style == style &&
        titles.scaler == scaler) {
      return titles.from;
    }
    final keys = <String>[];
    final pins = <({Offset at, Size title, double key})>[];
    for (final entry in widget.entries) {
      final parent = entry.parent;
      final title = parent.title.isEmpty
          ? Size.zero
          : rankingsMapTitleSize(parent.title, style, scaler);
      for (final location in parent.locations) {
        keys.add('${parent.id}/${location.id}');
        pins.add((
          at: const Epsg3857().latLngToOffset(
            LatLng(location.latitude, location.longitude),
            rankingsMapNameZoom.toDouble(),
          ),
          title: title,
          // The best scored keeps its title, the unscored last. Scores are
          // compared as a share of their category's scale.
          key: parent.isRanked
              ? -parent.overallScore! / entry.category.parentScoreMax
              : double.infinity,
        ));
      }
    }
    final plan = planPinTitles(pins, zoom: rankingsMapNameZoom);
    final from = {for (var i = 0; i < keys.length; i++) keys[i]: plan[i]};
    _titles = (
      entries: widget.entries,
      style: style,
      scaler: scaler,
      from: from,
    );
    return from;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // A row clicked in the editor's Locations section: pan to it, then clear
    // the request so the same row can ask again.
    ref.listen(rankingMapFocusProvider, (_, location) {
      if (location == null) return;
      // Without a key there is no map mounted for the controller to move.
      if (ref.read(geoapifyClientProvider) != null) {
        _focus(LatLng(location.latitude, location.longitude));
      }
      ref.read(rankingMapFocusProvider.notifier).state = null;
    });
    if (ref.watch(geoapifyClientProvider) == null) {
      return const RankingsMapUnavailable();
    }

    final withoutLocation = widget.entries
        .where((entry) => entry.parent.locations.isEmpty)
        .length;

    // Watched here: the map itself is built at layout, inside its builder.
    final showZoom = ref.watch(rankingMapShowZoomProvider);

    // Inset from the page's gutters and rounded like a card, so the map sits
    // in the page rather than filling it edge to edge.
    final radius = BorderRadius.circular(18);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
      child: DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          borderRadius: radius,
          border: Border.all(color: theme.dividerColor),
        ),
        child: ClipRRect(
          borderRadius: radius,
          child: _mapStack(theme, withoutLocation, showZoom),
        ),
      ),
    );
  }

  Widget _mapStack(ThemeData theme, int withoutLocation, bool showZoom) {
    final titlesFrom = _titlesFrom(theme, MediaQuery.textScalerOf(context));
    return Stack(
      fit: StackFit.expand,
      children: [
        Listener(
          onPointerDown: _onPointerDown,
          onPointerMove: _onPointerMove,
          onPointerUp: _onPointerEnd,
          onPointerCancel: _onPointerEnd,
          onPointerSignal: (_) => _touched = true,
          child: MouseRegion(
            cursor: _overName ? SystemMouseCursors.click : MouseCursor.defer,
            onHover: (event) => _onHover(event.localPosition),
            onExit: (_) => _onHover(null),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final minZoom = rankingsMapMinZoomAt(constraints.maxWidth);
                // A wider map raises the floor, which the camera only meets
                // on its next move: meet it now.
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted && _map.camera.zoom < minZoom) {
                    _map.move(_map.camera.center, minZoom);
                  }
                });
                return _TitlesFrom(
                  from: titlesFrom,
                  child: FlutterMap(
                    mapController: _map,
                    options: _options(context, minZoom),
                    children: [
                      RankingsTileLayer(
                        key: _tiles,
                        pins: [
                          for (final entry in widget.entries)
                            for (final location in entry.parent.locations)
                              (
                                point: LatLng(
                                  location.latitude,
                                  location.longitude,
                                ),
                                title: entry.parent.title,
                                titleFrom:
                                    titlesFrom['${entry.parent.id}/${location.id}'] ??
                                    double.infinity,
                              ),
                        ],
                      ),
                      if (_devicePoint case final point?)
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
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withValues(
                                        alpha: 0.3,
                                      ),
                                      blurRadius: 3,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      MarkerClusterLayerWidget(
                        // The layer reads the floor, rounded up, once: it is
                        // built anew when a resize moves that, or a floor
                        // lowered under it leaves every pin out of a cluster.
                        key: ValueKey(minZoom.ceil()),
                        options: MarkerClusterLayerOptions(
                          markers: _pins,
                          maxClusterRadius: 44,
                          size: const Size(38, 38),
                          padding: _fitPadding,
                          // A pressed cluster zooms until its pins part. At the
                          // package's own 17, close pins took a second press.
                          maxZoom: rankingsMapMaxZoom,
                          // The package moves the camera and only then brings the
                          // pins out, half a second each, the first easing to a
                          // crawl and the second starting from one: a visible wait
                          // between the two.
                          animationsOptions: const AnimationsOptions(
                            fitBound: Duration(milliseconds: 300),
                            fitBoundCurves: Curves.easeInOut,
                            zoom: Duration(milliseconds: 200),
                            spiderfy: Duration(milliseconds: 200),
                            fadeInCurve: Curves.easeOut,
                            clusterExpandCurve: Curves.easeOut,
                            spiderifyCurve: Curves.easeOut,
                          ),
                          showPolygon: false,
                          // The pins take their own taps, right-clicks and long-presses.
                          markerChildBehavior: true,
                          builder: (context, markers) =>
                              _ClusterBubble(count: markers.length),
                        ),
                      ),
                      if (showZoom) const _ZoomReadout(),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
        Positioned(
          left: 0,
          top: 0,
          child: ContextMenuRegion(
            key: _menuKey,
            itemsBuilder: () => _menuItems,
            child: const SizedBox.shrink(),
          ),
        ),
        if (withoutLocation > 0 && widget.onShowList != null)
          Positioned(
            left: 12,
            top: 12,
            child: Material(
              color: theme.colorScheme.surface.withValues(alpha: 0.92),
              borderRadius: BorderRadius.circular(VoyagerTheme.fieldRadius),
              elevation: 1,
              child: InkWell(
                onTap: widget.onShowList,
                borderRadius: BorderRadius.circular(VoyagerTheme.fieldRadius),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  child: Text(
                    '$withoutLocation without a location',
                    style: theme.textTheme.labelSmall,
                  ),
                ),
              ),
            ),
          ),
        const Positioned(left: 8, bottom: 8, child: RankingsMapAttribution()),
        Positioned(
          // Top rather than bottom: the page's Add button sits bottom right.
          right: 12,
          top: 12,
          child: Listener(
            onPointerDown: (_) => _touched = true,
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
                  tooltip: 'Fit all pins',
                  icon: PhosphorIconsRegular.cornersOut,
                  onPressed: _fit,
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
    );
  }
}

class _Pin extends StatelessWidget {
  const _Pin({
    required this.entry,
    required this.location,
    required this.selected,
    required this.onOpen,
    required this.onMenu,
  });

  final RankingMapEntry entry;
  final RankingLocation location;

  /// The id of the entry open in the panel.
  final ValueListenable<String?> selected;
  final VoidCallback onOpen;
  final void Function(BuildContext pinContext, Offset globalPosition) onMenu;

  @override
  Widget build(BuildContext context) {
    final parent = entry.parent;
    final title = parent.title.isEmpty ? 'Untitled' : parent.title;
    final pin = _pin(context, title);
    final titleFrom =
        _TitlesFrom.of(context)['${parent.id}/${location.id}'] ??
        double.infinity;
    // Spread out of a cluster, it has room its point does not: a pin sharing
    // a spot with another never earns its title by zooming.
    if (!MarkerSpiderfied.of(context) &&
        MapCamera.of(context).zoom < titleFrom) {
      return pin;
    }
    // Under the pin and outside its box, so the title takes no presses and
    // the pin stays centred on its point.
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(child: pin),
        Positioned(
          top: RankingsMapPin.size / 2 + rankingsMapTitleDrop,
          left: (RankingsMapPin.size - rankingsMapTitleWidth) / 2,
          width: rankingsMapTitleWidth,
          child: IgnorePointer(
            child: Text(
              parent.title,
              textAlign: TextAlign.center,
              maxLines: rankingsMapTitleLines,
              overflow: TextOverflow.ellipsis,
              style: rankingsMapTitleStyle(Theme.of(context)),
            ),
          ),
        ),
      ],
    );
  }

  Widget _pin(BuildContext context, String title) {
    final parent = entry.parent;
    return Tooltip(
      message: '$title · ${location.displayName}',
      waitDuration: const Duration(milliseconds: 400),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onOpen,
          onSecondaryTapUp: (details) =>
              onMenu(context, details.globalPosition),
          onLongPressStart: (details) =>
              onMenu(context, details.globalPosition),
          child: ValueListenableBuilder(
            valueListenable: selected,
            builder: (context, selectedId, _) => RankingsMapPin(
              color: paletteColor(entry.category.colorValue, context),
              score: parent.isRanked
                  ? formatRankingScore(parent.overallScore!)
                  : null,
              selected: parent.id == selectedId,
            ),
          ),
        ),
      ),
    );
  }
}

/// When each pin's title shows, by its marker's key — see [planPinTitles].
class _TitlesFrom extends InheritedWidget {
  const _TitlesFrom({required this.from, required super.child});

  final Map<String, double> from;

  static Map<String, double> of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_TitlesFrom>()!.from;

  @override
  bool updateShouldNotify(_TitlesFrom oldWidget) => from != oldWidget.from;
}

/// Pins too close to tell apart at this zoom, as a count. Neutral rather than
/// accent-coloured: on the All categories map it can hold several categories.
class _ClusterBubble extends StatefulWidget {
  const _ClusterBubble({required this.count});

  final int count;

  @override
  State<_ClusterBubble> createState() => _ClusterBubbleState();
}

class _ClusterBubbleState extends State<_ClusterBubble> {
  /// Whether the mouse is over it: lit in the accent, as a pressable name is.
  var _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: theme.colorScheme.surface,
          border: Border.all(
            color: _hovered
                ? theme.colorScheme.primary
                : theme.colorScheme.outline,
            width: _hovered ? 2 : 1,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.2),
              blurRadius: 3,
              offset: const Offset(0, 1),
            ),
          ],
        ),
        child: Center(
          child: Text(
            '${widget.count}',
            style: theme.textTheme.labelMedium?.copyWith(
              fontWeight: FontWeight.w700,
              color: _hovered ? theme.colorScheme.primary : null,
            ),
          ),
        ),
      ),
    );
  }
}

/// The camera's zoom level, for the Dev page's switch. A layer of the map, so
/// it follows the camera.
class _ZoomReadout extends StatelessWidget {
  const _ZoomReadout();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return IgnorePointer(
      child: Align(
        alignment: Alignment.bottomCenter,
        child: Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface.withValues(alpha: 0.92),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            'Zoom ${MapCamera.of(context).zoom.toStringAsFixed(2)}',
            style: theme.textTheme.labelSmall,
          ),
        ),
      ),
    );
  }
}

/// Which category a new entry goes in, asked on the All categories map.
Future<RankingCategory?> _pickCategory(
  BuildContext context,
  List<RankingCategory> categories,
) => showVoyagerDialog<RankingCategory>(
  context: context,
  builder: (context) => SimpleDialog(
    title: const Text('New entry in…'),
    children: [
      for (final category in categories)
        SimpleDialogOption(
          onPressed: () => Navigator.pop(context, category),
          child: _CategoryLabel(category: category),
        ),
    ],
  ),
);

class _CategoryLabel extends StatelessWidget {
  const _CategoryLabel({required this.category});

  final RankingCategory category;

  @override
  Widget build(BuildContext context) {
    final accent = paletteColor(category.colorValue, context);
    return Row(
      children: [
        Icon(rankingCategoryIcon(category.iconKey), size: 15, color: accent),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            category.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: accent,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}

/// Which entry a clicked point is added to: [scope] searchable by title, and
/// grouped by category when it spans more than one.
Future<RankingMapEntry?> _pickEntry(
  BuildContext context,
  List<RankingMapEntry> scope,
) => showVoyagerDialog<RankingMapEntry>(
  context: context,
  builder: (context) => _EntryPicker(scope: scope),
);

class _EntryPicker extends StatefulWidget {
  const _EntryPicker({required this.scope});

  final List<RankingMapEntry> scope;

  @override
  State<_EntryPicker> createState() => _EntryPickerState();
}

class _EntryPickerState extends State<_EntryPicker> {
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final query = _search.text.trim().toLowerCase();
    final matches = [
      for (final entry in widget.scope)
        if (entry.parent.title.toLowerCase().contains(query)) entry,
    ]..sort((a, b) => a.parent.title.compareTo(b.parent.title));
    final categories = <RankingCategory>[];
    for (final entry in widget.scope) {
      if (!categories.any((c) => c.id == entry.category.id)) {
        categories.add(entry.category);
      }
    }
    final grouped = categories.length > 1;

    return AlertDialog(
      title: const Text('Add location to…'),
      content: SizedBox(
        width: 360,
        height: 380,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            LabeledTextField(
              label: 'Search entries',
              controller: _search,
              autofocus: true,
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: matches.isEmpty
                  ? Center(
                      child: Text(
                        'No entries match',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  : ListView(
                      children: [
                        for (final category in categories) ...[
                          if (grouped &&
                              matches.any((e) => e.category.id == category.id))
                            Padding(
                              padding: const EdgeInsets.fromLTRB(8, 10, 8, 4),
                              child: _CategoryLabel(category: category),
                            ),
                          for (final entry in matches)
                            if (entry.category.id == category.id)
                              InkWell(
                                onTap: () => Navigator.pop(context, entry),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 7,
                                  ),
                                  child: Text(
                                    entry.parent.title.isEmpty
                                        ? 'Untitled'
                                        : entry.parent.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.bodySmall,
                                  ),
                                ),
                              ),
                        ],
                      ],
                    ),
            ),
          ],
        ),
      ),
      actions: [
        GlassButton(
          onPressed: () => Navigator.pop(context),
          label: 'Cancel',
          dense: true,
        ),
      ],
    );
  }
}

double _cosh(double x) => (math.exp(x) + math.exp(-x)) / 2;
double _sinh(double x) => (math.exp(x) - math.exp(-x)) / 2;
double _tanh(double x) => _sinh(x) / _cosh(x);

/// Exact for large [x] of either sign, where `log(x + sqrt(x² + 1))` is not.
double _asinh(double x) => x.sign * math.log(x.abs() + math.sqrt(x * x + 1));
