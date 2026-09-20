import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:voyager/app/providers.dart';
import 'package:voyager/core/constants/leetcode_constants.dart';
import 'package:voyager/core/motion/motion.dart';
import 'package:voyager/core/sync/debouncer.dart';
import 'package:voyager/core/theme/voyager_theme.dart';
import 'package:voyager/core/theme/app_fonts.dart';
import 'package:voyager/core/widgets/glass_button.dart';
import 'package:voyager/core/widgets/selector_pill.dart';
import 'package:voyager/core/widgets/voyager_scroll_view.dart';
import 'package:voyager/core/widgets/voyager_text_field.dart';
import 'package:voyager/core/widgets/voyager_toast.dart';
import 'package:voyager/domain/models/leetcode_cheat_models.dart';
import 'package:voyager/features/leetcode/leetcode_cheat_actions.dart';
import 'package:voyager/features/leetcode/leetcode_cheat_export.dart';
import 'package:voyager/features/leetcode/leetcode_cheat_providers.dart';
import 'package:voyager/features/leetcode/leetcode_cheat_search.dart';
import 'package:voyager/features/leetcode/leetcode_cheat_text.dart';
import 'package:voyager/features/leetcode/leetcode_code_controller.dart';
import 'package:voyager/features/leetcode/leetcode_code_field.dart';

/// How far the sheet stops short of the screen edges.
///
/// Smaller than the scratch editor's inset: the sheet is being *read* rather
/// than glanced at, so it takes the majority of the screen — but it still
/// stops short, because the margin it leaves is the scrim, and the scrim is
/// the click target that dismisses it.
const double _kSheetInset = 0.025;

/// Below this the outline rail is dropped entirely. It is a convenience, not
/// a navigation requirement — the tab's sections are all in the scroll.
const double _kOutlineBreakpoint = 1100;

const double _kOutlineWidth = 168;

/// How many frames an outline jump may spend building its way towards a
/// section that is not laid out yet. A viewport a frame, so this is far more
/// than the longest tab needs and still terminates.
const int _kJumpFrameBudget = 40;

/// Whether the cheat sheet route is currently on screen.
///
/// Not the place the app asks that question — [leetCodeCheatSheetOpenProvider]
/// is — but the toggle needs an answer before it has a `ref` to read, and the
/// route has to be able to say "I am already up" to a second chord press.
bool _isOpen = false;

/// Opens the cheat sheet, or closes it if it is already up.
///
/// What both the entry-point buttons and `Ctrl+Shift+C` call. From Editing the
/// chord drops to Viewing instead of closing (§2) — that decision lives in the
/// route's own key handling, which sees the mode; this only ever opens or
/// closes.
Future<void> toggleLeetCodeCheatSheet(BuildContext context, WidgetRef ref) {
  if (_isOpen) {
    _closeRequests.add(null);
    return Future.value();
  }
  return openLeetCodeCheatSheet(context, ref);
}

/// Broadcast so the open route hears a close asked for by a button that is
/// nowhere near it — the session page's top row, the scratch toolbar.
final _closeRequests = StreamController<void>.broadcast();

Future<void> openLeetCodeCheatSheet(BuildContext context, WidgetRef ref) {
  if (_isOpen) return Future.value();
  ref.read(leetCodeCheatSheetOpenProvider.notifier).state = true;
  // The root navigator, not the shell's: the fullscreen scratch editor already
  // pushes there, and the sheet has to render *above* it.
  return Navigator.of(context, rootNavigator: true)
      .push(
        PageRouteBuilder<void>(
          opaque: false,
          barrierColor: Colors.transparent,
          barrierDismissible: false,
          transitionDuration: Duration.zero,
          reverseTransitionDuration: Duration.zero,
          pageBuilder: (context, animation, secondaryAnimation) =>
              const _CheatSheetOverlay(),
        ),
      )
      .whenComplete(() {
        ref.read(leetCodeCheatSheetOpenProvider.notifier).state = false;
      });
}

class _CheatSheetOverlay extends ConsumerStatefulWidget {
  const _CheatSheetOverlay();

  @override
  ConsumerState<_CheatSheetOverlay> createState() => _CheatSheetOverlayState();
}

class _CheatSheetOverlayState extends ConsumerState<_CheatSheetOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _reveal;
  late final StreamSubscription<void> _closeSubscription;
  late final ProviderContainer _container;

  final _scrollController = ScrollController();
  final _searchController = TextEditingController();
  final _sectionKeys = <String, GlobalKey>{};

  /// Editing state is deliberately *not* persisted: the sheet opens in Viewing
  /// every single time (§2). It survives tab switches while the sheet stays
  /// open, and resets on close — which this field gets for free by living on
  /// the route's state.
  bool _editing = false;

  String _query = '';
  String? _tabId;
  bool _seeded = false;
  var _collapsed = <String>{};
  bool _closing = false;

  /// Per-entry editors, created the first time a row is edited and torn down
  /// when Editing mode ends.
  ///
  /// Never rebuilt from the model while they exist: a pull landing on the
  /// visible tab rebuilds the list, and a field the user is halfway through
  /// typing has to keep its local text (§8).
  final _entryEditors = <String, _EntryEditors>{};
  final _sectionEditors = <String, _NameEditor>{};

  @override
  void initState() {
    super.initState();
    _container = ProviderScope.containerOf(context, listen: false);
    _isOpen = true;
    _reveal = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _reveal.forward();
    });
    _closeSubscription = _closeRequests.stream.listen((_) => _close());
    HardwareKeyboard.instance.addHandler(_handleKeyEvent);
  }

  @override
  void dispose() {
    _isOpen = false;
    HardwareKeyboard.instance.removeHandler(_handleKeyEvent);
    _closeSubscription.cancel();
    // Whatever is still pending goes out before the controllers holding it
    // are torn down.
    unawaited(_flushPendingEdits());
    for (final editors in _entryEditors.values) {
      editors.dispose();
    }
    for (final editor in _sectionEditors.values) {
      editor.dispose();
    }
    _reveal.dispose();
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  LeetCodeCheatActions get _actions =>
      LeetCodeCheatActions.detached(_container);

  // --- Lifecycle -----------------------------------------------------------

  /// The chord, handled here because only the route knows the mode.
  ///
  /// From Viewing it closes; from Editing it drops to Viewing, and a second
  /// press closes (§2).
  bool _handleKeyEvent(KeyEvent event) {
    if (!mounted || event is! KeyDownEvent) return false;
    if (event.logicalKey != LogicalKeyboardKey.keyC) return false;
    if (!HardwareKeyboard.instance.isControlPressed) return false;
    if (!HardwareKeyboard.instance.isShiftPressed) return false;
    if (_editing) {
      unawaited(_setEditing(false));
    } else {
      _close();
    }
    return true;
  }

  Future<void> _close() async {
    if (_closing) return;
    _closing = true;
    await _flushPendingEdits();
    if (!mounted) return;
    await _reveal.reverse();
    if (mounted) Navigator.of(context).pop();
  }

  /// Click-outside. Ignored while Editing: nothing is *lost* — the debounce
  /// has already written — but your place is, and a stray click mid-sentence
  /// must not take the sheet away (§4.4).
  void _onScrimTap() {
    if (_editing) return;
    _close();
  }

  Future<void> _setEditing(bool editing) async {
    if (_editing == editing) return;
    if (!editing) await _flushPendingEdits();
    if (!mounted) return;
    setState(() {
      _editing = editing;
      // Entering Editing clears the filter (§2): the editable document is the
      // whole tab, not a slice of it.
      if (editing) {
        _query = '';
        _searchController.clear();
      } else {
        for (final editors in _entryEditors.values) {
          editors.dispose();
        }
        _entryEditors.clear();
        for (final editor in _sectionEditors.values) {
          editor.dispose();
        }
        _sectionEditors.clear();
      }
    });
  }

  Future<void> _flushPendingEdits() async {
    final actions = LeetCodeCheatActions.detached(_container);
    for (final entry in _entryEditors.entries) {
      entry.value.debouncer.cancel();
      await actions.saveEntry(
        entry.key,
        command: entry.value.command.text,
        description: entry.value.description.text,
        complexity: entry.value.complexity.text,
      );
    }
    for (final entry in _sectionEditors.entries) {
      entry.value.debouncer.cancel();
      await actions.renameSection(entry.key, entry.value.controller.text);
    }
  }

  Future<void> _switchTab(String id) async {
    if (_tabId == id) return;
    await _flushPendingEdits();
    if (!mounted) return;
    setState(() => _tabId = id);
    unawaited(_actions.setLastTabId(id));
  }

  // --- Build ---------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final sheet = ref.watch(leetCodeCheatSheetProvider);
    final data = sheet.valueOrNull ?? const LeetCodeCheatSheetData.empty();
    _seedFromSettings(data);

    final size = MediaQuery.sizeOf(context);
    final inset = EdgeInsets.symmetric(
      horizontal: size.width * _kSheetInset,
      vertical: size.height * _kSheetInset,
    );
    final reducedMotion = VoyagerMotion.reduced(context);

    return PopScope(
      // The route pops instantly (its transition is zero), so a system back
      // would make the sheet vanish rather than close — and the gesture has to
      // stop here rather than reaching the scratch editor below (§4.1).
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _close();
      },
      child: Material(
        color: Colors.transparent,
        child: AnimatedBuilder(
          animation: _reveal,
          builder: (context, child) {
            final t = _reveal.value.clamp(0.0, 1.0);
            return Stack(
              children: [
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    // Opaque, so the tap stops here. The scratch editor's own
                    // scrim is below this one and must never see it: a tap
                    // that dismisses the sheet must not also collapse the
                    // editor underneath (§4.1).
                    onTap: _onScrimTap,
                    child: ColoredBox(
                      color: Color.lerp(
                        Colors.transparent,
                        VoyagerColors.of(context).scrim,
                        t,
                      )!,
                    ),
                  ),
                ),
                Padding(
                  padding: inset,
                  child: reducedMotion
                      ? Opacity(opacity: t, child: child)
                      : Opacity(
                          opacity: t,
                          child: Transform.scale(
                            scale: 0.98 + 0.02 * t,
                            child: child,
                          ),
                        ),
                ),
              ],
            );
          },
          child: _SheetCard(child: _buildBody(data)),
        ),
      ),
    );
  }

  /// Takes the remembered tab and collapsed set from settings, once.
  ///
  /// A [leetCodeCheatLastTabId] naming a tab deleted on another device, or one
  /// this device has not pulled yet, falls back to the first tab by position —
  /// [LeetCodeCheatSheetData.resolveTab] does that, and a stale id is expected
  /// rather than exceptional (§5.5).
  void _seedFromSettings(LeetCodeCheatSheetData data) {
    if (_seeded) {
      // The remembered tab may have been deleted out from under the open
      // sheet by a pull; fall back the same way rather than showing nothing.
      if (_tabId != null && data.resolveTab(_tabId)?.id != _tabId) {
        _tabId = data.resolveTab(null)?.id;
      }
      return;
    }
    final settings = ref.watch(settingsProvider).valueOrNull;
    if (settings == null) return;
    _seeded = true;
    _tabId = data.resolveTab(settings.leetCodeCheatLastTabId)?.id;
    _collapsed = {...settings.leetCodeCheatCollapsedSections};
  }

  Widget _buildBody(LeetCodeCheatSheetData data) {
    final tab = data.resolveTab(_tabId);
    final hits = searchLeetCodeCheatSheet(data, _query);
    final filtering = _query.trim().isNotEmpty;
    final wide = MediaQuery.sizeOf(context).width >= _kOutlineBreakpoint;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Header(
          data: data,
          activeTabId: tab?.id,
          editing: _editing,
          searchController: _searchController,
          matchCounts: filtering ? leetCodeCheatMatchCounts(hits) : const {},
          allCollapsed: _allCollapsed(data, tab?.id),
          onSelectTab: _switchTab,
          onAddTab: _promptAddTab,
          onRenameTab: _promptRenameTab,
          onDeleteTab: _deleteTab,
          onQueryChanged: (value) => setState(() => _query = value),
          onToggleCollapseAll: () => _toggleCollapseAll(data, tab?.id),
          onToggleEditing: () => _setEditing(!_editing),
          onExportTab: tab == null ? null : () => _export(data, tabId: tab.id),
          onExportAll: () => _export(data),
          onClose: _close,
        ),
        const Divider(height: 1),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Dropped below the breakpoint, and the scroll position is
              // untouched by its coming and going (§8).
              if (wide && !filtering && tab != null)
                _OutlineRail(
                  sections: data.sectionsOf(tab.id),
                  onJump: _jumpToSection,
                ),
              Expanded(
                child: filtering
                    ? _SearchResults(
                        hits: hits,
                        query: _query,
                        onOpen: _openHit,
                        onEdit: (hit) => _openHit(hit, edit: true),
                      )
                    : _buildTabBody(data, tab),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildTabBody(LeetCodeCheatSheetData data, LeetCodeCheatTab? tab) {
    if (tab == null) {
      return _EmptyPrompt(
        message: _editing
            ? 'Add a tab with the + on the strip above.'
            : 'Nothing here yet. Press Edit to start your sheet.',
      );
    }
    final sections = data.sectionsOf(tab.id);
    if (sections.isEmpty && !_editing) {
      return const _EmptyPrompt(
        message: 'This tab is empty. Press Edit to add a section.',
      );
    }
    return _editing
        ? _EditingBody(
            key: ValueKey('editing-${tab.id}'),
            tab: tab,
            data: data,
            scrollController: _scrollController,
            entryEditorFor: _entryEditorFor,
            sectionEditorFor: _sectionEditorFor,
            sectionKeyFor: _sectionKeyFor,
            onReorderSections: (oldIndex, newIndex) =>
                _actions.reorderSections(sections, oldIndex, newIndex),
            onReorderEntries: (sectionId, oldIndex, newIndex) => _actions
                .reorderEntries(data.entriesOf(sectionId), oldIndex, newIndex),
            onAddSection: () =>
                _actions.createSection(tabId: tab.id, name: 'New section'),
            onAddEntry: (sectionId) =>
                _actions.createEntry(sectionId: sectionId),
            onDeleteSection: _deleteSection,
            onDeleteEntry: _deleteEntry,
          )
        : _ViewingBody(
            key: ValueKey('viewing-${tab.id}'),
            tab: tab,
            data: data,
            scrollController: _scrollController,
            collapsed: _collapsed,
            sectionKeyFor: _sectionKeyFor,
            onToggleSection: (id) => _toggleSection(data, id),
            onCopyCommand: _copyCommand,
            onEditEntry: (entry) => _beginEditingAt(entry),
          );
  }

  // --- Collapse ------------------------------------------------------------

  GlobalKey _sectionKeyFor(String id) =>
      _sectionKeys[id] ??= GlobalKey(debugLabel: 'cheatSection $id');

  bool _allCollapsed(LeetCodeCheatSheetData data, String? tabId) {
    if (tabId == null) return false;
    final sections = data.sectionsOf(tabId);
    return sections.isNotEmpty &&
        sections.every((section) => _collapsed.contains(section.id));
  }

  void _toggleSection(LeetCodeCheatSheetData data, String id) {
    setState(() {
      if (!_collapsed.remove(id)) _collapsed.add(id);
    });
    _persistCollapsed(data);
  }

  void _toggleCollapseAll(LeetCodeCheatSheetData data, String? tabId) {
    if (tabId == null) return;
    final sections = data.sectionsOf(tabId);
    final collapseAll = !_allCollapsed(data, tabId);
    setState(() {
      for (final section in sections) {
        if (collapseAll) {
          _collapsed.add(section.id);
        } else {
          _collapsed.remove(section.id);
        }
      }
    });
    _persistCollapsed(data);
  }

  void _persistCollapsed(LeetCodeCheatSheetData data) {
    unawaited(
      _actions.setCollapsedSections(
        _collapsed,
        liveSectionIds: {
          for (final sections in data.sectionsByTab.values)
            for (final section in sections) section.id,
        },
      ),
    );
  }

  void _jumpToSection(String id) {
    // Expanded first: scrolling to a collapsed heading lands on a row that is
    // about to change height anyway.
    if (_collapsed.contains(id)) {
      setState(() => _collapsed.remove(id));
      _persistCollapsed(_sheetData());
    }
    _scrollSectionIntoView(id, budget: _kJumpFrameBudget);
  }

  /// Brings [id]'s heading into view, a frame at a time.
  ///
  /// Viewing lays its whole document out eagerly, so the heading's key is
  /// always attached and the first pass is the only one. Editing's list builds
  /// lazily, so a heading a screen or more away has no context yet — and
  /// `ensureVisible` on a context that is not there is exactly the silent
  /// no-op the rail used to be in that mode. Stepping a viewport towards it
  /// builds the rows in between until the key catches, under a budget so a
  /// target that never appears stops rather than spins.
  void _scrollSectionIntoView(String id, {required int budget}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final target = _sectionKeys[id]?.currentContext;
      if (target != null) {
        unawaited(
          Scrollable.ensureVisible(
            target,
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            alignment: 0.05,
          ),
        );
        return;
      }
      if (budget == 0 || !_scrollController.hasClients) return;
      final position = _scrollController.position;
      final step = _sectionIsBelowBuilt(id)
          ? position.viewportDimension
          : -position.viewportDimension;
      final next = (position.pixels + step).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      );
      // Already against the end the target was supposed to be past: it is not
      // in this list at all, so stop rather than burn the rest of the budget.
      if (next == position.pixels) return;
      _scrollController.jumpTo(next);
      _scrollSectionIntoView(id, budget: budget - 1);
    });
  }

  /// Whether [id] sits after every section the list has actually built, i.e.
  /// whether reaching it means scrolling down rather than up.
  bool _sectionIsBelowBuilt(String id) {
    final sections = _sheetData().sectionsOf(_tabId ?? '');
    final target = sections.indexWhere((section) => section.id == id);
    if (target < 0) return true;
    for (var i = sections.length - 1; i > target; i--) {
      if (_sectionKeys[sections[i].id]?.currentContext != null) return false;
    }
    return true;
  }

  LeetCodeCheatSheetData _sheetData() =>
      ref.read(leetCodeCheatSheetProvider).valueOrNull ??
      const LeetCodeCheatSheetData.empty();

  // --- Search results ------------------------------------------------------

  /// Switches to the hit's tab, clears the filter and scrolls it into view.
  ///
  /// [edit] enters Editing on that entry — a double-click on a result — which
  /// also clears the filter, so the two paths share everything but the mode.
  Future<void> _openHit(LeetCodeCheatHit hit, {bool edit = false}) async {
    setState(() {
      _tabId = hit.tab.id;
      _query = '';
      _searchController.clear();
      _collapsed.remove(hit.section.id);
    });
    unawaited(_actions.setLastTabId(hit.tab.id));
    if (edit) {
      await _beginEditingAt(hit.entry);
      return;
    }
    _jumpToSection(hit.section.id);
  }

  /// Enters Editing focused on [entry] — the double-click path (§2).
  ///
  /// The section is expanded and scrolled to first so the row does not jump
  /// out from under the caret when the mode changes.
  Future<void> _beginEditingAt(LeetCodeCheatEntry entry) async {
    setState(() => _collapsed.remove(entry.sectionId));
    await _setEditing(true);
    if (!mounted) return;
    final editors = _entryEditorFor(entry);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) editors.commandFocus.requestFocus();
    });
  }

  // --- Copy ----------------------------------------------------------------

  Future<void> _copyCommand(LeetCodeCheatEntry entry) async {
    // An empty command is a no-op with no toast (§8): there is nothing to put
    // on the clipboard and nothing worth saying about it.
    if (entry.command.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: entry.command));
    if (!mounted) return;
    showVoyagerToast(
      context,
      message: 'Copied `${entry.command}`',
      icon: PhosphorIconsRegular.check,
      dwell: const Duration(milliseconds: 1400),
    );
  }

  Future<void> _export(LeetCodeCheatSheetData data, {String? tabId}) async {
    final markdown = leetCodeCheatSheetMarkdown(data, tabId: tabId);
    if (markdown.isEmpty) {
      showVoyagerToast(
        context,
        message: 'Nothing to export',
        icon: PhosphorIconsRegular.warning,
        dwell: const Duration(milliseconds: 1600),
      );
      return;
    }
    await Clipboard.setData(ClipboardData(text: markdown));
    if (!mounted) return;
    final name = tabId == null ? null : data.resolveTab(tabId)?.name;
    showVoyagerToast(
      context,
      message: name == null ? 'Copied the whole sheet' : 'Copied "$name"',
      icon: PhosphorIconsRegular.check,
      dwell: const Duration(milliseconds: 1600),
    );
  }

  // --- Editors -------------------------------------------------------------

  _EntryEditors _entryEditorFor(LeetCodeCheatEntry entry) {
    return _entryEditors[entry.id] ??= _EntryEditors(
      entry: entry,
      onSave: (command, description, complexity) => _actions.saveEntry(
        entry.id,
        command: command,
        description: description,
        complexity: complexity,
      ),
    );
  }

  _NameEditor _sectionEditorFor(LeetCodeCheatSection section) {
    return _sectionEditors[section.id] ??= _NameEditor(
      initial: section.name,
      onSave: (name) => _actions.renameSection(section.id, name),
    );
  }

  // --- Tabs ----------------------------------------------------------------

  Future<void> _promptAddTab() async {
    final result = await _showTabDialog(context, title: 'New tab');
    if (result == null) return;
    final tab = await _actions.createTab(
      name: result.name,
      languageKey: result.languageKey,
    );
    if (!mounted) return;
    setState(() => _tabId = tab.id);
    unawaited(_actions.setLastTabId(tab.id));
  }

  Future<void> _promptRenameTab(LeetCodeCheatTab tab) async {
    final result = await _showTabDialog(
      context,
      title: 'Edit tab',
      initialName: tab.name,
      initialLanguage: tab.languageKey,
    );
    if (result == null) return;
    await _actions.renameTab(tab.id, result.name);
    await _actions.setTabLanguage(tab.id, result.languageKey);
  }

  Future<void> _deleteTab(LeetCodeCheatTab tab) async {
    // Resolved before the delete: it unmounts the strip that asked for it, and
    // the undo offer has to outlive that.
    final overlay = Overlay.of(context, rootOverlay: true);
    await deleteCheatTabWithUndo(overlay, _container, tab: tab);
    if (!mounted) return;
    if (_tabId == tab.id) setState(() => _tabId = null);
  }

  Future<void> _deleteSection(LeetCodeCheatSection section) async {
    final overlay = Overlay.of(context, rootOverlay: true);
    _sectionEditors.remove(section.id)?.dispose();
    await deleteCheatSectionWithUndo(overlay, _container, section: section);
  }

  Future<void> _deleteEntry(LeetCodeCheatEntry entry) async {
    final overlay = Overlay.of(context, rootOverlay: true);
    _entryEditors.remove(entry.id)?.dispose();
    await deleteCheatEntryWithUndo(overlay, _container, entry: entry);
  }
}

// --- Frame -------------------------------------------------------------------

class _SheetCard extends StatelessWidget {
  const _SheetCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surface,
      elevation: 8,
      borderRadius: BorderRadius.circular(20),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }
}

class _EmptyPrompt extends StatelessWidget {
  const _EmptyPrompt({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          message,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

// --- Header ------------------------------------------------------------------

class _Header extends StatelessWidget {
  const _Header({
    required this.data,
    required this.activeTabId,
    required this.editing,
    required this.searchController,
    required this.matchCounts,
    required this.allCollapsed,
    required this.onSelectTab,
    required this.onAddTab,
    required this.onRenameTab,
    required this.onDeleteTab,
    required this.onQueryChanged,
    required this.onToggleCollapseAll,
    required this.onToggleEditing,
    required this.onExportTab,
    required this.onExportAll,
    required this.onClose,
  });

  final LeetCodeCheatSheetData data;
  final String? activeTabId;
  final bool editing;
  final TextEditingController searchController;
  final Map<String, int> matchCounts;
  final bool allCollapsed;
  final ValueChanged<String> onSelectTab;
  final VoidCallback onAddTab;
  final ValueChanged<LeetCodeCheatTab> onRenameTab;
  final ValueChanged<LeetCodeCheatTab> onDeleteTab;
  final ValueChanged<String> onQueryChanged;
  final VoidCallback onToggleCollapseAll;
  final VoidCallback onToggleEditing;
  final VoidCallback? onExportTab;
  final VoidCallback onExportAll;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Row(
        children: [
          Expanded(child: _tabStrip(context)),
          const SizedBox(width: 12),
          // Viewing mode only: entering Editing clears the filter, so a box
          // that stayed would be a control with nothing to control (§2).
          if (!editing)
            SizedBox(
              width: 200,
              child: VoyagerTextField(
                controller: searchController,
                onChanged: onQueryChanged,
                snippetsAllowed: false,
                decoration: InputDecoration(
                  isDense: true,
                  hintText: 'Search every tab',
                  prefixIcon: const Icon(
                    PhosphorIconsRegular.magnifyingGlass,
                    size: 16,
                  ),
                  prefixIconConstraints: const BoxConstraints(
                    minWidth: 32,
                    minHeight: 32,
                  ),
                  border: const OutlineInputBorder(),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 8,
                  ),
                ),
                style: theme.textTheme.bodySmall,
              ),
            ),
          const SizedBox(width: 8),
          GlassButton(
            dense: true,
            height: 32,
            icon: Icon(
              allCollapsed
                  ? PhosphorIconsRegular.arrowsOutLineVertical
                  : PhosphorIconsRegular.arrowsInLineVertical,
            ),
            label: allCollapsed ? 'Expand all' : 'Collapse all',
            tooltip: allCollapsed
                ? 'Expand every section in this tab'
                : 'Collapse every section in this tab',
            onPressed: onToggleCollapseAll,
          ),
          const SizedBox(width: 6),
          PopupMenuButton<bool>(
            tooltip: 'Copy as markdown',
            icon: const Icon(PhosphorIconsRegular.export, size: 18),
            onSelected: (thisTabOnly) {
              if (thisTabOnly) {
                onExportTab?.call();
              } else {
                onExportAll();
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: true,
                enabled: onExportTab != null,
                child: const Text('Copy this tab'),
              ),
              const PopupMenuItem(value: false, child: Text('Copy everything')),
            ],
          ),
          const SizedBox(width: 6),
          GlassButton(
            dense: true,
            height: 32,
            icon: const Icon(PhosphorIconsRegular.pencilSimple),
            label: editing ? 'Done' : 'Edit',
            color: editing ? theme.colorScheme.primary : null,
            tooltip: editing ? 'Back to reading' : 'Add and change entries',
            onPressed: onToggleEditing,
          ),
          const SizedBox(width: 6),
          GlassButton(
            dense: true,
            height: 32,
            icon: const Icon(PhosphorIconsRegular.x),
            tooltip: 'Close the cheat sheet',
            onPressed: onClose,
          ),
        ],
      ),
    );
  }

  Widget _tabStrip(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: 32,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          for (final tab in data.tabs) ...[
            _TabPill(
              tab: tab,
              isActive: tab.id == activeTabId,
              editing: editing,
              matchCount: matchCounts[tab.id],
              onTap: () => onSelectTab(tab.id),
              onRename: () => onRenameTab(tab),
              onDelete: () => onDeleteTab(tab),
            ),
            const SizedBox(width: 6),
          ],
          // The + belongs to Editing mode only — in Viewing there is nothing
          // to do with it.
          if (editing)
            SelectorPill(
              dense: true,
              icon: PhosphorIconsRegular.plus,
              label: 'Tab',
              onTap: onAddTab,
            )
          else if (data.tabs.isEmpty)
            Center(
              child: Text(
                'No tabs yet',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _TabPill extends StatelessWidget {
  const _TabPill({
    required this.tab,
    required this.isActive,
    required this.editing,
    required this.matchCount,
    required this.onTap,
    required this.onRename,
    required this.onDelete,
  });

  final LeetCodeCheatTab tab;
  final bool isActive;
  final bool editing;
  final int? matchCount;
  final VoidCallback onTap;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = matchCount == null ? tab.name : '${tab.name} · $matchCount';
    final pill = SelectorPill(
      dense: true,
      label: label,
      isActive: isActive,
      fillWhenActive: true,
      ellipsize: false,
      onTap: onTap,
    );
    if (!editing) return pill;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        pill,
        IconButton(
          icon: const Icon(PhosphorIconsRegular.pencilSimple, size: 14),
          tooltip: 'Rename "${tab.name}" or change its language',
          visualDensity: VisualDensity.compact,
          constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          padding: EdgeInsets.zero,
          onPressed: onRename,
        ),
        IconButton(
          icon: const Icon(PhosphorIconsRegular.trash, size: 14),
          tooltip: 'Delete "${tab.name}" and everything in it',
          visualDensity: VisualDensity.compact,
          constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          padding: EdgeInsets.zero,
          color: theme.colorScheme.error,
          onPressed: onDelete,
        ),
      ],
    );
  }
}

// --- Outline rail ------------------------------------------------------------

class _OutlineRail extends StatelessWidget {
  const _OutlineRail({required this.sections, required this.onJump});

  final List<LeetCodeCheatSection> sections;
  final ValueChanged<String> onJump;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: _kOutlineWidth,
      decoration: BoxDecoration(
        border: Border(right: BorderSide(color: theme.dividerColor, width: 1)),
      ),
      child: VoyagerScrollView(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final section in sections)
              TextButton(
                style: TextButton.styleFrom(
                  alignment: Alignment.centerLeft,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 6,
                  ),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  foregroundColor: theme.colorScheme.onSurfaceVariant,
                ),
                onPressed: () => onJump(section.id),
                child: Text(
                  section.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// --- Viewing -----------------------------------------------------------------

class _ViewingBody extends StatelessWidget {
  const _ViewingBody({
    super.key,
    required this.tab,
    required this.data,
    required this.scrollController,
    required this.collapsed,
    required this.sectionKeyFor,
    required this.onToggleSection,
    required this.onCopyCommand,
    required this.onEditEntry,
  });

  final LeetCodeCheatTab tab;
  final LeetCodeCheatSheetData data;
  final ScrollController scrollController;
  final Set<String> collapsed;
  final GlobalKey Function(String) sectionKeyFor;
  final ValueChanged<String> onToggleSection;
  final ValueChanged<LeetCodeCheatEntry> onCopyCommand;
  final ValueChanged<LeetCodeCheatEntry> onEditEntry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sections = data.sectionsOf(tab.id);
    return VoyagerScrollView(
      controller: scrollController,
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final section in sections) ...[
            _SectionHeading(
              key: sectionKeyFor(section.id),
              name: section.name,
              collapsed: collapsed.contains(section.id),
              onTap: () => onToggleSection(section.id),
            ),
            if (!collapsed.contains(section.id))
              for (final entry in data.entriesOf(section.id))
                _ViewingEntry(
                  entry: entry,
                  languageKey: tab.languageKey,
                  onCopy: () => onCopyCommand(entry),
                  onEdit: () => onEditEntry(entry),
                ),
            const SizedBox(height: 18),
          ],
          if (sections.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 32),
              child: Text(
                'This tab is empty. Press Edit to add a section.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _SectionHeading extends StatelessWidget {
  const _SectionHeading({
    super.key,
    required this.name,
    required this.collapsed,
    required this.onTap,
  });

  final String name;
  final bool collapsed;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Expanded(
              child: Text(
                name,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Icon(
              collapsed
                  ? PhosphorIconsRegular.caretRight
                  : PhosphorIconsRegular.caretDown,
              size: 16,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}

/// One entry as Viewing mode shows it: no field borders, no cursors, no drag
/// handles, no delete affordances.
class _ViewingEntry extends StatefulWidget {
  const _ViewingEntry({
    required this.entry,
    required this.languageKey,
    required this.onCopy,
    required this.onEdit,
    this.keywords = const [],
  });

  final LeetCodeCheatEntry entry;
  final String? languageKey;
  final VoidCallback onCopy;
  final VoidCallback onEdit;
  final List<String> keywords;

  @override
  State<_ViewingEntry> createState() => _ViewingEntryState();
}

class _ViewingEntryState extends State<_ViewingEntry> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final entry = widget.entry;
    final complexity = entry.complexity;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        // Click copies, double-click edits. In Editing mode neither is wired:
        // the click there places a caret (§2).
        onTap: widget.onCopy,
        onDoubleTap: widget.onEdit,
        behavior: HitTestBehavior.opaque,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: LeetCodeCheatCommandText(
                      entry.command,
                      languageKey: widget.languageKey,
                      keywords: widget.keywords,
                      style: theme.textTheme.bodyMedium ?? const TextStyle(),
                    ),
                  ),
                  if (_hovered)
                    Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: Icon(
                        PhosphorIconsRegular.copy,
                        size: 14,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  // Absent when unset — no placeholder, no em dash.
                  if (complexity != null && complexity.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: _ComplexityBadge(complexity),
                    ),
                ],
              ),
              if (entry.description.trim().isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: LeetCodeCheatDescription(
                    entry.description,
                    languageKey: widget.languageKey,
                    keywords: widget.keywords,
                    style:
                        theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ) ??
                        const TextStyle(),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ComplexityBadge extends StatelessWidget {
  const _ComplexityBadge(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: theme.colorScheme.onSurface.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: theme.textTheme.labelSmall?.copyWith(
          fontFamily: AppFonts.monoFamily,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

// --- Search results ----------------------------------------------------------

class _SearchResults extends StatelessWidget {
  const _SearchResults({
    required this.hits,
    required this.query,
    required this.onOpen,
    required this.onEdit,
  });

  final List<LeetCodeCheatHit> hits;
  final String query;
  final ValueChanged<LeetCodeCheatHit> onOpen;
  final ValueChanged<LeetCodeCheatHit> onEdit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (hits.isEmpty) {
      return _EmptyPrompt(message: 'Nothing matches "${query.trim()}".');
    }

    // Grouped by tab → section, so a hit in Python is visibly a hit in Python.
    final children = <Widget>[];
    String? lastTabId;
    String? lastSectionId;
    for (final hit in hits) {
      if (hit.tab.id != lastTabId) {
        lastTabId = hit.tab.id;
        lastSectionId = null;
        children.add(
          Padding(
            padding: EdgeInsets.only(top: children.isEmpty ? 0 : 18, bottom: 2),
            child: Text(
              hit.tab.name,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        );
      }
      if (hit.section.id != lastSectionId) {
        lastSectionId = hit.section.id;
        children.add(
          Padding(
            padding: const EdgeInsets.only(top: 6, bottom: 4),
            child: Text(
              hit.section.name,
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        );
      }
      children.add(
        _ViewingEntry(
          entry: hit.entry,
          languageKey: hit.tab.languageKey,
          keywords: [query],
          // A single click on a result is "take me there", not "copy" — the
          // result is a pointer into the sheet, and the copy affordance is
          // waiting where it lands.
          onCopy: () => onOpen(hit),
          onEdit: () => onEdit(hit),
        ),
      );
    }

    return VoyagerScrollView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }
}

// --- Editing -----------------------------------------------------------------

class _EditingBody extends StatelessWidget {
  const _EditingBody({
    super.key,
    required this.tab,
    required this.data,
    required this.scrollController,
    required this.entryEditorFor,
    required this.sectionEditorFor,
    required this.sectionKeyFor,
    required this.onReorderSections,
    required this.onReorderEntries,
    required this.onAddSection,
    required this.onAddEntry,
    required this.onDeleteSection,
    required this.onDeleteEntry,
  });

  final LeetCodeCheatTab tab;
  final LeetCodeCheatSheetData data;
  final ScrollController scrollController;
  final _EntryEditors Function(LeetCodeCheatEntry) entryEditorFor;
  final _NameEditor Function(LeetCodeCheatSection) sectionEditorFor;

  /// The same per-section [GlobalKey]s [_ViewingBody] attaches, so the outline
  /// rail can reach a heading in this mode too. Only one of the two bodies is
  /// ever mounted, so the key is never in two places at once.
  final GlobalKey Function(String) sectionKeyFor;

  final void Function(int oldIndex, int newIndex) onReorderSections;
  final void Function(String sectionId, int oldIndex, int newIndex)
  onReorderEntries;
  final VoidCallback onAddSection;
  final ValueChanged<String> onAddEntry;
  final ValueChanged<LeetCodeCheatSection> onDeleteSection;
  final ValueChanged<LeetCodeCheatEntry> onDeleteEntry;

  @override
  Widget build(BuildContext context) {
    final sections = data.sectionsOf(tab.id);
    return Column(
      children: [
        Expanded(
          child: ReorderableListView(
            scrollController: scrollController,
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
            onReorderItem: onReorderSections,
            children: [
              for (final section in sections)
                _EditingSection(
                  key: sectionKeyFor(section.id),
                  section: section,
                  tab: tab,
                  entries: data.entriesOf(section.id),
                  nameEditor: sectionEditorFor(section),
                  entryEditorFor: entryEditorFor,
                  onReorderEntries: (oldIndex, newIndex) =>
                      onReorderEntries(section.id, oldIndex, newIndex),
                  onAddEntry: () => onAddEntry(section.id),
                  onDelete: () => onDeleteSection(section),
                  onDeleteEntry: onDeleteEntry,
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
          // A Row rather than an Align: [GlassButton] has no intrinsic-width
          // guard, so under the bounded constraints an Align hands down it
          // stretches the whole content column and reads as a footer bar
          // instead of a sibling of "Add entry". A Row leaves the main axis
          // unbounded, which is the shape it gets in the header too.
          child: Row(
            children: [
              GlassButton(
                dense: true,
                height: 32,
                icon: const Icon(PhosphorIconsRegular.plus),
                label: 'Add section',
                onPressed: onAddSection,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _EditingSection extends StatelessWidget {
  const _EditingSection({
    super.key,
    required this.section,
    required this.tab,
    required this.entries,
    required this.nameEditor,
    required this.entryEditorFor,
    required this.onReorderEntries,
    required this.onAddEntry,
    required this.onDelete,
    required this.onDeleteEntry,
  });

  final LeetCodeCheatSection section;
  final LeetCodeCheatTab tab;
  final List<LeetCodeCheatEntry> entries;
  final _NameEditor nameEditor;
  final _EntryEditors Function(LeetCodeCheatEntry) entryEditorFor;
  final void Function(int oldIndex, int newIndex) onReorderEntries;
  final VoidCallback onAddEntry;
  final VoidCallback onDelete;
  final ValueChanged<LeetCodeCheatEntry> onDeleteEntry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: VoyagerTextField(
                  controller: nameEditor.controller,
                  focusNode: nameEditor.focusNode,
                  onChanged: nameEditor.onChanged,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                  decoration: const InputDecoration(
                    isDense: true,
                    hintText: 'Section name',
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 8,
                    ),
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(PhosphorIconsRegular.trash, size: 16),
                tooltip: 'Delete "${section.name}" and its entries',
                color: theme.colorScheme.error,
                onPressed: onDelete,
              ),
            ],
          ),
          const SizedBox(height: 8),
          ReorderableListView(
            shrinkWrap: true,
            // Nested inside the sections list, which owns the scrolling.
            physics: const NeverScrollableScrollPhysics(),
            onReorderItem: onReorderEntries,
            children: [
              for (final entry in entries)
                _EditingEntry(
                  key: ValueKey(entry.id),
                  entry: entry,
                  tab: tab,
                  editors: entryEditorFor(entry),
                  onDelete: () => onDeleteEntry(entry),
                ),
            ],
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              icon: const Icon(PhosphorIconsRegular.plus, size: 14),
              label: const Text('Add entry'),
              style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
              onPressed: onAddEntry,
            ),
          ),
        ],
      ),
    );
  }
}

class _EditingEntry extends StatelessWidget {
  const _EditingEntry({
    super.key,
    required this.entry,
    required this.tab,
    required this.editors,
    required this.onDelete,
  });

  final LeetCodeCheatEntry entry;
  final LeetCodeCheatTab tab;
  final _EntryEditors editors;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    editors.syncLanguage(cheatLanguageKey(tab.languageKey));

    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                // A code field: highlighting on, spell-check off, snippets
                // off. Squiggling every identifier would make it unusable.
                child: LeetCodeCodeSurface(
                  controller: editors.command,
                  focusNode: editors.commandFocus,
                  scrollable: false,
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 116,
                child: VoyagerTextField(
                  controller: editors.complexity,
                  focusNode: editors.complexityFocus,
                  onChanged: (_) => editors.schedule(),
                  snippetsAllowed: false,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontFamily: AppFonts.monoFamily,
                  ),
                  decoration: const InputDecoration(
                    isDense: true,
                    hintText: 'O(1)',
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 10,
                    ),
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(PhosphorIconsRegular.trash, size: 14),
                tooltip: 'Delete this entry',
                visualDensity: VisualDensity.compact,
                color: theme.colorScheme.error,
                onPressed: onDelete,
              ),
            ],
          ),
          const SizedBox(height: 6),
          // A normal prose field — spell-check, snippets and Vim all on,
          // exactly as every other prose field in the app.
          VoyagerTextField(
            controller: editors.description,
            focusNode: editors.descriptionFocus,
            onChanged: (_) => editors.schedule(),
            maxLines: null,
            minLines: 2,
            style: theme.textTheme.bodySmall,
            decoration: const InputDecoration(
              isDense: true,
              hintText: 'What it does',
              border: OutlineInputBorder(),
              contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            ),
          ),
        ],
      ),
    );
  }
}

/// The three controllers behind one entry in Editing mode, plus the debounce
/// that writes them.
///
/// Saving is debounced per record and flushed on blur, on mode toggle, on tab
/// switch and on close — the same contract the scratch pad keeps.
class _EntryEditors {
  _EntryEditors({required LeetCodeCheatEntry entry, required this.onSave})
    : command = LeetCodeCodeController(text: entry.command),
      description = TextEditingController(text: entry.description),
      complexity = TextEditingController(text: entry.complexity ?? '') {
    command.addListener(schedule);
    for (final node in [commandFocus, descriptionFocus, complexityFocus]) {
      node.addListener(() {
        if (!node.hasFocus) unawaited(flush());
      });
    }
  }

  final Future<void> Function(String, String, String) onSave;

  final LeetCodeCodeController command;
  final TextEditingController description;
  final TextEditingController complexity;

  final commandFocus = FocusNode(debugLabel: 'cheatCommand');
  final descriptionFocus = FocusNode(debugLabel: 'cheatDescription');
  final complexityFocus = FocusNode(debugLabel: 'cheatComplexity');

  final debouncer = Debouncer(delay: const Duration(milliseconds: 600));

  String? _language;

  /// Points the code controller at the tab's grammar, once per change.
  ///
  /// Called from `build` because the tab's language can be edited while the
  /// sheet is open; assigning unconditionally would re-highlight the field on
  /// every frame.
  void syncLanguage(String? languageKey) {
    if (_language == languageKey) return;
    _language = languageKey;
    command.language = languageKey == null
        ? null
        : leetCodeHighlightMode(languageKey);
  }

  void schedule() => debouncer.schedule(_write);

  Future<void> flush() async {
    debouncer.cancel();
    await _write();
  }

  Future<void> _write() =>
      onSave(command.fullText, description.text, complexity.text);

  void dispose() {
    debouncer.dispose();
    command.removeListener(schedule);
    command.dispose();
    description.dispose();
    complexity.dispose();
    commandFocus.dispose();
    descriptionFocus.dispose();
    complexityFocus.dispose();
  }
}

/// [_EntryEditors] for a section heading, which is one field.
class _NameEditor {
  _NameEditor({required String initial, required this.onSave})
    : controller = TextEditingController(text: initial) {
    focusNode.addListener(() {
      if (!focusNode.hasFocus) unawaited(flush());
    });
  }

  final TextEditingController controller;
  final focusNode = FocusNode(debugLabel: 'cheatSectionName');
  final debouncer = Debouncer(delay: const Duration(milliseconds: 600));
  final Future<void> Function(String) onSave;

  void onChanged(String _) => debouncer.schedule(() => onSave(controller.text));

  Future<void> flush() async {
    debouncer.cancel();
    await onSave(controller.text);
  }

  void dispose() {
    debouncer.dispose();
    controller.dispose();
    focusNode.dispose();
  }
}

// --- Tab dialog --------------------------------------------------------------

typedef _TabDraft = ({String name, String? languageKey});

/// Name plus an optional language, which is the whole of what a tab is.
///
/// "No language" is a first-class choice rather than an omission: it is what
/// makes a "Patterns" or "Big-O" tab legal, and it renders commands in plain
/// mono.
Future<_TabDraft?> _showTabDialog(
  BuildContext context, {
  required String title,
  String? initialName,
  String? initialLanguage,
}) {
  final controller = TextEditingController(text: initialName ?? '');
  var language = initialLanguage;

  return showDialog<_TabDraft>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              VoyagerTextField(
                controller: controller,
                autofocus: true,
                snippetsAllowed: false,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Syntax highlighting',
                style: Theme.of(context).textTheme.labelMedium,
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  SelectorPill(
                    dense: true,
                    label: 'None',
                    isActive: language == null,
                    fillWhenActive: true,
                    onTap: () => setState(() => language = null),
                  ),
                  for (final key in leetCodeCodeLanguages)
                    SelectorPill(
                      dense: true,
                      label: labelForLeetCodeLanguage(key),
                      isActive: language == key,
                      fillWhenActive: true,
                      onTap: () => setState(() => language = key),
                    ),
                ],
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final name = controller.text.trim();
              if (name.isEmpty) return;
              Navigator.of(context).pop((name: name, languageKey: language));
            },
            child: const Text('Save'),
          ),
        ],
      ),
    ),
  ).whenComplete(controller.dispose);
}
