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
      // The search page doesn't maintain a CRDT editing session, so the
      // debounced upload scheduled above would push empty char-ops — creating
      // a gap in the CRDT history that causes corrupted-op-chain conflicts on
      // next pull.  Cancel that upload and replace it with a full-text CRDT
      // overwrite that wipes stale ops and re-seeds from the current body.
      if (result != null) {
        remoteSync.cancelDocument(
          FirestoreCollections.journalEntries,
          baseline.id,
        );
        await remoteSync.forceOverwriteJournalEntryText(result!);
      }
      return result;
    } catch (error, stackTrace) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'SearchEntrySaveHelper',
          context: ErrorDescription('while saving entry from Search'),
        ),
      );
      return null;
    }
  }
}
