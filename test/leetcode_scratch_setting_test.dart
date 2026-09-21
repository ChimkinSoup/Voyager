// The scratch pad is off unless the user asks for it, and the answer follows
// the account rather than the machine — so the flag has to survive the settings
// round trip in both directions.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/sync/firestore_document_mapper.dart';
import 'package:voyager/domain/models/leetcode_models.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/repositories/repositories.dart';
import 'package:voyager/features/leetcode/leetcode_review_deck.dart';

class _RecordingSettings extends SettingsNotifier {
  static final saved = <AppSettings>[];

  @override
  Future<AppSettings> build() async => const AppSettings();

  @override
  Future<void> saveSettings(AppSettings settings) async {
    saved.add(settings);
    state = AsyncData(settings);
  }
}

class _EmptyLeetCodeRepository implements LeetCodeRepository {
  @override
  Future<List<LeetCodeProblem>> listProblems({
    bool includeDeleted = false,
  }) async => const [];

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  setUp(_RecordingSettings.saved.clear);

  test('a new account has no scratch pad', () {
    expect(const AppSettings().leetCodeEnableScratchCode, isFalse);
  });

  test('the flag survives the Firestore round trip', () {
    final local = AppSettings(updatedAt: DateTime.utc(2026, 8, 30));
    for (final value in [true, false]) {
      final remote = settingsToFirestore(
        local.copyWith(
          leetCodeEnableScratchCode: value,
          updatedAt: DateTime.utc(2026, 8, 31),
        ),
      );
      expect(remote['leetCodeEnableScratchCode'], value);
      expect(
        mergeSettingsFromRemote(
          Map<String, dynamic>.from(remote),
          local,
        ).leetCodeEnableScratchCode,
        value,
      );
    }
  });

  test('a document from a build that predates the flag reads as off', () {
    // Older devices simply never wrote the key; the absent value must not
    // arrive as a surprise pad on the next sync.
    final local = AppSettings(updatedAt: DateTime.utc(2026, 8, 30));
    final merged = mergeSettingsFromRemote({
      'settingsUpdatedAt': DateTime.utc(2026, 8, 31).toIso8601String(),
    }, local);
    expect(merged.leetCodeEnableScratchCode, isFalse);
  });

  testWidgets('the Study & Cram menu turns it on', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsProvider.overrideWith(_RecordingSettings.new),
          leetCodeRepositoryProvider.overrideWithValue(
            _EmptyLeetCodeRepository(),
          ),
        ],
        child: const MaterialApp(home: Scaffold(body: LeetCodeReviewDeck())),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(PhosphorIconsRegular.gear));
    await tester.pumpAndSettle();

    // It sits in the same menu as the hides, below the rule that separates
    // "add a surface" from "blank one".
    expect(find.text('Enable scratch code'), findsOneWidget);
    await tester.tap(find.text('Enable scratch code'));
    await tester.pumpAndSettle();

    expect(_RecordingSettings.saved.last.leetCodeEnableScratchCode, isTrue);
    // Turning the pad on hides nothing.
    expect(_RecordingSettings.saved.last.leetCodeHideCode, isFalse);
  });
}
