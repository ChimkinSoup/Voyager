// A title changed on another device was reverted everywhere when this device
// saved its body while typing: the page doesn't show a remote change while the
// body has focus, and every body save wrote the Title field's stale copy back
// (BUG-240). A save now writes only the fields changed here.

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/widgets/labeled_text_field.dart';
import 'package:voyager/core/widgets/tag_highlighted_text_field.dart';
import 'package:voyager/data/repositories/drift_repositories.dart';

import 'support/journal_page_harness.dart';

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  testWidgets('typing in the body keeps a title another device just changed', (
    tester,
  ) async {
    final db = await pumpJournalPage(tester);
    final repo = DriftJournalRepository(db);
    final body = find.byType(TagHighlightedTextField);

    await tester.tap(body);
    await tester.enterText(body, 'B body one');
    await _settle(tester);

    // Another device retitles the entry; the pull writes the row.
    final row = (await repo.getEntry('harness-entry'))!;
    await repo.upsertEntry(row.copyWith(title: 'Seeded entry T2'));

    await tester.enterText(body, 'B body one two');
    await _settle(tester);

    final stored = (await repo.getEntry('harness-entry'))!;
    expect(stored.body, 'B body one two');
    expect(stored.title, 'Seeded entry T2');
    // And the field follows, so the next save doesn't read it as an edit.
    final title = tester.widget<LabeledTextField>(
      find.byType(LabeledTextField).first,
    );
    expect(title.controller.text, 'Seeded entry T2');

    await tester.enterText(body, 'B body one two three');
    await _settle(tester);
    expect((await repo.getEntry('harness-entry'))!.title, 'Seeded entry T2');

    await disposeJournalPage(tester);
  });

  testWidgets('a title edited here is still saved', (tester) async {
    final db = await pumpJournalPage(tester);
    final repo = DriftJournalRepository(db);

    await tester.enterText(find.byType(LabeledTextField).first, 'Mine');
    await _settle(tester);
    await tester.enterText(find.byType(TagHighlightedTextField), 'text');
    await _settle(tester);

    expect((await repo.getEntry('harness-entry'))!.title, 'Mine');
    await disposeJournalPage(tester);
  });
}
