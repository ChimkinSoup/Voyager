import 'dart:async';

import 'package:voyager/core/constants/app_constants.dart';

typedef DebouncedCallback = Future<void> Function();

class Debouncer {
  Debouncer({Duration? delay})
    : delay = delay ?? const Duration(seconds: syncDebounceSeconds);

  final Duration delay;
  Timer? _timer;

  Duration get debounceDelay => delay;

  void schedule(DebouncedCallback callback) {
    _timer?.cancel();
    _timer = Timer(delay, () {
      unawaited(callback());
    });
  }

  void cancel() => _timer?.cancel();

  void dispose() => _timer?.cancel();
}
