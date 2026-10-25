import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/features/gaia/adapters/gaia_agent_runner.dart';
import 'package:voyager/features/gaia/adapters/gaia_clis.dart';
import 'package:voyager/features/gaia/companion/gaia_button.dart';
import 'package:voyager/features/dev/dev_fps_counter_tile.dart';
import 'package:voyager/features/gaia/companion/gaia_controller.dart';
import 'package:voyager/features/gaia/companion/gaia_debug_menu.dart';
import 'package:voyager/features/gaia/companion/gaia_sidebar.dart';
import 'package:voyager/features/gaia/companion/gaia_starfield.dart';
import 'package:voyager/features/gaia/companion/gaia_tier_commands.dart';
import 'package:voyager/features/gaia/companion/gaia_text_field.dart';
import 'package:voyager/features/gaia/companion/gaia_toast.dart';
import 'package:voyager/features/gaia/companion/gaia_vanish.dart';
import 'package:voyager/features/gaia/companion/gaia_window.dart';
import 'package:voyager/domain/models/gaia_models.dart';
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
      icon: toast.error
          ? Icons.error_outline
          : toast.question
          ? Icons.help_outline
          : Icons.check_circle_outline,
      iconColor: toast.error ? Theme.of(context).colorScheme.error : null,
      title: toast.title,
      body: toast.body,
      onTap: () => widget.controller.selectChat(toast.chatId),
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
                        // A Material, which the chat list's tiles paint
                        // their selection and ink on.
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
                bottom: 76,
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

class _Sidebar extends StatelessWidget {
  const _Sidebar({required this.controller});

  final GaiaController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
          child: ListView(
            padding: const EdgeInsets.symmetric(vertical: 8),
            children: [
              for (final chat in controller.chats)
                ListTile(
                  dense: true,
                  selected: chat.id == controller.currentChatId,
                  title: Text(chat.title, overflow: TextOverflow.ellipsis),
                  trailing: controller.isRunning(chat.id)
                      ? const SizedBox.square(
                          dimension: 12,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : null,
                  onTap: () => controller.selectChat(chat.id),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(8),
          child: Align(
            alignment: Alignment.centerLeft,
            child: IconButton(
              tooltip: 'Debug menu (Ctrl+Shift+D)',
              icon: const Icon(Icons.bug_report_outlined, size: 18),
              onPressed: () => showGaiaDebugMenu(context, controller),
            ),
          ),
        ),
      ],
    );
  }
}

/// The width messages keep to: about 115 characters a line.
const _column = 860.0;

class _Messages extends StatelessWidget {
  const _Messages({required this.messages});

  final List<GaiaMessage> messages;

  @override
  Widget build(BuildContext context) {
    // Reversed, so the newest stays in view as a reply streams in.
    return LayoutBuilder(
      // Messages keep to a middle column of about 115 characters a line, as
      // in Claude's apps; narrower chats keep only a small gutter.
      builder: (context, constraints) => ScrollConfiguration(
        // Scrolls without a bar.
        behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
        child: ListView.builder(
          reverse: true,
          padding: EdgeInsets.symmetric(
            horizontal: max(16, (constraints.maxWidth - _column) / 2),
            vertical: 16,
          ),
          itemCount: messages.length,
          itemBuilder: (context, index) {
            final i = messages.length - 1 - index;
            final message = messages[i];
            final switched = _switchedFrom(messages, i);
            final view = _MessageView(message: message);
            if (switched == null) return view;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _VendorDivider(to: message.adapter!),
                view,
              ],
            );
          },
        ),
      ),
    );
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
    final muted = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
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
  const _MessageView({required this.message});

  final GaiaMessage message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    if (message.role == GaiaMessageRole.user) {
      return _bubble(
        theme.colorScheme.surfaceContainerHighest,
        Alignment.centerRight,
        SelectableText(message.text),
      );
    }
    final status = switch (message.status) {
      GaiaMessageStatus.streaming || GaiaMessageStatus.complete => null,
      GaiaMessageStatus.error => 'Error${_detail(message.error)}',
      GaiaMessageStatus.cancelled => 'Stopped',
      GaiaMessageStatus.interrupted => 'Interrupted',
      GaiaMessageStatus.aborted => 'Aborted',
    };
    // The chat's own background, so Gaia's bubble shows only as the stars
    // fading behind it.
    return _bubble(
      theme.scaffoldBackgroundColor,
      Alignment.centerLeft,
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final part in message.parts)
            switch (part) {
              GaiaTextPart(:final text) => SelectableText(text),
              GaiaActivityPart(:final tools) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Text(_activity(tools), style: muted),
              ),
            },
          if (message.status == GaiaMessageStatus.streaming)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: SizedBox.square(
                dimension: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          if (status != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                status,
                style: muted?.copyWith(
                  color: message.status == GaiaMessageStatus.error
                      ? theme.colorScheme.error
                      : null,
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// A message's rectangle, hugging its text. Nearly opaque, so the
  /// starfield behind it is almost gone but the stars around it aren't.
  Widget _bubble(Color color, Alignment alignment, Widget child) {
    return Align(
      alignment: alignment,
      child: Container(
        // The user's keep clear of the left, so their side stays theirs.
        margin: EdgeInsets.only(
          bottom: 12,
          left: alignment == Alignment.centerRight ? 48 : 0,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.92),
          borderRadius: BorderRadius.circular(12),
        ),
        child: child,
      ),
    );
  }

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

class _Composer extends StatefulWidget {
  const _Composer({required this.controller});

  final GaiaController controller;

  @override
  State<_Composer> createState() => _ComposerState();
}

class _ComposerState extends State<_Composer> {
  final _text = TextEditingController();
  final _focus = FocusNode();
  final _vanish = GlobalKey<GaiaVanishState>();

  @override
  void initState() {
    super.initState();
    _text.addListener(() => unawaited(_takeTierCommand()));
  }

  @override
  void dispose() {
    _text.dispose();
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
    if (!await _takeTierCommand(atEnd: true) || !mounted) return;
    final text = _text.text;
    if (text.trim().isEmpty || widget.controller.currentRunning) return;
    _vanish.currentState!.vanish();
    _text.clear();
    widget.controller.send(text);
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
    return LayoutBuilder(
      builder: (context, constraints) {
        // A little wider than the messages' column, as in Claude's apps.
        final side = max(12.0, (constraints.maxWidth - _column) / 2 - 12);
        return Padding(
          padding: EdgeInsets.fromLTRB(side, 8, side, 12),
          child: CallbackShortcuts(
            bindings: {const SingleActivator(LogicalKeyboardKey.enter): _send},
            child: GaiaVanish(
              key: _vanish,
              controller: _text,
              builder: (context, vanishing) => GaiaTextField(
                controller: _text,
                focusNode: _focus,
                autofocus: true,
                minLines: vanishing ? null : 1,
                maxLines: vanishing ? null : 8,
                expands: vanishing,
                textAlignVertical: vanishing ? TextAlignVertical.top : null,
                hintText: vanishing ? null : 'Message Gaia',
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _TierPicker(controller: controller),
                    const SizedBox(width: 8),
                    if (running)
                      GaiaButton(
                        icon: Icons.stop,
                        size: 32,
                        onPressed: () =>
                            controller.stop(controller.currentChatId!),
                      )
                    else
                      GaiaButton(
                        icon: Icons.arrow_upward,
                        size: 32,
                        onPressed: _send,
                      ),
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

/// The tier the next message goes to (§7.2), and a menu of all three with
/// their agents.
class _TierPicker extends StatelessWidget {
  const _TierPicker({required this.controller});

  final GaiaController controller;

  @override
  Widget build(BuildContext context) {
    final current = controller.nextTier;
    return MenuAnchor(
      menuChildren: [
        for (final tier in GaiaTier.values)
          MenuItemButton(
            onPressed: () => switchGaiaTier(context, controller, tier),
            leadingIcon: Icon(tier == current ? Icons.check : null, size: 16),
            child: Text(
              '${tier.label} · ${controller.agentFor(tier)?.label ?? 'no agent'}',
            ),
          ),
      ],
      builder: (context, menu, _) => Tooltip(
        message: controller.agentFor(current)?.label ?? 'No agent',
        child: GaiaButton(
          label: current.label,
          size: 32,
          onPressed: () => menu.isOpen ? menu.close() : menu.open(),
        ),
      ),
    );
  }
}

/// Switches the current chat's next message to [tier]: silently before
/// its first reply, after the user's yes once there is one (§7.5). The
/// dialog says what the switch costs: the prompt cache, and across vendors
/// everything but a transcript. Ctrl+Enter confirms; Esc keeps the tier,
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
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter, control: true): () =>
            Navigator.of(context).pop(true),
      },
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
              'Press Ctrl+Enter to switch.',
            ].join('\n\n'),
          ),
          actions: [
            GaiaButton(
              label: 'Cancel',
              onPressed: () => Navigator.of(context).pop(false),
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
          GaiaButton(label: 'Cancel', onPressed: controller.cancelDrain),
        ],
      ),
    );
  }
}

/// In place of the composer while Abort is engaged (§15.7). Re-arming is
/// deliberate: confirmed with Ctrl+Enter.
class _Aborted extends StatelessWidget {
  const _Aborted({required this.controller});

  final GaiaController controller;

  Future<void> _confirm(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.enter, control: true): () =>
              Navigator.of(context).pop(true),
        },
        child: Focus(
          autofocus: true,
          child: AlertDialog(
            title: const Text('Re-arm Gaia?'),
            content: const Text(
              'Chats and runs work again. Press Ctrl+Enter to confirm.',
            ),
            actions: [
              GaiaButton(
                label: 'Cancel',
                onPressed: () => Navigator.of(context).pop(false),
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
