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
import 'package:voyager/domain/models/journal_models.dart';

/// Search entry editor using the same debounced save pipeline as [JournalPage].
class SearchEntrySaveHelper {
  SearchEntrySaveHelper({
    required this.coordinator,
    required this.remoteSync,
  });

  final JournalWriteCoordinator coordinator;
  final RemoteSyncService remoteSync;

  Future<JournalEntry?> saveEntry({
    required JournalEntry baseline,
    required String title,
    required String body,
    required int? mood,
    required String? weatherIcon,
    required String journalId,
    DateTime? entryDate,
  }) async {
    JournalEntry? saved;
    await coordinator.saveEntry(
      entryId: baseline.id,
      bumpVersion: true,
      applyDelta: (stored) {
        final updated = stored.copyWith(
          title: title,
          body: body,
          tags: extractTags(body),
          mood: mood,
          weatherIcon: weatherIcon,
          journalId: journalId,
          entryDate: entryDate,
          bumpVersion: false,
        );
        saved = updated;
        return updated;
      },
      onSuccess: (updated) => saved = updated,
    );
    await remoteSync.flushDocument(
      FirestoreCollections.journalEntries,
      baseline.id,
    );
    return saved;
  }
}
