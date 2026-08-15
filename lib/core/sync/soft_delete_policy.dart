import 'package:voyager/core/constants/app_constants.dart';

class SoftDeletePolicy {
  const SoftDeletePolicy();

  bool isExpired(DateTime deletedAt, DateTime now) {
    return now.difference(deletedAt).inDays >= softDeleteRetentionDays;
  }

  DateTime purgeEligibleAfter(DateTime deletedAt) {
    return deletedAt.add(const Duration(days: softDeleteRetentionDays));
  }

  /// [isExpired] restated as a bound on `deletedAt`, so the same rule can be
  /// written as a `WHERE` clause instead of a loop in Dart.
  ///
  /// A row is expired exactly when `deletedAt <= cutoff(now)`.
  DateTime purgeCutoff(DateTime now) {
    return now.subtract(const Duration(days: softDeleteRetentionDays));
  }
}
