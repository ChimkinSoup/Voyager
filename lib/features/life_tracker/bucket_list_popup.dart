import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/domain/models/life_tracker_models.dart';

/// Popup content for the swing's bubble: a bucket list that behaves like a
/// to-do list but with hollow-circle completions, no due dates or subtasks,
/// and an optional background note once a task is marked off.
class BucketListPopup extends ConsumerStatefulWidget {
  const BucketListPopup({super.key, required this.accentColor});

  final Color accentColor;

  @override
  ConsumerState<BucketListPopup> createState() => _BucketListPopupState();
}

class _BucketListPopupState extends ConsumerState<BucketListPopup> {
  final _newItemController = TextEditingController();

  @override
  void dispose() {
    _newItemController.dispose();
    super.dispose();
  }

  Future<void> _addItem() async {
    final title = _newItemController.text.trim();
    if (title.isEmpty) return;
    final now = utcNow();
    await ref.read(bucketListRepositoryProvider).upsertItem(
      BucketListItem(
        id: newId(),
        title: title,
        sortOrder: DateTime.now().millisecondsSinceEpoch,
        createdAt: now,
        updatedAt: now,
      ),
    );
    _newItemController.clear();
    ref.invalidate(bucketListItemsProvider);
  }

  Future<void> _toggle(BucketListItem item) async {
    if (!item.completed) {
      final note = await _promptForNote(context);
      if (!mounted) return;
      await ref.read(bucketListRepositoryProvider).upsertItem(
        item.copyWith(
          completed: true,
          completedAt: utcNow(),
          note: note?.isNotEmpty == true ? note : item.note,
          updatedAt: utcNow(),
        ),
      );
    } else {
      await ref.read(bucketListRepositoryProvider).upsertItem(
        item.copyWith(completed: false, clearCompletedAt: true, updatedAt: utcNow()),
      );
    }
    ref.invalidate(bucketListItemsProvider);
  }

  Future<String?> _promptForNote(BuildContext context) {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add a note?'),
        content: TextField(
          controller: controller,
          maxLines: 4,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'How did it go? (optional)',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Skip'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Future<void> _deleteItem(String id) async {
    await ref.read(bucketListRepositoryProvider).deleteItem(id);
    ref.invalidate(bucketListItemsProvider);
  }

  @override
  Widget build(BuildContext context) {
    final itemsAsync = ref.watch(bucketListItemsProvider);
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Bucket List', style: theme.textTheme.titleMedium),
          const SizedBox(height: 10),
          Flexible(
            child: itemsAsync.when(
              data: (items) {
                if (items.isEmpty) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Text(
                      'Nothing here yet — add something worth doing.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                      ),
                    ),
                  );
                }
                return ListView.builder(
                  shrinkWrap: true,
                  itemCount: items.length,
                  itemBuilder: (context, index) {
                    final item = items[index];
                    return _BucketListRow(
                      item: item,
                      accentColor: widget.accentColor,
                      onToggle: () => _toggle(item),
                      onDelete: () => _deleteItem(item.id),
                    );
                  },
                );
              },
              loading: () => const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (e, _) => Text('Couldn\'t load bucket list: $e'),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _newItemController,
                  decoration: const InputDecoration(
                    hintText: 'Add something to your bucket list…',
                    isDense: true,
                  ),
                  onSubmitted: (_) => _addItem(),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(icon: const Icon(Icons.add), onPressed: _addItem),
            ],
          ),
        ],
      ),
    );
  }
}

class _BucketListRow extends StatelessWidget {
  const _BucketListRow({
    required this.item,
    required this.accentColor,
    required this.onToggle,
    required this.onDelete,
  });

  final BucketListItem item;
  final Color accentColor;
  final VoidCallback onToggle;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onTap: onToggle,
            child: Padding(
              padding: const EdgeInsets.only(top: 3),
              child: _HollowCheckCircle(checked: item.completed, color: accentColor),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.title,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    decoration: item.completed ? TextDecoration.lineThrough : null,
                    color: item.completed
                        ? theme.colorScheme.onSurface.withValues(alpha: 0.5)
                        : null,
                  ),
                ),
                if (item.note != null && item.note!.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      item.note!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurface.withValues(alpha: 0.55),
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          IconButton(
            iconSize: 18,
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.close),
            onPressed: onDelete,
          ),
        ],
      ),
    );
  }
}

class _HollowCheckCircle extends StatelessWidget {
  const _HollowCheckCircle({required this.checked, required this.color});

  final bool checked;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      width: 20,
      height: 20,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: checked ? color.withValues(alpha: 0.18) : Colors.transparent,
        border: Border.all(color: color.withValues(alpha: 0.85), width: 2),
      ),
      child: checked
          ? Icon(Icons.check, size: 13, color: color)
          : null,
    );
  }
}
