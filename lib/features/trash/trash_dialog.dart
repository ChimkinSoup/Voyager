import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/icons/voyager_icons.dart';
import 'package:voyager/core/soft_delete/soft_delete_toast.dart';
import 'package:voyager/core/sync/soft_delete_policy.dart';
import 'package:voyager/core/widgets/confirm_dialog.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/voyager_dialog.dart';
import 'package:voyager/core/widgets/voyager_popup_menu_item.dart';
import 'package:voyager/core/widgets/voyager_toast.dart';
import 'package:voyager/features/trash/trash_kinds.dart';
import 'package:voyager/features/trash/trash_service.dart';

/// Everything deleted in the last 30 days, across every page — `TRASH_HLD.md`.
///
/// [feature] opens it already filtered, for a page's "Recently deleted" link.
Future<void> showTrashDialog(BuildContext context, {TrashFeature? feature}) {
  return showVoyagerDialog<void>(
    context: context,
    builder: (_) => _TrashDialog(initialFeature: feature),
  );
}

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
  final quoted = title == null ? null : '"${_capped(title)}"';
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

String _capped(String title) {
  const limit = 60;
  final chars = title.characters;
  if (chars.length <= limit) return title;
  return '${chars.take(limit).toString().trimRight()}…';
}

enum _RowAction { restore, erase }

class _TrashDialog extends ConsumerStatefulWidget {
  const _TrashDialog({this.initialFeature});

  final TrashFeature? initialFeature;

  @override
  ConsumerState<_TrashDialog> createState() => _TrashDialogState();
}

class _TrashDialogState extends ConsumerState<_TrashDialog> {
  late TrashFeature? _feature = widget.initialFeature;

  /// Set while a restore or erase is running, so a second click can't start
  /// another against rows the first is still rewriting.
  bool _busy = false;

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } finally {
      // Whatever it touched, every page reading those rows is now stale — and
      // so is this list.
      invalidateAllDataProvidersFrom(ref);
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restore(TrashItem item) => _run(() async {
    final label = trashItemLabel(item);
    try {
      final movedTo = await ref.read(trashServiceProvider).restore(item);
      if (!mounted) return;
      showVoyagerToast(
        context,
        message: movedTo == null
            ? 'Restored $label'
            : 'Restored $label to $movedTo',
        icon: PhosphorIconsRegular.arrowCounterClockwise,
      );
    } on RestoreSuperseded {
      if (!mounted) return;
      showVoyagerToast(context, message: 'Already restored');
    } on TrashRestoreBlocked catch (blocked) {
      if (!mounted) return;
      final parentTitle = blocked.parentTitle;
      showVoyagerToast(
        context,
        message: parentTitle == null || parentTitle.isEmpty
            ? "Can't restore $label: its ${blocked.parentNoun} no longer "
                  'exists'
            : 'Restore ${blocked.parentNoun} "${_capped(parentTitle)}" '
                  'first',
      );
    }
  });

  Future<void> _erase(TrashItem item) async {
    final summary = item.summary;
    final confirmed = await showConfirmDialog(
      context,
      title: 'Delete forever?',
      message: summary == null
          ? '${trashItemLabel(item)} will be permanently deleted on all your '
                "devices. This can't be undone."
          : '${trashItemLabel(item)} and its $summary will be permanently '
                "deleted on all your devices. This can't be undone.",
      confirmLabel: 'Delete forever',
    );
    if (!confirmed || !mounted) return;
    await _run(() => ref.read(trashServiceProvider).erase([item]));
  }

  Future<void> _empty(List<TrashItem> items) async {
    final feature = _feature;
    final confirmed = await showConfirmDialog(
      context,
      title: feature == null ? 'Empty trash?' : 'Empty ${feature.label} trash?',
      message:
          'Permanently delete ${items.length} '
          "${items.length == 1 ? 'item' : 'items'} on all your devices? "
          "This can't be undone.",
      confirmLabel: 'Empty trash',
    );
    if (!confirmed || !mounted) return;
    await _run(() => ref.read(trashServiceProvider).erase(items));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final all = ref.watch(trashItemsProvider).valueOrNull;
    final feature = _feature;
    final shown = all == null
        ? null
        : [
            for (final item in all)
              if (feature == null || item.kind.feature == feature) item,
          ];
    final features = {for (final item in all ?? const []) item.kind.feature};

    return AlertDialog(
      title: Row(
        children: [
          const Expanded(child: Text('Trash')),
          if (shown != null && shown.isNotEmpty)
            TextButton.icon(
              onPressed: _busy ? null : () => _empty(shown),
              icon: const Icon(PhosphorIconsRegular.trash, size: 18),
              label: Text(
                feature == null
                    ? 'Empty trash'
                    : 'Empty ${feature.label} trash',
              ),
            ),
        ],
      ),
      contentPadding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
      content: SizedBox(
        width: 600,
        height: 480,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (features.length > 1 || feature != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    ChoiceChip(
                      label: const Text('All'),
                      selected: feature == null,
                      onSelected: (_) => setState(() => _feature = null),
                    ),
                    for (final option in TrashFeature.values)
                      if (features.contains(option) || option == feature)
                        ChoiceChip(
                          avatar: Icon(trashFeatureIcon(option), size: 16),
                          label: Text(option.label),
                          selected: option == feature,
                          onSelected: (_) => setState(() => _feature = option),
                        ),
                  ],
                ),
              ),
            Expanded(
              child: shown == null
                  ? const Center(child: CircularProgressIndicator())
                  : shown.isEmpty
                  ? Center(
                      child: Text(
                        feature == null
                            ? 'Nothing in the trash. Deleted items stay here '
                                  'for 30 days.'
                            : 'Nothing from ${feature.label} in the trash.',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  : LayoutBuilder(
                      builder: (context, constraints) {
                        final compact = constraints.maxWidth < 420;
                        final now = DateTime.now().toUtc();
                        return ListView(
                          children: [
                            for (final item in shown)
                              _row(item, now: now, compact: compact),
                          ],
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        GlassButton(
          dense: true,
          onPressed: () => Navigator.of(context).pop(),
          label: 'Close',
        ),
      ],
    );
  }

  Widget _row(TrashItem item, {required DateTime now, required bool compact}) {
    return ListTile(
      key: ValueKey('trash-${item.kind.collection}-${item.id}'),
      contentPadding: EdgeInsets.zero,
      leading: Icon(trashFeatureIcon(item.kind.feature)),
      title: Text(
        trashItemLabel(item),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(trashItemDetail(item, now)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!compact)
            TextButton(
              onPressed: _busy ? null : () => _restore(item),
              child: const Text('Restore'),
            ),
          PopupMenuButton<_RowAction>(
            enabled: !_busy,
            tooltip: 'More',
            icon: const Icon(PhosphorIconsRegular.dotsThree),
            onSelected: (action) => switch (action) {
              _RowAction.restore => _restore(item),
              _RowAction.erase => _erase(item),
            },
            itemBuilder: (_) => voyagerPopupMenuEntries([
              if (compact)
                (value: _RowAction.restore, child: const Text('Restore')),
              (value: _RowAction.erase, child: const Text('Delete forever…')),
            ]),
          ),
        ],
      ),
    );
  }
}
