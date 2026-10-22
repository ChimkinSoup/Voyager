import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:win32/win32.dart';

/// The sounds the app plays, each `assets/sounds/<file>.wav`.
enum AppSound {
  taskComplete('Task completed', _ding),
  saved('Saved from a floater or its form', _ding),
  money('Finance entry logged', _ding),
  calendarDone('Calendar event done', _ding),
  restTimerEnd('Rest timer ended', 'rest_timer_end'),
  workoutFinished('Workout finished', 'workout_finished'),
  studyDeckFinished('Study deck finished', 'study_deck_finished'),
  bucketListDone('Bucket list item done', 'bucket_list_done'),
  leetCodeSaved('LeetCode problem saved', _ding),
  rankingSaved('Ranking edited', _ding),
  jobTracked('Job tracked', _ding),
  photoCheckIn('Photo series check-in', _ding);

  const AppSound(this.label, this.file);

  final String label;
  final String file;

  String get asset => 'sounds/$file.wav';
}

/// The one completion sound most events share.
const _ding = 'completion_ding';

/// Plays [AppSound]s. Best effort: a sound that fails to play is logged and
/// otherwise ignored.
///
/// Known and left alone: on Bluetooth output (earbuds, headsets) a sound can
/// lose its first 100–300 ms. The link sleeps after a few seconds of silence
/// and drops whatever plays while it wakes, so the completion ding's opening
/// "da" goes missing after a pause, while a second sound soon after plays in
/// full. Neither the files nor this class cause it: every sound starts at its
/// first sample, and speakers play it whole. The fixes were judged worse than
/// the clipping: holding the link awake with an inaudible stream keeps the
/// earbuds active and Voyager in the volume mixer, and padding each file with
/// silence delays every sound behind the click that set it off.
class AppSounds {
  AppSounds(this._enabled);

  /// The settings' master Sounds switch, read at each play.
  final bool Function() _enabled;

  final _players = <String, AudioPlayer>{};
  final _loaded = <String, Future<void>>{};

  /// Each asset's WAV bytes in native memory, for [PlaySound], which reads
  /// them while it plays. Kept for the life of the app.
  final _wavs = <String, Future<Pointer<Uint8>>>{};

  /// Plays [sound] without waiting for it.
  void play(AppSound sound) {
    if (!_enabled()) return;
    unawaited(_play(sound.asset));
  }

  Future<void> _play(String asset) async {
    // The plugin has no implementation under `flutter test`, and the player
    // reports that as an unhandled error the moment it is constructed.
    if (Platform.environment.containsKey('FLUTTER_TEST')) return;
    try {
      if (Platform.isWindows) return await _playOnWindows(asset);
      final player = _players[asset] ??= AudioPlayer();
      // Loaded once and kept: ReleaseMode.stop holds the source after each
      // play, so later plays skip copying the asset out of the bundle.
      await _once(_loaded, asset, () async {
        await player.setReleaseMode(ReleaseMode.stop);
        await player.setSourceAsset(asset);
      });
      // Restarts the sound when it is set off faster than it rings.
      await player.stop();
      await player.resume();
    } catch (e) {
      debugPrint('Sound $asset failed: $e');
    }
  }

  /// On Windows the player's stop seeks back to the start asynchronously, so
  /// the resume after it could play from the old position or jump partway
  /// through: a sound heard only in part. PlaySound plays the whole clip from
  /// memory, with less start-up delay, and a new sound replaces the last.
  Future<void> _playOnWindows(String asset) async {
    final wav = await _once(_wavs, asset, () async {
      final data = await rootBundle.load('assets/$asset');
      final wav = calloc<Uint8>(data.lengthInBytes);
      wav
          .asTypedList(data.lengthInBytes)
          .setAll(0, data.buffer.asUint8List(data.offsetInBytes));
      return wav;
    });
    if (PlaySound(wav.cast(), NULL, SND_MEMORY | SND_ASYNC | SND_NODEFAULT) ==
        FALSE) {
      throw StateError('PlaySound refused the clip');
    }
  }

  /// [load] run once per [key] and its result kept in [cache] — unless it
  /// fails, so the next play tries again rather than repeating the failure.
  Future<T> _once<T>(
    Map<String, Future<T>> cache,
    String key,
    Future<T> Function() load,
  ) {
    final cached = cache[key];
    if (cached != null) return cached;
    final loading = load();
    cache[key] = loading;
    return loading.catchError((Object error, StackTrace stack) {
      if (identical(cache[key], loading)) cache.remove(key);
      Error.throwWithStackTrace(error, stack);
    });
  }

  void dispose() {
    for (final player in _players.values) {
      unawaited(player.dispose());
    }
    if (_wavs.isEmpty) return;
    // Stopped before the memory it may be reading goes.
    PlaySound(nullptr, NULL, 0);
    for (final wav in _wavs.values) {
      unawaited(wav.then(calloc.free));
    }
  }
}

final appSoundsProvider = Provider<AppSounds>((ref) {
  final sounds = AppSounds(
    () => ref.read(settingsProvider).valueOrNull?.soundsEnabled ?? true,
  );
  ref.onDispose(sounds.dispose);
  return sounds;
});

/// Plays [AppSound.taskComplete] unless it is turned off in settings.
void playTaskCompleteSound(BuildContext context) {
  final container = ProviderScope.containerOf(context, listen: false);
  final settings = container.read(settingsProvider).valueOrNull;
  if (!(settings?.taskCompleteSoundEnabled ?? true)) return;
  container.read(appSoundsProvider).play(AppSound.taskComplete);
}
