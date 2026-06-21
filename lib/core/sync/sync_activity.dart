import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:voyager/domain/models/settings_models.dart';
import 'package:voyager/domain/repositories/repositories.dart';

enum SyncActivityDirection { upload, download }

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

class SyncActivityController extends ChangeNotifier {
  SyncActivityController({SettingsRepository? settingsRepository})
    : _settingsRepository = settingsRepository;

  final SettingsRepository? _settingsRepository;

  bool showUploads = false;
  bool showDownloads = false;

  Future<void> loadFromSettings() async {
    final repo = _settingsRepository;
    if (repo == null) return;
    final settings = await repo.getSettings();
    applySettings(settings);
  }

  void applySettings(AppSettings settings) {
    final uploads = settings.devShowSyncUploads;
    final downloads = settings.devShowSyncDownloads;
    if (showUploads == uploads && showDownloads == downloads) return;
    showUploads = uploads;
    showDownloads = downloads;
    notifyListeners();
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

  void recordUpload(String collection) {
    if (!showUploads) return;
    _record(SyncActivityDirection.upload, collection);
  }

  void recordDownloadCheck(String collection) {
    if (!showDownloads) return;
    _record(SyncActivityDirection.download, collection);
  }

  void _record(SyncActivityDirection direction, String collection) {
    _clearTimer?.cancel();
    latest = SyncActivityEvent(
      direction: direction,
      collection: collection,
      occurredAt: DateTime.now(),
      sequence: ++_sequence,
    );
    notifyListeners();

    _clearTimer = Timer(const Duration(milliseconds: 900), () {
      latest = null;
      notifyListeners();
    });
  }

  Future<void> _persist() async {
    final repo = _settingsRepository;
    if (repo == null) return;
    final settings = await repo.getSettings();
    await repo.saveSettings(
      settings.copyWith(
        devShowSyncUploads: showUploads,
        devShowSyncDownloads: showDownloads,
      ),
    );
  }

  SyncActivityEvent? latest;
  Timer? _clearTimer;
  int _sequence = 0;

  @override
  void dispose() {
    _clearTimer?.cancel();
    super.dispose();
  }
}
