import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/soft_delete/soft_delete_toast.dart';
import 'package:voyager/core/widgets/confirm_dialog.dart';
import 'package:voyager/core/widgets/context_menu.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/selector_pill.dart';
import 'package:voyager/core/widgets/voyager_dialog.dart';
import 'package:voyager/core/widgets/voyager_toast.dart';
import 'package:voyager/features/trash/trash_item_detail.dart';
import 'package:voyager/features/trash/trash_kinds.dart';
import 'package:voyager/features/trash/trash_labels.dart';
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
            : 'Restore ${blocked.parentNoun} "${cappedTrashTitle(parentTitle)}" '
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
            GlassButton(
              dense: true,
              enabled: !_busy,
              onPressed: () => _empty(shown),
              icon: const Icon(PhosphorIconsRegular.trash, size: 18),
              label: feature == null
                  ? 'Empty trash'
                  : 'Empty ${feature.label} trash',
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
                    SelectorPill(
                      label: 'All',
                      isActive: feature == null,
                      fillWhenActive: true,
                      onTap: () => setState(() => _feature = null),
                    ),
                    for (final option in TrashFeature.values)
                      if (features.contains(option) || option == feature)
                        SelectorPill(
                          icon: trashFeatureIcon(option),
                          label: option.label,
                          isActive: option == feature,
                          fillWhenActive: true,
                          onTap: () => setState(() => _feature = option),
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
      contentPadding: const EdgeInsets.symmetric(horizontal: 12),
      leading: Icon(trashFeatureIcon(item.kind.feature)),
      title: Text(
        trashItemLabel(item),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(trashItemDetail(item, now)),
      onTap: () => showTrashItemDetail(
        context,
        item,
        onRestore: _busy ? null : () => _restore(item),
        onErase: _busy ? null : () => _erase(item),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!compact) ...[
            GlassButton(
              dense: true,
              enabled: !_busy,
              onPressed: () => _restore(item),
              label: 'Restore',
            ),
            const SizedBox(width: 8),
          ],
          _RowMenu(
            enabled: !_busy,
            items: [
              // Disabled too, not just the button: right-click still opens
              // the region while a restore or erase is running.
              if (compact)
                ContextMenuItem(
                  label: 'Restore',
                  icon: PhosphorIconsRegular.arrowCounterClockwise,
                  enabled: !_busy,
                  onTap: () => _restore(item),
                ),
              ContextMenuItem(
                label: 'Delete forever…',
                icon: PhosphorIconsRegular.trash,
                isDestructive: true,
                enabled: !_busy,
                onTap: () => _erase(item),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// A row's "⋯" button, opening the app's glass menu under itself.
class _RowMenu extends StatefulWidget {
  const _RowMenu({required this.enabled, required this.items});

  final bool enabled;
  final List<ContextMenuItem> items;

  @override
  State<_RowMenu> createState() => _RowMenuState();
}

class _RowMenuState extends State<_RowMenu> {
  final _menuKey = GlobalKey<ContextMenuRegionState>();

  void _open() {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return;
    _menuKey.currentState?.openMenuAt(
      box.localToGlobal(box.size.bottomLeft(Offset.zero)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ContextMenuRegion(
      key: _menuKey,
      items: widget.items,
      child: GlassButton(
        dense: true,
        enabled: widget.enabled,
        tooltip: 'More',
        onPressed: _open,
        icon: const Icon(PhosphorIconsRegular.dotsThree, size: 18),
      ),
    );
  }
}
