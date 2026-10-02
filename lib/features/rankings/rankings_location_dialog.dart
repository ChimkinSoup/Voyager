import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';
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
  final _title = TextEditingController();
  final _map = MapController();
  Timer? _debounce;

  LatLng? _pin;
  String _address = '';
  String? _error;
  List<GeoapifyPlace> _suggestions = const [];
  bool _offerEverywhere = false;

  /// Bumped by every search and every geocode, so an answer that arrives
  /// after a newer question was asked is dropped.
  var _searchRequest = 0;
  var _geocodeRequest = 0;

  GeoapifyClient? get _client => ref.read(geoapifyClientProvider);

  @override
  void initState() {
    super.initState();
    _pin = widget.initialPoint;
    _address = widget.initialAddress;
    _title.text = widget.initialTitle;
    if (_pin != null && _address.isEmpty) unawaited(_reverseGeocode());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _input.dispose();
    _title.dispose();
    _map.dispose();
    super.dispose();
  }

  void _onInputChanged(String text) {
    _debounce?.cancel();
    _searchRequest++;
    setState(() {
      _error = null;
      _suggestions = const [];
      _offerEverywhere = false;
    });
    // Debounced like a search: a link typed or edited by hand would otherwise
    // be resolved, and refused, once per character.
    if (looksLikeLink(text)) {
      _debounce = Timer(_searchDebounce, () => unawaited(_resolveLink(text)));
      return;
    }
    if (_client == null || text.trim().length < _minSearchLength) return;
    _debounce = Timer(_searchDebounce, () => unawaited(_search()));
  }

  Future<void> _search({bool everywhere = false}) async {
    final client = _client;
    if (client == null) return;
    final request = ++_searchRequest;
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
      setState(() => _error = 'Search needs a connection');
      return;
    }
    if (!mounted || request != _searchRequest) return;
    setState(() {
      _suggestions = places;
      _offerEverywhere = places.isEmpty && !everywhere && widget.near != null;
      _error = places.isEmpty
          ? 'No places found. Paste a Google Maps link or drop a pin.'
          : null;
    });
  }

  Future<void> _resolveLink(String text) async {
    final request = ++_searchRequest;
    var link = text.trim();
    final uri = Uri.tryParse(link);
    if (uri != null && isGoogleMapsShortLink(uri)) {
      try {
        link = '${await ref.read(googleMapsShortLinkResolverProvider)(uri)}';
      } catch (_) {
        if (!mounted || request != _searchRequest) return;
        setState(() => _error = 'Short links need a connection');
        return;
      }
      if (!mounted || request != _searchRequest) return;
    }
    final place = parseGoogleMapsLink(link);
    if (place == null) {
      setState(() => _error = "Couldn't find a location in that link");
      return;
    }
    if (widget.withTitle && _title.text.trim().isEmpty && place.name != null) {
      _title.text = place.name!;
    }
    _setPin(LatLng(place.latitude, place.longitude));
    unawaited(_reverseGeocode());
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
    final String address;
    try {
      address = await client.reverseGeocode(pin.latitude, pin.longitude);
    } catch (_) {
      return;
    }
    if (!mounted || request != _geocodeRequest) return;
    setState(() => _address = address);
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
                    accentColor: widget.accent,
                  ),
                  const SizedBox(height: 12),
                ],
                LabeledTextField(
                  label: hasKey
                      ? 'Place name or Google Maps link'
                      : 'Google Maps link',
                  controller: _input,
                  autofocus: true,
                  accentColor: widget.accent,
                  onChanged: _onInputChanged,
                ),
                for (final place in _suggestions.take(5))
                  InkWell(
                    onTap: () => _setPin(
                      LatLng(place.latitude, place.longitude),
                      address: place.address,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 6,
                      ),
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
                              LayoutBuilder(
                                builder: (context, constraints) {
                                  final minZoom = rankingsMapMinZoomAt(
                                    constraints.maxWidth,
                                  );
                                  // A wider map raises the floor, which the
                                  // camera only meets on its next move: meet
                                  // it now.
                                  WidgetsBinding.instance.addPostFrameCallback((
                                    _,
                                  ) {
                                    if (mounted && _map.camera.zoom < minZoom) {
                                      _map.move(_map.camera.center, minZoom);
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
                                        pin != null
                                            ? _pinZoom
                                            : widget.near != null
                                            ? 12
                                            : 2,
                                      ),
                                      minZoom: minZoom,
                                      maxZoom: rankingsMapMaxZoom,
                                      backgroundColor:
                                          theme.colorScheme.surface,
                                      onTap: (_, point) {
                                        _setPin(point);
                                        unawaited(_reverseGeocode());
                                      },
                                    ),
                                    children: [
                                      RankingsTileLayer(
                                        pins: [
                                          if (pin != null)
                                            (point: pin, title: ''),
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
                                                        _PinDragRecognizer.new,
                                                        (
                                                          recognizer,
                                                        ) => recognizer
                                                          ..onUpdate = _dragPin
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
                Text(
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
