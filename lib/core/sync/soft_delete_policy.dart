import 'package:voyager/core/constants/app_constants.dart';

class SoftDeletePolicy {
  const SoftDeletePolicy();

  bool isExpired(DateTime deletedAt, DateTime now) {
    return now.difference(deletedAt).inDays >= softDeleteRetentionDays;
  }

  DateTime purgeEligibleAfter(DateTime deletedAt) {
    return deletedAt.add(const Duration(days: softDeleteRetentionDays));
  }
}
