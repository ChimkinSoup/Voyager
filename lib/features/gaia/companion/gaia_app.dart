import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:super_clipboard/super_clipboard.dart';
import 'package:voyager/core/media/media_clipboard.dart';
import 'package:voyager/core/media/widgets/media_paste_scope.dart';
import 'package:voyager/core/platform/windows_folder_picker.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/features/gaia/adapters/gaia_agent_runner.dart';
import 'package:voyager/features/gaia/adapters/gaia_clis.dart';
import 'package:voyager/features/gaia/companion/gaia_button.dart';
import 'package:voyager/features/gaia/companion/gaia_commands.dart';
import 'package:voyager/features/dev/dev_fps_counter_tile.dart';
import 'package:voyager/features/gaia/companion/gaia_controller.dart';
import 'package:voyager/features/gaia/companion/gaia_crop_overlay.dart';
import 'package:voyager/features/gaia/companion/gaia_debug_menu.dart';
import 'package:voyager/features/gaia/companion/gaia_file_card.dart';
import 'package:voyager/features/gaia/companion/gaia_activity_chip.dart';
import 'package:voyager/features/gaia/companion/gaia_appear.dart';
import 'package:voyager/features/gaia/companion/gaia_attachments.dart';
import 'package:voyager/features/gaia/companion/gaia_image_editor.dart';
import 'package:voyager/features/gaia/companion/gaia_image_thumb.dart';
import 'package:voyager/features/gaia/companion/gaia_lightbox.dart';
import 'package:voyager/features/gaia/companion/gaia_notch.dart';
import 'package:voyager/features/gaia/companion/gaia_orb.dart';
import 'package:voyager/features/gaia/companion/gaia_orb_materials.dart';
import 'package:voyager/features/gaia/companion/gaia_tier_glyph.dart';
import 'package:voyager/features/gaia/companion/gaia_sidebar.dart';
import 'package:voyager/features/gaia/companion/gaia_spinner.dart';
import 'package:voyager/features/gaia/companion/gaia_starfield.dart';
import 'package:voyager/features/gaia/companion/gaia_tier_commands.dart';
import 'package:voyager/features/gaia/companion/gaia_text_field.dart';
import 'package:voyager/features/gaia/companion/gaia_toast.dart';
import 'package:voyager/features/gaia/companion/gaia_vanish.dart';
import 'package:voyager/features/gaia/companion/gaia_window.dart';
import 'package:voyager/features/gaia/gaia_keybinds.dart';
import 'package:voyager/features/gaia/gaia_pipe.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/domain/services/media_ingest.dart';
import 'package:window_manager/window_manager.dart';

/// The companion's UI (GAIA_HLD.md §3.3): the small floater shows the last
/// few turns, the large one the whole chat, and the Gaia window adds a chat
/// sidebar.
class GaiaApp extends StatelessWidget {
  const GaiaApp({super.key, required this.controller});

  final GaiaController controller;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: controller.onScreen,
      builder: (context, onScreen, child) =>
          TickerMode(enabled: onScreen, child: child!),
      child: _Ambient(
        focused: controller.focused,
        child: ValueListenableBuilder(
          valueListenable: controller.accent,
          builder: (context, accent, _) => MaterialApp(
            title: 'Gaia',
            debugShowCheckedModeBanner: false,
            theme: _onGaiaSurface(Color(accent)),
            home: _RunToasts(
              controller: controller,
              child: ListenableBuilder(
                listenable: Listenable.merge([controller, controller.debug]),
                builder: (context, _) => _GaiaShell(controller: controller),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Voyager's dark theme with [accent], on Gaia's own surface tinted by it.
  static ThemeData _onGaiaSurface(Color accent) {
    final theme = VoyagerTheme.dark(accent: accent);
    final surface = gaiaSurface(accent);
    return theme.copyWith(
      scaffoldBackgroundColor: surface,
      canvasColor: surface,
      colorScheme: theme.colorScheme.copyWith(surface: surface),
      dialogTheme: theme.dialogTheme.copyWith(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
      ),
    );
  }
}

/// Provides [GaiaAmbient]: running while Gaia is [focused] and the cursor is
/// in its window. Above the app, so dialogs and toasts count as in it.
class _Ambient extends StatefulWidget {
  const _Ambient({required this.focused, required this.child});

  final ValueNotifier<bool> focused;
  final Widget child;

  @override
  State<_Ambient> createState() => _AmbientState();
}

class _AmbientState extends State<_Ambient> {
  var _pointerIn = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _pointerIn = true),
      onExit: (_) => setState(() => _pointerIn = false),
      child: ValueListenableBuilder(
        valueListenable: widget.focused,
        builder: (context, focused, child) => GaiaAmbient(
          running:
              focused &&
              _pointerIn &&
              !(MediaQuery.maybeDisableAnimationsOf(context) ?? false),
          child: child!,
        ),
        child: widget.child,
      ),
    );
  }
}

/// Shows Gaia's toast for each run the controller says finished while Gaia
/// was on screen. Clicked, it opens that chat.
class _RunToasts extends StatefulWidget {
  const _RunToasts({required this.controller, required this.child});

  final GaiaController controller;
  final Widget child;

  @override
  State<_RunToasts> createState() => _RunToastsState();
}

class _RunToastsState extends State<_RunToasts> {
  late final StreamSubscription<GaiaRunToast> _toasts;

  @override
  void initState() {
    super.initState();
    _toasts = widget.controller.toasts.listen(_show);
  }

  @override
  void dispose() {
    unawaited(_toasts.cancel());
    super.dispose();
  }

  void _show(GaiaRunToast toast) {
    if (!mounted) return;
    showGaiaToast(
      context,
      mark: toast.error
          ? GaiaToastMark.error
          : toast.question
          ? GaiaToastMark.question
          : GaiaToastMark.done,
      title: toast.title,
      body: toast.body,
      onTap: toast.chatId.isEmpty
          ? null
          : () => widget.controller.selectChat(toast.chatId),
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _GaiaShell extends StatelessWidget {
  const _GaiaShell({required this.controller});

  final GaiaController controller;

  @override
  Widget build(BuildContext context) {
    if (controller.cropping case final capture?
        when controller.layout == GaiaMode.overlay) {
      // A Material for its hint's text style, as the chat's Scaffold gives.
      return Material(
        type: MaterialType.transparency,
        child: GaiaCropOverlay(
          key: ValueKey(capture.path),
          path: capture.path,
          pixelWidth: capture.frame.width,
          onDone: controller.finishCrop,
        ),
      );
    }
    if (controller.layout == GaiaMode.pickUp) {
      return _PickUpPill(controller: controller);
    }
    final floater = controller.layout != GaiaMode.window;
    Widget chat({bool sidebarShown = false, VoidCallback? toggleSidebar}) =>
        Column(
          children: [
            _Header(
              controller: controller,
              sidebarShown: sidebarShown,
              toggleSidebar: toggleSidebar,
            ),
            const Divider(height: 1),
            Expanded(
              child: _Messages(
                messages: controller.layout == GaiaMode.small
                    ? _lastTurns(controller.messages, 3)
                    : controller.messages,
                imageFile: controller.imageFile,
                uploading: controller.uploadingImages,
                tier: controller.nextTier,
                running: controller.currentRunning,
                onEdit: (message) => _editMessage(context, controller, message),
                onAttach: controller.attachMessage,
              ),
            ),
            _Composer(controller: controller),
          ],
        );
    return CallbackShortcuts(
      bindings: {
        if (floater)
          const SingleActivator(LogicalKeyboardKey.escape): () =>
              controller.dismiss(),
        const SingleActivator(
          LogicalKeyboardKey.keyD,
          control: true,
          shift: true,
        ): () =>
            showGaiaDebugMenu(context, controller),
      },
      child: Scaffold(
        body: Stack(
          children: [
            // Behind the whole window, so the sidebar coming, going or
            // resizing covers stars rather than moving them.
            Positioned.fill(
              child: GaiaStarfield(
                active: controller.focused,
                child: floater
                    ? chat()
                    : GaiaSidebarLayout(
                        sidebar: controller.sidebar,
                        // A Material, which the sidebar's buttons paint
                        // their ink on.
                        side: Material(
                          color: Theme.of(context).scaffoldBackgroundColor,
                          child: _Sidebar(controller: controller),
                        ),
                        chat: (shown, toggle) =>
                            chat(sidebarShown: shown, toggleSidebar: toggle),
                      ),
              ),
            ),
            if (controller.debug.showFps)
              Positioned(
                // Above the composer, clear of the toasts below the header.
                bottom: 102,
                right: 12,
                child: IgnorePointer(
                  child: FpsCounterCard(monitor: controller.debug.fps),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// The messages from the [turns]th-last user message on.
  static List<GaiaMessage> _lastTurns(List<GaiaMessage> messages, int turns) {
    var seen = 0;
    for (var i = messages.length - 1; i >= 0; i--) {
      if (messages[i].role == GaiaMessageRole.user && ++seen == turns) {
        return messages.sublist(i);
      }
    }
    return messages;
  }
}

/// Pick-up mode's indicator (§15.3), at the top of the screen while the
/// user selects something: F again takes it, Esc or the button cancels.
class _PickUpPill extends StatelessWidget {
  const _PickUpPill({required this.controller});

  final GaiaController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final combo = gaiaComboFor(GaiaKeybind.pickUp, controller.keybinds);
    return Scaffold(
      body: DragToMoveArea(
        child: Row(
          children: [
            const SizedBox(width: 14),
            const GaiaSpinner(size: 20, label: 'Picking up'),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                combo.isEmpty
                    ? 'Selecting… press pick-up again, or Esc'
                    : 'Selecting… press $combo to bring it to Gaia',
                style: theme.textTheme.bodySmall,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            IconButton(
              tooltip: 'Cancel (Esc)',
              icon: const Icon(Icons.close, size: 16),
              onPressed: controller.cancelPickUp,
            ),
            const SizedBox(width: 4),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.controller,
    required this.sidebarShown,
    required this.toggleSidebar,
  });

  final GaiaController controller;
  final bool sidebarShown;

  /// Null in the floaters, which have no sidebar.
  final VoidCallback? toggleSidebar;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // The CLI the next message runs on.
    final adapter = controller.agentFor(controller.nextTier)?.adapter;
    final cli = kGaiaClis[adapter];
    final version = controller.cliVersions[adapter];
    final chip = !controller.cliChecked || cli == null
        ? null
        : version == null
        ? '${cli.name} not found'
        : isVersionInRange(version, cli.tested)
        ? null
        : 'Untested ${cli.name} ${version.$1}.${version.$2}.${version.$3}';
    final floater = controller.layout != GaiaMode.window;
    return DragToMoveArea(
      child: SizedBox(
        // Room for the round buttons' shadows.
        height: 52,
        child: Row(
          children: [
            if (toggleSidebar case final toggle?) ...[
              const SizedBox(width: 12),
              GaiaButton(
                icon: Icons.view_sidebar_outlined,
                size: 32,
                onPressed: toggle,
              ),
              const SizedBox(width: 10),
            ] else
              const SizedBox(width: 16),
            Expanded(
              child: Text(
                controller.currentChat?.title ?? 'New chat',
                style: theme.textTheme.titleSmall,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (chip != null) ...[
              Chip(
                label: Text(chip),
                visualDensity: VisualDensity.compact,
                labelStyle: theme.textTheme.labelSmall,
              ),
              const SizedBox(width: 4),
            ],
            // The sidebar's New chat, when there's no sidebar.
            if (!sidebarShown) ...[
              GaiaButton(
                icon: Icons.add,
                size: 32,
                onPressed: controller.newChat,
              ),
              const SizedBox(width: 10),
            ],
            if (floater) ...[
              GaiaButton(
                icon: Icons.open_in_full,
                size: 32,
                onPressed: controller.openWindow,
              ),
              const SizedBox(width: 10),
            ],
            if (!floater) const _WindowButtons(),
            GaiaButton(
              icon: Icons.close,
              size: 32,
              onPressed: controller.dismiss,
            ),
            const SizedBox(width: 12),
          ],
        ),
      ),
    );
  }
}

/// The Gaia window's Minimize and Maximize or Restore, beside its close.
/// The floaters have neither.
class _WindowButtons extends StatefulWidget {
  const _WindowButtons();

  @override
  State<_WindowButtons> createState() => _WindowButtonsState();
}

class _WindowButtonsState extends State<_WindowButtons> with WindowListener {
  var _maximized = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    windowManager.isMaximized().then((maximized) {
      if (mounted) setState(() => _maximized = maximized);
    });
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowMaximize() => setState(() => _maximized = true);

  @override
  void onWindowUnmaximize() => setState(() => _maximized = false);

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        GaiaButton(
          icon: Icons.remove,
          size: 32,
          onPressed: windowManager.minimize,
        ),
        const SizedBox(width: 10),
        GaiaButton(
          icon: _maximized ? Icons.filter_none : Icons.crop_square,
          size: 32,
          onPressed: _maximized
              ? windowManager.unmaximize
              : windowManager.maximize,
        ),
        const SizedBox(width: 10),
      ],
    );
  }
}

class _Sidebar extends StatefulWidget {
  const _Sidebar({required this.controller});

  final GaiaController controller;

  @override
  State<_Sidebar> createState() => _SidebarState();
}

class _SidebarState extends State<_Sidebar> {
  /// Each chat's tile as last built. Every change to Gaia rebuilds the
  /// sidebar, and its tiles are costly to build: one whose chat, selection
  /// and spinner haven't changed is given back as it was, which Flutter
  /// skips.
  final _tiles =
      <String, ({GaiaChat chat, bool selected, bool running, Widget tile})>{};

  /// The chat being renamed in its tile, and its field.
  String? _renaming;
  final _rename = TextEditingController();
  final _renameFocus = FocusNode();

  @override
  void didUpdateWidget(_Sidebar old) {
    super.didUpdateWidget(old);
    // The tiles' taps go to the controller they were built with.
    if (widget.controller != old.controller) _tiles.clear();
  }

  @override
  void dispose() {
    _rename.dispose();
    _renameFocus.dispose();
    super.dispose();
  }

  void _startRename(GaiaChat chat) {
    _rename.value = TextEditingValue(
      text: chat.title,
      selection: TextSelection(baseOffset: 0, extentOffset: chat.title.length),
    );
    setState(() => _renaming = chat.id);
    // Asked for, not autofocused: the composer, or the menu's giving it
    // back, has the scope's focus already.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _renaming == chat.id) _renameFocus.requestFocus();
    });
  }

  /// Enter or a click away keeps the new name; Esc doesn't.
  void _endRename({required bool keep}) {
    final chatId = _renaming;
    if (chatId == null) return;
    setState(() => _renaming = null);
    if (keep) {
      unawaited(widget.controller.renameChat(chatId, _rename.text.trim()));
    }
  }

  /// Off the list at once; the toast, once it's deleted, undoes it.
  Future<void> _delete(GaiaChat chat) async {
    final controller = widget.controller;
    final open = controller.currentChatId == chat.id;
    final String? media;
    try {
      media = await controller.deleteChat(chat.id);
    } on GaiaPipeException catch (error) {
      if (!mounted) return;
      showGaiaToast(
        context,
        mark: GaiaToastMark.error,
        title: '${chat.title} not deleted',
        body: '$error',
      );
      return;
    }
    if (!mounted) return;
    showGaiaToast(
      context,
      mark: GaiaToastMark.done,
      title: 'Deleted ${chat.title}',
      body: 'Click to undo',
      onTap: () => controller.restoreChat(chat.id, media, open: open),
    );
  }

  void _menu(GaiaChat chat, Offset position) {
    final controller = widget.controller;
    final running = controller.isRunning(chat.id);
    showGaiaMenu(context, position, [
      GaiaMenuItem(
        label: 'Rename',
        icon: Icons.edit_outlined,
        onPressed: () => _startRename(chat),
      ),
      GaiaMenuItem(
        label: 'Copy title',
        icon: Icons.content_copy,
        onPressed: () => Clipboard.setData(ClipboardData(text: chat.title)),
      ),
      if (running)
        GaiaMenuItem(
          label: 'Stop',
          icon: Icons.stop,
          onPressed: () => controller.stop(chat.id),
        )
      else
        // Not mid-run: the run would write it back.
        GaiaMenuItem(
          label: 'Delete',
          icon: Icons.delete_outline,
          destructive: true,
          onPressed: () => _delete(chat),
        ),
    ]);
  }

  Widget _tile(GaiaChat chat) {
    final controller = widget.controller;
    final selected = chat.id == controller.currentChatId;
    final running = controller.isRunning(chat.id);
    final renaming = chat.id == _renaming;
    if (_tiles[chat.id] case final last?
        when !renaming &&
            identical(last.chat, chat) &&
            last.selected == selected &&
            last.running == running) {
      return last.tile;
    }
    final tile = GestureDetector(
      key: ValueKey(chat.id),
      onSecondaryTapUp: (details) => _menu(chat, details.globalPosition),
      child: _ChatTile(
        selected: selected,
        title: renaming
            // In the tile's own text style, as its title was.
            ? Builder(
                builder: (context) => TextField(
                  controller: _rename,
                  focusNode: _renameFocus,
                  autofocus: true,
                  style: DefaultTextStyle.of(context).style,
                  decoration: const InputDecoration.collapsed(hintText: ''),
                  contextMenuBuilder: gaiaTextMenu,
                  onSubmitted: (_) => _endRename(keep: true),
                  onTapOutside: (_) => _endRename(keep: true),
                ),
              )
            : Text(chat.title, overflow: TextOverflow.ellipsis),
        trailing: running
            ? const GaiaSpinner(size: 16, label: 'Running')
            : null,
        onTap: renaming ? null : () => controller.selectChat(chat.id),
      ),
    );
    if (renaming) {
      // Not kept: the field's tile is built afresh as it's typed in.
      _tiles.remove(chat.id);
      return CallbackShortcuts(
        key: ValueKey(chat.id),
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): () =>
              _endRename(keep: false),
        },
        child: tile,
      );
    }
    _tiles[chat.id] = (
      chat: chat,
      selected: selected,
      running: running,
      tile: tile,
    );
    return tile;
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final theme = Theme.of(context);
    final ids = {for (final chat in controller.chats) chat.id};
    _tiles.removeWhere((id, _) => !ids.contains(id));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DragToMoveArea(
          child: SizedBox(
            height: 52,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('Gaia', style: theme.textTheme.titleMedium),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: GaiaButton(
            icon: Icons.add,
            label: 'New chat',
            onPressed: controller.newChat,
          ),
        ),
        Expanded(
          child: ScrollConfiguration(
            // Scrolls without a bar.
            behavior: ScrollConfiguration.of(
              context,
            ).copyWith(scrollbars: false),
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              children: [for (final chat in controller.chats) _tile(chat)],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Tooltip(
              message: 'Debug menu (Ctrl+Shift+D)',
              child: GaiaButton(
                icon: Icons.bug_report_outlined,
                size: 32,
                onPressed: () => showGaiaDebugMenu(context, controller),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// A chat in the sidebar, in the look of a [GaiaMenu]'s rows: dim text that
/// whitens over a faint fill on hover, and the open chat lit and edged in
/// the glow rings' rim.
class _ChatTile extends StatefulWidget {
  const _ChatTile({
    required this.selected,
    required this.title,
    required this.trailing,
    required this.onTap,
  });

  final bool selected;
  final Widget title;
  final Widget? trailing;

  /// Null while it's being renamed.
  final VoidCallback? onTap;

  @override
  State<_ChatTile> createState() => _ChatTileState();
}

class _ChatTileState extends State<_ChatTile> {
  var _hovered = false;

  @override
  Widget build(BuildContext context) {
    final selected = widget.selected;
    final lit = selected || _hovered;
    return MouseRegion(
      cursor: widget.onTap == null
          ? MouseCursor.defer
          : SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          height: 36,
          margin: const EdgeInsets.only(bottom: 2),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: Colors.white.withValues(
              alpha: selected
                  ? 0.08
                  : _hovered
                  ? 0.05
                  : 0,
            ),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: Colors.white.withValues(alpha: selected ? 0.1 : 0),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: AnimatedDefaultTextStyle(
                  duration: const Duration(milliseconds: 150),
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: lit ? Colors.white : const Color(0xFFA3A3A3),
                  ),
                  child: widget.title,
                ),
              ),
              if (widget.trailing case final trailing?) ...[
                const SizedBox(width: 8),
                trailing,
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// The width messages keep to: about 115 characters a line.
const _column = 860.0;

class _Messages extends StatefulWidget {
  const _Messages({
    required this.messages,
    required this.imageFile,
    required this.uploading,
    required this.tier,
    required this.running,
    required this.onEdit,
    required this.onAttach,
  });

  final List<GaiaMessage> messages;
  final Future<String?> Function(String mediaId) imageFile;

  /// The media ids of sent images still being attached.
  final Set<String> uploading;

  /// The one the next message goes on, which the latest reply's orb
  /// compacts into.
  final GaiaTier tier;

  /// The chat has a reply running from this window.
  final bool running;

  /// A message of the user's to edit and resend: it into the composer.
  final void Function(GaiaMessage message) onEdit;

  /// A message to attach to the draft as context (§9.3).
  final void Function(GaiaMessage message) onAttach;

  @override
  State<_Messages> createState() => _MessagesState();
}

GaiaMessage? _latestReply(List<GaiaMessage> messages) => messages
    .where((message) => message.role == GaiaMessageRole.assistant)
    .lastOrNull;

class _MessagesState extends State<_Messages> {
  final _scroll = ScrollController();

  /// One per chat, so its orb is carried on from one reply to the next: the
  /// last one's glyph flies to the new one, rather than a new orb blooming.
  /// This list's own, so a list built afresh (the window switching to or
  /// from a floater) starts its orbs where they are rather than flying them
  /// in from the old layout.
  final _orbKeys = <String, GlobalKey>{};

  /// The reply that keeps the orb while the chat scrolls down to a new one,
  /// so its glyph can fly there once the new reply's in view.
  String? _held;

  /// Each message's view as last built. Every change to Gaia rebuilds the
  /// list, and a message's view is costly to build: one whose message and
  /// placing haven't changed is given back as it was, which Flutter skips.
  final _views = <String, _MessageView>{};

  /// The messages this list has shown, in any chat, and those of them
  /// gathering in. Kept across chats, so one still running here isn't sent
  /// again on coming back to it.
  late Set<String> _seen;
  final _appearing = <String>{};

  @override
  void initState() {
    super.initState();
    _seen = {for (final message in widget.messages) message.id};
  }

  @override
  void didUpdateWidget(_Messages old) {
    super.didUpdateWidget(old);
    // The user's latest message new while a reply's claimed here: just sent
    // from this window, so it gathers in. Its reply may already be in after
    // it. The controller adds to the list it gave last time, so it's told
    // apart by [_seen].
    final question = widget.messages
        .where((message) => message.role == GaiaMessageRole.user)
        .lastOrNull;
    if (question != null && widget.running && !_seen.contains(question.id)) {
      _appearing.add(question.id);
    }
    _seen.addAll(widget.messages.map((message) => message.id));
    final was = _latestReply(old.messages);
    final now = _latestReply(widget.messages);
    // A new reply in the same chat, running here: a message was sent from
    // this window, so down to it. One synced in from elsewhere leaves the
    // chat where it is.
    if (!widget.running ||
        was == null ||
        now == null ||
        was.id == now.id ||
        was.chatId != now.chatId ||
        !_scroll.hasClients ||
        _scroll.offset == 0) {
      return;
    }
    final reduced = MediaQuery.disableAnimationsOf(context);
    final held = _held = reduced ? null : was.id;
    // Not mid-build, as scrolling notifies.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      if (reduced) return _scroll.jumpTo(0);
      _scroll
          .animateTo(
            0,
            duration: const Duration(milliseconds: 450),
            curve: Curves.easeInOutCubic,
          )
          .then((_) {
            if (mounted && _held == held) setState(() => _held = null);
          });
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// A clicked image opens among every image in the chat so far.
  void _open(GaiaImagePart image) {
    final images = [
      for (final message in widget.messages)
        ...message.parts.whereType<GaiaImagePart>(),
    ];
    showGaiaLightbox(
      context,
      images: images,
      initial: images.indexOf(image),
      imageFile: widget.imageFile,
    );
  }

  void _edit(GaiaMessage message) => widget.onEdit(message);

  void _attach(GaiaMessage message) => widget.onAttach(message);

  /// An image's bytes onto the clipboard, as stored.
  Future<void> _copyImage(GaiaImagePart image) async {
    final path = await widget.imageFile(image.mediaId);
    final clipboard = SystemClipboard.instance;
    if (!mounted) return;
    if (path == null || clipboard == null) {
      showGaiaToast(
        context,
        mark: GaiaToastMark.error,
        title: 'Image not copied',
        body: path == null
            ? "It isn't on this device yet."
            : "Copying images isn't supported here.",
      );
      return;
    }
    try {
      final bytes = await File(path).readAsBytes();
      await clipboard.write([DataWriterItem()..add(_imageFormat(bytes))]);
    } on Exception catch (error) {
      if (!mounted) return;
      showGaiaToast(
        context,
        mark: GaiaToastMark.error,
        title: 'Image not copied',
        body: '$error',
      );
    }
  }

  /// [bytes] in its format, by its signature: a draft's still uploading
  /// can be a GIF or a BMP, a stored one a WebP; anything else is a JPEG.
  static FutureOr<EncodedData> _imageFormat(Uint8List bytes) {
    if (bytes.length > 1 && bytes[0] == 0x42 && bytes[1] == 0x4D) {
      return Formats.bmp(bytes);
    }
    return switch (sniffImageFormat(bytes)) {
      SniffedImageFormat.png => Formats.png(bytes),
      SniffedImageFormat.gif => Formats.gif(bytes),
      SniffedImageFormat.webp => Formats.webp(bytes),
      _ => Formats.jpeg(bytes),
    };
  }

  /// [message]'s view: the one built last time while nothing it shows has
  /// changed.
  _MessageView _view(
    GaiaMessage message, {
    required double gutter,
    required GaiaTier? orbTier,
    required GlobalKey? orbKey,
  }) {
    final uploading = {
      for (final part in message.parts)
        if (part is GaiaImagePart && widget.uploading.contains(part.mediaId))
          part.mediaId,
    };
    final appear = _appearing.contains(message.id);
    final last = _views[message.id];
    if (last != null &&
        last.appear == appear &&
        identical(last.message, message) &&
        last.imageFile == widget.imageFile &&
        last.gutter == gutter &&
        last.orbTier == orbTier &&
        identical(last.orbKey, orbKey) &&
        setEquals(last.uploading, uploading)) {
      return last;
    }
    return _views[message.id] = _MessageView(
      message: message,
      imageFile: widget.imageFile,
      uploading: uploading,
      onOpen: _open,
      onCopyImage: _copyImage,
      onEdit: _edit,
      onAttach: _attach,
      gutter: gutter,
      orbTier: orbTier,
      orbKey: orbKey,
      appear: appear,
      onAppeared: () {
        if (mounted) setState(() => _appearing.remove(message.id));
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final _Messages(:messages, :tier) = widget;
    // Where each message sits in the reversed list.
    final indices = {
      for (final (i, message) in messages.indexed)
        message.id: messages.length - 1 - i,
    };
    _views.removeWhere((id, _) => !indices.containsKey(id));
    final held = messages.indexWhere((message) => message.id == _held);
    final latest = held >= 0
        ? held
        : messages.lastIndexWhere(
            (message) => message.role == GaiaMessageRole.assistant,
          );
    // Reversed, so the newest stays in view as a reply streams in.
    return LayoutBuilder(
      // Messages keep to a middle column of about 115 characters a line, as
      // in Claude's apps; narrower chats keep only a small gutter.
      builder: (context, constraints) {
        final gutter = max(16.0, (constraints.maxWidth - _column) / 2);
        return ScrollConfiguration(
          // Scrolls without a bar.
          behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
          child: ListView.builder(
            controller: _scroll,
            reverse: true,
            padding: EdgeInsets.symmetric(horizontal: gutter, vertical: 16),
            itemCount: messages.length,
            // A new message shifts the rest along; found by their keys,
            // they keep their views rather than each taking its neighbour's.
            findChildIndexCallback: (key) =>
                indices[(key as ValueKey<String>).value],
            itemBuilder: (context, index) {
              final i = messages.length - 1 - index;
              final message = messages[i];
              final switched = _switchedFrom(messages, i);
              final view = _view(
                message,
                gutter: gutter,
                orbTier: i == latest ? tier : null,
                orbKey: i == latest
                    ? _orbKeys.putIfAbsent(message.chatId, GlobalKey.new)
                    : null,
              );
              // The orb's reply is kept when scrolled out of the list, so
              // its orb doesn't bloom again on coming back.
              return _KeepAlive(
                key: ValueKey(message.id),
                keep: i == latest,
                child: switched == null
                    ? view
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _VendorDivider(to: message.adapter!),
                          view,
                        ],
                      ),
              );
            },
          ),
        );
      },
    );
  }
}

/// Keeps [child] built while scrolled out of its list, when [keep].
class _KeepAlive extends StatefulWidget {
  const _KeepAlive({super.key, required this.keep, required this.child});

  final bool keep;
  final Widget child;

  @override
  State<_KeepAlive> createState() => _KeepAliveState();
}

class _KeepAliveState extends State<_KeepAlive>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => widget.keep;

  @override
  void didUpdateWidget(_KeepAlive old) {
    super.didUpdateWidget(old);
    if (old.keep != widget.keep) updateKeepAlive();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}

/// The adapter of the reply before [index]'s, when [index] is a reply on
/// another one: the point a chat moved between vendors (§7.4).
String? _switchedFrom(List<GaiaMessage> messages, int index) {
  final adapter = messages[index].adapter;
  if (messages[index].role != GaiaMessageRole.assistant || adapter == null) {
    return null;
  }
  for (var i = index - 1; i >= 0; i--) {
    final earlier = messages[i];
    if (earlier.role != GaiaMessageRole.assistant || earlier.adapter == null) {
      continue;
    }
    return earlier.adapter == adapter ? null : earlier.adapter;
  }
  return null;
}

class _VendorDivider extends StatelessWidget {
  const _VendorDivider({required this.to});

  final String to;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.labelSmall?.copyWith(color: kGaiaStatusRose);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          const Expanded(child: Divider()),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              'Switched to ${kGaiaClis[to]?.name ?? to} · a transcript '
              'carried over',
              style: muted,
            ),
          ),
          const Expanded(child: Divider()),
        ],
      ),
    );
  }
}

class _MessageView extends StatelessWidget {
  const _MessageView({
    required this.message,
    required this.imageFile,
    required this.uploading,
    required this.onOpen,
    required this.onCopyImage,
    required this.onEdit,
    required this.onAttach,
    required this.gutter,
    required this.orbTier,
    required this.orbKey,
    required this.appear,
    required this.onAppeared,
  });

  final GaiaMessage message;
  final Future<String?> Function(String mediaId) imageFile;
  final Set<String> uploading;
  final void Function(GaiaImagePart image) onOpen;
  final void Function(GaiaImagePart image) onCopyImage;
  final void Function(GaiaMessage message) onEdit;
  final void Function(GaiaMessage message) onAttach;

  /// The list's margin either side of the messages.
  final double gutter;

  /// For the chat's latest reply, the tier its orb compacts into once it's
  /// done: the next message's; null for the rest, which have no orb.
  final GaiaTier? orbTier;

  /// The chat's orb's, which carries it on from one reply to the next.
  final GlobalKey? orbKey;

  /// A message of the user's just sent from this window, to gather in;
  /// [onAppeared] once it has.
  final bool appear;
  final VoidCallback onAppeared;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    if (message.role == GaiaMessageRole.user) {
      final images = message.parts.whereType<GaiaImagePart>();
      final files = message.parts.whereType<GaiaFilePart>();
      final window = message.parts.whereType<GaiaContextPart>().firstOrNull;
      final quotes = message.parts.whereType<GaiaQuotePart>();
      // Images and files float on their own above the prompt's bubble; a
      // message of only those has no bubble. Just sent, its text and
      // attachments gather in out of particles.
      return GaiaAppear(
        play: appear,
        ready: images.isEmpty
            ? null
            : () => Future.wait([
                for (final image in images)
                  GaiaImageThumb.precache(
                    context,
                    imageFile(image.mediaId),
                    96,
                  ),
              ]),
        onDone: onAppeared,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (images.isNotEmpty || files.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 48, bottom: 8),
                child: GaiaAppearPart(
                  child: Wrap(
                    alignment: WrapAlignment.end,
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final image in images)
                        GestureDetector(
                          onSecondaryTapUp: (details) =>
                              showGaiaMenu(context, details.globalPosition, [
                                GaiaMenuItem(
                                  label: 'Open',
                                  icon: Icons.open_in_full,
                                  onPressed: () => onOpen(image),
                                ),
                                GaiaMenuItem(
                                  label: 'Copy image',
                                  icon: Icons.content_copy,
                                  onPressed: () => onCopyImage(image),
                                ),
                              ]),
                          child: GaiaImageThumb(
                            file: imageFile(image.mediaId),
                            label: image.label,
                            height: 96,
                            uploading: uploading.contains(image.mediaId),
                            onTap: () => onOpen(image),
                          ),
                        ),
                      for (final file in files)
                        GaiaFileCard(file: file, height: 56),
                    ],
                  ),
                ),
              ),
            if (window != null || quotes.isNotEmpty || message.text.isNotEmpty)
              _bubble(
                theme.colorScheme.surfaceContainerHighest,
                Alignment.centerRight,
                GaiaAppearPart(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      if (window != null) ...[
                        _ContextChip(label: window.label),
                        const SizedBox(height: 6),
                      ],
                      for (final quote in quotes) ...[
                        _ContextChip(
                          label: quote.label,
                          icon: Icons.format_quote,
                        ),
                        const SizedBox(height: 6),
                      ],
                      if (message.text.isNotEmpty) _text(message.text),
                    ],
                  ),
                ),
              )
            else
              const SizedBox(height: 4),
          ],
        ),
      );
    }
    final status = switch (message.status) {
      GaiaMessageStatus.streaming || GaiaMessageStatus.complete => null,
      GaiaMessageStatus.error => 'Error${_detail(message.error)}',
      GaiaMessageStatus.cancelled => 'Stopped',
      GaiaMessageStatus.interrupted => 'Interrupted',
      GaiaMessageStatus.aborted => 'Aborted',
    };
    final streaming = message.status == GaiaMessageStatus.streaming;
    // The orb sits just left of Gaia's text, in the gutter and the bubble's
    // padding. Where those are narrower than the orb, every reply of hers is
    // indented to make room, so none of them moves when one starts or
    // finishes.
    final indent = max(
      0.0,
      kGaiaOrbSize + _orbGap - gutter - _bubblePadding.left,
    );
    // The chat's own background, so Gaia's bubble shows only as the stars
    // fading behind it.
    final bubble = _bubble(
      indent: indent,
      theme.scaffoldBackgroundColor,
      Alignment.centerLeft,
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final part in message.parts)
            switch (part) {
              GaiaTextPart(:final text) => _text(text),
              GaiaActivityPart(:final tools) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: GaiaActivityChip(label: _activity(tools)),
              ),
              // Only the user's messages carry attachments and context.
              GaiaImagePart() ||
              GaiaFilePart() ||
              GaiaContextPart() ||
              GaiaQuotePart() ||
              GaiaUnknownPart() => const SizedBox.shrink(),
            },
          if (status != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                status,
                style: muted?.copyWith(
                  color: message.status == GaiaMessageStatus.error
                      ? theme.colorScheme.error
                      : kGaiaStatusRose,
                ),
              ),
            ),
        ],
      ),
    );
    final tier = orbTier;
    // Just off the text, however wide the gutter, and level with
    // the newest line: the bubble's margin and padding below it, then half a
    // line. A Stack with or without the orb, so the bubble isn't built
    // afresh as the orb comes and goes.
    return Stack(
      clipBehavior: Clip.none,
      children: [
        bubble,
        if (tier != null)
          Positioned(
            left: indent + _bubblePadding.left - kGaiaOrbSize - _orbGap,
            bottom:
                _bubbleMargin + _bubblePadding.bottom + 10 - kGaiaOrbSize / 2,
            child: GaiaOrb(
              key: orbKey,
              tier: tier.index,
              startedAt: message.createdAt,
              state: !streaming
                  ? GaiaOrbState.glyph
                  : message.parts.lastOrNull is GaiaTextPart
                  ? GaiaOrbState.speaking
                  : GaiaOrbState.thinking,
            ),
          ),
      ],
    );
  }

  /// A message's rectangle, hugging its text. Nearly opaque, so the
  /// starfield behind it is almost gone but the stars around it aren't.
  Widget _bubble(
    Color color,
    Alignment alignment,
    Widget child, {
    double indent = 0,
  }) {
    return Align(
      alignment: alignment,
      child: _menuArea(
        Container(
          // The user's keep clear of the left, so their side stays theirs.
          margin: EdgeInsets.only(
            bottom: _bubbleMargin,
            left: alignment == Alignment.centerRight ? 48 : indent,
          ),
          padding: _bubblePadding,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.92),
            borderRadius: BorderRadius.circular(12),
          ),
          child: child,
        ),
      ),
    );
  }

  /// What right-clicking the message offers, beyond its text's own.
  List<GaiaMenuItem> _menu() => [
    if (message.text.isNotEmpty)
      GaiaMenuItem(
        label: 'Copy message',
        icon: Icons.copy_all,
        onPressed: () => Clipboard.setData(ClipboardData(text: message.text)),
      ),
    if (gaiaCodeBlocks(message.text) case final code?)
      GaiaMenuItem(
        label: 'Copy code',
        icon: Icons.code,
        onPressed: () => Clipboard.setData(ClipboardData(text: code)),
      ),
    if (message.text.isNotEmpty)
      GaiaMenuItem(
        label: 'Attach as context',
        icon: Icons.format_quote,
        onPressed: () => onAttach(message),
      ),
    if (message.role == GaiaMessageRole.user &&
        (message.text.isNotEmpty ||
            message.parts.any((part) => part is GaiaQuotePart)))
      GaiaMenuItem(
        label: 'Edit & resend',
        icon: Icons.edit_outlined,
        onPressed: () => onEdit(message),
      ),
  ];

  /// Selectable, with the message's actions in its right-click menu.
  Widget _text(String text) => _MessageText(text: text, menu: _menu);

  /// Right-clicked off its text, as on the bubble's padding: the message's
  /// actions alone.
  Widget _menuArea(Widget child) => Builder(
    builder: (context) => GestureDetector(
      onSecondaryTapUp: (details) {
        final items = _menu();
        if (items.isNotEmpty) {
          showGaiaMenu(context, details.globalPosition, items);
        }
      },
      child: child,
    ),
  );

  /// Below each bubble.
  static const _bubbleMargin = 12.0;

  /// Between the orb and Gaia's text.
  static const _orbGap = 10.0;

  static const _bubblePadding = EdgeInsets.symmetric(
    horizontal: 12,
    vertical: 8,
  );

  static String _detail(String? error) => error == null ? '' : ': $error';

  /// "Used Bash ×3, Edit".
  static String _activity(List<String> tools) {
    final counts = <String, int>{};
    for (final tool in tools) {
      counts[tool] = (counts[tool] ?? 0) + 1;
    }
    return 'Used ${[for (final MapEntry(:key, :value) in counts.entries) value > 1 ? '$key ×$value' : key].join(', ')}';
  }
}

/// A message's text, selectable, with [menu] after its own buttons in its
/// right-click menu.
class _MessageText extends StatefulWidget {
  const _MessageText({required this.text, required this.menu});

  final String text;

  /// Built only when the menu is: it scans the text for code.
  final List<GaiaMenuItem> Function() menu;

  @override
  State<_MessageText> createState() => _MessageTextState();
}

class _MessageTextState extends State<_MessageText> {
  /// The same function every build: a different one makes the text build
  /// its open menu afresh, replaying its entrance, as a streaming reply
  /// rebuilds it.
  Widget _contextMenu(BuildContext context, EditableTextState state) =>
      gaiaTextMenu(context, state, extra: widget.menu());

  @override
  Widget build(BuildContext context) =>
      SelectableText(widget.text, contextMenuBuilder: _contextMenu);
}

class _Composer extends StatefulWidget {
  const _Composer({required this.controller});

  final GaiaController controller;

  @override
  State<_Composer> createState() => _ComposerState();
}

class _ComposerState extends State<_Composer> {
  TextEditingController get _text => widget.controller.draft;
  final _focus = FocusNode();
  final _vanish = GlobalKey<GaiaVanishState>();
  final _imagesVanish = GlobalKey<GaiaVanishState>();

  /// The `/` palette's highlighted row, and whether Esc closed it for the
  /// draft as it stands.
  var _highlight = 0;
  String? _paletteClosedFor;

  /// The palette hovers over the chat from the overlay, above the
  /// composer, rather than pushing the chat up.
  final _portal = OverlayPortalController();
  final _link = LayerLink();

  @override
  void initState() {
    super.initState();
    _text.addListener(_onDraft);
    _portal.show();
  }

  void _onDraft() {
    unawaited(_takeTierCommand());
    // The palette follows the draft.
    setState(() => _highlight = 0);
  }

  /// A draft image clicked: the annotation editor (§9.4).
  Future<void> _edit(GaiaDraftImage image) async {
    final controller = widget.controller;
    final grew = await controller.enlargeForEditor();
    if (!mounted) return;
    final edits = await showGaiaImageEditor(
      context,
      path: image.path,
      label: image.label,
      edits: image.edits,
    );
    if (grew) await controller.restoreSmall();
    if (edits != null) await controller.editDraftImage(image.label, edits);
    _focus.requestFocus();
  }

  /// Ctrl+V: an image on the clipboard joins the draft (§9.3), unless it
  /// comes with text, which pastes as usual.
  Future<void> _paste() async {
    const clipboard = MediaClipboard();
    final offer = await clipboard.peek();
    if (!mounted) return;
    switch (routeMediaPaste(
      hasImage: offer.hasImage,
      hasText: offer.hasText,
      intoTextField: true,
    )) {
      case MediaPasteRoute.attach || MediaPasteRoute.both:
        final bytes = (await clipboard.read()).imageBytes;
        if (bytes != null) await widget.controller.attachImage(bytes);
      case MediaPasteRoute.text:
        if (_focus.context case final field? when field.mounted) {
          Actions.maybeInvoke(
            field,
            const PasteTextIntent(SelectionChangedCause.keyboard),
          );
        }
      case MediaPasteRoute.ignore:
        break;
    }
  }

  /// The palette's rows for the draft; empty when it isn't showing.
  List<GaiaPaletteItem> get _palette {
    final query = gaiaPaletteQuery(_text.text);
    if (query == null || _text.text == _paletteClosedFor) return const [];
    return filterGaiaPalette(
      gaiaPaletteItems(widget.controller.commands),
      query,
    );
  }

  /// A palette row picked (§9.2): a built-in runs, a tier switches, a
  /// standalone command sends, and any other command waits for its
  /// arguments.
  Future<void> _pick(GaiaPaletteItem item) async {
    final controller = widget.controller;
    if (item.builtin case final builtin?) {
      _text.clear();
      await controller.runBuiltin(builtin);
    } else if (item.tier case final tier?) {
      _text.clear();
      await switchGaiaTier(context, controller, tier);
    } else if (item.command case final command?) {
      // Closed over a standalone command left unsent mid-reply, so it
      // waits like any other draft.
      if (command.standalone) _paletteClosedFor = '/${command.name}';
      _text.value = TextEditingValue(
        text: command.standalone ? '/${command.name}' : '/${command.name} ',
        selection: TextSelection.collapsed(
          offset: command.name.length + (command.standalone ? 1 : 2),
        ),
      );
      // Straight to sending: the palette still matches `/name`, and
      // through [_send] it picked the row again instead (BUG-316).
      if (command.standalone) await _submit();
    }
    _focus.requestFocus();
  }

  void _move(int by) {
    final rows = _palette.length;
    if (rows == 0) return;
    setState(() => _highlight = (_highlight + by) % rows);
  }

  @override
  void dispose() {
    _text.removeListener(_onDraft);
    _focus.dispose();
    super.dispose();
  }

  /// An inline `/quick`, `/std` or `/deep` (§7.3), once completed: taken
  /// out of the draft whether or not the switch is confirmed. False when
  /// the user turned the switch down.
  Future<bool> _takeTierCommand({bool atEnd = false}) async {
    final command = findGaiaTierCommand(_text.value, atEnd: atEnd);
    if (command == null) return true;
    _text.value = command.value;
    return switchGaiaTier(context, widget.controller, command.tier);
  }

  /// A command ending the message switches before it's sent; turned down,
  /// the message stays in the composer.
  Future<void> _send() async {
    final palette = _palette;
    if (palette.isNotEmpty) return _pick(palette[_highlight]);
    return _submit();
  }

  /// [_send] without the palette.
  Future<void> _submit() async {
    // A built-in runs even mid-reply: /stop is for exactly then.
    if (gaiaBuiltinIn(_text.text) case final builtin?) {
      _text.clear();
      return widget.controller.runBuiltin(builtin);
    }
    if (!await _takeTierCommand(atEnd: true) || !mounted) return;
    final controller = widget.controller;
    final attached =
        controller.draftImages.isNotEmpty || controller.draftFiles.isNotEmpty;
    if (controller.draftIsEmpty || controller.currentRunning) {
      return;
    }
    if (!controller.readyToSend()) return;
    // After: it may take tokens out.
    final text = _text.text;
    GaiaVanishState.vanishTogether([
      if (attached) _imagesVanish.currentState!,
      _vanish.currentState!,
    ]);
    _text.clear();
    controller.send(
      text,
      images: controller.takeDraftImages(),
      files: controller.takeDraftFiles(),
    );
  }

  /// The +: files or a folder join the draft (§9.3).
  Future<void> _attach({required bool folder}) async {
    final paths = folder
        ? [?await pickFolder(title: 'Add a folder')]
        : [
            for (final file
                in (await FilePicker.platform.pickFiles(
                      allowMultiple: true,
                    ))?.files ??
                    const <PlatformFile>[])
              ?file.path,
          ];
    await widget.controller.attachPaths(paths, folder: folder);
    if (mounted) _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    if (controller.draining != null) {
      return _Draining(controller: controller);
    }
    if (controller.aborted) {
      return _Aborted(controller: controller);
    }
    final running = controller.currentRunning;
    final palette = _palette;
    final send = _sendCombo(controller);
    return LayoutBuilder(
      builder: (context, constraints) {
        // A little wider than the messages' column, as in Claude's apps.
        final side = max(12.0, (constraints.maxWidth - _column) / 2 - 12);
        return Padding(
          padding: EdgeInsets.fromLTRB(side, 8, side, 8),
          child: CallbackShortcuts(
            bindings: {
              send.activator: _send,
              const SingleActivator(LogicalKeyboardKey.keyV, control: true):
                  _paste,
              if (palette.isNotEmpty) ...{
                // Enter picks from the palette, whatever sends.
                const SingleActivator(LogicalKeyboardKey.enter): _send,
                const SingleActivator(LogicalKeyboardKey.tab): () =>
                    _pick(palette[_highlight]),
                const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
                    _move(1),
                const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
                    _move(-1),
                const SingleActivator(LogicalKeyboardKey.escape): () =>
                    setState(() => _paletteClosedFor = _text.text),
              },
            },
            child: OverlayPortal(
              controller: _portal,
              overlayChildBuilder: (context) => palette.isEmpty
                  ? const SizedBox.shrink()
                  : Align(
                      alignment: Alignment.topLeft,
                      child: CompositedTransformFollower(
                        link: _link,
                        showWhenUnlinked: false,
                        targetAnchor: Alignment.topLeft,
                        followerAnchor: Alignment.bottomLeft,
                        child: Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: GaiaPalette(
                            width: constraints.maxWidth - 2 * side,
                            highlight: _highlight.clamp(0, palette.length - 1),
                            items: [
                              for (final item in palette)
                                GaiaMenuItem(
                                  label: '/${item.name}',
                                  detail: item.description,
                                  onPressed: () => _pick(item),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
              child: CompositedTransformTarget(
                link: _link,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (controller.windowContext case final window?)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: _ContextChip(
                            label: window.label,
                            onRemove: controller.dropWindowContext,
                          ),
                        ),
                      ),
                    if (controller.draftQuotes.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            for (final quote in controller.draftQuotes)
                              _ContextChip(
                                label: quote.label,
                                icon: Icons.format_quote,
                                onRemove: () =>
                                    controller.removeDraftQuote(quote),
                              ),
                          ],
                        ),
                      ),
                    // Sent, the images and files dissolve like the text, and
                    // their row closes behind them.
                    GaiaVanish(
                      key: _imagesVanish,
                      refilled:
                          controller.draftImages.isNotEmpty ||
                          controller.arrivingImages.isNotEmpty ||
                          controller.draftFiles.isNotEmpty,
                      builder: (context, _) =>
                          controller.draftImages.isEmpty &&
                              controller.arrivingImages.isEmpty &&
                              controller.draftFiles.isEmpty
                          ? const SizedBox.shrink()
                          : Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  for (final image in controller.draftImages)
                                    GaiaImageThumb(
                                      // The preview's path too: the thumbnail
                                      // reads its path only once.
                                      key: ValueKey(
                                        image.preview ?? image.path,
                                      ),
                                      path: image.preview ?? image.path,
                                      label: image.label,
                                      height: 56,
                                      onTap: () => _edit(image),
                                      onRemove: () => controller
                                          .removeDraftImage(image.label),
                                    ),
                                  // Synced from another device and still
                                  // on their way: a placeholder until here.
                                  for (final image in controller.arrivingImages)
                                    GaiaImageThumb(
                                      key: ValueKey(image.mediaId),
                                      label: image.label,
                                      height: 56,
                                      uploading: true,
                                      busyLabel: 'Syncing',
                                      onRemove: () => controller
                                          .removeDraftImage(image.label),
                                    ),
                                  for (final file in controller.draftFiles)
                                    GaiaFileCard(
                                      file: file,
                                      height: 56,
                                      onRemove: () =>
                                          controller.removeDraftFile(file),
                                    ),
                                ],
                              ),
                            ),
                    ),
                    GaiaVanish(
                      key: _vanish,
                      controller: _text,
                      builder: (context, vanishing) => GaiaTextField(
                        controller: _text,
                        focusNode: _focus,
                        autofocus: true,
                        minLines: vanishing ? null : 1,
                        maxLines: vanishing ? null : 8,
                        expands: vanishing,
                        textAlignVertical: vanishing
                            ? TextAlignVertical.top
                            : null,
                        hintText: vanishing ? null : 'Message Gaia',
                        onPaste: _paste,
                        // The tier picker's notch, opening rightwards from the
                        // field's left edge.
                        leading: Padding(
                          // Level with the send button.
                          padding: const EdgeInsets.symmetric(vertical: 3),
                          child: GaiaNotch(
                            opensRight: true,
                            items: [
                              GaiaNotchItem<bool?>(
                                trigger: (color) =>
                                    Icon(Icons.add, size: 16, color: color),
                                options: [
                                  GaiaNotchOption(
                                    value: false,
                                    label: 'Add files',
                                    icon: (color, {required lit}) => Icon(
                                      Icons.description_outlined,
                                      size: 16,
                                      color: color,
                                    ),
                                  ),
                                  GaiaNotchOption(
                                    value: true,
                                    label: 'Add folder',
                                    icon: (color, {required lit}) => Icon(
                                      Icons.folder_outlined,
                                      size: 16,
                                      color: color,
                                    ),
                                  ),
                                ],
                                value: null,
                                onChanged: (folder) => _attach(folder: folder!),
                              ),
                            ],
                          ),
                        ),
                        trailing: running
                            ? GaiaButton(
                                icon: Icons.stop,
                                size: 32,
                                onPressed: () =>
                                    controller.stop(controller.currentChatId!),
                              )
                            : GaiaButton(
                                icon: Icons.arrow_upward,
                                size: 32,
                                onPressed: _send,
                              ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    _ComposerStatus(controller: controller),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The window the next message says it was asked from (§15.4), or a
/// message attached to it (§9.3), which the user can take off it.
class _ContextChip extends StatelessWidget {
  const _ContextChip({
    required this.label,
    this.icon = Icons.web_asset,
    this.onRemove,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    final style = theme.textTheme.labelSmall?.copyWith(color: accent);
    final chip = Container(
      constraints: const BoxConstraints(maxWidth: 420),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: accent),
          const SizedBox(width: 4),
          Flexible(
            child: Text(label, style: style, overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    );
    if (onRemove == null) return chip;
    // Clicking it removes it.
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: onRemove,
      child: chip,
    );
  }
}

/// Under the composer: the current chat's context, the next message's
/// account usage, and the tier picker.
class _ComposerStatus extends StatelessWidget {
  const _ComposerStatus({required this.controller});

  final GaiaController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = controller.contextTokens;
    final usage =
        controller.usage[controller.agentFor(controller.nextTier)?.adapter];
    return Row(
      children: [
        const SizedBox(width: 4),
        Expanded(
          child: Text(
            tokens == null ? '' : '${(tokens / 1000).round()}k context',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        if (usage != null) ...[
          _UsageRing(usage: usage),
          const SizedBox(width: 8),
        ],
        // The notch opens up and to the left, so it ends the row.
        _TierPicker(controller: controller),
      ],
    );
  }
}

/// An account's five-hour usage as a ring filling clockwise from the top,
/// with a bar for every window in its tooltip.
class _UsageRing extends StatelessWidget {
  const _UsageRing({required this.usage});

  final GaiaUsage usage;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      richMessage: WidgetSpan(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _UsageBar(name: '5-hour', window: usage.fiveHour),
            const SizedBox(height: 10),
            _UsageBar(name: 'Weekly', window: usage.weekly),
          ],
        ),
      ),
      padding: const EdgeInsets.all(10),
      child: CustomPaint(
        size: const Size.square(14),
        painter: _RingPainter(
          used: _usedNow(usage.fiveHour),
          track: Colors.white.withValues(alpha: 0.15),
          fill: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}

/// [window]'s share used, 0 once it has reset since it was read.
double _usedNow(GaiaUsageWindow? window) =>
    window == null || !window.resetsAt.isAfter(DateTime.now())
    ? 0
    : window.used.clamp(0.0, 1.0);

/// One usage window in the ring's tooltip: its name and share used over a
/// bar, and when it resets.
class _UsageBar extends StatelessWidget {
  const _UsageBar({required this.name, required this.window});

  final String name;
  final GaiaUsageWindow? window;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final window = this.window;
    final used = _usedNow(window);
    final String detail;
    if (window == null) {
      detail = 'Unknown';
    } else {
      final resets = window.resetsAt;
      final at = DateUtils.isSameDay(resets, DateTime.now())
          ? DateFormat.jm().format(resets)
          : DateFormat.E().add_jm().format(resets);
      // Its next reset isn't known until the account runs again.
      detail = resets.isAfter(DateTime.now()) ? 'Resets $at' : 'Reset at $at';
    }
    return SizedBox(
      width: 180,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: Text(name, style: theme.textTheme.bodySmall)),
              if (window != null)
                Text(
                  '${(used * 100).round()}%',
                  style: theme.textTheme.bodySmall,
                ),
            ],
          ),
          const SizedBox(height: 4),
          LinearProgressIndicator(
            value: used,
            minHeight: 4,
            borderRadius: BorderRadius.circular(2),
            backgroundColor: Colors.white.withValues(alpha: 0.15),
            color: theme.colorScheme.primary,
          ),
          const SizedBox(height: 4),
          Text(detail, style: muted),
        ],
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  const _RingPainter({
    required this.used,
    required this.track,
    required this.fill,
  });

  final double used;
  final Color track;
  final Color fill;

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 2.0;
    final rect = (Offset.zero & size).deflate(stroke / 2);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke;
    canvas
      ..drawOval(rect, paint..color = track)
      ..drawArc(
        rect,
        -pi / 2,
        2 * pi * used.clamp(0.0, 1.0),
        false,
        paint
          ..color = fill
          ..strokeCap = StrokeCap.round,
      );
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.used != used || old.track != track || old.fill != fill;
}

/// The tier the next message goes to (§7.2) and its agent, a notch that
/// opens onto all three.
class _TierPicker extends StatelessWidget {
  const _TierPicker({required this.controller});

  final GaiaController controller;

  @override
  Widget build(BuildContext context) {
    return GaiaNotch(
      items: [
        GaiaNotchItem<GaiaTier>(
          options: [
            for (final tier in GaiaTier.values)
              GaiaNotchOption(
                value: tier,
                label: tier.label,
                detail: controller.agentFor(tier)?.label ?? 'No agent',
                icon: (color, {required lit}) =>
                    GaiaTierGlyph(level: tier.index, color: color, lit: lit),
              ),
          ],
          value: controller.nextTier,
          onChanged: (tier) => switchGaiaTier(context, controller, tier),
        ),
      ],
    );
  }
}

/// Switches the current chat's next message to [tier]: silently before
/// its first reply, after the user's yes once there is one (§7.5). The
/// dialog says what the switch costs: the prompt cache, and across vendors
/// everything but a transcript. The send keybind confirms; Esc keeps the tier,
/// and the result is false.
Future<bool> switchGaiaTier(
  BuildContext context,
  GaiaController controller,
  GaiaTier tier,
) async {
  if (!controller.switchNeedsConfirm(tier)) {
    controller.pickTier(tier);
    return true;
  }
  final from = controller.nextTier;
  final fromAgent = controller.agentFor(from);
  final toAgent = controller.agentFor(tier);
  String name(GaiaTier tier, GaiaAgent? agent) =>
      agent == null ? tier.label : '${tier.label} (${agent.label})';
  String cli(GaiaAgent? agent) =>
      kGaiaClis[agent?.adapter]?.name ?? agent?.adapter ?? 'the other agent';
  final crossVendor =
      fromAgent != null &&
      toAgent != null &&
      fromAgent.adapter != toAgent.adapter;
  final tokens = controller.contextTokens;
  final send = _sendCombo(controller);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => CallbackShortcuts(
      bindings: {send.activator: () => Navigator.of(context).pop(true)},
      child: Focus(
        autofocus: true,
        child: AlertDialog(
          title: Text(
            'Switch from ${name(from, fromAgent)} to '
            '${name(tier, toAgent)}?',
          ),
          content: Text(
            [
              'The prompt cache is lost, so the next message re-reads the '
                  'whole context and uses extra tokens.',
              if (tokens != null)
                'Current context: ${(tokens / 1000).round()}k tokens.',
              if (crossVendor)
                'Only a transcript carries over to ${cli(toAgent)}. '
                    "${cli(fromAgent)}'s tool history doesn't.",
              'Press $send to switch.',
            ].join('\n\n'),
          ),
          actions: [
            GaiaButton(
              label: 'Cancel',
              onPressed: () => Navigator.of(context).pop(false),
              color: Theme.of(context).colorScheme.error,
            ),
            GaiaButton(
              label: 'Switch',
              onPressed: () => Navigator.of(context).pop(true),
            ),
          ],
        ),
      ),
    ),
  );
  if (confirmed != true) return false;
  controller.pickTier(tier);
  return true;
}

/// The send keybind (§9.1), Ctrl+Enter by default, which is also its
/// default when unbound: Enter and Shift+Enter are newlines.
GaiaCombo _sendCombo(GaiaController controller) =>
    parseGaiaCombo(gaiaComboFor(GaiaKeybind.send, controller.keybinds)) ??
    parseGaiaCombo(GaiaKeybind.send.defaultCombo)!;

/// Edit & resend: [message] into the composer, once the user says to
/// replace what's in it, with the send keybind or the button.
Future<void> _editMessage(
  BuildContext context,
  GaiaController controller,
  GaiaMessage message,
) async {
  if (!controller.draftIsEmpty) {
    final send = _sendCombo(controller);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => CallbackShortcuts(
        bindings: {send.activator: () => Navigator.of(context).pop(true)},
        child: Focus(
          autofocus: true,
          child: AlertDialog(
            title: const Text('Replace the draft?'),
            content: Text(
              "What's in the composer now, and what's attached to it, is "
              'lost.\n\nPress $send to replace.',
            ),
            actions: [
              GaiaButton(
                label: 'Cancel',
                onPressed: () => Navigator.of(context).pop(false),
                color: Theme.of(context).colorScheme.error,
              ),
              GaiaButton(
                label: 'Replace',
                onPressed: () => Navigator.of(context).pop(true),
              ),
            ],
          ),
        ),
      ),
    );
    if (confirmed != true) return;
  }
  controller.editMessage(message);
}

/// In place of the composer while Voyager waits to quit or update (§3.2):
/// wait for the runs, or cancel them and keep what they wrote.
class _Draining extends StatelessWidget {
  const _Draining({required this.controller});

  final GaiaController controller;

  @override
  Widget build(BuildContext context) {
    final count = controller.draining!;
    final runs = count == 1 ? '1 run' : '$count runs';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Row(
        children: [
          Expanded(
            child: Text(
              controller.drainWaiting
                  ? 'Voyager will quit once $runs finish${count == 1 ? 'es' : ''}'
                  : 'Gaia has $runs in progress',
            ),
          ),
          if (!controller.drainWaiting) ...[
            GaiaButton(label: 'Wait', onPressed: controller.waitForDrain),
            const SizedBox(width: 8),
          ],
          GaiaButton(
            label: 'Cancel',
            onPressed: controller.cancelDrain,
            color: Theme.of(context).colorScheme.error,
          ),
        ],
      ),
    );
  }
}

/// In place of the composer while Abort is engaged (§15.7). Re-arming is
/// deliberate: confirmed with the send keybind.
class _Aborted extends StatelessWidget {
  const _Aborted({required this.controller});

  final GaiaController controller;

  Future<void> _confirm(BuildContext context) async {
    final send = _sendCombo(controller);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => CallbackShortcuts(
        bindings: {send.activator: () => Navigator.of(context).pop(true)},
        child: Focus(
          autofocus: true,
          child: AlertDialog(
            title: const Text('Re-arm Gaia?'),
            content: Text('Chats and runs work again. Press $send to confirm.'),
            actions: [
              GaiaButton(
                label: 'Cancel',
                onPressed: () => Navigator.of(context).pop(false),
                color: Theme.of(context).colorScheme.error,
              ),
            ],
          ),
        ),
      ),
    );
    if (confirmed == true) await controller.rearm();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Row(
        children: [
          Icon(Icons.block, size: 18, color: theme.colorScheme.error),
          const SizedBox(width: 8),
          const Expanded(child: Text('Gaia is aborted')),
          GaiaButton(label: 'Re-arm', onPressed: () => _confirm(context)),
        ],
      ),
    );
  }
}
