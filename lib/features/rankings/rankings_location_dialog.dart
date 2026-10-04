import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/widgets/ctrl_enter_to_submit_scope.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/labeled_text_field.dart';
import 'package:voyager/core/widgets/voyager_dialog.dart';
import 'package:voyager/core/widgets/voyager_scroll_view.dart';
import 'package:voyager/data/remote/geoapify_client.dart';
import 'package:voyager/domain/models/ranking_models.dart';
import 'package:voyager/domain/rankings/google_maps_link.dart';
import 'package:voyager/domain/rankings/ranking_queries.dart';
import 'package:voyager/features/rankings/rankings_map_chrome.dart';
import 'package:voyager/features/rankings/rankings_providers.dart';

/// What the dialog hands back: a point, the address found for it, and — when
/// it was asked for one — the new entry's title.
typedef RankingLocationPick = ({
  double latitude,
  double longitude,
  String address,
  String title,
});

/// Finds a place three ways through one input and one small map: type its
/// name, paste a Google Maps link, or drop a pin. Whichever found it, the pin
/// can be nudged before it is added.
///
/// [near] is where a typed name is searched around and where the map opens
/// when there is no [initialPoint]. [existing] are the locations the entry
/// already has, which a new one may not sit on top of. [withTitle] adds the
/// title a new entry needs, starting as [initialTitle].
Future<RankingLocationPick?> showRankingLocationDialog(
  BuildContext context, {
  required Color accent,
  String heading = 'Add location',
  String submitLabel = 'Add',
  LatLng? initialPoint,
  String initialAddress = '',
  LatLng? near,
  List<RankingLocation> existing = const [],
  bool withTitle = false,
  String initialTitle = '',
}) => showVoyagerDialog<RankingLocationPick>(
  context: context,
  builder: (context) => _LocationDialog(
    accent: accent,
    heading: heading,
    submitLabel: submitLabel,
    initialPoint: initialPoint,
    initialAddress: initialAddress,
    near: near,
    existing: existing,
    withTitle: withTitle,
    initialTitle: initialTitle,
  ),
);

/// A drag that claims its pointer the moment it lands on the pin.
///
/// The pin sits on a map that pans on the same gesture, and left to compete
/// the map takes it: the pin rides along with the ground instead of moving
/// over it. Nothing else on the pin wants the pointer, so it can be taken
/// outright.
class _PinDragRecognizer extends PanGestureRecognizer {
  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    resolve(GestureDisposition.accepted);
  }
}

class _LocationDialog extends ConsumerStatefulWidget {
  const _LocationDialog({
    required this.accent,
    required this.heading,
    required this.submitLabel,
    required this.initialPoint,
    required this.initialAddress,
    required this.near,
    required this.existing,
    required this.withTitle,
    required this.initialTitle,
  });

  final Color accent;
  final String heading;
  final String submitLabel;
  final LatLng? initialPoint;
  final String initialAddress;
  final LatLng? near;
  final List<RankingLocation> existing;
  final bool withTitle;
  final String initialTitle;

  @override
  ConsumerState<_LocationDialog> createState() => _LocationDialogState();
}

class _LocationDialogState extends ConsumerState<_LocationDialog> {
  static const _searchDebounce = Duration(milliseconds: 300);
  static const _minSearchLength = 3;
  static const _pinZoom = 18.75;

  /// Smaller than the main map's pin, which crowds a map this small.
  static const _pinSize = 26.0;

  final _input = TextEditingController();
  final _inputFocus = FocusNode();
  final _title = TextEditingController();
  final _map = MapController();
  final _tiles = GlobalKey<RankingsTileLayerState>();
  Timer? _debounce;

  /// Whether the mouse is over a place to eat or drink's name or dot.
  var _overName = false;

  LatLng? _pin;
  String _address = '';
  String? _error;
  List<GeoapifyPlace> _suggestions = const [];
  bool _offerEverywhere = false;

  /// Every saved entry, for the matches listed while Geoapify is still
  /// answering. Empty until read.
  List<RankingParent> _saved = const [];

  /// Saved entries' locations whose title holds the typed text, listed above
  /// [_suggestions].
  List<GeoapifyPlace> _savedMatches = const [];

  static const _maxSavedMatches = 3;

  /// Bumped by every search and every geocode, so an answer that arrives
  /// after a newer question was asked is dropped.
  var _searchRequest = 0;
  var _geocodeRequest = 0;

  /// The search or short link waiting on the network, if any. Anything that
  /// drops its answer bumps [_searchRequest] past it, which takes the spinner
  /// down with it.
  int? _pendingSearch;
  bool get _searching => _pendingSearch == _searchRequest;

  /// The same for the address being looked up for the pin.
  int? _pendingGeocode;
  bool get _geocoding => _pendingGeocode == _geocodeRequest;

  /// What the list shows: saved matches first, then the places Geoapify found
  /// that aren't one of them.
  List<GeoapifyPlace> get _listed => [
    ..._savedMatches,
    for (final place in _suggestions)
      if (!_savedMatches.any((saved) => _samePlace(saved, place))) place,
  ];

  static bool _samePlace(GeoapifyPlace a, GeoapifyPlace b) =>
      const Distance().as(
        LengthUnit.Meter,
        LatLng(a.latitude, a.longitude),
        LatLng(b.latitude, b.longitude),
      ) <=
      rankingDuplicateLocationMeters;

  GeoapifyClient? get _client => ref.read(geoapifyClientProvider);

  @override
  void initState() {
    super.initState();
    _pin = widget.initialPoint;
    _address = widget.initialAddress;
    _title.text = widget.initialTitle;
    if (_pin != null && _address.isEmpty) unawaited(_reverseGeocode());
    unawaited(_loadSaved());
  }

  Future<void> _loadSaved() async {
    final categories = await ref.read(rankingCategoriesProvider.future);
    final saved = [
      for (final category in categories)
        ...await ref.read(rankingParentsProvider(category.id).future),
    ];
    if (mounted) _saved = saved;
  }

  /// The saved locations [text] names, nearest [_LocationDialog.near] first,
  /// leaving out those this entry already has.
  List<GeoapifyPlace> _matchSaved(String text) {
    final query = text.trim().toLowerCase();
    final near = widget.near;
    final matches = [
      for (final parent in _saved)
        if (parent.title.toLowerCase().contains(query))
          for (final location in parent.locations)
            if (!rankingHasLocationNear(
              widget.existing,
              location.latitude,
              location.longitude,
            ))
              (
                name: parent.title,
                address: location.address,
                latitude: location.latitude,
                longitude: location.longitude,
              ),
    ];
    if (near != null) {
      double away(GeoapifyPlace place) => const Distance().as(
        LengthUnit.Meter,
        near,
        LatLng(place.latitude, place.longitude),
      );
      matches.sort((a, b) => away(a).compareTo(away(b)));
    }
    return matches.take(_maxSavedMatches).toList();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _input.dispose();
    _inputFocus.dispose();
    _title.dispose();
    _map.dispose();
    super.dispose();
  }

  void _onInputChanged(String text) {
    _debounce?.cancel();
    _searchRequest++;
    final link = looksLikeLink(text);
    setState(() {
      _error = null;
      _suggestions = const [];
      _offerEverywhere = false;
      // Undebounced: they are read from memory, and shown while Geoapify is
      // still on its way.
      _savedMatches =
          link || _client == null || text.trim().length < _minSearchLength
          ? const []
          : _matchSaved(text);
    });
    // Debounced like a search: a link typed or edited by hand would otherwise
    // be resolved, and refused, once per character.
    if (link) {
      _debounce = Timer(_searchDebounce, () => unawaited(_resolveLink(text)));
      return;
    }
    if (_client == null || text.trim().length < _minSearchLength) return;
    _debounce = Timer(_searchDebounce, () => unawaited(_search()));
  }

  /// Enter runs the search or link still waiting out its debounce at once.
  void _onInputSubmitted(String text) {
    if (!(_debounce?.isActive ?? false)) return;
    _debounce!.cancel();
    unawaited(looksLikeLink(text) ? _resolveLink(text) : _search());
  }

  Future<void> _search({bool everywhere = false}) async {
    final client = _client;
    if (client == null) return;
    final request = ++_searchRequest;
    setState(() => _pendingSearch = request);
    final List<GeoapifyPlace> places;
    try {
      places = await client.searchPlaces(
        _input.text,
        latitude: widget.near?.latitude,
        longitude: widget.near?.longitude,
        everywhere: everywhere,
      );
    } catch (_) {
      if (!mounted || request != _searchRequest) return;
      setState(() {
        _pendingSearch = null;
        _error = 'Search needs a connection';
      });
      return;
    }
    if (!mounted || request != _searchRequest) return;
    _suggestions = places;
    final listed = _listed;
    // A single match is the place meant: pick it, so Ctrl+Enter alone saves.
    if (listed.length == 1) {
      _pickPlace(listed.single);
      return;
    }
    setState(() {
      _pendingSearch = null;
      _offerEverywhere = listed.isEmpty && !everywhere && widget.near != null;
      _error = listed.isEmpty
          ? 'No places found. Paste a Google Maps link or drop a pin.'
          : null;
    });
  }

  Future<void> _resolveLink(String text) async {
    final request = ++_searchRequest;
    var link = text.trim();
    final uri = Uri.tryParse(link);
    if (uri != null && isGoogleMapsShortLink(uri)) {
      setState(() => _pendingSearch = request);
      try {
        link = '${await ref.read(googleMapsShortLinkResolverProvider)(uri)}';
      } catch (_) {
        if (!mounted || request != _searchRequest) return;
        setState(() {
          _pendingSearch = null;
          _error = 'Short links need a connection';
        });
        return;
      }
      if (!mounted || request != _searchRequest) return;
    }
    final place = parseGoogleMapsLink(link);
    if (place == null) {
      setState(() {
        _pendingSearch = null;
        _error = "Couldn't find a location in that link";
      });
      return;
    }
    if (widget.withTitle && _title.text.trim().isEmpty && place.name != null) {
      _title.text = place.name!;
    }
    _setPin(LatLng(place.latitude, place.longitude));
    unawaited(_reverseGeocode());
  }

  /// Pins a searched [place], and names a new entry after it if it has no
  /// title yet.
  void _pickPlace(GeoapifyPlace place) {
    if (widget.withTitle && _title.text.trim().isEmpty) {
      _title.text = place.name;
    }
    _setPin(LatLng(place.latitude, place.longitude), address: place.address);
  }

  /// A press on a place to eat or drink's name or dot puts the pin on that
  /// place, and names a new entry after it if it has no title yet. Anywhere
  /// else, the pin goes where pressed.
  void _onTap(LatLng point) {
    final name = _tiles.currentState?.nameAt(point);
    if (name != null && widget.withTitle && _title.text.trim().isEmpty) {
      _title.text = name.text;
    }
    _setPin(name?.point ?? point);
    unawaited(_reverseGeocode());
  }

  /// Lights the place under the mouse at [position], if any; null once the
  /// mouse has left the map.
  void _onHover(Offset? position) {
    final over =
        _tiles.currentState?.light(
          position == null ? null : _map.camera.screenOffsetToLatLng(position),
        ) ??
        false;
    if (over != _overName) setState(() => _overName = over);
  }

  void _setPin(LatLng point, {String address = ''}) {
    // Whatever geocode is still out was asked about the pin's last position.
    _geocodeRequest++;
    // And a search still waiting or out would list its places under the pin.
    _debounce?.cancel();
    _searchRequest++;
    setState(() {
      _pin = point;
      _address = address;
      _error = null;
      _suggestions = const [];
      _savedMatches = const [];
      _offerEverywhere = false;
    });
    if (_client != null) {
      _map.move(
        point,
        _map.camera.zoom < _pinZoom ? _pinZoom : _map.camera.zoom,
      );
    }
  }

  /// Fills [_address] for wherever the pin settled. A failure leaves it
  /// blank: the coordinates are what is stored, and they are already right.
  Future<void> _reverseGeocode() async {
    final client = _client;
    final pin = _pin;
    if (client == null || pin == null) return;
    final request = ++_geocodeRequest;
    setState(() => _pendingGeocode = request);
    final String address;
    try {
      address = await client.reverseGeocode(pin.latitude, pin.longitude);
    } catch (_) {
      if (mounted && request == _geocodeRequest) {
        setState(() => _pendingGeocode = null);
      }
      return;
    }
    if (!mounted || request != _geocodeRequest) return;
    setState(() {
      _pendingGeocode = null;
      _address = address;
    });
  }

  void _dragPin(DragUpdateDetails details) {
    final camera = _map.camera;
    _geocodeRequest++;
    setState(() {
      // The address belonged to where the pin was. Blank until the drag ends
      // and a new one is found — and blank is what is stored if none is.
      _address = '';
      _pin = camera.screenOffsetToLatLng(
        camera.latLngToScreenOffset(_pin!) + details.delta,
      );
    });
  }

  void _submit() {
    // With places still listed, the first — the nearest — is the one meant.
    final listed = _listed;
    if (listed.isNotEmpty) _pickPlace(listed.first);
    final pin = _pin;
    if (pin == null) return;
    final title = _title.text.trim();
    if (widget.withTitle && title.isEmpty) {
      setState(() => _error = 'Give the entry a title');
      return;
    }
    if (rankingHasLocationNear(widget.existing, pin.latitude, pin.longitude)) {
      setState(() => _error = 'This entry already has a location here');
      return;
    }
    Navigator.pop(context, (
      latitude: pin.latitude,
      longitude: pin.longitude,
      address: _address,
      title: title,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasKey = ref.watch(geoapifyClientProvider) != null;
    final pin = _pin;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    return CtrlEnterToSubmitScope(
      onSubmit: _submit,
      child: AlertDialog(
        title: Text(widget.heading),
        content: SizedBox(
          width: 440,
          child: VoyagerScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (widget.withTitle) ...[
                  LabeledTextField(
                    label: 'Title',
                    controller: _title,
                    autofocus: true,
                    accentColor: widget.accent,
                    // Left to its default Enter takes the focus out of the
                    // field, up above the scope that hears Ctrl+Enter.
                    onEditingComplete: () {},
                  ),
                  const SizedBox(height: 12),
                ],
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    LabeledTextField(
                      label: hasKey
                          ? 'Place name or Google Maps link'
                          : 'Google Maps link',
                      controller: _input,
                      focusNode: _inputFocus,
                      autofocus: !widget.withTitle,
                      accentColor: widget.accent,
                      onChanged: _onInputChanged,
                      onSubmitted: _onInputSubmitted,
                      // Left to its default Enter takes the focus out of the
                      // field, up above the scope that hears Ctrl+Enter.
                      onEditingComplete: () {},
                    ),
                    if (_searching)
                      Positioned(
                        top: 0,
                        bottom: 0,
                        right: 14,
                        child: IgnorePointer(
                          child: Center(
                            child: SizedBox.square(
                              dimension: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: widget.accent,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                for (final place in _listed.take(5))
                  InkWell(
                    onTap: () {
                      _pickPlace(place);
                      // The row goes with the list, and the focus with it,
                      // up above the scope that hears Ctrl+Enter.
                      _inputFocus.requestFocus();
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 6,
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  place.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodySmall,
                                ),
                                Text(
                                  place.address,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: muted,
                                ),
                              ],
                            ),
                          ),
                          // One of your own entries, not a Geoapify find.
                          if (_savedMatches.contains(place))
                            Tooltip(
                              message: 'Saved entry',
                              child: Icon(
                                PhosphorIconsRegular.bookmarkSimple,
                                size: 14,
                                color: muted?.color,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                if (_error != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    _error!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ],
                if (_offerEverywhere) ...[
                  const SizedBox(height: 6),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: GlassButton(
                      dense: true,
                      label: 'Search everywhere',
                      onPressed: () => unawaited(_search(everywhere: true)),
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                SizedBox(
                  height: hasKey ? 240 : 48,
                  child: hasKey
                      ? ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              MouseRegion(
                                cursor: _overName
                                    ? SystemMouseCursors.click
                                    : MouseCursor.defer,
                                onHover: (event) =>
                                    _onHover(event.localPosition),
                                onExit: (_) => _onHover(null),
                                child: LayoutBuilder(
                                  builder: (context, constraints) {
                                    final minZoom = rankingsMapMinZoomAt(
                                      constraints.maxWidth,
                                    );
                                    // A wider map raises the floor, which the
                                    // camera only meets on its next move: meet
                                    // it now.
                                    WidgetsBinding.instance
                                        .addPostFrameCallback((_) {
                                          if (mounted &&
                                              _map.camera.zoom < minZoom) {
                                            _map.move(
                                              _map.camera.center,
                                              minZoom,
                                            );
                                          }
                                        });
                                    return FlutterMap(
                                      mapController: _map,
                                      options: MapOptions(
                                        initialCenter:
                                            pin ??
                                            widget.near ??
                                            const LatLng(20, 0),
                                        initialZoom: math.max(
                                          minZoom,
                                          pin != null || widget.near != null
                                              ? _pinZoom
                                              : 2,
                                        ),
                                        minZoom: minZoom,
                                        maxZoom: rankingsMapMaxZoom,
                                        backgroundColor:
                                            theme.colorScheme.surface,
                                        // Left to its default the map takes
                                        // the focus from the field above.
                                        interactionOptions:
                                            const InteractionOptions(
                                              keyboardOptions: KeyboardOptions(
                                                autofocus: false,
                                              ),
                                            ),
                                        onTap: (_, point) => _onTap(point),
                                      ),
                                      children: [
                                        RankingsTileLayer(
                                          key: _tiles,
                                          pins: [
                                            if (pin != null)
                                              (
                                                point: pin,
                                                title: '',
                                                titleFrom: double.infinity,
                                              ),
                                          ],
                                        ),
                                        if (pin != null)
                                          MarkerLayer(
                                            markers: [
                                              Marker(
                                                point: pin,
                                                width: _pinSize,
                                                height: _pinSize,
                                                child: RawGestureDetector(
                                                  gestures: {
                                                    _PinDragRecognizer:
                                                        GestureRecognizerFactoryWithHandlers<
                                                          _PinDragRecognizer
                                                        >(
                                                          _PinDragRecognizer
                                                              .new,
                                                          (
                                                            recognizer,
                                                          ) => recognizer
                                                            ..onUpdate =
                                                                _dragPin
                                                            ..onEnd = (_) =>
                                                                unawaited(
                                                                  _reverseGeocode(),
                                                                ),
                                                        ),
                                                  },
                                                  child: FittedBox(
                                                    child: SizedBox.square(
                                                      dimension:
                                                          RankingsMapPin.size,
                                                      child: RankingsMapPin(
                                                        color: widget.accent,
                                                        selected: true,
                                                      ),
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
                            ],
                          ),
                        )
                      : const RankingsMapUnavailable(),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        pin == null
                            ? hasKey
                                  ? 'Click the map to drop a pin.'
                                  : 'Paste a link with coordinates in it.'
                            : _address.isNotEmpty
                            ? _address
                            : '${pin.latitude.toStringAsFixed(5)}, '
                                  '${pin.longitude.toStringAsFixed(5)}',
                        style: muted,
                      ),
                    ),
                    if (_geocoding) ...[
                      const SizedBox(width: 8),
                      SizedBox.square(
                        dimension: 12,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.5,
                          color: widget.accent,
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
        actions: [
          GlassButton(
            onPressed: () => Navigator.pop(context),
            label: 'Cancel',
            dense: true,
          ),
          GlassButton(
            onPressed: _submit,
            enabled: pin != null,
            label: widget.submitLabel,
            color: widget.accent,
            dense: true,
          ),
        ],
      ),
    );
  }
}
