import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Breadcrumb stack of folder UUIDs the Study Hub has drilled into. Empty
/// means the Hub is showing the root level. Pushing/popping this list is the
/// entire folder-navigation model per STUDY.md's "in-memory stack" spec —
/// each change re-queries [studyFoldersProvider]/[studyDecksProvider] for
/// the new top-of-stack parent id.
final studyBreadcrumbStackProvider = StateProvider<List<String>>((ref) => []);

/// The deck currently zoomed into (Deck Workbench open). Null means the Hub
/// is showing. Distinct from the breadcrumb stack so leaving a deck returns
/// to the folder level the user was browsing, not back to root.
final studyActiveDeckIdProvider = StateProvider<String?>((ref) => null);

/// Multi-select mode toggle on the Deck Workbench's card list.
final studyMultiSelectEnabledProvider = StateProvider<bool>((ref) => false);

/// Card ids currently checked while [studyMultiSelectEnabledProvider] is on.
final studySelectedCardIdsProvider = StateProvider<Set<String>>((ref) => {});

/// Keyword filter typed into the Workbench control bar's search field.
final studySearchQueryProvider = StateProvider<String>((ref) => '');
