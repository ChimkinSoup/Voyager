import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/widgets/voyager_text_field.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/page/gaia_providers.dart';

/// The Gaia page's Queue tab (GAIA_HLD.md §13, §17): each chat's waiting
/// prompts and the global queue, on the desktop and the phone. Drag to
/// reorder, tap to copy, edit or delete; a chat's drain mode is switched
/// here too.
class GaiaQueueTab extends ConsumerWidget {
  const GaiaQueueTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final queue = ref.watch(gaiaQueueProvider).valueOrNull ?? const [];
    final chats = {
      for (final chat in ref.watch(gaiaChatsProvider).valueOrNull ?? const [])
        chat.id: chat,
    };
    final groups = <String?, List<GaiaQueueItem>>{};
    for (final item in queue) {
      // A deleted chat's queue goes with it.
      if (item.chatId != null && !chats.containsKey(item.chatId)) continue;
      (groups[item.chatId] ??= []).add(item);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Prompts waiting their turn. In Gaia, /queue or Ctrl+Q adds the '
          'draft to its chat, and /queue-pop takes the next one back. With '
          'drain on, each goes when the reply before it finishes.',
          style: muted,
        ),
        const SizedBox(height: 12),
        if (groups.isEmpty) Text('Nothing is queued.', style: muted),
        for (final MapEntry(key: chatId, value: items) in groups.entries) ...[
          _QueueGroup(chat: chats[chatId], items: items),
          const SizedBox(height: 16),
        ],
      ],
    );
  }
}

class _QueueGroup extends ConsumerWidget {
  const _QueueGroup({required this.chat, required this.items});

  /// Null for the global queue.
  final GaiaChat? chat;
  final List<GaiaQueueItem> items;

  Future<void> _reorder(WidgetRef ref, int from, int to) async {
    if (to == from) return;
    final moved = [...items];
    final item = moved.removeAt(from);
    moved.insert(to, item);
    final before = to > 0 ? moved[to - 1].order : null;
    final after = to < moved.length - 1 ? moved[to + 1].order : null;
    final order = before == null
        ? after! - 1
        : after == null
        ? before + 1
        : (before + after) / 2;
    await ref
        .read(gaiaRepositoryProvider)
        .upsertQueueItem(item.copyWith(order: order));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final chat = this.chat;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                chat?.title ?? 'Global queue',
                style: theme.textTheme.titleSmall,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (chat != null) ...[
              Text('Drain', style: theme.textTheme.bodySmall),
              Switch(
                value: chat.drain,
                onChanged: (drain) async {
                  final repository = ref.read(gaiaRepositoryProvider);
                  final current = await repository.getChat(chat.id);
                  if (current == null) return;
                  await repository.upsertChat(current.copyWith(drain: drain));
                },
              ),
            ],
          ],
        ),
        ReorderableListView(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          buildDefaultDragHandles: false,
          onReorderItem: (from, to) => unawaited(_reorder(ref, from, to)),
          children: [
            for (final (i, item) in items.indexed)
              ListTile(
                key: ValueKey(item.id),
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: ReorderableDragStartListener(
                  index: i,
                  child: const Icon(PhosphorIconsRegular.dotsSixVertical),
                ),
                title: Text(
                  item.text,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () async {
                  await Clipboard.setData(ClipboardData(text: item.text));
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(const SnackBar(content: Text('Copied')));
                },
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: 'Edit',
                      icon: const Icon(
                        PhosphorIconsRegular.pencilSimple,
                        size: 16,
                      ),
                      onPressed: () => _edit(context, ref, item),
                    ),
                    IconButton(
                      tooltip: 'Delete',
                      icon: const Icon(PhosphorIconsRegular.trash, size: 16),
                      onPressed: () => ref
                          .read(gaiaRepositoryProvider)
                          .upsertQueueItem(
                            item.copyWith(deletedAt: DateTime.now().toUtc()),
                          ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ],
    );
  }

  Future<void> _edit(
    BuildContext context,
    WidgetRef ref,
    GaiaQueueItem item,
  ) async {
    final controller = TextEditingController(text: item.text);
    final text = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Edit queued prompt'),
        content: SizedBox(
          width: 480,
          child: VoyagerTextField(
            controller: controller,
            autofocus: true,
            minLines: 2,
            maxLines: 8,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (text == null || text.isEmpty || text == item.text) return;
    await ref
        .read(gaiaRepositoryProvider)
        .upsertQueueItem(item.copyWith(text: text));
  }
}
