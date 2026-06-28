/// Lexicographic fractional indexing for CRDT character positions.
class FractionalIndex {
  FractionalIndex._();

  static const _digits =
      '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz';

  /// First key in an empty document.
  static String first() => 'a0';

  /// Key strictly after [key].
  static String after(String key) => between(before: key);

  /// Key strictly before [key].
  static String before(String key) => between(after: key);

  /// Key strictly between [before] and [after] (either may be null).
  static String between({String? before, String? after}) {
    if (before == null && after == null) return first();
    if (before == null) return _keyBefore(after!);
    if (after == null) return _keyAfter(before);
    if (before.compareTo(after) >= 0) {
      throw ArgumentError('before must be < after');
    }
    return _midpoint(before, after);
  }

  static String _keyAfter(String key) {
    final chars = key.split('');
    var i = chars.length - 1;
    while (i >= 0) {
      final idx = _digits.indexOf(chars[i]);
      if (idx < _digits.length - 1) {
        chars[i] = _digits[idx + 1];
        return chars.join();
      }
      chars[i] = _digits[0];
      i--;
    }
    return '$key${_digits[_digits.length ~/ 2]}';
  }

  static String _keyBefore(String key) {
    final chars = key.split('');
    var i = chars.length - 1;
    while (i >= 0) {
      final idx = _digits.indexOf(chars[i]);
      if (idx > 0) {
        chars[i] = _digits[idx - 1];
        return chars.join();
      }
      chars[i] = _digits[_digits.length - 1];
      i--;
    }
    return '0$key';
  }

  static String _midpoint(String before, String after) {
    var left = before;
    var right = after;
    var result = '';

    while (left.isNotEmpty || right.isNotEmpty) {
      final l = left.isEmpty ? 0 : _digits.indexOf(left[0]);
      final r = right.isEmpty ? _digits.length - 1 : _digits.indexOf(right[0]);

      if (left.isNotEmpty) left = left.substring(1);
      if (right.isNotEmpty) right = right.substring(1);

      if (r - l > 1) {
        result += _digits[(l + r) ~/ 2];
        return result;
      }

      result += _digits[l];
      if (r - l == 1 && left.isEmpty && right.isNotEmpty) {
        result += _digits[(_digits.length - 1) ~/ 2];
        return result;
      }
    }

    return '$before${_digits[_digits.length ~/ 2]}';
  }
}
