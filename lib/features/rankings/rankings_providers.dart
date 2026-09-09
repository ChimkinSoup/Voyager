import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/domain/models/ranking_models.dart';
import 'package:voyager/domain/rankings/ranking_queries.dart';

/// The category the page is showing, by id. Null means "the first one", which
/// is what a cold open resolves to; the page writes an explicit id as soon as
/// the user picks one.
final rankingSelectedCategoryProvider = StateProvider<String?>((ref) => null);

/// The category the page is actually showing, resolved from the selection and
/// the list — the same fallback the page makes, in a form the popovers can
/// watch.
///
/// The sort and filter menus live in a pushed route, so nothing rebuilds them
/// when the page rebuilds. Reading the category through a provider is what
/// keeps an open menu honest about the sort it just changed (§4.2).
final rankingActiveCategoryProvider = Provider<RankingCategory?>((ref) {
  final categories =
      ref.watch(rankingCategoriesProvider).valueOrNull ??
      const <RankingCategory>[];
  final selectedId = ref.watch(rankingSelectedCategoryProvider);
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

/// How the open entry's child list is being looked at. A view only — it never
/// writes the saved order back (§6.4).
final rankingChildSortProvider =
    StateProvider<({RankingChildSort sort, String? fieldId})>(
      (ref) => (sort: RankingChildSort.saved, fieldId: null),
    );

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
