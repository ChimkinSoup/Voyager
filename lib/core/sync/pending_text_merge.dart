import 'package:flutter/services.dart' show TextEditingValue, TextSelection;
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
    this.mapOffset,
    this.alreadySaved = false,
  });

  final String collection;
  final String documentId;
  final String previousRemoteText;
  final String remoteText;
  final List<String> remoteTags;

  /// Where an offset into [previousRemoteText] lands in [remoteText], by the
  /// character it sat after rather than by the change in length — so a remote
  /// insert after the caret leaves the caret where it was. Null when the
  /// change did not come from the document's character session.
  final int Function(int offset)? mapOffset;

  /// Whether the row already holds [remoteText], so the editor need not save
  /// it. Saving anyway would also write the page's copy of the other fields,
  /// which can be older than the row.
  final bool alreadySaved;

  /// [current] with this change merged in, or null when the change could not
  /// be placed in it. [current] itself when it already holds the change —
  /// merged, as far as the buffer is concerned, so the final flush does not
  /// diff it in a second time.
  ///
  /// The selection follows the characters it sat after when the editor still
  /// shows exactly [previousRemoteText]; otherwise the change was merged as a
  /// text diff, and the caret only shifts by the change in length.
  TextEditingValue? mergedInto(TextEditingValue current) {
    final before = current.text;
    if (before == remoteText) return current;
    final merged = TextDeltaInjector.injectRemoteDelta(
      localText: before,
      oldRemoteText: previousRemoteText,
      newRemoteText: remoteText,
    );
    if (merged == before) return null;

    final map = mapOffset;
    final selection = current.selection;
    if (map != null && before == previousRemoteText && selection.isValid) {
      return TextEditingValue(
        text: merged,
        selection: TextSelection(
          baseOffset: map(selection.baseOffset),
          extentOffset: map(selection.extentOffset),
        ),
      );
    }
    return TextEditingValue(
      text: merged,
      selection: TextSelection.collapsed(
        offset: TextDeltaInjector.adjustedSelection(
          selection: selection.baseOffset,
          before: before,
          after: merged,
        ),
      ),
    );
  }
}

/// Returns whether the listener put the change into its editor. An applied
/// change is dropped from the buffer: applying it again on the final flush
/// would insert it a second time.
typedef PendingTextMergeListener = bool Function(PendingTextMergeEvent event);

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
  ///
  /// [previousRemoteText] is the text the change applies to. Given, it is the
  /// document's character session just before the remote characters were
  /// folded in — what the editor is showing. Left out, the last remote text
  /// this buffer saw stands in, which goes stale whenever our own write comes
  /// back looking like someone else's and re-inserts text the editor holds.
  void bufferWhileEditing({
    required String collection,
    required String documentId,
    required String remoteText,
    String? previousRemoteText,
    String? remoteRichBodyJson,
    List<String> remoteTags = const [],
    int Function(int offset)? mapOffset,
  }) {
    final key = documentKey(collection, documentId);
    final previous =
        previousRemoteText ??
        _pending[key]?.remoteText ??
        _lastKnownRemoteText[key] ??
        remoteText;
    // A change still waiting for the editor is folded into this one, so the
    // final flush applies both rather than only the latest.
    final waiting = _pending[key];
    final next = PendingTextMerge(
      previousRemoteText: waiting != null && waiting.remoteText == previous
          ? waiting.previousRemoteText
          : previous,
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
      mapOffset: mapOffset,
    );
    if (_notify(key, event)) _pending.remove(key);
  }

  /// Shows a remote change in an open editor of a document nobody is editing.
  /// The pull has stored it already, so nothing is buffered for a flush.
  void showRemoteChange({
    required String collection,
    required String documentId,
    required String previousRemoteText,
    required String remoteText,
    int Function(int offset)? mapOffset,
  }) {
    if (previousRemoteText == remoteText) return;
    _notify(
      documentKey(collection, documentId),
      PendingTextMergeEvent(
        collection: collection,
        documentId: documentId,
        previousRemoteText: previousRemoteText,
        remoteText: remoteText,
        mapOffset: mapOffset,
        alreadySaved: true,
      ),
    );
  }

  /// Whether any listener put [event] into its editor.
  bool _notify(String key, PendingTextMergeEvent event) {
    var applied = false;
    for (final listener in List<PendingTextMergeListener>.from(
      _listeners[key] ?? const [],
    )) {
      if (listener(event)) applied = true;
    }
    return applied;
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
