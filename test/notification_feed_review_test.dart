// Due study cards and LeetCode problems reach the inbox as one row per queue
// (GAPS.md, "Inbox doesn't know about spaced repetition"). These pin how the
// rows are counted and keyed; the widget tests below drive the real popover.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/leetcode_models.dart';
import 'package:voyager/domain/models/notification_models.dart';
import 'package:voyager/domain/models/study_models.dart';
import 'package:voyager/features/notifications/notification_bell.dart';
import 'package:voyager/features/notifications/notification_inbox_popover.dart';

import 'fakes/fake_weather_api_client.dart';

final _stamp = DateTime.utc(2026, 1, 1);

StudyCard _card(String id, DateTime dueAt) => StudyCard(
  id: id,
  createdAt: _stamp,
  updatedAt: _stamp,
  deckId: 'deck',
  frontText: 'Front',
  backText: 'Back',
  dueAt: dueAt,
);

LeetCodeProblem _problem(String id, DateTime? dueAt) => LeetCodeProblem(
  id: id,
  createdAt: _stamp,
  updatedAt: _stamp,
  title: 'Two Sum',
  difficulty: LeetCodeDifficulty.easy,
  solvedAt: _stamp,
  dueAt: dueAt,
);

List<NotificationFeedItem> _feed({
  List<StudyCard> cards = const [],
  List<LeetCodeProblem> problems = const [],
  required DateTime now,
}) => buildNotificationFeed(
  tasks: const [],
  events: const [],
  bills: const [],
  studyCards: cards,
  leetCodeProblems: problems,
  now: now,
);

void main() {
  group('buildNotificationFeed review rows', () {
    final now = DateTime(2026, 9, 25, 14, 30);

    test('counts due cards and due problems, one row per queue', () {
      final feed = _feed(
        cards: [
          _card('a', now.subtract(const Duration(days: 2)).toUtc()),
          _card('b', now.toUtc()),
          _card('c', now.add(const Duration(minutes: 1)).toUtc()),
        ],
        problems: [
          // Never graded reads as due, the same as in the Review Deck.
          _problem('p1', null),
          _problem('p2', now.add(const Duration(days: 3)).toUtc()),
        ],
        now: now,
      );

      expect(feed, hasLength(2));
      final study = feed.firstWhere(
        (i) => i.reviewSource == ReviewSource.study,
      );
      final leetcode = feed.firstWhere(
        (i) => i.reviewSource == ReviewSource.leetcode,
      );
      expect(study.type, NotificationItemType.review);
      expect(study.reviewCount, 2);
      expect(leetcode.reviewCount, 1);
      expect(study.dueAt, DateTime(2026, 9, 25));
    });

    test('a queue with nothing due gets no row', () {
      final feed = _feed(
        cards: [_card('a', now.add(const Duration(days: 1)).toUtc())],
        now: now,
      );
      expect(feed, isEmpty);
    });

    test('hiding a review row lasts the day', () {
      final cards = [_card('a', DateTime.utc(2026, 9, 1))];
      final today = _feed(cards: cards, now: now).single;
      final laterToday = _feed(
        cards: cards,
        now: DateTime(2026, 9, 25, 23, 59),
      ).single;
      final tomorrow = _feed(
        cards: cards,
        now: DateTime(2026, 9, 26, 0, 1),
      ).single;

      expect(today.dismissalKey, 'review:study@2026-09-25|semi');
      expect(laterToday.dismissalKey, today.dismissalKey);
      expect(tomorrow.dismissalKey, isNot(today.dismissalKey));
    });
  });

  group('inbox review rows', () {
    Future<ProviderContainer> seed(
      WidgetTester tester, {
      List<String> hiddenPages = const [],
    }) async {
      tester.view.physicalSize = const Size(380, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final db = AppDatabase.inMemory();
      addTearDown(db.close);
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          syncRepositoryProvider.overrideWithValue(InMemorySyncRepository()),
          weatherApiClientProvider.overrideWithValue(FakeWeatherApiClient()),
        ],
      );
      addTearDown(container.dispose);

      final settingsRepo = container.read(settingsRepositoryProvider);
      await settingsRepo.saveSettings(
        (await settingsRepo.getSettings()).copyWith(
          hiddenNavPages: hiddenPages,
        ),
      );
      final study = container.read(studyRepositoryProvider);
      final now = DateTime.now().toUtc();
      await study.upsertDeck(
        StudyDeck(id: 'deck', name: 'Deck', createdAt: now, updatedAt: now),
      );
      for (final id in ['a', 'b']) {
        await study.upsertCard(
          _card(id, now.subtract(const Duration(days: 1))),
        );
      }
      return container;
    }

    Future<void> pumpInbox(
      WidgetTester tester,
      ProviderContainer container,
    ) async {
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            // The real bell: it owns the once-a-minute feed refresh.
            builder: (_, _) => const Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: NotificationBell(accent: Colors.blue),
              ),
            ),
          ),
          GoRoute(
            path: '/study',
            builder: (_, _) => const Scaffold(body: Text('Study page')),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(
            theme: VoyagerTheme.dark(),
            routerConfig: router,
          ),
        ),
      );
      await tester.tap(find.byType(NotificationBell));
      // Not pumpAndSettle: the popover keeps animations ticking while the
      // providers resolve.
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 80));
      }
    }

    testWidgets('shows due cards without lighting the bell, and opens Study', (
      tester,
    ) async {
      final container = await seed(tester);
      await pumpInbox(tester, container);

      expect(find.text('2 cards due'), findsOneWidget);
      expect(container.read(notificationBadgeStateProvider), isNull);

      await tester.tap(find.text('2 cards due'));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 80));
      }
      expect(find.byType(NotificationInboxPopover), findsNothing);
      expect(find.text('Study page'), findsOneWidget);
    });

    testWidgets('a card falling due shows up on the next tick', (tester) async {
      final container = await seed(tester);
      final dueSoon = DateTime.now().toUtc().add(
        const Duration(milliseconds: 300),
      );
      await container
          .read(studyRepositoryProvider)
          .upsertCard(_card('c', dueSoon));
      container.invalidate(studyAllCardsProvider);
      await pumpInbox(tester, container);
      expect(find.text('2 cards due'), findsOneWidget);

      // Real time, for DateTime.now(); then fake time, for the clock's timer.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 500)),
      );
      await tester.pump(const Duration(minutes: 1));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 80));
      }

      expect(find.text('3 cards due'), findsOneWidget);
    });

    testWidgets('a page hidden from the rail gets no row', (tester) async {
      final container = await seed(tester, hiddenPages: ['/study']);
      await pumpInbox(tester, container);

      expect(find.byType(NotificationInboxPopover), findsOneWidget);
      expect(find.text('2 cards due'), findsNothing);
    });
  });
}
