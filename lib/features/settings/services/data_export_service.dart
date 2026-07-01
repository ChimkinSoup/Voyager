import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:archive/archive.dart';
import 'package:path_provider/path_provider.dart';
import 'package:voyager/domain/repositories/repositories.dart';

class DataExportService {
  DataExportService(this._journalRepo, this._todoRepo);

  final JournalRepository _journalRepo;
  final TodoRepository _todoRepo;

  Future<File> exportDataToZip() async {
    // 1. Fetch data sequentially to avoid RAM spikes
    final journals = await _journalRepo.getAllEntries(includeDeleted: true);
    final tasks = await _todoRepo.getAllTasks(includeDeleted: true);

    // 2. Offload serialization and zipping to a background isolate
    final zipBytes = await compute(generateZipIsolate, {
      'journals': journals.map((j) => j.toJson()).toList(),
      'tasks': tasks.map((t) => t.toJson()).toList(),
    });

    // 3. Save to standard output directory (using path_provider)
    final outputDir = await getApplicationDocumentsDirectory();
    final exportFile = File(
      '${outputDir.path}/voyager_backup_${DateTime.now().millisecondsSinceEpoch}.zip',
    );
    return await exportFile.writeAsBytes(zipBytes);
  }
}

// Background Isolate Function (Must be top-level)
List<int> generateZipIsolate(Map<String, List<Map<String, dynamic>>> data) {
  final archive = Archive();

  // Create distinct files inside the ZIP
  final journalData = utf8.encode(jsonEncode(data['journals']));
  archive.addFile(ArchiveFile('journals.json', journalData.length, journalData));

  final taskData = utf8.encode(jsonEncode(data['tasks']));
  archive.addFile(ArchiveFile('tasks.json', taskData.length, taskData));

  // Encode the ZIP
  return ZipEncoder().encode(archive)!;
}
