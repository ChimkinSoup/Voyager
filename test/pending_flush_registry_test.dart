// The termination flush must never be able to hang.
//
// Every registered callback ends in a Firestore write, and an unreachable
// server makes that write wait indefinitely — on the window-close path that
// used to mean a window that would not close. See VoyagerApp.onWindowClose.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/sync/pending_flush_registry.dart';

void main() {
  const deadline = Duration(milliseconds: 50);

  final registered = <Future<void> Function()>[];

  void register(Future<void> Function() callback) {
    registered.add(callback);
    PendingFlushRegistry.instance.register(callback);
  }

  tearDown(() {
    for (final callback in registered) {
      PendingFlushRegistry.instance.unregister(callback);
    }
    registered.clear();
  });

  test('a callback that never completes does not hold up the flush', () async {
    final hung = Completer<void>();
    var laterRan = false;
    register(() => hung.future);
    register(() async {
      laterRan = true;
    });

    await PendingFlushRegistry.instance
        .flushAll(perCallbackDeadline: deadline)
        .timeout(const Duration(seconds: 5));

    expect(laterRan, isTrue);
  });

  test('a callback that throws does not stop the ones behind it', () async {
    var laterRan = false;
    register(() async => throw StateError('offline'));
    register(() async {
      laterRan = true;
    });

    await PendingFlushRegistry.instance.flushAll(perCallbackDeadline: deadline);

    expect(laterRan, isTrue);
  });

  test('without a deadline every callback is still awaited in full', () async {
    final order = <String>[];
    register(() async {
      await Future<void>.delayed(const Duration(milliseconds: 80));
      order.add('slow');
    });
    register(() async => order.add('fast'));

    await PendingFlushRegistry.instance.flushAll();

    expect(order, ['slow', 'fast']);
  });
}
