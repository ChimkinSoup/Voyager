// Tab order through a solution's boxes: Space goes straight to Explanation
// even with the form scrolled under the pinned close button, and Tab inside
// Explanation goes nowhere — a stray press mid-write-up keeps the caret put.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/sync/remote_sync_service.dart';
import 'package:voyager/data/database/app_database.dart';
import 'package:voyager/domain/models/leetcode_models.dart';
import 'package:voyager/domain/repositories/repositories.dart';
import 'package:voyager/features/leetcode/leetcode_track_modal.dart';

class _NoopLeetCodeRepository implements LeetCodeRepository {
  @override
  Future<List<LeetCodeProblem>> listProblems({
    bool includeDeleted = false,
  }) async => const [];

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _NoopRemoteSync implements RemoteSyncService {
  @override
  noSuchMethod(Invocation invocation) => null;
}

const _spaceHint = 'O(1)';
const _explanationHint = 'Walk through the logic in plain language';

Finder _field(String hint) => find
    .descendant(
      of: find
          .ancestor(of: find.text(hint).first, matching: find.byType(TextField))
          .first,
      matching: find.byType(EditableText),
    )
    .first;

bool _hasFocus(WidgetTester tester, String hint) =>
    tester.widget<EditableText>(_field(hint)).focusNode.hasPrimaryFocus;

Future<void> _openModal(WidgetTester tester) async {
  // Short enough that the Space row can be scrolled up level with the pinned
  // close button — the position the stray Tab stop showed up in.
  tester.view.physicalSize = const Size(1280, 500);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final db = AppDatabase.inMemory();
  addTearDown(db.close);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        leetCodeRepositoryProvider.overrideWithValue(
          _NoopLeetCodeRepository(),
        ),
        remoteSyncServiceProvider.overrideWithValue(_NoopRemoteSync()),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) => TextButton(
              onPressed: () => showLeetCodeTrackModal(context, ref),
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

void main() {
  testWidgets(
    'Tab from Space lands on Explanation with the row under the close button',
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
    (tester) async {
      await _openModal(tester);
      Scrollable.ensureVisible(tester.element(_field(_spaceHint)));
      await tester.pumpAndSettle();
      // The precondition that made the close button the next stop.
      expect(
        tester.getRect(_field(_spaceHint)).top,
        lessThan(tester.getRect(find.byTooltip('Close')).bottom),
      );

      await tester.tap(_field(_spaceHint));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();

      expect(_hasFocus(tester, _explanationHint), isTrue);
    },
  );

  testWidgets(
    'Tab inside Explanation keeps focus and types nothing',
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
    (tester) async {
      await _openModal(tester);
      await tester.ensureVisible(_field(_explanationHint));
      await tester.pumpAndSettle();
      await tester.tap(_field(_explanationHint));
      await tester.enterText(_field(_explanationHint), 'two pointers');
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();

      expect(_hasFocus(tester, _explanationHint), isTrue);
      expect(
        tester.widget<EditableText>(_field(_explanationHint)).controller.text,
        'two pointers',
      );
    },
  );
}
