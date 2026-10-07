import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/domain/models/journal_models.dart';

void main() {
  late List<FlutterErrorDetails> reported;

  setUp(() {
    reported = [];
    final onError = FlutterError.onError;
    FlutterError.onError = reported.add;
    addTearDown(() => FlutterError.onError = onError);
  });

  /// A container whose journals load once, then reload as [reload] does.
  ProviderContainer containerWhoseReload(
    Future<List<Journal>> Function() reload,
  ) {
    var builds = 0;
    final container = ProviderContainer(
      overrides: [
        journalsProvider.overrideWith(
          (ref) => builds++ == 0 ? Future.value(<Journal>[]) : reload(),
        ),
      ],
    );
    container.listen(journalsProvider, (_, _) {});
    return container;
  }

  test('a reload that never finishes is reported and given up on', () {
    fakeAsync((async) {
      final container = containerWhoseReload(
        () => Completer<List<Journal>>().future,
      );
      addTearDown(container.dispose);
      async.flushMicrotasks();

      var done = false;
      unawaited(reloadAllDataProvidersIn(container).then((_) => done = true));
      async.elapse(const Duration(seconds: 9));
      expect(done, isFalse);
      async.elapse(const Duration(seconds: 2));

      expect(done, isTrue);
      expect(reported.single.exception, isA<TimeoutException>());
    });
  });

  test('a reload that fails is reported rather than thrown', () async {
    final container = containerWhoseReload(
      () => Future.error(StateError('database is locked')),
    );
    addTearDown(container.dispose);
    await container.read(journalsProvider.future);

    await reloadAllDataProvidersIn(container);

    expect(reported.single.exception, isA<StateError>());
  });
}
