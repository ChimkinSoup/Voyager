import 'package:voyager/core/constants/app_constants.dart';
import 'package:voyager/core/soft_delete/erasure.dart';

class SoftDeletePolicy {
  const SoftDeletePolicy();

  /// An erased row never expires. It holds no content, and it is the only
  /// thing that stops a device coming back online, however long after the
  /// erase, from bringing the item back with a stale copy.
  bool isExpired(DateTime deletedAt, DateTime now) {
    return now.difference(deletedAt).inDays >= softDeleteRetentionDays &&
        !isErasedAt(deletedAt);
  }

  DateTime purgeEligibleAfter(DateTime deletedAt) {
    return deletedAt.add(const Duration(days: softDeleteRetentionDays));
  }

  /// [isExpired] restated as a bound on `deletedAt`, so the same rule can be
  /// written as a `WHERE` clause instead of a loop in Dart.
  ///
  /// A row is expired exactly when `deletedAt <= cutoff(now)` and it is not
  /// erased.
  DateTime purgeCutoff(DateTime now) {
    return now.subtract(const Duration(days: softDeleteRetentionDays));
  }
}
