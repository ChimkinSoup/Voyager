import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/domain/services/fractional_index.dart';

/// The key generator this one replaced, whose keys are already in synced
/// operation logs: 'a0', then one digit up at a time, adding a digit on
/// overflow.
String _legacyAfter(String key) {
  const digits =
      '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz';
  final chars = key.split('');
  for (var i = chars.length - 1; i >= 0; i--) {
    final idx = digits.indexOf(chars[i]);
    if (idx < digits.length - 1) {
      chars[i] = digits[idx + 1];
      return chars.join();
    }
    chars[i] = digits[0];
  }
  return '${key}U';
}

/// Inserts [count] keys at random places, each between its live neighbours
/// the way the character session does, checking every one as it goes.
List<String> _insertRandomly(List<String> keys, int count, Random random) {
  for (var n = 0; n < count; n++) {
    final at = random.nextInt(keys.length + 1);
    // Runs of typing: most inserts go right after the previous one.
    final runLength = 1 + random.nextInt(20);
    var low = at == 0 ? null : keys[at - 1];
    final high = at == keys.length ? null : keys[at];
    for (var r = 0; r < runLength; r++) {
      final key = FractionalIndex.between(before: low, after: high);
      expect(key, isNotEmpty);
      expect(key.endsWith('0'), isFalse, reason: 'key $key ends in 0');
      if (low != null) {
        expect(low.compareTo(key), lessThan(0), reason: '$low !< $key');
      }
      if (high != null) {
        expect(key.compareTo(high), lessThan(0), reason: '$key !< $high');
      }
      keys.insert(at + r, key);
      low = key;
    }
  }
  return keys;
}

void main() {
  test('random edits keep keys strictly ordered, on new and legacy keys', () {
    for (var seed = 0; seed < 6; seed++) {
      final random = Random(seed);
      final legacy = <String>['a0'];
      for (var i = 0; i < 3000; i++) {
        legacy.add(_legacyAfter(legacy.last));
      }
      for (final start in [
        <String>[],
        FractionalIndex.spread(500),
        legacy,
      ]) {
        final keys = _insertRandomly([...start], 400, random);
        for (var i = 1; i < keys.length; i++) {
          expect(keys[i - 1].compareTo(keys[i]), lessThan(0));
        }
      }
    }
  });

  test('typing at the end keeps keys short', () {
    var key = FractionalIndex.first();
    for (var i = 0; i < 20000; i++) {
      key = FractionalIndex.after(key);
    }
    // The old generator reached 596 characters here.
    expect(key.length, lessThanOrEqualTo(6));
  });

  test('typing a run in the middle keeps keys short', () {
    var low = 'a5';
    for (var i = 0; i < 2000; i++) {
      low = FractionalIndex.between(before: low, after: 'a6');
    }
    // The old generator reached 336 characters here.
    expect(low.length, lessThanOrEqualTo(8));
  });

  test('typing at the start keeps keys short', () {
    var key = FractionalIndex.first();
    for (var i = 0; i < 2000; i++) {
      key = FractionalIndex.before(key);
    }
    expect(key.length, lessThanOrEqualTo(6));
  });

  test('loaded text gets evenly spread short keys', () {
    final keys = FractionalIndex.spread(4000);
    expect(keys, hasLength(4000));
    expect(keys.every((k) => k.length <= 3 && !k.endsWith('0')), isTrue);
    for (var i = 1; i < keys.length; i++) {
      expect(keys[i - 1].compareTo(keys[i]), lessThan(0));
    }
    // Room is left at both ends.
    expect(FractionalIndex.after(keys.last).length, lessThanOrEqualTo(3));
    expect(FractionalIndex.before(keys.first).length, lessThanOrEqualTo(6));
  });

  test('typing after a long legacy key stops growing', () {
    var legacy = 'a0';
    for (var i = 0; i < 8000; i++) {
      legacy = _legacyAfter(legacy);
    }
    // Nothing shorter sorts after it, but the keys that follow stop growing.
    var key = FractionalIndex.after(legacy);
    expect(key.length, lessThanOrEqualTo(legacy.length + 2));
    final firstLength = key.length;
    for (var i = 0; i < 5000; i++) {
      key = FractionalIndex.after(key);
    }
    expect(key.length, firstLength);
  });
}
