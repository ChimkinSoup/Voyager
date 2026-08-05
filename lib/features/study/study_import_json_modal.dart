import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/domain/models/study_models.dart';

/// Bulk-adds cards to [deckId] from a JSON file: either a top-level array,
/// or `{"cards": [...]}`, of `{"front": "...", "back": "..."}` objects
/// (`frontText`/`backText` also accepted so a previously exported deck can
/// round-trip). Entries missing either side are skipped.
Future<void> showStudyImportJsonModal(
  BuildContext context,
  WidgetRef ref,
  String deckId,
) async {
  final result = await FilePicker.platform.pickFiles(
    type: FileType.custom,
    allowedExtensions: ['json'],
  );
  if (result == null || result.files.single.path == null) return;

  List<dynamic> raw;
  try {
    final content = await File(result.files.single.path!).readAsString();
    final decoded = jsonDecode(content);
    raw = decoded is List
        ? decoded
        : (decoded is Map ? (decoded['cards'] as List? ?? const []) : const []);
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not read JSON file: $e')));
    }
    return;
  }

  final now = utcNow();
  final repo = ref.read(studyRepositoryProvider);
  final remoteSync = ref.read(remoteSyncServiceProvider);
  var imported = 0;
  for (final entry in raw) {
    if (entry is! Map) continue;
    final front = (entry['front'] ?? entry['frontText'])?.toString().trim();
    final back = (entry['back'] ?? entry['backText'])?.toString().trim();
    if (front == null || front.isEmpty || back == null || back.isEmpty) continue;
    final card = StudyCard(
      id: newId(),
      createdAt: now,
      updatedAt: now,
      deckId: deckId,
      frontText: front,
      backText: back,
      dueAt: now,
    );
    await repo.upsertCard(card);
    remoteSync.pushStudyCard(card);
    imported++;
  }

  ref.invalidate(studyCardsProvider);
  ref.invalidate(studyDeckStatsProvider);
  ref.invalidate(studyStatsProvider);

  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Imported $imported card${imported == 1 ? '' : 's'}.')),
    );
  }
}
