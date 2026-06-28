import 'package:voyager/core/sync/text_delta_injector.dart';

/// Remote text payload held while a document is actively being edited.
class PendingTextMerge {
  const PendingTextMerge({
    required this.previousRemoteText,
    required this.remoteText,
    this.remoteRichBodyJson,
    this.remoteTags = const [],
  });

  final String previousRemoteText;
  final String remoteText;
  final String? remoteRichBodyJson;
  final List<String> remoteTags;

  PendingTextMerge advance(String nextRemoteText) {
    return PendingTextMerge(
      previousRemoteText: remoteText,
      remoteText: nextRemoteText,
      remoteRichBodyJson: remoteRichBodyJson,
      remoteTags: remoteTags,
    );
  }
}

class PendingTextMergeEvent {
  const PendingTextMergeEvent({
    required this.collection,
    required this.documentId,
    required this.previousRemoteText,
    required this.remoteText,
    this.remoteTags = const [],
  });

  final String collection;
  final String documentId;
  final String previousRemoteText;
  final String remoteText;
  final List<String> remoteTags;
}

typedef PendingTextMergeListener = void Function(PendingTextMergeEvent event);

/// In-memory buffer for remote text changes that arrive during active editing.
class PendingTextMergeBuffer {
  final Map<String, PendingTextMerge> _pending = {};
  final Map<String, String> _lastKnownRemoteText = {};
  final Map<String, List<PendingTextMergeListener>> _listeners = {};

  String documentKey(String collection, String documentId) =>
      '${collection}_$documentId';

  String? lastKnownRemoteText(String collection, String documentId) {
    return _lastKnownRemoteText[documentKey(collection, documentId)];
  }

  void recordRemoteText(String collection, String documentId, String text) {
    _lastKnownRemoteText[documentKey(collection, documentId)] = text;
  }

  void addListener(
    String collection,
    String documentId,
    PendingTextMergeListener listener,
  ) {
    final key = documentKey(collection, documentId);
    _listeners.putIfAbsent(key, () => []).add(listener);
  }

  void removeListener(
    String collection,
    String documentId,
    PendingTextMergeListener listener,
  ) {
    _listeners[documentKey(collection, documentId)]?.remove(listener);
  }

  bool hasPending(String collection, String documentId) {
    return _pending.containsKey(documentKey(collection, documentId));
  }

  /// Buffers [remoteText] while editing and notifies listeners for live delta
  /// injection into active text controllers.
  void bufferWhileEditing({
    required String collection,
    required String documentId,
    required String remoteText,
    String? remoteRichBodyJson,
    List<String> remoteTags = const [],
  }) {
    final key = documentKey(collection, documentId);
    final previous =
        _pending[key]?.remoteText ??
        _lastKnownRemoteText[key] ??
        remoteText;
    final next = PendingTextMerge(
      previousRemoteText: previous,
      remoteText: remoteText,
      remoteRichBodyJson: remoteRichBodyJson,
      remoteTags: remoteTags,
    );
    _pending[key] = next;
    _lastKnownRemoteText[key] = remoteText;

    if (previous == remoteText) return;
    final event = PendingTextMergeEvent(
      collection: collection,
      documentId: documentId,
      previousRemoteText: previous,
      remoteText: remoteText,
      remoteTags: remoteTags,
    );
    for (final listener in List<PendingTextMergeListener>.from(
      _listeners[key] ?? const [],
    )) {
      listener(event);
    }
  }

  PendingTextMerge? take(String collection, String documentId) {
    return _pending.remove(documentKey(collection, documentId));
  }

  void clearDocument(String collection, String documentId) {
    final key = documentKey(collection, documentId);
    _pending.remove(key);
    _lastKnownRemoteText.remove(key);
  }

  /// Merges buffered remote text into [currentLocalText] and clears the buffer.
  String? applyToLocalText({
    required String collection,
    required String documentId,
    required String currentLocalText,
  }) {
    final pending = take(collection, documentId);
    if (pending == null) return null;
    return TextDeltaInjector.injectRemoteDelta(
      localText: currentLocalText,
      oldRemoteText: pending.previousRemoteText,
      newRemoteText: pending.remoteText,
    );
  }
}
