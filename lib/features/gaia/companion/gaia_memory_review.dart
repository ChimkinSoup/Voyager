import 'dart:async';

import 'package:flutter/material.dart';
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

/// The decks a review goes through (GAIA_SETTINGS_HLD.md §6.1).
enum GaiaReviewDeck { inbox, topic, unsorted }

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

/// Which way a decided card leaves (§6.2).
enum GaiaReviewExit { up, down, aside }

/// What a card was decided as, as the summary counts it.
enum GaiaReviewOutcome {
  remembered('remembered', GaiaReviewExit.up),
  declined('declined', GaiaReviewExit.down),
  skipped('skipped', GaiaReviewExit.aside),
  kept('kept', GaiaReviewExit.up),
  archived('archived', GaiaReviewExit.down),
  deleted('deleted', GaiaReviewExit.down),
  pinned('pinned', GaiaReviewExit.up),
  putOff('put off', GaiaReviewExit.down),
  merged('merged', GaiaReviewExit.up),
  keptApart('kept apart', GaiaReviewExit.down),
  filed('filed', GaiaReviewExit.up);

  const GaiaReviewOutcome(this.word, this.exit);

  final String word;
  final GaiaReviewExit exit;
}

/// What a card asks: one of §6.2's rows, or nothing, once it's decided
/// here or elsewhere.
enum GaiaReviewKind { proposed, remembered, pin, merge, unsorted, done }

/// A card as it shows now, from the Memories tab's latest list.
typedef GaiaReviewCard = ({
  int index,
  GaiaReviewKind kind,
  GaiaMemory? memory,
  String? why,
  GaiaMemoryTopic? from,
  GaiaMemoryTopic? into,
  GaiaReviewOutcome? outcome,
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
  /// suggestions.
  factory GaiaMemoryReview.inbox(GaiaController controller) {
    final list = controller.memoryList!;
    return GaiaMemoryReview._(controller, GaiaReviewDeck.inbox, 'the inbox', [
      for (final memory in list.memories)
        if (memory.status == GaiaMemoryStatus.proposed)
          GaiaReviewMemory(memory.id),
      for (final pin in list.pins) GaiaReviewPin(pin.memory.id, pin.why),
      for (final merge in list.merges)
        GaiaReviewMerge(merge.from, merge.into, merge.why),
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
    }) => (
      index: i,
      kind: outcome == null ? kind : GaiaReviewKind.done,
      memory: memory,
      why: why,
      from: from,
      into: into,
      outcome: outcome,
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
      outcomes[at] = outcome;
      // It goes off saying what was done.
      leaving = (card: card(at), exit: outcome.exit);
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

/// The review in the Memories tab's place (GAIA_SETTINGS_HLD.md §6.2): the
/// card in front, larger than a list card, its actions and their keys,
/// the card decided last animating off over the next, and at the end what
/// was done. The keys are off while a text box has the focus.
class GaiaMemoryReviewView extends StatefulWidget {
  const GaiaMemoryReviewView({
    super.key,
    required this.controller,
    required this.review,
  });

  final GaiaController controller;
  final GaiaMemoryReview review;

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
    // Started from a button, which kept the focus somewhere in the list.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _keys.requestFocus();
    });
  }

  @override
  void dispose() {
    _keys.dispose();
    _editFocus.dispose();
    _editing?.text.dispose();
    super.dispose();
  }

  void _startEdit(GaiaMemory memory) {
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

    if (key == LogicalKeyboardKey.escape) {
      _controller.endReview();
      return KeyEventResult.handled;
    }
    if (control && key == LogicalKeyboardKey.keyZ) {
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
    VoidCallback? action;
    switch (card.kind) {
      case GaiaReviewKind.proposed:
        if (enter() && shift) {
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
        } else if (letter(LogicalKeyboardKey.keyE)) {
          action = () => _startEdit(memory!);
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
      return Focus(
        focusNode: _keys,
        autofocus: true,
        onKeyEvent: (node, event) =>
            node.hasPrimaryFocus ? _onKey(node, event) : KeyEventResult.ignored,
        child: GestureDetector(
          // A click on the page gives the keys back.
          behavior: HitTestBehavior.translucent,
          onTap: () {
            if (_editing == null) _keys.requestFocus();
          },
          child: GaiaPanelScroll(
            key: const PageStorageKey('gaia panel review'),
            slivers: [
              SliverToBoxAdapter(child: _header(review)),
              SliverToBoxAdapter(
                child: review.finished
                    ? _end(review)
                    : Stack(
                        clipBehavior: Clip.none,
                        children: [
                          _card(review.card(review.index)),
                          if (leaving != null)
                            Positioned(
                              left: 0,
                              right: 0,
                              top: 0,
                              child: _Leaving(
                                key: ValueKey(review.leavingSerial),
                                exit: leaving.exit,
                                onEnd: review.leftOff,
                                child: _card(leaving.card, still: true),
                              ),
                            ),
                        ],
                      ),
              ),
              SliverToBoxAdapter(child: _keysHint(review)),
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

  Widget _keysHint(GaiaMemoryReview review) {
    final kind = review.finished ? null : review.card(review.index).kind;
    final hint = switch (kind) {
      null => 'Enter back to the list · ← back · Ctrl+Z undo',
      GaiaReviewKind.proposed =>
        'Enter or A remember · Shift+Enter remember and pin · Backspace or D '
            'decline · E edit · → or S skip',
      GaiaReviewKind.remembered =>
        'Enter or → keep · Backspace or D archive · Ctrl+Backspace delete · '
            'E edit · P pin',
      GaiaReviewKind.pin => 'Enter pin · Backspace not now · → skip',
      GaiaReviewKind.merge => 'Enter merge · Backspace keep apart · → skip',
      GaiaReviewKind.unsorted =>
        'Enter file there · T choose · E edit · → or S skip',
      GaiaReviewKind.done => 'Enter or → next',
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 14, 4, 0),
      child: Text(
        kind == null ? hint : '$hint · ← back · Ctrl+Z undo · Esc stop',
        textAlign: TextAlign.center,
        style: GaiaType.label.copyWith(color: GaiaInk.faint),
      ),
    );
  }

  /// The card for [card]; [still] for the one animating off, which takes no
  /// clicks.
  Widget _card(GaiaReviewCard card, {bool still = false}) {
    final theme = Theme.of(context);
    final memory = card.memory;
    final tree = GaiaTopicTree(_controller.memoryList!.topics);
    final (IconData icon, String kindLabel) = switch (card.kind) {
      GaiaReviewKind.proposed => (Icons.bookmark_add_outlined, 'In the inbox'),
      GaiaReviewKind.remembered => (Icons.bookmark_outline, 'Remembered'),
      GaiaReviewKind.pin => (Icons.push_pin_outlined, 'Pin this?'),
      GaiaReviewKind.merge => (Icons.merge, 'Merge these topics?'),
      GaiaReviewKind.unsorted => (Icons.inbox_outlined, 'Unsorted'),
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
      if (card.from != null)
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
        Text('$why.', style: GaiaType.label.copyWith(color: GaiaInk.muted)),
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

  String _path(GaiaTopicTree tree, GaiaMemoryTopic? topic) {
    final path = tree.path(topic!.id);
    return path.isEmpty ? topic.name : path.join(' › ');
  }

  /// "from Planning the CS246 study plan, Nov 20": where it came from.
  Widget _source(GaiaMemory memory) {
    final chat = memory.sourceChatId == null
        ? null
        : _controller.chats
              .where((chat) => chat.id == memory.sourceChatId)
              .firstOrNull;
    final when = gaiaWhen(memory.createdAt.toLocal());
    return Text.rich(
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
          onTap: () async {
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
                  await _controller.writeMemories('newTopic', {
                        'name': pick.newName,
                      })
                      as String;
              await _controller.writeMemories('addMemoryTopic', {
                'memoryId': memory.id,
                'topicId': topicId,
              });
            }, "Couldn't save that");
          },
        ),
      ],
    );
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
    return switch (card.kind) {
      GaiaReviewKind.proposed => [
        button('Remember', 'Enter or A', () => _remember(memory!), main: true),
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
        button(memory!.pinned ? 'Unpin' : 'Pin', 'P', () => _togglePin(memory)),
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
        button('Edit', 'E', () => _startEdit(memory)),
        button('Skip', '→ or S', () => _skip(GaiaReviewOutcome.skipped)),
      ],
      GaiaReviewKind.done => const [],
    };
  }
}

/// A decided card going off: up, down or aside, fading.
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
    duration: GaiaMotion.move,
    curve: GaiaMotion.curve,
    onEnd: onEnd,
    child: child,
    builder: (context, t, child) => Opacity(
      opacity: 1 - t,
      child: Transform.translate(
        offset: switch (exit) {
          GaiaReviewExit.up => Offset(0, -80 * t),
          GaiaReviewExit.down => Offset(0, 80 * t),
          GaiaReviewExit.aside => Offset(160 * t, 0),
        },
        child: child,
      ),
    ),
  );
}
