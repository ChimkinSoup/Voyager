import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/features/gaia/companion/gaia_stats.dart';
import 'package:voyager/features/gaia/remote/gaia_stats_counter.dart';
import 'package:voyager/features/gaia/usage/gaia_stats_model.dart';
import 'package:voyager/features/gaia/usage/gaia_tokens.dart';

/// Gaia's lifetime stats in Firestore (GAIA_STATS_HLD.md §4).
void main() {
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  test(
    'adds up sightings, chats and meteors; a day and a first only once',
    () async {
      final firestore = FakeFirebaseFirestore();
      final counter = GaiaStatsCounter(firestore);
      // Signed out: dropped.
      await counter.add({'kind': 'chat'});
      counter.setUser('u1');
      await settle();

      await counter.add({'kind': 'satellite', 'id': 'iss'});
      await settle();
      final first = counter.stats.value!.satellites['iss']!.first;
      expect(first, isNotNull);
      await counter.add({'kind': 'satellite', 'id': 'iss'});
      await counter.add({'kind': 'aurora', 'id': 'gold'});
      await counter.add({'kind': 'meteors', 'n': 3});
      await counter.add({'kind': 'meteors', 'n': 2});
      await counter.add({'kind': 'chat'});
      await counter.add({'kind': 'day', 'day': '2026-11-22'});
      await counter.add({'kind': 'day', 'day': '2026-11-22'});
      await counter.add({'kind': 'day', 'day': '2026-11-23'});
      await settle();

      final stats = counter.stats.value!;
      expect(stats.satellites['iss']!.count, 2);
      expect(stats.satellites['iss']!.first, first);
      expect(stats.auroras['gold']!.count, 1);
      expect(stats.auroras['gold']!.first, isNotNull);
      expect(stats.meteors, 5);
      expect(stats.chats, 1);
      expect(stats.days, {'2026-11-22', '2026-11-23'});
    },
  );

  test('two desktops add to one count', () async {
    final firestore = FakeFirebaseFirestore();
    final laptop = GaiaStatsCounter(firestore)..setUser('u1');
    final desktop = GaiaStatsCounter(firestore)..setUser('u1');
    await settle();
    await laptop.add({'kind': 'chat'});
    await desktop.add({'kind': 'chat'});
    await settle();

    expect(laptop.stats.value!.chats, 2);
    expect(desktop.stats.value!.chats, 2);
  });

  test('reaches the companion as it left the main instance', () {
    final stats = GaiaStats(
      satellites: {
        'hubble': GaiaSeen(count: 4, first: DateTime(2026, 11, 14, 21, 3)),
      },
      auroras: const {'mauve': GaiaSeen(count: 1)},
      meteors: 120,
      chats: 9,
      days: const {'2026-11-22'},
    );
    final back = GaiaStats.fromJson(stats.toJson());

    expect(back.toJson(), stats.toJson());
    expect(back.satellites['hubble']!.first, DateTime(2026, 11, 14, 21, 3));
  });

  testWidgets(
    'the stats group the token count by account, tier and model, and the '
    'utility model by job',
    (tester) async {
      GaiaTokenRow row(
        String account,
        String source,
        String model,
        int input,
      ) => GaiaTokenRow(
        account: account,
        source: source,
        model: model,
        count: GaiaTokenCount(input: input),
      );
      final rows = [
        row('claude_code', 'deep', 'claude-opus-5-5', 3000),
        row('claude_code', 'quick', 'claude-haiku-5-5', 100),
        row('claude_code', 'utility:chat title', 'claude-haiku-5-5', 20),
        row('claude_code', 'utility:image caption', 'claude-haiku-5-5', 50),
        row('codex/work', 'standard', 'gpt-6.1-sol', 900),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ListView(
                children: gaiaTokenLines(
                  context,
                  rows,
                  (key) => key == 'claude_code' ? 'Claude · Default' : key,
                ),
              ),
            ),
          ),
        ),
      );
      List<String> texts() => [
        for (final text in tester.widgetList<Text>(find.byType(Text)))
          if (!text.data!.contains(' in · ')) text.data!,
      ];
      expect(texts(), [
        'All',
        '4.07K',
        'Claude · Default',
        '3.17K',
        'Quick',
        '100',
        'claude-haiku-5-5',
        '100',
        'Deep',
        '3K',
        'claude-opus-5-5',
        '3K',
        'Utility',
        '70',
        'Image caption',
        '50',
        'Chat title',
        '20',
        'codex/work',
        '900',
        'Standard',
        '900',
        'gpt-6.1-sol',
        '900',
      ]);
    },
  );
}
