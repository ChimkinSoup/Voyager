import 'package:flutter/foundation.dart';
import 'package:voyager/core/dev/cache_status.dart';

/// Tracks startup steps that are not backed by a [FutureProvider].
class WarmupTracker extends ChangeNotifier {
  final _states = <String, CacheItemState>{};

  Map<String, CacheItemState> get states => Map.unmodifiable(_states);

  void begin(String label) {
    _states[label] = CacheItemState.loading;
    notifyListeners();
  }

  void complete(String label) {
    _states[label] = CacheItemState.loaded;
    notifyListeners();
  }

  void fail(String label) {
    _states[label] = CacheItemState.failed;
    notifyListeners();
  }

  CacheItemState? stateFor(String label) => _states[label];
}
