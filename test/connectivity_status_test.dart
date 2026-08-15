import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/core/sync/connectivity_status.dart';

void main() {
  // The controller observes the app lifecycle to stop probing in the
  // background, so it needs a binding even in these non-widget tests.
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  const start = Duration(seconds: 1);
  const online = Duration(seconds: 10);
  const offline = Duration(seconds: 2);
  const timeout = Duration(seconds: 5);

  /// Runs [body] against a controller whose probe outcome is whatever
  /// `outcome()` currently returns, inside fake time.
  void withController(
    Future<void> Function() Function() outcome,
    void Function(FakeAsync async, ConnectivityStatusController controller)
    body,
  ) {
    fakeAsync((async) {
      final controller = ConnectivityStatusController(
        probe: () => outcome()(),
        startDelay: start,
        onlineInterval: online,
        offlineInterval: offline,
        probeTimeout: timeout,
      );
      body(async, controller);
      // Disposed inside the zone: the probe reschedules itself forever, so a
      // live controller would leave fakeAsync with a pending timer.
      controller.dispose();
    });
  }

  Future<void> Function() succeeds() => () async {};
  Future<void> Function() fails() =>
      () async => throw StateError('unreachable');

  test('starts online before the first probe has answered', () {
    withController(succeeds, (async, controller) {
      expect(controller.isOnline, isTrue);
      async.elapse(start ~/ 2);
      expect(controller.isOnline, isTrue);
    });
  });

  test('a single failed probe is not enough to report offline', () {
    withController(fails, (async, controller) {
      async.elapse(start);
      expect(
        controller.isOnline,
        isTrue,
        reason: 'one dropped request is a blip, not an outage',
      );
    });
  });

  test('two consecutive failures report offline', () {
    var notifications = 0;
    withController(fails, (async, controller) {
      controller.addListener(() => notifications++);
      async.elapse(start + offline);
      expect(controller.isOnline, isFalse);
      expect(notifications, 1);

      // Staying offline keeps probing but must not keep notifying.
      async.elapse(offline * 3);
      expect(notifications, 1);
    });
  });

  test('recovers on the first success after going offline', () {
    var outcome = fails;
    withController(() => outcome(), (async, controller) {
      async.elapse(start + offline);
      expect(controller.isOnline, isFalse);

      outcome = succeeds;
      async.elapse(offline);
      expect(controller.isOnline, isTrue);
    });
  });

  test('a probe that never answers counts as a failure', () {
    withController(
      () =>
          () => Completer<void>().future,
      (async, controller) {
        // Two full timeouts: the probe is rescheduled from its answer, so the
        // second attempt only begins once the first has timed out.
        async.elapse(start + timeout + offline + timeout);
        expect(controller.isOnline, isFalse);
      },
    );
  });

  test('recovery does not need the failure streak to be re-cleared', () {
    var outcome = succeeds;
    withController(() => outcome(), (async, controller) {
      // One failure, then a success, then one more failure: the streak reset
      // means this must not read as two failures in a row.
      outcome = fails;
      async.elapse(start); // fails once, so the next probe comes quickly
      outcome = succeeds;
      async.elapse(offline); // succeeds, clearing the streak
      outcome = fails;
      async.elapse(online); // fails once more
      expect(controller.isOnline, isTrue);
    });
  });

  test('stops probing once disposed', () {
    var probes = 0;
    fakeAsync((async) {
      final controller = ConnectivityStatusController(
        probe: () async => probes++,
        startDelay: start,
        onlineInterval: online,
      );
      async.elapse(start);
      expect(probes, 1);

      controller.dispose();
      async.elapse(online * 5);
      expect(probes, 1);
    });
  });

  group('foreground only', () {
    /// Runs [body] with a counting probe and a controller that is disposed —
    /// and returned to the foreground — however the test leaves it.
    void withProbeCount(
      void Function(
        FakeAsync async,
        ConnectivityStatusController controller,
        int Function() probes,
      )
      body,
    ) {
      var probes = 0;
      fakeAsync((async) {
        final controller = ConnectivityStatusController(
          probe: () async => probes++,
          startDelay: start,
          onlineInterval: online,
          offlineInterval: offline,
        );
        body(async, controller, () => probes);
        binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        controller.dispose();
      });
    }

    test('stops probing when the window loses focus', () {
      withProbeCount((async, controller, probes) {
        async.elapse(start);
        expect(probes(), 1);

        // What Windows reports on alt-tab.
        binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
        async.elapse(online * 5);
        expect(probes(), 1, reason: 'nobody is reading the badge');
      });
    });

    test('stops probing when the app is backgrounded', () {
      withProbeCount((async, controller, probes) {
        async.elapse(start);
        // Android's route to the background runs through every state.
        binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
        binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        async.elapse(online * 5);
        expect(probes(), 1);
      });
    });

    test(
      'probes immediately on return rather than waiting out the interval',
      () {
        withProbeCount((async, controller, probes) {
          async.elapse(start);
          binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
          async.elapse(online * 5);

          binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
          async.flushMicrotasks();
          expect(probes(), 2, reason: 'the badge is current before it is read');

          // And the schedule picks up again from there.
          async.elapse(online);
          expect(probes(), 3);
        });
      },
    );

    test('a quick trip away and back does not spend a probe', () {
      withProbeCount((async, controller, probes) {
        async.elapse(start); // probe 1, next one due an interval later
        binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
        async.elapse(online ~/ 5);
        binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        async.flushMicrotasks();
        expect(probes(), 1, reason: 'the last answer is still fresh');

        // The interval was picked up where it left off, not restarted: the
        // next probe still lands one interval after the last answer.
        async.elapse(online - (online ~/ 5));
        expect(probes(), 2);
      });
    });

    test('repeated alt-tabbing cannot starve the schedule', () {
      withProbeCount((async, controller, probes) {
        async.elapse(start); // probe 1
        // Away and back faster than the interval, over and over. Restarting
        // the interval on each return would mean the probe never runs again.
        for (var i = 0; i < 6; i++) {
          binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
          async.elapse(online ~/ 4);
          binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
          async.flushMicrotasks();
        }
        expect(probes(), greaterThan(1));
      });
    });

    test('a probe still in the air on return is not doubled up', () {
      var probes = 0;
      final answers = <Completer<void>>[];
      fakeAsync((async) {
        final controller = ConnectivityStatusController(
          probe: () {
            probes++;
            final answer = Completer<void>();
            answers.add(answer);
            return answer.future;
          },
          startDelay: start,
          onlineInterval: online,
          probeTimeout: const Duration(minutes: 1),
        );

        async.elapse(start);
        expect(probes, 1);

        binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
        binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        async.flushMicrotasks();
        expect(probes, 1, reason: 'the in-flight round-trip is answer enough');

        // Once it lands, the normal schedule resumes.
        answers.single.complete();
        async.elapse(online);
        expect(probes, 2);

        binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        controller.dispose();
      });
    });
  });
}
