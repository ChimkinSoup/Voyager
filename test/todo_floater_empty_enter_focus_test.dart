// Enter on the quick to-do bar with nothing (or only spaces) in it creates
// nothing, and used to drop keyboard focus, so whatever was typed next was
// lost (BUG-037).

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/remote/in_memory_sync.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/features/hotkeys/floaters/todo_floater.dart';

import 'fakes/fake_weather_api_client.dart';

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  for (final typed in ['', '   ']) {
    testWidgets('Enter on "$typed" keeps the field focused', (tester) async {
      final db = AppDatabase.inMemory();
      addTearDown(db.close);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            syncRepositoryProvider.overrideWithValue(InMemorySyncRepository()),
            weatherApiClientProvider.overrideWithValue(FakeWeatherApiClient()),
          ],
          child: const MaterialApp(home: Scaffold(body: TodoFloater())),
        ),
      );
      await tester.pumpAndSettle();

      final field = find.byType(EditableText);
      await tester.enterText(field, typed);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(tester.widget<EditableText>(field).focusNode.hasFocus, isTrue);
      await tester.enterText(field, 'abc');
      expect(tester.widget<EditableText>(field).controller.text, 'abc');
      expect(await DriftTodoRepository(db).listLists(), isEmpty);
    });
  }
}
