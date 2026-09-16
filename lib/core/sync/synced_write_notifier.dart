/// Tells the sync layer that records changed locally and need uploading.
///
/// The collections wired through this — calendars, trackers, finance, the
/// notification inbox, the bucket list, tag colors, custom words and settings —
/// deliberately don't follow the older convention of calling `remoteSync.pushX`
/// from the widget that made the edit. They are written from ~45 call sites
/// across the feature code, and a push call missing from any one of them is an
/// edit that silently never leaves the device. Firing from the repository
/// instead means every write reaches the sync layer, including ones added
/// later.
///
/// A repository can't simply hold the `RemoteSyncService`, because the service
/// is built *from* the repositories — Riverpod rejects that as a dependency
/// cycle. So the service registers itself here once it exists, and until it
/// does, writes are held rather than dropped: an edit made in the first second
/// after launch still uploads.
///
/// Records travel as `Object` because one notifier serves every collection;
/// the sync layer switches on the collection name to pick the mapper, exactly
/// as it already does for the collections that push explicitly.
///
/// Writes made while applying a pull pass `recordLocalActivity: false` and
/// never reach here, so a download can't bounce straight back up as an upload.
class SyncedWriteNotifier {
  void Function(String collection, List<Object> records)? _onWrite;

  /// Writes that happened before the sync layer registered itself — or while
  /// it is being rebuilt — grouped by collection in arrival order.
  ///
  /// Never trimmed. It used to drop the oldest entries past 500, and each
  /// dropped entry was a row written locally whose upload nothing would ever
  /// retry: a large import landing during a rebuild lost uploads silently.
  /// Grouping by collection keeps it to one entry per collection however many
  /// writes arrive.
  final _buffered = <String, List<Object>>{};

  /// Registered by the sync layer once it is built. Replays anything that was
  /// written in the meantime.
  set onWrite(void Function(String collection, List<Object> records)? handler) {
    _onWrite = handler;
    if (handler == null || _buffered.isEmpty) return;
    final replay = Map.of(_buffered);
    _buffered.clear();
    for (final entry in replay.entries) {
      handler(entry.key, entry.value);
    }
  }

  void notify(String collection, List<Object> records) {
    if (records.isEmpty) return;
    final handler = _onWrite;
    if (handler == null) {
      (_buffered[collection] ??= []).addAll(records);
      return;
    }
    handler(collection, records);
  }

  void notifyOne(String collection, Object record) {
    notify(collection, [record]);
  }
}
