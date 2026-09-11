// Deck links resolve to an effective card set (STUDY_DECK_LINKS_HLD.md §4.3):
// a deck's own cards plus every enabled link's, recursively, each card once.
// Cycles are refused on write, and the sync layer drops the newest edge of
// any loop two devices built between them.

import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/domain/models/study_models.dart';
import 'package:voyager/domain/services/study_deck_graph.dart';

final _t0 = DateTime.utc(2026, 9, 1);

StudyDeck _deck(String id, {bool deleted = false}) => StudyDeck(
  id: id,
  createdAt: _t0,
  updatedAt: _t0,
  name: 'Deck $id',
  deletedAt: deleted ? _t0 : null,
);

StudyCard _card(String id, String deckId, {bool deleted = false}) => StudyCard(
  id: id,
  createdAt: _t0,
  updatedAt: _t0,
  deckId: deckId,
  frontText: 'Q $id',
  backText: 'A $id',
  dueAt: _t0,
  deletedAt: deleted ? _t0 : null,
);

StudyDeckLink _link(
  String parent,
  String child, {
  bool enabled = true,
  int minute = 0,
  bool deleted = false,
}) {
  final at = _t0.add(Duration(minutes: minute));
  return StudyDeckLink(
    id: StudyDeckLink.idFor(parent, child),
    createdAt: at,
    updatedAt: at,
    parentDeckId: parent,
    childDeckId: child,
    enabled: enabled,
    deletedAt: deleted ? at : null,
  );
}

StudyDeckGraph _graph({
  List<String> decks = const ['hub', 'docker', 'aws', 'nested'],
  List<StudyDeck> extraDecks = const [],
  required List<StudyCard> cards,
  required List<StudyDeckLink> links,
}) => StudyDeckGraph(
  decks: [for (final id in decks) _deck(id), ...extraDecks],
  cards: cards,
  links: links,
);

Set<String> _ids(Iterable<StudyCard> cards) => {for (final c in cards) c.id};

void main() {
  group('effectiveCards', () {
    test('own cards plus every enabled link, recursively', () {
      final graph = _graph(
        cards: [
          _card('h1', 'hub'),
          _card('d1', 'docker'),
          _card('n1', 'nested'),
        ],
        links: [_link('hub', 'docker'), _link('docker', 'nested')],
      );
      expect(_ids(graph.effectiveCards('hub')), {'h1', 'd1', 'n1'});
      expect(_ids(graph.effectiveCards('docker')), {'d1', 'n1'});
      expect(_ids(graph.ownCards('hub')), {'h1'});
    });

    test('a disabled link contributes nothing, nor anything below it', () {
      final graph = _graph(
        cards: [_card('d1', 'docker'), _card('n1', 'nested')],
        links: [
          _link('hub', 'docker', enabled: false),
          _link('docker', 'nested'),
        ],
      );
      expect(graph.effectiveCards('hub'), isEmpty);
      // The placeholder stays: a toggle parks the link, it doesn't remove it.
      expect(graph.linksFrom('hub').single.childDeckId, 'docker');
    });

    test('each link obeys its own toggle', () {
      final graph = _graph(
        cards: [_card('d1', 'docker'), _card('n1', 'nested')],
        links: [
          _link('hub', 'docker'),
          _link('docker', 'nested', enabled: false),
        ],
      );
      expect(_ids(graph.effectiveCards('hub')), {'d1'});
    });

    test('a card reachable on two paths is counted once', () {
      final graph = _graph(
        cards: [_card('n1', 'nested')],
        links: [
          _link('hub', 'docker'),
          _link('hub', 'aws'),
          _link('docker', 'nested'),
          _link('aws', 'nested'),
        ],
      );
      expect(graph.effectiveCards('hub').map((c) => c.id), ['n1']);
    });

    test('deleted cards, decks and links contribute nothing', () {
      final graph = _graph(
        decks: const ['hub', 'aws', 'nested'],
        extraDecks: [_deck('docker', deleted: true)],
        cards: [
          _card('d1', 'docker'),
          _card('a1', 'aws'),
          _card('a2', 'aws', deleted: true),
          _card('n1', 'nested'),
        ],
        links: [
          _link('hub', 'docker'),
          _link('hub', 'aws'),
          _link('hub', 'nested', deleted: true),
        ],
      );
      expect(_ids(graph.effectiveCards('hub')), {'a1'});
      // A deleted child drops its placeholder (§9).
      expect(graph.linksFrom('hub').map((l) => l.childDeckId), ['aws']);
    });

    test('a card moved out of a linked deck leaves the hub with it', () {
      final links = [_link('hub', 'aws')];
      final before = _graph(cards: [_card('c', 'aws')], links: links);
      final after = _graph(cards: [_card('c', 'docker')], links: links);
      expect(_ids(before.effectiveCards('hub')), {'c'});
      expect(after.effectiveCards('hub'), isEmpty);
    });

    test('a card moved onto the hub stays when the link is turned off', () {
      final graph = _graph(
        cards: [_card('c', 'hub')],
        links: [_link('hub', 'aws', enabled: false)],
      );
      expect(_ids(graph.effectiveCards('hub')), {'c'});
    });

    test('a cycle that slipped in by sync still resolves', () {
      final graph = _graph(
        cards: [_card('h1', 'hub'), _card('d1', 'docker')],
        links: [_link('hub', 'docker'), _link('docker', 'hub')],
      );
      expect(_ids(graph.effectiveCards('hub')), {'h1', 'd1'});
    });
  });

  group('wouldCreateCycle', () {
    final graph = _graph(
      cards: const [],
      links: [
        _link('hub', 'docker'),
        _link('docker', 'nested', enabled: false),
      ],
    );

    test('refuses self, direct and indirect loops', () {
      expect(graph.wouldCreateCycle('hub', 'hub'), isTrue);
      expect(graph.wouldCreateCycle('docker', 'hub'), isTrue);
      // Through a disabled link: re-enabling it does no check of its own.
      expect(graph.wouldCreateCycle('nested', 'hub'), isTrue);
    });

    test('allows an edge that closes no loop', () {
      expect(graph.wouldCreateCycle('hub', 'nested'), isFalse);
      expect(graph.wouldCreateCycle('aws', 'hub'), isFalse);
    });
  });

  test('parentsOf lists the live decks that link a deck', () {
    final graph = _graph(
      decks: const ['hub', 'aws'],
      extraDecks: [_deck('gone', deleted: true)],
      cards: const [],
      links: [_link('hub', 'aws'), _link('gone', 'aws')],
    );
    expect(graph.parentsOf('aws').map((d) => d.id), ['hub']);
  });

  group('studyDeckLinksClosingCycles', () {
    test('drops the newest edge of a two-device loop', () {
      final older = _link('a', 'b', minute: 1);
      final newer = _link('b', 'a', minute: 2);
      expect(studyDeckLinksClosingCycles([older, newer]), [newer]);
      // Whatever order the rows arrived in.
      expect(studyDeckLinksClosingCycles([newer, older]), [newer]);
    });

    test('drops the newest edge of a longer loop', () {
      final links = [
        _link('a', 'b', minute: 3),
        _link('b', 'c', minute: 1),
        _link('c', 'a', minute: 2),
      ];
      expect(
        studyDeckLinksClosingCycles(links).map((l) => l.id),
        [StudyDeckLink.idFor('a', 'b')],
      );
    });

    test('leaves an acyclic graph and tombstones alone', () {
      expect(
        studyDeckLinksClosingCycles([
          _link('a', 'b'),
          _link('a', 'c'),
          _link('b', 'c'),
          _link('c', 'a', deleted: true),
        ]),
        isEmpty,
      );
    });
  });
}
