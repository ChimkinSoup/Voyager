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

  /// Writes that happened before the sync layer registered itself.
  final _buffered = <({String collection, List<Object> records})>[];

  /// Ceiling on [_buffered]. Only reached if a listener is never registered at
  /// all — in tests, and in any build where syncing is off — where the entries
  /// are never going anywhere and holding more of them helps nobody.
  static const _maxBuffered = 500;

  /// Registered by the sync layer once it is built. Replays anything that was
  /// written in the meantime.
  set onWrite(void Function(String collection, List<Object> records)? handler) {
    _onWrite = handler;
    if (handler == null || _buffered.isEmpty) return;
    final replay = List.of(_buffered);
    _buffered.clear();
    for (final entry in replay) {
      handler(entry.collection, entry.records);
    }
  }

  void notify(String collection, List<Object> records) {
    if (records.isEmpty) return;
    final handler = _onWrite;
    if (handler == null) {
      if (_buffered.length >= _maxBuffered) _buffered.removeAt(0);
      _buffered.add((collection: collection, records: records));
      return;
    }
    handler(collection, records);
  }

  void notifyOne(String collection, Object record) {
    notify(collection, [record]);
  }
}
