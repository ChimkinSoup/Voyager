// Settings → Jobs → Experience snippets (JOBS_EXPERIENCE_SNIPPETS_HLD.md §6.1,
// §8, §12): add, edit, delete behind a confirm, drag to reorder, and an
// editor whose warnings never block Save and whose Clean paste only rewrites
// when pressed — and not even then, if the edit is cancelled.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/features/settings/job_experience_snippets_dialog.dart';

const _warning = 'Non-standard characters or spacing detected';

void main() {
  late AppDatabase db;
  late DriftSettingsRepository repo;

  setUp(() {
    db = AppDatabase.inMemory();
    repo = DriftSettingsRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  Future<void> seed(List<JobExperienceSnippet> snippets) async {
    await repo.saveSettings(
      (await repo.getSettings()).copyWith(jobExperienceSnippets: snippets),
    );
  }

  Future<List<JobExperienceSnippet>> stored() async =>
      (await repo.getSettings()).jobExperienceSnippets;

  Future<void> openDialog(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showJobExperienceSnippetsDialog(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  // The editor is the only place with text fields: name first, then body.
  Finder nameField() => find.byType(TextField).at(0);
  Finder descriptionField() => find.byType(TextField).at(1);

  String descriptionText(WidgetTester tester) =>
      tester.widget<TextField>(descriptionField()).controller!.text;

  GlassButton button(WidgetTester tester, String label) =>
      tester.widget<GlassButton>(
        find.ancestor(of: find.text(label), matching: find.byType(GlassButton)),
      );

  testWidgets('adding one saves the name trimmed and the body verbatim', (
    tester,
  ) async {
    await openDialog(tester);
    expect(find.text("You haven't added any experiences yet."), findsOneWidget);

    await tester.tap(find.text('Add experience'));
    await tester.pumpAndSettle();
    await tester.enterText(nameField(), '  Acme - SWE Intern  ');
    await tester.enterText(descriptionField(), '- Built X.\n\n- Shipped Y.\n');
    await tester.pumpAndSettle();
    expect(find.text('25 characters'), findsOneWidget);

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final list = await stored();
    expect(list, hasLength(1));
    expect(list.single.name, 'Acme - SWE Intern');
    expect(list.single.description, '- Built X.\n\n- Shipped Y.\n');
    expect(find.text('Acme - SWE Intern'), findsOneWidget);
  });

  testWidgets('the editor fits a short window by shrinking the description', (
    tester,
  ) async {
    await openDialog(tester);
    tester.view.physicalSize = const Size(1000, 560);
    await tester.tap(find.text('Add experience'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(tester.getSize(descriptionField()).height, lessThan(560));
    expect(find.text('Save'), findsOneWidget);
  });

  testWidgets('a blank name blocks Save', (tester) async {
    await openDialog(tester);
    await tester.tap(find.text('Add experience'));
    await tester.pumpAndSettle();
    await tester.enterText(nameField(), '   ');
    await tester.enterText(descriptionField(), 'Body');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('Give the experience a name.'), findsOneWidget);
    // Still editing, nothing written.
    expect(find.text('Add experience'), findsWidgets);
    expect(nameField(), findsOneWidget);
    expect(await stored(), isEmpty);
  });

  testWidgets('warnings show as you type and do not block Save', (
    tester,
  ) async {
    await openDialog(tester);
    await tester.tap(find.text('Add experience'));
    await tester.pumpAndSettle();
    await tester.enterText(nameField(), 'Acme');
    await tester.enterText(descriptionField(), 'Plain text.');
    await tester.pumpAndSettle();
    expect(find.text(_warning), findsNothing);
    // Nothing to clean, so the button says so by being off.
    expect(button(tester, 'Clean paste').onPressed, isNull);

    await tester.enterText(descriptionField(), '“Led”  the team');
    await tester.pumpAndSettle();
    expect(find.text(_warning), findsOneWidget);

    await tester.tap(find.text('Details'));
    await tester.pumpAndSettle();
    expect(find.text('• Double spaces'), findsOneWidget);
    expect(find.text('• Curly quotes'), findsOneWidget);

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    // Saved exactly as typed: warnings never rewrite.
    expect((await stored()).single.description, '“Led”  the team');
  });

  testWidgets('Clean paste rewrites the field; Cancel throws it away', (
    tester,
  ) async {
    const messy = JobExperienceSnippet(
      id: 'a',
      name: 'Acme',
      description: '•  “Led” the team – twice…  \n',
    );
    await seed(const [messy]);
    await openDialog(tester);
    await tester.tap(find.byTooltip('Edit experience'));
    await tester.pumpAndSettle();
    expect(find.text(_warning), findsOneWidget);

    await tester.tap(find.text('Clean paste'));
    await tester.pumpAndSettle();
    expect(descriptionText(tester), '- "Led" the team - twice...');
    expect(find.text(_warning), findsNothing);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(await stored(), const [messy]);
  });

  testWidgets('Clean paste then Save keeps the cleaned text', (tester) async {
    await seed(const [
      JobExperienceSnippet(id: 'a', name: 'Acme', description: 'a  b'),
    ]);
    await openDialog(tester);
    await tester.tap(find.text('Acme'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clean paste'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect((await stored()).single.description, 'a b');
  });

  testWidgets('delete asks first, and cancelling keeps the snippet', (
    tester,
  ) async {
    await seed(const [
      JobExperienceSnippet(id: 'a', name: 'Acme', description: 'A'),
      JobExperienceSnippet(id: 'b', name: 'Beta', description: 'B'),
    ]);
    await openDialog(tester);

    await tester.tap(find.byTooltip('Delete experience').first);
    await tester.pumpAndSettle();
    expect(find.text('Delete “Acme”?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect((await stored()).map((s) => s.id), ['a', 'b']);

    await tester.tap(find.byTooltip('Delete experience').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect((await stored()).map((s) => s.id), ['b']);
    expect(find.text('Acme'), findsNothing);
  });

  testWidgets('dragging a row persists the new order at once', (tester) async {
    await seed(const [
      JobExperienceSnippet(id: 'a', name: 'Acme', description: ''),
      JobExperienceSnippet(id: 'b', name: 'Beta', description: ''),
      JobExperienceSnippet(id: 'c', name: 'Gamma', description: ''),
      JobExperienceSnippet(id: 'd', name: 'Delta', description: ''),
    ]);
    await openDialog(tester);

    // The fourth row's handle, dragged above the first.
    final handle = find.byType(ReorderableDragStartListener).at(3);
    final rowGap =
        tester.getCenter(find.text('Delta')).dy -
        tester.getCenter(find.text('Acme')).dy;
    final gesture = await tester.startGesture(tester.getCenter(handle));
    await tester.pump(const Duration(milliseconds: 100));
    for (var i = 0; i < 10; i++) {
      await gesture.moveBy(Offset(0, -(rowGap + 20) / 10));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pumpAndSettle();

    expect((await stored()).map((s) => s.id), ['d', 'a', 'b', 'c']);
  });
}
