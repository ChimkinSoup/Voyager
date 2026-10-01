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
import 'package:voyager/core/widgets/labeled_text_field.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/geoapify_client.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/ranking_models.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/features/rankings/rankings_edit_panel.dart';
import 'package:voyager/features/rankings/rankings_header.dart';
import 'package:voyager/features/rankings/rankings_locations_section.dart';
import 'package:voyager/features/rankings/rankings_map_chrome.dart';
import 'package:voyager/features/rankings/rankings_map_view.dart';
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
/// `ennio`, nothing for anything else, and one address for every point.
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

Future<({AppDatabase db, ProviderContainer container})> pumpRankingsPage(
  WidgetTester tester, {
  required Future<void> Function(DriftRankingRepository repo) seed,
  GeoapifyClient? geoapify,
  bool withKey = true,
  RankingsDeviceLocation? deviceLocation,
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

List<RankingsMapPin> pins(WidgetTester tester) =>
    tester.widgetList<RankingsMapPin>(find.byType(RankingsMapPin)).toList();

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
MapCamera mapCamera(WidgetTester tester) =>
    MapCamera.of(tester.element(find.byType(RankingsTileLayer).first));

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
      expect(mapCamera(tester).zoom, 16);

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

      await tester.enterText(dialogInput(), 'ennio');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(requests, hasLength(1));
      await tester.tap(find.text("Ennio's Pasta House"));
      await tester.pumpAndSettle();
      await tester.tap(dialogAdd());
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
      // ...when a searched place is picked instead.
      await tester.enterText(dialogInput(), 'ennio');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      await tester.tap(find.text("Ennio's Pasta House"));
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
  });
}
