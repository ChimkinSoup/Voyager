import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/companion/gaia_controller.dart';
import 'package:voyager/features/gaia/companion/gaia_notch.dart';
import 'package:voyager/features/gaia/companion/gaia_text_field.dart';
import 'package:voyager/features/gaia/gaia_pipe.dart';

/// A menu row's text, and its muted parts, as in a [GaiaMenu].
const _dim = Color(0xFFD4D4D4);
const _muted = Color(0xFFA3A3A3);

/// Opens Gaia's search (GAIA_HLD.md §17) in a [GaiaPanel] over the middle of
/// the window: chats whose title matches, then messages that do, newest
/// first. Picking one closes it and opens the chat, at the message for a
/// message. Up and Down move between them, Enter picks, Esc or a click
/// outside closes.
Future<void> showGaiaSearch(BuildContext context, GaiaController controller) =>
    showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Close search',
      barrierColor: Colors.black.withValues(alpha: 0.4),
      transitionDuration: const Duration(milliseconds: 150),
      // In, it grows as a menu does, whole, the barrier fading in behind;
      // faded, its fill would come before its faint ring. Out, it fades.
      transitionBuilder: (context, animation, _, child) =>
          animation.status == AnimationStatus.reverse
          ? FadeTransition(opacity: animation, child: child)
          : child,
      pageBuilder: (context, _, _) => _GaiaSearch(controller: controller),
    );

/// A result: a chat by its title, or a message.
typedef _Result = ({GaiaChat chat, GaiaSearchHit? hit});

class _GaiaSearch extends StatefulWidget {
  const _GaiaSearch({required this.controller});

  final GaiaController controller;

  @override
  State<_GaiaSearch> createState() => _GaiaSearchState();
}

class _GaiaSearchState extends State<_GaiaSearch> {
  final _query = TextEditingController();

  /// The field's, which hears Up, Down and Enter before the text does: a
  /// one-line field would take Up and Down to its ends.
  late final _focus = FocusNode(onKeyEvent: (_, event) => _key(event));

  /// The messages found for [_searched], the query last answered.
  var _searched = '';
  var _hits = const <GaiaSearchHit>[];
  Timer? _soon;

  /// The result Enter picks, lit as a hovered one is. Its own notifier, so
  /// hovering rows as the list scrolls under the cursor relights only them.
  final _highlight = ValueNotifier(0);

  /// Each built row's context, by its result's index, to keep the
  /// highlighted one in view.
  final _rows = <int, BuildContext>{};
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _query.addListener(_changed);
    // A chat deleted or renamed while it's open isn't left offered.
    widget.controller.addListener(_chatsChanged);
  }

  /// Rebuilt only as they change, not on every notify: a reply streams.
  late var _chats = widget.controller.chats;

  void _chatsChanged() {
    if (identical(_chats, widget.controller.chats)) return;
    _chats = widget.controller.chats;
    setState(() {});
  }

  @override
  void dispose() {
    widget.controller.removeListener(_chatsChanged);
    _soon?.cancel();
    _query.dispose();
    _focus.dispose();
    _highlight.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// Searched once typing pauses, not on every key.
  void _changed() {
    final query = _query.text.trim();
    if (query == _typed) return;
    _typed = query;
    _soon?.cancel();
    // Rebuilt at once for the chats matched by title.
    _highlight.value = 0;
    setState(() {});
    if (query.isEmpty) return;
    _soon = Timer(
      const Duration(milliseconds: 150),
      () => unawaited(_search(query)),
    );
  }

  /// The query as last typed, so a caret move isn't taken for an edit.
  var _typed = '';

  Future<void> _search(String query) async {
    List<GaiaSearchHit> hits;
    try {
      hits = await widget.controller.searchMessages(query);
    } on GaiaPipeException catch (error) {
      debugPrint('[gaia] search failed: $error');
      hits = const [];
    }
    // Not over a newer query's.
    if (!mounted || _query.text.trim() != query) return;
    setState(() {
      _searched = query;
      _hits = hits;
    });
  }

  /// [_results]'s last, and what it was made from.
  List<_Result> _shown = const [];
  (String, List<GaiaSearchHit>, List<GaiaChat>)? _shownFrom;

  /// Made afresh only as what they're made from changes, not on every
  /// build: there can be hundreds of chats.
  List<_Result> _results(String query) {
    final hits = _searched == query ? _hits : const <GaiaSearchHit>[];
    final chats = widget.controller.chats;
    if (_shownFrom case (final from, final fromHits, final fromChats)
        when from == query &&
            identical(fromHits, hits) &&
            identical(fromChats, chats)) {
      return _shown;
    }
    _shownFrom = (query, hits, chats);
    _rows.clear();
    return _shown = _resultsFor(query, hits);
  }

  List<_Result> _resultsFor(String query, List<GaiaSearchHit> hits) {
    if (query.isEmpty) {
      return [
        for (final chat in [
          ...widget.controller.chats,
        ]..sort((a, b) => b.lastMessageAt.compareTo(a.lastMessageAt)))
          (chat: chat, hit: null),
      ];
    }
    final chats = {for (final chat in widget.controller.chats) chat.id: chat};
    final lower = query.toLowerCase();
    return [
      for (final chat in chats.values)
        if (chat.title.toLowerCase().contains(lower)) (chat: chat, hit: null),
      // A chat deleted since the search went out isn't offered.
      for (final hit in hits)
        if (chats[hit.chatId] case final chat?) (chat: chat, hit: hit),
    ];
  }

  void _pick(_Result result) {
    Navigator.of(context).pop();
    final controller = widget.controller;
    if (result.hit case GaiaSearchHit(:final chatId, :final btwId?)) {
      unawaited(controller.revealBtw(chatId, btwId));
    } else if (result.hit case final hit?) {
      unawaited(controller.revealMessage(hit.chatId, hit.messageId));
    } else {
      unawaited(controller.selectChat(result.chat.id));
    }
  }

  KeyEventResult _key(KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isControlPressed ||
        keyboard.isAltPressed ||
        keyboard.isShiftPressed ||
        keyboard.isMetaPressed) {
      return KeyEventResult.ignored;
    }
    final results = _results(_query.text.trim());
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowDown:
        _move(1, results.length);
      case LogicalKeyboardKey.arrowUp:
        _move(-1, results.length);
      case LogicalKeyboardKey.enter || LogicalKeyboardKey.numpadEnter
          when event is KeyDownEvent:
        if (results.isNotEmpty) {
          _pick(results[_highlight.value.clamp(0, results.length - 1)]);
        }
      default:
        return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  void _move(int by, int count) {
    if (count == 0) return;
    final to = _highlight.value = (_highlight.value + by) % count;
    // Kept in view, once it's laid out where it now is.
    void reveal({required bool again}) {
      final row = _rows[to];
      if (row != null && row.mounted) {
        Scrollable.ensureVisible(
          row,
          duration: const Duration(milliseconds: 100),
          // Come round, it's put at the end it came round to: the list's
          // guess at its length may have left it past that end.
          alignment: by > 0 ? 0 : 1,
          alignmentPolicy: !again
              ? ScrollPositionAlignmentPolicy.explicit
              : by > 0
              ? ScrollPositionAlignmentPolicy.keepVisibleAtEnd
              : ScrollPositionAlignmentPolicy.keepVisibleAtStart,
        );
      } else if (again && _scroll.hasClients) {
        // Not built: come round from one end to the other.
        final position = _scroll.position;
        _scroll.jumpTo(
          by > 0 ? position.minScrollExtent : position.maxScrollExtent,
        );
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => reveal(again: false),
        );
      }
    }

    WidgetsBinding.instance.addPostFrameCallback((_) => reveal(again: true));
  }

  @override
  Widget build(BuildContext context) {
    final query = _query.text.trim();
    final results = _results(query);
    final named = results.where((result) => result.hit == null).length;
    // A heading's text, or a result's index.
    final items = <Object>[
      for (final (i, _) in results.indexed) ...[
        if (i == 0 && named > 0) query.isEmpty ? 'Recent' : 'Chats',
        if (i == named) 'Messages',
        i,
      ],
    ];
    final size = MediaQuery.sizeOf(context);
    final message = results.isNotEmpty
        ? null
        : query.isEmpty
        ? 'No chats yet'
        : _searched == query
        ? 'No matches'
        : null;
    return Center(
      child: GaiaPanel(
        child: SizedBox(
          width: min(720, size.width - 32),
          height: min(600, size.height - 64),
          // For the field and the rows' text, as a dialog's would have.
          child: Material(
            type: MaterialType.transparency,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.all(8),
                  // The glass over the field, centred on it however tall its
                  // text makes it: the field keeps a leading widget at its
                  // bottom.
                  child: Stack(
                    alignment: AlignmentDirectional.centerStart,
                    children: [
                      GaiaTextField(
                        controller: _query,
                        focusNode: _focus,
                        autofocus: true,
                        hintText: 'Search chats',
                        leading: const SizedBox(width: 24),
                      ),
                      const IgnorePointer(
                        child: Padding(
                          padding: EdgeInsetsDirectional.only(start: 12),
                          child: Icon(Icons.search, size: 18, color: _muted),
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: message != null
                      ? Center(
                          child: Text(
                            message,
                            style: const TextStyle(
                              fontSize: 13,
                              color: Color(0xFF737373),
                            ),
                          ),
                        )
                      : ScrollConfiguration(
                          // Scrolls without a bar.
                          behavior: ScrollConfiguration.of(
                            context,
                          ).copyWith(scrollbars: false),
                          // Only the rows in view are built.
                          child: ListView.builder(
                            controller: _scroll,
                            padding: const EdgeInsets.fromLTRB(6, 0, 6, 6),
                            itemCount: items.length,
                            itemBuilder: (context, n) => switch (items[n]) {
                              final int i => Builder(
                                builder: (context) {
                                  _rows[i] = context;
                                  return MouseRegion(
                                    cursor: SystemMouseCursors.click,
                                    onEnter: (_) => _highlight.value = i,
                                    child: GestureDetector(
                                      behavior: HitTestBehavior.opaque,
                                      onTap: () => _pick(results[i]),
                                      child: _Lit(
                                        highlight: _highlight,
                                        index: i,
                                        last: results.length - 1,
                                        builder: (lit) =>
                                            _Row(result: results[i], lit: lit),
                                      ),
                                    ),
                                  );
                                },
                              ),
                              final heading => _Heading('$heading'),
                            },
                          ),
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

/// [builder]'s row, lit while [highlight] is on [index] (or past [last], on
/// the last), and rebuilt only as that changes: not every row in view each
/// time the cursor crosses one.
class _Lit extends StatefulWidget {
  const _Lit({
    required this.highlight,
    required this.index,
    required this.last,
    required this.builder,
  });

  final ValueNotifier<int> highlight;
  final int index;
  final int last;
  final Widget Function(bool lit) builder;

  @override
  State<_Lit> createState() => _LitState();
}

class _LitState extends State<_Lit> {
  late var _lit = _now;

  bool get _now => widget.index == min(widget.highlight.value, widget.last);

  @override
  void initState() {
    super.initState();
    widget.highlight.addListener(_changed);
  }

  @override
  void didUpdateWidget(_Lit old) {
    super.didUpdateWidget(old);
    old.highlight.removeListener(_changed);
    widget.highlight.addListener(_changed);
    _lit = _now;
  }

  @override
  void dispose() {
    widget.highlight.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (_now != _lit) setState(() => _lit = _now);
  }

  @override
  Widget build(BuildContext context) => widget.builder(_lit);
}

/// Heads a group of the results.
class _Heading extends StatelessWidget {
  const _Heading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(10, 10, 10, 6),
    child: Text(
      text,
      style: const TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.4,
        color: Color(0xFF737373),
      ),
    ),
  );
}

/// A result, as a [GaiaMenu]'s row is drawn: a chat by its title, or a
/// message as its chat's title over the snippet of its text, the matched
/// terms lit in the accent.
class _Row extends StatelessWidget {
  const _Row({required this.result, required this.lit});

  final _Result result;
  final bool lit;

  /// [snippet] on one line, its marked terms in [style].
  static List<TextSpan> _spans(String snippet, TextStyle style) => [
    for (final (i, piece)
        in snippet
            .replaceAll(RegExp(r'\s+'), ' ')
            .split(GaiaSearchHit.start)
            .indexed)
      if (i == 0)
        TextSpan(text: piece)
      else if (piece.split(GaiaSearchHit.end) case [
        final term,
        ...final rest,
      ]) ...[
        TextSpan(text: term, style: style),
        TextSpan(text: rest.join()),
      ],
  ];

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final color = lit ? Colors.white : _dim;
    final hit = result.hit;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      margin: const EdgeInsets.only(bottom: 2),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: lit ? 0.05 : 0),
        borderRadius: BorderRadius.circular(6),
      ),
      child: hit == null
          ? Row(
              children: [
                Icon(
                  Icons.chat_bubble_outline,
                  size: 16,
                  color: lit ? color : _muted,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    result.chat.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: color,
                    ),
                  ),
                ),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 2,
              children: [
                Text(
                  // A side question's, under its chat (GAIA_BTW_HLD.md §9).
                  hit.btwId == null
                      ? result.chat.title
                      : '${result.chat.title} · btw',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    color: _muted,
                  ),
                ),
                Text.rich(
                  TextSpan(
                    children: _spans(
                      hit.snippet,
                      TextStyle(color: accent, fontWeight: FontWeight.w600),
                    ),
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, height: 1.35, color: color),
                ),
              ],
            ),
    );
  }
}
