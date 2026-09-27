import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/core/icons/voyager_icons.dart';
import 'package:voyager/core/sync/soft_delete_policy.dart';
import 'package:voyager/features/trash/trash_kinds.dart';
import 'package:voyager/features/trash/trash_service.dart';

IconData trashFeatureIcon(TrashFeature feature) => switch (feature) {
  TrashFeature.journal => VoyagerIcons.journal,
  TrashFeature.dreams => PhosphorIconsRegular.moonStars,
  TrashFeature.todo => PhosphorIconsRegular.listChecks,
  TrashFeature.calendar => VoyagerIcons.calendar,
  TrashFeature.study => PhosphorIconsRegular.cardsThree,
  TrashFeature.leetcode => PhosphorIconsRegular.code,
  TrashFeature.rankings => PhosphorIconsRegular.ranking,
  TrashFeature.jobs => PhosphorIconsRegular.briefcase,
  TrashFeature.finance => PhosphorIconsRegular.wallet,
  TrashFeature.analytics => PhosphorIconsRegular.chartLine,
  TrashFeature.workout => PhosphorIconsRegular.barbell,
  TrashFeature.life => PhosphorIconsRegular.tree,
};

/// `Journal "Work"`, `"Trip to Banff"`, or `Untitled entry`.
String trashItemLabel(TrashItem item) {
  final title = item.title;
  final quoted = title == null ? null : '"${cappedTrashTitle(title)}"';
  final container = item.kind.containerLabel;
  if (container != null) {
    return quoted == null ? 'Untitled ${item.kind.noun}' : '$container $quoted';
  }
  return quoted ?? 'Untitled ${item.kind.noun}';
}

/// "To-Do · deleted 5 days ago · 25 days left".
String trashItemDetail(
  TrashItem item,
  DateTime now, {
  SoftDeletePolicy policy = const SoftDeletePolicy(),
}) {
  final ago = now.difference(item.deletedAt);
  final deleted = switch (ago.inDays) {
    0 => 'deleted today',
    1 => 'deleted yesterday',
    final days => 'deleted $days days ago',
  };
  final hoursLeft = policy
      .purgeEligibleAfter(item.deletedAt)
      .difference(now)
      .inHours;
  final daysLeft = (hoursLeft / 24).ceil();
  final left = daysLeft <= 1 ? 'last day' : '$daysLeft days left';
  return [item.kind.feature.label, ?item.summary, deleted, left].join(' · ');
}

/// [title] cut to 60 characters, for quoting in a label or message.
String cappedTrashTitle(String title) {
  const limit = 60;
  final chars = title.characters;
  if (chars.length <= limit) return title;
  return '${chars.take(limit).toString().trimRight()}…';
}
