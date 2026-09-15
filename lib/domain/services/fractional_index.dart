/// Lexicographic fractional indexing for CRDT character positions.
///
/// A key reads as a base-62 fraction, so plain string comparison orders keys.
///
/// Text is typed forwards, so almost every new key lands just after the
/// previous one. Each step spends one unit a few digits below the room left
/// before the next key (the run of 'z's the key starts with), so a run of
/// typing adds a digit only every ~238k characters. Stepping at the key's own
/// last digit instead, or halving the gap, grew keys by one character every
/// ~30 characters typed at the end and every ~6 typed mid-text.
///
/// Generated keys never end in '0'. A key K followed by '0's leaves no string
/// strictly between K and it. Keys already in an operation log may predate
/// that rule, so every input is accepted.
class FractionalIndex {
  FractionalIndex._();

  static const _digits =
      '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz';
  static const _base = 62;

  /// First key in an empty document: the middle, with room on both sides.
  static String first() => 'V';

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
    return _keyBetween(before, after);
  }

  /// [count] increasing keys for text that arrives all at once.
  ///
  /// Spread evenly over [1/62, 1/2) rather than chained with [after], which
  /// would give a loaded entry the long keys of one typed character by
  /// character. The top half is left for text typed at the end.
  static List<String> spread(int count) {
    if (count <= 0) return const [];
    var scale = _base;
    while ((scale ~/ 2 - scale ~/ _base) ~/ (count + 1) < 1) {
      scale *= _base;
    }
    final width = _widthOf(scale);
    final start = scale ~/ _base;
    final step = (scale ~/ 2 - start) ~/ (count + 1);
    return [
      for (var i = 1; i <= count; i++) _fromInt(start + i * step, width),
    ];
  }

  static String _keyAfter(String key) {
    var zs = 0;
    while (zs < key.length && key[zs] == 'z') {
      zs++;
    }
    // Room left above the key is about 62^-zs. Stepping three digits below it
    // leaves 62^3 steps before the next digit; two at the very top, where a
    // short document shouldn't pay a third digit per character.
    final digits = _digitsOf(key, _stepWidth(zs));
    // Truncating never raises the key, and adding one unit at the last digit
    // lifts it past everything the truncation dropped. The carry stops at or
    // before the first non-'z' digit.
    var i = digits.length - 1;
    while (digits[i] == _base - 1) {
      digits[i] = 0;
      i--;
    }
    digits[i]++;
    return _encode(digits);
  }

  static String _keyBefore(String key) {
    var zeros = 0;
    while (zeros < key.length && key[zeros] == '0') {
      zeros++;
    }
    // Nothing sorts before an all-'0' key. Only old logs can hold one; the
    // result is out of order, which the session's order check re-seeds from.
    if (zeros == key.length) return '0$key';
    final digits = _digitsOf(key, _stepWidth(zeros));
    // Truncating never raises the key; one unit down makes it strictly lower,
    // and stays above zero because a non-'0' digit sits before the last.
    var i = digits.length - 1;
    while (digits[i] == 0) {
      digits[i] = _base - 1;
      i--;
    }
    digits[i]--;
    return _encode(digits);
  }

  static String _keyBetween(String low, String high) {
    var i = 0;
    while (i < low.length && low[i] == high[i]) {
      i++;
    }

    if (i == low.length) {
      // [low] is a prefix of [high]. Padding it with '0's keeps it the same
      // value and still below [high], up to one past [high]'s run of '0's.
      var zeros = 0;
      while (i + zeros < high.length && high[i + zeros] == '0') {
        zeros++;
      }
      // [high] is [low] followed by '0's: no key fits. Only old logs can hold
      // such a pair; see [_keyBefore].
      if (i + zeros == high.length) return '$low${_digits[_base ~/ 2]}';
      return _keyBetween('$low${'0' * (zeros + 1)}', high);
    }

    final lowDigit = _digits.indexOf(low[i]);
    final highDigit = _digits.indexOf(high[i]);
    if (highDigit - lowDigit > 1) {
      return '${high.substring(0, i)}${_digits[lowDigit + 1]}';
    }

    // Adjacent digits: extend one side. Just above [low] is where the next
    // typed character will want room, so it wins ties.
    final aboveLow =
        '${low.substring(0, i + 1)}${_keyAfter(low.substring(i + 1))}';
    final highRest = high.substring(i + 1);
    if (highRest.replaceAll('0', '').isEmpty) return aboveLow;
    final belowHigh = '${high.substring(0, i + 1)}${_keyBefore(highRest)}';
    return belowHigh.length < aboveLow.length ? belowHigh : aboveLow;
  }

  /// Digits in a step from a key whose room is [run] digits deep. Always at
  /// least two past the run, so the digit that ends it can move.
  static int _stepWidth(int run) => run == 0 ? 2 : run + 3;

  /// The first [length] digits of [key], padded with zeros.
  static List<int> _digitsOf(String key, int length) => [
    for (var i = 0; i < length; i++)
      i < key.length ? _digits.indexOf(key[i]) : 0,
  ];

  /// Drops trailing zeros, which leaves the value unchanged.
  static String _encode(List<int> digits) {
    var end = digits.length;
    while (end > 0 && digits[end - 1] == 0) {
      end--;
    }
    return digits.take(end).map((d) => _digits[d]).join();
  }

  static int _widthOf(int scale) {
    var width = 0;
    for (var s = scale; s > 1; s ~/= _base) {
      width++;
    }
    return width;
  }

  static String _fromInt(int value, int width) {
    final digits = List<int>.filled(width, 0);
    for (var i = width - 1; i >= 0; i--) {
      digits[i] = value % _base;
      value ~/= _base;
    }
    return _encode(digits);
  }
}
