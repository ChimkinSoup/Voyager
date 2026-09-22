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
import 'package:voyager/core/widgets/rounded_drag_proxy.dart';
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

/// The label column, and the complexity column opposite it.
///
/// Both are fixed so that labels and badges line up down the page rather than
/// tracking whatever the code beside them happens to be — which is the whole
/// point of giving either one a column. The label column collapses to nothing
/// on a row with no label, so those rows keep their code at the left margin.
const double _kLabelWidth = 132;

/// Wide enough for a note as long as "O(1) amortized" to stand on one line.
/// That matters more here than the 24pt it costs the code: the field is read
/// line for line against the block beside it, so a wrapped entry looks like
/// a cost belonging to the next line down.
const double _kComplexityWidth = 128;

/// The gap either column keeps from the code between them.
const double _kColumnGap = 12;

/// The strip between the code and the complexity column that the copy hint
/// lives in, gap included.
const double _kCopyWidth = _kColumnGap + 14;

/// Editing's complexity field, which has to fit "O(n log n)" inside
/// [_kComplexityWidth] while standing a line-height taller than it would
/// choose for itself.
const double _kEditingComplexitySize = 12;

/// How far the side columns are pushed down to sit on the code's first line
/// rather than on the top edge of its box.
const double _kColumnTopInset = 6;

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

  /// The section just added, whose name field takes focus when it mounts.
  String? _focusSectionId;

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
                  editing: _editing,
                  onJump: _jumpToSection,
                  onReorder: (oldIndex, newIndex) => _actions.reorderSections(
                    data.sectionsOf(tab.id),
                    oldIndex,
                    newIndex,
                  ),
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
            onReorderEntries: (sectionId, oldIndex, newIndex) => _actions
                .reorderEntries(data.entriesOf(sectionId), oldIndex, newIndex),
            focusSectionId: _focusSectionId,
            onAddSection: () => _addSection(tab.id),
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
      onSave: (command, label, description, complexity) => _actions.saveEntry(
        entry.id,
        command: command,
        label: label,
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

  // --- Sections ------------------------------------------------------------

  /// Blank rather than a placeholder name the user has to delete first: the
  /// field's hint already says what goes there, and the caret is put in it.
  Future<void> _addSection(String tabId) async {
    final section = await _actions.createSection(tabId: tabId, name: '');
    // The list builds lazily, so the new heading has to be scrolled to before
    // it exists to take focus — and it is only in the list once the reload
    // the create kicked off has landed.
    await _container.read(leetCodeCheatSheetProvider.future);
    if (!mounted) return;
    setState(() => _focusSectionId = section.id);
    _scrollSectionIntoView(section.id, budget: _kJumpFrameBudget);
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
  const _OutlineRail({
    required this.sections,
    required this.editing,
    required this.onJump,
    required this.onReorder,
  });

  final List<LeetCodeCheatSection> sections;

  /// Whether the rail also *moves* sections, which it only does in Editing.
  final bool editing;

  final ValueChanged<String> onJump;
  final void Function(int oldIndex, int newIndex) onReorder;

  static const _padding = EdgeInsets.symmetric(vertical: 14, horizontal: 8);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: _kOutlineWidth,
      decoration: BoxDecoration(
        border: Border(right: BorderSide(color: theme.dividerColor, width: 1)),
      ),
      // The rail is where a section is moved, because the body cannot be: a
      // section's drag proxy is its heading *and every entry under it*, which
      // is routinely taller than the sheet — tall enough that the framework's
      // auto-scroller asserts on it and then fights the drag. One line per
      // section is a proxy that behaves.
      child: editing
          ? ReorderableListView(
              padding: _padding,
              buildDefaultDragHandles: false,
              proxyDecorator: roundedDragProxy,
              onReorderItem: onReorder,
              children: [
                for (var i = 0; i < sections.length; i++)
                  Row(
                    key: ValueKey(sections[i].id),
                    children: [
                      _DragGrip(
                        index: i,
                        tooltip: 'Drag to reorder this section',
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 6,
                        ),
                      ),
                      Expanded(child: _railLabel(theme, sections[i])),
                    ],
                  ),
              ],
            )
          : VoyagerScrollView(
              padding: _padding,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final section in sections) _railLabel(theme, section),
                ],
              ),
            ),
    );
  }

  /// One section in the rail.
  ///
  /// Roomy on purpose: these are headings, not a menu, and a stack of them at
  /// list density reads as one grey block. The row breathes, the label takes a
  /// second line before it ellipsises, and the weight says "title".
  ///
  /// Solid accent, labelled in `onPrimary` — which the theme derives with
  /// [onColorLabel], the same rule a calendar event's text follows on its own
  /// colour. The accent is user-chosen and can land anywhere on the luminance
  /// range, so a pale one gets dark ink rather than unreadable white.
  Widget _railLabel(ThemeData theme, LeetCodeCheatSection section) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: TextButton(
        style: TextButton.styleFrom(
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 13),
          minimumSize: Size.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          backgroundColor: theme.colorScheme.primary,
          foregroundColor: theme.colorScheme.onPrimary,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(VoyagerTheme.fieldRadius),
          ),
        ),
        onPressed: () => onJump(section.id),
        child: Text(
          _sectionTitle(section.name),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          // The colour is set here and not left to the button's
          // `foregroundColor` alone: `bodySmall` already carries the theme's
          // body colour, and an explicit style on a [Text] merges over the
          // [DefaultTextStyle] the button wraps its label in.
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onPrimary,
            fontWeight: FontWeight.w500,
            height: 1.3,
            letterSpacing: 0.1,
          ),
        ),
      ),
    );
  }
}

/// What a section is called where it is read. A new section starts blank, and
/// an empty heading would read as a rendering fault rather than a name to fill.
String _sectionTitle(String name) =>
    name.trim().isEmpty ? 'Untitled section' : name;

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
    // Once for the whole tab, so the code column holds one left edge down the
    // page rather than jogging at every unlabelled row.
    final showLabel = sections.any(
      (section) => data
          .entriesOf(section.id)
          .any((entry) => (entry.label ?? '').trim().isNotEmpty),
    );
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
                  showLabel: showLabel,
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
    final accent = theme.colorScheme.primary;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(VoyagerTheme.fieldRadius),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(6, 10, 6, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    _sectionTitle(name),
                    // Heavier and wider-tracked than anything under it: with
                    // the rules between entries gone, weight is what tells a
                    // section boundary from a row's own label.
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: accent,
                      letterSpacing: 0.4,
                    ),
                  ),
                ),
                Icon(
                  collapsed
                      ? PhosphorIconsRegular.caretRight
                      : PhosphorIconsRegular.caretDown,
                  size: 16,
                  color: accent.withValues(alpha: 0.7),
                ),
              ],
            ),
            // The only horizontal rule on the page, now that the hairlines
            // between entries are gone.
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: SizedBox(
                height: 1,
                child: ColoredBox(color: accent.withValues(alpha: 0.32)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One entry as Viewing mode shows it: no field borders, no cursors, no drag
/// handles, no delete affordances.
///
/// Three columns — label, code over its note, complexity — so a row is read
/// down a column rather than across a block. The side columns are fixed width
/// ([_kLabelWidth], [_kComplexityWidth]) so they line up down the page.
///
/// [showLabel] is decided for the page rather than the row: a sheet where
/// nothing is labelled drops the column entirely rather than indenting every
/// row behind an empty gutter, but as soon as one row has a label the rest
/// hold the space, because a code column that jogs left and right down the
/// page is worse than a little white space.
class _ViewingEntry extends StatefulWidget {
  const _ViewingEntry({
    required this.entry,
    required this.languageKey,
    required this.showLabel,
    required this.onCopy,
    required this.onEdit,
    this.keywords = const [],
  });

  final LeetCodeCheatEntry entry;
  final String? languageKey;
  final bool showLabel;
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
    final isDark = theme.brightness == Brightness.dark;
    final entry = widget.entry;
    final label = entry.label?.trim();
    final lines = entry.commandLines;
    final costs = entry.complexityByLine;
    final description = entry.description.trim();

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
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: _hovered
                ? theme.colorScheme.primary.withValues(alpha: 0.05)
                : null,
            borderRadius: BorderRadius.circular(VoyagerTheme.fieldRadius),
          ),
          child: Padding(
            // Vertical breathing room is what separates one row from the next
            // now that there is no hairline doing it.
            padding: const EdgeInsets.fromLTRB(6, 7, 6, 7),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (widget.showLabel) ...[
                  SizedBox(
                    width: _kLabelWidth,
                    child: label == null || label.isEmpty
                        ? null
                        : Padding(
                            padding: const EdgeInsets.only(
                              top: _kColumnTopInset,
                            ),
                            child: Text(
                              label,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                                height: 1.4,
                              ),
                            ),
                          ),
                  ),
                  const SizedBox(width: _kColumnGap),
                ],
                Expanded(
                  child: Column(
                    // Stretched, not hugged: a plate that shrank to its own
                    // command would give every row a different right edge,
                    // and the column the badges hang off is what makes the
                    // page scan.
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // One row per line, each carrying its own cost. The
                      // plate is cut into cells that meet flush, so it still
                      // reads as one box around the block while every badge
                      // stays pinned to the line it belongs to — two columns
                      // measured apart could not stay level once a long line
                      // wrapped.
                      for (var i = 0; i < lines.length; i++)
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Container(
                                padding: EdgeInsets.fromLTRB(
                                  8,
                                  i == 0 ? 6 : 0,
                                  8,
                                  i == lines.length - 1 ? 6 : 0,
                                ),
                                // The code sits on its own plate, so the line
                                // between what to type and what it does is
                                // drawn before either is read. A neutral tint
                                // rather than the editor's paper: the syntax
                                // colours here are theme-aware, and the
                                // editor's background is dark in both themes.
                                decoration: BoxDecoration(
                                  color: theme.colorScheme.onSurface.withValues(
                                    alpha: isDark ? 0.05 : 0.04,
                                  ),
                                  borderRadius: BorderRadius.vertical(
                                    top: Radius.circular(
                                      i == 0 ? VoyagerTheme.fieldRadius : 0,
                                    ),
                                    bottom: Radius.circular(
                                      i == lines.length - 1
                                          ? VoyagerTheme.fieldRadius
                                          : 0,
                                    ),
                                  ),
                                ),
                                child: LeetCodeCheatCommandText(
                                  lines[i],
                                  languageKey: widget.languageKey,
                                  keywords: widget.keywords,
                                  style:
                                      theme.textTheme.bodyMedium ??
                                      const TextStyle(),
                                ),
                              ),
                            ),
                            // A reserved slot rather than an `if (_hovered)`:
                            // appearing and disappearing would shove the
                            // complexity column sideways under the cursor,
                            // and lining those up is the point. The icon
                            // rides the first line, since a copy takes the
                            // whole block either way.
                            SizedBox(
                              width: _kCopyWidth,
                              child: i != 0
                                  ? null
                                  : Padding(
                                      padding: const EdgeInsets.only(
                                        top: _kColumnTopInset + 1,
                                      ),
                                      child: Opacity(
                                        opacity: _hovered ? 1 : 0,
                                        child: Icon(
                                          PhosphorIconsRegular.copy,
                                          size: 14,
                                          color: theme
                                              .colorScheme
                                              .onSurfaceVariant,
                                        ),
                                      ),
                                    ),
                            ),
                            // Held open even when this line has no cost, so
                            // every badge on the page hangs off one edge.
                            SizedBox(
                              width: _kComplexityWidth,
                              child: costs[i].isEmpty
                                  ? null
                                  : Padding(
                                      padding: EdgeInsets.only(
                                        left: _kColumnGap,
                                        // Only the first line sits below the
                                        // plate's own top inset.
                                        top: i == 0 ? _kColumnTopInset : 0,
                                      ),
                                      child: Align(
                                        alignment: Alignment.topRight,
                                        child: _ComplexityBadge(costs[i]),
                                      ),
                                    ),
                            ),
                          ],
                        ),
                      // Indented behind an accent rule: the prose is what the
                      // code is not, and the offset says so before a word is
                      // read.
                      if (description.isNotEmpty)
                        Padding(
                          // Clear of the two columns to its right, so the
                          // note stays under the code rather than running out
                          // beneath the badges.
                          padding: const EdgeInsets.fromLTRB(
                            10,
                            6,
                            _kCopyWidth + _kComplexityWidth,
                            0,
                          ),
                          child: Container(
                            padding: const EdgeInsets.only(left: 10),
                            decoration: BoxDecoration(
                              border: Border(
                                left: BorderSide(
                                  color: theme.colorScheme.primary.withValues(
                                    alpha: 0.3,
                                  ),
                                  width: 2,
                                ),
                              ),
                            ),
                            child: LeetCodeCheatDescription(
                              entry.description,
                              languageKey: widget.languageKey,
                              keywords: widget.keywords,
                              style:
                                  theme.textTheme.bodySmall?.copyWith(
                                    // A step under the code it explains, on
                                    // top of the muted colour, and leaded
                                    // loosely enough that a note running to
                                    // three lines still scans.
                                    fontSize: 11.5,
                                    color: theme.colorScheme.onSurfaceVariant,
                                    height: 1.55,
                                  ) ??
                                  const TextStyle(),
                            ),
                          ),
                        ),
                    ],
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

/// What a complexity reads as costing, inferred from the badge's own text.
///
/// Inference, not parsing: the field is free text the user writes, so
/// "O(1) amortized" has to land on the same tier as a bare "O(1)", and
/// anything this does not recognise — "O(m+n)", a note in prose — falls to
/// [CheatComplexityTier.unknown] and is drawn neutral rather than guessed at.
enum CheatComplexityTier { cheap, moderate, expensive, unknown }

/// The tier [text] falls in, read off the first `O(...)` it contains.
@visibleForTesting
CheatComplexityTier cheatComplexityTier(String text) {
  final match = RegExp(r'[oO]\s*\(([^)]*)').firstMatch(text);
  if (match == null) return CheatComplexityTier.unknown;

  // Superscripts are how the user is most likely to have typed a power, and
  // the separators between factors carry no meaning here.
  final inner = match
      .group(1)!
      .toLowerCase()
      .replaceAll('²', '^2')
      .replaceAll('³', '^3')
      .replaceAll(RegExp(r'[\s*·×()]'), '');

  if (inner.contains('!')) return CheatComplexityTier.expensive;
  // `n^2` and up, and anything with a variable in the exponent: `2^n`, `n^k`.
  final power = RegExp(r'\^(\d+)').firstMatch(inner);
  if (power != null && (int.tryParse(power.group(1)!) ?? 0) >= 2) {
    return CheatComplexityTier.expensive;
  }
  if (RegExp(r'\^[a-z]').hasMatch(inner)) return CheatComplexityTier.expensive;

  return switch (inner) {
    '1' => CheatComplexityTier.cheap,
    'n' || 'logn' || 'nlogn' => CheatComplexityTier.moderate,
    _ => CheatComplexityTier.unknown,
  };
}

/// The colour a tier wears, in the theme in play.
///
/// The LeetCode difficulty triad, which is already what green, amber and red
/// mean everywhere else in this section. Those three are tuned for a dark
/// page, and amber in particular vanishes on cream at label size — so on the
/// light theme they keep their hue and are taken down to a lightness that
/// reads.
Color _complexityColor(ThemeData theme, CheatComplexityTier tier) {
  final base = switch (tier) {
    CheatComplexityTier.cheap => kLeetCodeEasyColor,
    CheatComplexityTier.moderate => kLeetCodeMediumColor,
    CheatComplexityTier.expensive => kLeetCodeHardColor,
    CheatComplexityTier.unknown => theme.colorScheme.onSurfaceVariant,
  };
  if (tier == CheatComplexityTier.unknown ||
      theme.brightness == Brightness.dark) {
    return base;
  }
  final hsl = HSLColor.fromColor(base);
  return hsl.lightness <= 0.38 ? base : hsl.withLightness(0.38).toColor();
}

class _ComplexityBadge extends StatelessWidget {
  const _ComplexityBadge(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = _complexityColor(theme, cheatComplexityTier(text));
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(VoyagerTheme.fieldRadius),
      ),
      child: Text(
        text,
        // Right-aligned for the run of it that wraps: the column is sized for
        // "O(n log n)", and a longer note like "O(1) amortized" takes a
        // second line rather than being cut.
        textAlign: TextAlign.right,
        style: theme.textTheme.labelSmall?.copyWith(
          fontFamily: AppFonts.monoFamily,
          color: color,
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

    // As in [_ViewingBody], decided once across everything on screen.
    final showLabel = hits.any(
      (hit) => (hit.entry.label ?? '').trim().isNotEmpty,
    );

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
                color: theme.colorScheme.primary,
              ),
            ),
          ),
        );
      }
      children.add(
        _ViewingEntry(
          entry: hit.entry,
          languageKey: hit.tab.languageKey,
          showLabel: showLabel,
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
    required this.focusSectionId,
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

  final String? focusSectionId;

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
          // A plain list: sections are moved from the outline rail, for the
          // reason [_OutlineRail] gives.
          child: ListView(
            controller: scrollController,
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
            children: [
              for (var i = 0; i < sections.length; i++)
                _EditingSection(
                  key: sectionKeyFor(sections[i].id),
                  section: sections[i],
                  tab: tab,
                  entries: data.entriesOf(sections[i].id),
                  nameEditor: sectionEditorFor(sections[i]),
                  autofocus: sections[i].id == focusSectionId,
                  entryEditorFor: entryEditorFor,
                  onReorderEntries: (oldIndex, newIndex) =>
                      onReorderEntries(sections[i].id, oldIndex, newIndex),
                  onAddEntry: () => onAddEntry(sections[i].id),
                  onDelete: () => onDeleteSection(sections[i]),
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
    required this.autofocus,
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
  final bool autofocus;
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
                  autofocus: autofocus,
                  onChanged: nameEditor.onChanged,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.primary,
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
            buildDefaultDragHandles: false,
            proxyDecorator: roundedDragProxy,
            onReorderItem: onReorderEntries,
            children: [
              for (var i = 0; i < entries.length; i++)
                _EditingEntry(
                  key: ValueKey(entries[i].id),
                  index: i,
                  entry: entries[i],
                  tab: tab,
                  editors: entryEditorFor(entries[i]),
                  onDelete: () => onDeleteEntry(entries[i]),
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
    required this.index,
    required this.entry,
    required this.tab,
    required this.editors,
    required this.onDelete,
  });

  final int index;
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
      // The columns Viewing reads the same row in, so a row edits where it is
      // read. The label column is held open here even when empty — Viewing
      // collapses it, but this is the only place a label can be typed.
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: _kLabelWidth,
            child: VoyagerTextField(
              controller: editors.label,
              focusNode: editors.labelFocus,
              onChanged: (_) => editors.schedule(),
              // Enter carries on to the code beside it, the field a label is
              // naming.
              onSubmitted: (_) => editors.commandFocus.requestFocus(),
              snippetsAllowed: false,
              style: theme.textTheme.bodySmall,
              decoration: const InputDecoration(
                isDense: true,
                hintText: 'Label',
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 10,
                ),
              ),
            ),
          ),
          const SizedBox(width: _kColumnGap),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // A code field: highlighting on, spell-check off, snippets
                // off. Squiggling every identifier would make it unusable.
                LeetCodeCodeSurface(
                  controller: editors.command,
                  focusNode: editors.commandFocus,
                  scrollable: false,
                ),
                const SizedBox(height: 6),
                // A normal prose field — spell-check, snippets and Vim all
                // on, exactly as every other prose field in the app. Under
                // the code, where Viewing shows the same text.
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
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 8,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: _kColumnGap),
          SizedBox(
            width: _kComplexityWidth,
            // One line per line of the code beside it, which is how the
            // badges are paired up — so the field takes the editor's line
            // height and first-line inset rather than its own, and the two
            // stay in step as the block grows.
            child: VoyagerTextField(
              controller: editors.complexity,
              focusNode: editors.complexityFocus,
              onChanged: (_) => editors.schedule(),
              snippetsAllowed: false,
              maxLines: null,
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: AppFonts.monoFamily,
                fontSize: _kEditingComplexitySize,
                height: kLeetCodeCodeLineHeight / _kEditingComplexitySize,
              ),
              decoration: InputDecoration(
                isDense: true,
                hintText: 'O(1)',
                border: const OutlineInputBorder(),
                contentPadding: EdgeInsets.fromLTRB(
                  8,
                  kLeetCodeCodeTopInset,
                  8,
                  kLeetCodeCodeTopInset,
                ),
              ),
            ),
          ),
          _DragGrip(index: index, tooltip: 'Drag to reorder this entry'),
          IconButton(
            icon: const Icon(PhosphorIconsRegular.trash, size: 14),
            tooltip: 'Delete this entry',
            visualDensity: VisualDensity.compact,
            color: theme.colorScheme.error,
            onPressed: onDelete,
          ),
        ],
      ),
    );
  }
}

/// The grab target for a drag, standing in for the handle the framework
/// would have drawn itself.
///
/// [padding] is what lines it up with whatever sits beside it: an entry's grip
/// matches the 40pt box of the trash [IconButton] it shares a top-aligned row
/// with, while the rail's rows are half that tall.
class _DragGrip extends StatelessWidget {
  const _DragGrip({
    required this.index,
    required this.tooltip,
    this.padding = const EdgeInsets.symmetric(horizontal: 6, vertical: 12),
  });

  final int index;
  final String tooltip;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return ReorderableDragStartListener(
      index: index,
      child: MouseRegion(
        cursor: SystemMouseCursors.grab,
        child: Tooltip(
          message: tooltip,
          child: Padding(
            padding: padding,
            child: Icon(
              PhosphorIconsRegular.dotsSixVertical,
              size: 16,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
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
      label = TextEditingController(text: entry.label ?? ''),
      description = TextEditingController(text: entry.description),
      complexity = TextEditingController(text: entry.complexity ?? '') {
    command.addListener(schedule);
    for (final node in [
      commandFocus,
      labelFocus,
      descriptionFocus,
      complexityFocus,
    ]) {
      node.addListener(() {
        if (!node.hasFocus) unawaited(flush());
      });
    }
  }

  final Future<void> Function(String, String, String, String) onSave;

  final LeetCodeCodeController command;
  final TextEditingController label;
  final TextEditingController description;
  final TextEditingController complexity;

  final commandFocus = FocusNode(debugLabel: 'cheatCommand');
  final labelFocus = FocusNode(debugLabel: 'cheatLabel');
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
      onSave(command.fullText, label.text, description.text, complexity.text);

  void dispose() {
    debouncer.dispose();
    command.removeListener(schedule);
    command.dispose();
    label.dispose();
    description.dispose();
    complexity.dispose();
    commandFocus.dispose();
    labelFocus.dispose();
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
