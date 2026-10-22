// A click on a floater's bare background played the Windows ding: the
// floater's page let it through to its route's modal barrier, which answers a
// click it can't dismiss on with the system alert.

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/features/hotkeys/floaters/floater_controller.dart';
import 'package:voyager/features/hotkeys/floaters/floater_host.dart';
import 'package:voyager/features/hotkeys/quick_capture.dart';

import 'fakes/fake_weather_api_client.dart';

class _OpenFloater extends FloaterController {
  _OpenFloater(super.ref);

  @override
  QuickCaptureKind? get active => QuickCaptureKind.todo;
}

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  testWidgets('clicking the floater background plays no sound', (tester) async {
    final sounds = <Object?>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'SystemSound.play') sounds.add(call.arguments);
        return null;
      },
    );
    final db = AppDatabase.inMemory();
    addTearDown(db.close);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          syncRepositoryProvider.overrideWithValue(InMemorySyncRepository()),
          weatherApiClientProvider.overrideWithValue(FakeWeatherApiClient()),
          floaterControllerProvider.overrideWith(_OpenFloater.new),
        ],
        child: const MaterialApp(home: FloaterHost(child: SizedBox())),
      ),
    );
    await tester.pumpAndSettle();

    final size = tester.getSize(find.byType(FloaterHost));
    await tester.tapAt(Offset(size.width - 2, size.height - 2));
    await tester.pumpAndSettle();

    expect(sounds, isEmpty);
  });
}
