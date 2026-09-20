// A dev toggle has to stick. It is written straight from the Dev page while
// every other settings menu in the app saves whole [AppSettings] objects built
// on the published copy — so if the write never reaches that copy, the next
// menu tap anywhere else resurrects the old flag. The FPS counter coming back
// after flipping the LeetCode scratch pad was exactly that.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/repositories/repositories.dart';

class _MemorySettingsRepository implements SettingsRepository {
  _MemorySettingsRepository(this.stored);

  AppSettings stored;

  @override
  Future<AppSettings> getSettings() async => stored;

  @override
  Future<void> saveSettings(
    AppSettings settings, {
    bool recordLocalActivity = true,
  }) async {
    stored = settings;
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
    'turning the FPS counter off survives another menu saving settings',
    () async {
      final repo = _MemorySettingsRepository(
        const AppSettings(devShowFpsCounter: true),
      );
      final container = ProviderContainer(
        overrides: [settingsRepositoryProvider.overrideWithValue(repo)],
      );
      addTearDown(container.dispose);

      await container.read(settingsProvider.future);
      // The controller reads the row itself on creation.
      container.read(devSettingsProvider);
      await Future<void>.delayed(Duration.zero);
      expect(container.read(devSettingsProvider).showFpsCounter, isTrue);

      await container.read(devSettingsProvider).setShowFpsCounter(false);

      // What the Study & Cram display menu does: a whole-object save built on
      // the settings the app is currently publishing.
      final live = container.read(settingsProvider).value!;
      await container
          .read(settingsProvider.notifier)
          .saveSettings(live.copyWith(leetCodeEnableScratchCode: true));

      expect(repo.stored.devShowFpsCounter, isFalse);
      expect(repo.stored.leetCodeEnableScratchCode, isTrue);
      expect(container.read(devSettingsProvider).showFpsCounter, isFalse);
    },
  );

  test('the sync activity toggles publish the same way', () async {
    final repo = _MemorySettingsRepository(
      const AppSettings(devShowSyncUploads: true),
    );
    final container = ProviderContainer(
      overrides: [settingsRepositoryProvider.overrideWithValue(repo)],
    );
    addTearDown(container.dispose);

    await container.read(settingsProvider.future);
    container.read(syncActivityProvider);
    await Future<void>.delayed(Duration.zero);

    await container.read(syncActivityProvider).setShowUploads(false);

    final live = container.read(settingsProvider).value!;
    await container
        .read(settingsProvider.notifier)
        .saveSettings(live.copyWith(leetCodeEnableScratchCode: true));

    expect(repo.stored.devShowSyncUploads, isFalse);
    expect(container.read(syncActivityProvider).showUploads, isFalse);
  });
}
