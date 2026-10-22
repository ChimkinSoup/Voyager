import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/sound/app_sounds.dart';
import 'package:voyager/core/widgets/voyager_checkbox.dart';
import 'package:voyager/domain/models/settings_models.dart';

class _CountingSound implements AppSounds {
  int plays = 0;

  @override
  void play(AppSound sound) {
    if (sound == AppSound.taskComplete) plays++;
  }

  @override
  void dispose() {}
}

class _Settings extends SettingsNotifier {
  _Settings(this.soundEnabled);

  final bool soundEnabled;

  @override
  Future<AppSettings> build() async =>
      AppSettings(taskCompleteSoundEnabled: soundEnabled);
}

Future<_CountingSound> _tapCheckbox(
  WidgetTester tester, {
  required bool soundEnabled,
  bool celebrateOnComplete = true,
}) async {
  final sound = _CountingSound();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        settingsProvider.overrideWith(() => _Settings(soundEnabled)),
        appSoundsProvider.overrideWithValue(sound),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Center(
            child: VoyagerCheckbox(
              value: false,
              celebrateOnComplete: celebrateOnComplete,
              onChanged: (_) {},
            ),
          ),
        ),
      ),
    ),
  );
  // Loaded up front, as the app's theme loads it at startup.
  await ProviderScope.containerOf(
    tester.element(find.byType(VoyagerCheckbox)),
  ).read(settingsProvider.future);
  await tester.tap(find.byType(VoyagerCheckbox));
  // Let the confetti burst run out.
  await tester.pump(const Duration(seconds: 5));
  return sound;
}

void main() {
  testWidgets('completing a task plays the chime', (tester) async {
    final sound = await _tapCheckbox(tester, soundEnabled: true);
    expect(sound.plays, 1);
  });

  testWidgets('the setting turns the chime off', (tester) async {
    final sound = await _tapCheckbox(tester, soundEnabled: false);
    expect(sound.plays, 0);
  });

  testWidgets('a checkbox that does not celebrate stays silent', (
    tester,
  ) async {
    final sound = await _tapCheckbox(
      tester,
      soundEnabled: true,
      celebrateOnComplete: false,
    );
    expect(sound.plays, 0);
  });
}
