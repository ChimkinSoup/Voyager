import 'dart:async';

// ignore_for_file: prefer_initializing_formals

import 'package:flutter/foundation.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/repositories/repositories.dart';

enum SyncActivityDirection { localSave, upload, download }

class SyncActivityEvent {
  const SyncActivityEvent({
    required this.direction,
    required this.collection,
    required this.occurredAt,
    required this.sequence,
  });

  final SyncActivityDirection direction;
  final String collection;
  final DateTime occurredAt;
  final int sequence;
}

class _SyncActivitySlot {
  SyncActivityEvent? event;
  Timer? clearTimer;
  Timer? flickerTimer;
}

class SyncActivityController extends ChangeNotifier {
  SyncActivityController({SettingsRepository? settingsRepository})
    : _settingsRepository = settingsRepository;

  final SettingsRepository? _settingsRepository;

  static const _displayDuration = Duration(milliseconds: 900);
  static const _flickerGap = Duration(milliseconds: 80);

  bool showLocalSaves = false;
  bool showUploads = false;
  bool showDownloads = false;

  final _slots = {
    SyncActivityDirection.localSave: _SyncActivitySlot(),
    SyncActivityDirection.upload: _SyncActivitySlot(),
    SyncActivityDirection.download: _SyncActivitySlot(),
  };

  final _sequences = {
    SyncActivityDirection.localSave: 0,
    SyncActivityDirection.upload: 0,
    SyncActivityDirection.download: 0,
  };

  Future<void> loadFromSettings() async {
    final repo = _settingsRepository;
    if (repo == null) return;
    final settings = await repo.getSettings();
    applySettings(settings);
  }

  void applySettings(AppSettings settings) {
    final localSaves = settings.devShowSyncLocalSaves;
    final uploads = settings.devShowSyncUploads;
    final downloads = settings.devShowSyncDownloads;
    if (showLocalSaves == localSaves &&
        showUploads == uploads &&
        showDownloads == downloads) {
      return;
    }
    showLocalSaves = localSaves;
    showUploads = uploads;
    showDownloads = downloads;
    notifyListeners();
  }

  Future<void> setShowLocalSaves(bool value) async {
    if (showLocalSaves == value) return;
    showLocalSaves = value;
    notifyListeners();
    await _persist();
  }

  Future<void> setShowUploads(bool value) async {
    if (showUploads == value) return;
    showUploads = value;
    notifyListeners();
    await _persist();
  }

  Future<void> setShowDownloads(bool value) async {
    if (showDownloads == value) return;
    showDownloads = value;
    notifyListeners();
    await _persist();
  }

  SyncActivityEvent? eventFor(SyncActivityDirection direction) {
    return _slots[direction]?.event;
  }

  void recordLocalSave(String collection) {
    if (!showLocalSaves) return;
    _record(SyncActivityDirection.localSave, collection);
  }

  void recordUpload(String collection) {
    if (!showUploads) return;
    _record(SyncActivityDirection.upload, collection);
  }

  void recordDownloadCheck(String collection) {
    if (!showDownloads) return;
    _record(SyncActivityDirection.download, collection);
  }

  void _record(SyncActivityDirection direction, String collection) {
    final slot = _slots[direction]!;

    void showEvent() {
      slot.clearTimer?.cancel();
      final sequence = _sequences[direction]! + 1;
      _sequences[direction] = sequence;
      slot.event = SyncActivityEvent(
        direction: direction,
        collection: collection,
        occurredAt: DateTime.now(),
        sequence: sequence,
      );
      notifyListeners();

      slot.clearTimer = Timer(_displayDuration, () {
        if (slot.event == null) return;
        slot.event = null;
        notifyListeners();
      });
    }

    slot.flickerTimer?.cancel();
    if (slot.event != null) {
      slot.clearTimer?.cancel();
      slot.event = null;
      notifyListeners();
      slot.flickerTimer = Timer(_flickerGap, showEvent);
    } else {
      showEvent();
    }
  }

  Future<void> _persist() async {
    final repo = _settingsRepository;
    if (repo == null) return;
    final settings = await repo.getSettings();
    await repo.saveSettings(
      settings.copyWith(
        devShowSyncLocalSaves: showLocalSaves,
        devShowSyncUploads: showUploads,
        devShowSyncDownloads: showDownloads,
      ),
    );
  }

  @override
  void dispose() {
    for (final slot in _slots.values) {
      slot.clearTimer?.cancel();
      slot.flickerTimer?.cancel();
    }
    super.dispose();
  }
}
