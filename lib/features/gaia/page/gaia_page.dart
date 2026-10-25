import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:uuid/uuid.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/platform/platform_info.dart';
import 'package:voyager/core/soft_delete/soft_delete_toast.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/voyager_text_field.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/adapters/claude_code/claude_code_events.dart';
import 'package:voyager/features/gaia/adapters/codex/codex_events.dart';
import 'package:voyager/features/gaia/adapters/codex/codex_runner.dart';
import 'package:voyager/features/gaia/gaia_secrets.dart';
import 'package:voyager/features/gaia/host/gaia_host.dart';
import 'package:voyager/features/gaia/page/gaia_providers.dart';

enum _GaiaTab { chats, setup, settings }

/// The Gaia page (GAIA_HLD.md §17): chats with search, the setup checklist,
/// and Gaia's settings. On the desktop a chat opens in Gaia itself; on
/// Android, until a phone can run agents (Phases 2 and 6), its transcript
/// opens read-only.
class GaiaPage extends ConsumerStatefulWidget {
  const GaiaPage({super.key});

  @override
  ConsumerState<GaiaPage> createState() => _GaiaPageState();
}

class _GaiaPageState extends ConsumerState<GaiaPage> {
  var _tab = _GaiaTab.chats;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      type: MaterialType.transparency,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
        children: [
          Row(
            children: [
              Text('Gaia', style: theme.textTheme.headlineSmall),
              const Spacer(),
              if (isWindows)
                GlassButton(
                  onPressed: () =>
                      GaiaHost.instance.onHotkey(GaiaHotkey.window),
                  icon: const Icon(PhosphorIconsRegular.planet, size: 13),
                  label: 'Open Gaia',
                  dense: true,
                ),
            ],
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: SegmentedButton<_GaiaTab>(
              showSelectedIcon: false,
              style: SegmentedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
              ),
              segments: [
                const ButtonSegment(
                  value: _GaiaTab.chats,
                  icon: Icon(PhosphorIconsRegular.chatsCircle, size: 15),
                  label: Text('Chats'),
                ),
                // The CLIs run on the desktop only.
                if (isWindows)
                  const ButtonSegment(
                    value: _GaiaTab.setup,
                    icon: Icon(PhosphorIconsRegular.wrench, size: 15),
                    label: Text('Setup'),
                  ),
                const ButtonSegment(
                  value: _GaiaTab.settings,
                  icon: Icon(PhosphorIconsRegular.gear, size: 15),
                  label: Text('Settings'),
                ),
              ],
              selected: {_tab},
              onSelectionChanged: (set) => setState(() => _tab = set.first),
            ),
          ),
          const SizedBox(height: 16),
          switch (_tab) {
            _GaiaTab.chats => const _ChatsTab(),
            _GaiaTab.setup => const _SetupTab(),
            _GaiaTab.settings => const _SettingsTab(),
          },
        ],
      ),
    );
  }
}

class _ChatsTab extends ConsumerStatefulWidget {
  const _ChatsTab();

  @override
  ConsumerState<_ChatsTab> createState() => _ChatsTabState();
}

class _ChatsTabState extends ConsumerState<_ChatsTab> {
  final _search = TextEditingController();
  var _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final chats = ref.watch(gaiaChatsProvider).valueOrNull ?? const [];
    final runs = isWindows ? ref.watch(gaiaRunsProvider) : const <GaiaRun>[];
    final running = {for (final run in runs) run.chatId};
    final query = _query.trim();
    final matches = query.isEmpty
        ? null
        : ref.watch(gaiaSearchProvider(query)).valueOrNull ?? const {};
    final shown = [
      for (final chat in chats)
        if (matches == null ||
            matches.contains(chat.id) ||
            chat.title.toLowerCase().contains(query.toLowerCase()))
          chat,
    ];
    final pinned = [
      for (final chat in shown)
        if (chat.pinned) chat,
    ];
    final recent = [
      for (final chat in shown)
        if (!chat.pinned) chat,
    ];
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (runs.isNotEmpty) ...[
          _SectionLabel(
            runs.length == 1 ? 'In progress' : 'In progress (${runs.length})',
          ),
          for (final run in runs)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const SizedBox.square(
                dimension: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              title: Text(
                run.title.isEmpty ? 'New chat' : run.title,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: GlassButton(
                onPressed: () => GaiaHost.instance.stop(run.chatId),
                icon: const Icon(PhosphorIconsRegular.stop, size: 13),
                label: 'Stop',
                dense: true,
              ),
              onTap: () => GaiaHost.instance.openChat(run.chatId),
            ),
          const SizedBox(height: 16),
        ],
        VoyagerTextField(
          controller: _search,
          decoration: const InputDecoration(
            hintText: 'Search chats',
            prefixIcon: Icon(PhosphorIconsRegular.magnifyingGlass, size: 16),
            isDense: true,
          ),
          onChanged: (text) => setState(() => _query = text),
        ),
        const SizedBox(height: 12),
        if (chats.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Text(
              isWindows
                  ? 'No chats yet. Open Gaia to start one.'
                  : 'No chats yet. Chats you have with Gaia on your '
                        'desktop show up here.',
              style: muted,
            ),
          )
        else if (shown.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Text('No chats match "$query".', style: muted),
          ),
        if (pinned.isNotEmpty) ...[
          const _SectionLabel('Pinned'),
          for (final chat in pinned)
            _ChatRow(chat: chat, running: running.contains(chat.id)),
          const SizedBox(height: 12),
        ],
        if (recent.isNotEmpty) ...[
          if (pinned.isNotEmpty) const _SectionLabel('Recent'),
          for (final chat in recent)
            _ChatRow(chat: chat, running: running.contains(chat.id)),
        ],
      ],
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text(
        text,
        style: theme.textTheme.labelMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _ChatRow extends ConsumerWidget {
  const _ChatRow({required this.chat, required this.running});

  final GaiaChat chat;
  final bool running;

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final overlay = Overlay.of(context, rootOverlay: true);
    final container = ProviderScope.containerOf(context, listen: false);
    final id = chat.id;
    await softDeleteWithUndo(
      overlay: overlay,
      message: deletedMessage(chat.title, fallback: 'chat'),
      delete: () => container.read(gaiaRepositoryProvider).softDeleteChat(id),
      restore: () => container.read(gaiaRepositoryProvider).restoreChat(id),
    );
  }

  void _open(BuildContext context) {
    if (isWindows) {
      GaiaHost.instance.openChat(chat.id);
    } else {
      Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => _GaiaTranscript(chat: chat)),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text(chat.title, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        _when(chat.lastMessageAt.toLocal()),
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (running)
            const Padding(
              padding: EdgeInsets.only(right: 8),
              child: SizedBox.square(
                dimension: 12,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          IconButton(
            tooltip: chat.pinned ? 'Unpin' : 'Pin',
            icon: Icon(
              chat.pinned
                  ? PhosphorIconsFill.pushPin
                  : PhosphorIconsRegular.pushPin,
              size: 16,
            ),
            // From the stored chat, not this row's: the companion may have
            // written its session or last message since the row was built.
            onPressed: () async {
              final repository = ref.read(gaiaRepositoryProvider);
              final current = await repository.getChat(chat.id);
              if (current == null) return;
              await repository.upsertChat(
                current.copyWith(pinned: !chat.pinned),
              );
            },
          ),
          IconButton(
            tooltip: 'Delete',
            icon: const Icon(PhosphorIconsRegular.trash, size: 16),
            // A chat mid-run is stopped first, from Gaia.
            onPressed: running ? null : () => _delete(context, ref),
          ),
        ],
      ),
      onTap: () => _open(context),
    );
  }

  static String _when(DateTime at) {
    final now = DateTime.now();
    if (at.year == now.year && at.month == now.month && at.day == now.day) {
      return DateFormat.jm().format(at);
    }
    return at.year == now.year
        ? DateFormat.MMMd().format(at)
        : DateFormat.yMMMd().format(at);
  }
}

/// A chat's transcript, read-only: Android's view until a phone can run
/// agents.
class _GaiaTranscript extends ConsumerWidget {
  const _GaiaTranscript({required this.chat});

  final GaiaChat chat;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final messages =
        ref.watch(gaiaMessagesProvider(chat.id)).valueOrNull ?? const [];
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Scaffold(
      appBar: AppBar(title: Text(chat.title, overflow: TextOverflow.ellipsis)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          for (final message in messages)
            if (message.role == GaiaMessageRole.user)
              Align(
                alignment: Alignment.centerRight,
                child: Container(
                  margin: const EdgeInsets.only(bottom: 12, left: 48),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: SelectableText(message.text),
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final part in message.parts)
                      switch (part) {
                        GaiaTextPart(:final text) => SelectableText(text),
                        GaiaActivityPart(:final tools) => Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Text(
                            'Used ${tools.toSet().join(', ')}',
                            style: muted,
                          ),
                        ),
                      },
                    if (message.status != GaiaMessageStatus.complete)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(switch (message.status) {
                          GaiaMessageStatus.streaming => 'Still running',
                          GaiaMessageStatus.error => 'Error',
                          GaiaMessageStatus.cancelled => 'Stopped',
                          GaiaMessageStatus.interrupted => 'Interrupted',
                          GaiaMessageStatus.aborted => 'Aborted',
                          GaiaMessageStatus.complete => '',
                        }, style: muted),
                      ),
                  ],
                ),
              ),
        ],
      ),
    );
  }
}

/// The CLI checklist (§5.1): installed, version, logged in, each with the
/// command that fixes it.
class _SetupTab extends StatelessWidget {
  const _SetupTab();

  @override
  Widget build(BuildContext context) {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [_ClaudeSetup(), SizedBox(height: 24), _CodexSetup()],
    );
  }
}

class _ClaudeSetup extends ConsumerWidget {
  const _ClaudeSetup();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final setup = ref.watch(gaiaClaudeSetupProvider);
    final (low, high) = kClaudeCodeTestedVersions;
    String v((int, int, int) version) =>
        '${version.$1}.${version.$2}.${version.$3}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text('Claude Code', style: theme.textTheme.titleMedium),
            const Spacer(),
            GlassButton(
              onPressed: setup.isLoading
                  ? null
                  : () => ref.invalidate(gaiaClaudeSetupProvider),
              icon: const Icon(PhosphorIconsRegular.arrowClockwise, size: 13),
              label: 'Check again',
              dense: true,
            ),
          ],
        ),
        const SizedBox(height: 8),
        switch (setup) {
          AsyncData(:final value) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _CheckRow(
                ok: value.installed,
                label: value.installed
                    ? 'Installed: ${v(value.version!)}'
                    : 'Not installed',
                fix: value.installed
                    ? null
                    : 'npm install -g @anthropic-ai/claude-code',
              ),
              if (value.installed) ...[
                _CheckRow(
                  ok: value.tested,
                  warnOnly: true,
                  label: value.tested
                      ? 'A tested version'
                      : 'Untested version: Gaia is tested with '
                            '${v(low)} up to ${v(high)}. Chats still run.',
                ),
                _CheckRow(
                  ok: value.loggedIn == true,
                  label: switch (value.loggedIn) {
                    true =>
                      'Logged in${value.email == null ? '' : ' as ${value.email}'}',
                    false => 'Not logged in',
                    null => "Couldn't read the login status",
                  },
                  fix: value.loggedIn == true ? null : 'claude auth login',
                ),
              ],
            ],
          ),
          AsyncError() => const _CheckRow(
            ok: false,
            label: "Couldn't run the check",
          ),
          _ => const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: LinearProgressIndicator(),
          ),
        },
      ],
    );
  }
}

class _CodexSetup extends ConsumerWidget {
  const _CodexSetup();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final setup = ref.watch(gaiaCodexSetupProvider);
    final (low, high) = kCodexTestedVersions;
    String v((int, int, int) version) =>
        '${version.$1}.${version.$2}.${version.$3}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text('Codex', style: theme.textTheme.titleMedium),
            const Spacer(),
            GlassButton(
              onPressed: setup.isLoading
                  ? null
                  : () => ref.invalidate(gaiaCodexSetupProvider),
              icon: const Icon(PhosphorIconsRegular.arrowClockwise, size: 13),
              label: 'Check again',
              dense: true,
            ),
          ],
        ),
        const SizedBox(height: 8),
        switch (setup) {
          AsyncData(:final value) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _CheckRow(
                ok: value.installed,
                label: value.installed
                    ? 'Installed: ${v(value.version!)}'
                    : 'Not installed',
                fix: value.installed ? null : 'npm install -g @openai/codex',
              ),
              if (value.installed) ...[
                _CheckRow(
                  ok: value.tested,
                  warnOnly: true,
                  label: value.tested
                      ? 'A tested version'
                      : 'Untested version: Gaia is tested with '
                            '${v(low)} up to ${v(high)}. Chats still run.',
                ),
                _CheckRow(
                  ok: value.loggedIn == true,
                  label: switch (value.loggedIn) {
                    true => 'Logged in',
                    false => 'Not logged in',
                    null => "Couldn't read the login status",
                  },
                  fix: value.loggedIn == true ? null : 'codex login',
                ),
                if (value.sandboxReady case final ready?)
                  _CheckRow(
                    ok: ready,
                    label: ready
                        ? 'Sandbox set up for Gaia'
                        : "Codex's Windows sandbox needs setting up once for "
                              'Gaia. Windows will ask you to approve it.',
                    action: ready
                        ? null
                        : GlassButton(
                            onPressed: () async {
                              await setUpCodexSandbox(
                                codexHome: await defaultGaiaCodexHome(),
                              );
                              ref.invalidate(gaiaCodexSetupProvider);
                            },
                            label: 'Set up',
                            dense: true,
                          ),
                  ),
              ],
            ],
          ),
          AsyncError() => const _CheckRow(
            ok: false,
            label: "Couldn't run the check",
          ),
          _ => const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: LinearProgressIndicator(),
          ),
        },
      ],
    );
  }
}

class _CheckRow extends StatelessWidget {
  const _CheckRow({
    required this.ok,
    required this.label,
    this.fix,
    this.action,
    this.warnOnly = false,
  });

  final bool ok;
  final String label;

  /// The command that fixes it, shown copyable.
  final String? fix;

  /// A button that fixes it.
  final Widget? action;

  /// Not a blocker: amber rather than red.
  final bool warnOnly;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = ok
        ? theme.colorScheme.primary
        : warnOnly
        ? Colors.amber
        : theme.colorScheme.error;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            ok
                ? PhosphorIconsRegular.checkCircle
                : warnOnly
                ? PhosphorIconsRegular.warningCircle
                : PhosphorIconsRegular.xCircle,
            size: 18,
            color: color,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label),
                if (action case final action?)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: action,
                  ),
                if (fix case final command?)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Row(
                      children: [
                        Flexible(
                          child: SelectableText(
                            command,
                            style: theme.textTheme.bodySmall?.copyWith(
                              fontFamily: 'monospace',
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: 'Copy',
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(PhosphorIconsRegular.copy, size: 14),
                          onPressed: () =>
                              Clipboard.setData(ClipboardData(text: command)),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SettingsTab extends ConsumerStatefulWidget {
  const _SettingsTab();

  @override
  ConsumerState<_SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends ConsumerState<_SettingsTab> {
  final _gaiaMd = TextEditingController();

  /// GAIA.md as last loaded or saved, to tell an edit from what's stored.
  String? _saved;

  @override
  void dispose() {
    _gaiaMd.dispose();
    super.dispose();
  }

  Future<void> _save(GaiaSettings settings) async {
    final text = _gaiaMd.text;
    await ref
        .read(gaiaRepositoryProvider)
        .upsertSettings(settings.copyWith(gaiaMd: text));
    setState(() => _saved = text);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final settings = ref.watch(gaiaSettingsProvider).valueOrNull;
    if (settings == null) return const SizedBox.shrink();
    // Loaded once, and again when another device changes it while nothing
    // here is unsaved.
    if (_saved == null ||
        (_gaiaMd.text == _saved && _saved != settings.gaiaMd)) {
      _saved = settings.gaiaMd;
      _gaiaMd.text = settings.gaiaMd;
    }
    final dirty = _gaiaMd.text != _saved;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('GAIA.md', style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          "Instructions every agent gets, in place of the CLIs' own global "
          'files (your CLAUDE.md is left out of Gaia chats). Synced to all '
          'your devices.',
          style: muted,
        ),
        const SizedBox(height: 8),
        VoyagerTextField(
          controller: _gaiaMd,
          minLines: 8,
          maxLines: 20,
          decoration: const InputDecoration(
            hintText: 'e.g. Keep answers short. I use Windows and Flutter.',
          ),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerRight,
          child: GlassButton(
            onPressed: dirty ? () => _save(settings) : null,
            label: 'Save',
            dense: true,
          ),
        ),
        const SizedBox(height: 24),
        _AgentsSection(settings: settings),
        const SizedBox(height: 24),
        _UtilitySection(settings: settings),
        const SizedBox(height: 16),
        if (isWindows) ...[
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Notify when a run finishes'),
            subtitle: const Text(
              'A Windows notification when Gaia finishes, or has a question, '
              'while it is hidden.',
            ),
            value: settings.notifyOnDone,
            onChanged: (value) => ref
                .read(gaiaRepositoryProvider)
                .upsertSettings(settings.copyWith(notifyOnDone: value)),
          ),
          const SizedBox(height: 8),
          Text(
            "Gaia's window is hidden from screenshots and screen recordings, "
            'including your own screen shares, so it never shows up in '
            'what it captures.',
            style: muted,
          ),
        ],
      ],
    );
  }
}

/// The adapters an agent can be added on, with their names. The Gemini CLI
/// is deferred until its login can be tested.
const _adapterLabels = {
  kGaiaClaudeCodeAdapter: 'Claude Code',
  kGaiaCodexAdapter: 'Codex',
};

/// Tiers and agents (§7.1): which agent each of Quick, Standard and Deep
/// runs on, and the agents to pick from.
class _AgentsSection extends ConsumerWidget {
  const _AgentsSection({required this.settings});

  final GaiaSettings settings;

  Future<void> _save(WidgetRef ref, GaiaSettings updated) =>
      ref.read(gaiaRepositoryProvider).upsertSettings(updated);

  Future<void> _add(BuildContext context, WidgetRef ref) async {
    final agent = await showDialog<GaiaAgent>(
      context: context,
      builder: (_) => const _AddAgentDialog(),
    );
    if (agent == null) return;
    await _save(ref, settings.copyWith(agents: [...settings.agents, agent]));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final inUse = settings.tiers.values.toSet();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Tiers', style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          'Each tier runs on an agent. Pick the tier for a message from '
          "Gaia's composer.",
          style: muted,
        ),
        const SizedBox(height: 8),
        for (final tier in GaiaTier.values)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                SizedBox(width: 96, child: Text(tier.label)),
                Expanded(
                  child: DropdownButton<String>(
                    isExpanded: true,
                    value: settings.agentFor(tier)?.id,
                    hint: const Text('No agent'),
                    items: [
                      for (final agent in settings.agents)
                        DropdownMenuItem(
                          value: agent.id,
                          child: Text(
                            '${agent.label} · '
                            '${_adapterLabels[agent.adapter] ?? agent.adapter}',
                          ),
                        ),
                    ],
                    onChanged: (id) {
                      if (id == null) return;
                      _save(
                        ref,
                        settings.copyWith(tiers: {...settings.tiers, tier: id}),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 16),
        Row(
          children: [
            Text('Agents', style: theme.textTheme.titleMedium),
            const Spacer(),
            GlassButton(
              onPressed: () => _add(context, ref),
              icon: const Icon(PhosphorIconsRegular.plus, size: 13),
              label: 'Add agent',
              dense: true,
            ),
          ],
        ),
        for (final agent in settings.agents)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(agent.label),
            subtitle: Text(
              '${_adapterLabels[agent.adapter] ?? agent.adapter} · '
              '${agent.model}',
              style: muted,
            ),
            trailing: IconButton(
              tooltip: inUse.contains(agent.id)
                  ? 'A tier uses this agent'
                  : 'Remove',
              icon: const Icon(PhosphorIconsRegular.trash, size: 16),
              onPressed: inUse.contains(agent.id)
                  ? null
                  : () => _save(
                      ref,
                      settings.copyWith(
                        agents: [
                          for (final a in settings.agents)
                            if (a.id != agent.id) a,
                        ],
                      ),
                    ),
            ),
          ),
      ],
    );
  }
}

class _AddAgentDialog extends StatefulWidget {
  const _AddAgentDialog();

  @override
  State<_AddAgentDialog> createState() => _AddAgentDialogState();
}

class _AddAgentDialogState extends State<_AddAgentDialog> {
  final _label = TextEditingController();
  final _model = TextEditingController();
  var _adapter = kGaiaClaudeCodeAdapter;

  @override
  void dispose() {
    _label.dispose();
    _model.dispose();
    super.dispose();
  }

  bool get _valid =>
      _label.text.trim().isNotEmpty && _model.text.trim().isNotEmpty;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add agent'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DropdownButton<String>(
              isExpanded: true,
              value: _adapter,
              items: [
                for (final MapEntry(:key, :value) in _adapterLabels.entries)
                  DropdownMenuItem(value: key, child: Text(value)),
              ],
              onChanged: (adapter) => setState(() => _adapter = adapter!),
            ),
            const SizedBox(height: 8),
            VoyagerTextField(
              controller: _model,
              decoration: InputDecoration(
                labelText: 'Model',
                hintText: _adapter == kGaiaCodexAdapter
                    ? 'e.g. gpt-6.1-sol'
                    : 'e.g. claude-sonnet-5-5',
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 8),
            VoyagerTextField(
              controller: _label,
              decoration: const InputDecoration(
                labelText: 'Name',
                hintText: 'e.g. GPT-6.1 Sol',
              ),
              onChanged: (_) => setState(() {}),
            ),
          ],
        ),
      ),
      actions: [
        GlassButton(
          onPressed: () => Navigator.of(context).pop(),
          label: 'Cancel',
          dense: true,
        ),
        GlassButton(
          onPressed: _valid
              ? () => Navigator.of(context).pop(
                  GaiaAgent(
                    id: const Uuid().v4(),
                    label: _label.text.trim(),
                    adapter: _adapter,
                    model: _model.text.trim(),
                  ),
                )
              : null,
          label: 'Add',
          dense: true,
        ),
      ],
    );
  }
}

/// The utility model (§5.1): a Gemini API key on this device, the model,
/// the terms it runs under, and the router (§7.2) it powers.
class _UtilitySection extends ConsumerStatefulWidget {
  const _UtilitySection({required this.settings});

  final GaiaSettings settings;

  @override
  ConsumerState<_UtilitySection> createState() => _UtilitySectionState();
}

class _UtilitySectionState extends ConsumerState<_UtilitySection> {
  final _key = TextEditingController();
  final _model = TextEditingController();
  final _rubric = TextEditingController();
  String? _savedModel;
  String? _savedRubric;

  @override
  void dispose() {
    _key.dispose();
    _model.dispose();
    _rubric.dispose();
    super.dispose();
  }

  Future<void> _save(GaiaSettings updated) =>
      ref.read(gaiaRepositoryProvider).upsertSettings(updated);

  Future<void> _saveKey(String? key) async {
    await GaiaSecrets().writeUtilityKey(key);
    _key.clear();
    ref.invalidate(gaiaUtilityKeySavedProvider);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final settings = widget.settings;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    // As GAIA.md's field: loaded once, and again on a change from another
    // device while nothing here is unsaved.
    if (_savedModel == null ||
        (_model.text == _savedModel && _savedModel != settings.utilityModel)) {
      _savedModel = settings.utilityModel;
      _model.text = settings.utilityModel;
    }
    if (_savedRubric == null ||
        (_rubric.text == _savedRubric &&
            _savedRubric != settings.routerRubric)) {
      _savedRubric = settings.routerRubric;
      _rubric.text = settings.routerRubric;
    }
    final keySaved = ref.watch(gaiaUtilityKeySavedProvider).valueOrNull;
    final dirty =
        _model.text.trim() != _savedModel || _rubric.text != _savedRubric;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Utility model', style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          'A fast Gemini model on an API key: it picks the tier for a new '
          "chat and writes chat titles. Without one, a new chat starts on "
          'the tier you last used and is titled by its first line.',
          style: muted,
        ),
        const SizedBox(height: 8),
        if (isWindows) ...[
          Row(
            children: [
              Expanded(
                child: VoyagerTextField(
                  controller: _key,
                  obscureText: true,
                  decoration: InputDecoration(
                    labelText: 'Gemini API key',
                    hintText: keySaved == true
                        ? 'Saved on this device'
                        : 'From Google AI Studio',
                    isDense: true,
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              const SizedBox(width: 8),
              GlassButton(
                onPressed: _key.text.trim().isEmpty
                    ? null
                    : () => _saveKey(_key.text),
                label: 'Save key',
                dense: true,
              ),
              if (keySaved == true) ...[
                const SizedBox(width: 8),
                GlassButton(
                  onPressed: () => _saveKey(null),
                  label: 'Remove',
                  dense: true,
                ),
              ],
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Kept on this computer only, encrypted to your Windows account. '
            'It is never synced.',
            style: muted,
          ),
          const SizedBox(height: 8),
        ],
        VoyagerTextField(
          controller: _model,
          decoration: const InputDecoration(
            labelText: 'Model',
            hintText: kGaiaDefaultUtilityModel,
            isDense: true,
          ),
          onChanged: (_) => setState(() {}),
        ),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          value: settings.utilityAcknowledged,
          title: const Text(
            'My key is on a paid tier, or I accept that Google may use these '
            'prompts',
          ),
          subtitle: const Text(
            'The utility model reads every chat. On the free tier, Google may '
            'use what it reads to improve its products.',
          ),
          onChanged: (value) =>
              _save(settings.copyWith(utilityAcknowledged: value)),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Pick the tier for a new chat'),
          subtitle: const Text(
            "Only a chat's first message. After that, the tier only changes "
            'when you change it.',
          ),
          value: settings.autoRoute,
          onChanged: (value) => _save(settings.copyWith(autoRoute: value)),
        ),
        VoyagerTextField(
          controller: _rubric,
          minLines: 3,
          maxLines: 8,
          decoration: const InputDecoration(
            labelText: 'Router rubric',
            hintText: kGaiaDefaultRouterRubric,
          ),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerRight,
          child: GlassButton(
            onPressed: dirty
                ? () async {
                    final model = _model.text.trim().isEmpty
                        ? kGaiaDefaultUtilityModel
                        : _model.text.trim();
                    final rubric = _rubric.text;
                    await _save(
                      settings.copyWith(
                        utilityModel: model,
                        routerRubric: rubric,
                      ),
                    );
                    setState(() {
                      _savedModel = model;
                      _model.text = model;
                      _savedRubric = rubric;
                    });
                  }
                : null,
            label: 'Save',
            dense: true,
          ),
        ),
      ],
    );
  }
}
