import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/companion/gaia_action_icon.dart';
import 'package:voyager/features/gaia/companion/gaia_button.dart';
import 'package:voyager/features/gaia/companion/gaia_card_text_field.dart';
import 'package:voyager/features/gaia/companion/gaia_controller.dart';
import 'package:voyager/features/gaia/companion/gaia_memory_card.dart';
import 'package:voyager/features/gaia/companion/gaia_memory_review.dart';
import 'package:voyager/features/gaia/companion/gaia_notch.dart';
import 'package:voyager/features/gaia/companion/gaia_orb_materials.dart';
import 'package:voyager/features/gaia/companion/gaia_settings_panel.dart';
import 'package:voyager/features/gaia/companion/gaia_style.dart';
import 'package:voyager/features/gaia/companion/gaia_text_field.dart';
import 'package:voyager/features/gaia/companion/gaia_toast.dart';
import 'package:voyager/features/gaia/companion/gaia_topic_picker.dart';
import 'package:voyager/features/gaia/gaia_pipe.dart';
import 'package:voyager/features/gaia/host/gaia_memories.dart';

/// The topic in view for memories in no topic (GAIA_MEMORY_TOPICS_HLD.md
/// §3.1).
const _unsorted = '';

/// What's dragged on the tab: a memory's card onto a topic, or a topic's
/// chip onto another or onto All memories, for the root.
sealed class _Dragged {
  const _Dragged(this.id);

  final String id;
}

class _DraggedMemory extends _Dragged {
  const _DraggedMemory(super.id);
}

class _DraggedTopic extends _Dragged {
  const _DraggedTopic(super.id);
}

/// The settings panel's Memories tab (GAIA_SETTINGS_HLD.md §5): one scroll
/// with the search, a breadcrumb and the topic in view's subtopics as chips
/// instead of a tree, the inbox, then the memories of the topic in view.
/// Everything the Gaia page's Memories tab does, through the pipe.
class GaiaMemoriesTab extends StatefulWidget {
  const GaiaMemoriesTab({super.key, required this.controller, this.askChat});

  final GaiaController controller;

  /// The review's Ask Gaia chat, while it shows one (GAIA_SETTINGS_HLD.md §7).
  final Widget? askChat;

  @override
  State<GaiaMemoriesTab> createState() => _GaiaMemoriesTabState();
}

class _GaiaMemoriesTabState extends State<GaiaMemoriesTab> {
  GaiaController get _controller => widget.controller;

  /// The topic in view: null for every memory, [_unsorted] for those in
  /// none.
  String? _topic;

  /// Whether a topic shows its subtopics' memories too.
  var _subtopics = true;

  var _showArchived = false;

  /// Whether the inbox is open; null for its default: open at All memories
  /// and in a search, folded in a topic, whose own memories it would bury.
  bool? _showInbox;

  /// The search box, whose context reaches the tab's scroll from anywhere.
  final _searchKey = GlobalKey();
  final _inboxKey = GlobalKey();

  /// Set while a reveal clears the search, which happens during a build.
  var _revealing = false;

  void _clearForReveal() {
    _revealing = true;
    _search.clear();
    _revealing = false;
  }

  final _search = TextEditingController();

  /// Esc clears the search, then lets go of it, so the next Esc closes
  /// the panel.
  late final _searchFocus = FocusNode(
    debugLabel: 'gaia memories search',
    onKeyEvent: (node, event) {
      if (event is! KeyDownEvent ||
          event.logicalKey != LogicalKeyboardKey.escape) {
        return KeyEventResult.ignored;
      }
      if (_search.text.isNotEmpty) {
        _search.clear();
      } else {
        node.unfocus();
      }
      return KeyEventResult.handled;
    },
  );

  /// The memory a recall chip asked for, shown and edged until the view
  /// changes.
  String? _highlighted;
  final _highlightKey = GlobalKey();

  /// The topic chip being renamed in place, and the new topic being named
  /// in the strip.
  String? _renaming;
  var _naming = false;

  @override
  void initState() {
    super.initState();
    _search.addListener(() {
      // A reveal clears it mid-build, and sets what it needs itself.
      if (_revealing) return;
      setState(() => _highlighted = null);
    });
  }

  @override
  void dispose() {
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _show(String? topic) => setState(() {
    _topic = topic;
    _showInbox = null;
    _highlighted = null;
    _renaming = null;
    _naming = false;
  });

  /// [action], with a refusal said in a toast titled [failed]; whether it
  /// went through.
  Future<bool> _run(Future<void> Function() action, String failed) async {
    try {
      await action();
      return true;
    } on GaiaPipeException catch (error) {
      if (mounted) {
        showGaiaToast(
          context,
          mark: GaiaToastMark.error,
          title: failed,
          body: error.message,
        );
      }
      return false;
    }
  }

  Future<bool> _write(
    String method,
    Map<String, Object?> params, {
    String failed = "Couldn't save that",
  }) => _run(() => _controller.writeMemories(method, params), failed);

  /// The memory a recall chip asked for, taken from the controller: the
  /// view cleared so nothing hides it, then scrolled to once it's built.
  void _takeReveal(GaiaMemoryList list) {
    if (_controller.revealInbox) {
      _controller.revealInbox = false;
      _topic = null;
      _clearForReveal();
      _highlighted = null;
      _showInbox = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final inbox = _inboxKey.currentContext;
        final search = _searchKey.currentContext;
        if (!mounted) return;
        if (inbox != null) {
          unawaited(
            Scrollable.ensureVisible(inbox, duration: GaiaMotion.quick),
          );
        } else if (search != null) {
          Scrollable.of(search).position.jumpTo(0);
        }
      });
    }
    final id = _controller.revealMemoryId;
    if (id == null) return;
    _controller.revealMemoryId = null;
    final memory = list.memories.where((memory) => memory.id == id).firstOrNull;
    if (memory == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        showGaiaToast(
          context,
          mark: GaiaToastMark.info,
          title: 'Not found',
          body: 'That memory is gone.',
        );
      });
      return;
    }
    _topic = null;
    _clearForReveal();
    _highlighted = id;
    if (memory.status == GaiaMemoryStatus.archived) _showArchived = true;
    if (memory.status == GaiaMemoryStatus.proposed) _showInbox = true;
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToHighlight(0));
  }

  /// Scrolls to the highlighted card. The lists build their cards lazily, so
  /// one far down isn't built yet: the tab steps down a screen at a time
  /// until it is.
  void _scrollToHighlight(int steps) {
    if (!mounted || _highlighted == null) return;
    final card = _highlightKey.currentContext;
    if (card != null) {
      unawaited(
        Scrollable.ensureVisible(
          card,
          alignment: 0.3,
          duration: GaiaMotion.quick,
        ),
      );
      return;
    }
    final search = _searchKey.currentContext;
    if (search == null || steps > 200) return;
    final position = Scrollable.of(search).position;
    if (steps == 0) {
      position.jumpTo(0);
    } else if (position.pixels >= position.maxScrollExtent) {
      return;
    } else {
      position.jumpTo(
        (position.pixels + position.viewportDimension * 0.8).clamp(
          0,
          position.maxScrollExtent,
        ),
      );
    }
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _scrollToHighlight(steps + 1),
    );
  }

  @override
  Widget build(BuildContext context) {
    final list = _controller.memoryList;
    if (list == null) {
      return const GaiaPanelScroll(
        slivers: [SliverToBoxAdapter(child: SizedBox.shrink())],
      );
    }
    if (_controller.review case final review?) {
      return GaiaMemoryReviewView(
        controller: _controller,
        review: review,
        chat: widget.askChat,
      );
    }
    _takeReveal(list);
    final tree = GaiaTopicTree(list.topics);
    final topic =
        _topic == null || _topic == _unsorted || tree.path(_topic!).isNotEmpty
        ? _topic
        : null;
    final query = _search.text.trim().toLowerCase();
    final named = {
      for (final topic in list.topics)
        if (query.isNotEmpty && topic.name.toLowerCase().contains(query))
          topic.id,
    };
    bool matches(GaiaMemory memory) =>
        query.isEmpty ||
        memory.text.toLowerCase().contains(query) ||
        memory.tags.any((tag) => tag.toLowerCase().contains(query)) ||
        memory.topicIds.any(named.contains);
    bool unsorted(GaiaMemory memory) =>
        memory.topicIds.every((id) => tree.path(id).isEmpty);
    // A memory dropped on a topic leaves the ones it has in the topic in
    // view's subtree, or every one it has from All and Unsorted.
    final moveWithin = topic == null || topic == _unsorted
        ? null
        : tree.subtree(topic);
    final scope = moveWithin == null || _subtopics ? moveWithin : {topic!};
    bool inScope(GaiaMemory memory) => switch (topic) {
      null => true,
      _unsorted => unsorted(memory),
      _ => memory.topicIds.any(scope!.contains),
    };
    final newest = list.memories.reversed;
    final inbox = [
      for (final memory in newest)
        // Across every topic, as on the page.
        if (memory.status == GaiaMemoryStatus.proposed && matches(memory))
          memory,
    ];
    List<GaiaMemory> filed(bool Function(GaiaMemory) test) => [
      for (final memory in newest)
        if (memory.status != GaiaMemoryStatus.proposed &&
            matches(memory) &&
            inScope(memory) &&
            test(memory))
          memory,
    ];
    final pinned = filed(
      (memory) => memory.status == GaiaMemoryStatus.active && memory.pinned,
    );
    final active = filed(
      (memory) => memory.status == GaiaMemoryStatus.active && !memory.pinned,
    );
    final archived = filed(
      (memory) => memory.status == GaiaMemoryStatus.archived,
    );
    final pins = [
      for (final pin in list.pins)
        if (matches(pin.memory)) pin,
    ];
    final merges = [
      for (final merge in list.merges)
        if (query.isEmpty ||
            named.contains(merge.from.id) ||
            named.contains(merge.into.id))
          merge,
    ];
    // What a chip counts and its topic shows: remembered and archived ones.
    final shelved = [
      for (final memory in list.memories)
        if (memory.status != GaiaMemoryStatus.proposed && matches(memory))
          memory,
    ];
    int count(String id) {
      final ids = tree.subtree(id);
      return shelved
          .where((memory) => memory.topicIds.any(ids.contains))
          .length;
    }

    final toSort = topic == _unsorted
        ? [...pinned, ...active, if (_showArchived) ...archived]
        : const <GaiaMemory>[];
    final sortedHere = [
      for (final memory in toSort)
        if (_controller.memorySorted.containsKey(memory.id)) memory.id,
    ];

    Widget card(GaiaMemory memory) => _MemoryCard(
      key: memory.id == _highlighted ? _highlightKey : ValueKey(memory.id),
      controller: _controller,
      memory: memory,
      tree: tree,
      moveWithin: moveWithin,
      newUnder: topic == null || topic == _unsorted ? null : topic,
      highlighted: memory.id == _highlighted,
      sorted: unsorted(memory) ? _controller.memorySorted[memory.id] : null,
      write: _write,
      run: _run,
    );

    // Built as they scroll in: a few hundred cards at once is a slow frame.
    Widget cards(List<GaiaMemory> memories) => SliverList.builder(
      itemCount: memories.length,
      itemBuilder: (context, i) => card(memories[i]),
    );
    final showInbox = _showInbox ?? (topic == null || query.isNotEmpty);

    final settings = _controller.settings;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyF, control: true):
            _searchFocus.requestFocus,
        const SingleActivator(LogicalKeyboardKey.f2): () {
          if (topic != null && topic != _unsorted) {
            setState(() => _renaming = topic);
          }
        },
      },
      // The tab's own scope, so its keys beat the shell's (Ctrl+F is Gaia's
      // chat search there), and a text box letting go leaves focus here.
      child: FocusScope(
        autofocus: true,
        child: GaiaPanelScroll(
          key: const PageStorageKey('gaia panel memories'),
          slivers: [
            const SliverToBoxAdapter(
              child: GaiaPanelNote(
                'Gaia adds the ones that fit to each message you send, '
                'whichever agent answers, and pinned ones go in every chat. Save '
                'one yourself with /remember. What Gaia offers, or notices once '
                'a chat goes quiet, waits in the inbox.',
              ),
            ),
            SliverToBoxAdapter(
              child: GaiaPanelSwitch(
                title: 'Keep what Gaia notices without asking',
                subtitle:
                    'What Gaia picks out of a chat once it goes quiet skips the '
                    'inbox. What an agent offers mid-chat still waits for you.',
                value: settings['autoAcceptCurator'] == true,
                onChanged: (value) => unawaited(
                  _run(
                    () => _controller.putSettings({'autoAcceptCurator': value}),
                    'Not saved',
                  ),
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(4, 12, 4, 4),
                child: GaiaTextField(
                  key: _searchKey,
                  controller: _search,
                  focusNode: _searchFocus,
                  hintText: 'Search memories and topics (Ctrl+F)',
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: _Breadcrumb(
                tree: tree,
                topic: topic,
                subtopics: _subtopics,
                onSubtopics: (value) => setState(() => _subtopics = value),
                onShow: _show,
                accepts: (dragged, onto) => _accepts(tree, dragged, onto),
                onDrop: (dragged, onto) => _drop(dragged, onto, moveWithin),
                // F2, or Rename on the chip before going in.
                rename: _renaming != null && _renaming == topic
                    ? _NameField(
                        key: ValueKey('rename crumb $topic'),
                        initial: tree[topic!]!.name,
                        onDone: (name) {
                          setState(() => _renaming = null);
                          if (name != null &&
                              name.isNotEmpty &&
                              name != tree[topic]?.name) {
                            unawaited(
                              _write('renameTopic', {
                                'topicId': topic,
                                'name': name,
                              }, failed: 'Not renamed'),
                            );
                          }
                        },
                      )
                    : null,
              ),
            ),
            SliverToBoxAdapter(
              child: _strip(
                tree,
                topic,
                list.projects,
                query,
                named,
                count,
                shelved.where(unsorted).length,
                moveWithin,
              ),
            ),
            SliverToBoxAdapter(
              child: _reviewBar(list, tree, topic, scope, unsorted),
            ),
            if (inbox.isNotEmpty || pins.isNotEmpty || merges.isNotEmpty) ...[
              SliverToBoxAdapter(
                child: GaiaPanelHeading(
                  key: _inboxKey,
                  'Inbox (${inbox.length + pins.length + merges.length})',
                  trailing: GaiaButton(
                    label: showInbox ? 'Hide' : 'Show',
                    size: 26,
                    padding: 10,
                    onPressed: () => setState(() => _showInbox = !showInbox),
                  ),
                ),
              ),
              if (showInbox) ...[
                SliverToBoxAdapter(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final merge in merges)
                        _SuggestionRow(
                          key: ValueKey(
                            'merge ${merge.from.id} ${merge.into.id}',
                          ),
                          icon: Icons.merge,
                          title:
                              'Merge "${tree.path(merge.from.id).join(' › ')}" '
                              'into "${tree.path(merge.into.id).join(' › ')}"?',
                          why: '${merge.why}.',
                          yes: 'Merge',
                          no: 'Keep both',
                          onYes: () => _write('mergeTopic', {
                            'topicId': merge.from.id,
                            'intoId': merge.into.id,
                          }, failed: "Couldn't merge"),
                          onNo: () => _write('keepApart', {
                            'topicId': merge.from.id,
                            'intoId': merge.into.id,
                          }),
                        ),
                      for (final pin in pins)
                        _SuggestionRow(
                          key: ValueKey('pin ${pin.memory.id}'),
                          icon: Icons.push_pin_outlined,
                          title: pin.memory.text,
                          why: 'Pin this? ${pin.why}.',
                          yes: 'Pin',
                          no: 'Not now',
                          onYes: () => _write('pinMemory', {
                            'memoryId': pin.memory.id,
                            'pinned': true,
                          }, failed: 'Not pinned'),
                          onNo: () =>
                              _write('pinLater', {'memoryId': pin.memory.id}),
                        ),
                    ],
                  ),
                ),
                cards(inbox),
              ],
            ],
            if (toSort.isNotEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(4, 14, 4, 0),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      GaiaButton(
                        label: _controller.memorySorting
                            ? 'Sorting…'
                            : 'Sort these',
                        icon: Icons.auto_awesome,
                        size: 30,
                        padding: 12,
                        onPressed: _controller.memorySorting
                            ? null
                            : () => unawaited(_controller.sortMemories(toSort)),
                      ),
                      if (sortedHere.isNotEmpty)
                        GaiaButton(
                          label: 'Accept all (${sortedHere.length})',
                          icon: Icons.done_all,
                          size: 30,
                          padding: 12,
                          onPressed: () async {
                            for (final id in sortedHere) {
                              if (!await _run(
                                () => _controller.acceptSorted(id),
                                "Couldn't file it",
                              )) {
                                break;
                              }
                            }
                          },
                        ),
                      if (_controller.memorySortError case final error?)
                        Text(
                          error,
                          style: GaiaType.label.copyWith(
                            color: kGaiaStatusRose,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            if (pinned.isNotEmpty) ...[
              SliverToBoxAdapter(
                child: GaiaPanelHeading('Pinned (${pinned.length})'),
              ),
              cards(pinned),
            ],
            SliverToBoxAdapter(
              child: GaiaPanelHeading(
                active.isEmpty ? 'Remembered' : 'Remembered (${active.length})',
              ),
            ),
            if (active.isEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
                  child: Text(
                    query.isEmpty ? 'Nothing here yet.' : 'Nothing matches.',
                    style: GaiaType.row.copyWith(color: GaiaInk.muted),
                  ),
                ),
              ),
            cards(active),
            if (archived.isNotEmpty) ...[
              SliverToBoxAdapter(
                child: GaiaPanelHeading(
                  'Archived (${archived.length})',
                  trailing: GaiaButton(
                    label: _showArchived ? 'Hide' : 'Show',
                    size: 26,
                    padding: 10,
                    onPressed: () =>
                        setState(() => _showArchived = !_showArchived),
                  ),
                ),
              ),
              if (_showArchived) cards(archived),
            ],
          ],
        ),
      ),
    );
  }

  /// The review bar (GAIA_SETTINGS_HLD.md §5.2 item 4): what's waiting in
  /// the inbox with Review, and Review these for the topic in view's
  /// remembered memories, or Unsorted's. Counted without the search.
  Widget _reviewBar(
    GaiaMemoryList list,
    GaiaTopicTree tree,
    String? topic,
    Set<String>? scope,
    bool Function(GaiaMemory memory) unsorted,
  ) {
    final waiting = list.memories
        .where((memory) => memory.status == GaiaMemoryStatus.proposed)
        .length;
    final suggestions = list.pins.length + list.merges.length;
    final here = topic == null
        ? 0
        : list.memories
              .where(
                (memory) =>
                    memory.status == GaiaMemoryStatus.active &&
                    (topic == _unsorted
                        ? unsorted(memory)
                        : memory.topicIds.any(scope!.contains)),
              )
              .length;
    if (waiting + suggestions == 0 && here == 0) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 10, 4, 0),
      child: Wrap(
        spacing: 10,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (waiting + suggestions > 0) ...[
            Text(
              [
                if (waiting > 0) '$waiting in the inbox',
                if (suggestions > 0)
                  '$suggestions ${suggestions == 1 ? 'suggestion' : 'suggestions'}',
              ].join(' · '),
              style: GaiaType.row.copyWith(color: GaiaInk.dim),
            ),
            GaiaButton(
              label: 'Review',
              icon: Icons.style_outlined,
              size: 30,
              padding: 12,
              onPressed: () =>
                  _controller.startReview(GaiaMemoryReview.inbox(_controller)),
            ),
          ],
          if (here > 0)
            GaiaButton(
              label: 'Review these ($here)',
              size: 30,
              padding: 12,
              color: GaiaInk.muted,
              onPressed: () => _controller.startReview(
                topic == _unsorted
                    ? GaiaMemoryReview.unsorted(_controller)
                    : GaiaMemoryReview.topic(
                        _controller,
                        scope!,
                        tree.path(topic!).join(' › '),
                      ),
              ),
            ),
        ],
      ),
    );
  }

  /// The topic in view's subtopics as chips (the roots at the top), then
  /// Unsorted at the root and + Topic. A search keeps the chips holding
  /// something it finds, or named by it.
  Widget _strip(
    GaiaTopicTree tree,
    String? topic,
    Set<String> projects,
    String query,
    Set<String> named,
    int Function(String id) count,
    int unsortedCount,
    Set<String>? moveWithin,
  ) {
    if (topic == _unsorted) return const SizedBox(height: 4);
    final children = [
      for (final child in tree.childrenOf(topic))
        if (query.isEmpty ||
            count(child.id) > 0 ||
            tree.subtree(child.id).any(named.contains))
          child,
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 2, 4, 4),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          for (final child in children)
            if (_renaming == child.id)
              _NameField(
                key: ValueKey('rename ${child.id}'),
                initial: child.name,
                onDone: (name) {
                  setState(() => _renaming = null);
                  if (name != null && name != child.name) {
                    unawaited(
                      _write('renameTopic', {
                        'topicId': child.id,
                        'name': name,
                      }, failed: 'Not renamed'),
                    );
                  }
                },
              )
            else
              _TopicStripChip(
                key: ValueKey(child.id),
                label: child.name,
                count: count(child.id),
                drag: _DraggedTopic(child.id),
                onTap: () => _show(child.id),
                onMenu: (position) => showGaiaMenu(
                  context,
                  position,
                  _topicMenu(tree, child, projects),
                ),
                accepts: (dragged) => _accepts(tree, dragged, child.id),
                onDrop: (dragged) => _drop(dragged, child.id, moveWithin),
              ),
          if (topic == null)
            _TopicStripChip(
              label: 'Unsorted',
              count: unsortedCount,
              icon: Icons.inbox_outlined,
              onTap: () => _show(_unsorted),
            ),
          if (_naming)
            _NameField(
              key: const ValueKey('new topic'),
              initial: '',
              hint: topic == null ? 'New topic' : 'New subtopic',
              onDone: (name) async {
                setState(() => _naming = false);
                if (name == null || name.isEmpty) return;
                await _write('newTopic', {
                  'name': name,
                  'parentId': ?topic,
                }, failed: 'No topic made');
              },
            )
          else
            _TopicStripChip(
              label: topic == null ? '+ Topic' : '+ Subtopic',
              onTap: () => setState(() => _naming = true),
            ),
        ],
      ),
    );
  }

  /// A topic chip's right-click menu. A project's topic can be merged into,
  /// not merged away, and goes when its project is deleted
  /// (GAIA_MEMORY_TOPICS_HLD.md §7).
  List<GaiaMenuItem> _topicMenu(
    GaiaTopicTree tree,
    GaiaMemoryTopic topic,
    Set<String> projects,
  ) {
    final linked = projects.contains(topic.projectId);
    return [
      GaiaMenuItem(
        label: 'Rename',
        icon: Icons.edit_outlined,
        onPressed: () => setState(() => _renaming = topic.id),
      ),
      GaiaMenuItem(
        label: 'New subtopic',
        icon: Icons.add,
        onPressed: () => setState(() {
          _show(topic.id);
          _naming = true;
        }),
      ),
      GaiaMenuItem(
        label: 'Move under…',
        icon: Icons.subdirectory_arrow_right,
        onPressed: () => unawaited(_moveUnder(tree, topic)),
      ),
      if (!linked) ...[
        GaiaMenuItem(
          label: 'Merge into…',
          icon: Icons.merge,
          onPressed: () => unawaited(_merge(tree, topic)),
        ),
        GaiaMenuItem(
          label: 'Delete',
          icon: Icons.delete_outline,
          destructive: true,
          onPressed: () => unawaited(_delete(tree, topic)),
        ),
      ] else
        GaiaMenuItem(
          label: "A project's topic",
          detail: 'goes with its project',
          icon: Icons.folder_outlined,
          onPressed: () {},
        ),
    ];
  }

  List<GaiaTopicLine> _lines(
    GaiaTopicTree tree, {
    Set<String> except = const {},
  }) => [
    for (final line in gaiaTopicLines(tree))
      if (!except.contains(line.id)) line,
  ];

  Future<void> _moveUnder(GaiaTopicTree tree, GaiaMemoryTopic topic) async {
    final pick = await showGaiaTopicPicker(
      context,
      title: 'Move "${topic.name}" under',
      topics: _lines(tree, except: tree.subtree(topic.id)),
      topLevel: true,
    );
    if (pick == null) return;
    await _write('moveTopic', {
      'topicId': topic.id,
      'parentId': pick.topicId,
    }, failed: 'Not moved');
  }

  Future<void> _merge(GaiaTopicTree tree, GaiaMemoryTopic topic) async {
    final pick = await showGaiaTopicPicker(
      context,
      title: 'Merge "${topic.name}" into',
      topics: _lines(tree, except: {topic.id}),
    );
    final into = pick?.topicId;
    if (into == null || !mounted) return;
    final kept = tree.path(into).join(' › ');
    final confirmed = await _confirm(
      context,
      title: 'Merge "${topic.name}" into "$kept"?',
      message:
          'Its memories and subtopics move to $kept, and "${topic.name}" '
          'goes to the trash.',
      confirm: 'Merge',
    );
    if (!confirmed) return;
    if (await _write('mergeTopic', {
      'topicId': topic.id,
      'intoId': into,
    }, failed: "Couldn't merge")) {
      _show(into);
    }
  }

  Future<void> _delete(GaiaTopicTree tree, GaiaMemoryTopic topic) async {
    final parent = tree.parentOf(topic.id);
    final confirmed = await _confirm(
      context,
      title: 'Delete "${topic.name}"?',
      message: [
        'Its memories stay in their other topics, or go to Unsorted.',
        if (tree.childrenOf(topic.id).isNotEmpty)
          'Its subtopics move up to '
              '${parent == null ? 'the top level' : tree.path(parent).last}.',
      ].join(' '),
      confirm: 'Delete',
    );
    if (!confirmed) return;
    await _write('deleteTopic', {'topicId': topic.id}, failed: 'Not deleted');
  }

  /// Whether [dragged] can go onto [onto] (null for the root): a memory onto
  /// any topic; a topic not under itself or where it already is.
  bool _accepts(GaiaTopicTree tree, _Dragged dragged, String? onto) =>
      switch (dragged) {
        _DraggedMemory() => onto != null,
        _DraggedTopic(:final id) =>
          id != onto &&
              tree.parentOf(id) != onto &&
              (onto == null || !tree.subtree(id).contains(onto)),
      };

  /// A memory dropped onto topic [onto] moves there, or with Ctrl is added;
  /// a topic goes under it, or to the root for null.
  void _drop(_Dragged dragged, String? onto, Set<String>? moveWithin) =>
      unawaited(switch (dragged) {
        _DraggedMemory(:final id) when onto != null =>
          HardwareKeyboard.instance.isControlPressed
              ? _write('addMemoryTopic', {'memoryId': id, 'topicId': onto})
              : _write('moveMemory', {
                  'memoryId': id,
                  'topicId': onto,
                  'within': ?moveWithin?.toList(),
                }),
        _DraggedTopic(:final id) => _write('moveTopic', {
          'topicId': id,
          'parentId': onto,
        }, failed: 'Not moved'),
        _ => Future<bool>.value(false),
      });
}

/// Confirms something destructive, drawn as the panel's other dialogs.
Future<bool> _confirm(
  BuildContext context, {
  required String title,
  required String message,
  required String confirm,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          GaiaButton(
            label: 'Cancel',
            onPressed: () => Navigator.of(context).pop(false),
          ),
          GaiaButton(
            label: confirm,
            color: kGaiaStatusRose,
            onPressed: () => Navigator.of(context).pop(true),
          ),
        ],
      ),
    ) ??
    false;

/// The breadcrumb: All memories › CS246 › Assignments, each crumb a click
/// back to it and a place to drop a memory or topic. With a topic in view,
/// whether its subtopics' memories show too.
class _Breadcrumb extends StatelessWidget {
  const _Breadcrumb({
    required this.tree,
    required this.topic,
    required this.subtopics,
    required this.onSubtopics,
    required this.onShow,
    required this.accepts,
    required this.onDrop,
    this.rename,
  });

  /// The topic in view's name being typed, in place of its crumb.
  final Widget? rename;
  final GaiaTopicTree tree;
  final String? topic;
  final bool subtopics;
  final ValueChanged<bool> onSubtopics;
  final ValueChanged<String?> onShow;
  final bool Function(_Dragged dragged, String? onto) accepts;
  final void Function(_Dragged dragged, String? onto) onDrop;

  @override
  Widget build(BuildContext context) {
    final topic = this.topic;
    final ids = <String>[
      if (topic != null && topic != _unsorted)
        for (String? at = topic; at != null; at = tree.parentOf(at)) at,
    ].reversed.toList();
    final separator = Text(
      '›',
      style: GaiaType.row.copyWith(color: GaiaInk.faint),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 10, 4, 4),
      child: Row(
        children: [
          Expanded(
            child: Wrap(
              spacing: 4,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _Crumb(
                  label: 'All memories',
                  current: topic == null,
                  onTap: () => onShow(null),
                  accepts: (dragged) =>
                      dragged is _DraggedTopic && accepts(dragged, null),
                  onDrop: (dragged) => onDrop(dragged, null),
                ),
                if (topic == _unsorted) ...[
                  separator,
                  _Crumb(label: 'Unsorted', current: true, onTap: () {}),
                ],
                for (final id in ids) ...[
                  separator,
                  if (id == topic && rename != null)
                    rename!
                  else
                    _Crumb(
                      label: tree[id]!.name,
                      current: id == topic,
                      onTap: () => onShow(id),
                      accepts: (dragged) => accepts(dragged, id),
                      onDrop: (dragged) => onDrop(dragged, id),
                    ),
                ],
              ],
            ),
          ),
          if (topic != null &&
              topic != _unsorted &&
              tree.childrenOf(topic).isNotEmpty)
            GaiaPanelChoice(
              label: 'Include subtopics',
              selected: subtopics,
              onTap: () => onSubtopics(!subtopics),
            ),
        ],
      ),
    );
  }
}

class _Crumb extends StatefulWidget {
  const _Crumb({
    required this.label,
    required this.current,
    required this.onTap,
    this.accepts,
    this.onDrop,
  });

  final String label;
  final bool current;
  final VoidCallback onTap;
  final bool Function(_Dragged dragged)? accepts;
  final ValueChanged<_Dragged>? onDrop;

  @override
  State<_Crumb> createState() => _CrumbState();
}

class _CrumbState extends State<_Crumb> {
  var _hovered = false;

  @override
  Widget build(BuildContext context) {
    Widget crumb(bool over) => MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: GaiaMotion.quick,
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
          decoration: BoxDecoration(
            color: over || _hovered
                ? GaiaInk.hover
                : GaiaInk.hover.withValues(alpha: 0),
            borderRadius: BorderRadius.circular(GaiaRadius.chip),
            border: Border.all(
              color: over
                  ? Theme.of(context).colorScheme.primary
                  : Colors.transparent,
            ),
          ),
          child: Text(
            widget.label,
            style: GaiaType.row.copyWith(
              color: widget.current || _hovered
                  ? GaiaInk.bright
                  : GaiaInk.muted,
            ),
          ),
        ),
      ),
    );
    final accepts = widget.accepts;
    if (accepts == null) return crumb(false);
    return DragTarget<_Dragged>(
      onWillAcceptWithDetails: (details) => accepts(details.data),
      onAcceptWithDetails: (details) => widget.onDrop!(details.data),
      builder: (context, candidates, _) => crumb(candidates.isNotEmpty),
    );
  }
}

/// A chip in the topic strip: its name and count. A click goes into it; a
/// right-click opens [onMenu]; with [drag], it can be dragged onto another
/// topic, and it takes a memory or topic dropped on it.
class _TopicStripChip extends StatefulWidget {
  const _TopicStripChip({
    super.key,
    required this.label,
    required this.onTap,
    this.count,
    this.icon,
    this.drag,
    this.onMenu,
    this.accepts,
    this.onDrop,
  });

  final String label;
  final int? count;
  final IconData? icon;
  final VoidCallback onTap;
  final _Dragged? drag;
  final void Function(Offset position)? onMenu;
  final bool Function(_Dragged dragged)? accepts;
  final ValueChanged<_Dragged>? onDrop;

  @override
  State<_TopicStripChip> createState() => _TopicStripChipState();
}

class _TopicStripChipState extends State<_TopicStripChip> {
  var _hovered = false;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    Widget chip(bool over) => MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        onSecondaryTapUp: widget.onMenu == null
            ? null
            : (details) => widget.onMenu!(details.globalPosition),
        child: AnimatedContainer(
          duration: GaiaMotion.quick,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: over || _hovered
                ? GaiaInk.hover
                : GaiaInk.hover.withValues(alpha: 0),
            borderRadius: BorderRadius.circular(GaiaRadius.chip),
            border: Border.all(color: over ? accent : GaiaInk.hairline),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.icon case final icon?) ...[
                Icon(
                  icon,
                  size: 13,
                  color: _hovered ? GaiaInk.bright : GaiaInk.muted,
                ),
                const SizedBox(width: 5),
              ],
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 220),
                child: Text(
                  widget.label,
                  overflow: TextOverflow.ellipsis,
                  style: GaiaType.row.copyWith(
                    color: _hovered ? GaiaInk.bright : GaiaInk.dim,
                  ),
                ),
              ),
              if (widget.count case final count?) ...[
                const SizedBox(width: 6),
                Text(
                  '$count',
                  style: GaiaType.label.copyWith(color: GaiaInk.faint),
                ),
              ],
            ],
          ),
        ),
      ),
    );
    final accepts = widget.accepts;
    Widget target = accepts == null
        ? chip(false)
        : DragTarget<_Dragged>(
            onWillAcceptWithDetails: (details) => accepts(details.data),
            onAcceptWithDetails: (details) => widget.onDrop!(details.data),
            builder: (context, candidates, _) => chip(candidates.isNotEmpty),
          );
    if (widget.drag case final drag?) {
      target = Draggable<_Dragged>(
        data: drag,
        dragAnchorStrategy: pointerDragAnchorStrategy,
        feedback: _dragLabel(context, widget.label),
        child: target,
      );
    }
    return target;
  }
}

/// A name typed in place: a topic renamed on its chip, or a new one in the
/// strip. Enter or a click away gives the name, Esc null.
class _NameField extends StatefulWidget {
  const _NameField({
    super.key,
    required this.initial,
    required this.onDone,
    this.hint,
  });

  final String initial;
  final String? hint;
  final ValueChanged<String?> onDone;

  @override
  State<_NameField> createState() => _NameFieldState();
}

class _NameFieldState extends State<_NameField> {
  late final _text = TextEditingController(text: widget.initial)
    ..selection = TextSelection(
      baseOffset: 0,
      extentOffset: widget.initial.length,
    );
  late final _focus = FocusNode(
    debugLabel: 'gaia topic name',
    onKeyEvent: (node, event) {
      if (event is! KeyDownEvent) return KeyEventResult.ignored;
      if (event.logicalKey == LogicalKeyboardKey.escape) {
        _finish(null);
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.enter ||
          event.logicalKey == LogicalKeyboardKey.numpadEnter) {
        _finish(_text.text.trim());
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    },
  );
  var _done = false;

  void _finish(String? name) {
    if (_done) return;
    _done = true;
    widget.onDone(name);
  }

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus) _finish(_text.text.trim());
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 200,
    child: GaiaTextField(
      controller: _text,
      focusNode: _focus,
      hintText: widget.hint,
    ),
  );
}

/// What follows the pointer while a card or chip is dragged.
Widget _dragLabel(BuildContext context, String text) => Transform.translate(
  offset: const Offset(14, -12),
  child: Container(
    constraints: const BoxConstraints(maxWidth: 260),
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: gaiaFloating(
      Theme.of(context).colorScheme,
      radius: GaiaRadius.row,
    ),
    child: Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: GaiaType.label.copyWith(
        color: GaiaInk.bright,
        decoration: TextDecoration.none,
      ),
    ),
  ),
);

/// A pin or merge suggestion in the inbox: what it is, why, and its two
/// answers.
class _SuggestionRow extends StatefulWidget {
  const _SuggestionRow({
    super.key,
    required this.icon,
    required this.title,
    required this.why,
    required this.yes,
    required this.no,
    required this.onYes,
    required this.onNo,
  });

  final IconData icon;
  final String title;
  final String why;
  final String yes;
  final String no;
  final Future<void> Function() onYes;
  final Future<void> Function() onNo;

  @override
  State<_SuggestionRow> createState() => _SuggestionRowState();
}

class _SuggestionRowState extends State<_SuggestionRow> {
  var _hovered = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
    onEnter: (_) => setState(() => _hovered = true),
    onExit: (_) => setState(() => _hovered = false),
    child: AnimatedContainer(
      duration: GaiaMotion.quick,
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
      decoration: BoxDecoration(
        color: _hovered ? GaiaInk.hover : GaiaInk.hover.withValues(alpha: 0),
        borderRadius: BorderRadius.circular(GaiaRadius.row),
      ),
      child: Row(
        children: [
          Icon(widget.icon, size: 16, color: kGaiaAstralGold),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.title,
                  style: GaiaType.row.copyWith(
                    color: _hovered ? GaiaInk.bright : GaiaInk.dim,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  widget.why,
                  style: GaiaType.label.copyWith(color: GaiaInk.muted),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          GaiaButton(
            label: widget.no,
            size: 28,
            padding: 10,
            color: GaiaInk.muted,
            onPressed: () => unawaited(widget.onNo()),
          ),
          const SizedBox(width: 6),
          GaiaButton(
            label: widget.yes,
            size: 28,
            padding: 10,
            onPressed: () => unawaited(widget.onYes()),
          ),
        ],
      ),
    ),
  );
}

/// A memory's card in the list (GAIA_SETTINGS_HLD.md §5.3): its text, a
/// click to edit it in place with its tags; its topics as the chat's memory
/// card shows them, a click taking one out, + Topic adding one through the
/// topic picker, and a new topic offered. Where it came from and when.
/// On hover: Suggest topics, pin, its main action (Remember, Archive,
/// Remember again), Dismiss or Delete with an undo, and a menu. Dragged
/// onto a topic, it moves there.
class _MemoryCard extends StatefulWidget {
  const _MemoryCard({
    super.key,
    required this.controller,
    required this.memory,
    required this.tree,
    required this.moveWithin,
    required this.newUnder,
    required this.highlighted,
    required this.sorted,
    required this.write,
    required this.run,
  });

  final GaiaController controller;
  final GaiaMemory memory;
  final GaiaTopicTree tree;
  final Set<String>? moveWithin;

  /// The topic in view, which a new topic named in the picker goes under.
  final String? newUnder;
  final bool highlighted;

  /// Where Sort these would file it; null for nowhere.
  final GaiaPlacement? sorted;
  final Future<bool> Function(
    String method,
    Map<String, Object?> params, {
    String failed,
  })
  write;
  final Future<bool> Function(Future<void> Function() action, String failed)
  run;

  @override
  State<_MemoryCard> createState() => _MemoryCardState();
}

class _MemoryCardState extends State<_MemoryCard> {
  var _hovered = false;
  var _suggesting = false;

  /// The text and tags being edited in place; null when not editing.
  ({TextEditingController text, TextEditingController tags})? _editing;
  final _editFocus = FocusNode(debugLabel: 'gaia memory edit');

  GaiaMemory get _memory => widget.memory;

  @override
  void dispose() {
    _editing?.text.dispose();
    _editing?.tags.dispose();
    _editFocus.dispose();
    super.dispose();
  }

  void _startEdit() {
    setState(
      () => _editing = (
        text: TextEditingController(text: _memory.text)
          ..selection = TextSelection.collapsed(offset: _memory.text.length),
        tags: TextEditingController(text: _memory.tags.join(', ')),
      ),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _editFocus.requestFocus();
    });
  }

  void _endEdit({required bool save}) {
    final editing = _editing;
    if (editing == null) return;
    final text = editing.text.text.trim();
    final tags = editing.tags.text.split(',');
    setState(() => _editing = null);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      editing.text.dispose();
      editing.tags.dispose();
    });
    if (!save || text.isEmpty) return;
    unawaited(
      widget.write('editMemory', {
        'memoryId': _memory.id,
        'text': text,
        'tags': tags,
      }, failed: 'Not saved'),
    );
  }

  /// Enter saves (Shift+Enter is a newline in the text), Esc cancels.
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

  Future<void> _delete() async {
    final proposed = _memory.status == GaiaMemoryStatus.proposed;
    final id = _memory.id;
    final controller = widget.controller;
    if (!await widget.write('deleteMemory', {'memoryId': id})) return;
    if (!mounted) return;
    showGaiaToast(
      context,
      mark: GaiaToastMark.done,
      title: proposed ? 'Dismissed' : 'Deleted',
      body: 'Click to undo.',
      onTap: () => unawaited(
        controller.writeMemories('undeleteMemory', {'memoryId': id}).catchError(
          (Object error) {
            debugPrint('[gaia] memory not restored: $error');
            return null;
          },
        ),
      ),
    );
  }

  Future<void> _suggest() async {
    setState(() => _suggesting = true);
    final said = await widget.controller.suggestTopics(_memory);
    if (!mounted) return;
    setState(() => _suggesting = false);
    if (said != null) {
      showGaiaToast(
        context,
        mark: GaiaToastMark.info,
        title: 'No topic',
        body: said,
      );
    }
  }

  /// + Topic: a topic picked, or a new one named, which is made under the
  /// topic in view first.
  Future<void> _addTopic() async {
    final tree = widget.tree;
    final pick = await showGaiaTopicPicker(
      context,
      title: 'Add to topic',
      topics: [
        for (final line in gaiaTopicLines(tree))
          if (!_memory.topicIds.contains(line.id)) line,
      ],
      newUnder: widget.newUnder == null
          ? ''
          : tree.path(widget.newUnder!).join(' › '),
    );
    if (pick == null) return;
    var topicId = pick.topicId;
    if (pick.newName case final name?) {
      await widget.run(() async {
        topicId =
            await widget.controller.writeMemories('newTopic', {
                  'name': name,
                  'parentId': ?widget.newUnder,
                })
                as String?;
      }, 'No topic made');
    }
    if (topicId == null) return;
    await widget.write('addMemoryTopic', {
      'memoryId': _memory.id,
      'topicId': topicId,
    });
  }

  /// Move to topic…: out of its topics in the topic in view (all of them
  /// from All memories), into the one picked.
  Future<void> _moveTo() async {
    final pick = await showGaiaTopicPicker(
      context,
      title: 'Move to topic',
      topics: gaiaTopicLines(widget.tree),
    );
    final topicId = pick?.topicId;
    if (topicId == null) return;
    await widget.write('moveMemory', {
      'memoryId': _memory.id,
      'topicId': topicId,
      'within': ?widget.moveWithin?.toList(),
    });
  }

  /// Ask Gaia (GAIA_SETTINGS_HLD.md §7.1): this memory as a one-card review,
  /// its chat open.
  void _askGaia() => widget.controller.startReview(
    GaiaMemoryReview.memory(widget.controller, _memory),
  );

  List<GaiaMenuItem> _menu() {
    final memory = _memory;
    final chatId = memory.sourceChatId;
    final proposed = memory.status == GaiaMemoryStatus.proposed;
    return [
      if (chatId != null &&
          widget.controller.chats.any((chat) => chat.id == chatId))
        GaiaMenuItem(
          label: 'Open its chat',
          icon: Icons.chat_bubble_outline,
          onPressed: () => unawaited(widget.controller.selectChat(chatId)),
        ),
      GaiaMenuItem(
        label: 'Edit',
        icon: Icons.edit_outlined,
        onPressed: _startEdit,
      ),
      if (memory.status != GaiaMemoryStatus.archived)
        GaiaMenuItem(
          label: 'Ask Gaia',
          icon: Icons.forum_outlined,
          onPressed: _askGaia,
        ),
      if (proposed)
        GaiaMenuItem(
          label: 'Remember and pin',
          icon: Icons.push_pin_outlined,
          onPressed: () => unawaited(
            widget.run(
              () => widget.controller.rememberMemory(memory, pin: true),
              "Couldn't remember it",
            ),
          ),
        ),
      if (widget.tree.childrenOf(null).isNotEmpty)
        GaiaMenuItem(
          label: 'Move to topic…',
          icon: Icons.drive_file_move_outline,
          onPressed: () => unawaited(_moveTo()),
        ),
      GaiaMenuItem(
        label: proposed ? 'Dismiss' : 'Delete',
        icon: proposed ? Icons.close : Icons.delete_outline,
        destructive: true,
        onPressed: () => unawaited(_delete()),
      ),
    ];
  }

  Widget _chips(ThemeData theme) {
    final memory = _memory;
    final tree = widget.tree;
    final label = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.primary,
      fontWeight: FontWeight.bold,
    );
    final background = theme.scaffoldBackgroundColor;
    final suggested = memory.suggestedTopic;
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final id in memory.topicIds)
          if (tree.path(id) case final path when path.isNotEmpty)
            GaiaTopicChip(
              label: path.join(' › '),
              style: label,
              background: background,
              tooltip: 'Remove from topic',
              removes: true,
              onTap: () => unawaited(
                widget.write('removeMemoryTopic', {
                  'memoryId': memory.id,
                  'topicId': id,
                }),
              ),
            ),
        if (suggested != null) ...[
          GaiaTopicChip(
            label: 'New topic: ${gaiaSuggestedTopicLabel(suggested, tree)}',
            style: label,
            background: background,
            checked: false,
            tooltip: 'Make this topic and file it there',
            onTap: () => unawaited(
              widget.write('acceptSuggestedTopic', {'memoryId': memory.id}),
            ),
          ),
          GaiaTopicChip(
            label: '✕',
            style: label,
            background: background,
            tooltip: "Don't make it",
            removes: true,
            onTap: () => unawaited(
              widget.write('dropSuggestedTopic', {'memoryId': memory.id}),
            ),
          ),
        ],
        GaiaTopicChip(
          label: '+ Topic',
          style: label,
          background: background,
          onTap: () => unawaited(_addTopic()),
        ),
      ],
    );
  }

  /// Sort these's suggestion: each topic and any new one, a click leaving
  /// it out, then Accept or Skip.
  Widget _sortedLine(ThemeData theme, GaiaPlacement placement) {
    final controller = widget.controller;
    final tree = widget.tree;
    final label = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.primary,
      fontWeight: FontWeight.bold,
    );
    final background = theme.scaffoldBackgroundColor;
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(
          'Suggested:',
          style: GaiaType.label.copyWith(color: GaiaInk.muted),
        ),
        for (final id in placement.topicIds)
          if (tree.path(id) case final path when path.isNotEmpty)
            GaiaTopicChip(
              label: path.join(' › '),
              style: label,
              background: background,
              tooltip: 'Leave this topic out',
              removes: true,
              onTap: () => controller.changeSorted(_memory.id, (
                topicIds: [
                  for (final other in placement.topicIds)
                    if (other != id) other,
                ],
                suggested: placement.suggested,
                tags: placement.tags,
              )),
            ),
        if (placement.suggested case final offer?)
          GaiaTopicChip(
            label: 'New topic: ${gaiaSuggestedTopicLabel(offer, tree)}',
            style: label,
            background: background,
            tooltip: "Don't make it",
            removes: true,
            onTap: () => controller.changeSorted(_memory.id, (
              topicIds: placement.topicIds,
              suggested: null,
              tags: placement.tags,
            )),
          ),
        GaiaButton(
          label: 'Accept',
          size: 24,
          padding: 8,
          onPressed: () => unawaited(
            widget.run(
              () => controller.acceptSorted(_memory.id),
              "Couldn't file it",
            ),
          ),
        ),
        GaiaButton(
          label: 'Skip',
          size: 24,
          padding: 8,
          color: GaiaInk.muted,
          onPressed: () => controller.changeSorted(_memory.id),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final memory = _memory;
    final controller = widget.controller;
    final editing = _editing;
    final proposed = memory.status == GaiaMemoryStatus.proposed;
    final chat = memory.sourceChatId == null
        ? null
        : controller.chats
              .where((chat) => chat.id == memory.sourceChatId)
              .firstOrNull;
    final unsorted = memory.topicIds.every(
      (id) => widget.tree.path(id).isEmpty,
    );
    final shown = _hovered && editing == null;
    final (primaryIcon, primaryLabel, primary) = switch (memory.status) {
      GaiaMemoryStatus.proposed => (
        Icons.check,
        'Remember',
        () => widget.run(
          () => controller.rememberMemory(memory),
          "Couldn't remember it",
        ),
      ),
      GaiaMemoryStatus.active => (
        Icons.archive_outlined,
        'Archive',
        () => widget.write('archiveMemory', {'memoryId': memory.id}),
      ),
      GaiaMemoryStatus.archived => (
        Icons.unarchive_outlined,
        'Remember again',
        () => widget.write('unarchiveMemory', {
          'memoryId': memory.id,
        }, failed: 'Not remembered'),
      ),
    };
    final faded = memory.status == GaiaMemoryStatus.archived;
    final body = AnimatedContainer(
      duration: GaiaMotion.quick,
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
      decoration: BoxDecoration(
        color: _hovered ? GaiaInk.hover : GaiaInk.hover.withValues(alpha: 0),
        borderRadius: BorderRadius.circular(GaiaRadius.row),
        border: Border.all(
          color: widget.highlighted
              ? theme.colorScheme.primary
              : GaiaInk.hairline.withValues(alpha: 0),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(
              proposed
                  ? Icons.bookmark_add_outlined
                  : memory.pinned
                  ? Icons.push_pin
                  : Icons.bookmark_outline,
              size: 16,
              color: proposed || memory.pinned
                  ? gaiaAstralGoldFor(theme.brightness)
                  : GaiaInk.faint,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (editing != null)
                  Focus(
                    onKeyEvent: _onEditKey,
                    onFocusChange: (focused) {
                      // A click away keeps what was typed.
                      if (!focused && _editing == editing) {
                        _endEdit(save: true);
                      }
                    },
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        GaiaCardTextField(
                          controller: editing.text,
                          focusNode: _editFocus,
                          maxLines: 6,
                          style: GaiaType.row.copyWith(color: GaiaInk.bright),
                        ),
                        const SizedBox(height: 6),
                        GaiaCardTextField(
                          controller: editing.tags,
                          labelText: 'Tags, separated by commas',
                          style: GaiaType.label.copyWith(color: GaiaInk.bright),
                        ),
                      ],
                    ),
                  )
                else
                  MouseRegion(
                    cursor: SystemMouseCursors.text,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: _startEdit,
                      child: Text(
                        memory.text,
                        style: GaiaType.row.copyWith(
                          color: faded
                              ? GaiaInk.muted
                              : _hovered
                              ? GaiaInk.bright
                              : GaiaInk.dim,
                        ),
                      ),
                    ),
                  ),
                const SizedBox(height: 3),
                Row(
                  children: [
                    if (memory.tags.isNotEmpty)
                      Flexible(
                        child: Text(
                          '${memory.tags.map((tag) => '#$tag').join(' ')} · ',
                          overflow: TextOverflow.ellipsis,
                          style: GaiaType.label.copyWith(color: GaiaInk.faint),
                        ),
                      ),
                    if (chat != null)
                      Flexible(
                        child: _ChatLink(
                          title: chat.title.isEmpty
                              ? 'Untitled chat'
                              : chat.title,
                          onTap: () =>
                              unawaited(controller.selectChat(chat.id)),
                        ),
                      ),
                    Text(
                      '${chat == null ? '' : ' · '}'
                      '${DateFormat.yMMMd().format(memory.createdAt.toLocal())}',
                      style: GaiaType.label.copyWith(color: GaiaInk.faint),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                _chips(theme),
                if (widget.sorted case final placement?) ...[
                  const SizedBox(height: 6),
                  _sortedLine(theme, placement),
                ],
              ],
            ),
          ),
          const SizedBox(width: 6),
          AnimatedOpacity(
            duration: GaiaMotion.quick,
            opacity: shown ? 1 : 0,
            child: IgnorePointer(
              ignoring: !shown,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Unsorted with nothing offered: the utility model can
                  // file it.
                  if (unsorted &&
                      memory.suggestedTopic == null &&
                      widget.sorted == null)
                    GaiaActionIcon(
                      label: _suggesting ? 'Suggesting…' : 'Suggest topics',
                      icon: Icons.auto_awesome,
                      compact: true,
                      onPressed: _suggesting ? null : _suggest,
                    ),
                  if (memory.status == GaiaMemoryStatus.active || memory.pinned)
                    GaiaActionIcon(
                      label: memory.pinned ? 'Unpin' : 'Pin to every chat',
                      icon: memory.pinned
                          ? Icons.push_pin
                          : Icons.push_pin_outlined,
                      compact: true,
                      onPressed: () => unawaited(
                        widget.write('pinMemory', {
                          'memoryId': memory.id,
                          'pinned': !memory.pinned,
                        }, failed: 'Not pinned'),
                      ),
                    ),
                  if (memory.status != GaiaMemoryStatus.archived)
                    GaiaActionIcon(
                      label: 'Ask Gaia',
                      icon: Icons.forum_outlined,
                      compact: true,
                      onPressed: _askGaia,
                    ),
                  GaiaActionIcon(
                    label: primaryLabel,
                    icon: primaryIcon,
                    compact: true,
                    onPressed: () => unawaited(primary()),
                  ),
                  GaiaActionIcon(
                    label: proposed ? 'Dismiss' : 'Delete',
                    icon: proposed ? Icons.close : Icons.delete_outline,
                    compact: true,
                    onPressed: () => unawaited(_delete()),
                  ),
                  Builder(
                    builder: (context) => GaiaActionIcon(
                      label: 'More',
                      icon: Icons.more_horiz,
                      compact: true,
                      onPressed: () {
                        final box = context.findRenderObject()! as RenderBox;
                        showGaiaMenu(
                          context,
                          box.localToGlobal(Offset(0, box.size.height)),
                          _menu(),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
    final card = MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onSecondaryTapUp: editing != null
            ? null
            : (details) =>
                  showGaiaMenu(context, details.globalPosition, _menu()),
        child: body,
      ),
    );
    if (editing != null) return card;
    return Draggable<_Dragged>(
      data: _DraggedMemory(memory.id),
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: _dragLabel(context, memory.text),
      childWhenDragging: Opacity(opacity: 0.5, child: card),
      child: card,
    );
  }
}

/// A memory's chat, which a click opens, closing the panel.
class _ChatLink extends StatefulWidget {
  const _ChatLink({required this.title, required this.onTap});

  final String title;
  final VoidCallback onTap;

  @override
  State<_ChatLink> createState() => _ChatLinkState();
}

class _ChatLinkState extends State<_ChatLink> {
  var _hovered = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: SystemMouseCursors.click,
    onEnter: (_) => setState(() => _hovered = true),
    onExit: (_) => setState(() => _hovered = false),
    child: GestureDetector(
      onTap: widget.onTap,
      child: Text(
        widget.title,
        overflow: TextOverflow.ellipsis,
        style: GaiaType.label.copyWith(
          color: _hovered ? GaiaInk.bright : GaiaInk.muted,
          decoration: _hovered ? TextDecoration.underline : null,
          decorationColor: GaiaInk.bright,
        ),
      ),
    ),
  );
}
