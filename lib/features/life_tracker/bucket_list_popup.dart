import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/core/widgets/voyager_dialog.dart';
import 'package:voyager/domain/models/life_tracker_models.dart';

/// Height one bucket list row occupies (a note pushes it taller, nothing makes
/// it shorter). The empty-state placeholder is pinned to the same number so the
/// popup doesn't visibly shrink the moment the first item replaces it.
const _kRowMinHeight = 48.0;

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
  final _editController = TextEditingController();
  final _editFocusNode = FocusNode();

  /// Id of the item whose title is currently being edited in place, if any.
  String? _editingId;

  @override
  void initState() {
    super.initState();
    // Clicking away from an open editor commits it, the same as pressing
    // Enter would — an abandoned edit that silently reverts reads as data loss.
    _editFocusNode.addListener(() {
      if (!_editFocusNode.hasFocus && _editingId != null) {
        unawaited(_commitEdit());
      }
    });
  }

  @override
  void dispose() {
    _newItemController.dispose();
    _editController.dispose();
    _editFocusNode.dispose();
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

  void _startEdit(BucketListItem item) {
    setState(() {
      _editingId = item.id;
      _editController.text = item.title;
      _editController.selection = TextSelection(
        baseOffset: 0,
        extentOffset: item.title.length,
      );
    });
    _editFocusNode.requestFocus();
  }

  Future<void> _commitEdit() async {
    final id = _editingId;
    if (id == null) return;
    final title = _editController.text.trim();
    setState(() => _editingId = null);

    final items = ref.read(bucketListItemsProvider).valueOrNull;
    final item = items?.where((i) => i.id == id).firstOrNull;
    // An empty title would leave a blank row with no way back into it, so
    // treat clearing the field as "no change" rather than as a rename.
    if (item == null || title.isEmpty || title == item.title) return;

    await ref
        .read(bucketListRepositoryProvider)
        .upsertItem(item.copyWith(title: title, updatedAt: utcNow()));
    ref.invalidate(bucketListItemsProvider);
  }

  void _cancelEdit() => setState(() => _editingId = null);

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
    return showVoyagerDialog<String>(
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
    if (_editingId == id) setState(() => _editingId = null);
    await ref.read(bucketListRepositoryProvider).deleteItem(id);
    ref.invalidate(bucketListItemsProvider);
  }

  @override
  Widget build(BuildContext context) {
    final itemsAsync = ref.watch(bucketListItemsProvider);
    final theme = Theme.of(context);
    final items = itemsAsync.valueOrNull ?? const <BucketListItem>[];
    final done = items.where((i) => i.completed).length;

    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('Bucket List', style: theme.textTheme.titleMedium),
              const Spacer(),
              if (items.isNotEmpty)
                Text(
                  '$done of ${items.length} done',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.65),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Flexible(
            child: itemsAsync.when(
              data: (items) {
                if (items.isEmpty) {
                  return SizedBox(
                    height: _kRowMinHeight,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Nothing here yet — add something worth doing.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                        ),
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
                      onEdit: () => _startEdit(item),
                      isEditing: _editingId == item.id,
                      editController: _editController,
                      editFocusNode: _editFocusNode,
                      onSubmitEdit: () => unawaited(_commitEdit()),
                      onCancelEdit: _cancelEdit,
                    );
                  },
                );
              },
              loading: () => const SizedBox(
                height: _kRowMinHeight,
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
    required this.onEdit,
    required this.isEditing,
    required this.editController,
    required this.editFocusNode,
    required this.onSubmitEdit,
    required this.onCancelEdit,
  });

  final BucketListItem item;
  final Color accentColor;
  final VoidCallback onToggle;
  final VoidCallback onDelete;
  final VoidCallback onEdit;
  final bool isEditing;
  final TextEditingController editController;
  final FocusNode editFocusNode;
  final VoidCallback onSubmitEdit;
  final VoidCallback onCancelEdit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final titleStyle = theme.textTheme.bodyMedium?.copyWith(
      decoration: item.completed ? TextDecoration.lineThrough : null,
      color: item.completed
          ? theme.colorScheme.onSurface.withValues(alpha: 0.5)
          : null,
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: _kRowMinHeight - 8),
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
                  if (isEditing)
                    _TitleEditor(
                      controller: editController,
                      focusNode: editFocusNode,
                      style: titleStyle,
                      accentColor: accentColor,
                      onSubmit: onSubmitEdit,
                      onCancel: onCancelEdit,
                    )
                  else
                    // Tap the title to rename in place; the circle to the left
                    // still owns completion, so the two don't compete.
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: onEdit,
                      child: Text(item.title, style: titleStyle),
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
      ),
    );
  }
}

/// The in-place rename field. Enter commits, Escape backs out; losing focus
/// commits too (see the listener in [_BucketListPopupState.initState]).
class _TitleEditor extends StatelessWidget {
  const _TitleEditor({
    required this.controller,
    required this.focusNode,
    required this.style,
    required this.accentColor,
    required this.onSubmit,
    required this.onCancel,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final TextStyle? style;
  final Color accentColor;
  final VoidCallback onSubmit;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): onCancel,
      },
      child: TextField(
        controller: controller,
        focusNode: focusNode,
        style: style?.copyWith(decoration: TextDecoration.none),
        cursorColor: accentColor,
        decoration: const InputDecoration(
          isDense: true,
          border: InputBorder.none,
          contentPadding: EdgeInsets.zero,
        ),
        onSubmitted: (_) => onSubmit(),
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
