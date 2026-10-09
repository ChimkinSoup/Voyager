import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:vector_map_tiles/vector_map_tiles.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/dev/dev_flags.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/data/remote/geoapify_client.dart';
import 'package:voyager/domain/models/ranking_models.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/rankings/ranking_queries.dart';

/// The category the page is showing, by id. Null means "whichever this device
/// was last on" (else the first), which is what a cold open resolves to; the
/// page writes an explicit id as soon as the user picks one.
final rankingSelectedCategoryProvider = StateProvider<String?>((ref) => null);

/// The selection that stands for the All categories map rather than for any
/// one category. Stored as the last-viewed id like a real one; with no
/// location-enabled category left it falls back the way a stale id does.
const rankingAllCategoriesId = 'all-categories';

/// The active categories that have a map, which is what All categories
/// overlays — and what has to be non-empty for it to be offered at all.
List<RankingCategory> rankingLocationCategories(
  Iterable<RankingCategory> categories,
) => [
  for (final category in categories)
    if (category.locationEnabled && !category.isArchived) category,
];

/// Where the rankings map is now, or was last left in this run of the app:
/// kept by the open map as it moves, and empty at launch so the first map
/// opens on the device. Nothing watches it — it is read when a map opens, and
/// when a place search needs somewhere to search around.
final rankingMapViewportProvider = StateProvider<RankingsMapViewport?>(
  (ref) => null,
);

/// Whether the map shows its zoom level. Toggled from the Dev page; lives
/// here so the map can watch it without depending on the dev feature.
final rankingMapShowZoomProvider = StateProvider<bool>(
  (ref) => DevFlags.showRankingsMapZoom,
);

/// Where the device was last found in this run of the app — by a map, or by
/// the editor's preview — for the preview to measure distances from. Null
/// until it is found.
final rankingDevicePointProvider = StateProvider<LatLng?>((ref) => null);

/// When [findRankingDevice] last got a fresh fix in this run of the app. Null
/// until it has.
final rankingDeviceFoundAtProvider = StateProvider<DateTime?>((ref) => null);

/// Where the device was last found: in this run, else on an earlier one. Null
/// when it never has been.
final rankingDeviceLocationProvider = Provider<LatLng?>((ref) {
  final saved = ref.watch(
    settingsProvider.select((s) => s.valueOrNull?.rankingsDeviceLocation),
  );
  return ref.watch(rankingDevicePointProvider) ??
      (saved == null ? null : LatLng(saved.latitude, saved.longitude));
});

/// A fresh fix of the device, or throws when none comes within 15 seconds.
/// Saved for a later run to start from, and published to
/// [rankingDevicePointProvider] and [rankingDeviceFoundAtProvider]. [read] is
/// a `Ref`'s or a container's.
Future<LatLng> findRankingDevice(
  T Function<T>(ProviderListenable<T> provider) read,
) async {
  final position = await Geolocator.getCurrentPosition(
    locationSettings: const LocationSettings(timeLimit: Duration(seconds: 15)),
  );
  unawaited(
    read(settingsRepositoryProvider).saveRankingsDeviceLocation((
      latitude: position.latitude,
      longitude: position.longitude,
    )),
  );
  final point = LatLng(position.latitude, position.longitude);
  read(rankingDevicePointProvider.notifier).state = point;
  read(rankingDeviceFoundAtProvider.notifier).state = DateTime.now();
  return point;
}

/// A location the open map should pan to — a row clicked in the editor's
/// Locations section. The map clears it once it has moved.
final rankingMapFocusProvider = StateProvider<RankingLocation?>((ref) => null);

/// Where the map's tiles come from. Null is the real thing: Geoapify over the
/// network. Tests override it so nothing leaves the machine.
final rankingMapTileProviderProvider = Provider<VectorTileProvider?>(
  (ref) => null,
);

/// Follows a Google Maps short link to the full link it stands for.
final googleMapsShortLinkResolverProvider =
    Provider<Future<Uri?> Function(Uri link)>((ref) {
      final client = http.Client();
      ref.onDispose(client.close);
      return (link) => resolveGoogleMapsShortLink(link, client);
    });

/// The category the page is actually showing, resolved from the selection and
/// the list — the same fallback the page makes, in a form the popovers can
/// watch.
///
/// The sort and filter menus live in a pushed route, so nothing rebuilds them
/// when the page rebuilds. Reading the category through a provider is what
/// keeps an open menu honest about the sort it just changed (§4.2).
final rankingActiveCategoryProvider = Provider<RankingCategory?>((ref) {
  final categories =
      ref.watch(rankingCategoriesProvider.settled).valueOrNull ??
      const <RankingCategory>[];
  final selectedId =
      ref.watch(rankingSelectedCategoryProvider) ??
      ref.watch(settingsProvider).valueOrNull?.lastViewedRankingCategoryId;
  if (selectedId == rankingAllCategoriesId &&
      rankingLocationCategories(categories).isNotEmpty) {
    return null;
  }
  return categories.where((c) => c.id == selectedId).firstOrNull ??
      categories.where((c) => !c.isArchived).firstOrNull;
});

/// Search box contents. Page-local, and deliberately not part of the global
/// Search page's corpora (§2).
final rankingSearchQueryProvider = StateProvider<String>((ref) => '');

/// The toolbar's narrowing. Not persisted: a filter is something you put on to
/// find one thing, unlike the sort, which is how you like to read the list.
final rankingFiltersProvider = StateProvider<RankingFilters>(
  (ref) => RankingFilters.none,
);

/// The entry whose editor panel is open, by id. Null closes the panel.
final rankingSelectedParentProvider = StateProvider<String?>((ref) => null);

/// What the editor panel shows for the open entry's title and overall score,
/// for its row in the list to show too.
///
/// The panel saves the title 400ms after typing stops and a score once its
/// popover closes, and the list only learns of either from the re-read after
/// the save. Its row reads this instead, so it keeps pace with the panel while
/// only that row rebuilds; the order and the averages still wait for the save.
final rankingPanelDraftProvider =
    StateProvider<({String id, String title, double? score})?>((ref) => null);

/// How the open entry's child list is being looked at. A view only — it never
/// writes the saved order back (§6.4).
final rankingChildSortProvider =
    StateProvider<({RankingChildSort sort, String? fieldId})>(
      (ref) => (sort: RankingChildSort.saved, fieldId: null),
    );

/// The rescales running now, by [rankingRescaleKey].
///
/// Held in a provider rather than on the sheet's widgets: switching tabs
/// remounts them mid-rescale, and a fresh widget would offer the pills again
/// while the category still reads the old scale.
final rankingRescalesInFlightProvider = StateProvider<Set<String>>(
  (ref) => const {},
);

/// [fieldId] null is the overall score ([isParent] says whose).
String rankingRescaleKey(
  String categoryId, {
  String? fieldId,
  bool isParent = true,
}) => '$categoryId/${fieldId ?? (isParent ? 'parent' : 'child')}';

/// Every rankings document id that has at least one image on it, parents and
/// children alike.
///
/// One pass over the reference table rather than a query per row: the
/// "has images" filter has to answer for every entry at once, and a row's own
/// fan loads its pictures itself either way.
final rankingDocumentIdsWithImagesProvider = FutureProvider<Set<String>>((
  ref,
) async {
  // Rebuilt whenever an image is attached or removed anywhere.
  ref.watch(mediaServiceProvider);
  final references = await ref.watch(mediaRepositoryProvider).listReferences();
  return {
    for (final reference in references)
      if (reference.collection == FirestoreCollections.rankings)
        reference.documentId,
  };
});
