import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/sync/journal_write_coordinator.dart';
import 'package:voyager/core/sync/pending_flush_registry.dart';
import 'package:voyager/core/utils/journal_tags.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/sync/remote_sync_service.dart';
import 'package:voyager/domain/repositories/repositories.dart';
import 'package:voyager/domain/models/journal_models.dart';

/// Search entry editor using the same debounced save pipeline as [JournalPage].
class SearchEntrySaveHelper {
  SearchEntrySaveHelper({
    required this.coordinator,
    required this.remoteSync,
    required this.journalRepository,
  });

  final JournalWriteCoordinator coordinator;
  final RemoteSyncService remoteSync;
  final JournalRepository journalRepository;

  Future<JournalEntry?> saveEntry({
    required JournalEntry baseline,
    required String title,
    required String body,
    required int? mood,
    required String? weatherIcon,
    required String journalId,
    DateTime? entryDate,
  }) async {
    try {
      JournalEntry? result;
      await coordinator.saveEntry(
        entryId: baseline.id,
        bumpVersion: true,
        applyDelta: (base) {
          return base.copyWith(
            title: title,
            body: body,
            tags: extractTags(body),
            mood: mood,
            weatherIcon: weatherIcon,
            journalId: journalId,
            entryDate: entryDate ?? base.entryDate,
            bumpVersion: false,
          );
        },
        onSuccess: (saved) {
          result = saved;
        },
      );
      return result;
    } catch (e, st) {
      debugPrint('Error saving entry in SearchEntrySaveHelper: $e\n$st');
      return null;
    }
  }
}
