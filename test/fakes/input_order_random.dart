import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';

/// A [Random] under which `List.shuffle` leaves the list as it was: shuffle
/// swaps each position `n - 1` with `nextInt(n)`, and this always answers
/// `n - 1`.
class InputOrderRandom implements Random {
  @override
  int nextInt(int max) => max - 1;

  @override
  double nextDouble() => 0;

  @override
  bool nextBool() => false;
}

/// Pins a study or LeetCode session to the order its cards were handed in, for
/// tests that expect a particular card first.
final Override noSessionShuffle = sessionShuffleRandomProvider
    .overrideWithValue(InputOrderRandom());
