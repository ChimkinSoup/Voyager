import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/companion/gaia_button.dart';
import 'package:voyager/features/gaia/companion/gaia_controller.dart';
import 'package:voyager/features/gaia/companion/gaia_markdown.dart';
import 'package:voyager/features/gaia/companion/gaia_spinner.dart';
import 'package:voyager/features/gaia/companion/gaia_text_field.dart';
import 'package:voyager/features/gaia/companion/gaia_toast.dart';

const _dim = Color(0xFFD4D4D4);
const _muted = Color(0xFFA3A3A3);
const _faint = Color(0xFF737373);

/// The answer's card: darker than the field fill the panel is.
const _tray = Color(0xFF1C1C1F);
const _cardEdge = Color(0xFF3F3F46);

/// The tallest the answer gets before it scrolls, the list aside.
const _answerMax = 420.0;

/// The [TapRegion] group of the side questions and the composer: a click
/// outside all of it closes them.
const gaiaBtwTapGroup = #gaiaBtw;

/// The chat in view's side questions (GAIA_BTW_HLD.md §8.1), docked under
/// the chat, on top of the composer, while open: the list, newest first,
/// over the selected one's answer. It opens where the controller asks
/// (§8.2): `/btw`, a btw just asked, the chip, or a search's hit; already
/// open, it moves there. Up and Down move between them, from the composer
/// too ([GaiaBtwDockState.move]); Alt+C copies the answer, Alt+F forks it,
/// Alt+X clears them all ([GaiaBtwDockState.shortcut]). Esc closes it, as
/// does another chat; one still streaming carries on.
class GaiaBtwDock extends StatefulWidget {
  const GaiaBtwDock({
    super.key,
    required this.controller,
    required this.maxHeight,
  });

  final GaiaController controller;

  /// The chat's height over the field, which it may fill before its answer
  /// scrolls.
  final double maxHeight;

  @override
  State<GaiaBtwDock> createState() => GaiaBtwDockState();
}

/// A row of the list, and how many show before it scrolls.
const _rowExtent = 34.0;
const _rowsShown = 5;
const _listPad = EdgeInsets.fromLTRB(6, 6, 6, 4);

class GaiaBtwDockState extends State<GaiaBtwDock> {
  /// The chat it was opened on; null while closed.
  String? _openOn;
  String? _selected;
  final _focus = FocusNode(debugLabel: 'Side questions');
  final _list = ScrollController();

  /// The btw last shown on each chat, which it opens at again.
  final _lastViewed = <String, String>{};

  late final StreamSubscription<String?> _opens;

  GaiaController get _controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _opens = _controller.btwOpens.listen(_open);
  }

  @override
  void dispose() {
    unawaited(_opens.cancel());
    _focus.dispose();
    _list.dispose();
    // Not while the tree is torn down, which the chip's rebuild would be.
    if (_openOn != null) {
      scheduleMicrotask(() {
        _controller
          ..btwPanelOpen = false
          ..btwShown = null;
      });
    }
    super.dispose();
  }

  void _open(String? at) {
    if (!mounted) return;
    setState(() {
      _openOn = _controller.currentChatId;
      _selected = at ?? _lastViewed[_openOn];
    });
    _controller.btwPanelOpen = true;
    // Its keys work at once, as the dialog's did.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _openOn != null) _focus.requestFocus();
    });
    _reveal();
  }

  /// Selects the btw [by] rows down the list, or up for negative; false
  /// while closed, or with none to move along.
  bool move(int by) {
    if (_openOn == null) return false;
    final btws = _btws;
    final current = _current(btws);
    if (current == null) return false;
    final to = (btws.indexOf(current) + by).clamp(0, btws.length - 1);
    _select(btws[to].id);
    return true;
  }

  void _select(String id) {
    setState(() => _selected = id);
    _reveal();
  }

  /// Scrolls the list just far enough to show the selected row, once laid
  /// out.
  void _reveal() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!_list.hasClients) return;
      final btws = _btws;
      final current = _current(btws);
      if (current == null) return;
      final position = _list.position;
      final top = _listPad.top + btws.indexOf(current) * _rowExtent;
      final bottom = top + _rowExtent + _listPad.bottom;
      final double to;
      if (top - _listPad.top < position.pixels) {
        to = top - _listPad.top;
      } else if (bottom > position.pixels + position.viewportDimension) {
        to = bottom - position.viewportDimension;
      } else {
        return;
      }
      unawaited(
        _list.animateTo(
          to.clamp(0, position.maxScrollExtent),
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
        ),
      );
    });
  }

  /// Closes it; false when it wasn't open.
  bool close() {
    if (_openOn == null) return false;
    setState(() => _openOn = null);
    _focus.unfocus();
    _controller.btwPanelOpen = false;
    _controller.btwShown = null;
    return true;
  }

  /// Newest first.
  List<GaiaBtw> get _btws =>
      _controller.btwsFor(_controller.currentChatId).reversed.toList();

  /// The selected one; the newest when none is, or it's gone.
  GaiaBtw? _current(List<GaiaBtw> btws) =>
      btws.where((btw) => btw.id == _selected).firstOrNull ?? btws.firstOrNull;

  /// Alt+C copies the selected answer, Alt+F forks it and Alt+X clears them
  /// all, from the composer too; with Alt, so a letter typed always types.
  /// False when [event] is none of them, or it's closed.
  bool shortcut(KeyEvent event) {
    final keyboard = HardwareKeyboard.instance;
    if (_openOn == null ||
        event is! KeyDownEvent ||
        !keyboard.isAltPressed ||
        keyboard.isControlPressed ||
        keyboard.isShiftPressed ||
        keyboard.isMetaPressed) {
      return false;
    }
    final current = _current(_btws);
    switch (event.logicalKey) {
      case LogicalKeyboardKey.keyC:
        if (current != null && current.answer.isNotEmpty) _copy(current);
      case LogicalKeyboardKey.keyF:
        if (current != null && _forkable(current)) _fork(current);
      case LogicalKeyboardKey.keyX:
        unawaited(_clear());
      default:
        return false;
    }
    return true;
  }

  /// Its own keys while focused; the letters go on to the composer.
  KeyEventResult _key(KeyEvent event) {
    if (shortcut(event)) return KeyEventResult.handled;
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isControlPressed ||
        keyboard.isAltPressed ||
        keyboard.isMetaPressed) {
      return KeyEventResult.ignored;
    }
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowUp:
        move(-1);
      case LogicalKeyboardKey.arrowDown:
        move(1);
      case LogicalKeyboardKey.escape when event is KeyDownEvent:
        close();
      default:
        return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  /// Failed and stopped ones too, as a handoff (§7).
  static bool _forkable(GaiaBtw btw) =>
      btw.status != GaiaMessageStatus.streaming;

  void _copy(GaiaBtw btw) {
    unawaited(Clipboard.setData(ClipboardData(text: btw.answer)));
    showGaiaToast(
      context,
      mark: GaiaToastMark.done,
      title: 'Copied',
      body: 'The answer is on the clipboard.',
    );
  }

  void _fork(GaiaBtw btw) {
    close();
    unawaited(_controller.forkBtw(btw));
  }

  /// All of them, with a toast to undo it (§4.2).
  Future<void> _clear() async {
    final chatId = _controller.currentChatId;
    final ids = await _controller.clearBtws();
    if (chatId == null || ids == null || !mounted) return;
    showGaiaToast(
      context,
      mark: GaiaToastMark.done,
      title: 'Cleared side questions',
      body: 'Click to undo',
      onTap: () => _controller.restoreBtws(chatId, ids),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_openOn == null) return const SizedBox.shrink();
    final accent = Theme.of(context).colorScheme.primary;
    // A click outside both it and the composer closes it.
    return TapRegion(
      groupId: gaiaBtwTapGroup,
      onTapOutside: (_) => close(),
      child: TapRegion(
        // A click elsewhere gives up its keys, so the composer can take them.
        onTapOutside: (_) {
          if (_focus.hasFocus) _focus.unfocus();
        },
        onTapInside: (_) {
          if (!_focus.hasFocus) _focus.requestFocus();
        },
        child: Focus(
          focusNode: _focus,
          onKeyEvent: (_, event) => _key(event),
          child: Container(
            // Squared off at the bottom, where it meets the composer.
            decoration: BoxDecoration(
              // Opaque, as the field it sits on.
              color: gaiaFieldFill,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(8),
              ),
              border: Border(top: BorderSide(color: accent, width: 2)),
            ),
            constraints: BoxConstraints(maxHeight: max(160, widget.maxHeight)),
            child: ListenableBuilder(
              listenable: Listenable.merge([
                _controller,
                _controller.btwStreamed,
              ]),
              builder: (context, _) {
                if (_controller.currentChatId != _openOn) {
                  // Another chat in view: they're that chat's no longer.
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted) close();
                  });
                  return const SizedBox.shrink();
                }
                return _body(context, accent);
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _body(BuildContext context, Color accent) {
    final btws = _btws;
    final current = _current(btws);
    final closer = Tooltip(
      message: 'Close (Esc)',
      child: GaiaButton(icon: Icons.close, size: 28, onPressed: close),
    );
    if (current == null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
        child: Row(
          children: [
            const Expanded(
              child: Text(
                'No side questions in this chat yet. Ask one with '
                '/btw <question>.',
                style: TextStyle(fontSize: 13, color: _faint),
              ),
            ),
            closer,
          ],
        ),
      );
    }
    _lastViewed[_openOn!] = _controller.btwShown = current.id;
    final ours = _controller.btwRunning(current.id);
    final picker = btws.length > 1 ? _rows(context, btws, current) : null;
    final answer = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 10,
      children: [
        if (current.answer.isNotEmpty) GaiaMarkdown(text: current.answer),
        if (_status(current, ours: ours) case final status?)
          Text(status, style: const TextStyle(fontSize: 12, color: _faint)),
      ],
    );
    final behavior = ScrollConfiguration.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // With more than one, the list over the answer's card.
        ?picker,
        Flexible(
          // No scrollbar of its own; a code block's keeps its.
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: _answerMax),
            child: ScrollConfiguration(
              behavior: behavior.copyWith(scrollbars: false),
              child: SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(8, picker == null ? 8 : 0, 8, 4),
                child: ScrollConfiguration(
                  behavior: behavior,
                  child: _card(current, answer, accent),
                ),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 8, 8),
          child: Row(
            spacing: 6,
            children: [
              Expanded(
                child: Text(
                  [
                    if (btws.length > 1) '↑/↓ to switch',
                    'Alt+C to copy',
                    'Alt+F to fork',
                    'Alt+X to clear',
                    'Esc to close',
                  ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11, color: _faint),
                ),
              ),
              if (ours)
                Tooltip(
                  message: 'Stop',
                  child: GaiaButton(
                    icon: Icons.stop,
                    size: 28,
                    onPressed: () => _controller.stopBtw(current.id),
                  ),
                ),
              Tooltip(
                message: 'Copy (Alt+C)',
                child: GaiaButton(
                  icon: Icons.copy,
                  size: 28,
                  onPressed: current.answer.isEmpty
                      ? null
                      : () => _copy(current),
                ),
              ),
              Tooltip(
                message: 'Continue as a chat (Alt+F)',
                child: GaiaButton(
                  icon: Icons.call_split,
                  size: 28,
                  onPressed: _forkable(current) ? () => _fork(current) : null,
                ),
              ),
              Tooltip(
                message: 'Clear history (Alt+X)',
                child: GaiaButton(
                  icon: Icons.delete_sweep_outlined,
                  size: 28,
                  onPressed: () => unawaited(_clear()),
                ),
              ),
              closer,
            ],
          ),
        ),
      ],
    );
  }

  /// The answer in an inset card, headed by its question in bold accent, so
  /// the question never reads as part of the answer.
  Widget _card(GaiaBtw btw, Widget answer, Color accent) => Container(
    padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
    decoration: BoxDecoration(
      color: _tray,
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: _cardEdge),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 8,
      children: [
        Text(
          btw.question,
          style: TextStyle(
            fontSize: 13.5,
            fontWeight: FontWeight.w700,
            color: accent,
          ),
        ),
        answer,
      ],
    ),
  );

  /// The list, five rows tall before it scrolls.
  Widget _rows(BuildContext context, List<GaiaBtw> btws, GaiaBtw current) =>
      ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: _listPad.vertical + _rowsShown * _rowExtent,
        ),
        child: ScrollConfiguration(
          behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
          child: ListView(
            controller: _list,
            shrinkWrap: true,
            itemExtent: _rowExtent,
            padding: _listPad,
            children: [for (final btw in btws) _row(btw, current)],
          ),
        ),
      );

  Widget _row(GaiaBtw btw, GaiaBtw current) => _Row(
    btw: btw,
    lit: btw.id == current.id,
    elsewhere:
        btw.status == GaiaMessageStatus.streaming &&
        !_controller.btwRunning(btw.id),
    onTap: () => _select(btw.id),
  );

  /// What the answer's end says of how it ended, or that it hasn't.
  static String? _status(GaiaBtw btw, {required bool ours}) =>
      switch (btw.status) {
        GaiaMessageStatus.streaming when !ours =>
          'Answering on ${btw.device.isEmpty ? 'another device' : btw.device}…',
        GaiaMessageStatus.streaming when btw.answer.isEmpty => 'Answering…',
        GaiaMessageStatus.error => btw.error ?? 'It failed.',
        // A notice beside an answer (GAIA_BTW_HLD.md §5.1).
        GaiaMessageStatus.complete => btw.error,
        GaiaMessageStatus.cancelled => 'Stopped.',
        _ => null,
      };
}

/// A side question in the list: its question on one line, with a spinner while it's answered. It lights under the mouse,
/// and more in the accent when selected.
class _Row extends StatefulWidget {
  const _Row({
    required this.btw,
    required this.lit,
    required this.elsewhere,
    required this.onTap,
  });

  final GaiaBtw btw;
  final bool lit;

  /// Answered on another device, which it names.
  final bool elsewhere;
  final VoidCallback onTap;

  @override
  State<_Row> createState() => _RowState();
}

class _RowState extends State<_Row> {
  var _hovered = false;

  @override
  Widget build(BuildContext context) {
    final btw = widget.btw;
    final lit = widget.lit;
    final accent = Theme.of(context).colorScheme.primary;
    final question = Text(
      btw.question.replaceAll(RegExp(r'\s+'), ' '),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: 13,
        color: lit || _hovered ? Colors.white : _dim,
      ),
    );
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          margin: const EdgeInsets.only(bottom: 2),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            // In the accent, as the card's question below it.
            color: lit
                ? accent.withValues(alpha: 0.16)
                : Colors.white.withValues(alpha: _hovered ? 0.06 : 0),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            spacing: 8,
            children: [
              Expanded(child: question),
              if (btw.status == GaiaMessageStatus.streaming) ...[
                if (widget.elsewhere)
                  Text(
                    btw.device.isEmpty ? 'elsewhere' : btw.device,
                    style: const TextStyle(fontSize: 11, color: _muted),
                  ),
                const GaiaSpinner(size: 14, label: 'Answering'),
              ] else if (btw.status == GaiaMessageStatus.error)
                const Icon(Icons.error_outline, size: 14, color: _muted),
            ],
          ),
        ),
      ),
    );
  }
}

/// Above the composer while the chat in view has side questions (§8.2):
/// how many, spinning while one streams with the panel closed. Clicked, it
/// opens them.
class GaiaBtwChip extends StatelessWidget {
  const GaiaBtwChip({super.key, required this.controller});

  final GaiaController controller;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: controller.btwStreamed,
    builder: (context, _, _) {
      final btws = controller.btwsFor(controller.currentChatId);
      if (btws.isEmpty) return const SizedBox.shrink();
      final theme = Theme.of(context);
      final accent = theme.colorScheme.primary;
      final streaming =
          !controller.btwPanelOpen &&
          btws.any((btw) => btw.status == GaiaMessageStatus.streaming);
      return InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: controller.openBtws,
        child: Container(
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
            spacing: 4,
            children: [
              if (streaming)
                GaiaSpinner(size: 12, color: accent, label: 'Answering')
              else
                Icon(Icons.forum_outlined, size: 12, color: accent),
              Text(
                btws.length == 1 ? '1 btw' : '${btws.length} btws',
                style: theme.textTheme.labelSmall?.copyWith(color: accent),
              ),
            ],
          ),
        ),
      );
    },
  );
}
