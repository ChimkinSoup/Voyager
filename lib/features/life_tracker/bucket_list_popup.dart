import 'dart:async';

import 'package:flutter/material.dart';
import 'package:voyager/core/vim/vim_enabled_scope.dart';
import 'package:voyager/core/vim/vim_text_overlay.dart';
import 'package:voyager/core/vim/vim_text_scope.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/core/widgets/field_scroll_padding.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/voyager_dialog.dart';
import 'package:voyager/domain/models/life_tracker_models.dart';

/// Height one bucket list row occupies (a note pushes it taller, nothing makes
/// it shorter). The empty-state placeholder is pinned to the same number so the
/// popup doesn't visibly shrink the moment the first item replaces it.
const _kRowMinHeight = 48.0;

/// Height of a row's title line — the shared box the completion circle, the
/// title and the delete button are each centred in.
///
/// Sized to give the rename field room above and below its text: at zero
/// content padding the field was exactly one line tall, so selecting the first
/// character drew a highlight flush with the field's edges and spilling past
/// its rounded corners. 30 with 5px of padding still left the highlight
/// touching top and bottom; this and [_kTitleEditorPadding] are set together,
/// and the field's line box has to stay comfortably inside this height.
const _kTitleLineHeight = 36.0;

/// Padding inside the rename field. Horizontal as well as vertical, so a
/// selection that starts at the first character has somewhere to sit rather
/// than bleeding over the field's left edge.
const _kTitleEditorPadding = EdgeInsets.symmetric(horizontal: 6, vertical: 8);

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
  final _newItemFocusNode = FocusNode();
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
    _newItemFocusNode.dispose();
    _editController.dispose();
    _editFocusNode.dispose();
    super.dispose();
  }

  Future<void> _addItem() async {
    final title = _newItemController.text.trim();
    if (title.isEmpty) return;
    final now = utcNow();
    await ref
        .read(bucketListRepositoryProvider)
        .upsertItem(
          BucketListItem(
            id: newId(),
            title: title,
            sortOrder: DateTime.now().millisecondsSinceEpoch,
            createdAt: now,
            updatedAt: now,
          ),
        );
    _newItemController.clear();
    // Submitting a TextField hands focus back to the surrounding scope, which
    // ends the run of "type, Enter, type, Enter" that adding several items in
    // one sitting is made of.
    _newItemFocusNode.requestFocus();
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
      // Three outcomes, and an empty note is not the same as no answer:
      // null means the prompt was skipped or dismissed, which leaves whatever
      // note a previous completion wrote alone; '' means the user saved the
      // field blank, which is how an old note is removed.
      await ref
          .read(bucketListRepositoryProvider)
          .upsertItem(
            item.copyWith(
              completed: true,
              completedAt: utcNow(),
              note: note == null || note.isEmpty ? null : note,
              clearNote: note != null && note.isEmpty,
              updatedAt: utcNow(),
            ),
          );
    } else {
      await ref
          .read(bucketListRepositoryProvider)
          .upsertItem(
            item.copyWith(
              completed: false,
              clearCompletedAt: true,
              updatedAt: utcNow(),
            ),
          );
    }
    ref.invalidate(bucketListItemsProvider);
  }

  /// Returns null when the prompt was skipped or dismissed, and the (trimmed)
  /// note otherwise — including the empty string, which [_toggle] reads as
  /// "remove the note this item already had".
  Future<String?> _promptForNote(BuildContext context) {
    return showVoyagerDialog<String>(
      context: context,
      builder: (context) => const _BucketNoteDialog(),
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
                          color: theme.colorScheme.onSurface.withValues(
                            alpha: 0.6,
                          ),
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
                child: VimTextScope(
                  enabled: VimEnabledScope.of(context) && vimSuitsField(),
                  controller: _newItemController,
                  multiline: false,
                  builder: (context, vim) {
                    final textStyle =
                        theme.textTheme.bodyLarge ?? const TextStyle();
                    const hintText = 'Add something to your bucket list…';
                    return VimOverlayHost(
                      session: vim.session,
              snippetSession: vim.snippetSession,
                      overlayPaintsSelection: vim.overlayPaintsSelection,
                      controller: _newItemController,
                      focusNode: _newItemFocusNode,
                      style: textStyle,
                      accentColor: theme.colorScheme.primary,
                      overlayPadding: vimOverlayPadding(
                        contentPadding: kM3OutlinedDenseContentPadding,
                        density: theme.visualDensity,
                        cursorWidth: vim.overlayCaretWidth,
                        outlineGap: true,
                        outlineCenter: true,
                      ),
                      hintText: hintText,
                      child: TextField(
                        controller: _newItemController,
                        focusNode: _newItemFocusNode,
                        style: textStyle,
                        cursorColor: vim.overlayCaretColor(
                          theme.colorScheme.primary,
                        ),
                        cursorWidth: vim.overlayCaretWidth,
                        undoController: vim.undoController,
                        scrollPadding: kVoyagerFieldScrollPadding,
                        decoration: const InputDecoration(
                          hintText: hintText,
                          isDense: true,
                          contentPadding: kM3OutlinedDenseContentPadding,
                        ),
                        onSubmitted: (_) => _addItem(),
                      ),
                    );
                  },
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
            // Both the circle and the title sit in a box of the same fixed
            // height and are centred in it, so they line up on one axis
            // regardless of which of the two title widgets is showing. The
            // circle used to be nudged down by a hardcoded 3px, which only
            // ever matched the plain Text — swapping in the taller editor
            // pushed the title off it.
            SizedBox(
              height: _kTitleLineHeight,
              child: Center(
                child: GestureDetector(
                  onTap: onToggle,
                  child: _HollowCheckCircle(
                    checked: item.completed,
                    color: accentColor,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              // Tap anywhere in the row's text column to rename in place —
              // the whole width, and the note under the title too, not just
              // the glyphs. A short item like "Skydive" left almost the entire
              // row inert, with the only way in a click on eight characters.
              // The circle to the left still owns completion and the ✕ to the
              // right deletion, so nothing here competes with either.
              child: _TapToEdit(
                enabled: !isEditing,
                onTap: onEdit,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      height: _kTitleLineHeight,
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: isEditing
                            ? _TitleEditor(
                                controller: editController,
                                focusNode: editFocusNode,
                                style: titleStyle,
                                accentColor: accentColor,
                                onSubmit: onSubmitEdit,
                                onCancel: onCancelEdit,
                              )
                            // Inset by the editor's own horizontal padding so
                            // the text doesn't jump sideways the moment the
                            // field swaps in.
                            : Padding(
                                padding: EdgeInsets.only(
                                  left: _kTitleEditorPadding.left,
                                ),
                                child: Text(item.title, style: titleStyle),
                              ),
                      ),
                    ),
                    if (item.note != null && item.note!.isNotEmpty)
                      Padding(
                        // Same left inset the title carries, so the note reads
                        // as hanging off it rather than as a second column. The
                        // title's inset is the rename editor's own horizontal
                        // padding (see above); without matching it here the
                        // note started a few pixels to the left of the words it
                        // belongs to.
                        padding: EdgeInsets.only(
                          top: 2,
                          left: _kTitleEditorPadding.left,
                        ),
                        child: Text(
                          item.note!,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurface.withValues(
                              alpha: 0.55,
                            ),
                            fontStyle: FontStyle.italic,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            SizedBox(
              height: _kTitleLineHeight,
              child: Center(
                child: IconButton(
                  iconSize: 18,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(
                    width: _kTitleLineHeight,
                    height: _kTitleLineHeight,
                  ),
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.close),
                  onPressed: onDelete,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Makes [child] and all the space it is laid out in open the rename editor,
/// and gets out of the way once it is open — a live tap target sitting over a
/// focused text field would steal the click that positions its caret.
class _TapToEdit extends StatelessWidget {
  const _TapToEdit({
    required this.enabled,
    required this.onTap,
    required this.child,
  });

  final bool enabled;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!enabled) return child;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: child,
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
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): onCancel},
      child: VimTextScope(
        enabled: VimEnabledScope.of(context) && vimSuitsField(),
        controller: controller,
        multiline: false,
        accentColor: accentColor,
        builder: (context, vim) {
          final textStyle =
              (style ??
                      Theme.of(context).textTheme.bodyMedium ??
                      const TextStyle())
                  .copyWith(decoration: TextDecoration.none);
          return VimOverlayHost(
            session: vim.session,
              snippetSession: vim.snippetSession,
            overlayPaintsSelection: vim.overlayPaintsSelection,
            controller: controller,
            focusNode: focusNode,
            style: textStyle,
            accentColor: accentColor,
            overlayPadding: vimOverlayPadding(
              contentPadding: _kTitleEditorPadding,
              density: Theme.of(context).visualDensity,
              cursorWidth: vim.overlayCaretWidth,
              outlineGap: true,
              outlineCenter: true,
            ),
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              style: textStyle,
              cursorColor: vim.overlayCaretColor(accentColor),
              cursorWidth: vim.overlayCaretWidth,
              undoController: vim.undoController,
              scrollPadding: kVoyagerFieldScrollPadding,
              decoration: const InputDecoration(
                isDense: true,
                border: InputBorder.none,
                contentPadding: _kTitleEditorPadding,
              ),
              onSubmitted: (_) => onSubmit(),
            ),
          );
        },
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
      child: checked ? Icon(Icons.check, size: 13, color: color) : null,
    );
  }
}

/// Owns controller/focus so Save cannot dispose them during dismiss animation.
class _BucketNoteDialog extends StatefulWidget {
  const _BucketNoteDialog();

  @override
  State<_BucketNoteDialog> createState() => _BucketNoteDialogState();
}

class _BucketNoteDialogState extends State<_BucketNoteDialog> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add a note?'),
      // Room to actually write in: the note is prose about how the thing
      // went, and the old four-line box in a shrink-wrapped dialog gave it
      // barely more space than the one-line title field it sits above.
      content: SizedBox(
        width: 560,
        height: 260,
        child: VimTextScope(
          enabled: VimEnabledScope.of(context) && vimSuitsField(),
          controller: _controller,
          multiline: true,
          builder: (context, vim) {
            final theme = Theme.of(context);
            final textStyle = theme.textTheme.bodyLarge ?? const TextStyle();
            const hintText = 'How did it go? (optional)';
            return VimOverlayHost(
              session: vim.session,
              snippetSession: vim.snippetSession,
              overlayPaintsSelection: vim.overlayPaintsSelection,
              controller: _controller,
              focusNode: _focusNode,
              style: textStyle,
              accentColor: theme.colorScheme.primary,
              overlayPadding: vimOverlayPadding(
                contentPadding: kM3OutlinedContentPadding,
                density: theme.visualDensity,
                cursorWidth: vim.overlayCaretWidth,
                outlineGap: true,
              ),
              hintText: hintText,
              fit: StackFit.expand,
              child: TextField(
                controller: _controller,
                focusNode: _focusNode,
                expands: true,
                maxLines: null,
                minLines: null,
                textAlignVertical: TextAlignVertical.top,
                keyboardType: TextInputType.multiline,
                autofocus: true,
                scrollPadding: kVoyagerFieldScrollPadding,
                cursorColor: vim.overlayCaretColor(theme.colorScheme.primary),
                cursorWidth: vim.overlayCaretWidth,
                undoController: vim.undoController,
                decoration: const InputDecoration(
                  hintText: hintText,
                  contentPadding: kM3OutlinedContentPadding,
                ),
              ),
            );
          },
        ),
      ),
      // Both glass, like every other dialog's action row. Skip was a
      // [TextButton], whose hover overlay reads as a blur smear on top of
      // the dialog's translucent surface rather than as a button lighting up.
      actions: [
        GlassButton(
          dense: true,
          onPressed: () => Navigator.of(context).pop(),
          label: 'Skip',
        ),
        GlassButton(
          dense: true,
          onPressed: () => Navigator.of(context).pop(_controller.text.trim()),
          label: 'Save',
        ),
      ],
    );
  }
}
