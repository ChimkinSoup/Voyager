import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/app/voyager_app.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/firebase_auth_repository.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'fakes/fake_weather_api_client.dart';

void main() {
  testWidgets('app renders login screen', (tester) async {
    // Without this override, databaseProvider opens the real on-disk
    // voyager.sqlite (see app_database.dart's _openConnection). That both
    // leaks test runs into real app data and, if the persisted settings have
    // the background wave/petal animation on, makes the Timer-driven
    // animation reschedule forever inside pumpAndSettle's fake-async loop —
    // an unbounded, ever-accelerating rebuild loop with no timeout.
    final db = AppDatabase.inMemory();
    addTearDown(db.close);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          authRepositoryProvider.overrideWithValue(InMemoryAuthRepository()),
          syncRepositoryProvider.overrideWithValue(InMemorySyncRepository()),
          weatherApiClientProvider.overrideWithValue(FakeWeatherApiClient()),
        ],
        child: const VoyagerApp(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Voyager'), findsOneWidget);
    expect(find.text('Sign in'), findsOneWidget);
    expect(find.text('Forgot password?'), findsOneWidget);
  });
}
