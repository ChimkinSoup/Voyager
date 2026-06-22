import 'package:flutter/foundation.dart';
import 'package:voyager/core/dev/cache_status.dart';

@immutable
class MonthZoomPrewarmCheck {
  const MonthZoomPrewarmCheck({
    required this.label,
    required this.passed,
    this.detail,
  });

  final String label;
  final bool passed;
  final String? detail;
}

@immutable
class MonthZoomPrewarmStatus {
  const MonthZoomPrewarmStatus({
    required this.checks,
    required this.isFullyPrewarmed,
    required this.summary,
    required this.layoutCacheStatus,
  });

  factory MonthZoomPrewarmStatus.idle() {
    return const MonthZoomPrewarmStatus(
      checks: [],
      isFullyPrewarmed: false,
      summary: 'Open Calendar in year view',
      layoutCacheStatus: CacheItemStatus(
        label: 'Calendar zoom layout',
        state: CacheItemState.notStarted,
        detail: 'Calendar not active',
      ),
    );
  }

  final List<MonthZoomPrewarmCheck> checks;
  final bool isFullyPrewarmed;
  final String summary;
  final CacheItemStatus layoutCacheStatus;

  int get passedCount => checks.where((check) => check.passed).length;

  int get totalCount => checks.length;
}

bool _checksEqual(MonthZoomPrewarmCheck a, MonthZoomPrewarmCheck b) {
  return a.label == b.label && a.passed == b.passed && a.detail == b.detail;
}

bool _checksEqualLists(
  List<MonthZoomPrewarmCheck> a,
  List<MonthZoomPrewarmCheck> b,
) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (!_checksEqual(a[i], b[i])) return false;
  }
  return true;
}

/// Tracks year→month zoom transition prewarm readiness for debug UI.
class MonthZoomPrewarmTracker extends ChangeNotifier {
  MonthZoomPrewarmStatus _status = MonthZoomPrewarmStatus.idle();

  MonthZoomPrewarmStatus get status => _status;

  CacheItemStatus get layoutCacheStatus => _status.layoutCacheStatus;

  void update(MonthZoomPrewarmStatus status) {
    if (_status.isFullyPrewarmed == status.isFullyPrewarmed &&
        _status.summary == status.summary &&
        _status.layoutCacheStatus == status.layoutCacheStatus &&
        _checksEqualLists(_status.checks, status.checks)) {
      return;
    }
    _status = status;
    notifyListeners();
  }

  void markIdle() {
    update(MonthZoomPrewarmStatus.idle());
  }
}
