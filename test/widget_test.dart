import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/app/voyager_app.dart';
import 'package:voyager/data/remote/firebase_auth_repository.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'fakes/fake_weather_api_client.dart';

void main() {
  testWidgets('app renders login screen', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
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
