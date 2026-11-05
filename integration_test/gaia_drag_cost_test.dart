// What a drag's flash costs the app while it plays (code review #5): the
// runner draws flashes on its main thread, which also answers Flutter's
// platform channels. Measures, idle and during a short and a full-screen
// diagonal drag, how long a trivial channel call takes to come back, and how
// late a Dart timer fires. Prints the numbers; asserts nothing.
//
//   flutter test integration_test/gaia_drag_cost_test.dart -d windows
//
// Close any running Voyager first: the build replaces its exe.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:win32/win32.dart';

const _channel = MethodChannel('voyager/gaia_border');

/// Milliseconds: the median, the 95th percentile and the worst; and the share
/// over 4 ms, a quarter of a frame.
typedef _Stats = ({double median, double p95, double worst, double over4});

_Stats _stats(List<double> samples) {
  final sorted = [...samples]..sort();
  return (
    median: sorted[sorted.length ~/ 2],
    p95: sorted[(sorted.length * 0.95).floor()],
    worst: sorted.last,
    over4: sorted.where((s) => s > 4).length / sorted.length,
  );
}

/// Over [window]: channel round trips, one after another, and a 1 ms timer's
/// lateness, side by side.
Future<({_Stats ping, _Stats timer, int pings})> _sample(
  Duration window,
) async {
  final pings = <double>[];
  final lateness = <double>[];
  final clock = Stopwatch()..start();
  var last = clock.elapsedMicroseconds;
  final timer = Timer.periodic(const Duration(milliseconds: 1), (_) {
    final now = clock.elapsedMicroseconds;
    lateness.add((now - last) / 1000 - 1);
    last = now;
  });
  while (clock.elapsed < window) {
    final start = clock.elapsedMicroseconds;
    try {
      // Unknown, so answered at once by the same handler as 'flash'.
      await _channel.invokeMethod<void>('ping');
    } on MissingPluginException {
      // Expected.
    }
    pings.add((clock.elapsedMicroseconds - start) / 1000);
    // Spaced, so the runner's queue empties and its frame timer can fire:
    // Windows only sends WM_TIMER with nothing else waiting.
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  timer.cancel();
  return (ping: _stats(pings), timer: _stats(lateness), pings: pings.length);
}

String _describe(_Stats s) =>
    'median ${s.median.toStringAsFixed(2)}, p95 ${s.p95.toStringAsFixed(1)}, '
    'worst ${s.worst.toStringAsFixed(1)} ms, '
    '${(s.over4 * 100).toStringAsFixed(1)}% over 4 ms';

String _row(String what, ({_Stats ping, _Stats timer, int pings}) r) =>
    '$what:\n  channel round trip ${_describe(r.ping)} (${r.pings} calls)\n'
    '  1 ms timer lateness ${_describe(r.timer)}';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a drag flash, short and full-screen', (tester) async {
    final width = GetSystemMetrics(SM_CXSCREEN);
    final height = GetSystemMetrics(SM_CYSCREEN);
    debugPrint('[cost] primary screen ${width}x$height physical px');
    // A real drag's travel, and its whole play: lead-in 120, travel 330,
    // hold 300, fade 250.
    const play = Duration(milliseconds: 1000);
    Future<void> drag(int x, int y, int toX, int toY, String style) =>
        _channel.invokeMethod<void>('flash', {
          'kind': 'drag',
          'style': style,
          'x': x,
          'y': y,
          'to_x': toX,
          'to_y': toY,
          'ms': 330,
          'accent': 0x7C9EFF,
        });

    // Warm up the channel and the flash windows.
    await _sample(const Duration(milliseconds: 300));
    await drag(200, 200, 500, 300, 'astral');
    await Future<void>.delayed(play);

    for (final style in ['astral', 'classic']) {
      debugPrint(_row('[cost] $style idle', await _sample(play)));
      await drag(200, 200, 500, 300, style);
      debugPrint(_row('[cost] $style short 300 px', await _sample(play)));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final clock = Stopwatch()..start();
      await drag(40, 40, width - 40, height - 40, style);
      final start = clock.elapsedMicroseconds / 1000;
      debugPrint(
        '[cost] $style full-screen: the flash call itself took '
        '${start.toStringAsFixed(1)} ms (the first frame is drawn in it)',
      );
      debugPrint(
        _row('[cost] $style full-screen diagonal', await _sample(play)),
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
  });
}
