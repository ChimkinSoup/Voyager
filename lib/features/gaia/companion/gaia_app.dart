import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/gestures.dart'
    show computeHitSlop, kDoubleTapSlop, kDoubleTapTimeout, kPrimaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart' show RenderAbstractViewport, RenderFlex;
import 'package:intl/intl.dart';
import 'package:super_clipboard/super_clipboard.dart';
import 'package:voyager/app/providers.dart'
    show voyagerSpellCheckServiceProvider;
import 'package:voyager/core/media/media_clipboard.dart';
import 'package:voyager/core/media/widgets/media_paste_scope.dart';
import 'package:voyager/core/platform/windows_folder_picker.dart';
import 'package:voyager/core/snippets/snippet_enabled_scope.dart';
import 'package:voyager/core/snippets/snippet_index.dart';
import 'package:voyager/core/spellcheck/autocorrect_enabled_scope.dart';
import 'package:voyager/core/spellcheck/dictionary_loader.dart';
import 'package:voyager/core/spellcheck/voyager_spell_check_service.dart';
import 'package:voyager/core/text/list_text_editing.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/core/utils/time_format.dart';
import 'package:voyager/core/vim/vim_enabled_scope.dart';
import 'package:voyager/core/vim/vim_text_scope.dart';
import 'package:voyager/features/gaia/adapters/gaia_agent_runner.dart';
import 'package:voyager/features/gaia/adapters/gaia_clis.dart';
import 'package:voyager/features/gaia/companion/gaia_btw.dart';
import 'package:voyager/features/gaia/companion/gaia_button.dart';
import 'package:voyager/features/gaia/companion/gaia_card_view.dart';
import 'package:voyager/features/gaia/companion/gaia_chat_body.dart';
import 'package:voyager/features/gaia/companion/gaia_commands.dart';
import 'package:voyager/features/gaia/companion/gaia_composer_text.dart';
import 'package:voyager/features/dev/dev_fps_counter_tile.dart';
import 'package:voyager/features/gaia/companion/gaia_controller.dart';
import 'package:voyager/features/gaia/usage/gaia_usage.dart';
import 'package:voyager/features/gaia/usage/gaia_usage_bar.dart';
import 'package:voyager/features/gaia/usage/gaia_usage_limits.dart';
import 'package:voyager/features/gaia/companion/gaia_crop_overlay.dart';
import 'package:voyager/features/gaia/companion/gaia_debug_menu.dart';
import 'package:voyager/features/gaia/companion/gaia_file_card.dart';
import 'package:voyager/features/gaia/companion/gaia_action_icon.dart';
import 'package:voyager/features/gaia/companion/gaia_activity_chip.dart';
import 'package:voyager/features/gaia/companion/gaia_appear.dart';
import 'package:voyager/features/gaia/companion/gaia_attachments.dart';
import 'package:voyager/features/gaia/companion/gaia_image_editor.dart';
import 'package:voyager/features/gaia/companion/gaia_image_thumb.dart';
import 'package:voyager/features/gaia/companion/gaia_lightbox.dart';
import 'package:voyager/features/gaia/companion/gaia_markdown.dart';
import 'package:voyager/features/gaia/companion/gaia_notch.dart';
import 'package:voyager/features/gaia/companion/gaia_search.dart';
import 'package:voyager/features/gaia/companion/gaia_offline_icon.dart';
import 'package:voyager/features/gaia/companion/gaia_orb.dart';
import 'package:voyager/features/gaia/companion/gaia_orb_materials.dart';
import 'package:voyager/features/gaia/companion/gaia_pinned_prompt.dart';
import 'package:voyager/features/gaia/companion/gaia_tier_picker.dart';
import 'package:voyager/features/gaia/companion/gaia_sidebar.dart';
import 'package:voyager/features/gaia/companion/gaia_spinner.dart';
import 'package:voyager/features/gaia/companion/gaia_starfield.dart';
import 'package:voyager/features/gaia/companion/gaia_steady_list.dart';
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

/// The companion's UI (GAIA_HLD.md §3.3): the small and large floaters show
/// the whole chat, and the Gaia window adds a chat sidebar.
class GaiaApp extends StatefulWidget {
  const GaiaApp({super.key, required this.controller});

  final GaiaController controller;

  @override
  State<GaiaApp> createState() => _GaiaAppState();
}

class _GaiaAppState extends State<GaiaApp> {
  final _popups = _Popups();
  late final StreamSubscription<void> _captures;

  /// The composer's own checker (§9.5): Voyager's, on the user's words from
  /// the main instance, skipping what isn't prose in a prompt.
  final _spelling = VoyagerSpellCheckService(skipZones: gaiaComposerSkipZones);
  var _snippets = SnippetScopeData.disabled;

  GaiaController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    // The crop overlay is the chat's route turned into the overlay, so any
    // dialog or menu open over the chat would stay on top of it.
    _captures = controller.captures.listen((_) => _popups.dismiss());
    unawaited(loadDictionaryFromAssets().then(_spelling.updateDictionary));
    controller.textSettings.addListener(_onTextSettings);
    _onTextSettings();
  }

  /// The words and snippets as they now stand; the toggles are read where
  /// they're built.
  void _onTextSettings() {
    final settings = controller.textSettings.value;
    _spelling
      ..updateCustomWords(settings.customWords)
      ..updateFlaggedWords(settings.flaggedWords);
    _snippets = SnippetScopeData(
      enabled: settings.snippetsEnabled,
      expandKey: settings.expandKey,
      index: SnippetIndex.from(settings.snippets),
    );
  }

  @override
  void dispose() {
    unawaited(_captures.cancel());
    controller.textSettings.removeListener(_onTextSettings);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: controller.onScreen,
      builder: (context, onScreen, child) =>
          TickerMode(enabled: onScreen, child: child!),
      child: _Ambient(
        focused: controller.focused,
        // Above the app, so its dialogs and menus see them too. The checker
        // is read from a provider by Voyager's spellcheck layers.
        child: ProviderScope(
          overrides: [
            voyagerSpellCheckServiceProvider.overrideWithValue(_spelling),
          ],
          child: ValueListenableBuilder(
            valueListenable: controller.textSettings,
            builder: (context, settings, child) => VimEnabledScope(
              enabled: settings.vim,
              child: AutocorrectEnabledScope(
                data: AutocorrectScopeData(
                  enabled: settings.autocorrect,
                  service: _spelling,
                ),
                child: SnippetEnabledScope(data: _snippets, child: child!),
              ),
            ),
            child: _app(),
          ),
        ),
      ),
    );
  }

  Widget _app() => ValueListenableBuilder(
    valueListenable: controller.accent,
    builder: (context, accent, _) => MaterialApp(
      title: 'Gaia',
      debugShowCheckedModeBanner: false,
      theme: _onGaiaSurface(Color(accent)),
      navigatorObservers: [_popups],
      home: _RunToasts(
        controller: controller,
        child: ListenableBuilder(
          listenable: Listenable.merge([controller, controller.debug]),
          builder: (context, _) => _GaiaShell(controller: controller),
        ),
      ),
    ),
  );

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

/// The routes pushed over the chat's: dialogs and menus.
class _Popups extends NavigatorObserver {
  final _routes = <Route<dynamic>>[];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (previousRoute != null) _routes.add(route);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _routes.remove(route);

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _routes.remove(route);

  /// Gone at once, no exit animation; whoever awaits one gets null. The
  /// right-click menu too, an overlay entry rather than a route.
  void dismiss() {
    ContextMenuController.removeAny();
    for (final route in _routes.reversed.toList()) {
      navigator!.removeRoute(route);
    }
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
  late final StreamSubscription<({GaiaRunToast toast, String btwId})>
  _btwToasts;

  @override
  void initState() {
    super.initState();
    _toasts = widget.controller.toasts.listen(_show);
    _btwToasts = widget.controller.btwToasts.listen(
      (toast) => _show(toast.toast, btwId: toast.btwId),
    );
  }

  @override
  void dispose() {
    unawaited(_toasts.cancel());
    unawaited(_btwToasts.cancel());
    super.dispose();
  }

  /// With [btwId], a side question's, which a click opens.
  void _show(GaiaRunToast toast, {String? btwId}) {
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
          : btwId != null
          ? () => widget.controller.revealBtw(toast.chatId, btwId)
          : () => widget.controller.selectChat(toast.chatId),
    );
    // A run's toast, not the UI's own, into Voyager's notification history.
    widget.controller.toastShown(toast.title, toast.body);
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
              // The composer's chips float over the messages' foot.
              child: GaiaChatBody(
                // Also rebuilt alone as a reply's text streams in.
                messages: ValueListenableBuilder(
                  valueListenable: controller.streamed,
                  builder: (context, _, _) => _Messages(
                    messages: controller.messages,
                    imageFile: controller.imageFile,
                    uploading: controller.uploadingImages,
                    tier: controller.nextTier,
                    running: controller.currentRunning,
                    onEdit: (message) =>
                        _editMessage(context, controller, message),
                    onAttach: controller.attachMessage,
                    controller: controller,
                  ),
                ),
                composer: _Composer(controller: controller),
              ),
            ),
          ],
        );
    return CallbackShortcuts(
      bindings: {
        // A text box eats Esc, so it never closes the floater from inside
        // one, whatever Vim's mode.
        if (floater)
          const SingleActivator(LogicalKeyboardKey.escape): () {
            final focused = FocusManager.instance.primaryFocus?.context;
            if (focused?.findAncestorStateOfType<EditableTextState>() == null) {
              controller.dismiss();
            }
          },
        const SingleActivator(LogicalKeyboardKey.keyN, control: true):
            controller.newChat,
        const SingleActivator(
          LogicalKeyboardKey.keyN,
          control: true,
          shift: true,
        ): controller.moveDraftToNewChat,
        const SingleActivator(LogicalKeyboardKey.keyF, control: true): () =>
            showGaiaSearch(context, controller),
        const SingleActivator(
          LogicalKeyboardKey.keyD,
          control: true,
          shift: true,
        ): () =>
            showGaiaDebugMenu(context, controller),
      },
      // Focus leaving a text box lands here, under the bindings, so Esc
      // still reaches them with nothing focused.
      child: FocusScope(
        onKeyEvent: (_, event) {
          final card = _cardKey(controller, event);
          if (card == KeyEventResult.handled) return card;
          return _typeToComposer(controller, event);
        },
        child: _ClickToComposer(
          controller: controller,
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
                            chat: (shown, toggle) => chat(
                              sidebarShown: shown,
                              toggleSidebar: toggle,
                            ),
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
        ),
      ),
    );
  }
}

/// A plain click anywhere in Gaia, on the chat or a card, a button or the
/// sidebar, gives the composer the focus, so its keys work from there. Not
/// a click into another text box, which keeps it, nor one that opened a
/// menu or a dialog; and not a drag, a double or triple click or a
/// Shift+click, which select the chat's text, and would lose it with the
/// focus.
class _ClickToComposer extends StatefulWidget {
  const _ClickToComposer({required this.controller, required this.child});

  final GaiaController controller;
  final Widget child;

  @override
  State<_ClickToComposer> createState() => _ClickToComposerState();
}

class _ClickToComposerState extends State<_ClickToComposer> {
  /// Where the click in progress went down; null for one that doesn't count.
  Offset? _down;

  /// The last click's release, for telling a double click.
  ({Duration at, Offset where})? _lastUp;

  /// The composer taking the focus, once the click turns out not to be a
  /// double click's first: the second and third clicks select without taking
  /// the focus back, so Ctrl+C would go to the composer.
  Timer? _pending;

  @override
  void dispose() {
    _pending?.cancel();
    super.dispose();
  }

  void _onDown(PointerDownEvent event) {
    _pending?.cancel();
    final last = _lastUp;
    final repeat =
        last != null &&
        event.timeStamp - last.at < kDoubleTapTimeout &&
        (event.position - last.where).distance < kDoubleTapSlop;
    _down =
        event.buttons == kPrimaryButton &&
            !repeat &&
            !HardwareKeyboard.instance.isShiftPressed
        ? event.position
        : null;
  }

  void _onUp(PointerUpEvent event) {
    final down = _down;
    _down = null;
    _lastUp = (at: event.timeStamp, where: event.position);
    if (down == null ||
        (event.position - down).distance > computeHitSlop(event.kind, null)) {
      return;
    }
    // After the click's own tap, which may open a menu or focus a field, and
    // after the time a second click would have come in.
    _pending = Timer(kDoubleTapTimeout, () {
      if (!mounted || !(ModalRoute.of(context)?.isCurrent ?? true)) return;
      if (_inTextField() || _inBtwDock()) return;
      widget.controller.focusComposer();
    });
  }

  @override
  Widget build(BuildContext context) => Listener(
    behavior: HitTestBehavior.translucent,
    onPointerDown: _onDown,
    onPointerUp: _onUp,
    child: widget.child,
  );
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
      body: _DragArea(
        floater: true,
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
            Tooltip(
              message: 'Cancel (Esc)',
              child: GaiaButton(
                icon: Icons.close,
                onPressed: controller.cancelPickUp,
                size: 28,
              ),
            ),
            const SizedBox(width: 4),
          ],
        ),
      ),
    );
  }
}

/// New chat's buttons: with Shift held, the draft goes with it.
void _newChat(GaiaController controller) =>
    HardwareKeyboard.instance.isShiftPressed
    ? controller.moveDraftToNewChat()
    : controller.newChat();

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
    return _DragArea(
      floater: floater,
      fullScreen: controller.fullScreen,
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
            if (controller.connectivity case final connectivity?)
              ListenableBuilder(
                listenable: connectivity,
                builder: (context, _) => connectivity.isOnline
                    ? const SizedBox.shrink()
                    : GaiaOfflineIcon(
                        cli: cli?.name,
                        retrying: connectivity.isRetrying,
                        onRetry: () => unawaited(connectivity.retryNow()),
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
                onPressed: () => _newChat(controller),
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
            if (!floater) _WindowButtons(controller: controller),
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

/// Drags the window by its header. A double click maximises the Gaia
/// window, as a title bar's does; a floater keeps its size. A full-screen
/// window stays put.
class _DragArea extends StatelessWidget {
  const _DragArea({
    required this.floater,
    this.fullScreen = false,
    required this.child,
  });

  final bool floater;
  final bool fullScreen;
  final Widget child;

  @override
  Widget build(BuildContext context) => fullScreen && !floater
      ? child
      : floater
      ? GestureDetector(
          behavior: HitTestBehavior.translucent,
          onPanStart: (_) => windowManager.startDragging(),
          child: child,
        )
      : DragToMoveArea(child: child);
}

/// The Gaia window's Minimize and Maximize or Restore, beside its close.
/// The floaters have neither.
class _WindowButtons extends StatefulWidget {
  const _WindowButtons({required this.controller});

  final GaiaController controller;

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
    final fullScreen = widget.controller.fullScreen;
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
          icon: fullScreen || _maximized
              ? Icons.filter_none
              : Icons.crop_square,
          size: 32,
          onPressed: fullScreen
              ? widget.controller.leaveFullScreen
              : _maximized
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
      <
        String,
        ({GaiaChat chat, bool selected, bool running, bool? open, Widget tile})
      >{};

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
        label: chat.pinned ? 'Unpin' : 'Pin',
        icon: chat.pinned ? Icons.push_pin : Icons.push_pin_outlined,
        onPressed: () => controller.setPinned(chat.id, !chat.pinned),
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

  /// [open]: whether the chat's forks show under it; null when it has none.
  Widget _tile(GaiaChat chat, {bool? open}) {
    final controller = widget.controller;
    final selected = chat.id == controller.currentChatId;
    final running = controller.isRunning(chat.id);
    final renaming = chat.id == _renaming;
    if (_tiles[chat.id] case final last?
        when !renaming &&
            identical(last.chat, chat) &&
            last.selected == selected &&
            last.running == running &&
            last.open == open) {
      return last.tile;
    }
    final tile = GestureDetector(
      key: ValueKey(chat.id),
      onSecondaryTapUp: (details) => _menu(chat, details.globalPosition),
      child: _ChatTile(
        selected: selected,
        title: renaming
            // In the tile's own text style, as its title was, in Gaia's
            // field: its fill, and its edge lit in the accent. Out past the
            // title on both sides by its padding, and the text collapsed and
            // centred as the title is, so the text stays put.
            ? LayoutBuilder(
                builder: (context, constraints) => OverflowBox(
                  maxWidth: constraints.maxWidth + 8,
                  child: Container(
                    height: 30,
                    // With the 1 of the edge, the 4 it's out by.
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    alignment: Alignment.centerLeft,
                    decoration: BoxDecoration(
                      color: gaiaFieldFill,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: Theme.of(
                          context,
                        ).colorScheme.primary.withValues(alpha: 0.6),
                      ),
                    ),
                    child: TextField(
                      controller: _rename,
                      focusNode: _renameFocus,
                      autofocus: true,
                      // Not merged over the theme's text style, whose line
                      // height and spacing would move the text.
                      style: DefaultTextStyle.of(context).style.copyWith(
                        inherit: false,
                        textBaseline: TextBaseline.alphabetic,
                      ),
                      decoration: const InputDecoration(
                        isCollapsed: true,
                        // The box above is the fill: the theme's would show
                        // as a faint one round the text.
                        filled: false,
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                      ),
                      contextMenuBuilder: gaiaTextMenu,
                      onSubmitted: (_) => _endRename(keep: true),
                      onTapOutside: (_) => _endRename(keep: true),
                    ),
                  ),
                ),
              )
            : Text(chat.title, overflow: TextOverflow.ellipsis),
        chevron: open == null
            ? null
            : _ForksChevron(
                open: open,
                onTap: () {
                  unawaited(controller.sidebar.setCollapsed(chat.id, open));
                  setState(() {});
                },
              ),
        trailing: chat.pinned || running
            ? Row(
                mainAxisSize: MainAxisSize.min,
                spacing: 8,
                children: [
                  if (chat.pinned)
                    // Its own context, so the accent changing reaches a tile
                    // that's given back as it was.
                    Builder(
                      builder: (context) => Icon(
                        Icons.push_pin,
                        size: 14,
                        color: Theme.of(context).colorScheme.primary,
                        semanticLabel: 'Pinned',
                      ),
                    ),
                  if (running) const GaiaSpinner(size: 16, label: 'Running'),
                ],
              )
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
      open: open,
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
        SizedBox(
          height: 52,
          child: Row(
            children: [
              Expanded(
                child: DragToMoveArea(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text('Gaia', style: theme.textTheme.titleMedium),
                    ),
                  ),
                ),
              ),
              // Not in the drag area, whose double click would hold back its
              // clicks till it's sure there's no second.
              Padding(
                padding: const EdgeInsets.only(right: 10),
                child: GaiaButton(
                  icon: Icons.search,
                  size: 32,
                  onPressed: () => showGaiaSearch(context, controller),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: GaiaButton(
            icon: Icons.add,
            label: 'New chat',
            onPressed: () => _newChat(controller),
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
              children: [
                for (final (:chat, :forks) in gaiaForkGroups(controller.chats))
                  if (forks.isEmpty)
                    _tile(chat)
                  else if (controller.sidebar.collapsed.contains(chat.id))
                    _tile(chat, open: false)
                  else ...[
                    _tile(chat, open: true),
                    _ForkBracket(
                      key: ValueKey('forks of ${chat.id}'),
                      children: [for (final fork in forks) _tile(fork)],
                    ),
                  ],
              ],
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
    this.chevron,
    required this.trailing,
    required this.onTap,
  });

  final bool selected;
  final Widget title;

  /// Right after the title: a chat's fold for its forks.
  final Widget? chevron;
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
    // Not while it's being renamed: the field is what's under the cursor.
    final hovered = _hovered && widget.onTap != null;
    final lit = selected || hovered;
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
                  : hovered
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
                  child: widget.chevron == null
                      ? widget.title
                      : Row(
                          children: [
                            Flexible(child: widget.title),
                            const SizedBox(width: 4),
                            widget.chevron!,
                          ],
                        ),
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

/// Folds a chat's forks away under it, or shows them.
class _ForksChevron extends StatelessWidget {
  const _ForksChevron({required this.open, required this.onTap});

  final bool open;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: SystemMouseCursors.click,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: AnimatedRotation(
          turns: open ? 0 : -0.25,
          duration: const Duration(milliseconds: 150),
          child: Icon(
            Icons.expand_more,
            size: 16,
            color: DefaultTextStyle.of(context).style.color,
            semanticLabel: open ? 'Hide forks' : 'Show forks',
          ),
        ),
      ),
    ),
  );
}

/// How far a chat's forks sit in from it.
const _forkIndent = 22.0;

/// A chat's forks, in under it, with a line down from the chat that turns
/// into the last of them.
class _ForkBracket extends StatelessWidget {
  const _ForkBracket({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: const _ForkBracketPainter(),
    child: Padding(
      padding: const EdgeInsets.only(left: _forkIndent),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    ),
  );
}

class _ForkBracketPainter extends CustomPainter {
  const _ForkBracketPainter();

  @override
  void paint(Canvas canvas, Size size) {
    const x = 12.0;
    const radius = 6.0;
    // The last tile's middle: 36 high, then its 2 below.
    final y = size.height - 2 - 18;
    canvas.drawPath(
      Path()
        ..moveTo(x, 0)
        ..lineTo(x, y - radius)
        ..quadraticBezierTo(x, y, x + radius, y)
        // Short of the tile, which starts at _forkIndent.
        ..lineTo(_forkIndent - 4, y),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = Colors.white.withValues(alpha: 0.2),
    );
  }

  @override
  bool shouldRepaint(_ForkBracketPainter oldDelegate) => false;
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
    required this.controller,
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

  /// For the cards in replies (§10), which answer through it.
  final GaiaController controller;

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

  /// The latest reply as last built. The controller changes the list it
  /// gave last time in place, so the old widget's list can't tell.
  GaiaMessage? _reply;

  /// Each message's view as last built. Every change to Gaia rebuilds the
  /// list, and a message's view is costly to build: one whose message and
  /// placing haven't changed is given back as it was, which Flutter skips.
  final _views = <String, _MessageView>{};

  /// The messages this list has shown, in any chat, and those of them
  /// gathering in. Kept across chats, so one still running here isn't sent
  /// again on coming back to it.
  late Set<String> _seen;
  final _appearing = <String>{};

  /// Each built message's context, so the list can tell where it sits.
  final _placed = <String, BuildContext>{};

  /// What the list's scroll shows over it, as [_cutOff] finds it, and
  /// [scrolledUp] far enough from the newest to offer a way back down. Its
  /// own notifier, so scrolling rebuilds only what's over the list.
  final _over =
      ValueNotifier<
        ({String? pinned, String? chapter, bool chapterOff, bool scrolledUp})
      >((pinned: null, chapter: null, chapterOff: false, scrolledUp: false));
  bool _placing = false;

  /// The message whose chapter is being renamed in its divider, and its
  /// field.
  String? _renaming;
  final _rename = TextEditingController();
  final _renameFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _seen = {for (final message in widget.messages) message.id};
    _reply = _latestReply(widget.messages);
    // The chapter being read, for the rail, before any scroll.
    _place();
    _takeReveal();
  }

  /// The message a search just scrolled to, lit a moment so it's found.
  String? _flashed;

  /// Up to the message a search picked ([GaiaController.revealing]), once
  /// the list has it.
  void _takeReveal() {
    final id = widget.controller.revealing;
    if (id == null || !widget.messages.any((message) => message.id == id)) {
      return;
    }
    widget.controller.revealing = null;
    // Not mid-build, as scrolling notifies.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await _reveal(id);
      if (mounted) setState(() => _flashed = id);
    });
  }

  void _startRename(GaiaMessage message) {
    final title = message.chapter ?? '';
    _rename.value = TextEditingValue(
      text: title,
      selection: TextSelection(baseOffset: 0, extentOffset: title.length),
    );
    setState(() => _renaming = message.id);
    // Asked for, not autofocused, as the sidebar's rename.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _renaming == message.id) _renameFocus.requestFocus();
    });
  }

  /// Enter or a click away keeps the new title; Esc doesn't, nor does an
  /// empty one, which doesn't unpin.
  void _endRename({required bool keep}) {
    final id = _renaming;
    if (id == null) return;
    setState(() => _renaming = null);
    final message = widget.messages.where((m) => m.id == id).firstOrNull;
    if (keep && message != null) {
      unawaited(widget.controller.setChapter(message, _rename.text));
    }
  }

  /// What right-clicking a chapter's divider offers.
  List<GaiaMenuItem> _chapterMenu(GaiaMessage message) => [
    GaiaMenuItem(
      label: 'Rename chapter',
      icon: Icons.edit_outlined,
      onPressed: () => _startRename(message),
    ),
    GaiaMenuItem(
      label: 'Unpin chapter',
      icon: Icons.bookmark_remove_outlined,
      onPressed: () => unawaited(widget.controller.setChapter(message, null)),
    ),
  ];

  @override
  void didUpdateWidget(_Messages old) {
    super.didUpdateWidget(old);
    _place();
    _takeReveal();
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
    final was = _reply;
    final now = _reply = _latestReply(widget.messages);
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
    _rename.dispose();
    _renameFocus.dispose();
    _scroll.dispose();
    _over.dispose();
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

  /// [_over] afresh once the list's laid out.
  void _place() {
    if (_placing) return;
    _placing = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _placing = false;
      if (!mounted) return;
      final (:pinned, :chapter, :chapterOff) = _cutOff();
      final scrolledUp = _scroll.hasClients && _scroll.offset > 100;
      // Diagnostic for the to-bottom button stuck on screen.
      if (scrolledUp != _over.value.scrolledUp) {
        debugPrint(
          '[gaia] to-bottom ${scrolledUp ? 'shown' : 'hidden'}: offset '
          '${_scroll.hasClients ? _scroll.offset.round() : 'none'}, '
          'animations ${widget.controller.onScreen.value ? 'on' : 'off'}',
        );
      }
      _over.value = (
        pinned: pinned,
        chapter: chapter,
        chapterOff: chapterOff,
        scrolledUp: scrolledUp,
      );
    });
    // Told of a change after a frame, as of metrics, there may be no next.
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  /// [pinned]: the user's message, with text, heading the turn across the
  /// list's top, when that's scrolled above it. [chapter]: the message
  /// heading the chapter across the top, and [chapterOff] when its divider
  /// is scrolled above it.
  ({String? pinned, String? chapter, bool chapterOff}) _cutOff() {
    const none = (pinned: null, chapter: null, chapterOff: false);
    final list = context.findRenderObject();
    if (list is! RenderBox) return none;
    final messages = widget.messages;
    for (final (i, message) in messages.indexed) {
      // Unbuilt messages have no place yet.
      final box = _placed[message.id]?.findRenderObject();
      if (box is! RenderBox || !box.hasSize) continue;
      final top = box.localToGlobal(Offset.zero, ancestor: list).dy;
      if (top + box.size.height <= 0) continue;
      // The first message reaching below the top: the one across it.
      final prompt = messages.lastIndexWhere(
        (message) => message.role == GaiaMessageRole.user,
        i,
      );
      var chapter = messages.lastIndexWhere(
        (message) => message.chapter != null,
        i,
      );
      // At the bottom, a chapter too near the end to reach the top is still
      // the one being read: the last whose divider is on screen.
      if (_scroll.hasClients &&
          _scroll.offset <= _scroll.position.minScrollExtent) {
        final last = messages.lastIndexWhere((message) {
          if (message.chapter == null) return false;
          final box = _placed[message.id]?.findRenderObject();
          return box is RenderBox &&
              box.hasSize &&
              box.localToGlobal(Offset.zero, ancestor: list).dy <
                  list.size.height;
        });
        if (last > chapter) chapter = last;
      }
      return (
        pinned:
            prompt < 0 ||
                (prompt == i && top >= 0) ||
                _pinnedLabel(messages[prompt]).isEmpty
            ? null
            : messages[prompt].id,
        chapter: chapter < 0 ? null : messages[chapter].id,
        // One below the top, from the bottom, has its divider in view.
        chapterOff: chapter >= 0 && chapter <= i && !(chapter == i && top >= 0),
      );
    }
    return none;
  }

  /// Up to [id]'s message, its top to the list's.
  Future<void> _reveal(String id) async {
    // Not built, the list is laid out around it, just above the top, rather
    // than through every message between, each costly to build; then the
    // last of the way is a glide.
    final i = widget.messages.indexWhere((message) => message.id == id);
    if (_placed[id] == null && i >= 0) {
      final built = _placed.values.firstOrNull;
      final at = built == null
          ? null
          : GaiaSteadyList.jumpTo(built, widget.messages.length - 1 - i);
      if (at == null) return;
      _scroll.jumpTo(max(0.0, at - _scroll.position.viewportDimension));
      await WidgetsBinding.instance.endOfFrame;
    }
    final box = _placed[id]?.findRenderObject();
    if (!mounted || box is! RenderBox) return;
    // Reversed, so its top to the list's.
    double offsetOf(RenderBox box) =>
        RenderAbstractViewport.of(box).getOffsetToReveal(box, 1).offset;
    var target = offsetOf(box);
    if (MediaQuery.disableAnimationsOf(context)) {
      _scroll.jumpTo(target);
    } else {
      final distance = target - _scroll.offset;
      final position = _scroll.position as ScrollPositionWithSingleContext;
      final glide = _GlideToMessage(
        position,
        target: () {
          final now = _placed[id]?.findRenderObject();
          if (now is RenderBox && now.attached) target = offsetOf(now);
          return target;
        },
        distance: distance,
        // Longer the further it goes, so a long way isn't a blur.
        duration: Duration(
          milliseconds: (250 + distance.abs() / 8).clamp(250, 600).round(),
        ),
        curve: Curves.easeInOutCubic,
        vsync: position.context.vsync,
      );
      position.beginActivity(glide);
      await glide.done;
    }
  }

  /// Down to the newest message.
  void _toBottom() {
    // Diagnostic for the to-bottom button stuck on screen.
    debugPrint('[gaia] to-bottom tapped');
    if (!_scroll.hasClients) return;
    if (MediaQuery.disableAnimationsOf(context)) return _scroll.jumpTo(0);
    _scroll.animateTo(
      0,
      // Longer the further it goes, as in [_reveal].
      duration: Duration(
        milliseconds: (250 + _scroll.offset / 8).clamp(250, 600).round(),
      ),
      curve: Curves.easeInOutCubic,
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
      onRenameChapter: _startRename,
      controller: widget.controller,
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
        // The rail's entries (GAIA_CHAPTERS_HLD.md §6.3): the chat's start,
        // while no chapter heads it, then each chapter in order.
        final chapters = [
          if (messages.any((message) => message.chapter != null) &&
              messages.first.chapter == null)
            (id: messages.first.id, title: 'Start of chat'),
          for (final message in messages)
            if (message.chapter case final title?)
              (id: message.id, title: title),
        ];
        // Clear of the chapter rail where the gutter's too narrow.
        final left = chapters.isEmpty ? gutter : max(gutter, _railWidth);
        final list = ScrollConfiguration(
          // Scrolls without a bar.
          behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
          child: GaiaSteadyList.builder(
            steady: true,
            controller: _scroll,
            reverse: true,
            padding: EdgeInsets.fromLTRB(left, 16, gutter, 4),
            // Clear of the composer's chips, which float over the list.
            foot: const GaiaFloatGap(),
            itemCount: messages.length,
            // A new message shifts the rest along; found by their keys,
            // they keep their views rather than each taking its neighbour's.
            findChildIndexCallback: (key) =>
                indices[(key as ValueKey<String>).value],
            itemBuilder: (context, index) {
              final i = messages.length - 1 - index;
              final message = messages[i];
              final movedReply = _replyHeadedBy(messages, i);
              final switched = movedReply == null
                  ? null
                  : _switchedFrom(messages, movedReply);
              final moved = movedReply == null || switched != null
                  ? null
                  : _movedAccount(messages, movedReply, widget.controller);
              final view = _view(
                message,
                gutter: left,
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
                child: _Placed(
                  id: message.id,
                  placed: _placed,
                  // A Column with or without a divider, since a prompt gets its
                  // divider once its reply starts: its view must carry on.
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Above a vendor divider: it heads the section.
                      if (message.chapter case final chapter?)
                        _ChapterDivider(
                          title: chapter,
                          renaming: _renaming == message.id,
                          rename: _rename,
                          renameFocus: _renameFocus,
                          onEndRename: _endRename,
                          menu: () => _chapterMenu(message),
                        ),
                      if (switched != null || moved != null)
                        _VendorDivider(
                          text: moved == null
                              ? 'Switched to '
                                    '${kGaiaClis[messages[movedReply!].adapter]?.name ?? messages[movedReply].adapter} '
                                    '· a transcript carried over'
                              : 'Switched to $moved',
                        ),
                      _Flash(
                        on: _flashed == message.id,
                        onDone: () {
                          if (mounted && _flashed == message.id) {
                            setState(() => _flashed = null);
                          }
                        },
                        child: view,
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        );
        return NotificationListener<Notification>(
          onNotification: (notification) {
            // The list's own, not a code block's scrolled sideways.
            if ((notification is ScrollNotification &&
                    notification.depth == 0) ||
                (notification is ScrollMetricsNotification &&
                    notification.depth == 0)) {
              _place();
            }
            return false;
          },
          child: Stack(
            children: [
              list,
              Positioned(
                top: 8,
                left: left,
                right: gutter,
                child: ValueListenableBuilder(
                  valueListenable: _over,
                  builder: (context, over, _) {
                    final pinned = messages
                        .where((message) => message.id == over.pinned)
                        .firstOrNull;
                    final chapter = over.chapterOff
                        ? messages
                              .where(
                                (message) =>
                                    message.id == over.chapter &&
                                    message.chapter != null,
                              )
                              .firstOrNull
                        : null;
                    return AnimatedSwitcher(
                      duration: const Duration(milliseconds: 150),
                      transitionBuilder: gaiaPinnedFade,
                      child: pinned == null && chapter == null
                          ? const SizedBox.shrink()
                          // One key for every prompt, so only coming and
                          // going fades the box.
                          : GaiaPinnedPrompt(
                              key: const ValueKey('pinned'),
                              id: pinned?.id,
                              text: pinned == null
                                  ? null
                                  : _pinnedLabel(pinned),
                              onTap: pinned == null
                                  ? null
                                  : () => _reveal(pinned.id),
                              chapterId: chapter?.id,
                              chapter: chapter?.chapter,
                              onChapterTap: chapter == null
                                  ? null
                                  : () => _reveal(chapter.id),
                            ),
                    );
                  },
                ),
              ),
              if (chapters.isNotEmpty)
                Positioned(
                  top: 8,
                  left: 0,
                  child: ValueListenableBuilder(
                    valueListenable: _over,
                    builder: (context, over, _) => _ChapterRail(
                      chapters: chapters,
                      current:
                          chapters
                              .where((entry) => entry.id == over.chapter)
                              .map((entry) => entry.id)
                              .firstOrNull ??
                          chapters.first.id,
                      onPick: (id) => unawaited(_reveal(id)),
                    ),
                  ),
                ),
              Positioned(
                bottom: 20,
                left: 0,
                right: 0,
                // Above the composer's chips under it.
                child: GaiaAboveFloat(
                  child: Center(
                    child: ValueListenableBuilder(
                      valueListenable: _over,
                      // Not clicked while it fades out.
                      builder: (context, over, _) => IgnorePointer(
                        ignoring: !over.scrolledUp,
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 150),
                          transitionBuilder: gaiaPinnedFade,
                          child: over.scrolledUp
                              ? _ToBottom(onTap: _toBottom)
                              : const SizedBox.shrink(),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Back down to the newest message, while scrolled up from it: round, in
/// the pinned prompt's colours.
class _ToBottom extends StatelessWidget {
  const _ToBottom({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: gaiaPromptColor(theme),
      shape: const CircleBorder(),
      elevation: 2,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Icon(
            Icons.keyboard_double_arrow_down_rounded,
            size: 18,
            color: theme.colorScheme.primary,
          ),
        ),
      ),
    );
  }
}

/// Notes its context in [placed], under [id], while it's built.
class _Placed extends StatefulWidget {
  const _Placed({required this.id, required this.placed, required this.child});

  final String id;
  final Map<String, BuildContext> placed;
  final Widget child;

  @override
  State<_Placed> createState() => _PlacedState();
}

class _PlacedState extends State<_Placed> {
  @override
  void initState() {
    super.initState();
    widget.placed[widget.id] = context;
  }

  @override
  void dispose() {
    if (widget.placed[widget.id] == context) widget.placed.remove(widget.id);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Lights [child] in the accent as [on] turns true, and fades it back out,
/// then calls [onDone]: a message a search scrolled to, so it's found.
class _Flash extends StatefulWidget {
  const _Flash({required this.on, required this.onDone, required this.child});

  final bool on;
  final VoidCallback onDone;
  final Widget child;

  @override
  State<_Flash> createState() => _FlashState();
}

class _FlashState extends State<_Flash> with SingleTickerProviderStateMixin {
  late final _fade = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  );

  @override
  void initState() {
    super.initState();
    if (widget.on) _run();
  }

  @override
  void didUpdateWidget(_Flash old) {
    super.didUpdateWidget(old);
    if (widget.on && !old.on) _run();
  }

  @override
  void dispose() {
    _fade.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    try {
      await _fade.forward(from: 0).orCancel;
    } on TickerCanceled {
      // Scrolled away mid-flash: done, or it would flash again rebuilt.
      if (!mounted) widget.onDone();
      return;
    }
    if (mounted) widget.onDone();
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return AnimatedBuilder(
      animation: _fade,
      builder: (context, child) {
        // Held lit for the first third, then faded out.
        final t = _fade.isAnimating
            ? 1 -
                  Curves.easeOut.transform(
                    ((_fade.value - 1 / 3) * 1.5).clamp(0.0, 1.0),
                  )
            : 0.0;
        // Unlit, nothing painted; kept in the tree, so the message isn't
        // rebuilt afresh as it lights.
        return DecoratedBox(
          decoration: t == 0
              ? const BoxDecoration()
              : BoxDecoration(
                  color: accent.withValues(alpha: 0.1 * t),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: accent.withValues(alpha: 0.4 * t)),
                ),
          child: child,
        );
      },
      child: widget.child,
    );
  }
}

/// What [message] shows pinned over the chat: its first line, or failing
/// that what it attached, as "2 images, PDF file".
String _pinnedLabel(GaiaMessage message) {
  final text = message.text.trim();
  if (text.isNotEmpty) return text.split('\n').first;
  final images = message.parts.whereType<GaiaImagePart>().length;
  final files = message.parts.whereType<GaiaFilePart>().toList();
  final type = files.length == 1 ? gaiaFileType(files.single) : null;
  return [
    if (images > 0) images == 1 ? '1 image' : '$images images',
    if (type == 'Folder' || type == 'File')
      type
    else if (type != null)
      '$type file'
    else if (files.length > 1)
      '${files.length} files',
  ].join(', ');
}

/// Scrolling to a message that a reply growing below keeps moving along the
/// list: what's animated is the distance left to it, as of each frame, rather
/// than the way to where it was when this started.
class _GlideToMessage extends DrivenScrollActivity {
  _GlideToMessage(
    super.delegate, {
    required this.target,
    required double distance,
    required super.duration,
    required super.curve,
    required super.vsync,
  }) : super(from: distance, to: 0);

  /// The list's offset with the message in place, now.
  final double Function() target;

  @override
  bool applyMoveTo(double value) => super.applyMoveTo(target() - value);
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
  // A reply that failed before any output may never have carried the
  // transcript over (a CLI command refused before catching up), so the
  // divider waits for one that got going. One that streamed some and then
  // failed had its session, and the transcript with it.
  bool neverStarted(GaiaMessage message) =>
      message.status == GaiaMessageStatus.error && message.parts.isEmpty;
  if (messages[index].role != GaiaMessageRole.assistant ||
      adapter == null ||
      neverStarted(messages[index])) {
    return null;
  }
  for (var i = index - 1; i >= 0; i--) {
    final earlier = messages[i];
    if (earlier.role != GaiaMessageRole.assistant ||
        earlier.adapter == null ||
        neverStarted(earlier)) {
      continue;
    }
    return earlier.adapter == adapter ? null : earlier.adapter;
  }
  return null;
}

/// The name of [index]'s account when it's a reply on another account than
/// the reply before it, on the same adapter: the point a chat moved (§6.5).
String? _movedAccount(
  List<GaiaMessage> messages,
  int index,
  GaiaController controller,
) {
  final message = messages[index];
  final adapter = message.adapter;
  if (message.role != GaiaMessageRole.assistant || adapter == null) return null;
  final account = message.account ?? kGaiaDefaultAccountId;
  for (var i = index - 1; i >= 0; i--) {
    final earlier = messages[i];
    if (earlier.role != GaiaMessageRole.assistant || earlier.adapter == null) {
      continue;
    }
    if (earlier.adapter != adapter ||
        (earlier.account ?? kGaiaDefaultAccountId) == account) {
      return null;
    }
    return controller
            .accountsFor(adapter)
            .where((known) => known.id == account)
            .firstOrNull
            ?.label ??
        'another account';
  }
  return null;
}

/// The reply whose divider, if it has one, would go before [index] (§6.5,
/// §7.4): a prompt carries its reply's, and a reply only its own when it has no
/// prompt.
int? _replyHeadedBy(List<GaiaMessage> messages, int index) {
  bool isPrompt(int i) => messages[i].role == GaiaMessageRole.user;
  if (isPrompt(index)) {
    return index + 1 < messages.length && !isPrompt(index + 1)
        ? index + 1
        : null;
  }
  return index > 0 && isPrompt(index - 1) ? null : index;
}

class _VendorDivider extends StatelessWidget {
  const _VendorDivider({required this.text});

  final String text;

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
            child: Text(text, style: muted),
          ),
          const Expanded(child: Divider()),
        ],
      ),
    );
  }
}

/// Above a message that starts a chapter (GAIA_CHAPTERS_HLD.md §6.2): its
/// title in the accent, with a bookmark, in [_VendorDivider]'s look. Renamed
/// in place, as the sidebar renames a chat.
class _ChapterDivider extends StatelessWidget {
  const _ChapterDivider({
    required this.title,
    required this.renaming,
    required this.rename,
    required this.renameFocus,
    required this.onEndRename,
    required this.menu,
  });

  final String title;
  final bool renaming;
  final TextEditingController rename;
  final FocusNode renameFocus;
  final void Function({required bool keep}) onEndRename;
  final List<GaiaMenuItem> Function() menu;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    final style = theme.textTheme.labelSmall?.copyWith(color: accent);
    final label = renaming
        ? SizedBox(
            width: 240,
            child: CallbackShortcuts(
              bindings: {
                const SingleActivator(LogicalKeyboardKey.escape): () =>
                    onEndRename(keep: false),
              },
              child: TextField(
                controller: rename,
                focusNode: renameFocus,
                style: style,
                decoration: const InputDecoration(
                  isCollapsed: true,
                  filled: false,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                ),
                contextMenuBuilder: gaiaTextMenu,
                onSubmitted: (_) => onEndRename(keep: true),
                onTapOutside: (_) => onEndRename(keep: true),
              ),
            ),
          )
        : Flexible(
            child: Text(title, style: style, overflow: TextOverflow.ellipsis),
          );
    return GestureDetector(
      onSecondaryTapUp: (details) =>
          showGaiaMenu(context, details.globalPosition, menu()),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Row(
          children: [
            const Expanded(child: Divider()),
            const SizedBox(width: 8),
            Icon(Icons.bookmark, size: 12, color: accent),
            const SizedBox(width: 4),
            label,
            const SizedBox(width: 8),
            const Expanded(child: Divider()),
          ],
        ),
      ),
    );
  }
}

/// How much of the chat's left the chapter rail takes, which the pinned bar
/// keeps clear of.
const _railWidth = 44.0;

/// The chat's chapters as faint lines down its top left
/// (GAIA_CHAPTERS_HLD.md §6.3): the one being read longer and in the accent,
/// the lines easing between lengths as the chat scrolls from one chapter to
/// the next. Hovered, they open into the chapters' titles, each clicked to
/// glide to it.
class _ChapterRail extends StatefulWidget {
  const _ChapterRail({
    required this.chapters,
    required this.current,
    required this.onPick,
  });

  final List<({String id, String title})> chapters;

  /// The id of the chapter being read.
  final String current;
  final void Function(String id) onPick;

  @override
  State<_ChapterRail> createState() => _ChapterRailState();
}

class _ChapterRailState extends State<_ChapterRail> {
  bool _open = false;

  static const _ease = Duration(milliseconds: 250);

  /// A chapter's dash, in the rail and the list alike.
  Widget _dash(bool current, ThemeData theme, {double long = 18}) =>
      AnimatedContainer(
        duration: _ease,
        curve: Curves.easeOutCubic,
        width: current ? long : 10,
        height: 2,
        decoration: BoxDecoration(
          color: current
              ? theme.colorScheme.primary
              : theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(1),
        ),
      );

  Widget _lines(ThemeData theme) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 10, 8),
    child: SizedBox(
      width: _railWidth - 26,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 6,
        children: [
          for (final chapter in widget.chapters)
            _dash(chapter.id == widget.current, theme),
        ],
      ),
    ),
  );

  Widget _list(ThemeData theme) => Padding(
    // Its first dash where the rail's was.
    padding: const EdgeInsets.only(left: 6),
    child: Material(
      color: theme.colorScheme.surfaceContainerHigh,
      elevation: 6,
      borderRadius: BorderRadius.circular(10),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 300, maxHeight: 360),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(4),
          child: IntrinsicWidth(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final chapter in widget.chapters)
                  _row(chapter, chapter.id == widget.current, theme),
              ],
            ),
          ),
        ),
      ),
    ),
  );

  Widget _row(
    ({String id, String title}) chapter,
    bool current,
    ThemeData theme,
  ) => Material(
    color: current
        ? theme.colorScheme.onSurface.withValues(alpha: 0.08)
        : Colors.transparent,
    borderRadius: BorderRadius.circular(6),
    child: InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: () {
        setState(() => _open = false);
        widget.onPick(chapter.id);
      },
      child: Padding(
        padding: const EdgeInsets.fromLTRB(6, 7, 12, 7),
        child: Row(
          children: [
            SizedBox(
              width: 14,
              child: Align(
                alignment: Alignment.centerLeft,
                child: _dash(current, theme, long: 14),
              ),
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                chapter.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: current
                      ? theme.colorScheme.onSurface
                      : theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return MouseRegion(
      onEnter: (_) => setState(() => _open = true),
      onExit: (_) => setState(() => _open = false),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 150),
        transitionBuilder: (child, animation) => FadeTransition(
          opacity: animation,
          child: ScaleTransition(
            alignment: Alignment.topLeft,
            scale: Tween(begin: 0.96, end: 1.0).animate(animation),
            child: child,
          ),
        ),
        layoutBuilder: (current, previous) => Stack(
          alignment: Alignment.topLeft,
          children: [...previous, ?current],
        ),
        child: _open
            ? KeyedSubtree(key: const ValueKey('list'), child: _list(theme))
            : KeyedSubtree(key: const ValueKey('rail'), child: _lines(theme)),
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
    required this.onRenameChapter,
    required this.controller,
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

  /// Its chapter's title to edit in its divider.
  final void Function(GaiaMessage message) onRenameChapter;
  final GaiaController controller;

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
      final control = message.parts.whereType<GaiaElementPart>().firstOrNull;
      final quotes = message.parts.whereType<GaiaQuotePart>();
      // Images and files float on their own above the prompt's bubble; a
      // message of only those has no bubble. Just sent, its text and
      // attachments gather in out of particles.
      return _HoverActions(
        alignment: Alignment.centerRight,
        inset: 0,
        copy: message.text,
        actions: _actions,
        at: message.createdAt,
        controller: controller,
        child: GaiaAppear(
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
              if (window != null ||
                  control != null ||
                  quotes.isNotEmpty ||
                  message.text.isNotEmpty)
                _bubble(
                  gaiaPromptColor(theme),
                  Alignment.centerRight,
                  GaiaAppearPart(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        if (window != null) ...[
                          _ContextChip(label: window.label),
                          const SizedBox(height: 6),
                        ],
                        if (control != null) ...[
                          _ContextChip(
                            label: control.label,
                            icon: Icons.ads_click,
                          ),
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
                        _forking(muted),
                      ],
                    ),
                  ),
                )
              else
                const SizedBox(height: 4),
            ],
          ),
        ),
      );
    }
    final status = switch (message.status) {
      GaiaMessageStatus.streaming || GaiaMessageStatus.complete => null,
      // What it got as far as stays above this (§6.5).
      GaiaMessageStatus.error when gaiaRunLimited(message.error ?? '') =>
        'Stopped at the usage limit${_detail(message.error)}',
      GaiaMessageStatus.error => 'Error${_detail(message.error)}',
      GaiaMessageStatus.cancelled => 'Stopped',
      GaiaMessageStatus.interrupted => 'Interrupted',
      GaiaMessageStatus.aborted => 'Aborted',
    };
    final streaming = message.status == GaiaMessageStatus.streaming;
    // The orb sits just left of Gaia's text, in the gutter and the bubble's
    // padding. Where those are narrower than the orb and its margin, every
    // reply of hers is indented to make room, so none of them moves when one
    // starts or finishes.
    final indent = max(
      0.0,
      _orbMargin + kGaiaOrbSize + _orbGap - gutter - _bubblePadding.left,
    );
    // The chat's own background, so Gaia's bubble shows only as the stars
    // fading behind it.
    final bubble = _bubble(
      indent: indent,
      padding: _replyPadding,
      theme.scaffoldBackgroundColor,
      Alignment.centerLeft,
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final (index, part) in message.parts.indexed)
            switch (part) {
              GaiaTextPart(:final text, :final checks) => _MessageText(
                text: text,
                markdown: true,
                menu: _menu,
                checks: checks,
                onCheck: (task) => controller.toggleCheck(message, index, task),
              ),
              GaiaActivityPart(:final tools) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                // Rebuilt with the controller too: a result is kept after its
                // call shows.
                child: ListenableBuilder(
                  listenable: controller,
                  builder: (context, _) => GaiaActivityChip(
                    label: _activity(tools),
                    part: part,
                    hasResult: (id) =>
                        controller.hasToolResult(message.chatId, id),
                    result: (id) => controller.toolResult(message.chatId, id),
                  ),
                ),
              ),
              // Rebuilt with the controller, not the message: whether it's
              // waiting and what's picked aren't on the message.
              GaiaCardPart() => ListenableBuilder(
                listenable: controller,
                builder: (context, _) => GaiaCardView(
                  card: part,
                  waiting: controller.cards.isWaiting(part.id),
                  picks: controller.cardPicks(part.id),
                  fields: part.kind == GaiaCardKind.proposal
                      ? controller.proposalFields(part)
                      : null,
                  sendKey: '${_sendCombo(controller)}',
                  onPick: (index) => controller.pickCardOption(part, index),
                  onAllow: part.kind == GaiaCardKind.proposal
                      ? () => controller.acceptProposal(part)
                      : () => controller.allowCard(part),
                  onReject: () => controller.rejectCard(part),
                  onEdit: (key, value) =>
                      controller.editProposal(part, key, value),
                  onAcceptAll: controller.openProposals.length > 1
                      ? controller.acceptAllProposals
                      : null,
                  onRunAll: () => controller.approveControl(part, once: true),
                  onRunNext: () => controller.approveControl(part, once: false),
                ),
              ),
              // Only the user's messages carry attachments and context.
              GaiaImagePart() ||
              GaiaFilePart() ||
              GaiaContextPart() ||
              GaiaElementPart() ||
              GaiaQuotePart() ||
              GaiaUnknownPart() => const SizedBox.shrink(),
            },
          // Rebuilt with the controller: a retry isn't on the message.
          if (streaming)
            ListenableBuilder(
              listenable: controller,
              builder: (context, _) =>
                  switch (controller.retryingOf(message.id)) {
                    null => const SizedBox.shrink(),
                    final retry => Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: _RetryLine(
                        key: ValueKey(retry),
                        retry: retry,
                        style: muted?.copyWith(color: kGaiaStatusRose),
                      ),
                    ),
                  },
            ),
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
          _forking(muted),
        ],
      ),
    );
    final tier = orbTier;
    // Just off the text, however wide the gutter, and level with
    // the newest line: the bubble's margin and padding below it, then half a
    // line. A Stack with or without the orb, so the bubble isn't built
    // afresh as the orb comes and goes. Its actions' icons line up with its
    // text; none while it streams.
    return _HoverActions(
      alignment: Alignment.centerLeft,
      inset: indent + _bubblePadding.left - kGaiaActionIconPadding,
      above: _HoverActions._above - _replyPadding.bottom,
      copy: message.text,
      actions: streaming ? null : _actions,
      label: controller.replyLabel(message),
      at: message.createdAt,
      controller: controller,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          bubble,
          if (tier != null)
            Positioned(
              left: indent + _bubblePadding.left - kGaiaOrbSize - _orbGap,
              bottom:
                  _bubbleMargin + _replyPadding.bottom + 10 - kGaiaOrbSize / 2,
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
      ),
    );
  }

  /// A message's rectangle, hugging its text. Nearly opaque, so the
  /// starfield behind it is almost gone but the stars around it aren't.
  Widget _bubble(
    Color color,
    Alignment alignment,
    Widget child, {
    double indent = 0,
    EdgeInsets padding = _bubblePadding,
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
          padding: padding,
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
    ..._actions(),
    if (message.chapter != null) ...[
      GaiaMenuItem(
        label: 'Rename chapter',
        icon: Icons.edit_outlined,
        onPressed: () => onRenameChapter(message),
      ),
      GaiaMenuItem(
        label: 'Unpin chapter',
        icon: Icons.bookmark_remove_outlined,
        onPressed: () => unawaited(controller.setChapter(message, null)),
      ),
    ],
  ];

  /// What the bar under the message offers on hover after copying it, as
  /// Claude's desktop app does: those of [_menu] that act on the message.
  List<GaiaMenuItem> _actions() => [
    if (message.role == GaiaMessageRole.user &&
        (message.text.isNotEmpty ||
            message.parts.any((part) => part is GaiaQuotePart)))
      GaiaMenuItem(
        label: 'Edit & resend',
        icon: Icons.edit_outlined,
        onPressed: () => onEdit(message),
      ),
    // Not a reply still streaming, which no fork copies (§3).
    if (message.status != GaiaMessageStatus.streaming)
      GaiaMenuItem(
        label: 'Fork from here',
        icon: Icons.call_split,
        onPressed: () => unawaited(controller.forkChat(message)),
      ),
    // Not where nothing would be dropped, or what's dropped is still coming
    // (GAIA_REWIND_HLD.md §3).
    if (controller.canRewind(message))
      GaiaMenuItem(
        label: 'Rewind to here',
        icon: Icons.history,
        onPressed: () => unawaited(controller.rewindChat(message)),
      ),
    // Not a reply still streaming, whose text can still change
    // (GAIA_CHAPTERS_HLD.md §6.1).
    if (controller.canPinChapter(message))
      GaiaMenuItem(
        label: 'Pin as chapter',
        icon: Icons.bookmark_add_outlined,
        onPressed: () => unawaited(controller.pinChapter(message)),
      ),
  ];

  /// Selectable, with the message's actions in its right-click menu. Gaia's
  /// as Markdown (§9.5); the user's as they typed it.
  Widget _text(String text, {bool markdown = false}) =>
      _MessageText(text: text, markdown: markdown, menu: _menu);

  /// "Forking…" while a fork from here waits on a prompt just sent. Rebuilt
  /// with the controller: that isn't on the message.
  Widget _forking(TextStyle? style) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => controller.forkingAt != message.id
        ? const SizedBox.shrink()
        : Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const GaiaSpinner(size: 14, label: 'Forking'),
                const SizedBox(width: 6),
                Text('Forking…', style: style),
              ],
            ),
          ),
  );

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

  /// Below each bubble, above its actions' bar.
  static const _bubbleMargin = 0.0;

  /// Between the orb and Gaia's text.
  static const _orbGap = 10.0;

  /// At least this between the orb and the chat's left edge.
  static const _orbMargin = 16.0;

  /// Gaia's: a little below, so her last line clears the faint bubble, which
  /// her actions' bar makes up for, sitting as far under her text as the
  /// user's do under their bubble.
  static const _replyPadding = EdgeInsets.fromLTRB(12, 8, 12, 4);

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

/// "3:42 PM" today, "Yesterday", "Mon" within the week, "Sep 20" this year,
/// "Sep 20, 2025" before: when a message was sent, rounded to its day.
String gaiaWhenLabel(DateTime at, DateTime now) {
  final local = at.toLocal();
  final days = DateTime.utc(
    now.year,
    now.month,
    now.day,
  ).difference(DateTime.utc(local.year, local.month, local.day)).inDays;
  if (days <= 0) return formatTime12Hour(local);
  if (days == 1) return 'Yesterday';
  if (days < 7) return DateFormat.E().format(local);
  if (local.year == now.year) return DateFormat.MMMd().format(local);
  return DateFormat.yMMMd().format(local);
}

/// A message, with a bar of faint icons under it while the cursor's anywhere
/// across its row, as in Claude's desktop app: Copy, then [actions]. The bar's
/// room is always kept, so nothing moves as it shows.
class _HoverActions extends StatefulWidget {
  const _HoverActions({
    required this.alignment,
    required this.inset,
    required this.copy,
    required this.actions,
    required this.controller,
    required this.child,
    this.above = _above,
    this.label,
    this.at,
  });

  /// The bar's side: the message's own.
  final Alignment alignment;

  /// From the bar's side to its first icon's button.
  final double inset;

  /// The text Copy puts on the clipboard; no Copy when null or empty.
  final String? copy;

  /// Null for no bar.
  final List<GaiaMenuItem> Function()? actions;

  /// What [actions] depend on beyond the message, as whether a rewind's
  /// possible.
  final GaiaController controller;
  final Widget child;

  /// Between the message and the icons' hover boxes.
  final double above;

  /// Muted text after the icons, as which model wrote a reply.
  final String? label;

  /// When the message was sent, as a muted "Yesterday" with the exact time
  /// on hover: past the icons on the left, before them on the right.
  final DateTime? at;

  /// Between the message and the icons' hover boxes, and below them, as in
  /// Claude's desktop app.
  static const _above = 4.0;
  static const _below = 8.0;

  @override
  State<_HoverActions> createState() => _HoverActionsState();
}

class _HoverActionsState extends State<_HoverActions>
    with SingleTickerProviderStateMixin {
  var _hovered = false;

  /// Focus on the row or one of its icons, which shows the bar as hovering
  /// does, so Tab reaches its actions.
  var _focused = false;

  /// The bar's opacity; it's built only while not dismissed.
  late final _fade = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 150),
  )..addStatusListener((_) => setState(() {}));

  /// Copy's icon a tick for a moment after copying.
  var _copied = false;
  Timer? _copiedTimer;

  @override
  void didUpdateWidget(_HoverActions oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A reply that finishes streaming under the cursor fades its bar in.
    _sync();
  }

  @override
  void dispose() {
    _copiedTimer?.cancel();
    _fade.dispose();
    super.dispose();
  }

  void _hover(bool hovered) {
    _hovered = hovered;
    _sync();
  }

  void _focus(bool focused) {
    _focused = focused;
    _sync();
  }

  void _sync() {
    if ((_hovered || _focused) && widget.actions != null) {
      unawaited(_fade.forward());
    } else {
      unawaited(_fade.reverse());
    }
  }

  void _copy(String text) {
    unawaited(Clipboard.setData(ClipboardData(text: text)));
    _copiedTimer?.cancel();
    setState(() => _copied = true);
    _copiedTimer = Timer(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final actions = widget.actions;
    final shown = (_hovered || _focused) && actions != null;
    final muted = Theme.of(context).textTheme.bodySmall?.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    final right = widget.alignment == Alignment.centerRight;
    final at = widget.at?.toLocal();
    final when = at == null
        ? null
        : Padding(
            padding: right
                ? const EdgeInsets.only(right: 6)
                : const EdgeInsets.only(left: 6),
            child: Tooltip(
              message: DateFormat.yMMMMEEEEd().add_jm().format(at),
              child: Text(gaiaWhenLabel(at, DateTime.now()), style: muted),
            ),
          );
    return Focus(
      onFocusChange: _focus,
      child: MouseRegion(
        opaque: false,
        hitTestBehavior: HitTestBehavior.translucent,
        onEnter: (_) => _hover(true),
        onExit: (_) => _hover(false),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            widget.child,
            SizedBox(height: widget.above),
            SizedBox(
              height: kGaiaActionIconExtent,
              child: _fade.isDismissed || actions == null
                  ? null
                  : IgnorePointer(
                      ignoring: !shown,
                      child: FadeTransition(
                        opacity: _fade,
                        child: Align(
                          alignment: widget.alignment,
                          child: Padding(
                            padding: widget.alignment == Alignment.centerRight
                                ? EdgeInsets.only(right: widget.inset)
                                : EdgeInsets.only(left: widget.inset),
                            // Rebuilt with the controller: what's offered isn't
                            // all on the message.
                            child: ListenableBuilder(
                              listenable: widget.controller,
                              builder: (context, _) => Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (right && when != null) when,
                                  if (widget.copy case final text?
                                      when text.isNotEmpty)
                                    GaiaActionIcon(
                                      label: _copied ? 'Copied' : 'Copy',
                                      icon: _copied ? Icons.check : Icons.copy,
                                      onPressed: () => _copy(text),
                                    ),
                                  for (final action in actions())
                                    GaiaActionIcon(
                                      label: action.label,
                                      icon: action.icon!,
                                      onPressed: action.onPressed,
                                    ),
                                  if (widget.label case final label?)
                                    Padding(
                                      padding: const EdgeInsets.only(left: 6),
                                      child: Text(label, style: muted),
                                    ),
                                  if (!right && when != null) when,
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
            ),
            const SizedBox(height: _HoverActions._below),
          ],
        ),
      ),
    );
  }
}

/// "Connection lost, retrying in 12s (3/10)", counting down to the attempt,
/// then "retrying now" while it runs.
class _RetryLine extends StatefulWidget {
  const _RetryLine({super.key, required this.retry, this.style});

  final GaiaRetry retry;
  final TextStyle? style;

  @override
  State<_RetryLine> createState() => _RetryLineState();
}

class _RetryLineState extends State<_RetryLine> {
  late final Timer _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      setState(() {});
      if (_left == null) _tick.cancel();
    });
  }

  @override
  void dispose() {
    _tick.cancel();
    super.dispose();
  }

  /// Whole seconds to the attempt, rounded up; null once it's due, or
  /// when that isn't known.
  int? get _left {
    final due = widget.retry.due;
    if (due == null) return null;
    final ms = due.difference(DateTime.now()).inMilliseconds;
    return ms <= 0 ? null : (ms / 1000).ceil();
  }

  @override
  Widget build(BuildContext context) {
    final GaiaRetrying(:attempt, :maxRetries, :status) = widget.retry.retry;
    final left = _left;
    final when = left != null
        ? 'retrying in ${left}s'
        : widget.retry.due == null
        ? 'retrying'
        : 'retrying now';
    return Text(
      '${status == null ? 'Connection lost' : 'API error $status'}, '
      '$when ($attempt/$maxRetries)…',
      style: widget.style,
    );
  }
}

/// A message's text, selectable, with [menu] after its own buttons in its
/// right-click menu.
class _MessageText extends StatefulWidget {
  const _MessageText({
    required this.text,
    required this.markdown,
    required this.menu,
    this.checks = const {},
    this.onCheck,
  });

  final String text;
  final bool markdown;

  /// As on [GaiaMarkdown].
  final Set<int> checks;
  final ValueChanged<int>? onCheck;

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

  Widget _selectionMenu(BuildContext context, SelectableRegionState state) =>
      gaiaSelectionMenu(context, state, extra: widget.menu());

  @override
  Widget build(BuildContext context) => widget.markdown
      ? GaiaMarkdown(
          text: widget.text,
          contextMenuBuilder: _selectionMenu,
          checks: widget.checks,
          onCheck: widget.onCheck,
        )
      : SelectableText(widget.text, contextMenuBuilder: _contextMenu);
}

/// Where the composer pastes from; a test's stand-in has no platform to read.
@visibleForTesting
MediaClipboard gaiaClipboard = const MediaClipboard();

class _Composer extends StatefulWidget {
  const _Composer({required this.controller});

  final GaiaController controller;

  @override
  State<_Composer> createState() => _ComposerState();
}

class _ComposerState extends State<_Composer> {
  TextEditingController get _text => widget.controller.draft;

  /// The palette's keys are the field's own: they come to it before
  /// anything above it, Vim included, sees them.
  late final _focus = FocusNode(onKeyEvent: _paletteKey);
  late final StreamSubscription<void> _summoned;
  late final StreamSubscription<void> _usageOpened;
  final _vanish = GlobalKey<GaiaVanishState>();
  final _imagesVanish = GlobalKey<GaiaVanishState>();

  /// The side questions over the field, which Up and Down move along.
  final _btwDock = GlobalKey<GaiaBtwDockState>();

  /// The `/` palette's highlighted row, and whether Esc closed it for the
  /// draft as it stands.
  var _highlight = 0;
  String? _paletteClosedFor;

  /// A `/word` no command has, turned away once for the draft as it stood
  /// then (GAIA_NATIVE_COMMANDS.md §7): sent again unchanged, it goes.
  ({String word, String? suggestion})? _unknown;
  String? _unknownFor;

  /// A `/word` none of Gaia's own name, held while the CLI's commands are
  /// still being read: sent now, a CLI command would go as text.
  var _reading = false;

  /// The palette hovers over the chat from the overlay, above the
  /// composer, rather than pushing the chat up.
  final _portal = OverlayPortalController();

  /// The side questions float over the chat too, on the field's top edge.
  final _btwPortal = OverlayPortalController();
  final _fieldMark = GlobalKey();
  final _link = LayerLink();

  @override
  void initState() {
    super.initState();
    _text.addListener(_onDraft);
    _summoned = widget.controller.summoned.listen((_) => _focus.requestFocus());
    _usageOpened = widget.controller.usageOpens.listen((_) {
      if (mounted) unawaited(_showGaiaUsage(context, widget.controller));
    });
    widget.controller.focused.addListener(_onWindowFocus);
    _composers[widget.controller] = this;
  }

  /// A key typed with the focus elsewhere in Gaia (see [_typeToComposer]):
  /// [character] goes in the draft where its caret was, or at the end, and
  /// the composer takes the focus for the rest. Vim is in Insert, as a field
  /// it left is reset to.
  void typeIn(String character) {
    final value = _text.value;
    final at = value.selection.isValid
        ? value.selection
        : TextSelection.collapsed(offset: value.text.length);
    _text.value = TextEditingValue(
      text: value.text.replaceRange(at.start, at.end, character),
      selection: TextSelection.collapsed(offset: at.start + character.length),
    );
    _focus.requestFocus();
  }

  /// Ctrl+V with the focus elsewhere in Gaia: [_paste], into the composer,
  /// which takes the focus. Text goes at its caret, or at the end when it
  /// has none yet.
  void pasteIn() {
    if (!_text.selection.isValid) {
      _text.selection = TextSelection.collapsed(offset: _text.text.length);
    }
    _focus.requestFocus();
    unawaited(_paste());
  }

  /// Gaia can come up for a card without the focus, and with no summon to
  /// give the composer it: clicked into, the window has nothing focused,
  /// and the send keybind and an option's digit go nowhere. Not over a
  /// field the click put the focus in.
  void _onWindowFocus() {
    final primary = FocusManager.instance.primaryFocus;
    if (widget.controller.focused.value &&
        (ModalRoute.of(context)?.isCurrent ?? true) &&
        (primary == null || primary is FocusScopeNode)) {
      _focus.requestFocus();
    }
  }

  void _onDraft() {
    unawaited(_takeCommands());
    // The palette follows the draft, and the unknown command's line goes
    // once it changes.
    setState(() {
      _highlight = 0;
      if (_text.text != _unknownFor) _unknown = _unknownFor = null;
      _reading = false;
    });
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
    final clipboard = gaiaClipboard;
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

  /// Ctrl+V in Vim's Normal mode, which keeps the key and pastes the text
  /// itself: the image [_paste] would have attached, by the same rule.
  Future<void> _pasteImage() async {
    final clipboard = gaiaClipboard;
    final offer = await clipboard.peek();
    if (!offer.hasImage || offer.hasText || !mounted) return;
    final bytes = (await clipboard.read()).imageBytes;
    if (bytes != null) await widget.controller.attachImage(bytes);
  }

  /// The palette's rows for the draft; empty when it isn't showing. A
  /// user's command only for a whole draft: it takes the rest as arguments.
  List<GaiaPaletteItem> get _palette {
    final token = gaiaPaletteToken(_text.value);
    if (token == null || _text.text == _paletteClosedFor) return const [];
    return filterGaiaPalette([
      for (final item in _paletteItems(widget.controller.nativeCommands))
        if (token.whole || (item.command == null && item.native == null)) item,
    ], token.query);
  }

  /// Every row the palette can show, the CLI's own [natives] among them.
  List<GaiaPaletteItem> _paletteItems(List<GaiaNativeCommand>? natives) =>
      gaiaPaletteItems(
        widget.controller.commands,
        accounts: widget.controller.accounts,
        natives: natives ?? const [],
      );

  /// The unknown command's suggestion in place of its `/word`.
  void _useSuggestion() {
    final unknown = _unknown;
    final suggestion = unknown?.suggestion;
    if (unknown == null || suggestion == null) return;
    final text = _text.text.trimLeft().replaceFirst(
      '/${unknown.word}',
      '/$suggestion',
    );
    _text.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: suggestion.length + 1),
    );
  }

  /// The palette's `/word` taken out of the draft, with a space beside it.
  void _cutToken() {
    final token = gaiaPaletteToken(_text.value);
    if (token == null) return;
    final text = _text.text;
    final start = token.start;
    var end = token.end;
    // Ending the draft, the space before stays: more is typed after it.
    if (end < text.length && text[end] == ' ') end++;
    _text.value = TextEditingValue(
      text: text.replaceRange(start, end, ''),
      selection: TextSelection.collapsed(offset: start),
    );
  }

  /// A palette row picked (§9.2): a built-in runs, a tier or an account
  /// switches, a standalone command sends, and any other command, or `/remember`, waits
  /// for its arguments. A CLI's command that takes none sends too, unless
  /// [complete] (Tab) asks only for its name.
  Future<void> _pick(GaiaPaletteItem item, {bool complete = false}) async {
    final controller = widget.controller;
    if (item.builtin
        case GaiaBuiltin.remember || GaiaBuiltin.queue || GaiaBuiltin.btw) {
      // What else the draft held becomes what's remembered, queued, or asked
      // beside the chat. `/btw` with nothing else opens the panel.
      _cutToken();
      if (item.builtin == GaiaBuiltin.btw && _text.text.trim().isEmpty) {
        controller.openBtws();
        _focus.requestFocus();
        return;
      }
      final text = '/${item.builtin!.name} ${_text.text.trim()}';
      _text.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
    } else if (item.builtin case final builtin?) {
      _cutToken();
      await controller.runBuiltin(builtin);
    } else if (item.tier case final tier?) {
      _cutToken();
      await switchGaiaTier(context, controller, tier);
    } else if (item.account case final account?) {
      _cutToken();
      await switchGaiaAccount(context, controller, account.adapter, account);
    } else if (item.native case final native?) {
      // Its arguments, if any, go after it (GAIA_NATIVE_COMMANDS.md §5).
      // One that takes none sends, closed over as a standalone command is.
      final send = native.argumentHint.isEmpty && !complete;
      final text = send ? '/${native.name}' : '/${native.name} ';
      if (send) _paletteClosedFor = text;
      _text.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
      if (send) await _submitPicked();
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
      if (command.standalone) await _submitPicked();
    }
    _focus.requestFocus();
  }

  /// [_submit] for a row [_pick] just put in the draft: changing the draft set
  /// off its own check for commands, which would have the send turned away.
  /// Mid-reply it waits in the draft: [_submit] there is the stop button's.
  Future<void> _submitPicked() async {
    while (_takingCommands) {
      await Future<void>.delayed(Duration.zero);
    }
    if (mounted && !widget.controller.currentRunning) await _submit();
  }

  /// While the palette shows: Enter picks from it, whatever sends, as does
  /// Tab; Up and Down move along it, and Esc closes it for the draft as it
  /// stands. Otherwise the keys go to list editing ([_listKey]).
  KeyEventResult _paletteKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    if (_palette.isEmpty) {
      // Tab takes the unknown command's suggestion.
      if (event is KeyDownEvent &&
          event.logicalKey == LogicalKeyboardKey.tab &&
          _unknown?.suggestion != null &&
          !HardwareKeyboard.instance.isShiftPressed &&
          !HardwareKeyboard.instance.isControlPressed &&
          !HardwareKeyboard.instance.isAltPressed) {
        _useSuggestion();
        return KeyEventResult.handled;
      }
      return _listKey(node, event);
    }
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isControlPressed ||
        keyboard.isAltPressed ||
        keyboard.isShiftPressed ||
        keyboard.isMetaPressed) {
      return KeyEventResult.ignored;
    }
    final palette = _palette;
    switch (event.logicalKey) {
      case LogicalKeyboardKey.enter || LogicalKeyboardKey.numpadEnter:
        unawaited(_send());
      case LogicalKeyboardKey.tab:
        unawaited(
          _pick(
            palette[_highlight.clamp(0, palette.length - 1)],
            complete: true,
          ),
        );
      case LogicalKeyboardKey.arrowDown:
        _move(1);
      case LogicalKeyboardKey.arrowUp:
        _move(-1);
      case LogicalKeyboardKey.escape:
        setState(() => _paletteClosedFor = _text.text);
      default:
        return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  /// Without the palette: Tab and Shift+Tab indent and outdent a list line,
  /// unless a snippet wants Tab, and Backspace just past a marker takes it
  /// away, as in Voyager's notes.
  KeyEventResult _listKey(FocusNode node, KeyEvent event) {
    // The side questions' Alt keys while they're open, and Esc closes them
    // once Vim has no use for it: from Insert, it goes to Normal first.
    final dock = _btwDock.currentState;
    if (dock != null &&
        (dock.shortcut(event) ||
            (event is KeyDownEvent &&
                event.logicalKey == LogicalKeyboardKey.escape &&
                VimTextScope.escapeIsSpare(node.context) &&
                dock.close()))) {
      return KeyEventResult.handled;
    }
    // Up and Down move along them too, unless the draft runs over lines,
    // wrapped or not, for the caret to move between.
    if (event is! KeyUpEvent &&
        (event.logicalKey == LogicalKeyboardKey.arrowUp ||
            event.logicalKey == LogicalKeyboardKey.arrowDown) &&
        !HardwareKeyboard.instance.isShiftPressed &&
        !HardwareKeyboard.instance.isControlPressed &&
        !HardwareKeyboard.instance.isAltPressed &&
        !HardwareKeyboard.instance.isMetaPressed &&
        !_draftRunsOver() &&
        (dock?.move(event.logicalKey == LogicalKeyboardKey.arrowUp ? -1 : 1) ??
            false)) {
      return KeyEventResult.handled;
    }
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isControlPressed ||
        keyboard.isAltPressed ||
        keyboard.isMetaPressed) {
      return KeyEventResult.ignored;
    }
    final handled = switch (event.logicalKey) {
      LogicalKeyboardKey.tab =>
        !VimTextScope.snippetWantsTab(node.context) &&
            handleListTab(controller: _text, outdent: keyboard.isShiftPressed),
      LogicalKeyboardKey.backspace => handleListBackspace(controller: _text),
      _ => false,
    };
    return handled ? KeyEventResult.handled : KeyEventResult.ignored;
  }

  /// Whether the draft takes more than one line on screen, a long one
  /// wrapped as much as one broken.
  bool _draftRunsOver() {
    final editable = _focus.context
        ?.findAncestorStateOfType<EditableTextState>()
        ?.renderEditable;
    if (editable == null) return false;
    final end = TextPosition(offset: editable.plainText.length);
    return editable.getLocalRectForCaret(const TextPosition(offset: 0)).top !=
        editable.getLocalRectForCaret(end).top;
  }

  /// From the field's top up to the chat's, under its header, less a
  /// margin: what the side questions may fill. Read at layout, with both
  /// laid out.
  double _roomOverField() {
    final field = _fieldMark.currentContext?.findRenderObject() as RenderBox?;
    final chat = context.findAncestorRenderObjectOfType<RenderFlex>();
    if (field == null || chat == null || !field.attached) {
      return double.infinity;
    }
    // The composer's place in the chat's column; the one before it, the
    // messages, starts where the chat does.
    RenderObject? composer = context.findRenderObject();
    while (composer != null && composer.parent != chat) {
      composer = composer.parent;
    }
    final above = composer == null
        ? null
        : chat.childBefore(composer as RenderBox);
    if (above == null) return double.infinity;
    return field.localToGlobal(Offset.zero).dy -
        above.localToGlobal(Offset.zero).dy -
        12;
  }

  void _move(int by) {
    final rows = _palette.length;
    if (rows == 0) return;
    setState(() => _highlight = (_highlight + by) % rows);
  }

  @override
  void dispose() {
    _text.removeListener(_onDraft);
    unawaited(_summoned.cancel());
    unawaited(_usageOpened.cancel());
    widget.controller.focused.removeListener(_onWindowFocus);
    if (_composers[widget.controller] == this) {
      _composers[widget.controller] = null;
    }
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

  /// Aliases turned down, while the draft still holds them: the word was just
  /// a word, so it isn't asked about again.
  final _declinedAliases = <GaiaAccount>{};

  /// An account's alias, once completed. It may be a path's `/tmp` rather than
  /// the alias, so it always asks, and comes out only on a yes (§9.2). One
  /// already current is left as written.
  Future<bool> _takeAccountCommand({bool atEnd = false}) async {
    final controller = widget.controller;
    _declinedAliases.removeWhere(
      (account) => !_text.text.contains('/${account.alias}'),
    );
    final command = findGaiaAccountCommand(_text.value, [
      for (final account in controller.accounts)
        if (!_declinedAliases.contains(account) &&
            account != controller.currentAccount(account.adapter))
          account,
    ], atEnd: atEnd);
    if (command == null) return true;
    final account = command.account;
    final confirmed = await switchGaiaAccount(
      context,
      controller,
      account.adapter,
      account,
      ask: true,
    );
    if (confirmed) {
      _text.value = command.value;
    } else {
      _declinedAliases.add(account);
    }
    return confirmed;
  }

  /// Taking the draft's commands: each cut re-enters [_onDraft].
  var _takingCommands = false;

  /// Every command in the draft, one at a time, so their dialogs don't stack.
  /// False when the user turned one down, or some are already being taken.
  Future<bool> _takeCommands({bool atEnd = false}) async {
    if (_takingCommands) return false;
    _takingCommands = true;
    try {
      while (true) {
        final before = _text.text;
        if (!await _takeTierCommand(atEnd: atEnd) || !mounted) return false;
        if (!await _takeAccountCommand(atEnd: atEnd) || !mounted) return false;
        if (_text.text == before) return true;
      }
    } finally {
      _takingCommands = false;
    }
  }

  /// A command ending the message switches before it's sent; turned down,
  /// the message stays in the composer.
  Future<void> _send() async {
    final palette = _palette;
    if (palette.isNotEmpty) {
      return _pick(palette[_highlight.clamp(0, palette.length - 1)]);
    }
    return _submit();
  }

  /// [_send] without the palette.
  Future<void> _submit() async {
    // `/this` with the question after it: the same as picking it first.
    if (gaiaThisRest(_text.text) case final rest?) {
      final typed = _text.value;
      _text.text = rest;
      if (!await widget.controller.attachThis()) {
        _text.value = typed;
        return;
      }
      // Changing the draft set off its own check for commands, which would
      // have this send's turned away.
      while (_takingCommands) {
        await Future<void>.delayed(Duration.zero);
      }
      if (!mounted) return;
    }
    // A built-in runs even mid-reply: /stop is for exactly then.
    if (gaiaBuiltinIn(_text.text) case final builtin?) {
      _text.clear();
      return widget.controller.runBuiltin(builtin);
    }
    // So is /remember (§11), which never goes to the agent.
    if (gaiaRememberText(_text.text) case final memory?) {
      _text.clear();
      return widget.controller.remember(memory);
    }
    // And /queue (§13), which waits its turn.
    if (gaiaQueueText(_text.text) case final queued?) {
      _text.clear();
      return widget.controller.enqueue(queued);
    }
    // And /btw (GAIA_BTW_HLD.md §3): a side question, never queued, and
    // never the stop a send is mid-reply. The draft's attachments stay.
    if (gaiaBtwText(_text.text) case final question?) {
      _text.clear();
      return widget.controller.askBtw(question);
    }
    // A `/word` no command has stays, once, rather than going to the agent
    // as text (GAIA_NATIVE_COMMANDS.md §7). Not while the CLI's own are still
    // being read, which would turn theirs away too.
    final natives = _text.text.trimLeft().startsWith('/')
        ? widget.controller.nativeCommands
        : null;
    if (!widget.controller.currentRunning &&
        natives != null &&
        _text.text != _unknownFor) {
      if (gaiaUnknownCommand(_text.text, _paletteItems(natives))
          case final unknown?) {
        setState(() {
          _unknown = unknown;
          _unknownFor = _text.text;
        });
        return;
      }
    }
    if (!widget.controller.currentRunning &&
        _text.text.trimLeft().startsWith('/') &&
        natives == null &&
        gaiaUnknownCommand(_text.text, _paletteItems(null)) != null) {
      setState(() => _reading = true);
      return;
    }
    if (await _submitCard(widget.controller)) return;
    final controller = widget.controller;
    // Mid-reply, send is the stop button's, as the button is; the draft
    // waits, commands and all.
    if (controller.currentRunning) {
      return controller.stop(controller.currentChatId!);
    }
    if (!await _takeCommands(atEnd: true) || !mounted) return;
    final attached =
        controller.draftImages.isNotEmpty || controller.draftFiles.isNotEmpty;
    if (controller.draftIsEmpty) return;
    if (!controller.readyToSend()) return;
    // After: it may take tokens out.
    final text = _text.text;
    GaiaVanishState.vanishTogether([
      if (attached) _imagesVanish.currentState!,
      _vanish.currentState!,
    ]);
    _text.clear();
    // Its undo steps hold the text just sent, whose images have gone with it.
    controller.draftUndo.reset();
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
    if (controller.limitCard case final limit?) {
      return LayoutBuilder(
        builder: (context, constraints) {
          // In line with the composer it stands in for.
          final side = max(12.0, (constraints.maxWidth - _column) / 2 - 12);
          return Padding(
            padding: EdgeInsets.fromLTRB(side, 8, side, 8),
            child: _LimitDecision(
              // Each preview starts afresh, with its checkbox ticked.
              key: ValueKey(controller.limitPreview?.label),
              controller: controller,
              card: limit,
              onDone: () => WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) _focus.requestFocus();
              }),
            ),
          );
        },
      );
    }
    // Here, not once in initState: the ones above take the portal out of the
    // tree, and it comes back hidden.
    if (!_portal.isShowing) _portal.show();
    if (!_btwPortal.isShowing) _btwPortal.show();
    final running = controller.currentRunning;
    final palette = _palette;
    final send = _sendCombo(controller);
    final card = controller.openCard;
    // A question's options by number, while there's nothing typed to put
    // the digit in. Every digit, so a miss does nothing rather than typing
    // itself and taking the rest away.
    final pickable =
        card != null && card.options.isNotEmpty && _text.text.isEmpty
        ? _digits.length
        : 0;
    final composer = LayoutBuilder(
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
              // Queues the draft for later rather than sending it (§13).
              const SingleActivator(
                LogicalKeyboardKey.keyQ,
                control: true,
              ): () {
                final text = _text.text.trim();
                if (text.isEmpty) return;
                _text.clear();
                unawaited(controller.enqueue(text));
              },
              for (var i = 0; i < pickable; i++)
                SingleActivator(_digits[i]): () =>
                    controller.pickCardOption(card!, i),
            },
            // The side questions while open (GAIA_BTW_HLD.md §8.1), floating
            // over the chat on the field's top edge, as wide as it. Under
            // the palette, which is the nearer portal.
            child: OverlayPortal.overlayChildLayoutBuilder(
              controller: _btwPortal,
              // At layout, when where the field and chat are is known. Placed
              // by hand, not by a follower layer: a tooltip in it can't find
              // its place on screen through one.
              overlayChildBuilder: (context, info) {
                final field =
                    _fieldMark.currentContext?.findRenderObject() as RenderBox?;
                final overlay = Overlay.of(context).context.findRenderObject();
                if (field == null || !field.attached) {
                  return const SizedBox.shrink();
                }
                final at = field.localToGlobal(Offset.zero, ancestor: overlay);
                return Stack(
                  children: [
                    Positioned(
                      left: at.dx,
                      bottom: info.overlaySize.height - at.dy,
                      // The composer's full width, so nothing under it peeks
                      // out at the sides.
                      width: constraints.maxWidth - 2 * side,
                      child: Material(
                        type: MaterialType.transparency,
                        child: GaiaBtwDock(
                          key: _btwDock,
                          controller: controller,
                          maxHeight: _roomOverField(),
                        ),
                      ),
                    ),
                  ],
                );
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
                          child: TapRegion(
                            groupId: gaiaBtwTapGroup,
                            child: Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: GaiaPalette(
                                width: constraints.maxWidth - 2 * side,
                                highlight: _highlight.clamp(
                                  0,
                                  palette.length - 1,
                                ),
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
                      ),
                child: CompositedTransformTarget(
                  link: _link,
                  // Clicks here keep the side questions open.
                  child: TapRegion(
                    groupId: gaiaBtwTapGroup,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (controller.lowUsage case final low?)
                          _LowUsageBanner(controller: controller, low: low),
                        // The chat's queue and drain mode (§13); clicking it
                        // loads the next prompt to review. Beside it, its side
                        // questions (GAIA_BTW_HLD.md §8.2).
                        if ((
                              controller
                                  .queueFor(controller.currentChatId)
                                  .length,
                              controller
                                  .btwsFor(controller.currentChatId)
                                  .length,
                            )
                            case (final queued, final btws)
                            when queued > 0 ||
                                btws > 0 ||
                                (controller.currentChat?.drain ?? false))
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: Wrap(
                                spacing: 6,
                                runSpacing: 6,
                                children: [
                                  if (queued > 0 ||
                                      (controller.currentChat?.drain ?? false))
                                    _ContextChip(
                                      label: [
                                        if (queued == 1)
                                          '1 queued'
                                        else if (queued > 1)
                                          '$queued queued',
                                        if (controller.currentChat?.drain ??
                                            false)
                                          'drain on',
                                      ].join(' · '),
                                      icon: Icons.queue,
                                      onRemove: queued == 0
                                          ? null
                                          : () => controller.popQueue(
                                              send: false,
                                            ),
                                    ),
                                  // Under the side questions while they're open,
                                  // so the field doesn't move as they do.
                                  if (btws > 0)
                                    GaiaBtwChip(controller: controller),
                                ],
                              ),
                            ),
                          ),
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
                        if (controller.draftControl case final control?)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: _ContextChip(
                                label: control.label,
                                icon: Icons.ads_click,
                                onRemove: controller.dropDraftControl,
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
                                      for (final image
                                          in controller.draftImages)
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
                                      for (final image
                                          in controller.arrivingImages)
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
                        // The field's top edge, which the side questions sit on.
                        // What's above it floats over the chat.
                        GaiaFieldLine(key: _fieldMark),
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
                            hintText: vanishing
                                ? null
                                : switch (card?.kind) {
                                    GaiaCardKind.question => 'Type an answer',
                                    GaiaCardKind.permission =>
                                      'Send to allow, or say why not',
                                    GaiaCardKind.proposal =>
                                      'Send to save, or say what to change',
                                    GaiaCardKind.control =>
                                      'Send to run, or say why not',
                                    null => 'Message Gaia',
                                  },
                            onPaste: _paste,
                            undoController: controller.draftUndo,
                            lists: true,
                            onAddWord: (word) =>
                                unawaited(controller.addWord(word)),
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
                                    onChanged: (folder) =>
                                        _attach(folder: folder!),
                                  ),
                                ],
                              ),
                            ),
                            // Mid-reply it's the reply's stop, except for what
                            // [_submit] takes before that stop: a side question
                            // (GAIA_BTW_HLD.md §3), /queue (§13) and /remember
                            // (§11) send as Enter does.
                            trailing:
                                running &&
                                    gaiaBtwText(_text.text) == null &&
                                    gaiaQueueText(_text.text) == null &&
                                    gaiaRememberText(_text.text) == null
                                ? GaiaButton(
                                    icon: Icons.stop,
                                    size: 32,
                                    onPressed: () => controller.stop(
                                      controller.currentChatId!,
                                    ),
                                  )
                                : GaiaButton(
                                    icon: Icons.arrow_upward,
                                    size: 32,
                                    onPressed: _send,
                                  ),
                          ),
                        ),
                        const SizedBox(height: 6),
                        _ComposerStatus(
                          controller: controller,
                          // In the status line, not a line of its own, so the
                          // composer keeps its height and the chat stays put.
                          notice: switch (_unknown) {
                            (:final word, suggestion: null) =>
                              'Unknown command /${_clipCommand(word)}. Send again '
                                  'to send as typed.',
                            (:final word, :final suggestion?) =>
                              'Unknown command /${_clipCommand(word)}. Tab for '
                                  '/${_clipCommand(suggestion)}, or send again to '
                                  'send as typed.',
                            null
                                when _reading &&
                                    controller.nativeCommands == null =>
                              "Reading ${kGaiaClis[controller.agentFor(controller.nextTier)?.adapter]?.name ?? 'the CLI'}'s "
                                  'commands. Send again in a moment.',
                            _ => null,
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
    return MediaPasteOwnerScope(pasteImage: _pasteImage, child: composer);
  }
}

/// The next message's account is low (§6.5). Never in the way: the composer
/// stays, and the button only offers.
class _LowUsageBanner extends StatelessWidget {
  const _LowUsageBanner({required this.controller, required this.low});

  /// Its button's height, kept without one so the text doesn't move when the
  /// button comes or goes.
  static const _height = 28.0;

  final GaiaController controller;
  final GaiaLowUsage low;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final other = low.switchTo;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        // Solid, as it floats over the chat's text.
        color: theme.scaffoldBackgroundColor,
        constraints: const BoxConstraints(minHeight: _height),
        child: Row(
          children: [
            const Icon(Icons.warning_amber, size: 16, color: kGaiaStatusRose),
            const SizedBox(width: 8),
            Expanded(child: Text(low.text, style: theme.textTheme.bodySmall)),
            if (other != null) ...[
              const SizedBox(width: 8),
              GaiaButton(
                label: 'Switch to ${other.label}',
                size: _height,
                padding: 10,
                still: true,
                onPressed: () => controller.limitPreview != null
                    ? controller.previewLimit(null)
                    : switchGaiaAccount(
                        context,
                        controller,
                        low.adapter,
                        other,
                      ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// In place of the composer while the next message's account is out (§6.5):
/// what the user has configured instead, for them to pick. It carries what a
/// switch costs, so no §7.5 dialog follows. The send keybind takes the first
/// option, Esc dismisses it.
class _LimitDecision extends StatefulWidget {
  const _LimitDecision({
    super.key,
    required this.controller,
    required this.card,
    required this.onDone,
  });

  final GaiaController controller;
  final GaiaLimitCard card;

  /// It's gone: the composer takes the focus back.
  final VoidCallback onDone;

  @override
  State<_LimitDecision> createState() => _LimitDecisionState();
}

class _LimitDecisionState extends State<_LimitDecision> {
  final _focus = FocusNode(debugLabel: 'gaia limit card');
  late final StreamSubscription<void> _summoned;
  var _resend = true;

  @override
  void initState() {
    super.initState();
    _summoned = widget.controller.summoned.listen((_) => _focus.requestFocus());
    widget.controller.focused.addListener(_onWindowFocus);
  }

  /// A limit can be hit with the user in another app. Coming back without a
  /// summon, nothing else gives the card the focus its keys need.
  void _onWindowFocus() {
    if (widget.controller.focused.value) _focus.requestFocus();
  }

  @override
  void dispose() {
    unawaited(_summoned.cancel());
    widget.controller.focused.removeListener(_onWindowFocus);
    _focus.dispose();
    super.dispose();
  }

  void _accept(void Function() choose) {
    if (widget.controller.limitPreview != null) return _dismiss();
    final resend = widget.card.resend && _resend;
    choose();
    if (resend) unawaited(widget.controller.resendInterrupted());
    widget.onDone();
  }

  void _dismiss() {
    widget.controller.dismissLimitCard();
    widget.onDone();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final card = widget.card;
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final name = card.named
        ? '${card.agent.label} (${card.account.label})'
        : card.agent.label;
    final cli = kGaiaClis[card.agent.adapter]?.name ?? card.agent.adapter;
    final send = _sendCombo(controller);
    final preview = controller.limitPreview;
    final reply = preview?.reply ?? controller.accountSwitchNeedsConfirm;
    final tokens = preview == null
        ? controller.contextTokens
        : preview.contextTokens;

    final options = <({String label, VoidCallback pick})>[
      for (final account in card.accounts)
        (
          label: 'Switch to ${account.label}',
          pick: () => _accept(
            () => controller.switchAccount(card.agent.adapter, account),
          ),
        ),
      for (final tier in card.tiers)
        (
          label: switch (preview?.tierAgents[tier] ??
              controller.agentFor(tier)) {
            final agent? => '${tier.label} (${agent.label})',
            null => tier.label,
          },
          pick: () => _accept(() => controller.pickTier(tier)),
        ),
    ];
    String resetLine(({GaiaAccount account, DateTime? at}) reset) =>
        switch (reset.at) {
          null =>
            "It isn't known when "
                '${card.named ? reset.account.label : name} resets.',
          final at =>
            '${card.named ? '${reset.account.label} resets' : 'Resets'} at '
                '${gaiaResetTime(at)}.',
        };
    // With no account left to switch to, each that's out has a line of its own.
    final listed = card.named && card.accounts.isEmpty;
    // Otherwise the line is the account that's out here: its reset is what
    // decides between waiting and switching.
    final own = listed
        ? null
        : card.resets
              .where(
                (reset) =>
                    reset.account == card.account &&
                    (options.isEmpty || reset.at != null),
              )
              .firstOrNull;
    final detail = [
      if (own != null) resetLine(own),
      if (options.isNotEmpty) ...[
        if (reply)
          'The prompt cache is lost, so the next message re-reads '
              'the whole context and uses extra tokens.',
        if (card.accounts.isNotEmpty)
          'Your other chats on ${card.account.label} move too, on '
              'their next message.',
        if (card.tiers.isNotEmpty && reply)
          "Only a transcript carries over. $cli's tool history "
              "doesn't.",
      ],
    ].join(' ');
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): _dismiss,
        if (options.isNotEmpty) send.activator: options.first.pick,
      },
      child: Focus(
        focusNode: _focus,
        autofocus: true,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                options.isEmpty ? 'Usage has run out' : '$name is out of usage',
                style: theme.textTheme.titleSmall,
              ),
              if (listed && card.resets.isNotEmpty) ...[
                const SizedBox(height: 4),
                for (final reset in card.resets)
                  Text(resetLine(reset), style: muted),
              ],
              if (detail.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(detail, style: muted),
              ],
              if (options.isNotEmpty && reply && tokens != null) ...[
                const SizedBox(height: 4),
                Text(
                  'Current context: ${(tokens / 1000).round()}k tokens.',
                  style: muted,
                ),
              ],
              if (card.resend && options.isNotEmpty) ...[
                const SizedBox(height: 4),
                InkWell(
                  borderRadius: BorderRadius.circular(6),
                  onTap: () => setState(() => _resend = !_resend),
                  child: Padding(
                    padding: const EdgeInsets.only(right: 7),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IgnorePointer(
                          child: Checkbox(
                            value: _resend,
                            materialTapTargetSize:
                                MaterialTapTargetSize.shrinkWrap,
                            visualDensity: VisualDensity.compact,
                            onChanged: (_) {},
                          ),
                        ),
                        Text(
                          'Resend my last message',
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  for (final (index, option) in options.indexed)
                    GaiaButton(
                      label: option.label,
                      // The first is the one the keybind takes: only it has
                      // the moving light.
                      still: index > 0,
                      onPressed: option.pick,
                    ),
                  GaiaButton(
                    label: 'Dismiss',
                    still: options.isNotEmpty,
                    color: theme.colorScheme.error,
                    onPressed: _dismiss,
                  ),
                  if (options.isNotEmpty)
                    Text('$send takes the first', style: muted),
                ],
              ),
            ],
          ),
        ),
      ),
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
        // Solid, as it floats over the chat's text.
        color: Color.alphaBlend(
          accent.withValues(alpha: 0.15),
          theme.scaffoldBackgroundColor,
        ),
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

/// 84000 as "84k", a whole million as "1M".
String _tokensK(int tokens) => tokens >= 1000000 && tokens % 1000000 == 0
    ? '${tokens ~/ 1000000}M'
    : '${(tokens / 1000).round()}k';

/// A long `/word` trails off, so the rest of the status line's notice shows.
String _clipCommand(String word) =>
    word.length > 16 ? '${word.substring(0, 16)}...' : word;

/// Under the composer: the current chat's context, the next message's
/// account usage, and the tier picker. Hovering the context shows how much
/// of the model's window it fills.
class _ComposerStatus extends StatelessWidget {
  const _ComposerStatus({required this.controller, this.notice});

  final GaiaController controller;

  /// The draft's unknown or held `/word` (GAIA_NATIVE_COMMANDS.md §7), in
  /// place of the context count until the draft changes.
  final String? notice;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = controller.contextTokens;
    final adapter = controller.agentFor(controller.nextTier)?.adapter;
    final accounts = adapter == null
        ? const <GaiaAccount>[]
        : controller.accountsFor(adapter);
    final current = adapter == null ? null : controller.currentAccount(adapter);
    VoidCallback? switchTo(GaiaAccount account) => account == current
        ? null
        : () => switchGaiaAccount(context, controller, adapter!, account);
    return Row(
      children: [
        const SizedBox(width: 4),
        Expanded(
          child: Align(
            alignment: Alignment.centerLeft,
            child: notice != null
                ? Tooltip(
                    message: notice!,
                    child: Row(
                      children: [
                        const Icon(
                          Icons.help_outline,
                          size: 14,
                          color: kGaiaStatusRose,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            notice!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: kGaiaStatusRose,
                              fontSize:
                                  (theme.textTheme.bodySmall?.fontSize ?? 12) -
                                  1,
                            ),
                          ),
                        ),
                      ],
                    ),
                  )
                : Tooltip(
                    message: controller.seeScreenWarning || tokens == null
                        ? ''
                        : switch (controller.contextWindow) {
                            final window? when window > 0 =>
                              '${_tokensK(tokens)} of ${_tokensK(window)} tokens '
                                  '(${(tokens * 100 / window).round()}%)',
                            _ => '',
                          },
                    child: Text(
                      controller.seeScreenWarning
                          ? 'Agent tools could leak or obey screen text.'
                          : tokens == null
                          ? ''
                          : '${_tokensK(tokens)} context',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: controller.seeScreenWarning
                            ? kGaiaStatusRose
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
          ),
        ),
        const SizedBox(width: 4),
        // Per chat, on this device (§15.6): off by default. Clicking one leaves
        // the caret in the composer.
        TextFieldTapRegion(
          child: Tooltip(
            message: controller.canSeeScreen
                ? 'Can see screen: on. An agent with its CLI\'s shell or web tools '
                      'could send screen text elsewhere, or be steered by it.'
                : 'Can see screen: off',
            child: InkWell(
              borderRadius: BorderRadius.circular(4),
              onTap: controller.toggleSeeScreen,
              child: Padding(
                padding: const EdgeInsets.all(_UsageRing.margin),
                child: Icon(
                  controller.canSeeScreen
                      ? Icons.visibility
                      : Icons.visibility_off_outlined,
                  size: 14,
                  color: controller.canSeeScreen
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ),
        // Off, Ask or Auto (GAIA_AUTONOMY_HLD.md §4): a menu rather than a
        // cycle, so one stray click can't reach Auto.
        TextFieldTapRegion(
          child: Tooltip(
            message: switch (controller.hand) {
              GaiaHand.off => 'Can control: off',
              GaiaHand.ask =>
                'Can control: Ask. Gaia asks before each step list, and the '
                    'border shows while this is on. Esc stops a run.',
              GaiaHand.auto =>
                'Can control: Auto. Gaia acts, runs commands and edits files '
                    'with no cards. Esc stops a run.',
            },
            child: Builder(
              builder: (button) => InkWell(
                borderRadius: BorderRadius.circular(4),
                // At the button, not the pointer, so Enter and Space open
                // it too.
                onTap: () {
                  final box = button.findRenderObject()! as RenderBox;
                  _showHandMenu(
                    context,
                    controller,
                    box.localToGlobal(box.size.center(Offset.zero)),
                  );
                },
                child: Padding(
                  padding: const EdgeInsets.all(_UsageRing.margin),
                  child: _HandIcon(hand: controller.hand),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 8 - 2 * _UsageRing.margin),
        // One per account, its own in order; dulled unless the next message
        // runs on it, and clicking a dulled one switches to it (§6.2). Each
        // has [_UsageRing.margin] to click in, within the gap they'd otherwise
        // leave, so the row's spacing is 8 between them.
        for (final account in accounts) ...[
          if (controller.usageUntracked(adapter!, account)
              case final untracked?)
            if (account == current)
              Padding(
                padding: const EdgeInsets.all(_UsageRing.margin),
                child: Tooltip(
                  message: untracked,
                  child: Text(
                    'Usage untracked',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              )
            else
              _UsageRing(
                dull: true,
                label: account.label,
                message: untracked,
                onTap: switchTo(account),
              )
          else if (controller.usage[account.key] case final usage?)
            _UsageRing(
              usage: usage,
              dull: account != current,
              label: accounts.length > 1 ? account.label : null,
              onTap: switchTo(account),
            )
          else if (account != current)
            _UsageRing(
              dull: true,
              label: account.label,
              message: 'Not read yet',
              onTap: switchTo(account),
            ),
          const SizedBox(width: 8 - 2 * _UsageRing.margin),
        ],
        const SizedBox(width: _UsageRing.margin),
        // The notch opens up and to the left, so it ends the row.
        _TierPicker(controller: controller),
      ],
    );
  }
}

/// An account's five-hour usage as a ring filling clockwise from the top,
/// with a bar for every window in its tooltip.
///
/// [dull] for an account the next message doesn't run on, and [onTap] switches
/// to it, as the tier picker's account item does (§6.5). [label] names the
/// account when there are several; [message] stands in for numbers it doesn't
/// have.
class _UsageRing extends StatelessWidget {
  const _UsageRing({
    this.usage,
    this.dull = false,
    this.label,
    this.message,
    this.onTap,
  });

  /// Around the ring on every side, for a target bigger than its 14 px.
  static const margin = 3.0;

  final GaiaUsage? usage;
  final bool dull;
  final String? label;
  final String? message;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final usage = this.usage;
    final ring = CustomPaint(
      size: const Size.square(14),
      painter: _RingPainter(
        // A plan with no 5-hour window has only its weekly one to show.
        used: (usage?.fiveHour ?? usage?.weekly)?.usedNow ?? 0,
        track: Colors.white.withValues(alpha: 0.15),
        fill: Theme.of(context).colorScheme.primary,
      ),
    );
    return Tooltip(
      richMessage: WidgetSpan(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (label case final label?) ...[
              Text(label, style: Theme.of(context).textTheme.labelMedium),
              const SizedBox(height: 10),
            ],
            if (message case final message?)
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 260),
                child: Text(message),
              ),
            if (usage != null)
              for (final (index, bar) in gaiaUsageBars(usage).indexed) ...[
                if (index > 0) const SizedBox(height: 10),
                bar,
              ],
          ],
        ),
      ),
      padding: const EdgeInsets.all(10),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(margin),
          child: dull ? Opacity(opacity: 0.4, child: ring) : ring,
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  const _RingPainter({
    required this.used,
    required this.track,
    required this.fill,
    this.stroke = 2.0,
  });

  final double used;
  final Color track;
  final Color fill;
  final double stroke;

  @override
  void paint(Canvas canvas, Size size) {
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
      old.used != used ||
      old.track != track ||
      old.fill != fill ||
      old.stroke != stroke;
}

/// The tier the next message goes to (§7.2) and its agent, a notch that
/// opens onto all three; before it, once its adapter has several, the account
/// (§6.5), whose options open above the tiers' from either. In a new chat,
/// Auto leaves the tier to the router: its glyph runs through the tiers
/// until the router answers, then settles into the tier picked as the
/// notch's ring flashes.
class _TierPicker extends StatelessWidget {
  const _TierPicker({required this.controller});

  final GaiaController controller;

  @override
  Widget build(BuildContext context) {
    final auto = controller.routable && controller.pickedTier == null;
    final routing = auto && controller.routing;
    final adapter = controller.agentFor(controller.nextTier)?.adapter;
    final accounts = adapter == null
        ? const <GaiaAccount>[]
        : controller.accountsFor(adapter);
    return GaiaRouteFlash(
      routing: routing,
      chatId: controller.currentChatId,
      picked: controller.pickedTier != null,
      child: GaiaNotch(
        items: [
          if (accounts.length > 1)
            GaiaNotchItem<GaiaAccount>(
              options: [
                for (final account in accounts)
                  GaiaNotchOption(
                    value: account,
                    label: account.label,
                    detail: switch (controller.usage[account.key]?.fiveHour) {
                      final window? =>
                        '${(window.usedNow * 100).round()}% used',
                      null => null,
                    },
                  ),
              ],
              value: controller.currentAccount(adapter!),
              onChanged: (account) =>
                  switchGaiaAccount(context, controller, adapter, account),
            ),
          gaiaTierItem(
            autoOffered: controller.routable,
            tier: auto ? null : controller.nextTier,
            routing: routing,
            agent: (tier) => controller.agentFor(tier)?.label,
            lastReply: controller.lastReplyTier,
            onChanged: (tier) => tier == null
                ? controller.pickTier(null)
                : switchGaiaTier(context, controller, tier),
          ),
        ],
      ),
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
  final confirmed = await _confirmSwitch(
    context,
    controller,
    title:
        'Switch from ${name(from, fromAgent)} to '
        '${name(tier, toAgent)}?',
    note: crossVendor
        ? 'Only a transcript carries over to ${cli(toAgent)}. '
              "${cli(fromAgent)}'s tool history doesn't."
        : null,
  );
  if (confirmed != true) return false;
  controller.pickTier(tier);
  return true;
}

/// Switches [adapter]'s next messages to [account], for every chat: silently
/// with no reply here to lose the cache of, after the user's yes otherwise,
/// as [switchGaiaTier] (§6.5), or always with [ask]. Never by itself: not on a
/// low account. An adapter this chat's next message isn't on costs this chat
/// nothing, and the dialog says so. False when the user turned the switch down.
Future<bool> switchGaiaAccount(
  BuildContext context,
  GaiaController controller,
  String adapter,
  GaiaAccount account, {
  bool ask = false,
}) async {
  final from = controller.currentAccount(adapter);
  if (from == account) return true;
  final reply = controller.accountSwitchNeedsConfirm;
  if (ask || reply) {
    final next = controller.agentFor(controller.nextTier)?.adapter;
    final elsewhere = next != null && next != adapter;
    String cli(String adapter) => kGaiaClis[adapter]?.name ?? adapter;
    final confirmed = await _confirmSwitch(
      context,
      controller,
      title: elsewhere
          ? 'Switch ${cli(adapter)} from ${from.label} to ${account.label}?'
          : 'Switch from ${from.label} to ${account.label}?',
      note: [
        if (elsewhere) "This chat's next message stays on ${cli(next)}.",
        'Your other chats on ${from.label} move too, on their next message.',
      ].join(' '),
      losesCache: reply && !elsewhere,
    );
    if (confirmed != true) return false;
  }
  controller.switchAccount(adapter, account);
  return true;
}

/// What a switch costs (§7.5), with [note] for what's particular to it. The
/// send keybind confirms; Esc doesn't.
Future<bool?> _confirmSwitch(
  BuildContext context,
  GaiaController controller, {
  required String title,
  String? note,
  bool losesCache = true,
}) {
  final tokens = controller.contextTokens;
  final send = _sendCombo(controller);
  return showDialog<bool>(
    context: context,
    builder: (context) => CallbackShortcuts(
      bindings: {send.activator: () => Navigator.of(context).pop(true)},
      child: Focus(
        autofocus: true,
        child: AlertDialog(
          title: Text(title),
          content: Text(
            [
              if (losesCache) ...[
                'The prompt cache is lost, so the next message re-reads the '
                    'whole context and uses extra tokens.',
                if (tokens != null)
                  'Current context: ${(tokens / 1000).round()}k tokens.',
              ],
              ?note,
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
}

/// An open card takes the draft (§10, §10.1): a question's answer, a
/// permission's "why not", or a proposal's correction. Sent empty, a
/// permission is allowed and a proposal saved as its editor has it. False
/// with no card open.
Future<bool> _submitCard(GaiaController controller) async {
  final card = controller.openCard;
  if (card == null) return false;
  final draft = controller.draft;
  final text = draft.text;
  switch (card.kind) {
    case GaiaCardKind.question:
      if (await controller.answerCard(card, text: text)) draft.clear();
    case GaiaCardKind.permission:
      if (text.trim().isEmpty) {
        controller.allowCard(card);
      } else {
        controller.rejectCard(card, message: text);
        draft.clear();
      }
    case GaiaCardKind.proposal:
      if (text.trim().isEmpty) {
        controller.acceptProposal(card);
      } else {
        controller.rejectCard(card, message: text);
        draft.clear();
      }
    case GaiaCardKind.control:
      if (text.trim().isEmpty) {
        controller.approveControl(card, once: gaiaControlCanRunAll(card));
      } else {
        controller.rejectCard(card, message: text);
        draft.clear();
      }
  }
  return true;
}

/// The composer's keys for an open card, wherever in the window the focus
/// is (a button, a card's own field, or nothing): the send keybind answers
/// it, and a question's digits pick its options while the draft is empty.
/// Not the digits in a text box, which types them; the composer has its
/// own, which come first.
KeyEventResult _cardKey(GaiaController controller, KeyEvent event) {
  final card = controller.openCard;
  if (card == null || event is KeyUpEvent) return KeyEventResult.ignored;
  final keyboard = HardwareKeyboard.instance;
  final inText = _inTextField();
  // A card's own field, not the sidebar's search or a rename.
  final inCard =
      FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<GaiaCardView>() !=
      null;
  final modified =
      keyboard.isControlPressed ||
      keyboard.isAltPressed ||
      keyboard.isMetaPressed;
  // A send keybind of plain Enter is a card field's newline.
  if (((modified && inCard) || !inText) &&
      _sendCombo(controller).activator.accepts(event, keyboard)) {
    // Held down, once: not on a card that opens meanwhile.
    if (event is KeyDownEvent) unawaited(_submitCard(controller));
    return KeyEventResult.handled;
  }
  final digit = _digits.indexOf(event.logicalKey);
  if (digit < 0 ||
      card.options.isEmpty ||
      controller.draft.text.isNotEmpty ||
      modified ||
      keyboard.isShiftPressed ||
      inText) {
    return KeyEventResult.ignored;
  }
  // A miss does nothing, as in the composer.
  if (event is KeyDownEvent) controller.pickCardOption(card, digit);
  return KeyEventResult.handled;
}

/// The composer on screen for each controller, for [_typeToComposer]; none
/// while a usage limit or Voyager quitting stands in for it.
final _composers = Expando<_ComposerState>();

/// Type to focus, as in other chat apps: a character typed with the focus
/// elsewhere in Gaia, on the chat, a button or nothing, goes in the
/// composer, which takes the focus. Not with Ctrl, Alt or the Windows key
/// (AltGr, which is Ctrl+Alt, types), nor Space on a button, which presses
/// it; keys a focused control takes never come here.
KeyEventResult _typeToComposer(GaiaController controller, KeyEvent event) {
  final character = event.character;
  final composer = _composers[controller];
  if (event is! KeyDownEvent || composer == null || _inTextField()) {
    return KeyEventResult.ignored;
  }
  final keyboard = HardwareKeyboard.instance;
  final control = keyboard.isControlPressed;
  final alt = keyboard.isAltPressed;
  // Ctrl+V pastes there too: text at its caret, or an image attached.
  if (event.logicalKey == LogicalKeyboardKey.keyV &&
      control &&
      !alt &&
      !keyboard.isShiftPressed &&
      !keyboard.isMetaPressed) {
    composer.pasteIn();
    return KeyEventResult.handled;
  }
  if (character == null ||
      character.isEmpty ||
      character.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f)) {
    return KeyEventResult.ignored;
  }
  if (keyboard.isMetaPressed ||
      (control != alt) ||
      (character == ' ' &&
          FocusManager.instance.primaryFocus is! FocusScopeNode)) {
    return KeyEventResult.ignored;
  }
  composer.typeIn(character);
  return KeyEventResult.handled;
}

/// The focus is in a box the user types in: not read-only text, such as a
/// card's, selected in the chat.
bool _inTextField() {
  final editable = FocusManager.instance.primaryFocus?.context
      ?.findAncestorStateOfType<EditableTextState>();
  return editable != null && !editable.widget.readOnly;
}

/// The focus is in the side questions' dock, whose keys it keeps; a click
/// outside it lets go.
bool _inBtwDock() =>
    FocusManager.instance.primaryFocus?.context
        ?.findAncestorWidgetOfExactType<GaiaBtwDock>() !=
    null;

/// 1 to 9, which pick a question card's options.
const _digits = [
  LogicalKeyboardKey.digit1,
  LogicalKeyboardKey.digit2,
  LogicalKeyboardKey.digit3,
  LogicalKeyboardKey.digit4,
  LogicalKeyboardKey.digit5,
  LogicalKeyboardKey.digit6,
  LogicalKeyboardKey.digit7,
  LogicalKeyboardKey.digit8,
  LogicalKeyboardKey.digit9,
  // Never an option (ask_user takes at most 9), but beside 9 to miss onto.
  LogicalKeyboardKey.digit0,
];

/// The hand's menu (GAIA_AUTONOMY_HLD.md §4). The first Auto on this device
/// shows its notice.
void _showHandMenu(
  BuildContext context,
  GaiaController controller,
  Offset position,
) {
  final hand = controller.hand;
  String? current(GaiaHand item) => item == hand ? 'On' : null;
  showGaiaMenu(context, position, [
    GaiaMenuItem(
      label: 'Off',
      icon: Icons.pan_tool_alt_outlined,
      detail: 'No input',
      shortcut: current(GaiaHand.off),
      onPressed: () => unawaited(controller.setHand(GaiaHand.off)),
    ),
    GaiaMenuItem(
      label: 'Ask',
      icon: Icons.pan_tool_alt,
      detail: 'A card before each step list',
      shortcut: current(GaiaHand.ask),
      onPressed: () => unawaited(controller.setHand(GaiaHand.ask)),
    ),
    GaiaMenuItem(
      label: 'Auto',
      icon: Icons.bolt,
      detail: 'No cards, commands too',
      shortcut: current(GaiaHand.auto),
      onPressed: () => unawaited(_chooseAuto(context, controller)),
    ),
  ]);
}

/// `/usage`: every window of the next message's accounts, a row each led by
/// a ring like the composer's.
Future<void> _showGaiaUsage(BuildContext context, GaiaController controller) {
  return showDialog<void>(
    context: context,
    // Rebuilt as usage reads land, which may be after it opens.
    builder: (context) => ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final adapter = controller.agentFor(controller.nextTier)?.adapter;
        final accounts = adapter == null
            ? const <GaiaAccount>[]
            : controller.accountsFor(adapter);
        final theme = Theme.of(context);
        final muted = theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        );
        Widget row(String name, GaiaUsageWindow? window) => Row(
          children: [
            CustomPaint(
              size: const Size.square(20),
              painter: _RingPainter(
                used: window?.usedNow ?? 0,
                track: Colors.white.withValues(alpha: 0.15),
                fill: theme.colorScheme.primary,
                stroke: 2.5,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(child: Text(name, style: theme.textTheme.bodyLarge)),
            Text(gaiaUsageDetail(window), style: muted),
            SizedBox(
              width: 56,
              child: Text(
                window == null ? '–' : '${(window.usedNow * 100).round()}%',
                textAlign: TextAlign.right,
                style: theme.textTheme.bodyLarge,
              ),
            ),
          ],
        );
        return Dialog(
          child: SizedBox(
            width: 480,
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(28, 24, 28, 28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Usage', style: theme.textTheme.titleLarge),
                  if (accounts.isEmpty) ...[
                    const SizedBox(height: 20),
                    Text('No agent for this tier.', style: muted),
                  ],
                  for (final account in accounts) ...[
                    const SizedBox(height: 20),
                    if (accounts.length > 1) ...[
                      Text(
                        account.label,
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                    if (controller.usageUntracked(adapter!, account)
                        case final untracked?)
                      Text(untracked, style: muted)
                    else if (controller.usage[account.key] case final usage?)
                      for (final (i, (name, window)) in gaiaUsageWindows(
                        usage,
                      ).indexed) ...[
                        if (i > 0) const SizedBox(height: 12),
                        row(name, window),
                      ]
                    else
                      Text('Not read yet', style: muted),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    ),
  );
}

/// Auto, once the user has read its notice on this device (§4).
Future<void> _chooseAuto(
  BuildContext context,
  GaiaController controller,
) async {
  if (await controller.autoConsented()) {
    return controller.setHand(GaiaHand.auto);
  }
  if (!context.mounted) return;
  final send = _sendCombo(controller);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => CallbackShortcuts(
      bindings: {send.activator: () => Navigator.of(context).pop(true)},
      child: Focus(
        autofocus: true,
        child: AlertDialog(
          title: const Text('Let Gaia act without asking?'),
          content: const Text(
            'In Auto, Gaia clicks, types, runs shell commands and edits files '
            'in this chat with no cards to approve. You are responsible for '
            'what it does.\n\n'
            'Text it reads, on a page or in an email, can steer it. Use Auto '
            'for tasks you chose, and Ask for anything strangers wrote.\n\n'
            'Gaia may work in a window behind the ones you use, where you '
            "can't see it. Its activity card lists each step.\n\n"
            'The Stop button stops a run. So does Esc while Gaia or its '
            'window is in front, or a key you press in that window.',
          ),
          actions: [
            GaiaButton(
              label: 'Cancel',
              onPressed: () => Navigator.of(context).pop(false),
              color: Theme.of(context).colorScheme.error,
            ),
            GaiaButton(
              label: 'Turn on Auto ($send)',
              onPressed: () => Navigator.of(context).pop(true),
            ),
          ],
        ),
      ),
    ),
  );
  if (confirmed == true) {
    await controller.setHand(GaiaHand.auto, consented: true);
  }
}

/// The hand's icon: outlined for Off, filled for Ask, filled with a small
/// four-point star by it for Auto (§4).
class _HandIcon extends StatelessWidget {
  const _HandIcon({required this.hand});

  final GaiaHand hand;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = hand == GaiaHand.off
        ? theme.colorScheme.onSurfaceVariant
        : theme.colorScheme.primary;
    const outlined = Icon(Icons.pan_tool_alt_outlined, size: 14);
    // The filled glyph's edge sits inside the outlined one's, so filled is
    // the outline with its inside filled in, keeping the hand's size.
    final icon = IconTheme.merge(
      data: IconThemeData(color: color),
      child: hand == GaiaHand.off
          ? outlined
          : const Stack(
              children: [outlined, Icon(Icons.pan_tool_alt, size: 14)],
            ),
    );
    if (hand != GaiaHand.auto) return icon;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        icon,
        Positioned(
          right: -3,
          top: -3,
          child: CustomPaint(
            size: const Size.square(7),
            painter: _StarPainter(color),
          ),
        ),
      ],
    );
  }
}

/// A four-point star with concave sides, like a glint.
class _StarPainter extends CustomPainter {
  const _StarPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width / 2;
    final path = Path()..moveTo(c.dx, c.dy - r);
    var from = (0, -1);
    for (final (dx, dy) in [(1, 0), (0, 1), (-1, 0), (0, -1)]) {
      // Pulled in towards the middle, not all the way, so the arms keep
      // some width at this size.
      path.quadraticBezierTo(
        c.dx + (from.$1 + dx) * r * 0.12,
        c.dy + (from.$2 + dy) * r * 0.12,
        c.dx + dx * r,
        c.dy + dy * r,
      );
      from = (dx, dy);
    }
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_StarPainter old) => old.color != color;
}

/// The send keybind (§9.1), Ctrl+Enter by default, which is also its
/// default when unbound: Enter and Shift+Enter are newlines.
GaiaCombo _sendCombo(GaiaController controller) =>
    parseGaiaCombo(gaiaComboFor(GaiaKeybind.send, controller.keybinds)) ??
    parseGaiaCombo(GaiaKeybind.send.defaultCombo)!;

/// Edit & resend: [message] into the composer, once the user says to
/// replace what's in it, with the send keybind or the button, and the
/// focus there to edit it.
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
  controller.focusComposer();
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
