import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show OverflowBoxFit;
import 'package:flutter/services.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/companion/gaia_button.dart';
import 'package:voyager/features/gaia/companion/gaia_card_text_field.dart';
import 'package:voyager/features/gaia/companion/gaia_controller.dart';
import 'package:voyager/features/gaia/companion/gaia_memory_card.dart';
import 'package:voyager/features/gaia/companion/gaia_orb_materials.dart';
import 'package:voyager/features/gaia/companion/gaia_settings_panel.dart';
import 'package:voyager/features/gaia/companion/gaia_style.dart';
import 'package:voyager/features/gaia/companion/gaia_topic_picker.dart';
import 'package:voyager/features/gaia/gaia_pipe.dart';
import 'package:voyager/features/gaia/host/gaia_memories.dart';
import 'package:voyager/features/gaia/remote/gaia_remote.dart' show gaiaWhen;

/// The decks a review goes through (GAIA_SETTINGS_HLD.md §6.1); [memory] is
/// one memory, asked about from its card in the list (§7.1).
enum GaiaReviewDeck { inbox, topic, unsorted, memory }

/// One card of a deck, by id, as it was when the deck was dealt.
sealed class GaiaReviewItem {
  const GaiaReviewItem();
}

/// A memory: proposed in the inbox, remembered in a topic, or unsorted.
final class GaiaReviewMemory extends GaiaReviewItem {
  const GaiaReviewMemory(this.id);

  final String id;
}

final class GaiaReviewPin extends GaiaReviewItem {
  const GaiaReviewPin(this.id, this.why);

  final String id;
  final String why;
}

/// Two topics to merge, as they were dealt: named so even once merged.
final class GaiaReviewMerge extends GaiaReviewItem {
  const GaiaReviewMerge(this.from, this.into, this.why);

  final GaiaMemoryTopic from;
  final GaiaMemoryTopic into;
  final String why;
}

/// One of the weekly sweep's suggestions (GAIA_MEMORY_TOPICS_HLD.md §27.4),
/// as it was dealt.
final class GaiaReviewSweep extends GaiaReviewItem {
  const GaiaReviewSweep(this.suggestion);

  final GaiaMemorySuggestion suggestion;
}

/// Which way a decided card leaves (§6.2).
enum GaiaReviewExit { up, down, aside }

/// What a card was decided as, as the summary counts it.
enum GaiaReviewOutcome {
  remembered('remembered', GaiaReviewExit.up),
  updated('updated', GaiaReviewExit.up),
  declined('declined', GaiaReviewExit.down),
  skipped('skipped', GaiaReviewExit.aside),
  kept('kept', GaiaReviewExit.up),
  archived('archived', GaiaReviewExit.down),
  deleted('deleted', GaiaReviewExit.down),
  pinned('pinned', GaiaReviewExit.up),
  putOff('put off', GaiaReviewExit.down),
  merged('merged', GaiaReviewExit.up),
  keptApart('kept apart', GaiaReviewExit.down),
  filed('filed', GaiaReviewExit.up),
  leftUnsorted('left unsorted', GaiaReviewExit.down),
  renamed('renamed', GaiaReviewExit.up),
  keptBoth('kept both', GaiaReviewExit.down);

  const GaiaReviewOutcome(this.word, this.exit);

  final String word;
  final GaiaReviewExit exit;
}

/// What a card asks: one of §6.2's rows, one of the sweep's suggestions
/// (GAIA_MEMORY_TOPICS_HLD.md §27.4), or nothing, once it's decided here or
/// elsewhere.
enum GaiaReviewKind {
  proposed,
  remembered,
  pin,
  merge,
  unsorted,
  same,
  conflict,
  expired,
  topicMerge,
  topicRename,
  done,
}

/// A card as it shows now, from the Memories tab's latest list.
typedef GaiaReviewCard = ({
  int index,
  GaiaReviewKind kind,
  GaiaMemory? memory,
  String? why,
  GaiaMemoryTopic? from,
  GaiaMemoryTopic? into,
  GaiaReviewOutcome? outcome,
  GaiaMemorySuggestion? suggestion,
});

/// How a decision is undone; null for one that wrote nothing.
typedef GaiaReviewUndo = Future<void> Function()?;

class _Decision {
  _Decision(this.index, this.outcome);

  final int index;

  /// Null for one that leaves the card in front (a pin).
  final GaiaReviewOutcome? outcome;

  /// The write, giving back its undo.
  late final Future<GaiaReviewUndo> written;
}

/// A review in progress (GAIA_SETTINGS_HLD.md §6): a deck fixed when it's
/// dealt, the card in front, what each card was decided as, and the
/// decisions to undo, last first. A card decided elsewhere is skipped when
/// its turn comes.
class GaiaMemoryReview extends ChangeNotifier {
  GaiaMemoryReview._(this._controller, this.deck, this.title, this.items) {
    _next(0);
  }

  /// The inbox: proposed memories, oldest first, then pin and merge
  /// suggestions, then the weekly sweep's.
  factory GaiaMemoryReview.inbox(GaiaController controller) {
    final list = controller.memoryList!;
    return GaiaMemoryReview._(controller, GaiaReviewDeck.inbox, 'the inbox', [
      for (final memory in list.memories)
        if (memory.status == GaiaMemoryStatus.proposed)
          GaiaReviewMemory(memory.id),
      for (final pin in list.pins) GaiaReviewPin(pin.memory.id, pin.why),
      for (final merge in list.merges)
        GaiaReviewMerge(merge.from, merge.into, merge.why),
      for (final suggestion in list.suggestions)
        if (suggestion.kind != GaiaSuggestionKind.place)
          GaiaReviewSweep(suggestion),
    ]);
  }

  /// The remembered memories in the topics [scope], oldest first, for
  /// pruning; [title] names the topic.
  factory GaiaMemoryReview.topic(
    GaiaController controller,
    Set<String> scope,
    String title,
  ) => GaiaMemoryReview._(controller, GaiaReviewDeck.topic, title, [
    for (final memory in controller.memoryList!.memories)
      if (memory.status == GaiaMemoryStatus.active &&
          memory.topicIds.any(scope.contains))
        GaiaReviewMemory(memory.id),
  ]);

  /// One memory, proposed or remembered, with its Ask Gaia chat open: Ask
  /// Gaia from its card in the list.
  factory GaiaMemoryReview.memory(
    GaiaController controller,
    GaiaMemory memory,
  ) => GaiaMemoryReview._(controller, GaiaReviewDeck.memory, 'this memory', [
    GaiaReviewMemory(memory.id),
  ])..asked.add(memory.id);

  /// The remembered memories in no topic, oldest first, each with where the
  /// utility model would file it, asked for a batch ahead.
  factory GaiaMemoryReview.unsorted(GaiaController controller) {
    final list = controller.memoryList!;
    final tree = GaiaTopicTree(list.topics);
    return GaiaMemoryReview._(controller, GaiaReviewDeck.unsorted, 'Unsorted', [
      for (final memory in list.memories)
        if (memory.status == GaiaMemoryStatus.active && _unsorted(memory, tree))
          GaiaReviewMemory(memory.id),
    ]);
  }

  final GaiaController _controller;
  final GaiaReviewDeck deck;
  final String title;
  final List<GaiaReviewItem> items;

  /// The card in front; [items]' length once the deck is done.
  var index = 0;
  final outcomes = <int, GaiaReviewOutcome>{};
  final _decisions = <_Decision>[];

  /// The undos in flight, run one at a time.
  Future<void> _undoing = Future.value();

  /// The card animating off, and a serial that starts its animation.
  ({GaiaReviewCard card, GaiaReviewExit exit})? leaving;
  var leavingSerial = 0;

  /// Unsorted memories the utility model has answered for.
  final _asked = <String>{};

  /// Waiting for a sort already running to end, to ask after it.
  var _waiting = false;

  /// The memories whose Ask Gaia chat shows whenever their card is in
  /// front, for the rest of the review (§7.1).
  final asked = <String>{};

  /// The memory whose source chat was last shown from its card's source
  /// line (§6.2), shown again whenever that card is in front, in place of
  /// its Ask Gaia chat.
  String? sourceOf;

  /// Esc in an Ask Gaia chat's composer (§7.1): the keys back to the deck,
  /// the chat left showing. The view takes it and sets it back.
  var wantsKeys = false;

  void backToDeck() {
    wantsKeys = true;
    notifyListeners();
  }

  /// Esc on the deck with the Ask Gaia chat showing: it stays closed.
  void dismissAsk(String memoryId) {
    if (!asked.remove(memoryId)) return;
    notifyListeners();
  }

  /// A memory proposed from an Ask Gaia chat (§6.1): an inbox deck takes it
  /// at its end.
  void addProposal(String memoryId) {
    if (deck != GaiaReviewDeck.inbox ||
        items.any((item) => item is GaiaReviewMemory && item.id == memoryId)) {
      return;
    }
    items.add(GaiaReviewMemory(memoryId));
    notifyListeners();
  }

  bool get finished => index >= items.length;
  bool get canUndo => _decisions.isNotEmpty;

  /// The card whose decision Ctrl+Z undoes next.
  int? get lastDecided => _decisions.lastOrNull?.index;

  GaiaReviewCard card(int i) {
    final list = _controller.memoryList!;
    final outcome = outcomes[i];
    GaiaMemory? find(String id) =>
        list.memories.where((memory) => memory.id == id).firstOrNull;
    GaiaReviewCard of(
      GaiaReviewKind kind, {
      GaiaMemory? memory,
      String? why,
      GaiaMemoryTopic? from,
      GaiaMemoryTopic? into,
      GaiaMemorySuggestion? suggestion,
    }) => (
      index: i,
      kind: outcome == null ? kind : GaiaReviewKind.done,
      memory: memory,
      why: why,
      from: from,
      into: into,
      outcome: outcome,
      suggestion: suggestion,
    );
    switch (items[i]) {
      case GaiaReviewMemory(:final id):
        final memory = find(id);
        final open = switch (deck) {
          _ when memory == null => GaiaReviewKind.done,
          GaiaReviewDeck.inbox =>
            memory.status == GaiaMemoryStatus.proposed
                ? GaiaReviewKind.proposed
                : GaiaReviewKind.done,
          GaiaReviewDeck.topic =>
            memory.status == GaiaMemoryStatus.active
                ? GaiaReviewKind.remembered
                : GaiaReviewKind.done,
          GaiaReviewDeck.memory => switch (memory.status) {
            GaiaMemoryStatus.proposed => GaiaReviewKind.proposed,
            GaiaMemoryStatus.active => GaiaReviewKind.remembered,
            GaiaMemoryStatus.archived => GaiaReviewKind.done,
          },
          GaiaReviewDeck.unsorted =>
            memory.status == GaiaMemoryStatus.active &&
                    _unsorted(memory, GaiaTopicTree(list.topics))
                ? GaiaReviewKind.unsorted
                : GaiaReviewKind.done,
        };
        return of(open, memory: memory);
      case GaiaReviewPin(:final id, :final why):
        return of(
          list.pins.any((pin) => pin.memory.id == id)
              ? GaiaReviewKind.pin
              : GaiaReviewKind.done,
          memory: find(id),
          why: why,
        );
      case GaiaReviewMerge(:final from, :final into, :final why):
        GaiaMemoryTopic topic(GaiaMemoryTopic dealt) =>
            list.topics.where((topic) => topic.id == dealt.id).firstOrNull ??
            dealt;
        return of(
          list.merges.any(
                (merge) => merge.from.id == from.id && merge.into.id == into.id,
              )
              ? GaiaReviewKind.merge
              : GaiaReviewKind.done,
          why: why,
          from: topic(from),
          into: topic(into),
        );
      case GaiaReviewSweep(:final suggestion):
        final live = list.suggestions
            .where((s) => s.id == suggestion.id)
            .firstOrNull;
        return of(
          live == null
              ? GaiaReviewKind.done
              : switch (live.kind) {
                  GaiaSuggestionKind.same => GaiaReviewKind.same,
                  GaiaSuggestionKind.conflict => GaiaReviewKind.conflict,
                  GaiaSuggestionKind.expired => GaiaReviewKind.expired,
                  GaiaSuggestionKind.topicMerge => GaiaReviewKind.topicMerge,
                  GaiaSuggestionKind.topicRename => GaiaReviewKind.topicRename,
                  GaiaSuggestionKind.place => GaiaReviewKind.done,
                },
          why: suggestion.why,
          suggestion: live ?? suggestion,
        );
    }
  }

  /// The first card from [from] on still to decide, or the end.
  void _next(int from) {
    var i = from;
    while (i < items.length && card(i).kind == GaiaReviewKind.done) {
      i++;
    }
    index = i;
    _askAhead();
  }

  /// Unsorted: where the utility model would file this batch and the next,
  /// each memory asked about once it's answered; after a sort already
  /// running, and again on the next card after one that failed.
  void _askAhead() {
    if (deck != GaiaReviewDeck.unsorted) return;
    if (_controller.memorySortRunning case final running?) {
      if (_waiting) return;
      _waiting = true;
      unawaited(
        running.then((_) {
          _waiting = false;
          if (_controller.review == this) _askAhead();
        }),
      );
      return;
    }
    final list = _controller.memoryList!;
    final ask = [
      for (final item in items.skip(index).take(2 * kGaiaSortBatch))
        if (item case GaiaReviewMemory(:final id)
            when !_asked.contains(id) &&
                !_controller.memorySorted.containsKey(id))
          ?list.memories.where((memory) => memory.id == id).firstOrNull,
    ];
    if (ask.isEmpty) return;
    unawaited(_sort(ask));
  }

  Future<void> _sort(List<GaiaMemory> ask) async {
    await _controller.sortMemories(ask);
    if (_controller.memorySortError == null) {
      _asked.addAll(ask.map((memory) => memory.id));
    }
  }

  /// → on a card already decided: the next one to decide.
  void forward() {
    if (finished) return;
    leaving = null;
    _next(index + 1);
    notifyListeners();
  }

  /// ←: the card before, decided or not, but not one skipped unseen.
  void back() {
    for (var i = index - 1; i >= 0; i--) {
      if (outcomes.containsKey(i) || card(i).kind != GaiaReviewKind.done) {
        index = i;
        leaving = null;
        notifyListeners();
        return;
      }
    }
  }

  /// The card in front decided as [outcome] by [write], which gives back
  /// its undo. It animates off and the next comes up at once, the write
  /// going on behind; one refused puts the card back, saying why. A null
  /// [outcome] leaves the card in front (a pin).
  void decide(
    GaiaReviewOutcome? outcome,
    Future<GaiaReviewUndo> Function() write,
  ) {
    if (finished) return;
    final at = index;
    final decision = _Decision(at, outcome);
    _decisions.add(decision);
    if (outcome != null) {
      // It goes off just as it stood, so it keeps its size.
      leaving = (card: card(at), exit: outcome.exit);
      outcomes[at] = outcome;
      leavingSerial++;
      _next(at + 1);
    }
    notifyListeners();
    decision.written = write();
    unawaited(_putBackIfRefused(decision));
  }

  Future<void> _putBackIfRefused(_Decision decision) async {
    try {
      await decision.written;
    } on GaiaPipeException catch (error) {
      _decisions.remove(decision);
      if (decision.outcome != null) {
        outcomes.remove(decision.index);
        // Back to the earliest refused, never on past one.
        if (decision.index < index) index = decision.index;
        leaving = null;
      }
      _controller.noteRefusal('Not saved', error.message);
      notifyListeners();
    }
  }

  /// Ctrl+Z: the last decision undone, its card back in front; each after
  /// the one before it has finished.
  Future<void> undo() {
    final done = _undoing.then((_) => _undoLast());
    _undoing = done.catchError((Object _) {});
    return done;
  }

  /// One refused stays to undo again.
  Future<void> _undoLast() async {
    final decision = _decisions.lastOrNull;
    if (decision == null) return;
    final GaiaReviewUndo revert;
    try {
      revert = await decision.written;
    } on GaiaPipeException {
      return; // Refused, and put back already.
    }
    if (revert != null) {
      try {
        await revert();
      } on GaiaPipeException catch (error) {
        _controller.noteRefusal('Not undone', error.message);
        return;
      }
    }
    _decisions.remove(decision);
    outcomes.remove(decision.index);
    index = decision.index;
    leaving = null;
    notifyListeners();
  }

  /// "12 remembered · 5 declined · 3 skipped", in the order first decided.
  String get summary {
    final counts = <GaiaReviewOutcome, int>{};
    for (final outcome in [
      for (final i in outcomes.keys.toList()..sort()) outcomes[i]!,
    ]) {
      counts[outcome] = (counts[outcome] ?? 0) + 1;
    }
    if (counts.isEmpty) return 'Nothing decided.';
    return [
      for (final MapEntry(:key, :value) in counts.entries) '$value ${key.word}',
    ].join(' · ');
  }

  void leftOff() {
    leaving = null;
    notifyListeners();
  }
}

bool _unsorted(GaiaMemory memory, GaiaTopicTree tree) =>
    memory.topicIds.every((id) => tree.path(id).isEmpty);

/// What the sweep's [suggestion] asks, as its card's heading
/// (GAIA_MEMORY_TOPICS_HLD.md §27.4).
String gaiaSuggestionHeading(
  GaiaMemorySuggestion suggestion,
  GaiaTopicTree tree,
) {
  String path(String id) {
    final path = tree.path(id);
    return path.isEmpty ? '…' : path.join(' › ');
  }

  return switch (suggestion.kind) {
    GaiaSuggestionKind.same => 'Same thing?',
    GaiaSuggestionKind.conflict => 'These disagree',
    GaiaSuggestionKind.expired => 'Out of date?',
    GaiaSuggestionKind.topicMerge =>
      'Merge "${path(suggestion.topicIds.first)}" into '
          '"${path(suggestion.topicIds.last)}"?',
    GaiaSuggestionKind.topicRename =>
      'Rename "${path(suggestion.topicIds.single)}" to "${suggestion.text}"?',
    GaiaSuggestionKind.place => 'Unsorted',
  };
}

IconData gaiaSuggestionIcon(GaiaSuggestionKind kind) => switch (kind) {
  GaiaSuggestionKind.same => Icons.call_merge,
  GaiaSuggestionKind.conflict => Icons.compare_arrows,
  GaiaSuggestionKind.expired => Icons.history,
  GaiaSuggestionKind.topicMerge => Icons.merge,
  GaiaSuggestionKind.topicRename => Icons.drive_file_rename_outline,
  GaiaSuggestionKind.place => Icons.inbox_outlined,
};

/// The review in the Memories tab's place (GAIA_SETTINGS_HLD.md §6.2): the
/// card in front, larger than a list card, its actions and their keys,
/// the card decided last animating off over the next, and at the end what
/// was done. The keys are off while a text box has the focus.
class GaiaMemoryReviewView extends StatefulWidget {
  const GaiaMemoryReviewView({
    super.key,
    required this.controller,
    required this.review,
    this.chat,
  });

  final GaiaController controller;
  final GaiaMemoryReview review;

  /// The Ask Gaia chat (GAIA_SETTINGS_HLD.md §7.1), built by the Gaia window
  /// while [GaiaController.asking] is set, or the card's source chat, read-only,
  /// while [GaiaController.showingSource] is (§6.2): under the card, or beside
  /// it in a window wider than [kGaiaAskBesideWidth].
  final Widget? chat;

  @override
  State<GaiaMemoryReviewView> createState() => _GaiaMemoryReviewViewState();
}

class _GaiaMemoryReviewViewState extends State<GaiaMemoryReviewView> {
  GaiaController get _controller => widget.controller;
  GaiaMemoryReview get _review => widget.review;

  final _keys = FocusNode(debugLabel: 'gaia memory review');

  /// The text being edited in place, and whose; null when not editing.
  ({String id, TextEditingController text})? _editing;

  /// The last edit saved, which a decision waits for.
  Future<void>? _saving;

  /// Same thing's merged text as edited here, by suggestion; [_editing]'s
  /// id is [_mergedEdit] and the suggestion's while it's edited.
  final _merged = <String, String>{};
  static const _mergedEdit = 'merged:';

  /// The card going off, built once as it starts, and its serial: it keeps
  /// its look and size while the write it set off changes what it shows.
  (int, Widget)? _leavingCard;
  late final _editFocus = FocusNode(
    debugLabel: 'gaia review edit',
    onKeyEvent: (node, event) {
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
    },
  );

  @override
  void initState() {
    super.initState();
    _review.addListener(_onReview);
    // The hint says what Esc does in the Ask Gaia composer.
    _keys.addListener(_onKeysFocus);
    // Started from a button, which kept the focus somewhere in the list.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _keys.requestFocus();
      _syncAsk();
    });
  }

  @override
  void didUpdateWidget(GaiaMemoryReviewView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.review == widget.review) return;
    oldWidget.review.removeListener(_onReview);
    widget.review.addListener(_onReview);
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncAsk());
  }

  void _onKeysFocus() {
    if (mounted) setState(() {});
  }

  /// Whether this review last showed an Ask Gaia chat.
  var _wasAsking = false;

  void _onReview() {
    // Built here, as it's decided, before the write it sets off goes on.
    final review = _review;
    if (review.leaving case final leaving?
        when _leavingCard?.$1 != review.leavingSerial) {
      _leavingCard = (review.leavingSerial, _card(leaving.card, still: true));
    }
    final was = _wasAsking;
    _syncAsk();
    // Back from an Ask Gaia chat, the keys are the deck's again; not taken
    // from anything else that has them.
    if (was && _controller.asking == null && _editing == null) {
      _keys.requestFocus();
    }
    if (review.wantsKeys) {
      review.wantsKeys = false;
      if (_editing == null) _keys.requestFocus();
    }
  }

  /// The Ask Gaia chat follows the card in front (§7.1): shown for one asked
  /// about in this review, hidden for any other. So does the source chat, in
  /// its place.
  void _syncAsk() {
    if (!mounted) return;
    final review = _review;
    final memory = review.finished ? null : review.card(review.index).memory;
    final source = memory?.sourceChatId;
    if (memory != null && memory.id == review.sourceOf && source != null) {
      unawaited(_controller.showSource(memory));
    } else if (memory != null && review.asked.contains(memory.id)) {
      _controller.askAbout(memory);
    } else {
      _controller.closeAsk();
    }
    _wasAsking = _controller.asking != null;
  }

  /// Ask Gaia (/): [memory]'s chat shown, its composer given the focus.
  void _ask(GaiaMemory memory) {
    _review.sourceOf = null;
    _review.asked.add(memory.id);
    if (_controller.asking == memory.id) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _controller.focusComposer(),
      );
      return;
    }
    _controller.askAbout(memory);
    _wasAsking = true;
  }

  /// The source line clicked: [memory]'s source chat shown, or hidden again.
  void _toggleSource(GaiaMemory memory) {
    _review.sourceOf = _review.sourceOf == memory.id ? null : memory.id;
    _syncAsk();
  }

  @override
  void dispose() {
    _review.removeListener(_onReview);
    _keys.dispose();
    _editFocus.dispose();
    _editing?.text.dispose();
    super.dispose();
  }

  void _startEdit(GaiaMemory memory) {
    _dropEdit();
    setState(
      () => _editing = (
        id: memory.id,
        text: TextEditingController(text: memory.text)
          ..selection = TextSelection.collapsed(offset: memory.text.length),
      ),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _editFocus.requestFocus();
    });
  }

  /// An open edit replaced by another: its controller freed once the field
  /// that used it is gone.
  void _dropEdit() {
    final old = _editing?.text;
    if (old != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
    }
  }

  void _endEdit({required bool save}) {
    final editing = _editing;
    if (editing == null) return;
    final text = editing.text.text.trim();
    setState(() => _editing = null);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      editing.text.dispose();
      if (mounted) _keys.requestFocus();
    });
    if (!save || text.isEmpty) return;
    // A merge's text, kept here until Merge (§27.4).
    if (editing.id.startsWith(_mergedEdit)) {
      setState(() => _merged[editing.id.substring(_mergedEdit.length)] = text);
      return;
    }
    final saving = _run(
      () => _controller.writeMemories('editMemory', {
        'memoryId': editing.id,
        'text': text,
      }),
      'Not saved',
    );
    _saving = saving;
    unawaited(saving);
  }

  Future<void> _run(Future<void> Function() action, String failed) async {
    try {
      await action();
    } on GaiaPipeException catch (error) {
      _controller.noteRefusal(failed, error.message);
    }
  }

  /// [memories] as they are now, to put back on undo.
  List<GaiaMemory> _now(Iterable<String> ids) => [
    for (final memory in _controller.memoryList!.memories)
      if (ids.contains(memory.id)) memory,
  ];

  GaiaReviewUndo _reverting(List<GaiaMemory> was) =>
      () => _controller.revertMemories(memories: was);

  /// A write to [memory] decided as [outcome], undone by putting it back.
  void _decideMemory(
    GaiaReviewOutcome? outcome,
    GaiaMemory memory,
    Future<void> Function() write,
  ) {
    _review.decide(outcome, () async {
      await _saving;
      final was = _now([memory.id]);
      await write();
      return _reverting(was);
    });
  }

  void _remember(GaiaMemory memory, {bool pin = false}) {
    _review.decide(GaiaReviewOutcome.remembered, () async {
      // With its edit, if one is saving.
      await _saving;
      // Taken before: one it merges into, with the pin, is put back too.
      final before = _controller.memoryList!.memories;
      final stands = await _controller.rememberMemory(
        _now([memory.id]).firstOrNull ?? memory,
        pin: pin,
      );
      return _reverting([
        for (final was in before)
          if (was.id == memory.id || (pin && was.id == stands)) was,
      ]);
    });
  }

  /// The memory proposal [memory] would update, while it's still kept
  /// (GAIA_MEMORY_TOPICS_HLD.md §27.3); null for a plain proposal.
  GaiaMemory? _replaced(GaiaMemory? memory) => memory == null
      ? null
      : gaiaReplacedMemory(memory, _controller.memoryList!.memories);

  bool _updates(GaiaMemory? memory) => _replaced(memory) != null;

  /// "Update this?" accepted: the proposal's text written into the memory
  /// it updates, both put back on undo. One refused (a pin over the budget)
  /// puts the card back, saying why.
  void _update(GaiaMemory memory) {
    _review.decide(GaiaReviewOutcome.updated, () async {
      // With its edit, if one is saving.
      await _saving;
      return _reverting(await _controller.updateMemory(memory.id));
    });
  }

  void _skip(GaiaReviewOutcome outcome) =>
      _review.decide(outcome, () async => null);

  void _merge(GaiaMemoryTopic from, GaiaMemoryTopic into) {
    final list = _controller.memoryList!;
    final tree = GaiaTopicTree(list.topics);
    final topics = [from, into, ...tree.childrenOf(from.id)];
    final memories = [
      for (final memory in list.memories)
        if (memory.topicIds.contains(from.id) ||
            memory.suggestedTopic?.parentId == from.id)
          memory,
    ];
    _review.decide(GaiaReviewOutcome.merged, () async {
      await _controller.writeMemories('mergeTopic', {
        'topicId': from.id,
        'intoId': into.id,
      });
      return () =>
          _controller.revertMemories(memories: memories, topics: topics);
    });
  }

  void _keepApart(GaiaMemoryTopic from, GaiaMemoryTopic into) {
    final ids = {'topicId': from.id, 'intoId': into.id};
    _review.decide(GaiaReviewOutcome.keptApart, () async {
      await _controller.writeMemories('keepApart', ids);
      return () => _controller.writeMemories('undoKeepApart', ids);
    });
  }

  void _fileThere(GaiaMemory memory) {
    final placement = _controller.memorySorted[memory.id];
    if (placement == null) return;
    final was = _now([memory.id]);
    _review.decide(GaiaReviewOutcome.filed, () async {
      final had = {
        for (final topic in _controller.memoryList!.topics) topic.id,
      };
      await _controller.acceptSorted(memory.id);
      // The new topic it offered, made.
      final made = [
        for (final topic in _controller.memoryList!.topics)
          if (!had.contains(topic.id)) topic.id,
      ];
      return () async {
        await _controller.revertMemories(memories: was);
        for (final id in made) {
          await _controller.writeMemories('deleteTopic', {'topicId': id});
        }
        // Undone, it's offered again.
        _controller.changeSorted(memory.id, placement);
      };
    });
  }

  /// Leave unsorted: its suggestion dropped and the choice remembered, as
  /// on the tab (GAIA_MEMORY_TOPICS_HLD.md §27.5); both undone together.
  void _leaveUnsorted(GaiaMemory memory) {
    final placement = _controller.memorySorted[memory.id];
    _review.decide(GaiaReviewOutcome.leftUnsorted, () async {
      await _controller.leaveUnsorted(memory.id);
      return () => _controller.undoLeaveUnsorted(memory.id, placement);
    });
  }

  /// The sweep's [suggestion] decided as [outcome] (§27.4): [accept]ed, a
  /// merge with its text as edited, [keep]ing one of two, or kept apart.
  void _decideSweep(
    GaiaReviewOutcome outcome,
    GaiaMemorySuggestion suggestion, {
    bool accept = false,
    String? keep,
  }) {
    // Merge clicked mid-edit: the text as typed, not as last saved.
    final editing = _editing;
    final typed = editing?.id == '$_mergedEdit${suggestion.id}'
        ? editing!.text.text.trim()
        : '';
    _review.decide(
      outcome,
      () => _controller.decideSuggestion(
        suggestion,
        accept: accept,
        keep: keep,
        text: accept && suggestion.kind == GaiaSuggestionKind.same
            ? (typed.isNotEmpty
                  ? typed
                  : _merged[suggestion.id] ?? suggestion.text)
            : null,
      ),
    );
  }

  void _editMerged(GaiaMemorySuggestion suggestion) {
    final text = _merged[suggestion.id] ?? suggestion.text ?? '';
    _dropEdit();
    setState(
      () => _editing = (
        id: '$_mergedEdit${suggestion.id}',
        text: TextEditingController(text: text)
          ..selection = TextSelection.collapsed(offset: text.length),
      ),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _editFocus.requestFocus();
    });
  }

  /// Choose…: the topic picker, then filed in what's picked, a new topic
  /// made at the root first.
  Future<void> _choose(GaiaMemory memory) async {
    final tree = GaiaTopicTree(_controller.memoryList!.topics);
    final pick = await showGaiaTopicPicker(
      context,
      title: 'File it in',
      topics: gaiaTopicLines(tree),
      newUnder: '',
    );
    if (mounted) _keys.requestFocus();
    if (pick == null || (pick.topicId == null && pick.newName == null)) return;
    final was = _now([memory.id]);
    _review.decide(GaiaReviewOutcome.filed, () async {
      final made = pick.topicId == null
          ? await _controller.writeMemories('newTopic', {'name': pick.newName})
                as String
          : null;
      await _controller.writeMemories('addMemoryTopic', {
        'memoryId': memory.id,
        'topicId': pick.topicId ?? made,
      });
      return () async {
        await _controller.revertMemories(memories: was);
        if (made != null) {
          await _controller.writeMemories('deleteTopic', {'topicId': made});
        }
      };
    });
  }

  /// §6.2's keys for the card in front, when nothing else has the focus.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final key = event.logicalKey;
    // Held down, only ← goes on: a held Enter isn't thirty decisions.
    if (event is! KeyDownEvent &&
        !(event is KeyRepeatEvent && key == LogicalKeyboardKey.arrowLeft)) {
      return KeyEventResult.ignored;
    }
    final keyboard = HardwareKeyboard.instance;
    final control = keyboard.isControlPressed;
    final shift = keyboard.isShiftPressed;
    final plain = !control && !keyboard.isAltPressed && !shift;
    final review = _review;
    bool enter() =>
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter;
    bool letter(LogicalKeyboardKey letter) => plain && key == letter;
    final backspace = key == LogicalKeyboardKey.backspace && !control;
    final right =
        key == LogicalKeyboardKey.arrowRight || letter(LogicalKeyboardKey.keyS);

    // The Ask Gaia chat first, then the review (§8).
    if (key == LogicalKeyboardKey.escape) {
      if (_controller.asking != null) {
        _controller.closeAsk(dismiss: true);
      } else {
        _controller.endReview();
      }
      return KeyEventResult.handled;
    }
    if ((control && key == LogicalKeyboardKey.keyZ) ||
        letter(LogicalKeyboardKey.keyU)) {
      unawaited(review.undo());
      return KeyEventResult.handled;
    }
    // The shell's Ctrl+F would open the chat search over the panel.
    if (control && key == LogicalKeyboardKey.keyF) {
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      review.back();
      return KeyEventResult.handled;
    }
    if (review.finished) {
      if (enter()) _controller.endReview();
      return enter() ? KeyEventResult.handled : KeyEventResult.ignored;
    }
    final card = review.card(review.index);
    final memory = card.memory;
    if (memory != null &&
        memory.status != GaiaMemoryStatus.archived &&
        plain &&
        key == LogicalKeyboardKey.slash) {
      _ask(memory);
      return KeyEventResult.handled;
    }
    // R: Gaia's latest open change for this card applied (§7.5).
    if (memory != null &&
        card.kind != GaiaReviewKind.done &&
        letter(LogicalKeyboardKey.keyR)) {
      if (_controller.asking == memory.id &&
          _controller.openRevision(memory.id) != null) {
        _applyRevision(memory);
      }
      return KeyEventResult.handled;
    }
    VoidCallback? action;
    switch (card.kind) {
      case GaiaReviewKind.proposed:
        // "Update this?" (GAIA_MEMORY_TOPICS_HLD.md §27.3): Enter updates,
        // A keeps both.
        final updates = _updates(memory);
        if (updates && enter() && !shift) {
          action = () => _update(memory!);
        } else if (enter() && shift && !updates) {
          action = () => _remember(memory!, pin: true);
        } else if ((enter() && !shift) || letter(LogicalKeyboardKey.keyA)) {
          action = () => _remember(memory!);
        } else if (backspace || letter(LogicalKeyboardKey.keyD)) {
          action = () => _decideMemory(
            GaiaReviewOutcome.declined,
            memory!,
            () => _controller.writeMemories('decideMemory', {
              'memoryId': memory.id,
              'accept': false,
            }),
          );
        } else if (letter(LogicalKeyboardKey.keyE)) {
          action = () => _startEdit(memory!);
        } else if (letter(LogicalKeyboardKey.keyT)) {
          action = () => unawaited(_addTopic(memory!));
        } else if (right) {
          action = () => _skip(GaiaReviewOutcome.skipped);
        }
      case GaiaReviewKind.remembered:
        if (enter() || key == LogicalKeyboardKey.arrowRight) {
          action = () => _skip(GaiaReviewOutcome.kept);
        } else if (control && key == LogicalKeyboardKey.backspace) {
          action = () => _decideMemory(
            GaiaReviewOutcome.deleted,
            memory!,
            () => _controller.writeMemories('deleteMemory', {
              'memoryId': memory.id,
            }),
          );
        } else if (backspace || letter(LogicalKeyboardKey.keyD)) {
          action = () => _decideMemory(
            GaiaReviewOutcome.archived,
            memory!,
            () => _controller.writeMemories('archiveMemory', {
              'memoryId': memory.id,
            }),
          );
        } else if (letter(LogicalKeyboardKey.keyE)) {
          action = () => _startEdit(memory!);
        } else if (letter(LogicalKeyboardKey.keyP)) {
          action = () => _togglePin(memory!);
        } else if (letter(LogicalKeyboardKey.keyT)) {
          action = () => unawaited(_addTopic(memory!));
        }
      case GaiaReviewKind.pin:
        if (enter()) {
          action = () => _pin(memory!);
        } else if (backspace) {
          action = () => _putOff(memory!);
        } else if (right) {
          action = () => _skip(GaiaReviewOutcome.skipped);
        }
      case GaiaReviewKind.merge:
        if (enter()) {
          action = () => _merge(card.from!, card.into!);
        } else if (backspace) {
          action = () => _keepApart(card.from!, card.into!);
        } else if (right) {
          action = () => _skip(GaiaReviewOutcome.skipped);
        }
      case GaiaReviewKind.unsorted:
        if (enter()) {
          action = () => _fileThere(memory!);
        } else if (letter(LogicalKeyboardKey.keyT)) {
          action = () => unawaited(_choose(memory!));
        } else if (backspace || letter(LogicalKeyboardKey.keyD)) {
          action = () => _leaveUnsorted(memory!);
        } else if (letter(LogicalKeyboardKey.keyE)) {
          action = () => _startEdit(memory!);
        } else if (right) {
          action = () => _skip(GaiaReviewOutcome.skipped);
        }
      case GaiaReviewKind.same:
        final suggestion = card.suggestion!;
        if (enter()) {
          action = () =>
              _decideSweep(GaiaReviewOutcome.merged, suggestion, accept: true);
        } else if (backspace) {
          action = () => _decideSweep(GaiaReviewOutcome.keptApart, suggestion);
        } else if (letter(LogicalKeyboardKey.keyE)) {
          action = () => _editMerged(suggestion);
        } else if (right) {
          action = () => _skip(GaiaReviewOutcome.skipped);
        }
      case GaiaReviewKind.conflict:
        final suggestion = card.suggestion!;
        final digit = [
          LogicalKeyboardKey.digit1,
          LogicalKeyboardKey.digit2,
        ].indexOf(key);
        if (plain && digit >= 0) {
          action = () => _decideSweep(
            GaiaReviewOutcome.kept,
            suggestion,
            keep: suggestion.memoryIds[digit],
          );
        } else if (backspace) {
          action = () => _decideSweep(GaiaReviewOutcome.keptBoth, suggestion);
        } else if (right) {
          action = () => _skip(GaiaReviewOutcome.skipped);
        }
      case GaiaReviewKind.expired ||
          GaiaReviewKind.topicMerge ||
          GaiaReviewKind.topicRename:
        final suggestion = card.suggestion!;
        if (enter()) {
          action = () => _decideSweep(
            switch (card.kind) {
              GaiaReviewKind.expired => GaiaReviewOutcome.archived,
              GaiaReviewKind.topicMerge => GaiaReviewOutcome.merged,
              _ => GaiaReviewOutcome.renamed,
            },
            suggestion,
            accept: true,
          );
        } else if (backspace) {
          action = () => _decideSweep(
            card.kind == GaiaReviewKind.topicMerge
                ? GaiaReviewOutcome.keptBoth
                : GaiaReviewOutcome.kept,
            suggestion,
          );
        } else if (right) {
          action = () => _skip(GaiaReviewOutcome.skipped);
        }
      case GaiaReviewKind.done:
        if (enter() || right) action = review.forward;
    }
    if (action == null) return KeyEventResult.ignored;
    action();
    return KeyEventResult.handled;
  }

  /// R: the latest open revision card in [memory]'s Ask Gaia chat applied
  /// with every change it offers, as its Apply would; the deck stays on the
  /// card. Undone, the memory and its topics are back, any topic it made is
  /// deleted, and the card is open again.
  void _applyRevision(GaiaMemory memory) {
    final (message, revision) = _controller.openRevision(memory.id)!;
    _review.decide(null, () async {
      await _saving;
      final was = _now([memory.id]);
      final made = await _controller.reviseMemory(
        message,
        revision,
        accept: true,
      );
      return () async {
        await _controller.revertMemories(memories: was);
        for (final id in made) {
          await _controller.writeMemories('deleteTopic', {'topicId': id});
        }
        await _controller.reopenRevision(message, revision);
      };
    });
  }

  void _togglePin(GaiaMemory memory) => _decideMemory(
    null,
    memory,
    () => _controller.writeMemories('pinMemory', {
      'memoryId': memory.id,
      'pinned': !memory.pinned,
    }),
  );

  void _pin(GaiaMemory memory) => _decideMemory(
    GaiaReviewOutcome.pinned,
    memory,
    () => _controller.writeMemories('pinMemory', {
      'memoryId': memory.id,
      'pinned': true,
    }),
  );

  void _putOff(GaiaMemory memory) {
    final ids = {'memoryId': memory.id};
    _review.decide(GaiaReviewOutcome.putOff, () async {
      await _controller.writeMemories('pinLater', ids);
      return () => _controller.writeMemories('undoPinLater', ids);
    });
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _review,
    builder: (context, _) {
      final review = _review;
      final leaving = review.leaving;
      final chat = widget.chat;
      final deck = GestureDetector(
        // A click on the page gives the keys back.
        behavior: HitTestBehavior.translucent,
        onTap: () {
          if (_editing == null) _keys.requestFocus();
        },
        child: LayoutBuilder(
          builder: (context, constraints) => GaiaPanelScroll(
            key: const PageStorageKey('gaia panel review'),
            slivers: [
              SliverToBoxAdapter(child: _header(review)),
              SliverToBoxAdapter(
                child: review.finished
                    ? _end(review)
                    : AnimatedSize(
                        // Eases to the next card's height as one goes off;
                        // any other change of size, an edit's, is at once
                        // (a zero duration would end inside layout, which
                        // asserts).
                        duration: leaving != null
                            ? _deckTime
                            : const Duration(microseconds: 1),
                        curve: GaiaMotion.curve,
                        alignment: Alignment.topCenter,
                        clipBehavior: Clip.none,
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            _Entering(
                              key: ValueKey(review.leavingSerial),
                              play: leaving != null,
                              child: _card(review.card(review.index)),
                            ),
                            if (leaving != null)
                              Positioned(
                                left: 0,
                                right: 0,
                                top: 0,
                                child: _Leaving(
                                  key: ValueKey(review.leavingSerial),
                                  exit: leaving.exit,
                                  onEnd: review.leftOff,
                                  child: _leavingCard!.$2,
                                ),
                              ),
                          ],
                        ),
                      ),
              ),
              SliverToBoxAdapter(
                child: _keysHint(review, constraints.maxWidth),
              ),
            ],
          ),
        ),
      );
      return Focus(
        focusNode: _keys,
        autofocus: true,
        onKeyEvent: (node, event) =>
            node.hasPrimaryFocus ? _onKey(node, event) : KeyEventResult.ignored,
        child: chat == null
            ? deck
            : LayoutBuilder(
                builder: (context, constraints) =>
                    constraints.maxWidth > kGaiaAskBesideWidth
                    ? Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(child: deck),
                          const VerticalDivider(width: 1),
                          SizedBox(
                            width: min(560, constraints.maxWidth / 2),
                            child: chat,
                          ),
                        ],
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Flexible(flex: 2, child: deck),
                          const Divider(height: 1),
                          Expanded(flex: 3, child: chat),
                        ],
                      ),
              ),
      );
    },
  );

  Widget _header(GaiaMemoryReview review) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 0, 0, 14),
    child: Row(
      children: [
        Expanded(
          child: Text(
            'Reviewing ${review.title}',
            style: GaiaType.heading,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        Text(
          review.finished
              ? 'Done'
              : '${review.index + 1} / ${review.items.length}',
          style: GaiaType.label.copyWith(color: GaiaInk.muted),
        ),
        const SizedBox(width: 12),
        Tooltip(
          message: 'Back to the list (Esc)',
          child: GaiaButton(
            icon: Icons.close,
            size: 28,
            onPressed: _controller.endReview,
          ),
        ),
      ],
    ),
  );

  Widget _end(GaiaMemoryReview review) => Container(
    padding: const EdgeInsets.all(24),
    decoration: gaiaFloating(
      Theme.of(context).colorScheme,
      radius: GaiaRadius.panel,
    ),
    child: Column(
      children: [
        Icon(Icons.done_all, size: 28, color: GaiaInk.dim),
        const SizedBox(height: 10),
        Text(
          review.items.isEmpty ? 'Nothing to review.' : review.summary,
          textAlign: TextAlign.center,
          style: GaiaType.row.copyWith(color: GaiaInk.bright, fontSize: 15),
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          children: [
            if (review.canUndo)
              GaiaButton(
                label: 'Undo the last',
                size: 30,
                padding: 12,
                color: GaiaInk.muted,
                onPressed: () => unawaited(review.undo()),
              ),
            GaiaButton(
              label: 'Back to the list',
              size: 30,
              padding: 12,
              onPressed: _controller.endReview,
            ),
          ],
        ),
      ],
    ),
  );

  /// The keys for the card in front, under the column, free to run past it
  /// into the panel's sides ([panelWidth] wide in all).
  Widget _keysHint(GaiaMemoryReview review, double panelWidth) {
    final card = review.finished ? null : review.card(review.index);
    final kind = card?.kind;
    // Each pair is the keys (any one of them) and what they do.
    final List<(List<String>, String)> hint = switch (kind) {
      null => [
        (['Enter'], 'back to the list'),
        (['←'], 'back'),
        (['Ctrl+Z', 'U'], 'undo'),
      ],
      GaiaReviewKind.proposed when _updates(card?.memory) => [
        (['Enter'], 'update'),
        (['A'], 'keep both'),
        (['Backspace', 'D'], 'dismiss'),
        (['E'], 'edit'),
        (['T'], 'topic'),
        (['→', 'S'], 'skip'),
      ],
      GaiaReviewKind.proposed => [
        (['Enter', 'A'], 'remember'),
        (['Shift+Enter'], 'remember and pin'),
        (['Backspace', 'D'], 'decline'),
        (['E'], 'edit'),
        (['T'], 'topic'),
        (['→', 'S'], 'skip'),
      ],
      GaiaReviewKind.remembered => [
        (['Enter', '→'], 'keep'),
        (['Backspace', 'D'], 'archive'),
        (['Ctrl+Backspace'], 'delete'),
        (['E'], 'edit'),
        (['P'], 'pin'),
        (['T'], 'topic'),
      ],
      GaiaReviewKind.pin => [
        (['Enter'], 'pin'),
        (['Backspace'], 'not now'),
        (['→'], 'skip'),
      ],
      GaiaReviewKind.merge => [
        (['Enter'], 'merge'),
        (['Backspace'], 'keep apart'),
        (['→'], 'skip'),
      ],
      GaiaReviewKind.unsorted => [
        (['Enter'], 'file there'),
        (['T'], 'choose'),
        (['Backspace', 'D'], 'leave unsorted'),
        (['E'], 'edit'),
        (['→', 'S'], 'skip'),
      ],
      GaiaReviewKind.same => [
        (['Enter'], 'merge'),
        (['Backspace'], 'keep apart'),
        (['E'], 'edit'),
        (['→'], 'skip'),
      ],
      GaiaReviewKind.conflict => [
        (['1', '2'], 'keep that one'),
        (['Backspace'], 'keep both'),
        (['→'], 'skip'),
      ],
      GaiaReviewKind.expired => [
        (['Enter'], 'archive'),
        (['Backspace'], 'keep'),
        (['→'], 'skip'),
      ],
      GaiaReviewKind.topicMerge => [
        (['Enter'], 'merge'),
        (['Backspace'], 'keep both'),
        (['→'], 'skip'),
      ],
      GaiaReviewKind.topicRename => [
        (['Enter'], 'rename'),
        (['Backspace'], 'keep'),
        (['→'], 'skip'),
      ],
      GaiaReviewKind.done => [
        (['Enter', '→'], 'next'),
      ],
    };
    final chatOpen = _controller.asking != null;
    // The chat is inside the deck's Focus, so the deck has focus while the
    // composer does; only not the primary one.
    if (chatOpen && !_keys.hasPrimaryFocus && _editing == null) {
      // Typing in the Ask Gaia composer: the deck's keys are off.
      hint
        ..clear()
        ..add((['Esc'], 'back to the deck'));
    } else if (kind != null) {
      hint.addAll([
        if (chatOpen &&
            kind != GaiaReviewKind.done &&
            card?.memory != null &&
            _controller.asking == card!.memory!.id &&
            _controller.openRevision(card.memory!.id) != null)
          (['R'], "apply Gaia's change"),
        if (card?.memory != null &&
            card!.memory!.status != GaiaMemoryStatus.archived)
          (['/'], chatOpen ? 'back to the chat' : 'ask Gaia'),
        (['←'], 'back'),
        (['Ctrl+Z', 'U'], 'undo'),
        (['Esc'], chatOpen ? 'close the chat' : 'stop'),
      ]);
    }
    final keyStyle = TextStyle(color: Theme.of(context).colorScheme.primary);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 14, 4, 0),
      // Centred on the column but as wide as the panel less its least
      // margin; wrapped between items where that's too narrow (beside the
      // Ask Gaia chat), never shrunk.
      child: OverflowBox(
        maxWidth: panelWidth - 2 * gaiaPanelSide(0),
        fit: OverflowBoxFit.deferToChild,
        child: Wrap(
          alignment: WrapAlignment.center,
          children: [
            for (final (i, (keys, does)) in hint.indexed)
              Text.rich(
                TextSpan(
                  children: [
                    for (final (j, key) in keys.indexed) ...[
                      if (j > 0) const TextSpan(text: ' or '),
                      TextSpan(text: key, style: keyStyle),
                    ],
                    TextSpan(text: ' $does'),
                    if (i < hint.length - 1) const TextSpan(text: ' · '),
                  ],
                ),
                style: GaiaType.label.copyWith(color: GaiaInk.faint),
              ),
          ],
        ),
      ),
    );
  }

  /// The card for [card]; [still] for the one animating off, which takes no
  /// clicks.
  Widget _card(GaiaReviewCard card, {bool still = false}) {
    final theme = Theme.of(context);
    final memory = card.memory;
    final tree = GaiaTopicTree(_controller.memoryList!.topics);
    final replaced = card.kind == GaiaReviewKind.proposed
        ? _replaced(memory)
        : null;
    final (IconData icon, String kindLabel) = switch (card.kind) {
      GaiaReviewKind.proposed when replaced != null => (
        Icons.update,
        'Update this?',
      ),
      GaiaReviewKind.proposed => (Icons.bookmark_add_outlined, 'In the inbox'),
      GaiaReviewKind.remembered => (Icons.bookmark_outline, 'Remembered'),
      GaiaReviewKind.pin => (Icons.push_pin_outlined, 'Pin this?'),
      GaiaReviewKind.merge => (Icons.merge, 'Merge these topics?'),
      GaiaReviewKind.unsorted => (Icons.inbox_outlined, 'Unsorted'),
      GaiaReviewKind.same ||
      GaiaReviewKind.conflict ||
      GaiaReviewKind.expired ||
      GaiaReviewKind.topicMerge ||
      GaiaReviewKind.topicRename => (
        gaiaSuggestionIcon(card.suggestion!.kind),
        switch (card.kind) {
          GaiaReviewKind.same => 'Same thing?',
          GaiaReviewKind.conflict => 'These disagree',
          GaiaReviewKind.expired => 'Out of date?',
          GaiaReviewKind.topicMerge => 'Merge these topics?',
          _ => 'Rename this topic?',
        },
      ),
      GaiaReviewKind.done => (
        Icons.check,
        switch (card.outcome) {
          final outcome? =>
            '${outcome.word[0].toUpperCase()}${outcome.word.substring(1)}'
                '${_review.lastDecided == card.index ? ' · Ctrl+Z undoes it' : ''}',
          null => 'Decided elsewhere',
        },
      ),
    };
    final editing = _editing;
    final body = <Widget>[
      Row(
        children: [
          Icon(icon, size: 16, color: gaiaAstralGoldFor(theme.brightness)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              kindLabel,
              style: GaiaType.label.copyWith(color: GaiaInk.muted),
            ),
          ),
          if (memory?.pinned ?? false)
            Text(
              'Pinned',
              style: GaiaType.label.copyWith(
                color: gaiaAstralGoldFor(theme.brightness),
              ),
            ),
        ],
      ),
      const SizedBox(height: 12),
      // What it updates, struck through above the new text (§27.3).
      if (replaced != null) ...[
        Text(
          replaced.text,
          style: GaiaType.row.copyWith(
            color: GaiaInk.muted,
            fontSize: 16,
            decoration: TextDecoration.lineThrough,
          ),
        ),
        const SizedBox(height: 6),
      ],
      if (card.suggestion case final suggestion?)
        ..._sweepBody(card, suggestion, tree, still: still)
      else if (card.from != null)
        Text(
          'Merge "${_path(tree, card.from)}" into "${_path(tree, card.into)}"',
          style: GaiaType.row.copyWith(color: GaiaInk.bright, fontSize: 16),
        )
      else if (memory != null && editing?.id == memory.id && !still)
        GaiaCardTextField(
          controller: editing!.text,
          focusNode: _editFocus,
          maxLines: 8,
          style: GaiaType.row.copyWith(color: GaiaInk.bright, fontSize: 16),
        )
      else if (memory != null)
        MouseRegion(
          cursor: card.kind == GaiaReviewKind.done
              ? MouseCursor.defer
              : SystemMouseCursors.text,
          child: GestureDetector(
            onTap: card.kind == GaiaReviewKind.done
                ? null
                : () => _startEdit(memory),
            child: Text(
              memory.text,
              style: GaiaType.row.copyWith(
                color: card.kind == GaiaReviewKind.done
                    ? GaiaInk.muted
                    : GaiaInk.bright,
                fontSize: 16,
              ),
            ),
          ),
        )
      else
        Text(
          'That memory is gone.',
          style: GaiaType.row.copyWith(color: GaiaInk.muted),
        ),
      if (card.why case final why?) ...[
        const SizedBox(height: 6),
        Text(
          RegExp(r'[.!?…]$').hasMatch(why) ? why : '$why.',
          style: GaiaType.label.copyWith(color: GaiaInk.muted),
        ),
      ],
      if (memory != null && card.kind != GaiaReviewKind.merge) ...[
        const SizedBox(height: 8),
        _source(memory),
        if (card.kind != GaiaReviewKind.done) ...[
          const SizedBox(height: 10),
          _chips(theme, tree, memory),
        ],
        if (card.kind == GaiaReviewKind.unsorted) ...[
          const SizedBox(height: 10),
          _placement(theme, tree, memory),
        ],
      ],
      if (card.kind != GaiaReviewKind.done) ...[
        const SizedBox(height: 18),
        Wrap(spacing: 8, runSpacing: 8, children: _actions(card)),
      ] else if (card.index == _review.index) ...[
        const SizedBox(height: 18),
        GaiaButton(
          label: 'Next',
          size: 30,
          padding: 12,
          onPressed: _review.forward,
        ),
      ],
    ];
    return IgnorePointer(
      ignoring: still,
      child: Container(
        padding: const EdgeInsets.fromLTRB(22, 18, 22, 20),
        decoration: gaiaFloating(theme.colorScheme, radius: GaiaRadius.panel),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: body,
        ),
      ),
    );
  }

  /// A sweep card's body (§27.4): the memories it names, conflict's with
  /// their keys, same thing's merged text, a click editing it, or what a
  /// topic would become.
  List<Widget> _sweepBody(
    GaiaReviewCard card,
    GaiaMemorySuggestion suggestion,
    GaiaTopicTree tree, {
    required bool still,
  }) {
    final open = card.kind != GaiaReviewKind.done;
    final memories = _controller.memoryList!.memories;
    final big = GaiaType.row.copyWith(
      color: open ? GaiaInk.bright : GaiaInk.muted,
      fontSize: 16,
    );
    final dim = GaiaType.row.copyWith(color: GaiaInk.dim, fontSize: 15);
    final editing = _editing;
    if (suggestion.kind == GaiaSuggestionKind.topicMerge ||
        suggestion.kind == GaiaSuggestionKind.topicRename) {
      return [Text(gaiaSuggestionHeading(suggestion, tree), style: big)];
    }
    return [
      for (final (i, id) in suggestion.memoryIds.indexed)
        if (memories.where((memory) => memory.id == id).firstOrNull
            case final memory?)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text.rich(
              TextSpan(
                children: [
                  if (suggestion.kind == GaiaSuggestionKind.conflict && open)
                    TextSpan(
                      text: '${i + 1}  ',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  TextSpan(text: memory.text),
                  if (suggestion.kind == GaiaSuggestionKind.expired)
                    TextSpan(
                      text: '  saved ${gaiaWhen(memory.createdAt.toLocal())}',
                      style: GaiaType.label.copyWith(color: GaiaInk.faint),
                    ),
                ],
              ),
              style: suggestion.kind == GaiaSuggestionKind.same ? dim : big,
            ),
          ),
      if (suggestion.kind == GaiaSuggestionKind.same) ...[
        const SizedBox(height: 4),
        Text(
          'As one memory:',
          style: GaiaType.label.copyWith(color: GaiaInk.muted),
        ),
        const SizedBox(height: 4),
        if (editing?.id == '$_mergedEdit${suggestion.id}' && !still)
          GaiaCardTextField(
            controller: editing!.text,
            focusNode: _editFocus,
            maxLines: 8,
            style: big,
          )
        else
          MouseRegion(
            cursor: open ? SystemMouseCursors.text : MouseCursor.defer,
            child: GestureDetector(
              onTap: open ? () => _editMerged(suggestion) : null,
              child: Text(
                _merged[suggestion.id] ?? suggestion.text ?? '',
                style: big,
              ),
            ),
          ),
      ],
    ];
  }

  String _path(GaiaTopicTree tree, GaiaMemoryTopic? topic) {
    final path = tree.path(topic!.id);
    return path.isEmpty ? topic.name : path.join(' › ');
  }

  /// "from Planning the CS246 study plan, Nov 20": where it came from, a
  /// click showing that chat read-only (§6.2).
  Widget _source(GaiaMemory memory) {
    final chat = memory.sourceChatId == null
        ? null
        : _controller.chats
              .where((chat) => chat.id == memory.sourceChatId)
              .firstOrNull;
    final when = gaiaWhen(memory.createdAt.toLocal());
    final line = Text.rich(
      TextSpan(
        children: [
          if (chat != null) ...[
            const TextSpan(text: 'from '),
            TextSpan(
              text: chat.title.isEmpty ? 'Untitled chat' : chat.title,
              style: const TextStyle(fontStyle: FontStyle.italic),
            ),
            TextSpan(text: ', $when'),
          ] else
            TextSpan(text: when),
        ],
      ),
      style: GaiaType.label.copyWith(color: GaiaInk.faint),
    );
    if (chat == null) return line;
    return Tooltip(
      message: _controller.showingSource == chat.id
          ? 'Hide this chat'
          : 'Show this chat',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(onTap: () => _toggleSource(memory), child: line),
      ),
    );
  }

  /// Its topics, a click taking one out; the new topic offered; + Topic.
  Widget _chips(ThemeData theme, GaiaTopicTree tree, GaiaMemory memory) {
    final label = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.primary,
      fontWeight: FontWeight.bold,
    );
    final background = Color.lerp(
      theme.colorScheme.surface,
      Colors.black,
      0.5,
    )!;
    void write(String method, [Map<String, Object?> more = const {}]) =>
        unawaited(
          _run(
            () => _controller.writeMemories(method, {
              'memoryId': memory.id,
              ...more,
            }),
            "Couldn't save that",
          ),
        );
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
              tint: gaiaTopicTint(id, theme.brightness),
              tooltip: 'Remove from topic',
              removes: true,
              onTap: () => write('removeMemoryTopic', {'topicId': id}),
            ),
        if (memory.suggestedTopic case final suggested?) ...[
          GaiaTopicChip(
            label: 'New topic: ${gaiaSuggestedTopicLabel(suggested, tree)}',
            style: label,
            background: background,
            checked: false,
            tooltip: 'Make this topic and file it there',
            onTap: () => write('acceptSuggestedTopic'),
          ),
          GaiaTopicChip(
            label: '✕',
            style: label,
            background: background,
            tooltip: "Don't make it",
            removes: true,
            onTap: () => write('dropSuggestedTopic'),
          ),
        ],
        GaiaTopicChip(
          label: '+ Topic',
          style: label,
          background: background,
          onTap: () => _addTopic(memory),
        ),
      ],
    );
  }

  /// + Topic (or T): the topic picker, then added to what's picked, a new
  /// topic made at the root first. The card stays in front.
  Future<void> _addTopic(GaiaMemory memory) async {
    final tree = GaiaTopicTree(_controller.memoryList!.topics);
    final pick = await showGaiaTopicPicker(
      context,
      title: 'Add to topic',
      topics: [
        for (final line in gaiaTopicLines(tree))
          if (!memory.topicIds.contains(line.id)) line,
      ],
      newUnder: '',
    );
    if (mounted) _keys.requestFocus();
    if (pick == null) return;
    await _run(() async {
      final topicId =
          pick.topicId ??
          await _controller.writeMemories('newTopic', {'name': pick.newName})
              as String;
      await _controller.writeMemories('addMemoryTopic', {
        'memoryId': memory.id,
        'topicId': topicId,
      });
    }, "Couldn't save that");
  }

  /// Unsorted: where the utility model would file it, a click leaving a
  /// topic out; or that it's being asked.
  Widget _placement(ThemeData theme, GaiaTopicTree tree, GaiaMemory memory) {
    final placement = _controller.memorySorted[memory.id];
    final muted = GaiaType.label.copyWith(color: GaiaInk.muted);
    if (placement == null) {
      return Text(
        _controller.memorySorting
            ? 'Finding a topic…'
            : _controller.memorySortError ?? 'No topic suggested. T to choose.',
        style: muted,
      );
    }
    final label = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.primary,
      fontWeight: FontWeight.bold,
    );
    final background = Color.lerp(
      theme.colorScheme.surface,
      Colors.black,
      0.5,
    )!;
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text('File it in:', style: muted),
        for (final id in placement.topicIds)
          if (tree.path(id) case final path when path.isNotEmpty)
            GaiaTopicChip(
              label: path.join(' › '),
              style: label,
              background: background,
              tint: gaiaTopicTint(id, theme.brightness),
              tooltip: 'Leave this topic out',
              removes: true,
              onTap: () => _controller.changeSorted(memory.id, (
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
            onTap: () => _controller.changeSorted(memory.id, (
              topicIds: placement.topicIds,
              suggested: null,
              tags: placement.tags,
            )),
          ),
      ],
    );
  }

  List<Widget> _actions(GaiaReviewCard card) {
    final memory = card.memory;
    Widget button(
      String label,
      String keys,
      VoidCallback? onPressed, {
      bool main = false,
    }) => Tooltip(
      message: keys,
      child: GaiaButton(
        label: label,
        size: 32,
        padding: 14,
        color: main ? null : GaiaInk.muted,
        onPressed: onPressed == null
            ? null
            : () {
                onPressed();
                _keys.requestFocus();
              },
      ),
    );
    return [
      ...switch (card.kind) {
        GaiaReviewKind.proposed when _updates(memory) => [
          button('Update', 'Enter', () => _update(memory!), main: true),
          button('Keep both', 'A', () => _remember(memory!)),
          button(
            'Dismiss',
            'Backspace or D',
            () => _decideMemory(
              GaiaReviewOutcome.declined,
              memory!,
              () => _controller.writeMemories('decideMemory', {
                'memoryId': memory.id,
                'accept': false,
              }),
            ),
          ),
          button('Edit', 'E', () => _startEdit(memory!)),
          button('Skip', '→ or S', () => _skip(GaiaReviewOutcome.skipped)),
        ],
        GaiaReviewKind.proposed => [
          button(
            'Remember',
            'Enter or A',
            () => _remember(memory!),
            main: true,
          ),
          button(
            'Remember and pin',
            'Shift+Enter',
            () => _remember(memory!, pin: true),
          ),
          button(
            'Decline',
            'Backspace or D',
            () => _decideMemory(
              GaiaReviewOutcome.declined,
              memory!,
              () => _controller.writeMemories('decideMemory', {
                'memoryId': memory.id,
                'accept': false,
              }),
            ),
          ),
          button('Edit', 'E', () => _startEdit(memory!)),
          button('Skip', '→ or S', () => _skip(GaiaReviewOutcome.skipped)),
        ],
        GaiaReviewKind.remembered => [
          button(
            'Keep',
            'Enter or →',
            () => _skip(GaiaReviewOutcome.kept),
            main: true,
          ),
          button(
            'Archive',
            'Backspace or D',
            () => _decideMemory(
              GaiaReviewOutcome.archived,
              memory!,
              () => _controller.writeMemories('archiveMemory', {
                'memoryId': memory.id,
              }),
            ),
          ),
          button(
            'Delete',
            'Ctrl+Backspace',
            () => _decideMemory(
              GaiaReviewOutcome.deleted,
              memory!,
              () => _controller.writeMemories('deleteMemory', {
                'memoryId': memory.id,
              }),
            ),
          ),
          button('Edit', 'E', () => _startEdit(memory!)),
          button(
            memory!.pinned ? 'Unpin' : 'Pin',
            'P',
            () => _togglePin(memory),
          ),
        ],
        GaiaReviewKind.pin => [
          button('Pin', 'Enter', () => _pin(memory!), main: true),
          button('Not now', 'Backspace', () => _putOff(memory!)),
          button('Skip', '→', () => _skip(GaiaReviewOutcome.skipped)),
        ],
        GaiaReviewKind.merge => [
          button(
            'Merge',
            'Enter',
            () => _merge(card.from!, card.into!),
            main: true,
          ),
          button(
            'Keep apart',
            'Backspace',
            () => _keepApart(card.from!, card.into!),
          ),
          button('Skip', '→', () => _skip(GaiaReviewOutcome.skipped)),
        ],
        GaiaReviewKind.unsorted => [
          button(
            'File there',
            'Enter',
            _controller.memorySorted.containsKey(memory!.id)
                ? () => _fileThere(memory)
                : null,
            main: true,
          ),
          button('Choose…', 'T', () => unawaited(_choose(memory))),
          button(
            'Leave unsorted',
            'Backspace or D',
            () => _leaveUnsorted(memory),
          ),
          button('Edit', 'E', () => _startEdit(memory)),
          button('Skip', '→ or S', () => _skip(GaiaReviewOutcome.skipped)),
        ],
        GaiaReviewKind.same => [
          button(
            'Merge',
            'Enter',
            () => _decideSweep(
              GaiaReviewOutcome.merged,
              card.suggestion!,
              accept: true,
            ),
            main: true,
          ),
          button(
            'Keep apart',
            'Backspace',
            () => _decideSweep(GaiaReviewOutcome.keptApart, card.suggestion!),
          ),
          button('Edit', 'E', () => _editMerged(card.suggestion!)),
          button('Skip', '→', () => _skip(GaiaReviewOutcome.skipped)),
        ],
        GaiaReviewKind.conflict => [
          for (final (i, id) in card.suggestion!.memoryIds.indexed)
            button(
              'Keep ${i + 1}',
              '${i + 1}: the other goes to the trash',
              () => _decideSweep(
                GaiaReviewOutcome.kept,
                card.suggestion!,
                keep: id,
              ),
              main: i == 0,
            ),
          button(
            'Keep both',
            'Backspace',
            () => _decideSweep(GaiaReviewOutcome.keptBoth, card.suggestion!),
          ),
          button('Skip', '→', () => _skip(GaiaReviewOutcome.skipped)),
        ],
        GaiaReviewKind.expired => [
          button(
            'Archive',
            'Enter',
            () => _decideSweep(
              GaiaReviewOutcome.archived,
              card.suggestion!,
              accept: true,
            ),
            main: true,
          ),
          button(
            'Keep',
            'Backspace',
            () => _decideSweep(GaiaReviewOutcome.kept, card.suggestion!),
          ),
          button('Skip', '→', () => _skip(GaiaReviewOutcome.skipped)),
        ],
        GaiaReviewKind.topicMerge => [
          button(
            'Merge',
            'Enter',
            () => _decideSweep(
              GaiaReviewOutcome.merged,
              card.suggestion!,
              accept: true,
            ),
            main: true,
          ),
          button(
            'Keep both',
            'Backspace',
            () => _decideSweep(GaiaReviewOutcome.keptBoth, card.suggestion!),
          ),
          button('Skip', '→', () => _skip(GaiaReviewOutcome.skipped)),
        ],
        GaiaReviewKind.topicRename => [
          button(
            'Rename',
            'Enter',
            () => _decideSweep(
              GaiaReviewOutcome.renamed,
              card.suggestion!,
              accept: true,
            ),
            main: true,
          ),
          button(
            'Keep',
            'Backspace',
            () => _decideSweep(GaiaReviewOutcome.kept, card.suggestion!),
          ),
          button('Skip', '→', () => _skip(GaiaReviewOutcome.skipped)),
        ],
        GaiaReviewKind.done => const <Widget>[],
      },
      if (memory != null && card.kind != GaiaReviewKind.done)
        button('Ask Gaia', '/', () => _ask(memory)),
    ];
  }
}

/// How wide the review is past which an Ask Gaia chat sits beside the card
/// rather than under it (§7.1).
const kGaiaAskBesideWidth = 1000.0;

/// How long a decided card takes to go off, and the next to come up.
const _deckTime = Duration(milliseconds: 320);

/// A decided card going off whole: up, down or aside, fading out at the end.
class _Leaving extends StatelessWidget {
  const _Leaving({
    super.key,
    required this.exit,
    required this.onEnd,
    required this.child,
  });

  final GaiaReviewExit exit;
  final VoidCallback onEnd;
  final Widget child;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(begin: 0, end: 1),
    duration: _deckTime,
    curve: GaiaMotion.travel,
    onEnd: onEnd,
    child: child,
    builder: (context, t, child) => Opacity(
      opacity: (1 - (t - 0.5) / 0.5).clamp(0.0, 1.0),
      child: FractionalTranslation(
        translation:
            switch (exit) {
              GaiaReviewExit.up => const Offset(0, -1.3),
              GaiaReviewExit.down => const Offset(0, 1.3),
              GaiaReviewExit.aside => const Offset(1.2, 0),
            } *
            t,
        child: child,
      ),
    ),
  );
}

/// The card in front, rising from under the one going off when [play] is
/// set on its first build; a new key plays it again. It takes no pointer
/// till it's up, so a tooltip under the mouse waits for it to settle.
class _Entering extends StatelessWidget {
  const _Entering({super.key, required this.play, required this.child});

  final bool play;
  final Widget child;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(begin: play ? 0 : 1, end: 1),
    duration: _deckTime,
    curve: GaiaMotion.curve,
    child: child,
    builder: (context, t, child) => IgnorePointer(
      ignoring: t < 1,
      child: Transform.translate(
        offset: Offset(0, 14 * (1 - t)),
        child: Transform.scale(scale: 0.92 + 0.08 * t, child: child),
      ),
    ),
  );
}
