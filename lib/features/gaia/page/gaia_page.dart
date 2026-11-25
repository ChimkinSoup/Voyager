import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:uuid/uuid.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/platform/platform_info.dart';
import 'package:voyager/core/soft_delete/soft_delete_toast.dart';
import 'package:voyager/core/sync/firestore_collections.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/core/widgets/confirm_dialog.dart';
import 'package:voyager/core/widgets/context_menu.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/prompt_name_dialog.dart';
import 'package:voyager/core/widgets/voyager_text_field.dart';
import 'package:voyager/core/widgets/voyager_toast.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/domain/repositories/repositories.dart';
import 'package:voyager/features/gaia/companion/gaia_card_view.dart';
import 'package:voyager/features/gaia/companion/gaia_commands.dart';
import 'package:voyager/features/gaia/companion/gaia_settings_panel.dart';
import 'package:voyager/features/gaia/companion/gaia_spinner.dart';
import 'package:voyager/features/gaia/host/gaia_chat_store.dart';
import 'package:voyager/features/gaia/host/gaia_host.dart';
import 'package:voyager/features/gaia/host/gaia_memories.dart';
import 'package:voyager/features/gaia/host/gaia_voyager_reads.dart';
import 'package:voyager/features/gaia/page/gaia_providers.dart';
import 'package:voyager/features/gaia/page/gaia_remote_chat.dart';
import 'package:voyager/features/gaia/page/gaia_queue_tab.dart';
import 'package:voyager/features/gaia/page/gaia_status_tab.dart';
import 'package:voyager/features/gaia/tools/gaia_proposals.dart';

enum _GaiaTab { chats, actions, memories, queue, status, settings }

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

  /// The memory a recall chip asked to show (GAIA_MEMORY_TOPICS_HLD.md §4.5).
  String? _revealed;

  @override
  void initState() {
    super.initState();
    _reveal(ref.read(gaiaRevealMemoryProvider));
  }

  /// Memory [id] shown on the Memories tab; the request is taken, so the
  /// page doesn't open on it again.
  void _reveal(String? id) {
    if (id == null) return;
    _tab = _GaiaTab.memories;
    _revealed = id;
    Future.microtask(
      () => ref.read(gaiaRevealMemoryProvider.notifier).state = null,
    );
  }

  @override
  Widget build(BuildContext context) {
    // Everything here is in the Gaia window's settings panel on the desktop
    // (GAIA_SETTINGS_HLD.md §9); the phone keeps the full page.
    if (isWindows) return const _OpenInGaia();
    ref.listen(gaiaRevealMemoryProvider, (_, id) {
      if (id != null) setState(() => _reveal(id));
    });
    final theme = Theme.of(context);
    final inbox = [
      for (final memory
          in ref.watch(gaiaMemoriesProvider).valueOrNull ?? const [])
        if (memory.status == GaiaMemoryStatus.proposed) memory,
    ].length;
    return Material(
      type: MaterialType.transparency,
      // A centred column of at most [_pageWidth], on a wide window: a row's
      // actions stay within reach of its title rather than a screen away
      // from it. The rest still scrolls the list.
      child: LayoutBuilder(
        builder: (context, constraints) {
          final side = max(24.0, (constraints.maxWidth - _pageWidth) / 2);
          return ListView(
            padding: EdgeInsets.fromLTRB(side, 20, side, 24),
            children: [
              Text('Gaia', style: theme.textTheme.headlineSmall),
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
                      label: Text(
                        inbox == 0 ? 'Memories' : 'Memories ($inbox)',
                      ),
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
                _GaiaTab.memories => _MemoriesTab(focus: _revealed),
                _GaiaTab.queue => const GaiaQueueTab(),
                _GaiaTab.status => const GaiaStatusTab(),
                _GaiaTab.settings => const _SettingsTab(),
              },
            ],
          );
        },
      ),
    );
  }
}

/// The widest the page's content gets: room for all seven tabs in a row.
const _pageWidth = 1200.0;

/// The desktop's Gaia page (GAIA_SETTINGS_HLD.md §9): a way into the Gaia
/// window, and into its settings panel at each tab.
class _OpenInGaia extends StatelessWidget {
  const _OpenInGaia();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      type: MaterialType.transparency,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
        children: [
          Text('Gaia', style: theme.textTheme.headlineSmall),
          const SizedBox(height: 12),
          Text(
            "Gaia's chats, memories and settings are in the Gaia window. "
            'Its sidebar lists the chats, and the gear at its foot (Ctrl+,) '
            'opens the rest.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerLeft,
            child: GlassButton(
              onPressed: () => GaiaHost.instance.onHotkey(GaiaHotkey.window),
              icon: const Icon(PhosphorIconsRegular.planet, size: 13),
              label: 'Open in Gaia',
            ),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final tab in GaiaPanelTab.values)
                GlassButton(
                  onPressed: () => GaiaHost.instance.openPanel(tab.name),
                  icon: Icon(switch (tab) {
                    GaiaPanelTab.memories => PhosphorIconsRegular.brain,
                    GaiaPanelTab.actions => PhosphorIconsRegular.listChecks,
                    GaiaPanelTab.queue => PhosphorIconsRegular.queue,
                    GaiaPanelTab.status => PhosphorIconsRegular.broadcast,
                    GaiaPanelTab.setup => PhosphorIconsRegular.wrench,
                    GaiaPanelTab.settings => PhosphorIconsRegular.gear,
                  }, size: 13),
                  label: tab.label,
                  dense: true,
                ),
            ],
          ),
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

  /// Whether the Archived chats show; folded away to begin with.
  var _archivedOpen = false;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final chats = ref.watch(gaiaChatsProvider).valueOrNull ?? const [];
    final running = ref.watch(gaiaRunningChatsProvider);
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
    final projects = ref.watch(gaiaProjectsProvider).valueOrNull ?? const [];
    final closedProjects = ref.watch(gaiaClosedProjectsProvider);
    // Grouped by project (GAIA_PROJECTS_HLD.md §7.3). A search lists what it
    // found on its own, forks or projects or not.
    final sections = gaiaChatSections(shown, query.isEmpty ? projects : []);
    final listed = gaiaProjectsListed(chats, projects);
    List<GaiaForkGroup> found(bool pinned) => [
      for (final chat in shown)
        if (chat.pinned == pinned) (chat: chat, forks: const <GaiaChat>[]),
    ];
    final pinned = query.isEmpty ? sections.pinned : found(true);
    final recent = query.isEmpty ? sections.chats : found(false);
    List<Widget> rows(List<GaiaForkGroup> groups) => [
      for (final (:chat, :forks) in groups) ...[
        _ChatRow(
          chat: chat,
          projects: listed,
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
              child: _ChatRow(
                chat: fork,
                projects: listed,
                running: running.contains(fork.id),
              ),
            ),
      ],
    ];
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
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
            const SizedBox(width: 8),
            GlassButton(
              dense: true,
              label: 'New project',
              icon: const Icon(PhosphorIconsRegular.folderPlus, size: 13),
              onPressed: () => _newProject(context),
            ),
            // On the phone a chat starts here and runs on a desktop.
            const SizedBox(width: 8),
            GlassButton(
              dense: true,
              label: 'New chat',
              icon: const Icon(PhosphorIconsRegular.plus, size: 13),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => GaiaRemoteChatPage(chatId: const Uuid().v4()),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (chats.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Text(
              'No chats yet. Start one, and it runs on your desktop.',
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
        if (sections.projects.isNotEmpty) ...[
          const _SectionLabel('Projects'),
          for (final section in sections.projects) ...[
            _ProjectRow(
              section: section,
              open: !closedProjects.contains(section.project.id),
              onFold: () => ref
                  .read(gaiaClosedProjectsProvider.notifier)
                  .toggle(section.project.id),
              running: section.groups.any(
                (group) => [
                  group.chat,
                  ...group.forks,
                ].any((chat) => running.contains(chat.id)),
              ),
            ),
            if (!closedProjects.contains(section.project.id))
              Padding(
                padding: const EdgeInsets.only(left: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: rows(section.groups),
                ),
              ),
          ],
          const SizedBox(height: 12),
        ],
        if (recent.isNotEmpty) ...[
          if (pinned.isNotEmpty || sections.projects.isNotEmpty)
            const _SectionLabel('Chats'),
          ...rows(recent),
        ],
        // A search lists them with the rest.
        if (query.isEmpty && sections.archived.isNotEmpty) ...[
          const SizedBox(height: 12),
          Row(
            children: [
              const _SectionLabel('Archived'),
              IconButton(
                tooltip: _archivedOpen ? 'Hide archived' : 'Show archived',
                visualDensity: VisualDensity.compact,
                icon: Icon(
                  _archivedOpen
                      ? PhosphorIconsRegular.caretDown
                      : PhosphorIconsRegular.caretRight,
                  size: 14,
                ),
                onPressed: () => setState(() => _archivedOpen = !_archivedOpen),
              ),
            ],
          ),
          if (_archivedOpen) ...rows(sections.archived),
        ],
      ],
    );
  }
}

/// Asks for a project's name, [from] the one it has; null when cancelled.
Future<String?> _askProjectName(
  BuildContext context, {
  required String title,
  String from = '',
}) async => (await showPromptNameDialog(
  context,
  title: title,
  initial: from,
  contentWidth: 360,
  validate: (name) => name.trim().isEmpty ? 'It needs a name.' : null,
))?.trim();

/// A project made from the name asked for; gives back its id, or null when
/// cancelled.
Future<String?> _newProject(BuildContext context) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final name = await _askProjectName(context, title: 'New project');
  if (name == null) return null;
  final now = utcNow();
  final project = GaiaProject(
    id: const Uuid().v4(),
    name: name,
    createdAt: now,
    updatedAt: now,
    version: 1,
  );
  await container.read(gaiaRepositoryProvider).upsertProject(project);
  return project.id;
}

/// A project's row (GAIA_PROJECTS_HLD.md §7.3): it folds open to its chats,
/// with its menu: a new chat in it on the phone, Rename and Delete.
class _ProjectRow extends ConsumerWidget {
  const _ProjectRow({
    required this.section,
    required this.open,
    required this.onFold,
    required this.running,
  });

  final GaiaProjectSection section;
  final bool open;
  final VoidCallback onFold;

  /// One of its chats is running, so they can't be deleted with it.
  final bool running;

  Future<void> _rename(BuildContext context) async {
    final container = ProviderScope.containerOf(context, listen: false);
    final project = section.project;
    final name = await _askProjectName(
      context,
      title: 'Rename project',
      from: project.name,
    );
    if (name == null || name == project.name) return;
    final repository = container.read(gaiaRepositoryProvider);
    final current = await repository.getProject(project.id);
    if (current == null || current.isDeleted) return;
    await repository.upsertProject(current.copyWith(name: name));
  }

  /// The delete dialog (GAIA_PROJECTS_HLD.md §3.3): its chats stay, as
  /// chats with no project, unless the box is ticked.
  Future<void> _delete(BuildContext context) async {
    final container = ProviderScope.containerOf(context, listen: false);
    final project = section.project;
    final count = section.count;
    final its = count == 1 ? 'its chat' : 'its $count chats';
    final itsCap = 'I${its.substring(1)}';
    var withChats = false;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text('Delete "${project.name}"?'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                count == 0
                    ? 'It has no chats.'
                    : withChats
                    ? '$itsCap will go to the trash with it.'
                    : '$itsCap will stay, as '
                          '${count == 1 ? 'a chat' : 'chats'} with no project.',
              ),
              if (count > 0)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: withChats,
                  title: Text('Also delete $its'),
                  subtitle: running
                      ? const Text('Stop the one running first.')
                      : null,
                  onChanged: running
                      ? null
                      : (value) => setState(() => withChats = value ?? false),
                ),
            ],
          ),
          actions: [
            GlassButton(
              onPressed: () => Navigator.of(context).pop(false),
              label: 'Cancel',
              dense: true,
            ),
            GlassButton(
              onPressed: () => Navigator.of(context).pop(true),
              label: 'Delete',
              dense: true,
            ),
          ],
        ),
      ),
    );
    if (confirmed != true) return;
    // One may have started while the dialog was open.
    if (withChats) {
      final running = container.read(gaiaRunningChatsProvider);
      if (section.groups.any(
        (group) => [
          group.chat,
          ...group.forks,
        ].any((chat) => running.contains(chat.id)),
      )) {
        if (context.mounted) {
          showVoyagerToast(
            context,
            message:
                "Didn't delete ${project.name}: one of its chats "
                'started running',
          );
        }
        return;
      }
    }
    final deleted = await gaiaDeleteProject(
      container.read(gaiaRepositoryProvider),
      project.id,
      withChats: withChats,
    );
    // Their images go onto the chats' 30-day clock with them (GAIA_HLD.md
    // §8), and a restore from the trash brings them back.
    final media = container.read(mediaServiceProvider);
    for (final chat in deleted) {
      await media.removeReferencesForOwner(
        FirestoreCollections.gaiaChats,
        chat.id,
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final count = section.count;
    // Which desktops have its folder (GAIA_PROJECTS_HLD.md §4); one with no
    // heartbeat here goes unnamed.
    final beacons = {
      for (final beacon in ref.watch(gaiaBeaconsProvider).valueOrNull ?? [])
        beacon.deviceId: beacon.name,
    };
    final folders = section.project.folderPaths.keys;
    final on = [for (final device in folders) ?beacons[device]];
    final folder = folders.isEmpty
        ? ''
        : on.length == folders.length
        ? ' · folder on ${on.join(', ')}'
        : ' · folder on ${folders.length == 1 ? 'a desktop' : '${folders.length} desktops'}';
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        open ? PhosphorIconsRegular.caretDown : PhosphorIconsRegular.caretRight,
        size: 14,
      ),
      minLeadingWidth: 14,
      title: Text(section.project.name, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${count == 1 ? '1 chat' : '$count chats'}$folder',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      trailing: PopupMenuButton<VoidCallback>(
        tooltip: 'Project',
        icon: const Icon(PhosphorIconsRegular.dotsThree, size: 16),
        onSelected: (action) => action(),
        itemBuilder: (_) => [
          // On the phone a chat starts here and runs on a desktop.
          PopupMenuItem(
            value: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => GaiaRemoteChatPage(
                  chatId: const Uuid().v4(),
                  projectId: section.project.id,
                ),
              ),
            ),
            child: const Text('New chat'),
          ),
          PopupMenuItem(
            value: () => _rename(context),
            child: const Text('Rename'),
          ),
          PopupMenuItem(
            value: () => _delete(context),
            child: const Text('Delete project…'),
          ),
        ],
      ),
      onTap: onFold,
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

class _ActionRow extends StatelessWidget {
  const _ActionRow({required this.action});

  final GaiaAction action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (:chat, :message, :card) = action;
    // The chat has every step.
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
        GaiaProposalEntity.reminder => PhosphorIconsRegular.tray,
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
    );
  }
}

/// Gaia's memories (§11, §17), in two panes (GAIA_MEMORY_TOPICS_HLD.md
/// §3.2): the topic tree, and the selected topic's memories. The inbox of
/// proposed ones to approve, edit or dismiss comes first, across every
/// topic; then the active ones recall draws on, and the archived ones kept
/// out of it. [focus] is shown highlighted, scrolled to.
class _MemoriesTab extends ConsumerStatefulWidget {
  const _MemoriesTab({this.focus});

  final String? focus;

  @override
  ConsumerState<_MemoriesTab> createState() => _MemoriesTabState();
}

/// The tree's entry for memories in no topic (§3.1).
const _unsorted = '';

class _MemoriesTabState extends ConsumerState<_MemoriesTab> {
  /// The topic shown: null for every memory, [_unsorted] for those in none.
  String? _selected;

  /// Whether a topic shows its subtopics' memories too (§3.2).
  var _subtopics = true;

  final _search = TextEditingController();

  final _focusKey = GlobalKey();

  /// The shown topic's title, above its memories.
  final _titleKey = GlobalKey();

  /// The two panes, on a wide window.
  final _panesKey = GlobalKey();

  /// The panes' height: what's left of the page below the search, measured
  /// after a frame. Null until then.
  double? _panesHeight;

  /// [_panesHeight] afresh, from where the panes start on the page.
  void _fitPanes() {
    final context = _panesKey.currentContext;
    final box = context?.findRenderObject();
    if (!mounted || box is! RenderBox || !box.attached) return;
    final page = Scrollable.of(context!).position;
    final top = RenderAbstractViewport.of(box).getOffsetToReveal(box, 0).offset;
    // 24: the page's padding below them.
    final height = max(400.0, page.viewportDimension - top - 24);
    if (height != _panesHeight) setState(() => _panesHeight = height);
  }

  /// [id]'s memories shown, scrolled to below the inbox, which every topic
  /// shows first.
  void _select(String? id) {
    setState(() => _selected = id);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final context = _titleKey.currentContext;
      if (!mounted || context == null) return;
      // Its own pane to the top: the page around it only if that still
      // leaves the title below the window, as panes at their least can.
      Scrollable.of(
        context,
      ).position.ensureVisible(context.findRenderObject()!);
      Scrollable.ensureVisible(
        context,
        alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
      );
    });
  }

  @override
  void initState() {
    super.initState();
    _scrollToFocus();
  }

  @override
  void didUpdateWidget(_MemoriesTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.focus != oldWidget.focus) {
      // A topic or a search could hide it.
      _selected = null;
      _search.clear();
      _scrollToFocus();
    }
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// Scrolled to once the focused row is first built, which may be only
  /// after the memories load (BUG-383).
  bool _scrollPending = false;

  void _scrollToFocus() => _scrollPending = widget.focus != null;

  /// A dialog with the tree, for a window too narrow for two panes.
  Future<void> _pickShown() => showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Topics'),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Consumer(
            builder: (context, ref, _) {
              final tree = GaiaTopicTree(
                ref.watch(gaiaMemoryTopicsProvider).valueOrNull ?? const [],
              );
              return _TopicTree(
                tree: tree,
                selected: _validSelected(tree),
                onSelect: (id) {
                  _select(id);
                  Navigator.of(dialogContext).pop();
                },
              );
            },
          ),
        ),
      ),
    ),
  );

  /// [_selected], or null for a topic deleted meanwhile, which shows
  /// everything again.
  String? _validSelected(GaiaTopicTree tree) =>
      _selected == null ||
          _selected == _unsorted ||
          tree.path(_selected!).isNotEmpty
      ? _selected
      : null;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final memories = ref.watch(gaiaMemoriesProvider).valueOrNull;
    final settings = ref.watch(gaiaSettingsProvider).valueOrNull;
    final topics = ref.watch(gaiaMemoryTopicsProvider).valueOrNull ?? const [];
    if (memories == null || settings == null) return const SizedBox.shrink();
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final tree = GaiaTopicTree(topics);
    final selected = _validSelected(tree);
    final query = _search.text.trim().toLowerCase();
    final named = {
      for (final topic in topics)
        if (query.isNotEmpty && topic.name.toLowerCase().contains(query))
          topic.id,
    };
    bool matches(GaiaMemory memory) =>
        query.isEmpty ||
        memory.text.toLowerCase().contains(query) ||
        memory.tags.any((tag) => tag.toLowerCase().contains(query)) ||
        memory.topicIds.any(named.contains);
    // A memory dropped on a topic leaves the ones it has in the selected
    // topic's subtree (§3.2), or every one it has from All and Unsorted.
    final moveWithin = selected == null || selected == _unsorted
        ? null
        : tree.subtree(selected);
    final scope = moveWithin == null || _subtopics ? moveWithin : {selected!};
    bool inScope(GaiaMemory memory) => switch (selected) {
      null => true,
      _unsorted => memory.topicIds.every((id) => tree.path(id).isEmpty),
      _ => memory.topicIds.any(scope!.contains),
    };
    List<GaiaMemory> withStatus(GaiaMemoryStatus status) => [
      for (final memory in memories.reversed)
        if (memory.status == status &&
            matches(memory) &&
            // The inbox is shown across every topic (§3.2).
            (status == GaiaMemoryStatus.proposed || inScope(memory)))
          memory,
    ];
    // A search keeps the topics it names, and those holding a memory it
    // finds, with the topics above them.
    Set<String>? visible;
    if (query.isNotEmpty) {
      final found = {
        for (final memory in memories)
          if (matches(memory)) ...memory.topicIds,
      };
      visible = {};
      for (final topic in topics) {
        if (!named.contains(topic.id) && !found.contains(topic.id)) {
          continue;
        }
        for (String? at = topic.id; at != null; at = tree.parentOf(at)) {
          visible.add(at);
        }
      }
    }
    if (_scrollPending) {
      _scrollPending = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final context = _focusKey.currentContext;
        if (mounted && context != null) {
          Scrollable.ensureVisible(context, alignment: 0.3);
        }
      });
    }
    Widget row(GaiaMemory memory) => _MemoryRow(
      key: memory.id == widget.focus ? _focusKey : null,
      memory: memory,
      tree: tree,
      moveWithin: moveWithin,
      highlighted: memory.id == widget.focus,
    );
    final inbox = withStatus(GaiaMemoryStatus.proposed);
    final active = withStatus(GaiaMemoryStatus.active);
    final archived = withStatus(GaiaMemoryStatus.archived);
    // Suggestions in the inbox (GAIA_MEMORY_TOPICS_HLD.md §3.3, §5): pins
    // from this device's recall history and the curator, and merges.
    final hints = ref.watch(gaiaMemoryHintsProvider).valueOrNull ?? const [];
    final pins = [
      for (final pin in gaiaPinSuggestions(
        memories,
        ref.watch(gaiaRecallHistoryProvider).valueOrNull ?? const [],
        hints,
        utcNow(),
      ))
        if (matches(pin.memory)) pin,
    ];
    final merges = [
      for (final merge in gaiaMergeSuggestions(tree, memories, {
        for (final project
            in ref.watch(gaiaProjectsProvider).valueOrNull ?? const [])
          project.id,
      }, hints))
        if (query.isEmpty ||
            named.contains(merge.from.id) ||
            named.contains(merge.into.id))
          merge,
    ];
    final suggestions = pins.length + merges.length;
    final title = switch (selected) {
      null => 'All memories',
      _unsorted => 'Unsorted',
      _ => tree.path(selected).join(' › '),
    };
    Widget list() => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (inbox.isNotEmpty || suggestions > 0) ...[
          _SectionLabel('Inbox (${inbox.length + suggestions})'),
          for (final merge in merges) _MergeSuggestionRow(merge, tree: tree),
          for (final pin in pins) _PinSuggestionRow(pin),
          for (final memory in inbox) row(memory),
          const SizedBox(height: 16),
        ],
        Row(
          key: _titleKey,
          children: [
            Expanded(
              child: Text(
                title,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall,
              ),
            ),
            if (scope != null) ...[
              Checkbox(
                value: _subtopics,
                visualDensity: VisualDensity.compact,
                onChanged: (value) =>
                    setState(() => _subtopics = value ?? true),
              ),
              Text('Include subtopics', style: theme.textTheme.bodySmall),
            ],
          ],
        ),
        const SizedBox(height: 4),
        _SectionLabel(
          active.isEmpty ? 'Remembered' : 'Remembered (${active.length})',
        ),
        if (active.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text('Nothing yet.', style: muted),
          ),
        for (final memory in active) row(memory),
        if (archived.isNotEmpty) ...[
          const SizedBox(height: 16),
          _SectionLabel('Archived (${archived.length})'),
          for (final memory in archived) row(memory),
        ],
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Gaia adds the ones that fit to each message you send, whichever '
          'agent answers, and pinned ones go in every chat. Save one '
          'yourself with /remember in Gaia. What Gaia offers, or notices '
          'once a chat goes quiet, waits in the inbox.',
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
        VoyagerTextField(
          controller: _search,
          decoration: const InputDecoration(
            hintText: 'Search memories and topics',
            prefixIcon: Icon(PhosphorIconsRegular.magnifyingGlass, size: 16),
            isDense: true,
          ),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (context, constraints) {
            // Each pane scrolls on its own, filling the page below the
            // search.
            if (constraints.maxWidth >= 640) {
              // Again as the window resizes, or the text above rewraps.
              MediaQuery.sizeOf(context);
              WidgetsBinding.instance.addPostFrameCallback((_) => _fitPanes());
              return SizedBox(
                key: _panesKey,
                height:
                    _panesHeight ??
                    max(400, MediaQuery.sizeOf(context).height - 48),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 240,
                      child: SingleChildScrollView(
                        child: _TopicTree(
                          tree: tree,
                          selected: selected,
                          visible: visible,
                          onSelect: _select,
                        ),
                      ),
                    ),
                    const SizedBox(width: 24),
                    Expanded(child: SingleChildScrollView(child: list())),
                  ],
                ),
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: GlassButton(
                    onPressed: _pickShown,
                    icon: const Icon(PhosphorIconsRegular.treeView, size: 13),
                    label: title,
                    dense: true,
                  ),
                ),
                const SizedBox(height: 12),
                list(),
              ],
            );
          },
        ),
      ],
    );
  }
}

/// [tree]'s topics in the order shown, each with its depth.
List<(GaiaMemoryTopic, int)> _topicsInOrder(GaiaTopicTree tree) {
  final order = <(GaiaMemoryTopic, int)>[];
  void walk(String? parent, int depth) {
    for (final topic in tree.childrenOf(parent)) {
      order.add((topic, depth));
      walk(topic.id, depth + 1);
    }
  }

  walk(null, 0);
  return order;
}

/// A topic picked from [tree] in a dialog, leaving out [exclude]; with
/// [topLevel], an entry for the root, which gives [_unsorted]. Null when
/// cancelled.
Future<String?> _pickTopic(
  BuildContext context,
  GaiaTopicTree tree, {
  required String title,
  Set<String> exclude = const {},
  bool topLevel = false,
}) => showDialog<String>(
  context: context,
  builder: (context) => SimpleDialog(
    title: Text(title),
    children: [
      if (topLevel)
        SimpleDialogOption(
          onPressed: () => Navigator.of(context).pop(_unsorted),
          child: const Text('Top level'),
        ),
      for (final (topic, depth) in _topicsInOrder(tree))
        if (!exclude.contains(topic.id))
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop(topic.id),
            child: Padding(
              padding: EdgeInsets.only(left: 16.0 * depth),
              child: Text(topic.name, overflow: TextOverflow.ellipsis),
            ),
          ),
    ],
  ),
);

/// The Memories tab's topic tree (GAIA_MEMORY_TOPICS_HLD.md §3.2): All
/// memories, every topic, and Unsorted. Each topic has a menu.
class _TopicTree extends ConsumerStatefulWidget {
  const _TopicTree({
    required this.tree,
    required this.selected,
    required this.onSelect,
    this.visible,
  });

  final GaiaTopicTree tree;
  final String? selected;

  /// The topics a search keeps; null for every one.
  final Set<String>? visible;
  final ValueChanged<String?> onSelect;

  @override
  ConsumerState<_TopicTree> createState() => _TopicTreeState();
}

class _TopicTreeState extends ConsumerState<_TopicTree> {
  final _focus = FocusNode(debugLabel: 'memory topics');

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  GaiaMemories get _memories => GaiaMemories(ref.read(gaiaRepositoryProvider));

  /// [action], with a refusal shown in a toast; whether it went through.
  Future<bool> _run(Future<void> Function() action) async {
    try {
      await action();
      return true;
    } on GaiaReadException catch (error) {
      if (mounted) {
        showVoyagerToast(
          context,
          message: error.message,
          icon: PhosphorIconsRegular.warning,
        );
      }
      return false;
    }
  }

  String? _named(String name) => name.trim().isEmpty ? 'Give it a name.' : null;

  Future<void> _newTopic({String? parentId}) async {
    final name = await showPromptNameDialog(
      context,
      title: parentId == null ? 'New topic' : 'New subtopic',
      validate: _named,
    );
    if (name == null) return;
    final topic = await _memories.newTopic(name, parentId: parentId);
    widget.onSelect(topic.id);
  }

  Future<void> _rename(GaiaMemoryTopic topic) async {
    final name = await showPromptNameDialog(
      context,
      title: 'Rename topic',
      initial: topic.name,
      validate: _named,
    );
    if (name == null) return;
    await _memories.renameTopic(topic.id, name);
  }

  Future<void> _moveUnder(GaiaMemoryTopic topic) async {
    final to = await _pickTopic(
      context,
      widget.tree,
      title: 'Move "${topic.name}" under',
      exclude: widget.tree.subtree(topic.id),
      topLevel: true,
    );
    if (to == null) return;
    await _run(
      () => _memories.moveTopic(topic.id, to == _unsorted ? null : to),
    );
  }

  Future<void> _delete(GaiaMemoryTopic topic) async {
    final parent = widget.tree.parentOf(topic.id);
    final hasChildren = widget.tree.childrenOf(topic.id).isNotEmpty;
    final confirmed = await showConfirmDialog(
      context,
      title: 'Delete "${topic.name}"?',
      message: [
        'Its memories stay in their other topics, or go to Unsorted.',
        if (hasChildren)
          'Its subtopics move up to '
              '${parent == null ? 'the top level' : widget.tree.path(parent).last}.',
      ].join(' '),
    );
    if (!confirmed) return;
    await _run(() => _memories.deleteTopic(topic.id));
  }

  /// Merged into a topic picked in a dialog (GAIA_MEMORY_TOPICS_HLD.md
  /// §3.2), once confirmed.
  Future<void> _merge(GaiaMemoryTopic topic) async {
    final into = await _pickTopic(
      context,
      widget.tree,
      title: 'Merge "${topic.name}" into',
      exclude: {topic.id},
    );
    if (into == null || !mounted) return;
    final kept = widget.tree.path(into).join(' › ');
    final confirmed = await showConfirmDialog(
      context,
      title: 'Merge "${topic.name}" into "$kept"?',
      message:
          'Its memories and subtopics move to $kept, and "${topic.name}" '
          'goes to the trash.',
      confirmLabel: 'Merge',
    );
    if (!confirmed) return;
    if (await _run(() => _memories.mergeTopic(topic.id, into))) {
      widget.onSelect(into);
    }
  }

  List<ContextMenuItem> _menu(GaiaMemoryTopic topic, Set<String> projects) {
    final linked = projects.contains(topic.projectId);
    return [
      ContextMenuItem(
        label: 'Rename',
        icon: PhosphorIconsRegular.pencilSimple,
        onTap: () => _rename(topic),
      ),
      ContextMenuItem(
        label: 'New subtopic',
        icon: PhosphorIconsRegular.plus,
        onTap: () => _newTopic(parentId: topic.id),
      ),
      ContextMenuItem(
        label: 'Move under…',
        icon: PhosphorIconsRegular.arrowElbowDownRight,
        onTap: () => _moveUnder(topic),
      ),
      // A project's topic can be kept in a merge, not merged away (§3.2).
      ContextMenuItem(
        label: linked ? "Merge into… (a project's topic stays)" : 'Merge into…',
        icon: PhosphorIconsRegular.arrowsMerge,
        onTap: linked ? null : () => _merge(topic),
      ),
      ContextMenuItem(
        label: linked ? 'Delete (goes with its project)' : 'Delete',
        icon: PhosphorIconsRegular.trash,
        isDestructive: true,
        onTap: linked ? null : () => _delete(topic),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final projects = <String>{
      for (final project
          in ref.watch(gaiaProjectsProvider).valueOrNull ?? const [])
        project.id,
    };
    final tree = widget.tree;

    Widget tile({
      required String? id,
      required String label,
      required int depth,
      required IconData icon,
      Widget? trailing,
    }) => Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Colors.transparent),
      ),
      child: ListTile(
        dense: true,
        visualDensity: VisualDensity.compact,
        contentPadding: EdgeInsets.only(left: 4 + 16.0 * depth, right: 4),
        minLeadingWidth: 16,
        horizontalTitleGap: 8,
        leading: Icon(icon, size: 15),
        title: Text(label, overflow: TextOverflow.ellipsis),
        trailing: trailing,
        selected: widget.selected == id,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        onTap: () {
          _focus.requestFocus();
          widget.onSelect(id);
        },
      ),
    );

    Widget topicRow(GaiaMemoryTopic topic, int depth) => tile(
      id: topic.id,
      label: topic.name,
      depth: depth,
      icon: PhosphorIconsRegular.folderSimple,
      trailing: ContextMenuButton(items: _menu(topic, projects)),
    );

    final all = tile(
      id: null,
      label: 'All memories',
      depth: 0,
      icon: PhosphorIconsRegular.stack,
    );
    final selected = widget.selected;
    return Focus(
      focusNode: _focus,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent ||
            event.logicalKey != LogicalKeyboardKey.f2 ||
            selected == null ||
            selected == _unsorted) {
          return KeyEventResult.ignored;
        }
        final topic = tree[selected];
        if (topic == null) return KeyEventResult.ignored;
        unawaited(_rename(topic));
        return KeyEventResult.handled;
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: GlassButton(
              onPressed: () => _newTopic(),
              icon: const Icon(PhosphorIconsRegular.plus, size: 13),
              label: 'New topic',
              dense: true,
            ),
          ),
          const SizedBox(height: 8),
          all,
          for (final (topic, depth) in _topicsInOrder(tree))
            if (widget.visible?.contains(topic.id) ?? true)
              topicRow(topic, depth),
          tile(
            id: _unsorted,
            label: 'Unsorted',
            depth: 0,
            icon: PhosphorIconsRegular.tray,
          ),
        ],
      ),
    );
  }
}

class _MemoryRow extends ConsumerWidget {
  const _MemoryRow({
    super.key,
    required this.memory,
    required this.tree,
    required this.moveWithin,
    this.highlighted = false,
  });

  final GaiaMemory memory;
  final GaiaTopicTree tree;

  /// The topics a move takes it out of (GAIA_MEMORY_TOPICS_HLD.md §3.2);
  /// null for every one.
  final Set<String>? moveWithin;
  final bool highlighted;

  Future<void> _save(WidgetRef ref, GaiaMemory memory) =>
      ref.read(gaiaRepositoryProvider).upsertMemory(memory);

  Future<void> _edit(BuildContext context, WidgetRef ref) async {
    final edited = await showDialog<({String text, List<String> tags})>(
      context: context,
      builder: (_) => _MemoryDialog(memory: memory),
    );
    if (edited == null || !context.mounted) return;
    // An active one edited to say what another does would be a second copy
    // in every chat's index. A proposal is checked as it's remembered.
    if (memory.status == GaiaMemoryStatus.active &&
        await _alreadyRemembered(context, ref, edited.text)) {
      return;
    }
    await _save(ref, memory.copyWith(text: edited.text, tags: edited.tags));
    // An open card in its chat offers it as it now says.
    if (memory.status == GaiaMemoryStatus.proposed &&
        edited.text != memory.text) {
      await _setCards(
        ref.read(gaiaRepositoryProvider),
        GaiaCardState.open,
        edited.text,
      );
    }
  }

  /// Moved to a topic picked in a dialog, or with [add] added to one
  /// (GAIA_MEMORY_TOPICS_HLD.md §3.2).
  Future<void> _file(
    BuildContext context,
    WidgetRef ref, {
    required bool add,
  }) async {
    final to = await _pickTopic(
      context,
      tree,
      title: add ? 'Add to topic' : 'Move to topic',
      exclude: add ? memory.topicIds.toSet() : const {},
    );
    if (to == null) return;
    final memories = GaiaMemories(ref.read(gaiaRepositoryProvider));
    if (add) {
      await memories.addMemoryTopic(memory.id, to);
    } else {
      await memories.moveMemory(memory.id, to, within: moveWithin);
    }
  }

  /// Pinned, or unpinned (GAIA_MEMORY_TOPICS_HLD.md §3.3); a pin past the
  /// budget is refused with a toast.
  Future<void> _pin(BuildContext context, WidgetRef ref) async {
    try {
      await GaiaMemories(
        ref.read(gaiaRepositoryProvider),
      ).pin(memory.id, pinned: !memory.pinned);
    } on GaiaReadException catch (error) {
      if (context.mounted) {
        showVoyagerToast(
          context,
          message: error.message,
          icon: PhosphorIconsRegular.warning,
          dwell: const Duration(seconds: 4),
        );
      }
    }
  }

  /// Whether an active memory other than this one says [text], from any
  /// project (GAIA_MEMORY_TOPICS_HLD.md §5), said in a toast when it does.
  Future<bool> _alreadyRemembered(
    BuildContext context,
    WidgetRef ref,
    String text,
  ) async {
    final same = await GaiaMemories(
      ref.read(gaiaRepositoryProvider),
    ).sameActive(text, except: memory.id);
    if (same == null) return false;
    if (context.mounted) {
      showVoyagerToast(context, message: 'Already remembered: ${same.text}');
    }
    return true;
  }

  /// Remembered from the inbox: the proposal's card in its chat says so too.
  /// One an active memory already says is spent instead, that one standing.
  Future<void> _remember(BuildContext context, WidgetRef ref) async {
    final repository = ref.read(gaiaRepositoryProvider);
    final same = await GaiaMemories(
      repository,
    ).sameActive(memory.text, except: memory.id);
    if (same == null) {
      await _save(ref, memory.copyWith(status: GaiaMemoryStatus.active));
    } else {
      await _save(ref, memory.copyWith(deletedAt: utcNow()));
      if (context.mounted) {
        showVoyagerToast(context, message: 'Already remembered: ${same.text}');
      }
    }
    await _setCards(
      repository,
      GaiaCardState.accepted,
      same?.text ?? memory.text,
    );
  }

  /// This memory's card in the chat that proposed it set to [state].
  Future<void> _setCards(
    GaiaRepository repository,
    GaiaCardState state,
    String text,
  ) async {
    final chatId = memory.sourceChatId;
    if (chatId == null) return;
    await GaiaHost.instance.setMemoryCards(
      repository,
      chatId,
      memory.id,
      state,
      text,
    );
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
      delete: () async {
        await repository.upsertMemory(memory.copyWith(deletedAt: utcNow()));
        // A proposal's card says it was dismissed, until that's undone.
        if (proposed) {
          await _setCards(repository, GaiaCardState.rejected, memory.text);
        }
      },
      restore: () async {
        final current = await repository.getMemory(memory.id);
        if (current == null) return;
        await repository.upsertMemory(current.copyWith(clearDeletedAt: true));
        if (proposed && current.status == GaiaMemoryStatus.proposed) {
          await _setCards(repository, GaiaCardState.open, current.text);
        }
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
    // Its topics, each by its path, with × to take it out of one
    // (GAIA_MEMORY_TOPICS_HLD.md §3.2); one that points nowhere is left out.
    final topics = [
      for (final id in memory.topicIds)
        if (tree.path(id) case final path when path.isNotEmpty)
          (id, path.join(' › ')),
    ];
    // A new topic offered for it, made only once accepted (§5).
    final suggested = memory.suggestedTopic == null
        ? null
        : gaiaSuggestedTopicLabel(memory.suggestedTopic!, tree);
    final (icon, label, onPressed) = switch (memory.status) {
      GaiaMemoryStatus.proposed => (
        PhosphorIconsRegular.check,
        'Remember',
        () => _remember(context, ref),
      ),
      GaiaMemoryStatus.active => (
        PhosphorIconsRegular.archive,
        'Archive',
        () => _save(ref, memory.copyWith(status: GaiaMemoryStatus.archived)),
      ),
      GaiaMemoryStatus.archived => (
        PhosphorIconsRegular.arrowCounterClockwise,
        'Remember again',
        () async {
          if (await _alreadyRemembered(context, ref, memory.text)) {
            return;
          }
          await _save(ref, memory.copyWith(status: GaiaMemoryStatus.active));
        },
      ),
    };
    return ListTile(
      contentPadding: EdgeInsets.zero,
      selected: highlighted,
      title: Text(memory.text),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            [
              if (memory.tags.isNotEmpty)
                memory.tags.map((t) => '#$t').join(' '),
              ?source?.title,
              DateFormat.yMMMd().format(memory.createdAt.toLocal()),
            ].join(' · '),
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall,
          ),
          if (topics.isNotEmpty || suggested != null) ...[
            const SizedBox(height: 4),
            Wrap(
              spacing: 4,
              runSpacing: 4,
              children: [
                for (final (id, path) in topics)
                  _TopicChip(
                    label: path,
                    onRemove: () => GaiaMemories(
                      ref.read(gaiaRepositoryProvider),
                    ).removeMemoryTopic(memory.id, id),
                  ),
                if (suggested != null)
                  _TopicChip(
                    label: '+ New topic: $suggested',
                    tooltip: 'Make this topic and file it there',
                    removeTooltip: "Don't make it",
                    onTap: () => GaiaMemories(
                      ref.read(gaiaRepositoryProvider),
                    ).acceptSuggestedTopic(memory.id),
                    onRemove: () => GaiaMemories(
                      ref.read(gaiaRepositoryProvider),
                    ).dropSuggestedTopic(memory.id),
                  ),
              ],
            ),
          ],
        ],
      ),
      onTap: () => _edit(context, ref),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // In every chat's system prompt (GAIA_MEMORY_TOPICS_HLD.md §3.3).
          if (memory.status == GaiaMemoryStatus.active || memory.pinned)
            IconButton(
              tooltip: memory.pinned ? 'Unpin' : 'Pin to every chat',
              icon: Icon(
                memory.pinned
                    ? PhosphorIconsFill.pushPin
                    : PhosphorIconsRegular.pushPin,
                size: 16,
              ),
              onPressed: () => _pin(context, ref),
            ),
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
          if (tree.childrenOf(null).isNotEmpty)
            ContextMenuButton(
              items: [
                ContextMenuItem(
                  label: 'Move to topic…',
                  icon: PhosphorIconsRegular.arrowBendUpRight,
                  onTap: () => _file(context, ref, add: false),
                ),
                ContextMenuItem(
                  label: 'Add to topic…',
                  icon: PhosphorIconsRegular.plus,
                  onTap: () => _file(context, ref, add: true),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

/// "Pin this?" in the inbox (GAIA_MEMORY_TOPICS_HLD.md §3.3): Pin, or Not
/// now for [kGaiaPinLater].
class _PinSuggestionRow extends ConsumerWidget {
  const _PinSuggestionRow(this.suggestion);

  final GaiaPinSuggestion suggestion;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final memories = GaiaMemories(ref.read(gaiaRepositoryProvider));
    final memory = suggestion.memory;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(PhosphorIconsRegular.pushPin, size: 16),
      minLeadingWidth: 16,
      title: Text(memory.text),
      subtitle: Text('Pin this? ${suggestion.why}.'),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextButton(
            onPressed: () async {
              try {
                await memories.pin(memory.id, pinned: true);
              } on GaiaReadException catch (error) {
                if (context.mounted) {
                  showVoyagerToast(
                    context,
                    message: error.message,
                    icon: PhosphorIconsRegular.warning,
                    dwell: const Duration(seconds: 4),
                  );
                }
              }
            },
            child: const Text('Pin'),
          ),
          TextButton(
            onPressed: () => memories.pinLater(memory.id),
            child: const Text('Not now'),
          ),
        ],
      ),
    );
  }
}

/// "Merge X into Y?" in the inbox (GAIA_MEMORY_TOPICS_HLD.md §5): Merge, or
/// Keep both, which this device doesn't suggest again.
class _MergeSuggestionRow extends ConsumerWidget {
  const _MergeSuggestionRow(this.suggestion, {required this.tree});

  final GaiaMergeSuggestion suggestion;
  final GaiaTopicTree tree;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final memories = GaiaMemories(ref.read(gaiaRepositoryProvider));
    final from = tree.path(suggestion.from.id).join(' › ');
    final into = tree.path(suggestion.into.id).join(' › ');
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(PhosphorIconsRegular.arrowsMerge, size: 16),
      minLeadingWidth: 16,
      title: Text('Merge "$from" into "$into"?'),
      subtitle: Text('${suggestion.why}.'),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextButton(
            onPressed: () async {
              try {
                await memories.mergeTopic(
                  suggestion.from.id,
                  suggestion.into.id,
                );
              } on GaiaReadException catch (error) {
                if (context.mounted) {
                  showVoyagerToast(
                    context,
                    message: error.message,
                    icon: PhosphorIconsRegular.warning,
                  );
                }
              }
            },
            child: const Text('Merge'),
          ),
          TextButton(
            onPressed: () =>
                memories.keepApart(suggestion.from.id, suggestion.into.id),
            child: const Text('Keep both'),
          ),
        ],
      ),
    );
  }
}

/// A memory's topic on its row, with × to take it out; or a new topic
/// offered for it, which [onTap] accepts.
class _TopicChip extends StatelessWidget {
  const _TopicChip({
    required this.label,
    required this.onRemove,
    this.onTap,
    this.tooltip,
    this.removeTooltip = 'Remove from topic',
  });

  final String label;
  final VoidCallback onRemove;
  final VoidCallback? onTap;
  final String? tooltip;
  final String removeTooltip;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = Text(
      label,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.labelSmall?.copyWith(
        color: theme.colorScheme.primary,
        fontWeight: FontWeight.bold,
      ),
    );
    return Container(
      constraints: const BoxConstraints(maxWidth: 220),
      padding: const EdgeInsets.only(left: 8, right: 2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: InkWell(
              onTap: onTap,
              child: tooltip == null
                  ? text
                  : Tooltip(message: tooltip, child: text),
            ),
          ),
          InkWell(
            onTap: onRemove,
            customBorder: const CircleBorder(),
            child: Tooltip(
              message: removeTooltip,
              child: Padding(
                padding: const EdgeInsets.all(3),
                child: Icon(
                  PhosphorIconsRegular.x,
                  size: 10,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
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
    required this.projects,
    required this.running,
    this.open,
    this.onFold,
  });

  final GaiaChat chat;

  /// The live projects, to move it to (GAIA_PROJECTS_HLD.md §3.2).
  final List<GaiaProject> projects;
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
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => GaiaRemoteChatPage(chatId: chat.id),
      ),
    );
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
            onPressed: () => gaiaSetPinned(
              ref.read(gaiaRepositoryProvider),
              chat.id,
              !chat.pinned,
            ),
          ),
          PopupMenuButton<VoidCallback>(
            tooltip: 'Move to project',
            icon: const Icon(PhosphorIconsRegular.folderSimple, size: 16),
            onSelected: (action) => action(),
            itemBuilder: (_) {
              final repository = ref.read(gaiaRepositoryProvider);
              final inProject = projects.any((p) => p.id == chat.projectId);
              return [
                for (final project in projects)
                  if (project.id != chat.projectId)
                    PopupMenuItem(
                      value: () =>
                          gaiaMoveChat(repository, chat.id, project.id),
                      child: Text(
                        project.name,
                        style: TextStyle(
                          color: theme.colorScheme.primary,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                PopupMenuItem(
                  value: () async {
                    final projectId = await _newProject(context);
                    if (projectId != null) {
                      await gaiaMoveChat(repository, chat.id, projectId);
                    }
                  },
                  child: const Text('New project…'),
                ),
                if (inProject)
                  PopupMenuItem(
                    value: () => gaiaMoveChat(repository, chat.id, null),
                    child: const Text('Remove from project'),
                  ),
              ];
            },
          ),
          IconButton(
            tooltip: chat.archived ? 'Unarchive' : 'Archive',
            icon: Icon(
              chat.archived
                  ? PhosphorIconsRegular.arrowCounterClockwise
                  : PhosphorIconsRegular.archive,
              size: 16,
            ),
            // From the stored chat, as Pin is.
            onPressed: () => gaiaSetArchived(
              ref.read(gaiaRepositoryProvider),
              chat.id,
              !chat.archived,
            ),
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
        _NameSection(settings: settings),
        const SizedBox(height: 24),
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
        const SizedBox(height: 16),
      ],
    );
  }
}

/// What new-chat greetings call the user (GAIA_GREETINGS_HLD.md §3).
class _NameSection extends ConsumerStatefulWidget {
  const _NameSection({required this.settings});

  final GaiaSettings settings;

  @override
  ConsumerState<_NameSection> createState() => _NameSectionState();
}

class _NameSectionState extends ConsumerState<_NameSection> {
  final _name = TextEditingController();

  /// The name as last loaded or saved.
  String? _saved;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    // Stored as the companion uses it: spaces alone are no name (§3).
    final text = _name.text.trim();
    _name.text = text;
    await ref
        .read(gaiaRepositoryProvider)
        .upsertSettings(widget.settings.copyWith(userName: text));
    if (mounted) setState(() => _saved = text);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final stored = widget.settings.userName;
    // As GAIA.md's: reloaded when it changes elsewhere with nothing unsaved.
    if (_saved == null || (_name.text == _saved && _saved != stored)) {
      _saved = stored;
      _name.text = stored;
    }
    final dirty = _name.text != _saved;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Your name', style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          'Gaia uses it to greet you in a new chat. Synced to all your '
          'devices.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        VoyagerTextField(
          controller: _name,
          maxLength: 24,
          buildCounter:
              (_, {required currentLength, required isFocused, maxLength}) =>
                  null,
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) {
            if (_name.text != _saved) _save();
          },
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerRight,
          child: GlassButton(
            onPressed: dirty ? _save : null,
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
                            '${_adapterLabels[agent.adapter] ?? agent.adapter}'
                            '${agent.effort == null ? '' : ' · ${agent.effort} effort'}',
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
              '${agent.model}'
              '${agent.effort == null ? '' : ' · ${agent.effort} effort'}',
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

  /// Null for the CLI's default.
  String? _effort;

  /// The model is typed in, not one of [kGaiaModels].
  var _custom = false;
  static const _customItem = '';

  @override
  void dispose() {
    _label.dispose();
    _model.dispose();
    super.dispose();
  }

  bool get _valid =>
      _label.text.trim().isNotEmpty && _model.text.trim().isNotEmpty;

  List<String> get _efforts => gaiaEfforts(_adapter, _model.text.trim());

  /// [_effort], unless the model now chosen doesn't take it.
  String? get _chosenEffort => _efforts.contains(_effort) ? _effort : null;

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
              onChanged: (adapter) => setState(() {
                _adapter = adapter!;
                // Each CLI has its own models and levels.
                if (!_custom) _model.clear();
                if (!(kGaiaEfforts[_adapter] ?? []).contains(_effort)) {
                  _effort = null;
                }
              }),
            ),
            const SizedBox(height: 8),
            DropdownButton<String>(
              isExpanded: true,
              value: _custom
                  ? _customItem
                  : (kGaiaModels[_adapter] ?? []).contains(_model.text)
                  ? _model.text
                  : null,
              hint: const Text('Model'),
              items: [
                for (final model in kGaiaModels[_adapter] ?? <String>[])
                  DropdownMenuItem(value: model, child: Text(model)),
                const DropdownMenuItem(
                  value: _customItem,
                  child: Text('Custom…'),
                ),
              ],
              onChanged: (model) => setState(() {
                _custom = model == _customItem;
                _model.text = model!;
              }),
            ),
            if (_custom) ...[
              const SizedBox(height: 8),
              VoyagerTextField(
                controller: _model,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: 'Model',
                  hintText: _adapter == kGaiaCodexAdapter
                      ? 'e.g. gpt-6.1-sol'
                      : 'e.g. claude-sonnet-5-5',
                ),
                onChanged: (_) => setState(() {}),
              ),
            ],
            const SizedBox(height: 8),
            DropdownButton<String?>(
              isExpanded: true,
              value: _chosenEffort,
              items: [
                const DropdownMenuItem(child: Text('Default effort')),
                for (final effort in _efforts)
                  DropdownMenuItem(
                    value: effort,
                    child: Text('$effort effort'),
                  ),
              ],
              onChanged: (effort) => setState(() => _effort = effort),
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
                    effort: _chosenEffort,
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
final _reservedCommandNames = kGaiaReservedCommandNames;

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
