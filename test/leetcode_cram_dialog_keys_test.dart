// The LeetCode cram's arrow keys stay out of a dialog open over the run. The
// delete confirm opens on the root navigator, which leaves the cram's route —
// on a shell branch's navigator — current behind it, so ← / → used to pass or
// fail the problem hidden under the dialog (the Study half is BUG-194).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/session_resume/session_checkpoint_store.dart';
import 'package:voyager/core/sync/remote_sync_service.dart';
import 'package:voyager/core/widgets/confirm_dialog.dart';
import 'package:voyager/domain/models/enums.dart';
import 'package:voyager/domain/models/leetcode_models.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/repositories/repositories.dart';
import 'package:voyager/features/leetcode/leetcode_cram_page.dart';

import 'fakes/input_order_random.dart';

class _StubLeetCodeRepository implements LeetCodeRepository {
  _StubLeetCodeRepository(this.problems);

  final List<LeetCodeProblem> problems;

  @override
  Future<List<LeetCodeProblem>> listProblems({
    bool includeDeleted = false,
  }) async => problems;

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _NoopRemoteSync implements RemoteSyncService {
  @override
  noSuchMethod(Invocation invocation) => null;
}

class _FixedSettings extends SettingsNotifier {
  @override
  Future<AppSettings> build() async => const AppSettings();
}

List<LeetCodeProblem> _problems() {
  final now = DateTime.utc(2026, 8, 9, 12);
  return [
    for (final (id, title) in [('1', 'Two Sum'), ('2', 'Add Two Numbers')])
      LeetCodeProblem(
        id: id,
        createdAt: now,
        updatedAt: now,
        title: title,
        questionFrontendId: id,
        difficulty: LeetCodeDifficulty.medium,
        solutions: const [LeetCodeSolution(algorithm: 'An approach')],
        solvedAt: now,
      ),
  ];
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

void main() {
  testWidgets('arrows with a dialog over the run do not decide the problem '
      'behind it', (tester) async {
    tester.view.physicalSize = const Size(1600, 1100);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          leetCodeRepositoryProvider.overrideWithValue(
            _StubLeetCodeRepository(_problems()),
          ),
          remoteSyncServiceProvider.overrideWithValue(_NoopRemoteSync()),
          sessionCheckpointStoreProvider.overrideWithValue(
            MemorySessionCheckpointStore(),
          ),
          settingsProvider.overrideWith(_FixedSettings.new),
          noSessionShuffle,
        ],
        // A navigator of its own under the root one, as the shell's branches
        // have, so the dialog lands on the root navigator above it.
        child: MaterialApp(
          home: Navigator(
            onGenerateRoute: (_) => MaterialPageRoute<void>(
              builder: (_) => const LeetCodeCramPage(problemIds: {'1', '2'}),
            ),
          ),
        ),
      ),
    );
    await _settle(tester);
    expect(find.text('1 Two Sum'), findsWidgets);

    // The same dialog the problem menu's Delete raises.
    unawaited(
      showConfirmDialog(
        tester.element(find.byType(LeetCodeCramPage)),
        title: 'Delete "Two Sum"?',
        message: 'Moved to trash.',
      ),
    );
    await _settle(tester);
    expect(find.text('Delete "Two Sum"?'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await _settle(tester);
    await tester.tap(find.text('Cancel'));
    await _settle(tester);

    expect(find.text('Delete "Two Sum"?'), findsNothing);
    expect(find.text('1 Two Sum'), findsWidgets);
    expect(find.text('2 Add Two Numbers'), findsNothing);
  });
}
