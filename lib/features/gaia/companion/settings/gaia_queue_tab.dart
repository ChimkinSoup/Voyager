import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/companion/gaia_action_icon.dart';
import 'package:voyager/features/gaia/companion/gaia_card_text_field.dart';
import 'package:voyager/features/gaia/companion/gaia_controller.dart';
import 'package:voyager/features/gaia/companion/gaia_settings_panel.dart';
import 'package:voyager/features/gaia/companion/gaia_style.dart';
import 'package:voyager/features/gaia/companion/gaia_toast.dart';

/// The settings panel's Queue tab (GAIA_SETTINGS_HLD.md §4): each chat's
/// waiting prompts and the global queue, as the Gaia page shows them
/// (GAIA_HLD.md §13). Click a prompt to edit it, drag its handle to reorder
/// it within its chat; copy and delete show on hover. A chat's drain mode
/// is switched here too.
class GaiaQueueTab extends StatelessWidget {
  const GaiaQueueTab({super.key, required this.controller});

  final GaiaController controller;

  @override
  Widget build(BuildContext context) {
    final chats = {for (final chat in controller.chats) chat.id: chat};
    final groups = <String?, List<GaiaQueueItem>>{};
    for (final item in controller.queue) {
      // A deleted chat's queue goes with it.
      if (item.chatId != null && !chats.containsKey(item.chatId)) continue;
      (groups[item.chatId] ??= []).add(item);
    }
    final muted = GaiaType.row.copyWith(color: GaiaInk.muted);
    return GaiaPanelScroll(
      key: const PageStorageKey('gaia panel queue'),
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
            child: Text(
              'Prompts waiting their turn. /queue or Ctrl+Q adds the draft to '
              'its chat, and /queue-pop takes the next one back. With drain '
              'on, each goes when the reply before it finishes.',
              style: muted,
            ),
          ),
        ),
        if (groups.isEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Text('Nothing is queued.', style: muted),
            ),
          ),
        for (final MapEntry(key: chatId, value: items) in groups.entries)
          _QueueGroup(
            key: ValueKey(chatId),
            controller: controller,
            chat: chats[chatId],
            items: items,
          ),
      ],
    );
  }
}

class _QueueGroup extends StatelessWidget {
  const _QueueGroup({
    super.key,
    required this.controller,
    required this.chat,
    required this.items,
  });

  final GaiaController controller;

  /// Null for the global queue.
  final GaiaChat? chat;
  final List<GaiaQueueItem> items;

  void _reorder(int from, int to) {
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
    unawaited(controller.reorderQueued(item.id, order));
  }

  @override
  Widget build(BuildContext context) {
    final chat = this.chat;
    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(
          child: GaiaPanelHeading(
            chat?.title ?? 'Global queue',
            trailing: chat == null
                ? null
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Drain',
                        style: GaiaType.label.copyWith(color: GaiaInk.muted),
                      ),
                      Transform.scale(
                        scale: 0.75,
                        child: Switch(
                          value: chat.drain,
                          onChanged: (drain) =>
                              controller.setChatDrain(chat.id, drain),
                        ),
                      ),
                    ],
                  ),
          ),
        ),
        SliverReorderableList(
          itemCount: items.length,
          onReorderItem: _reorder,
          proxyDecorator: (child, index, animation) => Material(
            color: Theme.of(context).scaffoldBackgroundColor,
            borderRadius: BorderRadius.circular(GaiaRadius.row),
            child: child,
          ),
          itemBuilder: (context, i) => _QueueRow(
            key: ValueKey(items[i].id),
            controller: controller,
            item: items[i],
            index: i,
          ),
        ),
      ],
    );
  }
}

class _QueueRow extends StatefulWidget {
  const _QueueRow({
    super.key,
    required this.controller,
    required this.item,
    required this.index,
  });

  final GaiaController controller;
  final GaiaQueueItem item;
  final int index;

  @override
  State<_QueueRow> createState() => _QueueRowState();
}

class _QueueRowState extends State<_QueueRow> {
  var _hovered = false;

  /// The text being edited in place; null when not editing.
  TextEditingController? _editing;
  final _editFocus = FocusNode(debugLabel: 'gaia queue edit');

  @override
  void dispose() {
    _editing?.dispose();
    _editFocus.dispose();
    super.dispose();
  }

  void _startEdit() {
    setState(
      () => _editing = TextEditingController(text: widget.item.text)
        ..selection = TextSelection.collapsed(offset: widget.item.text.length),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _editFocus.requestFocus();
    });
  }

  /// Ends the edit, with [save] the text kept unless it's empty or the same.
  void _endEdit({required bool save}) {
    final text = _editing?.text.trim() ?? '';
    final editing = _editing;
    setState(() => _editing = null);
    // After the field it's attached to is gone.
    WidgetsBinding.instance.addPostFrameCallback((_) => editing?.dispose());
    if (save && text.isNotEmpty && text != widget.item.text) {
      unawaited(widget.controller.editQueued(widget.item.id, text));
    }
  }

  /// Enter saves (Shift+Enter is a newline), Esc cancels.
  KeyEventResult _onEditKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      _endEdit(save: false);
      return KeyEventResult.handled;
    }
    if ((event.logicalKey == LogicalKeyboardKey.enter ||
            event.logicalKey == LogicalKeyboardKey.numpadEnter) &&
        !HardwareKeyboard.instance.isShiftPressed) {
      _endEdit(save: true);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final editing = _editing;
    final shown = _hovered && editing == null;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedContainer(
        duration: GaiaMotion.quick,
        margin: const EdgeInsets.only(bottom: 2),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        decoration: BoxDecoration(
          color: _hovered ? GaiaInk.hover : GaiaInk.hover.withValues(alpha: 0),
          borderRadius: BorderRadius.circular(GaiaRadius.row),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ReorderableDragStartListener(
              index: widget.index,
              enabled: editing == null,
              child: MouseRegion(
                cursor: SystemMouseCursors.grab,
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: Icon(
                    Icons.drag_indicator,
                    size: 16,
                    color: _hovered ? GaiaInk.muted : GaiaInk.faint,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: editing != null
                  ? Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Focus(
                        onKeyEvent: _onEditKey,
                        onFocusChange: (focused) {
                          // A click away keeps what was typed.
                          if (!focused && _editing == editing) {
                            _endEdit(save: true);
                          }
                        },
                        child: GaiaCardTextField(
                          controller: editing,
                          focusNode: _editFocus,
                          maxLines: 8,
                          style: GaiaType.row.copyWith(color: GaiaInk.bright),
                        ),
                      ),
                    )
                  : MouseRegion(
                      cursor: SystemMouseCursors.text,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: _startEdit,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Text(
                            widget.item.text,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: GaiaType.row.copyWith(
                              color: _hovered ? GaiaInk.bright : GaiaInk.dim,
                            ),
                          ),
                        ),
                      ),
                    ),
            ),
            const SizedBox(width: 4),
            AnimatedOpacity(
              duration: GaiaMotion.quick,
              opacity: shown ? 1 : 0,
              child: IgnorePointer(
                ignoring: !shown,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    GaiaActionIcon(
                      label: 'Copy',
                      icon: Icons.copy,
                      compact: true,
                      onPressed: () async {
                        await Clipboard.setData(
                          ClipboardData(text: widget.item.text),
                        );
                        if (!context.mounted) return;
                        showGaiaToast(
                          context,
                          mark: GaiaToastMark.done,
                          title: 'Copied',
                          body: 'The prompt is on the clipboard.',
                        );
                      },
                    ),
                    GaiaActionIcon(
                      label: 'Delete',
                      icon: Icons.delete_outline,
                      compact: true,
                      onPressed: () =>
                          widget.controller.deleteQueued(widget.item.id),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
