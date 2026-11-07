import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:uuid/uuid.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/platform/platform_info.dart';
import 'package:voyager/core/soft_delete/soft_delete_toast.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/theme/app_fonts.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/voyager_text_field.dart';
import 'package:voyager/core/widgets/voyager_toast.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/adapters/claude_code/claude_code_events.dart';
import 'package:voyager/features/gaia/adapters/codex/codex_events.dart';
import 'package:voyager/features/gaia/adapters/codex/codex_runner.dart';
import 'package:voyager/features/gaia/companion/gaia_card_view.dart';
import 'package:voyager/features/gaia/companion/gaia_commands.dart';
import 'package:voyager/features/gaia/companion/gaia_spinner.dart';
import 'package:voyager/features/gaia/gaia_keybinds.dart';
import 'package:voyager/features/gaia/host/gaia_host.dart';
import 'package:voyager/features/gaia/host/gaia_memories.dart';
import 'package:voyager/features/gaia/host/gaia_voyager_reads.dart';
import 'package:voyager/features/gaia/page/gaia_providers.dart';
import 'package:voyager/features/gaia/usage/gaia_usage.dart';
import 'package:voyager/features/gaia/usage/gaia_usage_bar.dart';
import 'package:voyager/features/gaia/page/gaia_remote_chat.dart';
import 'package:voyager/features/gaia/page/gaia_queue_tab.dart';
import 'package:voyager/features/gaia/page/gaia_status_tab.dart';
import 'package:voyager/features/gaia/tools/gaia_proposals.dart';

enum _GaiaTab { chats, actions, memories, queue, status, setup, settings }

/// The Gaia page (GAIA_HLD.md §17): chats with search, the action log,
/// memories and their inbox, desktops and paired devices, the setup
/// checklist, and Gaia's settings. On the desktop a chat opens in Gaia
/// itself; on Android it opens here, and runs on a paired desktop (§12.2).
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
    final inbox = [
      for (final memory
          in ref.watch(gaiaMemoriesProvider).valueOrNull ?? const [])
        if (memory.status == GaiaMemoryStatus.proposed) memory,
    ].length;
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
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
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
                const ButtonSegment(
                  value: _GaiaTab.actions,
                  icon: Icon(PhosphorIconsRegular.listChecks, size: 15),
                  label: Text('Actions'),
                ),
                ButtonSegment(
                  value: _GaiaTab.memories,
                  icon: const Icon(PhosphorIconsRegular.brain, size: 15),
                  label: Text(inbox == 0 ? 'Memories' : 'Memories ($inbox)'),
                ),
                const ButtonSegment(
                  value: _GaiaTab.queue,
                  icon: Icon(PhosphorIconsRegular.queue, size: 15),
                  label: Text('Queue'),
                ),
                const ButtonSegment(
                  value: _GaiaTab.status,
                  icon: Icon(PhosphorIconsRegular.broadcast, size: 15),
                  label: Text('Status'),
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
            _GaiaTab.actions => const _ActionsTab(),
            _GaiaTab.memories => const _MemoriesTab(),
            _GaiaTab.queue => const GaiaQueueTab(),
            _GaiaTab.status => const GaiaStatusTab(),
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

  /// The chats whose forks are folded away under them.
  final _collapsed = <String>{};

  /// The forks listed so far, so a new one shows its group again.
  Set<String>? _forks;

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
    // On the phone, what every desktop says it's running (§12.2).
    final running = isWindows
        ? {for (final run in runs) run.chatId}
        : {
            for (final beacon
                in ref.watch(gaiaBeaconsProvider).valueOrNull ?? const [])
              for (final run in beacon.runs) run.chatId,
          };
    // A new fork shows its group again (GAIA_FORKING_HLD.md §7).
    final forks = {
      for (final chat in chats)
        if (chat.forkOf != null) chat.id,
    };
    if (_forks case final known?) {
      for (final chat in chats) {
        if (chat.forkOf != null && !known.contains(chat.id)) {
          _collapsed.remove(chat.forkOf);
        }
      }
    }
    _forks = forks;
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
    // A search lists what it found on its own, forks or not.
    final groups = query.isEmpty
        ? gaiaForkGroups(shown)
        : [for (final chat in shown) (chat: chat, forks: const <GaiaChat>[])];
    final pinned = [
      for (final group in groups)
        if (group.chat.pinned) group,
    ];
    final recent = [
      for (final group in groups)
        if (!group.chat.pinned) group,
    ];
    List<Widget> rows(List<({GaiaChat chat, List<GaiaChat> forks})> groups) => [
      for (final (:chat, :forks) in groups) ...[
        _ChatRow(
          chat: chat,
          running: running.contains(chat.id),
          open: forks.isEmpty ? null : !_collapsed.contains(chat.id),
          onFold: () => setState(() {
            if (!_collapsed.remove(chat.id)) _collapsed.add(chat.id);
          }),
        ),
        if (!_collapsed.contains(chat.id))
          for (final (i, fork) in forks.indexed)
            _ForkLine(
              last: i == forks.length - 1,
              child: _ChatRow(chat: fork, running: running.contains(fork.id)),
            ),
      ],
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
              leading: const GaiaSpinner(size: 20, label: 'Running'),
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
        Row(
          children: [
            Expanded(
              child: VoyagerTextField(
                controller: _search,
                decoration: const InputDecoration(
                  hintText: 'Search chats',
                  prefixIcon: Icon(
                    PhosphorIconsRegular.magnifyingGlass,
                    size: 16,
                  ),
                  isDense: true,
                ),
                onChanged: (text) => setState(() => _query = text),
              ),
            ),
            // On the phone a chat starts here and runs on a desktop.
            if (!isWindows) ...[
              const SizedBox(width: 8),
              GlassButton(
                dense: true,
                label: 'New chat',
                icon: const Icon(PhosphorIconsRegular.plus, size: 13),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        GaiaRemoteChatPage(chatId: const Uuid().v4()),
                  ),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 12),
        if (chats.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Text(
              isWindows
                  ? 'No chats yet. Open Gaia to start one.'
                  : 'No chats yet. Start one, and it runs on your desktop.',
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
          ...rows(pinned),
          const SizedBox(height: 12),
        ],
        if (recent.isNotEmpty) ...[
          if (pinned.isNotEmpty) const _SectionLabel('Recent'),
          ...rows(recent),
        ],
      ],
    );
  }
}

/// The action log (§17): what Gaia saved, from which chat, with Undo. Undo
/// runs through this desktop's executor, so the phone shows the log alone.
class _ActionsTab extends ConsumerWidget {
  const _ActionsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final actions = ref.watch(gaiaActionsProvider).valueOrNull;
    if (actions == null) return const SizedBox.shrink();
    if (actions.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Text(
          "Nothing yet. What Gaia saves or does after you accept it shows here.",
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [for (final action in actions) _ActionRow(action: action)],
    );
  }
}

class _ActionRow extends StatefulWidget {
  const _ActionRow({required this.action});

  final GaiaAction action;

  @override
  State<_ActionRow> createState() => _ActionRowState();
}

class _ActionRowState extends State<_ActionRow> {
  var _undoing = false;

  Future<void> _undo() async {
    setState(() => _undoing = true);
    try {
      await GaiaHost.instance.undoProposal(
        widget.action.message,
        widget.action.card.id,
      );
    } on GaiaReadException catch (error) {
      if (mounted) {
        showVoyagerToast(context, message: "Couldn't undo: ${error.message}");
      }
    } finally {
      if (mounted) setState(() => _undoing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (:chat, :message, :card) = widget.action;
    // Input can't be taken back, so no Undo (§15.6). The chat has every step.
    if (card.kind == GaiaCardKind.control) {
      final steps = card.input['steps'] as List? ?? const [];
      final ran = (card.answer?['ran'] as num?)?.toInt() ?? 0;
      return ListTile(
        contentPadding: EdgeInsets.zero,
        leading: const Icon(PhosphorIconsRegular.cursorClick, size: 20),
        title: Text(
          gaiaIsActivity(card)
              ? 'Auto: ${card.input['total'] ?? ran} actions'
                    "${card.input['app'] == null ? '' : ' in ${card.input['app']}'}"
              : 'Ran $ran of ${steps.length} '
                    "${steps.length == 1 ? 'step' : 'steps'} "
                    "in ${card.input['app'] ?? 'a window'}",
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          [
            chat.title,
            DateFormat.yMMMd().add_Hm().format(message.createdAt.toLocal()),
            if (gaiaControlStopped(card)) 'stopped',
          ].join(' · '),
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall,
        ),
      );
    }
    final proposal = card.proposal!;
    final fields =
        (card.answer?['fields'] as Map?)?.cast<String, Object?>() ??
        proposal.fields;
    final undone = card.answer?['undoneAt'] != null;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(switch (proposal.entity) {
        GaiaProposalEntity.todo => PhosphorIconsRegular.checkSquare,
        GaiaProposalEntity.event => PhosphorIconsRegular.calendarBlank,
        GaiaProposalEntity.journal => PhosphorIconsRegular.notebook,
      }, size: 20),
      title: Text(
        gaiaProposalTitle(proposal, fields),
        overflow: TextOverflow.ellipsis,
        style: undone
            ? const TextStyle(decoration: TextDecoration.lineThrough)
            : null,
      ),
      subtitle: Text(
        [
          chat.title,
          DateFormat.yMMMd().add_Hm().format(message.createdAt.toLocal()),
          if (undone) 'undone',
        ].join(' · '),
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall,
      ),
      trailing: isWindows && !undone
          ? GlassButton(
              onPressed: _undoing ? null : _undo,
              icon: const Icon(PhosphorIconsRegular.arrowCounterClockwise),
              label: 'Undo',
              dense: true,
            )
          : null,
    );
  }
}

/// Gaia's memories (§11, §17): the inbox of proposed ones to approve, edit
/// or dismiss, the active ones every new chat's index lists, and the
/// archived ones kept out of it.
class _MemoriesTab extends ConsumerWidget {
  const _MemoriesTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final memories = ref.watch(gaiaMemoriesProvider).valueOrNull;
    final settings = ref.watch(gaiaSettingsProvider).valueOrNull;
    if (memories == null || settings == null) return const SizedBox.shrink();
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    List<GaiaMemory> withStatus(GaiaMemoryStatus status) => [
      for (final memory in memories.reversed)
        if (memory.status == status) memory,
    ];
    final inbox = withStatus(GaiaMemoryStatus.proposed);
    final active = withStatus(GaiaMemoryStatus.active);
    final archived = withStatus(GaiaMemoryStatus.archived);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Every new chat starts with a list of these, whichever agent '
          'answers. Save one yourself with /remember in Gaia. What Gaia '
          'offers, or notices once a chat goes quiet, waits in the inbox.',
          style: muted,
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Keep what Gaia notices without asking'),
          subtitle: const Text(
            'What Gaia picks out of a chat once it goes quiet skips the '
            'inbox. What an agent offers mid-chat still waits for you.',
          ),
          value: settings.autoAcceptCurator,
          onChanged: (value) => ref
              .read(gaiaRepositoryProvider)
              .upsertSettings(settings.copyWith(autoAcceptCurator: value)),
        ),
        const SizedBox(height: 8),
        if (inbox.isNotEmpty) ...[
          _SectionLabel('Inbox (${inbox.length})'),
          for (final memory in inbox) _MemoryRow(memory: memory),
          const SizedBox(height: 16),
        ],
        _SectionLabel(
          active.isEmpty ? 'Remembered' : 'Remembered (${active.length})',
        ),
        if (active.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text('Nothing yet.', style: muted),
          ),
        for (final memory in active) _MemoryRow(memory: memory),
        if (archived.isNotEmpty) ...[
          const SizedBox(height: 16),
          _SectionLabel('Archived (${archived.length})'),
          for (final memory in archived) _MemoryRow(memory: memory),
        ],
      ],
    );
  }
}

class _MemoryRow extends ConsumerWidget {
  const _MemoryRow({required this.memory});

  final GaiaMemory memory;

  Future<void> _save(WidgetRef ref, GaiaMemory memory) =>
      ref.read(gaiaRepositoryProvider).upsertMemory(memory);

  Future<void> _edit(BuildContext context, WidgetRef ref) async {
    final edited = await showDialog<({String text, List<String> tags})>(
      context: context,
      builder: (_) => _MemoryDialog(memory: memory),
    );
    if (edited == null) return;
    await _save(ref, memory.copyWith(text: edited.text, tags: edited.tags));
  }

  Future<void> _delete(BuildContext context) async {
    final overlay = Overlay.of(context, rootOverlay: true);
    final container = ProviderScope.containerOf(context, listen: false);
    final repository = container.read(gaiaRepositoryProvider);
    final proposed = memory.status == GaiaMemoryStatus.proposed;
    await softDeleteWithUndo(
      overlay: overlay,
      message: proposed
          ? 'Dismissed'
          : deletedMessage(memory.text, fallback: 'memory'),
      delete: () =>
          repository.upsertMemory(memory.copyWith(deletedAt: utcNow())),
      restore: () async {
        final current = await repository.getMemory(memory.id);
        if (current == null) return;
        await repository.upsertMemory(current.copyWith(clearDeletedAt: true));
      },
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final source = memory.sourceChatId == null
        ? null
        : (ref.watch(gaiaChatsProvider).valueOrNull ?? const [])
              .where((chat) => chat.id == memory.sourceChatId)
              .firstOrNull;
    final (icon, label, onPressed) = switch (memory.status) {
      GaiaMemoryStatus.proposed => (
        PhosphorIconsRegular.check,
        'Remember',
        () => _save(ref, memory.copyWith(status: GaiaMemoryStatus.active)),
      ),
      GaiaMemoryStatus.active => (
        PhosphorIconsRegular.archive,
        'Archive',
        () => _save(ref, memory.copyWith(status: GaiaMemoryStatus.archived)),
      ),
      GaiaMemoryStatus.archived => (
        PhosphorIconsRegular.arrowCounterClockwise,
        'Remember again',
        () => _save(ref, memory.copyWith(status: GaiaMemoryStatus.active)),
      ),
    };
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(memory.text),
      subtitle: Text(
        [
          if (memory.tags.isNotEmpty) memory.tags.map((t) => '#$t').join(' '),
          ?source?.title,
          DateFormat.yMMMd().format(memory.createdAt.toLocal()),
        ].join(' · '),
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall,
      ),
      onTap: () => _edit(context, ref),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: label,
            icon: Icon(icon, size: 16),
            onPressed: onPressed,
          ),
          IconButton(
            tooltip: memory.status == GaiaMemoryStatus.proposed
                ? 'Dismiss'
                : 'Delete',
            icon: Icon(
              memory.status == GaiaMemoryStatus.proposed
                  ? PhosphorIconsRegular.x
                  : PhosphorIconsRegular.trash,
              size: 16,
            ),
            onPressed: () => _delete(context),
          ),
        ],
      ),
    );
  }
}

class _MemoryDialog extends StatefulWidget {
  const _MemoryDialog({required this.memory});

  final GaiaMemory memory;

  @override
  State<_MemoryDialog> createState() => _MemoryDialogState();
}

class _MemoryDialogState extends State<_MemoryDialog> {
  late final _text = TextEditingController(text: widget.memory.text);
  late final _tags = TextEditingController(text: widget.memory.tags.join(', '));

  @override
  void dispose() {
    _text.dispose();
    _tags.dispose();
    super.dispose();
  }

  bool get _valid {
    final text = _text.text.trim();
    return text.isNotEmpty && text.length <= kGaiaMemoryMaxLength;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Edit memory'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            VoyagerTextField(
              controller: _text,
              minLines: 2,
              maxLines: 6,
              maxLength: kGaiaMemoryMaxLength,
              decoration: const InputDecoration(labelText: 'Memory'),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 8),
            VoyagerTextField(
              controller: _tags,
              decoration: const InputDecoration(
                labelText: 'Tags',
                hintText: 'Separated by commas',
              ),
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
              ? () => Navigator.of(context).pop((
                  text: _text.text.trim(),
                  tags: gaiaMemoryTags(_tags.text.split(',')),
                ))
              : null,
          label: 'Save',
          dense: true,
        ),
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

/// A fork's row, in under its original chat, with the line down from it:
/// on through the row, or for the [last], turning into it.
class _ForkLine extends StatelessWidget {
  const _ForkLine({required this.last, required this.child});

  final bool last;
  final Widget child;

  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: _ForkLinePainter(
      last: last,
      color: Theme.of(context).colorScheme.outlineVariant,
    ),
    child: Padding(padding: const EdgeInsets.only(left: 22), child: child),
  );
}

class _ForkLinePainter extends CustomPainter {
  const _ForkLinePainter({required this.last, required this.color});

  final bool last;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    const x = 6.0;
    const radius = 6.0;
    final y = size.height / 2;
    canvas.drawPath(
      last
          ? (Path()
              ..moveTo(x, 0)
              ..lineTo(x, y - radius)
              ..quadraticBezierTo(x, y, x + radius, y)
              ..lineTo(18, y))
          : (Path()
              ..moveTo(x, 0)
              ..lineTo(x, size.height)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(_ForkLinePainter oldDelegate) =>
      oldDelegate.last != last || oldDelegate.color != color;
}

class _ChatRow extends ConsumerWidget {
  const _ChatRow({
    required this.chat,
    required this.running,
    this.open,
    this.onFold,
  });

  final GaiaChat chat;
  final bool running;

  /// Whether the chat's forks show under it; null when it has none.
  final bool? open;
  final VoidCallback? onFold;

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final overlay = Overlay.of(context, rootOverlay: true);
    final container = ProviderScope.containerOf(context, listen: false);
    final id = chat.id;
    final media = container.read(mediaServiceProvider);
    // Its images go onto the chat's 30-day clock with it (GAIA_HLD.md §8).
    DateTime? mediaDeletedAt;
    await softDeleteWithUndo(
      overlay: overlay,
      message: deletedMessage(chat.title, fallback: 'chat'),
      delete: () async {
        await container.read(gaiaRepositoryProvider).softDeleteChat(id);
        mediaDeletedAt = await media.removeReferencesForOwner(
          FirestoreCollections.gaiaChats,
          id,
        );
      },
      restore: () async {
        await container.read(gaiaRepositoryProvider).restoreChat(id);
        if (mediaDeletedAt case final at?) {
          await media.restoreReferencesForOwner(
            FirestoreCollections.gaiaChats,
            id,
            at,
          );
        }
      },
    );
  }

  void _open(BuildContext context) {
    if (isWindows) {
      GaiaHost.instance.openChat(chat.id);
    } else {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => GaiaRemoteChatPage(chatId: chat.id),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: open == null
          ? Text(chat.title, overflow: TextOverflow.ellipsis)
          : Row(
              children: [
                Flexible(
                  child: Text(chat.title, overflow: TextOverflow.ellipsis),
                ),
                IconButton(
                  tooltip: open! ? 'Hide forks' : 'Show forks',
                  visualDensity: VisualDensity.compact,
                  icon: Icon(
                    open!
                        ? PhosphorIconsRegular.caretDown
                        : PhosphorIconsRegular.caretRight,
                    size: 14,
                  ),
                  onPressed: onFold,
                ),
              ],
            ),
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
              child: GaiaSpinner(size: 20, label: 'Running'),
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
                  : () => ref
                      ..invalidate(gaiaClaudeSetupProvider)
                      ..invalidate(gaiaClaudeAccountProvider),
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
        if (setup.valueOrNull?.installed ?? false)
          const _Accounts(adapter: kGaiaClaudeCodeAdapter),
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
                  : () => ref
                      ..invalidate(gaiaCodexSetupProvider)
                      ..invalidate(gaiaCodexAccountProvider),
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
        if (setup.valueOrNull?.installed ?? false)
          const _Accounts(adapter: kGaiaCodexAdapter),
      ],
    );
  }
}

/// An adapter's accounts in order (§6.1), the first being the default, each
/// with its login and usage. Switching between them is the composer's (§6.5).
class _Accounts extends ConsumerWidget {
  const _Accounts({required this.adapter});

  final String adapter;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(gaiaSettingsProvider).valueOrNull;
    if (settings == null) return const SizedBox.shrink();
    final accounts = settings.accountsFor(adapter);
    Future<void> save(List<GaiaAccount> list) => ref
        .read(gaiaRepositoryProvider)
        .upsertSettings(
          settings.copyWith(
            accounts: [
              for (final account in settings.accounts)
                if (account.adapter != adapter) account,
              ...list,
            ],
          ),
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (index, account) in accounts.indexed)
          _AccountRow(
            key: ValueKey(account.id),
            account: account,
            several: accounts.length > 1,
            // Every adapter's accounts share the composer's `/` palette.
            takenAliases: {
              ..._reservedCommandNames,
              for (final command in settings.commands) command.name,
              for (final other in settings.accounts)
                if (other.id != account.id || other.adapter != adapter)
                  other.alias,
            },
            onSave: (label, alias) => save([
              for (final other in accounts)
                other == account
                    ? other.copyWith(label: label, alias: alias)
                    : other,
            ]),
            onUp: index == 0
                ? null
                : () => save(
                    [...accounts]
                      ..removeAt(index)
                      ..insert(index - 1, account),
                  ),
            onDown: index == accounts.length - 1
                ? null
                : () => save(
                    [...accounts]
                      ..removeAt(index)
                      ..insert(index + 1, account),
                  ),
            onRemove: accounts.length == 1
                ? null
                : () => save([...accounts]..removeAt(index)),
          ),
        const SizedBox(height: 12),
        _AddAccount(
          adapter: adapter,
          onAdd: (label, dir) => save([
            ...accounts,
            GaiaAccount(
              id: const Uuid().v4(),
              label: label,
              adapter: adapter,
              dir: dir,
            ),
          ]),
          taken: {for (final account in accounts) account.dir},
        ),
      ],
    );
  }
}

class _AccountRow extends ConsumerStatefulWidget {
  const _AccountRow({
    super.key,
    required this.account,
    required this.several,
    required this.takenAliases,
    required this.onSave,
    required this.onUp,
    required this.onDown,
    required this.onRemove,
  });

  final GaiaAccount account;
  final bool several;

  /// Names its alias can't take.
  final Set<String> takenAliases;
  final void Function(String label, String alias) onSave;
  final VoidCallback? onUp;
  final VoidCallback? onDown;
  final VoidCallback? onRemove;

  @override
  ConsumerState<_AccountRow> createState() => _AccountRowState();
}

class _AccountRowState extends ConsumerState<_AccountRow> {
  late final _label = TextEditingController(text: widget.account.label);
  late final _alias = TextEditingController(text: widget.account.alias);

  @override
  void didUpdateWidget(_AccountRow old) {
    super.didUpdateWidget(old);
    // Renamed on another device, while nothing here is unsaved.
    if (_label.text == old.account.label) _label.text = widget.account.label;
    if (_alias.text == old.account.alias) _alias.text = widget.account.alias;
  }

  @override
  void dispose() {
    _label.dispose();
    _alias.dispose();
    super.dispose();
  }

  String? get _aliasError {
    final alias = _alias.text.trim();
    if (alias.isEmpty) return null;
    if (!RegExp(r'^[\w-]+$').hasMatch(alias)) {
      return 'Letters, digits, - and _ only';
    }
    if (widget.takenAliases.contains(alias)) return 'Already a command';
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final account = widget.account;
    final label = _label.text.trim();
    final alias = _alias.text.trim();
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              SizedBox(
                width: 160,
                child: VoyagerTextField(
                  controller: _label,
                  decoration: const InputDecoration(
                    labelText: 'Account',
                    isDense: true,
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 150,
                child: VoyagerTextField(
                  controller: _alias,
                  decoration: InputDecoration(
                    labelText: 'Alias',
                    prefixText: '/',
                    isDense: true,
                    errorText: _aliasError,
                    errorMaxLines: 2,
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              if (label.isNotEmpty &&
                  _aliasError == null &&
                  (label != account.label || alias != account.alias)) ...[
                const SizedBox(width: 8),
                GlassButton(
                  onPressed: () => widget.onSave(label, alias),
                  label: 'Save',
                  dense: true,
                ),
              ],
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  account.dir.isEmpty
                      ? 'The folder Voyager was started with'
                      : account.dir,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (widget.several) ...[
                IconButton(
                  tooltip: 'Move up',
                  onPressed: widget.onUp,
                  icon: const Icon(PhosphorIconsRegular.arrowUp, size: 14),
                ),
                IconButton(
                  tooltip: 'Move down',
                  onPressed: widget.onDown,
                  icon: const Icon(PhosphorIconsRegular.arrowDown, size: 14),
                ),
                IconButton(
                  tooltip: 'Remove',
                  onPressed: widget.onRemove,
                  icon: const Icon(PhosphorIconsRegular.trash, size: 14),
                ),
              ],
            ],
          ),
          if (account.adapter == kGaiaCodexAdapter)
            _CodexAccountChecks(account: account)
          else
            _ClaudeAccountChecks(account: account),
          GaiaUsageRow(account: account),
        ],
      ),
    );
  }
}

/// A login's check, once there's an answer: a CLI that hasn't said shouldn't
/// hold the page up.
class _ClaudeAccountChecks extends ConsumerWidget {
  const _ClaudeAccountChecks({required this.account});

  final GaiaAccount account;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(gaiaClaudeAccountProvider(account.dir)).valueOrNull;
    if (value == null) return const SizedBox.shrink();
    return _CheckRow(
      ok: value.loggedIn == true,
      label: switch (value.loggedIn) {
        true => 'Logged in${value.email == null ? '' : ' as ${value.email}'}',
        false => 'Not logged in',
        null => "Couldn't read the login status",
      },
      fix: value.loggedIn == true
          ? null
          : account.dir.isEmpty
          ? 'claude auth login'
          : '\$env:CLAUDE_CONFIG_DIR="${account.dir}"; claude auth login',
    );
  }
}

class _CodexAccountChecks extends ConsumerWidget {
  const _CodexAccountChecks({required this.account});

  final GaiaAccount account;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(gaiaCodexAccountProvider(account)).valueOrNull;
    if (value == null) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _CheckRow(
          ok: value.loggedIn == true,
          label: switch (value.loggedIn) {
            true => 'Logged in',
            false => 'Not logged in',
            null => "Couldn't read the login status",
          },
          fix: value.loggedIn == true
              ? null
              : account.dir.isEmpty
              ? 'codex login'
              : '\$env:CODEX_HOME="${account.dir}"; codex login',
        ),
        if (value.sandboxReady case final ready?)
          _CheckRow(
            ok: ready,
            label: ready
                ? 'Sandbox set up for Gaia'
                : "Codex's Windows sandbox needs setting up once for this "
                      'account. Windows will ask you to approve it.',
            action: ready
                ? null
                : GlassButton(
                    onPressed: () async {
                      await setUpCodexSandbox(
                        codexHome: p.join(
                          await gaiaCodexHomesRoot(),
                          account.id,
                        ),
                        loginHome: codexLoginHome(account),
                      );
                      ref.invalidate(gaiaCodexAccountProvider(account));
                    },
                    label: 'Set up',
                    dense: true,
                  ),
          ),
      ],
    );
  }
}

/// A new account's name and folder (§6.1). A folder is fixed once it's added:
/// its sessions, and a Codex account's home, belong to that login.
class _AddAccount extends StatefulWidget {
  const _AddAccount({
    required this.adapter,
    required this.onAdd,
    required this.taken,
  });

  final String adapter;
  final void Function(String label, String dir) onAdd;
  final Set<String> taken;

  @override
  State<_AddAccount> createState() => _AddAccountState();
}

class _AddAccountState extends State<_AddAccount> {
  final _label = TextEditingController();
  final _dir = TextEditingController();

  @override
  void dispose() {
    _label.dispose();
    _dir.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final codex = widget.adapter == kGaiaCodexAdapter;
    final label = _label.text.trim();
    // Explorer's "Copy as path" wraps the path in quotes, which can't be part
    // of a Windows path.
    final dir = _dir.text.replaceAll('"', '').trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            SizedBox(
              width: 160,
              child: VoyagerTextField(
                controller: _label,
                decoration: const InputDecoration(
                  labelText: 'New account',
                  hintText: 'e.g. Work',
                  isDense: true,
                ),
                onChanged: (_) => setState(() {}),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: VoyagerTextField(
                controller: _dir,
                decoration: InputDecoration(
                  labelText: 'Folder',
                  hintText: codex
                      ? r'e.g. C:\Users\you\.codex-2'
                      : r'e.g. C:\Users\you\.claude-2',
                  isDense: true,
                ),
                onChanged: (_) => setState(() {}),
              ),
            ),
            const SizedBox(width: 8),
            GlassButton(
              onPressed:
                  label.isEmpty || dir.isEmpty || widget.taken.contains(dir)
                  ? null
                  : () {
                      widget.onAdd(label, dir);
                      _label.clear();
                      _dir.clear();
                      setState(() {});
                    },
              label: 'Add',
              dense: true,
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          codex
              ? 'A folder is a CODEX_HOME holding a login, which Gaia copies '
                    'into a Codex home of its own. The first account is the '
                    'default. Synced to all your devices.'
              : "A folder is a CLAUDE_CONFIG_DIR, used on Gaia's runs only. "
                    'The first account is the default. Synced to all your '
                    'devices.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

/// An account's usage (§6.4): its bars, or what's wrong with reading them.
class GaiaUsageRow extends ConsumerWidget {
  const GaiaUsageRow({super.key, required this.account});

  final GaiaAccount account;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // A login check that finds a login outdates the last usage read's signed
    // out, which would otherwise stand until the next one (§6.4). Either can
    // come first.
    void recheck(AsyncValue<bool?> login) {
      if (!login.isLoading &&
          login.valueOrNull == true &&
          ref.read(gaiaUsageProvider)[account.key]?.health ==
              GaiaUsageHealth.signedOut) {
        ref.read(gaiaRecheckUsageProvider)(account.key);
      }
    }

    ref.listen(
      gaiaUsageProvider.select((usage) => usage[account.key]?.health),
      (_, _) => recheck(
        account.adapter == kGaiaCodexAdapter
            ? ref
                  .read(gaiaCodexAccountProvider(account))
                  .whenData((setup) => setup.loggedIn)
            : ref
                  .read(gaiaClaudeAccountProvider(account.dir))
                  .whenData((setup) => setup.loggedIn),
      ),
    );
    final read = ref.watch(gaiaUsageProvider)[account.key];
    if (read == null) return const SizedBox.shrink();
    final health = read.health;
    if (account.adapter == kGaiaCodexAdapter) {
      ref.listen(
        gaiaCodexAccountProvider(account),
        (_, next) => recheck(next.whenData((setup) => setup.loggedIn)),
      );
    } else {
      ref.listen(
        gaiaClaudeAccountProvider(account.dir),
        (_, next) => recheck(next.whenData((setup) => setup.loggedIn)),
      );
    }
    // The login check above already says so, with the command to fix it.
    final loggedIn = account.adapter == kGaiaCodexAdapter
        ? ref.watch(gaiaCodexAccountProvider(account)).valueOrNull?.loggedIn
        : ref
              .watch(gaiaClaudeAccountProvider(account.dir))
              .valueOrNull
              ?.loggedIn;
    if (health == GaiaUsageHealth.signedOut && loggedIn == false) {
      return const SizedBox.shrink();
    }
    if (health != null && health != GaiaUsageHealth.ok) {
      return _CheckRow(
        ok: false,
        warnOnly: true,
        label: gaiaUsageMessage(
          account.adapter,
          health,
          read.checkedAt,
          account: account,
        ),
      );
    }
    final usage = read.usage;
    if (usage == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Wrap(spacing: 20, runSpacing: 10, children: gaiaUsageBars(usage)),
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
                              fontFamily: AppFonts.monoFamily,
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
        const SizedBox(height: 24),
        _CommandsSection(settings: settings),
        if (isWindows) ...[
          const SizedBox(height: 24),
          _KeysSection(settings: settings),
        ],
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
          _ContextSection(settings: settings),
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

/// Focused-window context (§15.4): whether each message says which window
/// Gaia was opened from, and the apps and sites it never reads.
class _ContextSection extends ConsumerStatefulWidget {
  const _ContextSection({required this.settings});

  final GaiaSettings settings;

  @override
  ConsumerState<_ContextSection> createState() => _ContextSectionState();
}

class _ContextSectionState extends ConsumerState<_ContextSection> {
  final _exclusions = TextEditingController();

  /// The list as last loaded or saved, one per line.
  String? _saved;

  static String _lines(List<String> entries) => entries.join('\n');

  @override
  void dispose() {
    _exclusions.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final text = _exclusions.text;
    await ref
        .read(gaiaRepositoryProvider)
        .upsertSettings(
          widget.settings.copyWith(
            contextExclusions: [
              for (final line in text.split('\n'))
                if (line.trim().isNotEmpty) line.trim(),
            ],
          ),
        );
    setState(() => _saved = text);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final settings = widget.settings;
    final stored = _lines(settings.contextExclusions);
    // As GAIA.md's: reloaded when it changes elsewhere with nothing unsaved.
    if (_saved == null || (_exclusions.text == _saved && _saved != stored)) {
      _saved = stored;
      _exclusions.text = stored;
    }
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Say which window Gaia was opened from'),
          subtitle: const Text(
            "Each message carries the app, window title and, in a browser, "
            'the address you were on. It shows on the draft, where you can '
            'remove it.',
          ),
          value: settings.windowContext,
          onChanged: (value) => ref
              .read(gaiaRepositoryProvider)
              .upsertSettings(settings.copyWith(windowContext: value)),
        ),
        const SizedBox(height: 4),
        Text('Never read', style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        Text(
          "Apps and sites Gaia doesn't describe or read a selection from, "
          'one per line: an app or its exe name, or a site like rbc.com.',
          style: muted,
        ),
        const SizedBox(height: 8),
        VoyagerTextField(
          controller: _exclusions,
          minLines: 3,
          maxLines: 8,
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerRight,
          child: GlassButton(
            onPressed: _exclusions.text != _saved ? _save : null,
            label: 'Save',
            dense: true,
          ),
        ),
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

/// The utility model (§5.1): the model, and the router (§7.2) it powers.
class _UtilitySection extends ConsumerStatefulWidget {
  const _UtilitySection({required this.settings});

  final GaiaSettings settings;

  @override
  ConsumerState<_UtilitySection> createState() => _UtilitySectionState();
}

class _UtilitySectionState extends ConsumerState<_UtilitySection> {
  final _model = TextEditingController();
  final _rubric = TextEditingController();
  String? _savedModel;
  String? _savedRubric;

  @override
  void dispose() {
    _model.dispose();
    _rubric.dispose();
    super.dispose();
  }

  Future<void> _save(GaiaSettings updated) =>
      ref.read(gaiaRepositoryProvider).upsertSettings(updated);

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
    final dirty =
        _model.text.trim() != _savedModel || _rubric.text != _savedRubric;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Utility model', style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          'A fast Claude model on Claude Code, on the same login as your '
          'chats: it picks the tier for a new chat, writes chat titles and '
          'sums up a chat for another agent. No API key needed.',
          style: muted,
        ),
        const SizedBox(height: 8),
        VoyagerTextField(
          controller: _model,
          decoration: const InputDecoration(
            labelText: 'Model',
            hintText: kGaiaDefaultUtilityModel,
            isDense: true,
          ),
          onChanged: (_) => setState(() {}),
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
        Row(
          children: [
            const Expanded(child: Text('Default tier')),
            DropdownButton<GaiaTier?>(
              value: settings.defaultTier,
              hint: const Text('Last used'),
              items: [
                const DropdownMenuItem(child: Text('Last used')),
                for (final tier in GaiaTier.values)
                  DropdownMenuItem(value: tier, child: Text(tier.label)),
              ],
              onChanged: (tier) => _save(
                tier == null
                    ? settings.copyWith(clearDefaultTier: true)
                    : settings.copyWith(defaultTier: tier),
              ),
            ),
          ],
        ),
        Text(
          'A new chat starts on it when the router is off or fails, and the '
          'router picks it when unsure.',
          style: muted,
        ),
        const SizedBox(height: 8),
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

/// Names Gaia's own commands take (§9.2), which a user command can't.
final _reservedCommandNames = {
  for (final builtin in GaiaBuiltin.values) builtin.name,
  for (final tier in GaiaTier.values) tier.command.substring(1),
};

/// The user's slash commands (§9.2): templates `/name args` expands to on
/// send.
class _CommandsSection extends ConsumerWidget {
  const _CommandsSection({required this.settings});

  final GaiaSettings settings;

  Future<void> _edit(
    BuildContext context,
    WidgetRef ref, [
    GaiaCommand? command,
  ]) async {
    final edited = await showDialog<GaiaCommand>(
      context: context,
      builder: (_) => _CommandDialog(
        command: command,
        taken: {
          ..._reservedCommandNames,
          for (final account in settings.accounts) account.alias,
          for (final c in settings.commands)
            if (c.name != command?.name) c.name,
        },
      ),
    );
    if (edited == null) return;
    await ref
        .read(gaiaRepositoryProvider)
        .upsertSettings(
          settings.copyWith(
            commands: command == null
                ? [...settings.commands, edited]
                : [
                    for (final c in settings.commands)
                      c.name == command.name ? edited : c,
                  ],
          ),
        );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text('Commands', style: theme.textTheme.titleMedium),
            const Spacer(),
            GlassButton(
              onPressed: () => _edit(context, ref),
              icon: const Icon(PhosphorIconsRegular.plus, size: 13),
              label: 'Add command',
              dense: true,
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          r'Type /name in Gaia, then anything after it: it becomes the '
          r'template, with $ARGUMENTS (what you typed after the name), $1 to '
          r'$9 (its words), $CLIPBOARD, $SELECTION (the text selected '
          r'where you opened Gaia) and $DATE filled in.',
          style: muted,
        ),
        for (final command in settings.commands)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text('/${command.name}'),
            subtitle: Text(
              command.description.isEmpty
                  ? command.template.split('\n').first
                  : command.description,
              style: muted,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            onTap: () => _edit(context, ref, command),
            trailing: IconButton(
              tooltip: 'Remove',
              icon: const Icon(PhosphorIconsRegular.trash, size: 16),
              onPressed: () => ref
                  .read(gaiaRepositoryProvider)
                  .upsertSettings(
                    settings.copyWith(
                      commands: [
                        for (final c in settings.commands)
                          if (c.name != command.name) c,
                      ],
                    ),
                  ),
            ),
          ),
      ],
    );
  }
}

class _CommandDialog extends StatefulWidget {
  const _CommandDialog({required this.command, required this.taken});

  /// Null for a new one.
  final GaiaCommand? command;

  /// Names already in use.
  final Set<String> taken;

  @override
  State<_CommandDialog> createState() => _CommandDialogState();
}

class _CommandDialogState extends State<_CommandDialog> {
  late final _name = TextEditingController(text: widget.command?.name);
  late final _description = TextEditingController(
    text: widget.command?.description,
  );
  late final _template = TextEditingController(text: widget.command?.template);
  late var _standalone = widget.command?.standalone ?? false;

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    _template.dispose();
    super.dispose();
  }

  String? get _nameError {
    final name = _name.text.trim();
    if (name.isEmpty) return null;
    if (!RegExp(r'^[\w-]+$').hasMatch(name)) {
      return 'Letters, digits, - and _ only';
    }
    if (widget.taken.contains(name)) return 'Already a command';
    return null;
  }

  bool get _valid =>
      _name.text.trim().isNotEmpty &&
      _nameError == null &&
      _template.text.trim().isNotEmpty;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.command == null ? 'Add command' : 'Edit command'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            VoyagerTextField(
              controller: _name,
              decoration: InputDecoration(
                labelText: 'Name',
                prefixText: '/',
                errorText: _nameError,
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 8),
            VoyagerTextField(
              controller: _description,
              decoration: const InputDecoration(
                labelText: 'Description (optional)',
              ),
            ),
            const SizedBox(height: 8),
            VoyagerTextField(
              controller: _template,
              minLines: 3,
              maxLines: 10,
              decoration: const InputDecoration(
                labelText: 'Template',
                hintText: r'e.g. Explain this in plain words: $ARGUMENTS',
              ),
              onChanged: (_) => setState(() {}),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _standalone,
              title: const Text('Send as soon as it is picked'),
              subtitle: const Text('For a command that takes no arguments.'),
              onChanged: (value) => setState(() => _standalone = value!),
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
                  GaiaCommand(
                    name: _name.text.trim(),
                    template: _template.text,
                    description: _description.text.trim(),
                    standalone: _standalone,
                  ),
                )
              : null,
          label: 'Save',
          dense: true,
        ),
      ],
    );
  }
}

/// Gaia's rebindable keys (§9.1, §15.1): send, and the global hotkeys.
class _KeysSection extends ConsumerWidget {
  const _KeysSection({required this.settings});

  final GaiaSettings settings;

  Future<void> _save(WidgetRef ref, Map<String, String> keybinds) => ref
      .read(gaiaRepositoryProvider)
      .upsertSettings(settings.copyWith(keybinds: keybinds));

  Future<void> _change(
    BuildContext context,
    WidgetRef ref,
    GaiaKeybind keybind,
  ) async {
    final combo = await showDialog<GaiaCombo>(
      context: context,
      builder: (_) => _ComboDialog(keybind: keybind),
    );
    if (combo == null || !context.mounted) return;
    final stored = '$combo';
    final clash = GaiaKeybind.values
        .where(
          (other) =>
              other != keybind &&
              other.global == keybind.global &&
              gaiaComboFor(other, settings.keybinds) == stored,
        )
        .firstOrNull;
    if (clash != null) {
      showVoyagerToast(context, message: '$stored is already ${clash.label}');
      return;
    }
    // Send only works inside Gaia, so it can't take a system-wide hotkey.
    final voyager = ref.read(settingsProvider).valueOrNull;
    final voyagerClash = !keybind.global || voyager == null
        ? null
        : gaiaHotkeyClash(stored, {
            'Quick journal entry': voyager.journalHotkey,
            'Quick to-do': voyager.todoHotkey,
            'Quick transaction': voyager.financeHotkey,
            'Quick reminder': voyager.reminderHotkey,
            'Quick event': voyager.calendarHotkey,
          });
    if (voyagerClash != null) {
      showVoyagerToast(context, message: '$stored is already $voyagerClash');
      return;
    }
    await _save(ref, {...settings.keybinds, keybind.name: stored});
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Keys', style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          'Send works in Gaia. The others work from any app; they need Ctrl, '
          'Alt or Win so they never take over plain typing.',
          style: muted,
        ),
        for (final keybind in GaiaKeybind.values)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(keybind.label),
            subtitle: Text(switch (gaiaComboFor(keybind, settings.keybinds)) {
              '' => 'Not set',
              final combo => combo,
            }, style: muted),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (settings.keybinds.containsKey(keybind.name))
                  IconButton(
                    tooltip: keybind.defaultCombo.isEmpty
                        ? 'Clear'
                        : 'Reset to ${keybind.defaultCombo}',
                    icon: const Icon(
                      PhosphorIconsRegular.arrowCounterClockwise,
                      size: 16,
                    ),
                    onPressed: () => _save(ref, {
                      for (final MapEntry(:key, :value)
                          in settings.keybinds.entries)
                        if (key != keybind.name) key: value,
                    }),
                  ),
                GlassButton(
                  onPressed: () => _change(context, ref, keybind),
                  label: 'Change',
                  dense: true,
                ),
              ],
            ),
          ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Put Gaia on the right in a split'),
          subtitle: const Text(
            'Split the screen with Gaia puts the other window on the left. '
            'Off, Gaia goes on the left and the other window on the right.',
          ),
          value: settings.splitGaiaRight,
          onChanged: (value) => ref
              .read(gaiaRepositoryProvider)
              .upsertSettings(settings.copyWith(splitGaiaRight: value)),
        ),
      ],
    );
  }
}

/// Waits for a key combo: the key pressed with the modifiers held. Esc on
/// its own cancels.
class _ComboDialog extends StatefulWidget {
  const _ComboDialog({required this.keybind});

  final GaiaKeybind keybind;

  @override
  State<_ComboDialog> createState() => _ComboDialogState();
}

class _ComboDialogState extends State<_ComboDialog> {
  String? _refused;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    super.dispose();
  }

  bool _onKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    final keyboard = HardwareKeyboard.instance;
    if (event.logicalKey == LogicalKeyboardKey.escape &&
        !keyboard.isControlPressed &&
        !keyboard.isAltPressed &&
        !keyboard.isShiftPressed) {
      Navigator.of(context).pop();
      return true;
    }
    final combo = gaiaComboFromEvent(event);
    if (combo == null) return false;
    if (widget.keybind.global && !combo.hasModifier) {
      setState(() => _refused = '$combo needs Ctrl, Alt or Win with it.');
      return true;
    }
    Navigator.of(context).pop(combo);
    return true;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.keybind.label),
      content: Text(
        _refused ??
            'Press the keys for ${widget.keybind.label}: a letter, digit, '
                'F-key, Space, Enter or Backspace, with any modifiers.\n'
                'Esc to cancel.',
      ),
    );
  }
}
