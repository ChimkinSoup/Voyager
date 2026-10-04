// The Rankings map surface (RANKINGS_MAP_HLD.md): the List / Map toggle, pins
// that follow the same search and filters as the list, the menus on a pin and
// on the empty map, the Add location dialog's three ways of finding a place,
// the panel's Locations section, and the All categories map.
//
// Nothing here touches the network: tiles come from a blank provider, and
// Geoapify and the short-link resolver are answered in-process.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:vector_map_tiles/vector_map_tiles.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/labeled_text_field.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/geoapify_client.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/ranking_models.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/features/rankings/rankings_actions.dart';
import 'package:voyager/features/rankings/rankings_edit_panel.dart';
import 'package:voyager/features/rankings/rankings_header.dart';
import 'package:voyager/features/rankings/rankings_location_preview.dart';
import 'package:voyager/features/rankings/rankings_locations_section.dart';
import 'package:voyager/features/rankings/rankings_map_chrome.dart';
import 'package:voyager/features/rankings/rankings_map_view.dart';
import 'package:voyager/features/rankings/rankings_offline_maps.dart';
import 'package:voyager/features/rankings/rankings_offline_maps_dialogs.dart';
import 'package:voyager/features/rankings/rankings_page.dart';
import 'package:voyager/features/rankings/rankings_providers.dart';
import 'package:voyager/features/rankings/rankings_row.dart';
import 'package:voyager/features/rankings/rankings_score_input.dart';

import 'fakes/fake_weather_api_client.dart';

final _now = DateTime.utc(2026, 8, 1);

/// Tiles with nothing in them: an empty tile is a valid one, so the map
/// draws its background and no request is made.
class _BlankTiles extends VectorTileProvider {
  @override
  int get maximumZoom => 14;

  @override
  int get minimumZoom => 0;

  @override
  TileOffset get tileOffset => TileOffset.DEFAULT;

  @override
  Future<Uint8List> provide(TileIdentity tile) async => Uint8List(0);
}

RankingCategory makeCategory({
  String name = 'Restaurants',
  bool locationEnabled = true,
  int parentScoreMax = 5,
  int colorValue = 0xFF7C9EFF,
}) => RankingCategory(
  id: newId(),
  name: name,
  colorValue: colorValue,
  locationEnabled: locationEnabled,
  parentScoreMax: parentScoreMax,
  createdAt: _now,
  updatedAt: _now,
);

/// Branches a kilometre or so apart, so a fitted map draws them as separate
/// pins rather than one cluster.
RankingLocation branch(int n, {String label = ''}) => RankingLocation(
  id: 'loc-$n',
  latitude: 43.46 + n * 0.02,
  longitude: -80.52 + n * 0.02,
  address: '$n King Street North',
  label: label,
  sortOrder: n,
);

RankingParent makeParent({
  required String categoryId,
  required String title,
  double? score,
  List<RankingLocation> locations = const [],
  List<String> tags = const [],
}) => RankingParent(
  id: newId(),
  categoryId: categoryId,
  title: title,
  overallScore: score,
  locations: locations,
  tags: tags,
  createdAt: _now,
  updatedAt: _now,
);

/// Geoapify, answered in-process: one place for any search containing
/// `ennio`, two for `pasta`, nothing for anything else, and one address for
/// every point.
GeoapifyClient fakeGeoapify({List<Uri>? requests}) => GeoapifyClient(
  apiKey: 'test-key',
  httpClient: MockClient((request) async {
    requests?.add(request.url);
    final results = request.url.path.endsWith('/reverse')
        ? [
            {'formatted': '1 Reverse Street'},
          ]
        : (request.url.queryParameters['text'] ?? '').contains('ennio')
        ? [
            {
              'name': "Ennio's Pasta House",
              'formatted': '384 King Street North, Waterloo',
              'lat': 43.4833807,
              'lon': -80.5260427,
            },
          ]
        : (request.url.queryParameters['text'] ?? '').contains('pasta')
        ? [
            {
              'name': "Ennio's Pasta House",
              'formatted': '384 King Street North, Waterloo',
              'lat': 43.4833807,
              'lon': -80.5260427,
            },
            {
              'name': 'Pasta Bar',
              'formatted': '1 Pasta Lane, Waterloo',
              'lat': 43.47,
              'lon': -80.52,
            },
          ]
        : const <Map<String, dynamic>>[];
    return http.Response(
      jsonEncode({'results': results}),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
  }),
);

/// [fakeGeoapify], with the reverse geocode under the test's control: each
/// call waits on the next of [reverse], and an error there is a failed lookup.
GeoapifyClient heldGeoapify(List<Completer<String>> reverse) => GeoapifyClient(
  apiKey: 'test-key',
  httpClient: MockClient((request) async {
    http.Response results(List<Map<String, dynamic>> results) => http.Response(
      jsonEncode({'results': results}),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
    if (!request.url.path.endsWith('/reverse')) {
      return results([
        {
          'name': "Ennio's Pasta House",
          'formatted': '384 King Street North, Waterloo',
          'lat': 43.4833807,
          'lon': -80.5260427,
        },
      ]);
    }
    final held = Completer<String>();
    reverse.add(held);
    return results([
      {'formatted': await held.future},
    ]);
  }),
);

/// Geoapify with every search held until [held] completes, then finding two
/// pasta places. Addresses answer at once.
GeoapifyClient heldSearchGeoapify(Completer<void> held) => GeoapifyClient(
  apiKey: 'test-key',
  httpClient: MockClient((request) async {
    final reverse = request.url.path.endsWith('/reverse');
    if (!reverse) await held.future;
    return http.Response(
      jsonEncode({
        'results': reverse
            ? [
                {'formatted': '1 Reverse Street'},
              ]
            : [
                for (final name in ['Pasta Bar', 'Pasta Hut'])
                  {
                    'name': name,
                    'formatted': '1 Pasta Lane, Waterloo',
                    'lat': 43.47,
                    'lon': -80.52,
                  },
              ],
      }),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
  }),
);

Future<({AppDatabase db, ProviderContainer container})> pumpRankingsPage(
  WidgetTester tester, {
  required Future<void> Function(DriftRankingRepository repo) seed,
  GeoapifyClient? geoapify,
  bool withKey = true,
  RankingsDeviceLocation? deviceLocation,
  Future<Uri?> Function(Uri link)? shortLinks,
}) async {
  // The tile cache asks the platform for a temporary directory, and a widget
  // test has no plugin behind that channel.
  final cache = Directory.systemTemp.createTempSync('voyager_map_tiles');
  addTearDown(() => cache.deleteSync(recursive: true));
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('plugins.flutter.io/path_provider'),
    (call) async => cache.path,
  );

  tester.view.physicalSize = const Size(1600, 1200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final db = AppDatabase.inMemory();
  addTearDown(db.close);
  await seed(DriftRankingRepository(db));
  if (deviceLocation != null) {
    final settings = DriftSettingsRepository(db);
    await settings.getSettings(); // writes the row the save updates
    await settings.saveRankingsDeviceLocation(deviceLocation);
  }

  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      syncRepositoryProvider.overrideWithValue(InMemorySyncRepository()),
      weatherApiClientProvider.overrideWithValue(FakeWeatherApiClient()),
      geoapifyClientProvider.overrideWithValue(
        withKey ? geoapify ?? fakeGeoapify() : null,
      ),
      rankingMapTileProviderProvider.overrideWithValue(_BlankTiles()),
      googleMapsShortLinkResolverProvider.overrideWithValue(
        shortLinks ??
            (link) async => Uri.parse(
              'https://www.google.com/maps/place/Short+Link+Cafe/'
              'data=!3d43.5!4d-80.5',
            ),
      ),
    ],
  );
  addTearDown(container.dispose);
  await container.read(settingsProvider.future);
  final categories = await container.read(rankingCategoriesProvider.future);
  for (final category in categories) {
    await container.read(rankingParentsProvider(category.id).future);
    await container.read(rankingChildrenByParentProvider(category.id).future);
  }

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: RankingsPage()),
    ),
  );
  await tester.pumpAndSettle();
  return (db: db, container: container);
}

/// Lets the map's timers run out — its debounced viewport save, and the tile
/// layer's own delayed work — so none outlives the test.
Future<void> settleMap(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 12));
  await tester.pumpAndSettle();
}

/// [testWidgets], ending with [settleMap]: every test here mounts a map,
/// on the page or in the dialog.
void mapTest(String description, Future<void> Function(WidgetTester) body) =>
    testWidgets(description, (tester) async {
      await body(tester);
      await settleMap(tester);
    });

Future<void> openMap(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(InkWell, 'Map'));
  await tester.pumpAndSettle();
  await settleMap(tester);
}

/// Whether [element] is in the editor's preview rather than the map or the
/// location dialog — the page's helpers below mean the big map.
bool _inPreview(Element element) =>
    element.findAncestorWidgetOfExactType<RankingLocationPreview>() != null;

List<RankingsMapPin> pins(WidgetTester tester) => [
  for (final element in find.byType(RankingsMapPin).evaluate())
    if (!_inPreview(element)) element.widget as RankingsMapPin,
];

Future<List<RankingParent>> storedParents(AppDatabase db) async {
  final repo = DriftRankingRepository(db);
  return [
    for (final category in await repo.listCategories())
      ...await repo.listParents(category.id),
  ];
}

/// The text box of the labelled field called [label].
Finder labeledField(String label) => find.descendant(
  of: find.widgetWithText(LabeledTextField, label),
  matching: find.byType(TextField),
);

/// The dialog's own Add, not the page's Add button behind it.
Finder dialogAdd() =>
    find.descendant(of: find.byType(AlertDialog), matching: find.text('Add'));

/// The page map's camera.
MapCamera mapCamera(WidgetTester tester) => MapCamera.of(
  find.byType(RankingsTileLayer).evaluate().firstWhere((e) => !_inPreview(e)),
);

/// The device's location, answered in-process with permission granted:
/// [recent] gives the fix the system already holds, or null for none — which
/// throws, as Windows does — and [fresh] each new fix, when the test is ready.
void fakeDevice(
  WidgetTester tester, {
  required LatLng? Function() recent,
  required Future<LatLng> Function() fresh,
}) {
  Map<String, Object> position(LatLng point) => {
    'latitude': point.latitude,
    'longitude': point.longitude,
    'timestamp': 0,
  };
  const channel = MethodChannel('flutter.baseflow.com/geolocator');
  // Outlives the test otherwise, and moves the next test's map.
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      null,
    ),
  );
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    channel,
    (call) async => switch (call.method) {
      'checkPermission' => 2, // while in use
      'isLocationServiceEnabled' => true,
      'getLastKnownPosition' => position(
        recent() ?? (throw PlatformException(code: 'UNKNOWN_ERROR')),
      ),
      'getCurrentPosition' => position(await fresh()),
      _ => null,
    },
  );
}

void main() {
  mapTest('a category without locations has no map toggle', (tester) async {
    await pumpRankingsPage(
      tester,
      seed: (repo) async {
        final category = makeCategory(locationEnabled: false);
        await repo.upsertCategory(category);
        await repo.upsertParent(
          makeParent(categoryId: category.id, title: 'Lazeez'),
        );
      },
    );
    expect(find.text('Map'), findsNothing);
    expect(find.text('All categories'), findsNothing);
  });

  mapTest('the map draws a pin per location: scored solid, unranked '
      'hollow', (tester) async {
    await pumpRankingsPage(
      tester,
      seed: (repo) async {
        final category = makeCategory();
        await repo.upsertCategory(category);
        // A chain: one entry, two branches, one score.
        await repo.upsertParent(
          makeParent(
            categoryId: category.id,
            title: 'Lazeez',
            score: 4.5,
            locations: [branch(0), branch(1)],
          ),
        );
        await repo.upsertParent(
          makeParent(
            categoryId: category.id,
            title: 'Ennio',
            locations: [branch(2)],
          ),
        );
        await repo.upsertParent(
          makeParent(categoryId: category.id, title: 'Nowhere'),
        );
      },
    );
    expect(find.byType(RankingsMapView), findsNothing);

    await openMap(tester);

    expect(find.byType(RankingsRow), findsNothing);
    expect([for (final pin in pins(tester)) pin.score], ['4.5', '4.5', null]);
    // The entry with no location is off the map, and counted.
    expect(find.text('1 without a location'), findsOneWidget);
    expect(find.textContaining('OpenStreetMap contributors'), findsOneWidget);

    // The chip is the way back to where that entry can be seen.
    await tester.tap(find.text('1 without a location'));
    await tester.pumpAndSettle();
    expect(find.byType(RankingsMapView), findsNothing);
    expect(find.byType(RankingsRow), findsNWidgets(3));
    await settleMap(tester);
  });

  mapTest('the chosen view is kept per category', (tester) async {
    final harness = await pumpRankingsPage(
      tester,
      seed: (repo) async {
        final category = makeCategory();
        await repo.upsertCategory(category);
        await repo.upsertParent(
          makeParent(
            categoryId: category.id,
            title: 'Lazeez',
            locations: [branch(0)],
          ),
        );
      },
    );
    await openMap(tester);

    final settings = await DriftSettingsRepository(harness.db).getSettings();
    final category = (await DriftRankingRepository(
      harness.db,
    ).listCategories()).single;
    expect(settings.rankingsMapViewCategories, [category.id]);
  });

  mapTest('search and the status chips narrow the pins as they do the '
      'list', (tester) async {
    await pumpRankingsPage(
      tester,
      seed: (repo) async {
        final category = makeCategory();
        await repo.upsertCategory(category);
        await repo.upsertParent(
          makeParent(
            categoryId: category.id,
            title: 'Lazeez',
            score: 4,
            locations: [branch(0, label: 'Airport')],
          ),
        );
        await repo.upsertParent(
          makeParent(
            categoryId: category.id,
            title: 'Ennio',
            locations: [branch(2)],
          ),
        );
      },
    );
    await openMap(tester);
    expect(pins(tester), hasLength(2));

    await tester.enterText(find.byType(TextField), 'ennio');
    await tester.pumpAndSettle();
    expect([for (final pin in pins(tester)) pin.score], [null]);

    // A location's label is searchable too.
    await tester.enterText(find.byType(TextField), 'airport');
    await tester.pumpAndSettle();
    expect([for (final pin in pins(tester)) pin.score], ['4']);

    await tester.enterText(find.byType(TextField), '');
    await tester.pumpAndSettle();
    // The In progress chip leaves no queued entry, and every ranked one.
    await tester.tap(
      find.descendant(
        of: find.byType(RankingsStatsBand),
        matching: find.text('In progress'),
      ),
    );
    await tester.pumpAndSettle();
    expect([for (final pin in pins(tester)) pin.score], ['4']);
    await settleMap(tester);
  });

  mapTest('clicking a pin opens the entry, and its pins are marked', (
    tester,
  ) async {
    await pumpRankingsPage(
      tester,
      seed: (repo) async {
        final category = makeCategory();
        await repo.upsertCategory(category);
        await repo.upsertParent(
          makeParent(
            categoryId: category.id,
            title: 'Lazeez',
            score: 4,
            locations: [branch(0), branch(1)],
          ),
        );
        await repo.upsertParent(
          makeParent(
            categoryId: category.id,
            title: 'Ennio',
            locations: [branch(3)],
          ),
        );
      },
    );
    await openMap(tester);

    await tester.tap(find.byType(RankingsMapPin).first);
    await tester.pumpAndSettle();

    final panel = tester.widget<RankingsEditPanel>(
      find.byType(RankingsEditPanel),
    );
    expect(panel.parent.title, 'Lazeez');
    // Both of the chain's branches are ringed; the other entry's is not.
    expect([for (final pin in pins(tester)) pin.selected], [true, true, false]);
    // The panel lists the branches it has.
    expect(
      find.descendant(
        of: find.byType(RankingLocationsSection),
        matching: find.text('0 King Street North'),
      ),
      findsOneWidget,
    );
    await settleMap(tester);
  });

  mapTest('rating from one pin scores the entry on every branch', (
    tester,
  ) async {
    final harness = await pumpRankingsPage(
      tester,
      seed: (repo) async {
        final category = makeCategory();
        await repo.upsertCategory(category);
        await repo.upsertParent(
          makeParent(
            categoryId: category.id,
            title: 'Lazeez',
            locations: [branch(0), branch(1)],
          ),
        );
      },
    );
    await openMap(tester);
    expect([for (final pin in pins(tester)) pin.score], [null, null]);

    await tester.tap(
      find.byType(RankingsMapPin).first,
      buttons: kSecondaryButton,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rate…'));
    await tester.pumpAndSettle();
    expect(find.byType(RankingScorePopover), findsOneWidget);
    // Enter commits the midpoint the popover opened on.
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect((await storedParents(harness.db)).single.overallScore, 2.5);
    expect([for (final pin in pins(tester)) pin.score], ['2.5', '2.5']);
    await settleMap(tester);
  });

  mapTest('a pin removes its own branch only, and undo brings it back', (
    tester,
  ) async {
    final harness = await pumpRankingsPage(
      tester,
      seed: (repo) async {
        final category = makeCategory();
        await repo.upsertCategory(category);
        await repo.upsertParent(
          makeParent(
            categoryId: category.id,
            title: 'Lazeez',
            score: 4,
            locations: [branch(0), branch(1)],
          ),
        );
      },
    );
    await openMap(tester);

    await tester.tap(
      find.byType(RankingsMapPin).first,
      buttons: kSecondaryButton,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove this location'));
    await tester.pumpAndSettle();

    var locations = (await storedParents(harness.db)).single.locations;
    expect(locations, hasLength(1));
    expect(pins(tester), hasLength(1));

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    locations = (await storedParents(harness.db)).single.locations;
    expect([for (final l in locations) l.id], ['loc-0', 'loc-1']);
    await settleMap(tester);
    // Let the toast finish leaving.
    await tester.pump(const Duration(seconds: 10));
    await tester.pumpAndSettle();
  });

  mapTest('right-clicking the map creates a queued entry there', (
    tester,
  ) async {
    final harness = await pumpRankingsPage(
      tester,
      seed: (repo) async {
        final category = makeCategory();
        await repo.upsertCategory(category);
        await repo.upsertParent(
          makeParent(
            categoryId: category.id,
            title: 'Lazeez',
            score: 4,
            locations: [branch(0)],
          ),
        );
      },
    );
    await openMap(tester);

    final map = tester.getRect(find.byType(RankingsMapView));
    await tester.tapAt(
      map.center + const Offset(200, 120),
      buttons: kSecondaryButton,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('New entry here'));
    await tester.pumpAndSettle();

    // The title can be typed straight away; the dialog's map doesn't take
    // the focus.
    expect(
      tester
          .widget<EditableText>(
            find.descendant(
              of: labeledField('Title'),
              matching: find.byType(EditableText),
            ),
          )
          .focusNode
          .hasFocus,
      isTrue,
    );

    // The clicked point is reverse-geocoded into the dialog.
    expect(find.text('1 Reverse Street'), findsOneWidget);
    // A title is required.
    await tester.tap(dialogAdd());
    await tester.pumpAndSettle();
    expect(find.text('Give the entry a title'), findsOneWidget);

    await tester.enterText(labeledField('Title'), 'Ennio');
    await tester.tap(dialogAdd());
    await tester.pumpAndSettle();

    final created = (await storedParents(
      harness.db,
    )).singleWhere((parent) => parent.title == 'Ennio');
    expect(created.status, RankingStatus.queued);
    expect(created.isRanked, isFalse);
    expect(created.locations.single.address, '1 Reverse Street');
    // It opens, the same as an entry made with the Add button.
    expect(
      tester
          .widget<RankingsEditPanel>(find.byType(RankingsEditPanel))
          .parent
          .id,
      created.id,
    );
    expect(pins(tester), hasLength(2));
    await settleMap(tester);
  });

  mapTest('a name with one match is picked, so Ctrl+Enter alone adds the '
      'entry', (tester) async {
    final harness = await pumpRankingsPage(
      tester,
      geoapify: fakeGeoapify(),
      seed: (repo) async {
        final category = makeCategory();
        await repo.upsertCategory(category);
        await repo.upsertParent(
          makeParent(
            categoryId: category.id,
            title: 'Lazeez',
            locations: [branch(0)],
          ),
        );
      },
    );
    await openMap(tester);

    final map = tester.getRect(find.byType(RankingsMapView));
    await tester.tapAt(
      map.center + const Offset(200, 120),
      buttons: kSecondaryButton,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('New entry here'));
    await tester.pumpAndSettle();
    await tester.enterText(
      labeledField('Place name or Google Maps link'),
      'ennio',
    );
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    final created = (await storedParents(
      harness.db,
    )).singleWhere((parent) => parent.title == "Ennio's Pasta House");
    final location = created.locations.single;
    expect(location.latitude, 43.4833807);
    expect(location.longitude, -80.5260427);
    expect(location.address, '384 King Street North, Waterloo');
    await settleMap(tester);
  });

  mapTest('a spinner shows in the place field while a search is out', (
    tester,
  ) async {
    final held = Completer<void>();
    await pumpRankingsPage(
      tester,
      geoapify: heldSearchGeoapify(held),
      seed: (repo) async {
        final category = makeCategory();
        await repo.upsertCategory(category);
        await repo.upsertParent(
          makeParent(
            categoryId: category.id,
            title: 'Lazeez',
            locations: [branch(0)],
          ),
        );
      },
    );
    await openMap(tester);

    final map = tester.getRect(find.byType(RankingsMapView));
    await tester.tapAt(
      map.center + const Offset(200, 120),
      buttons: kSecondaryButton,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('New entry here'));
    await tester.pumpAndSettle();
    final field = labeledField('Place name or Google Maps link');
    await tester.enterText(field, 'pasta');
    final spinner = find.byType(CircularProgressIndicator);
    // Still inside the debounce: nothing has been asked yet.
    await tester.pump(const Duration(milliseconds: 100));
    expect(spinner, findsNothing);
    await tester.pump(const Duration(milliseconds: 300));
    expect(spinner, findsOneWidget);
    // Over the right end of the field.
    final fieldRect = tester.getRect(
      find.widgetWithText(LabeledTextField, 'Place name or Google Maps link'),
    );
    final spinnerRect = tester.getRect(spinner);
    expect(spinnerRect.right, lessThan(fieldRect.right));
    expect(spinnerRect.left, greaterThan(fieldRect.center.dx));
    expect(spinnerRect.center.dy, closeTo(fieldRect.center.dy, 1));

    held.complete();
    await tester.pumpAndSettle();
    expect(spinner, findsNothing);
    expect(find.text('Pasta Bar'), findsOneWidget);
    await settleMap(tester);
  });

  mapTest('Enter searches at once and keeps the field, so Ctrl+Enter adds '
      'the entry', (tester) async {
    final harness = await pumpRankingsPage(
      tester,
      seed: (repo) async {
        final category = makeCategory();
        await repo.upsertCategory(category);
        await repo.upsertParent(
          makeParent(
            categoryId: category.id,
            title: 'Lazeez',
            locations: [branch(0)],
          ),
        );
      },
    );
    await openMap(tester);

    final map = tester.getRect(find.byType(RankingsMapView));
    await tester.tapAt(
      map.center + const Offset(200, 120),
      buttons: kSecondaryButton,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('New entry here'));
    await tester.pumpAndSettle();
    await tester.enterText(
      labeledField('Place name or Google Maps link'),
      'ennio',
    );
    // Before the debounce would have searched.
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    await tester.pump();
    expect(find.text("Ennio's Pasta House"), findsOneWidget);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    final created = (await storedParents(
      harness.db,
    )).singleWhere((parent) => parent.title == "Ennio's Pasta House");
    expect(created.locations.single.latitude, 43.4833807);
    await settleMap(tester);
  });

  mapTest('Enter in the title keeps the field, so Ctrl+Enter adds the entry', (
    tester,
  ) async {
    final harness = await pumpRankingsPage(
      tester,
      seed: (repo) async {
        final category = makeCategory();
        await repo.upsertCategory(category);
        await repo.upsertParent(
          makeParent(
            categoryId: category.id,
            title: 'Lazeez',
            locations: [branch(0)],
          ),
        );
      },
    );
    await openMap(tester);

    final map = tester.getRect(find.byType(RankingsMapView));
    await tester.tapAt(
      map.center + const Offset(200, 120),
      buttons: kSecondaryButton,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('New entry here'));
    await tester.pumpAndSettle();
    await tester.enterText(labeledField('Title'), 'Matter');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    expect(
      (await storedParents(harness.db)).where((p) => p.title == 'Matter'),
      hasLength(1),
    );
    await settleMap(tester);
  });

  mapTest('Ctrl+Enter with places listed adds the first of them', (
    tester,
  ) async {
    final harness = await pumpRankingsPage(
      tester,
      seed: (repo) async {
        final category = makeCategory();
        await repo.upsertCategory(category);
        await repo.upsertParent(
          makeParent(
            categoryId: category.id,
            title: 'Lazeez',
            locations: [branch(0)],
          ),
        );
      },
    );
    await openMap(tester);

    final map = tester.getRect(find.byType(RankingsMapView));
    await tester.tapAt(
      map.center + const Offset(200, 120),
      buttons: kSecondaryButton,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('New entry here'));
    await tester.pumpAndSettle();
    await tester.enterText(
      labeledField('Place name or Google Maps link'),
      'pasta',
    );
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.text('Pasta Bar'), findsOneWidget);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    final created = (await storedParents(
      harness.db,
    )).singleWhere((parent) => parent.title == "Ennio's Pasta House");
    expect(created.locations.single.latitude, 43.4833807);
    expect(created.locations.single.address, '384 King Street North, Waterloo');
    await settleMap(tester);
  });

  mapTest('right-clicking the map adds the point to an existing entry', (
    tester,
  ) async {
    final harness = await pumpRankingsPage(
      tester,
      seed: (repo) async {
        final category = makeCategory();
        await repo.upsertCategory(category);
        await repo.upsertParent(
          makeParent(
            categoryId: category.id,
            title: 'Lazeez',
            locations: [branch(0)],
          ),
        );
        await repo.upsertParent(
          makeParent(categoryId: category.id, title: 'Ennio'),
        );
      },
    );
    await openMap(tester);

    final map = tester.getRect(find.byType(RankingsMapView));
    await tester.tapAt(
      map.center + const Offset(200, 120),
      buttons: kSecondaryButton,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add this location to an existing entry…'));
    await tester.pumpAndSettle();
    // The picker holds the whole scope, the entry with no pin included.
    await tester.enterText(labeledField('Search entries'), 'enn');
    await tester.pumpAndSettle();
    // Lazeez is still on the map behind, as the title under its pin.
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Lazeez'),
      ),
      findsNothing,
    );
    expect(find.text('Lazeez'), findsOneWidget);
    await tester.tap(find.text('Ennio'));
    await tester.pumpAndSettle();

    final ennio = (await storedParents(
      harness.db,
    )).singleWhere((parent) => parent.title == 'Ennio');
    expect(ennio.locations.single.address, '1 Reverse Street');
    // Pinning a place is not starting it.
    expect(ennio.status, RankingStatus.queued);
    expect(pins(tester), hasLength(2));
    await settleMap(tester);
  });

  mapTest('a toast spins while the added point waits on its address', (
    tester,
  ) async {
    final reverse = <Completer<String>>[];
    await pumpRankingsPage(
      tester,
      geoapify: heldGeoapify(reverse),
      seed: (repo) async {
        final category = makeCategory();
        await repo.upsertCategory(category);
        await repo.upsertParent(
          makeParent(
            categoryId: category.id,
            title: 'Lazeez',
            locations: [branch(0)],
          ),
        );
        await repo.upsertParent(
          makeParent(categoryId: category.id, title: 'Ennio'),
        );
      },
    );
    await openMap(tester);

    final map = tester.getRect(find.byType(RankingsMapView));
    await tester.tapAt(
      map.center + const Offset(200, 120),
      buttons: kSecondaryButton,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add this location to an existing entry…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ennio'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(reverse, hasLength(1));
    expect(find.text('Adding location…'), findsOneWidget);
    expect(pins(tester), hasLength(1));

    reverse.single.complete('1 Found Street');
    await tester.pumpAndSettle();
    expect(find.text('Adding location…'), findsNothing);
    expect(pins(tester), hasLength(2));
    await settleMap(tester);
  });

  group('where the map opens', () {
    Future<void> seedOnePin(DriftRankingRepository repo) async {
      final category = makeCategory();
      await repo.upsertCategory(category);
      await repo.upsertParent(
        makeParent(
          categoryId: category.id,
          title: 'Lazeez',
          locations: [branch(0)],
        ),
      );
    }

    mapTest('the first map of a run opens where the device was last found, '
        'then moves to a fresh fix and keeps it for the next run', (
      tester,
    ) async {
      var fresh = Completer<LatLng>();
      fakeDevice(tester, recent: () => null, fresh: () => fresh.future);
      final harness = await pumpRankingsPage(
        tester,
        seed: seedOnePin,
        deviceLocation: (latitude: 41, longitude: -75),
      );
      await openMap(tester);
      // There at once, not fitted to the pin while the fix is awaited.
      expect(mapCamera(tester).center, const LatLng(41, -75));
      expect(mapCamera(tester).zoom, 18.75);

      fresh.complete(const LatLng(40, -74));
      await settleMap(tester);
      expect(mapCamera(tester).center, const LatLng(40, -74));
      expect(
        (await DriftSettingsRepository(
          harness.db,
        ).getSettings()).rankingsDeviceLocation,
        (latitude: 40.0, longitude: -74.0),
      );

      // Dragged away and reopened in the same run: where it was left.
      fresh = Completer<LatLng>();
      await tester.drag(find.byType(FlutterMap), const Offset(-300, 0));
      await settleMap(tester);
      final left = mapCamera(tester).center;
      await tester.tap(find.widgetWithText(InkWell, 'List'));
      await tester.pumpAndSettle();
      await openMap(tester);
      expect(mapCamera(tester).center, left);
    });

    mapTest('a map opened later in the run still shows where the device is, '
        'without moving there, and finds it again once the fix is '
        '10 minutes old', (tester) async {
      LatLng? deviceDot() => tester
          .widgetList<MarkerLayer>(find.byType(MarkerLayer))
          .expand((layer) => layer.markers)
          .where((marker) => marker.width == 16)
          .firstOrNull
          ?.point;
      var fix = const LatLng(40, -74);
      var lookups = 0;
      fakeDevice(
        tester,
        recent: () => null,
        fresh: () async {
          lookups++;
          return fix;
        },
      );
      await pumpRankingsPage(tester, seed: seedOnePin);
      await openMap(tester);
      expect(deviceDot(), const LatLng(40, -74));
      expect(lookups, 1);

      await tester.drag(find.byType(FlutterMap), const Offset(-300, 0));
      await settleMap(tester);
      final left = mapCamera(tester).center;
      Future<void> reopen() async {
        await tester.tap(find.widgetWithText(InkWell, 'List'));
        await tester.pumpAndSettle();
        await openMap(tester);
      }

      // Within 10 minutes: the last fix stands, and no lookup is made.
      fix = const LatLng(40.001, -74.001);
      await reopen();
      expect(deviceDot(), const LatLng(40, -74));
      expect(lookups, 1);
      expect(mapCamera(tester).center, left);

      ProviderScope.containerOf(
        tester.element(find.byType(FlutterMap)),
      ).read(rankingDeviceFoundAtProvider.notifier).state = DateTime.now()
          .subtract(const Duration(minutes: 11));
      await reopen();
      expect(deviceDot(), const LatLng(40.001, -74.001));
      expect(lookups, 2);
      expect(mapCamera(tester).center, left);
    });

    mapTest('Locate shows the fix the system holds at once, then a fresh '
        'one', (tester) async {
      final fresh = Completer<LatLng>();
      LatLng? recent;
      fakeDevice(tester, recent: () => recent, fresh: () => fresh.future);
      await pumpRankingsPage(tester, seed: seedOnePin);
      await openMap(tester);
      // Nothing saved and no fix yet: the pins.
      expect(mapCamera(tester).center.latitude, closeTo(43.46, 1e-6));
      expect(mapCamera(tester).center.longitude, closeTo(-80.52, 1e-6));

      recent = const LatLng(42, -76);
      await tester.tap(find.byTooltip('Show my location'));
      await tester.pumpAndSettle();
      expect(mapCamera(tester).center, const LatLng(42, -76));
      fresh.complete(const LatLng(40.5, -74.5));
      await settleMap(tester);
      expect(mapCamera(tester).center, const LatLng(40.5, -74.5));
    });

    mapTest('Locate flies: a far hop zooms out on the way and lasts longer '
        'than a near one', (tester) async {
      LatLng? recent;
      final fresh = Completer<LatLng>();
      fakeDevice(tester, recent: () => recent, fresh: () => fresh.future);
      await pumpRankingsPage(tester, seed: seedOnePin);
      await openMap(tester);

      // Returns how many 50 ms frames the flight to [to] took, and the
      // lowest zoom it passed through.
      Future<({int frames, double lowest})> fly(LatLng to) async {
        recent = to;
        final start = mapCamera(tester).zoom;
        await tester.tap(find.byTooltip('Show my location'));
        var frames = 0;
        var lowest = start;
        while (mapCamera(tester).center != to && frames < 100) {
          await tester.pump(const Duration(milliseconds: 50));
          lowest = math.min(lowest, mapCamera(tester).zoom);
          frames++;
        }
        expect(mapCamera(tester).zoom, 18.75);
        return (frames: frames, lowest: lowest);
      }

      final far = await fly(const LatLng(42, -76));
      expect(far.frames, greaterThan(1));
      expect(far.lowest, lessThan(16));
      final near = await fly(const LatLng(42.0005, -76.0005));
      expect(near.frames, greaterThan(1));
      expect(near.frames, lessThan(far.frames));
      expect(near.lowest, greaterThan(18));
      fresh.complete(const LatLng(42.0005, -76.0005));
    });

    mapTest('zoom out stops where the world fills the map', (tester) async {
      await pumpRankingsPage(tester, seed: seedOnePin);
      await openMap(tester);
      for (var i = 0; i < 25; i++) {
        await tester.tap(find.byTooltip('Zoom out'));
        await tester.pump();
      }
      await settleMap(tester);
      final camera = mapCamera(tester);
      expect(
        256 * math.pow(2, camera.zoom),
        closeTo(camera.nonRotatedSize.width, 1e-6),
      );
    });

    mapTest('zoom stops where the tiles do', (tester) async {
      await pumpRankingsPage(tester, seed: seedOnePin);
      await openMap(tester);
      for (var i = 0; i < 6; i++) {
        await tester.tap(find.byTooltip('Zoom in'));
        await tester.pump();
      }
      await settleMap(tester);
      expect(mapCamera(tester).zoom, rankingsMapMaxZoom);
    });
  });

  group('the Locations section', () {
    Future<({AppDatabase db, ProviderContainer container})> openEntry(
      WidgetTester tester, {
      GeoapifyClient? geoapify,
      bool withKey = true,
      List<RankingLocation> locations = const [],
    }) async {
      final harness = await pumpRankingsPage(
        tester,
        geoapify: geoapify,
        withKey: withKey,
        seed: (repo) async {
          final category = makeCategory();
          await repo.upsertCategory(category);
          await repo.upsertParent(
            makeParent(
              categoryId: category.id,
              title: 'Ennio',
              locations: locations,
            ),
          );
        },
      );
      await tester.tap(find.byType(RankingsRow));
      await tester.pumpAndSettle();
      return harness;
    }

    Finder dialogInput() => find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );

    MapCamera previewCamera(WidgetTester tester) => MapCamera.of(
      tester.element(
        find.descendant(
          of: find.byType(RankingLocationPreview),
          matching: find.byType(RankingsTileLayer),
        ),
      ),
    );

    mapTest('previews a chain at the branch nearest the device', (
      tester,
    ) async {
      fakeDevice(
        tester,
        recent: () => null,
        fresh: () async => const LatLng(43.501, -80.481),
      );
      await openEntry(tester, locations: [branch(0), branch(1), branch(2)]);
      expect(find.byType(RankingLocationPreview), findsOneWidget);
      expect(
        previewCamera(tester).center,
        LatLng(branch(2).latitude, branch(2).longitude),
      );
      expect(find.text('Nearest of 3'), findsOneWidget);
      final selected = tester
          .widgetList<RankingsMapPin>(
            find.descendant(
              of: find.byType(RankingLocationPreview),
              matching: find.byType(RankingsMapPin),
            ),
          )
          .where((pin) => pin.selected);
      expect(selected, hasLength(1));
    });

    mapTest('with no device location, previews the first location', (
      tester,
    ) async {
      await openEntry(tester, locations: [branch(0), branch(1)]);
      expect(
        previewCamera(tester).center,
        LatLng(branch(0).latitude, branch(0).longitude),
      );
      expect(find.textContaining('Nearest of'), findsNothing);
    });

    mapTest('a press on the preview opens the map there, panel still open', (
      tester,
    ) async {
      fakeDevice(
        tester,
        recent: () => null,
        fresh: () async => const LatLng(43.501, -80.481),
      );
      await openEntry(tester, locations: [branch(0), branch(1), branch(2)]);
      await tester.tap(find.byType(RankingLocationPreview));
      await tester.pumpAndSettle();
      expect(find.byType(RankingsMapView), findsOneWidget);
      expect(find.byType(RankingsEditPanel), findsOneWidget);
      final camera = mapCamera(tester);
      expect(camera.center, LatLng(branch(2).latitude, branch(2).longitude));
      expect(camera.zoom, RankingLocationPreview.zoom);
    });

    LatLng at(RankingLocation location) =>
        LatLng(location.latitude, location.longitude);

    mapTest('beside the open map, a press on the preview pans the map there', (
      tester,
    ) async {
      await openEntry(tester, locations: [branch(0), branch(1)]);
      await openMap(tester);
      expect(find.byType(RankingsEditPanel), findsOneWidget);
      expect(find.byType(RankingLocationPreview), findsOneWidget);
      await tester.drag(find.byType(RankingsMapView), const Offset(-300, 0));
      await settleMap(tester);
      expect(mapCamera(tester).center, isNot(at(branch(0))));
      await tester.tap(find.byType(RankingLocationPreview));
      await tester.pumpAndSettle();
      expect(mapCamera(tester).center, at(branch(0)));
      // Still in map view, and the request is spent.
      expect(find.byType(RankingsMapView), findsOneWidget);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(RankingsMapView)),
      );
      expect(container.read(rankingMapFocusProvider), isNull);
    });

    mapTest('follows the entry live: a closer branch added, the shown one '
        'moved away, then removed, then every location gone', (tester) async {
      // Nearest to branch(1) of 0, 1 and 4.
      fakeDevice(
        tester,
        recent: () => null,
        fresh: () async => const LatLng(43.481, -80.499),
      );
      final harness = await openEntry(
        tester,
        locations: [branch(0), branch(4)],
      );
      final parentId = (await storedParents(harness.db)).single.id;
      final actions = RankingsActions.detached(harness.container);
      Future<void> settle() async {
        await tester.pumpAndSettle();
        await tester.pump();
      }

      expect(previewCamera(tester).center, at(branch(0)));
      expect(find.text('Nearest of 2'), findsOneWidget);

      // A closer branch, added: the preview goes to it, and counts it.
      await actions.addLocation(
        parentId,
        latitude: branch(1).latitude,
        longitude: branch(1).longitude,
        address: 'added',
      );
      await settle();
      expect(previewCamera(tester).center, at(branch(1)));
      expect(find.text('Nearest of 3'), findsOneWidget);

      // The shown branch moved far off: the next nearest takes over.
      final added = (await storedParents(
        harness.db,
      )).single.locations.singleWhere((l) => l.address == 'added');
      await actions.updateLocation(
        parentId,
        added.copyWith(latitude: 44.5, longitude: -79.5),
      );
      await settle();
      expect(previewCamera(tester).center, at(branch(0)));

      // A far branch moved right next to the device: it takes over.
      await actions.updateLocation(
        parentId,
        branch(4).copyWith(latitude: 43.4811, longitude: -80.4991),
      );
      await settle();
      expect(previewCamera(tester).center, const LatLng(43.4811, -80.4991));

      // Removed: back to the next nearest.
      await actions.removeLocation(parentId, branch(4).id);
      await settle();
      expect(previewCamera(tester).center, at(branch(0)));
      expect(find.text('Nearest of 2'), findsOneWidget);

      // Down to one: no count to show.
      await actions.removeLocation(parentId, added.id);
      await settle();
      expect(previewCamera(tester).center, at(branch(0)));
      expect(find.textContaining('Nearest of'), findsNothing);

      // None left: no preview, and nothing thrown.
      await actions.removeLocation(parentId, branch(0).id);
      await settle();
      expect(find.byType(RankingLocationPreview), findsNothing);

      // The first location back: the preview with it.
      await actions.addLocation(
        parentId,
        latitude: branch(2).latitude,
        longitude: branch(2).longitude,
        address: 'again',
      );
      await settle();
      expect(previewCamera(tester).center, at(branch(2)));
    });

    mapTest('without the device, follows the first location in the entry '
        'order', (tester) async {
      final harness = await openEntry(
        tester,
        locations: [branch(0), branch(1)],
      );
      final parentId = (await storedParents(harness.db)).single.id;
      await RankingsActions.detached(
        harness.container,
      ).reorderLocations(parentId, [branch(1).id, branch(0).id]);
      await tester.pumpAndSettle();
      await tester.pump();
      expect(previewCamera(tester).center, at(branch(1)));
    });

    mapTest('the device found by Locate on the map recentres the preview', (
      tester,
    ) async {
      LatLng? recent;
      final fresh = Completer<LatLng>();
      fakeDevice(tester, recent: () => recent, fresh: () => fresh.future);
      await openEntry(tester, locations: [branch(0), branch(3)]);
      await openMap(tester);
      // No fix yet: the first location.
      expect(previewCamera(tester).center, at(branch(0)));
      recent = const LatLng(43.521, -80.459); // by branch(3)
      await tester.tap(find.byTooltip('Show my location'));
      await tester.pumpAndSettle();
      await tester.pump();
      expect(previewCamera(tester).center, at(branch(3)));
      expect(find.text('Nearest of 2'), findsOneWidget);
      fresh.complete(const LatLng(43.521, -80.459));
    });

    mapTest('adds a place found by name', (tester) async {
      final requests = <Uri>[];
      final harness = await openEntry(
        tester,
        geoapify: fakeGeoapify(requests: requests),
      );
      await tester.tap(find.text('Add location'));
      await tester.pumpAndSettle();
      // Nothing to add until a place is found.
      await tester.enterText(dialogInput(), 'en');
      await tester.pump(const Duration(milliseconds: 400));
      // Under three characters spends no credit.
      expect(requests, isEmpty);

      await tester.enterText(dialogInput(), 'pasta');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      // Amenities and the untyped fallback, asked at once.
      expect(requests, hasLength(2));
      // A mouse click, which takes the focus off the field as on desktop.
      await tester.tap(
        find.text("Ennio's Pasta House"),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      // Clicking a suggestion leaves the keyboard where Ctrl+Enter adds it.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();

      final parent = (await storedParents(harness.db)).single;
      final location = parent.locations.single;
      expect(location.latitude, 43.4833807);
      expect(location.longitude, -80.5260427);
      expect(location.address, '384 King Street North, Waterloo');
      // A location-only edit leaves a queued entry queued.
      expect(parent.status, RankingStatus.queued);
      expect(
        find.descendant(
          of: find.byType(RankingLocationsSection),
          matching: find.text('384 King Street North, Waterloo'),
        ),
        findsOneWidget,
      );
    });

    mapTest('a name nothing matches offers the other two ways in', (
      tester,
    ) async {
      final requests = <Uri>[];
      await openEntry(
        tester,
        geoapify: fakeGeoapify(requests: requests),
        locations: [branch(0)],
      );
      await tester.tap(find.text('Add location'));
      await tester.pumpAndSettle();
      await tester.enterText(dialogInput(), 'nowhere at all');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      expect(find.textContaining('No places found'), findsOneWidget);
      // Searched around the entry's own location, within the radius.
      expect(requests.first.queryParameters['filter'], startsWith('circle:'));
      await tester.tap(find.text('Search everywhere'));
      await tester.pumpAndSettle();
      expect(requests.last.queryParameters.containsKey('filter'), isFalse);
      expect(find.text('Search everywhere'), findsNothing);
    });

    mapTest('adds a place from a pasted full link', (tester) async {
      final harness = await openEntry(tester);
      await tester.tap(find.text('Add location'));
      await tester.pumpAndSettle();
      await tester.enterText(
        dialogInput(),
        'https://www.google.com/maps/place/Lazeez/@43.4,-80.5,17z/'
        'data=!3d43.4723!4d-80.5449',
      );
      // A link waits out the same debounce a search does.
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      // One reverse geocode fills the address.
      expect(find.text('1 Reverse Street'), findsOneWidget);
      await tester.tap(dialogAdd());
      await tester.pumpAndSettle();

      final location = (await storedParents(
        harness.db,
      )).single.locations.single;
      expect(location.latitude, 43.4723);
      expect(location.longitude, -80.5449);
      expect(location.address, '1 Reverse Street');
    });

    mapTest('adds a place from a short link, by following it', (tester) async {
      final harness = await openEntry(tester);
      await tester.tap(find.text('Add location'));
      await tester.pumpAndSettle();
      await tester.enterText(dialogInput(), 'https://maps.app.goo.gl/AbCd123');
      // A link waits out the same debounce a search does.
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      await tester.tap(dialogAdd());
      await tester.pumpAndSettle();

      final location = (await storedParents(
        harness.db,
      )).single.locations.single;
      expect(location.latitude, 43.5);
      expect(location.longitude, -80.5);
    });

    mapTest('a spinner shows in the field while a short link is followed', (
      tester,
    ) async {
      final followed = Completer<Uri?>();
      await pumpRankingsPage(
        tester,
        shortLinks: (_) => followed.future,
        seed: (repo) async {
          final category = makeCategory();
          await repo.upsertCategory(category);
          await repo.upsertParent(
            makeParent(categoryId: category.id, title: 'Ennio'),
          );
        },
      );
      await tester.tap(find.byType(RankingsRow));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add location'));
      await tester.pumpAndSettle();
      final spinner = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(CircularProgressIndicator),
      );

      await tester.enterText(dialogInput(), 'https://maps.app.goo.gl/AbCd123');
      await tester.pump(const Duration(milliseconds: 400));
      expect(spinner, findsOneWidget);

      followed.complete(
        Uri.parse(
          'https://www.google.com/maps/place/Short+Link+Cafe/'
          'data=!3d43.5!4d-80.5',
        ),
      );
      await tester.pumpAndSettle();
      expect(spinner, findsNothing);
      expect(find.text('1 Reverse Street'), findsOneWidget);
    });

    mapTest('saved entries that match are listed before Geoapify answers', (
      tester,
    ) async {
      final held = Completer<void>();
      final harness = await pumpRankingsPage(
        tester,
        geoapify: heldSearchGeoapify(held),
        seed: (repo) async {
          final category = makeCategory();
          await repo.upsertCategory(category);
          await repo.upsertParent(
            makeParent(categoryId: category.id, title: 'Ennio'),
          );
          await repo.upsertParent(
            makeParent(
              categoryId: category.id,
              title: 'Pasta Palace',
              locations: [branch(3)],
            ),
          );
        },
      );
      await tester.tap(find.widgetWithText(RankingsRow, 'Ennio'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add location'));
      await tester.pumpAndSettle();
      final dialog = find.byType(AlertDialog);
      Finder inDialog(Finder finder) =>
          find.descendant(of: dialog, matching: finder);

      await tester.enterText(dialogInput(), 'pasta');
      await tester.pump();
      // Not even waiting out the debounce, let alone Geoapify.
      expect(inDialog(find.text('Pasta Palace')), findsOneWidget);
      expect(inDialog(find.byTooltip('Saved entry')), findsOneWidget);
      expect(inDialog(find.text('Pasta Bar')), findsNothing);

      held.complete();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      // Geoapify's finds follow, under it.
      expect(
        tester.getTopLeft(inDialog(find.text('Pasta Palace'))).dy,
        lessThan(tester.getTopLeft(inDialog(find.text('Pasta Bar'))).dy),
      );
      await tester.tap(
        inDialog(find.text('Pasta Palace')),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      await tester.tap(dialogAdd());
      await tester.pumpAndSettle();

      final location = (await storedParents(
        harness.db,
      )).singleWhere((parent) => parent.title == 'Ennio').locations.single;
      expect(location.latitude, branch(3).latitude);
      expect(location.longitude, branch(3).longitude);
      expect(location.address, branch(3).address);
    });

    mapTest('an entry is not offered its own locations', (tester) async {
      await pumpRankingsPage(
        tester,
        seed: (repo) async {
          final category = makeCategory();
          await repo.upsertCategory(category);
          await repo.upsertParent(
            makeParent(
              categoryId: category.id,
              title: 'Pasta Palace',
              locations: [branch(3)],
            ),
          );
        },
      );
      await tester.tap(find.byType(RankingsRow));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add location'));
      await tester.pumpAndSettle();
      await tester.enterText(dialogInput(), 'pasta');
      await tester.pump();
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byTooltip('Saved entry'),
        ),
        findsNothing,
      );
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
    });

    mapTest('a link with no location in it adds nothing', (tester) async {
      final harness = await openEntry(tester);
      await tester.tap(find.text('Add location'));
      await tester.pumpAndSettle();
      await tester.enterText(
        dialogInput(),
        'https://www.google.com/maps/place/Lazeez/',
      );
      // A link waits out the same debounce a search does.
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(
        find.text("Couldn't find a location in that link"),
        findsOneWidget,
      );
      await tester.tap(dialogAdd());
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect((await storedParents(harness.db)).single.locations, isEmpty);
    });

    mapTest('adds a place by dropping a pin on the dialog map', (tester) async {
      final harness = await openEntry(tester);
      await tester.tap(find.text('Add location'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(FlutterMap),
        ),
      );
      // The map holds a tap back until it knows it is not a double-tap.
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      expect(find.text('1 Reverse Street'), findsOneWidget);
      await tester.tap(dialogAdd());
      await tester.pumpAndSettle();
      expect(
        (await storedParents(harness.db)).single.locations.single.address,
        '1 Reverse Street',
      );
    });

    mapTest('the dialog map zooms out only until the world fills it', (
      tester,
    ) async {
      await openEntry(tester);
      await tester.tap(find.text('Add location'));
      await tester.pumpAndSettle();
      final map = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(FlutterMap),
      );
      final pointer = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(pointer.hover(tester.getCenter(map)));
      for (var i = 0; i < 10; i++) {
        await tester.sendEventToBinding(pointer.scroll(const Offset(0, 500)));
        await tester.pump();
      }
      await tester.pumpAndSettle();
      final camera = MapCamera.of(
        tester.element(
          find.descendant(of: map, matching: find.byType(RankingsTileLayer)),
        ),
      );
      expect(
        256 * math.pow(2, camera.zoom),
        closeTo(camera.nonRotatedSize.width, 1e-6),
      );
    });

    mapTest('refuses a second location on top of one it has', (tester) async {
      final harness = await openEntry(tester, locations: [branch(0)]);
      await tester.tap(find.text('Add location'));
      await tester.pumpAndSettle();
      // Ten metres or so from the branch it already has.
      await tester.enterText(
        dialogInput(),
        'https://maps.google.com/?q=43.46005,-80.52005',
      );
      // A link waits out the same debounce a search does.
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      await tester.tap(dialogAdd());
      await tester.pumpAndSettle();

      expect(
        find.text('This entry already has a location here'),
        findsOneWidget,
      );
      expect((await storedParents(harness.db)).single.locations, hasLength(1));
    });

    mapTest('without a key, stored locations still list and a full link '
        'still adds', (tester) async {
      final harness = await openEntry(
        tester,
        withKey: false,
        locations: [branch(0, label: 'Airport')],
      );
      expect(find.text('Airport'), findsOneWidget);
      expect(find.text('0 King Street North'), findsOneWidget);

      await tester.tap(find.text('Add location'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Map unavailable'), findsOneWidget);
      await tester.enterText(
        dialogInput(),
        'https://maps.google.com/?q=43.5,-80.6',
      );
      // A link waits out the same debounce a search does.
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      await tester.tap(dialogAdd());
      await tester.pumpAndSettle();
      expect((await storedParents(harness.db)).single.locations, hasLength(2));
    });

    mapTest('a late address for an earlier pin does not replace the chosen '
        "place's", (tester) async {
      final reverse = <Completer<String>>[];
      final harness = await openEntry(tester, geoapify: heldGeoapify(reverse));
      await tester.tap(find.text('Add location'));
      await tester.pumpAndSettle();
      // Drop a pin; its address lookup is still out...
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(FlutterMap),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      expect(reverse, hasLength(1));
      // ...when a searched place, the only match, is picked instead.
      await tester.enterText(dialogInput(), 'ennio');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      reverse.single.complete('Somewhere Else Entirely');
      await tester.pumpAndSettle();

      expect(find.text('Somewhere Else Entirely'), findsNothing);
      await tester.tap(dialogAdd());
      await tester.pumpAndSettle();
      expect(
        (await storedParents(harness.db)).single.locations.single.address,
        '384 King Street North, Waterloo',
      );
    });

    mapTest('a spinner shows by the pin while its address is looked up', (
      tester,
    ) async {
      final reverse = <Completer<String>>[];
      await openEntry(tester, geoapify: heldGeoapify(reverse));
      await tester.tap(find.text('Add location'));
      await tester.pumpAndSettle();
      final spinner = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(CircularProgressIndicator),
      );
      expect(spinner, findsNothing);

      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(FlutterMap),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      expect(reverse, hasLength(1));
      expect(spinner, findsOneWidget);

      reverse.single.complete('1 Found Street');
      await tester.pumpAndSettle();
      expect(spinner, findsNothing);
      expect(find.text('1 Found Street'), findsOneWidget);
    });

    mapTest('a failed address lookup takes its spinner down', (tester) async {
      final reverse = <Completer<String>>[];
      await openEntry(tester, geoapify: heldGeoapify(reverse));
      await tester.tap(find.text('Add location'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(FlutterMap),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      reverse.single.completeError(Exception('offline'));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(CircularProgressIndicator),
        ),
        findsNothing,
      );
    });

    mapTest('a dragged pin does not keep the address it was dragged from', (
      tester,
    ) async {
      final reverse = <Completer<String>>[];
      final harness = await openEntry(
        tester,
        geoapify: heldGeoapify(reverse),
        locations: [branch(0)],
      );
      await tester.tap(find.byTooltip('Location options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Edit location…'));
      await tester.pumpAndSettle();
      final dialog = find.byType(AlertDialog);
      expect(
        find.descendant(of: dialog, matching: find.text('0 King Street North')),
        findsOneWidget,
      );

      await tester.drag(
        find.descendant(of: dialog, matching: find.byType(RankingsMapPin)),
        const Offset(80, 40),
      );
      await tester.pumpAndSettle();
      // The lookup for where it landed fails, as it would offline.
      reverse.single.completeError(Exception('offline'));
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: dialog, matching: find.text('0 King Street North')),
        findsNothing,
      );
      await tester.tap(
        find.descendant(of: dialog, matching: find.text('Save')),
      );
      await tester.pumpAndSettle();

      final location = (await storedParents(
        harness.db,
      )).single.locations.single;
      expect(location.latitude, isNot(branch(0).latitude));
      // Moved, with no address rather than the old one.
      expect(location.address, '');
    });

    mapTest('a row clicked with no map open leaves no pan request behind', (
      tester,
    ) async {
      final harness = await openEntry(tester, locations: [branch(0)]);
      await tester.tap(find.text('0 King Street North'));
      await tester.pumpAndSettle();
      expect(harness.container.read(rankingMapFocusProvider), isNull);
    });

    mapTest('renames a location from its menu', (tester) async {
      final harness = await openEntry(tester, locations: [branch(0)]);
      await tester.tap(find.byTooltip('Location options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Rename'));
      await tester.pumpAndSettle();
      await tester.enterText(dialogInput(), 'Queen St');
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();

      expect(
        (await storedParents(harness.db)).single.locations.single.label,
        'Queen St',
      );
      // The label leads, and the address drops to the second line.
      final section = find.byType(RankingLocationsSection);
      expect(
        find.descendant(of: section, matching: find.text('Queen St')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: section,
          matching: find.text('0 King Street North'),
        ),
        findsOneWidget,
      );
    });
  });

  mapTest('the map says so when there is no Geoapify key', (tester) async {
    await pumpRankingsPage(
      tester,
      withKey: false,
      seed: (repo) async {
        final category = makeCategory();
        await repo.upsertCategory(category);
        await repo.upsertParent(
          makeParent(
            categoryId: category.id,
            title: 'Lazeez',
            locations: [branch(0)],
          ),
        );
      },
    );
    await tester.tap(find.widgetWithText(InkWell, 'Map'));
    await tester.pumpAndSettle();
    expect(find.text('Map unavailable — no Geoapify key'), findsOneWidget);
    expect(find.byType(FlutterMap), findsNothing);
  });

  mapTest('with no key, clicking a location row neither throws nor leaves a '
      'pan request', (tester) async {
    final harness = await pumpRankingsPage(
      tester,
      withKey: false,
      seed: (repo) async {
        final category = makeCategory();
        await repo.upsertCategory(category);
        await repo.upsertParent(
          makeParent(
            categoryId: category.id,
            title: 'Lazeez',
            locations: [branch(0)],
          ),
        );
      },
    );
    // Open the entry from the list, then switch to the unavailable map.
    await tester.tap(find.byType(RankingsRow));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(InkWell, 'Map'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(RankingLocationsSection),
        matching: find.text('0 King Street North'),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(harness.container.read(rankingMapFocusProvider), isNull);
  });

  mapTest('pins still cluster at the world view after the map narrows', (
    tester,
  ) async {
    // 2560 wide, the floor is log2(10): the cluster layer starts at 4.
    tester.view.physicalSize = const Size(2560, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final cache = Directory.systemTemp.createTempSync('voyager_map_tiles');
    addTearDown(() => cache.deleteSync(recursive: true));
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => cache.path,
    );
    final db = AppDatabase.inMemory();
    addTearDown(db.close);
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        syncRepositoryProvider.overrideWithValue(InMemorySyncRepository()),
        weatherApiClientProvider.overrideWithValue(FakeWeatherApiClient()),
        geoapifyClientProvider.overrideWithValue(fakeGeoapify()),
        rankingMapTileProviderProvider.overrideWithValue(_BlankTiles()),
      ],
    );
    addTearDown(container.dispose);
    await container.read(settingsProvider.future);
    final category = makeCategory();
    final entry = makeParent(
      categoryId: category.id,
      title: 'Lazeez',
      locations: [branch(0), branch(1), branch(2)],
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: RankingsMapView(
              entries: [(parent: entry, category: category)],
              scope: const [],
              createIn: const [],
              selectedParentId: null,
              onOpen: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // 1000 wide, the floor drops to about 1.97; then out to 2.
    tester.view.physicalSize = const Size(1000, 800);
    await tester.pumpAndSettle();
    tester
        .widget<FlutterMap>(find.byType(FlutterMap))
        .mapController!
        .move(const LatLng(43.48, -80.5), 2);
    await tester.pumpAndSettle();

    expect(find.byType(RankingsMapPin), findsNothing);
    expect(find.text('3'), findsOneWidget);
  });

  mapTest('pins spread out of a cluster that zoom cannot part show their '
      'titles', (tester) async {
    await pumpRankingsPage(
      tester,
      seed: (repo) async {
        final category = makeCategory();
        await repo.upsertCategory(category);
        // Two entries at the very same spot: no zoom ever parts them.
        await repo.upsertParent(
          makeParent(
            categoryId: category.id,
            title: 'Lazeez',
            locations: [branch(0)],
          ),
        );
        await repo.upsertParent(
          makeParent(
            categoryId: category.id,
            title: 'Ennio',
            locations: [branch(0)],
          ),
        );
      },
    );
    await openMap(tester);
    expect(pins(tester), isEmpty);

    await tester.tap(
      find.descendant(
        of: find.byType(RankingsMapView),
        matching: find.text('2'),
      ),
    );
    await tester.pumpAndSettle();

    expect(pins(tester), hasLength(2));
    expect(find.text('Lazeez'), findsOneWidget);
    expect(find.text('Ennio'), findsOneWidget);
  });

  mapTest('a map opened before its entries arrive fits them once they do', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final cache = Directory.systemTemp.createTempSync('voyager_map_tiles');
    addTearDown(() => cache.deleteSync(recursive: true));
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => cache.path,
    );
    final db = AppDatabase.inMemory();
    addTearDown(db.close);
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        syncRepositoryProvider.overrideWithValue(InMemorySyncRepository()),
        weatherApiClientProvider.overrideWithValue(FakeWeatherApiClient()),
        geoapifyClientProvider.overrideWithValue(fakeGeoapify()),
        rankingMapTileProviderProvider.overrideWithValue(_BlankTiles()),
      ],
    );
    addTearDown(container.dispose);
    await container.read(settingsProvider.future);
    final category = makeCategory();
    final entry = makeParent(
      categoryId: category.id,
      title: 'Lazeez',
      locations: [branch(0)],
    );

    Widget map({required bool loading}) => UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: RankingsMapView(
            entries: loading ? const [] : [(parent: entry, category: category)],
            scope: const [],
            createIn: const [],
            selectedParentId: null,
            onOpen: (_) {},
            loading: loading,
          ),
        ),
      ),
    );
    LatLng center() => tester
        .widget<FlutterMap>(find.byType(FlutterMap))
        .mapController!
        .camera
        .center;

    await tester.pumpWidget(map(loading: true));
    await tester.pumpAndSettle();
    // Nothing to fit and nowhere remembered: the world view.
    expect(center().latitude, closeTo(20, 0.01));

    await tester.pumpWidget(map(loading: false));
    await tester.pumpAndSettle();
    expect(center().latitude, closeTo(branch(0).latitude, 0.001));
    expect(center().longitude, closeTo(branch(0).longitude, 0.001));
  });

  mapTest('a map opened with only some categories loaded fits once, when all '
      'are', (tester) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final cache = Directory.systemTemp.createTempSync('voyager_map_tiles');
    addTearDown(() => cache.deleteSync(recursive: true));
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => cache.path,
    );
    final db = AppDatabase.inMemory();
    addTearDown(db.close);
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        syncRepositoryProvider.overrideWithValue(InMemorySyncRepository()),
        weatherApiClientProvider.overrideWithValue(FakeWeatherApiClient()),
        geoapifyClientProvider.overrideWithValue(fakeGeoapify()),
        rankingMapTileProviderProvider.overrideWithValue(_BlankTiles()),
      ],
    );
    addTearDown(container.dispose);
    await container.read(settingsProvider.future);
    final category = makeCategory();
    final loaded = (
      parent: makeParent(
        categoryId: category.id,
        title: 'Lazeez',
        locations: [branch(0)],
      ),
      category: category,
    );
    final pending = (
      parent: makeParent(
        categoryId: category.id,
        title: 'Mozy',
        locations: [branch(5)],
      ),
      category: category,
    );

    Widget map({required bool loading}) => UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: RankingsMapView(
            entries: loading ? [loaded] : [loaded, pending],
            scope: const [],
            createIn: const [],
            selectedParentId: null,
            onOpen: (_) {},
            loading: loading,
          ),
        ),
      ),
    );
    MapCamera camera() => tester
        .widget<FlutterMap>(find.byType(FlutterMap))
        .mapController!
        .camera;

    await tester.pumpWidget(map(loading: true));
    await tester.pumpAndSettle();
    // Not fitted to the one category in yet: close in on its lone pin, only
    // to pull out again when the rest arrive.
    expect(camera().center.latitude, closeTo(20, 0.01));
    expect(camera().zoom, 2);

    await tester.pumpWidget(map(loading: false));
    await tester.pumpAndSettle();
    final middle = (branch(0).latitude + branch(5).latitude) / 2;
    expect(camera().center.latitude, closeTo(middle, 0.01));
    expect(camera().zoom, lessThan(16));
  });

  group('All categories', () {
    Future<({AppDatabase db, ProviderContainer container})> pumpTwo(
      WidgetTester tester,
    ) => pumpRankingsPage(
      tester,
      seed: (repo) async {
        final restaurants = makeCategory();
        final cafes = makeCategory(
          name: 'Cafes',
          parentScoreMax: 10,
          colorValue: 0xFFFF8A65,
        );
        final shows = makeCategory(name: 'Shows', locationEnabled: false);
        await repo.upsertCategory(restaurants.copyWith(sortOrder: 0));
        await repo.upsertCategory(cafes.copyWith(sortOrder: 1));
        await repo.upsertCategory(shows.copyWith(sortOrder: 2));
        await repo.upsertParent(
          makeParent(
            categoryId: restaurants.id,
            title: 'Lazeez',
            score: 4.5,
            locations: [branch(0)],
            tags: ['shawarma'],
          ),
        );
        await repo.upsertParent(
          makeParent(
            categoryId: cafes.id,
            title: 'Smile Tiger',
            score: 8.4,
            locations: [branch(2)],
            tags: ['espresso'],
          ),
        );
        await repo.upsertParent(
          makeParent(categoryId: shows.id, title: 'Severance', score: 5),
        );
      },
    );

    Future<void> openAll(WidgetTester tester) async {
      await tester.tap(
        find.descendant(
          of: find.byType(RankingsStatsBand),
          matching: find.text('Restaurants'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('All categories'));
      await tester.pumpAndSettle();
      await settleMap(tester);
    }

    mapTest('overlays every mapped category, each on its own scale', (
      tester,
    ) async {
      final harness = await pumpTwo(tester);
      await openAll(tester);

      // Map-only: no List toggle, no sort.
      expect(find.text('List'), findsNothing);
      expect(find.text('Score'), findsNothing);
      expect([for (final pin in pins(tester)) pin.score], ['4.5', '8.4']);
      expect(pins(tester).first.color, isNot(pins(tester).last.color));
      // A count of what is visible, and no average across mixed scales.
      final band = find.byType(RankingsStatsBand);
      expect(find.descendant(of: band, matching: find.text('2')), findsOne);
      expect(
        find.descendant(of: band, matching: find.text('entries')),
        findsOne,
      );
      expect(
        find.descendant(of: band, matching: find.text('avg')),
        findsNothing,
      );
      // The category with locations off is not offered a chip.
      expect(find.widgetWithText(InkWell, 'Shows'), findsNothing);

      // It is where the page reopens.
      final settings = await DriftSettingsRepository(harness.db).getSettings();
      expect(settings.lastViewedRankingCategoryId, rankingAllCategoriesId);
    });

    mapTest('a category chip takes its pins off, on this device', (
      tester,
    ) async {
      final harness = await pumpTwo(tester);
      await openAll(tester);

      await tester.tap(find.widgetWithText(InkWell, 'Cafes'));
      await tester.pumpAndSettle();
      expect([for (final pin in pins(tester)) pin.score], ['4.5']);

      final cafes = (await DriftRankingRepository(
        harness.db,
      ).listCategories()).singleWhere((c) => c.name == 'Cafes');
      final settings = await DriftSettingsRepository(harness.db).getSettings();
      expect(settings.rankingsMapHiddenCategories, [cafes.id]);
      await settleMap(tester);
    });

    mapTest('the filter has the tags of every visible category and no '
        'score range', (tester) async {
      await pumpTwo(tester);
      await openAll(tester);

      await tester.tap(find.text('Filter'));
      await tester.pumpAndSettle();
      expect(find.byType(RangeSlider), findsNothing);
      expect(find.text('shawarma'), findsOneWidget);
      await tester.tap(find.text('espresso'));
      await tester.pumpAndSettle();
      expect([for (final pin in pins(tester)) pin.score], ['8.4']);
      await settleMap(tester);
    });

    mapTest('a pin opens the panel on its own category', (tester) async {
      await pumpTwo(tester);
      await openAll(tester);

      await tester.tap(find.byType(RankingsMapPin).last);
      await tester.pumpAndSettle();
      final panel = tester.widget<RankingsEditPanel>(
        find.byType(RankingsEditPanel),
      );
      expect(panel.parent.title, 'Smile Tiger');
      expect(panel.category.name, 'Cafes');
      expect(panel.category.parentScoreMax, 10);
      await settleMap(tester);
    });

    mapTest('a new entry asks which category it goes in', (tester) async {
      final harness = await pumpTwo(tester);
      await openAll(tester);

      final map = tester.getRect(find.byType(RankingsMapView));
      await tester.tapAt(
        map.center + const Offset(250, 150),
        buttons: kSecondaryButton,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('New entry here'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(SimpleDialog),
          matching: find.text('Cafes'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(labeledField('Title'), 'Matter');
      await tester.tap(dialogAdd());
      await tester.pumpAndSettle();

      final created = (await storedParents(
        harness.db,
      )).singleWhere((parent) => parent.title == 'Matter');
      final cafes = (await DriftRankingRepository(
        harness.db,
      ).listCategories()).singleWhere((c) => c.name == 'Cafes');
      expect(created.categoryId, cafes.id);
      expect(created.locations, hasLength(1));
      await settleMap(tester);
    });

    mapTest('where two titles meet, the better share of its scale keeps it', (
      tester,
    ) async {
      await pumpRankingsPage(
        tester,
        seed: (repo) async {
          final restaurants = makeCategory();
          final cafes = makeCategory(
            name: 'Cafes',
            parentScoreMax: 10,
            colorValue: 0xFFFF8A65,
          );
          await repo.upsertCategory(restaurants.copyWith(sortOrder: 0));
          await repo.upsertCategory(cafes.copyWith(sortOrder: 1));
          // Side by side, a few pixels apart at the name zoom: their titles
          // run over each other there.
          await repo.upsertParent(
            makeParent(
              categoryId: restaurants.id,
              title: 'Lazeez',
              score: 4.9,
              locations: [branch(0)],
            ),
          );
          final next = branch(1);
          await repo.upsertParent(
            makeParent(
              categoryId: cafes.id,
              title: 'Smile Tiger',
              score: 6,
              locations: [
                RankingLocation(
                  id: next.id,
                  latitude: branch(0).latitude,
                  longitude: branch(0).longitude + 0.0003,
                  address: next.address,
                  sortOrder: next.sortOrder,
                ),
              ],
            ),
          );
        },
      );
      await openAll(tester);

      final layer =
          find
                  .byType(RankingsTileLayer)
                  .evaluate()
                  .firstWhere((element) => !_inPreview(element))
                  .widget
              as RankingsTileLayer;
      double titleFrom(String title) =>
          layer.pins.singleWhere((pin) => pin.title == title).titleFrom;
      // 4.9 of 5 beats 6 of 10, though 6 is the larger number: its title
      // shows first.
      expect(titleFrom('Lazeez'), lessThan(titleFrom('Smile Tiger')));
    });
  });

  mapTest('the area to download follows the dialog as the window resizes', (
    tester,
  ) async {
    final harness = await pumpRankingsPage(
      tester,
      seed: (repo) async {
        final category = makeCategory();
        await repo.upsertCategory(category);
        await repo.upsertParent(
          makeParent(categoryId: category.id, title: 'Lazeez'),
        );
      },
    );
    // Opens where the Rankings map was left, so it looks for no device.
    harness.container.read(rankingMapViewportProvider.notifier).state = (
      latitude: 43.47,
      longitude: -80.5,
      zoom: 12,
    );
    unawaited(
      showRankingOfflineDownloadDialog(
        tester.element(find.byType(RankingsPage)),
      ),
    );
    await tester.pumpAndSettle();

    final dialog = find.byType(AlertDialog);
    String shownCount() => tester
        .widgetList<Text>(
          find.descendant(of: dialog, matching: find.byType(Text)),
        )
        .map((text) => text.data ?? '')
        .singleWhere((data) => data.endsWith(' tiles'));
    String countOnScreen() {
      final camera = MapCamera.of(
        find
            .descendant(of: dialog, matching: find.byType(RankingsTileLayer))
            .evaluate()
            .single,
      );
      final network = harness.container.read(rankingMapNetworkTilesProvider)!;
      final count = rankingOfflineTileCount(
        camera.visibleBounds,
        network.minimumZoom,
        network.maximumZoom,
      );
      return '$count tiles';
    }

    final before = shownCount();
    expect(before, countOnScreen());

    // A shorter window squeezes the map, showing less without moving it.
    tester.view.physicalSize = const Size(1600, 520);
    await tester.pumpAndSettle();

    expect(countOnScreen(), isNot(before));
    expect(shownCount(), countOnScreen());

    await tester.tap(find.widgetWithText(GlassButton, 'Cancel'));
    await tester.pumpAndSettle();
  });
}
