import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/core/session_resume/session_checkpoint_store.dart';

/// Keeps a session page's checkpoint slots in memory.
///
/// Sessions wait for their slot to be read before they build a queue, and the
/// file-backed store the app ships cannot answer in a widget test — there is
/// no documents directory behind it. Any test that opens Study or Cram needs
/// this, the same way it needs a repository.
Override memorySessionCheckpoints([MemorySessionCheckpointStore? store]) =>
    sessionCheckpointStoreProvider.overrideWithValue(
      store ?? MemorySessionCheckpointStore(),
    );
