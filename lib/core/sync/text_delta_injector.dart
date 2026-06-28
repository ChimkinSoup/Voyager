/// Applies a remote text change into local editor text while the user is typing.
///
/// Given the remote text before and after a sync pull, injects only the remote
/// delta into [localText] so uncommitted local edits are preserved.
class TextDeltaInjector {
  const TextDeltaInjector._();

  static String injectRemoteDelta({
    required String localText,
    required String oldRemoteText,
    required String newRemoteText,
  }) {
    if (oldRemoteText == newRemoteText) return localText;
    if (localText == oldRemoteText) return newRemoteText;

    final prefixLen = _commonPrefixLength(oldRemoteText, newRemoteText);
    final suffixLen = _commonSuffixLength(
      oldRemoteText,
      newRemoteText,
      prefixLen,
    );

    final oldMiddle = oldRemoteText.substring(
      prefixLen,
      oldRemoteText.length - suffixLen,
    );
    final newMiddle = newRemoteText.substring(
      prefixLen,
      newRemoteText.length - suffixLen,
    );

    if (oldMiddle.isEmpty) {
      return _insertAt(localText, prefixLen, newMiddle);
    }

    final localPrefix = localText.length >= prefixLen
        ? localText.substring(0, prefixLen)
        : localText;
    if (localPrefix != oldRemoteText.substring(0, prefixLen)) {
      return _fallbackMerge(localText, oldRemoteText, newRemoteText);
    }

    final localSuffixStart = localText.length - suffixLen;
    if (suffixLen > 0 &&
        (localSuffixStart < prefixLen ||
            localText.substring(localSuffixStart) !=
                oldRemoteText.substring(oldRemoteText.length - suffixLen))) {
      return _fallbackMerge(localText, oldRemoteText, newRemoteText);
    }

    final localMiddleEnd = localText.length - suffixLen;
    final localMiddle = localText.substring(prefixLen, localMiddleEnd);

    if (localMiddle == oldMiddle) {
      return localText.replaceRange(prefixLen, localMiddleEnd, newMiddle);
    }

    final matchIndex = localMiddle.indexOf(oldMiddle);
    if (matchIndex >= 0) {
      final start = prefixLen + matchIndex;
      return localText.replaceRange(start, start + oldMiddle.length, newMiddle);
    }

    return _fallbackMerge(localText, oldRemoteText, newRemoteText);
  }

  static int adjustedSelection({
    required int selection,
    required String before,
    required String after,
  }) {
    if (before == after) return selection;
    final delta = after.length - before.length;
    return (selection + delta).clamp(0, after.length);
  }

  static int _commonPrefixLength(String a, String b) {
    final max = a.length < b.length ? a.length : b.length;
    var i = 0;
    while (i < max && a.codeUnitAt(i) == b.codeUnitAt(i)) {
      i++;
    }
    return i;
  }

  static int _commonSuffixLength(String a, String b, int prefixLen) {
    var i = 0;
    while (i < a.length - prefixLen &&
        i < b.length - prefixLen &&
        a.codeUnitAt(a.length - 1 - i) == b.codeUnitAt(b.length - 1 - i)) {
      i++;
    }
    return i;
  }

  static String _insertAt(String text, int index, String insert) {
    if (insert.isEmpty) return text;
    final clamped = index.clamp(0, text.length);
    if (clamped == text.length) return '$text$insert';
    if (clamped == 0) return '$insert$text';
    return text.replaceRange(clamped, clamped, insert);
  }

  static String _fallbackMerge(
    String localText,
    String oldRemoteText,
    String newRemoteText,
  ) {
    if (localText.contains(oldRemoteText)) {
      return localText.replaceFirst(oldRemoteText, newRemoteText);
    }
    if (localText.endsWith(oldRemoteText)) {
      return localText.substring(0, localText.length - oldRemoteText.length) +
          newRemoteText;
    }
    return '$localText\n$newRemoteText';
  }
}
