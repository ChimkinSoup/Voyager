// Enter on an empty name in the shared "New journal / list / calendar" dialog
// said "Title cannot be empty" under a field labelled "Name", and left keyboard
// focus nowhere; the custom quotes dialog dropped focus the same way on a
// rejected quote (BUG-050).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/widgets/create_name_color_dialog.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/features/settings/custom_quotes_dialog.dart';

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

Widget _launcher(void Function(BuildContext) show) => MaterialApp(
  home: Scaffold(
    body: Builder(
      builder: (context) =>
          TextButton(onPressed: () => show(context), child: const Text('open')),
    ),
  ),
);

bool _fieldHasFocus(WidgetTester tester) {
  final editable = tester.widget<EditableText>(find.byType(EditableText));
  return editable.focusNode.hasPrimaryFocus;
}

void main() {
  testWidgets(
    'an empty name is rejected as a name and keeps the field focused',
    (tester) async {
      await tester.pumpWidget(
        _launcher(
          (context) => showCreateNameColorDialog(
            context,
            title: 'New journal',
            palette: const [0xFF3366FF, 0xFFFF6633],
            initialColor: 0xFF3366FF,
          ),
        ),
      );
      await _open(tester);
      expect(_fieldHasFocus(tester), isTrue);

      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(find.text('Name cannot be empty'), findsOneWidget);
      expect(find.text('Title cannot be empty'), findsNothing);
      expect(_fieldHasFocus(tester), isTrue);

      // What's typed next lands in the field.
      tester.testTextInput.enterText('Alpha');
      await tester.pumpAndSettle();
      expect(find.text('Alpha'), findsOneWidget);
      expect(find.text('Name cannot be empty'), findsNothing);
    },
  );

  testWidgets('a rejected custom quote keeps the field focused', (
    tester,
  ) async {
    final db = AppDatabase.inMemory();
    addTearDown(db.close);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          bundledQuotesProvider.overrideWith(
            (ref) async => const [Quote(id: 'b1', text: 'Bundled quote')],
          ),
        ],
        child: _launcher(showCustomQuotesDialog),
      ),
    );
    await _open(tester);

    // Empty, then a duplicate of a bundled quote.
    for (final (text, error) in [
      ('', 'Write a quote first.'),
      ('bundled QUOTE', 'That quote is already in the pool.'),
    ]) {
      final field = find.byType(EditableText).first;
      await tester.tap(field);
      await tester.pump();
      tester.testTextInput.enterText(text);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();

      expect(find.text(error), findsOneWidget);
      expect(
        tester.widget<EditableText>(field).focusNode.hasPrimaryFocus,
        isTrue,
      );
    }
  });
}
