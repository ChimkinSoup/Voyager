import 'package:voyager/domain/models/study_models.dart';

/// The library's deck-in-deck links, resolved against the decks and cards they
/// point at — STUDY_DECK_LINKS_HLD.md §4.3.
///
/// Pure and in-memory: built once from three flat lists, so every deck tile,
/// the workbench and the session launchers read the same answer without a
/// query per deck.
class StudyDeckGraph {
  StudyDeckGraph({
    required Iterable<StudyDeck> decks,
    required Iterable<StudyCard> cards,
    required Iterable<StudyDeckLink> links,
  }) {
    for (final deck in decks) {
      if (deck.deletedAt == null) _decks[deck.id] = deck;
    }
    for (final card in cards) {
      if (card.deletedAt != null) continue;
      _cardsByDeck.putIfAbsent(card.deckId, () => []).add(card);
    }
    final live = [
      for (final link in links)
        if (link.deletedAt == null) link,
    ]..sort(_byAge);
    for (final link in live) {
      _outgoing.putIfAbsent(link.parentDeckId, () => []).add(link);
      _incoming.putIfAbsent(link.childDeckId, () => []).add(link);
    }
  }

  /// What a surface reads while the three lists are still loading.
  static final empty = StudyDeckGraph(decks: const [], cards: const [], links: const []);

  final _decks = <String, StudyDeck>{};
  final _cardsByDeck = <String, List<StudyCard>>{};

  /// Every live link row, by either end — deck liveness is applied on read,
  /// not here, so the cycle check still sees an edge whose child a sync pull
  /// has not delivered yet.
  final _outgoing = <String, List<StudyDeckLink>>{};
  final _incoming = <String, List<StudyDeckLink>>{};

  StudyDeck? deck(String id) => _decks[id];

  /// [deckId]'s native cards — the ones whose home it is.
  List<StudyCard> ownCards(String deckId) => _cardsByDeck[deckId] ?? const [];

  /// The links [parentDeckId] shows as placeholders: live rows to a live
  /// child, enabled or not, oldest first. A soft-deleted child drops its
  /// placeholder (§9).
  List<StudyDeckLink> linksFrom(String parentDeckId) => [
    for (final link in _outgoing[parentDeckId] ?? const <StudyDeckLink>[])
      if (_decks.containsKey(link.childDeckId)) link,
  ];

  /// The live decks that link [childDeckId] — the "Included in" readout.
  List<StudyDeck> parentsOf(String childDeckId) => [
    for (final link in _incoming[childDeckId] ?? const <StudyDeckLink>[])
      ?_decks[link.parentDeckId],
  ];

  /// Every card a Study or Cram session of [deckId] draws from: its own cards,
  /// then — recursively — each enabled link's, deduped by card id with the
  /// first path to reach a card winning.
  ///
  /// Cycles are refused on write, but a pull can land one before the sync
  /// layer breaks it, so the walk still keeps a visited set.
  List<StudyCard> effectiveCards(String deckId) {
    final seenCards = <String>{};
    final seenDecks = <String>{};
    final result = <StudyCard>[];
    void walk(String id) {
      if (!_decks.containsKey(id) || !seenDecks.add(id)) return;
      for (final card in ownCards(id)) {
        if (seenCards.add(card.id)) result.add(card);
      }
      for (final link in _outgoing[id] ?? const <StudyDeckLink>[]) {
        if (link.enabled) walk(link.childDeckId);
      }
    }

    walk(deckId);
    return result;
  }

  /// Whether linking [childDeckId] into [parentDeckId] would close a loop:
  /// the parent is the child itself, or is already reachable from it.
  ///
  /// Walks disabled links too. Re-enabling one does no check of its own, so
  /// a loop that only exists while a toggle is off is still a loop.
  bool wouldCreateCycle(String parentDeckId, String childDeckId) {
    if (parentDeckId == childDeckId) return true;
    return _reaches(childDeckId, parentDeckId);
  }

  bool _reaches(String from, String to) {
    final seen = <String>{};
    final stack = [from];
    while (stack.isNotEmpty) {
      final id = stack.removeLast();
      if (id == to) return true;
      if (!seen.add(id)) continue;
      for (final link in _outgoing[id] ?? const <StudyDeckLink>[]) {
        stack.add(link.childDeckId);
      }
    }
    return false;
  }
}

/// Oldest first, ties broken by id — the one order every device agrees on.
int _byAge(StudyDeckLink a, StudyDeckLink b) {
  final byCreated = a.createdAt.compareTo(b.createdAt);
  return byCreated != 0 ? byCreated : a.id.compareTo(b.id);
}

/// The links to drop so that [links] holds no cycle, for the sync layer to
/// tombstone after a pull (§9: two devices can each add one half of a loop
/// while apart).
///
/// Links are admitted oldest first and one that would close a loop is the
/// one refused — so of any cycle, the newest edge goes. The order depends only
/// on the rows, never on which device is asking or what it pulled first, so
/// two devices that see the same links drop the same one.
List<StudyDeckLink> studyDeckLinksClosingCycles(Iterable<StudyDeckLink> links) {
  final live = [
    for (final link in links)
      if (link.deletedAt == null) link,
  ]..sort(_byAge);
  final outgoing = <String, List<String>>{};
  bool reaches(String from, String to) {
    final seen = <String>{};
    final stack = [from];
    while (stack.isNotEmpty) {
      final id = stack.removeLast();
      if (id == to) return true;
      if (!seen.add(id)) continue;
      stack.addAll(outgoing[id] ?? const []);
    }
    return false;
  }

  final dropped = <StudyDeckLink>[];
  for (final link in live) {
    if (link.parentDeckId == link.childDeckId ||
        reaches(link.childDeckId, link.parentDeckId)) {
      dropped.add(link);
      continue;
    }
    outgoing.putIfAbsent(link.parentDeckId, () => []).add(link.childDeckId);
  }
  return dropped;
}
