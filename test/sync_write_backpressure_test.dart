import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/sync/firestore_write_gate.dart';

void main() {
  /// A gate whose inherited queue is already confirmed empty, so the full
  /// allowance is in force.
  Future<FirestoreWriteGate> settledGate() async {
    final gate = FirestoreWriteGate(waitForPendingWrites: () async {});
    // The probe is deliberately unawaited inside the gate, so let its
    // completion land before the test reads the limit.
    await Future<void>.delayed(Duration.zero);
    return gate;
  }

  group('write gate', () {
    test('runs writes while there is room, and releases the slot', () async {
      final gate = await settledGate();

      expect(await gate.run(() async => 'done'), 'done');
      expect(gate.inFlight, 0);
      expect(gate.isPaused, isFalse);
      expect(gate.refusedWrites, 0);
    });

    test('refuses once the allowance is full, and resumes as it drains', () async {
      final gate = await settledGate();
      final blockers = <Completer<void>>[];

      // Fill the allowance with writes that never complete — a stalled
      // connection, which is the whole point.
      for (var i = 0; i < FirestoreWriteGate.inFlightLimit; i++) {
        final blocker = Completer<void>();
        blockers.add(blocker);
        unawaited(gate.run(() => blocker.future));
      }
      expect(gate.inFlight, FirestoreWriteGate.inFlightLimit);
      expect(gate.isPaused, isTrue);

      await expectLater(
        gate.run(() async {}),
        throwsA(isA<SyncBackpressureException>()),
      );
      expect(gate.refusedWrites, 1);

      // One acknowledgement is one slot back.
      blockers.first.complete();
      await Future<void>.delayed(Duration.zero);
      expect(gate.isPaused, isFalse);
      expect(await gate.run(() async => 'through'), 'through');

      for (final blocker in blockers.skip(1)) {
        blocker.complete();
      }
    });

    test('a failed write does not leak its slot', () async {
      final gate = await settledGate();

      await expectLater(
        gate.run(() async => throw StateError('rejected')),
        throwsStateError,
      );
      expect(gate.inFlight, 0);
    });

    test('peak survives the backlog draining away', () async {
      final gate = await settledGate();
      final blocker = Completer<void>();
      unawaited(gate.run(() => blocker.future));
      expect(gate.peakInFlight, 1);

      blocker.complete();
      await Future<void>.delayed(Duration.zero);
      expect(gate.inFlight, 0);
      expect(gate.peakInFlight, 1);
    });

    test('runs on a tighter allowance until the inherited queue clears', () async {
      // Never completes: a queue left by an earlier session that is still
      // wedged. This is the case that used to let a restart hand Firestore a
      // fresh 50 writes on top of a backlog it could not see.
      final gate = FirestoreWriteGate(
        waitForPendingWrites: () => Completer<void>().future,
      );
      await Future<void>.delayed(Duration.zero);

      expect(gate.hasStartupBacklog, isTrue);
      expect(gate.limit, lessThan(FirestoreWriteGate.inFlightLimit));

      final blockers = <Completer<void>>[];
      for (var i = 0; i < gate.limit; i++) {
        final blocker = Completer<void>();
        blockers.add(blocker);
        unawaited(gate.run(() => blocker.future));
      }
      await expectLater(
        gate.run(() async {}),
        throwsA(isA<SyncBackpressureException>()),
      );

      for (final blocker in blockers) {
        blocker.complete();
      }
    });

    test('a probe the platform cannot answer does not wedge the gate', () async {
      final gate = FirestoreWriteGate(
        waitForPendingWrites: () => throw UnimplementedError(),
      );
      await Future<void>.delayed(Duration.zero);

      expect(gate.hasStartupBacklog, isFalse);
      expect(gate.limit, FirestoreWriteGate.inFlightLimit);
    });
  });

  group('write gate stalls', () {
    test('a write that is never acknowledged times out and frees its slot', () {
      fakeAsync((async) {
        final gate = FirestoreWriteGate(waitForPendingWrites: () async {});
        async.flushMicrotasks();

        Object? thrown;
        unawaited(
          gate.run(() => Completer<void>().future).catchError((Object error) {
            thrown = error;
          }),
        );
        async.elapse(FirestoreWriteGate.writeTimeout * 2);

        expect(thrown, isA<TimeoutException>());
        expect(gate.inFlight, 0);
        expect(gate.timedOutWrites, 1);
      });
    });

    test('a timeout latches the gate shut rather than re-admitting', () {
      // The point of the latch. Freeing the slot without it would let the gate
      // feed a fresh batch into the same stopped queue every writeTimeout,
      // which is the backlog this class exists to prevent.
      fakeAsync((async) {
        final gate = FirestoreWriteGate(
          waitForPendingWrites: () => Completer<void>().future,
        );
        async.flushMicrotasks();

        unawaited(gate.run(() => Completer<void>().future).catchError((_) {}));
        async.elapse(FirestoreWriteGate.writeTimeout * 2);

        expect(gate.isStalled, isTrue);
        expect(gate.isPaused, isTrue);
        expect(gate.limit, 0);

        Object? refusal;
        unawaited(
          gate.run(() async {}).catchError((Object error) {
            refusal = error;
          }),
        );
        async.flushMicrotasks();

        expect(refusal, isA<SyncBackpressureException>());
        expect((refusal! as SyncBackpressureException).stalled, isTrue);
      });
    });

    test('the gate reopens when the queue is next seen to drain', () {
      // Recovery without a restart, which is the other half of the latch: the
      // re-armed probe is the only thing that can tell a recovered stream from
      // a stopped one, because attempting a write to find out is the thing
      // that deepens the queue.
      fakeAsync((async) {
        final probes = <Completer<void>>[];
        final gate = FirestoreWriteGate(
          waitForPendingWrites: () {
            final probe = Completer<void>();
            probes.add(probe);
            return probe.future;
          },
        );
        async.flushMicrotasks();
        expect(probes, hasLength(1));

        unawaited(gate.run(() => Completer<void>().future).catchError((_) {}));
        async.elapse(FirestoreWriteGate.writeTimeout * 2);
        expect(gate.isStalled, isTrue);

        // The stall re-armed the probe rather than reusing the launch one,
        // which by now is never going to answer.
        expect(probes, hasLength(2));

        probes.last.complete();
        async.flushMicrotasks();

        expect(gate.isStalled, isFalse);
        expect(gate.hasStartupBacklog, isFalse);
        expect(gate.limit, FirestoreWriteGate.inFlightLimit);
      });
    });

    test('a batch timing out together arms one probe, not one each', () {
      fakeAsync((async) {
        var probeCount = 0;
        final gate = FirestoreWriteGate(
          waitForPendingWrites: () {
            probeCount++;
            return Completer<void>().future;
          },
        );
        async.flushMicrotasks();

        for (var i = 0; i < 5; i++) {
          unawaited(gate.run(() => Completer<void>().future).catchError((_) {}));
        }
        async.elapse(FirestoreWriteGate.writeTimeout * 2);

        expect(gate.timedOutWrites, 5);
        expect(probeCount, 2); // one at launch, one for the stall
      });
    });
  });
}
