import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/adapters/gaia_agent_runner.dart';
import 'package:voyager/features/gaia/adapters/gaia_clis.dart';
import 'package:voyager/features/gaia/companion/gaia_tier_commands.dart';

/// Names Gaia's own commands take (§9.2), which a user command or an
/// account's alias can't.
final kGaiaReservedCommandNames = {
  for (final builtin in GaiaBuiltin.values) ...builtin.names,
  for (final tier in GaiaTier.values) tier.command.substring(1),
};

/// Why [name] can't be a command or alias, or null if it can: an empty one
/// isn't refused, only not yet a name.
String? gaiaCommandNameError(String name, Set<String> taken) {
  if (name.isEmpty) return null;
  if (!RegExp(r'^[\w-]+$').hasMatch(name)) {
    return 'Letters, digits, - and _ only';
  }
  if (taken.contains(name)) return 'Already a command';
  return null;
}

/// Gaia's own commands (GAIA_HLD.md §9.2) that run rather than expand. The
/// others the HLD lists come with their phases.
enum GaiaBuiltin {
  /// `/clear` and `/reset` too, as in Claude Code, where they would start a
  /// session Gaia wouldn't follow (GAIA_NATIVE_COMMANDS.md §4).
  newChat('new', 'Start a new chat', aliases: {'clear', 'reset'}),
  stop('stop', 'Stop the reply in progress'),

  /// Takes the rest of the draft: see [gaiaRememberText].
  remember('remember', 'Remember something about you in every new chat'),

  /// Takes the rest of the draft too: see [gaiaQueueText] (§13).
  queue('queue', "Queue the draft for this chat, to send later"),
  queuePop('queue-pop', "Load this chat's next queued prompt to review"),
  queuePopSend('queue-pop!', "Send this chat's next queued prompt now"),
  drain('drain', 'Send queued prompts one after another, on or off'),

  /// One stash for every chat, kept and synced as drafts are: stashing
  /// again adds to it.
  stash('stash', 'Put the draft aside, to bring back in any chat'),
  stashPop('stash-pop', 'Bring the stashed draft into this chat'),
  thisControl('this', 'Attach the control the cursor was on when Gaia opened'),

  /// Takes the rest of the draft: see [gaiaBtwText] (GAIA_BTW_HLD.md §3).
  /// Alone, it opens the side questions.
  btw('btw', 'Ask a side question about this chat'),

  /// Picks from the projects the rest of its line filters: see
  /// [gaiaProjectPick] (GAIA_PROJECTS_HLD.md §7.5).
  project('project', 'Move this chat to a project', aliases: {'move'}),

  /// Gaia's usage bars rather than the CLI's own text, which is laid out
  /// for a terminal (GAIA_NATIVE_COMMANDS.md §5).
  usage('usage', 'Show plan usage for the next message\'s accounts'),

  /// The lifetime stats, as the sidebar's moon opens them
  /// (GAIA_STATS_HLD.md §2).
  stats('stats', 'Show lifetime stats'),

  /// The hand (GAIA_AUTONOMY_HLD.md §4), anywhere in the draft like a tier
  /// command: see [gaiaInlineBuiltins]. Least first, so `/con` picks Off.
  controlOff(
    'control-off',
    "Gaia can't click or type in this chat",
    aliases: {'controloff'},
  ),
  controlAsk(
    'control-ask',
    'Gaia acts after a card you approve',
    aliases: {'controlask'},
  ),
  controlAuto(
    'control-auto',
    'Gaia acts with no cards, commands too',
    aliases: {'controlauto'},
  ),
  screen('screen', 'Let Gaia see your screen in this chat, on or off'),
  window('window', 'Attach or remove the window Gaia was opened from');

  const GaiaBuiltin(this.name, this.description, {this.aliases = const {}});

  final String name;
  final String description;

  /// Other names it runs by, which the palette matches as well.
  final Set<String> aliases;

  /// [name] and [aliases]: every `/word` it takes.
  Set<String> get names => {name, ...aliases};
}

/// The built-ins that also fire inline, once completed, as a tier command
/// does: see [findGaiaInlineBuiltin]. Not `/screen` or `/window`, which
/// toggle, so pasted or restored text would flip them each time.
const gaiaInlineBuiltins = {
  GaiaBuiltin.controlOff,
  GaiaBuiltin.controlAsk,
  GaiaBuiltin.controlAuto,
};

/// One row of the `/` palette: a built-in, a tier, an account's alias, a
/// user's command, or one of the CLI's own (GAIA_NATIVE_COMMANDS.md).
typedef GaiaPaletteItem = ({
  String name,
  String description,
  GaiaBuiltin? builtin,
  GaiaTier? tier,
  GaiaAccount? account,
  GaiaCommand? command,
  GaiaNativeCommand? native,
});

List<GaiaPaletteItem> gaiaPaletteItems(
  List<GaiaCommand> commands, {
  List<GaiaAccount> accounts = const [],
  List<GaiaNativeCommand> natives = const [],
}) {
  final taken = {
    for (final builtin in GaiaBuiltin.values) ...builtin.names,
    for (final tier in GaiaTier.values) tier.command.substring(1),
    for (final account in accounts)
      if (account.alias.isNotEmpty) account.alias,
    for (final command in commands) command.name,
  };
  return [
    for (final builtin in GaiaBuiltin.values)
      (
        name: builtin.name,
        description: builtin.description,
        builtin: builtin,
        tier: null,
        account: null,
        command: null,
        native: null,
      ),
    for (final tier in GaiaTier.values)
      (
        name: tier.command.substring(1),
        description: 'Switch to ${tier.label}',
        builtin: null,
        tier: tier,
        account: null,
        command: null,
        native: null,
      ),
    for (final account in accounts)
      if (account.alias.isNotEmpty)
        (
          name: account.alias,
          description:
              'Switch to ${account.label} '
              '(${kGaiaClis[account.adapter]?.name ?? account.adapter})',
          builtin: null,
          tier: null,
          account: account,
          command: null,
          native: null,
        ),
    for (final command in commands)
      (
        name: command.name,
        description: command.description.isEmpty
            ? command.template.split('\n').first
            : command.description,
        builtin: null,
        tier: null,
        account: null,
        command: command,
        native: null,
      ),
    // The CLI's own, less any a row above already names: Gaia's win.
    for (final native in natives)
      if (!taken.contains(native.name))
        (
          name: native.name,
          description: native.argumentHint.isEmpty
              ? native.description
              : '${native.description} (${native.argumentHint})',
          builtin: null,
          tier: null,
          account: null,
          command: null,
          native: native,
        ),
  ];
}

/// [items] that fuzzily match [query] (what's typed after the slash),
/// best first: the very name, a prefix, then a substring, then the letters in
/// order.
List<GaiaPaletteItem> filterGaiaPalette(
  List<GaiaPaletteItem> items,
  String query, {
  List<String> recent = const [],
}) {
  int? score(String name) => _fuzzyScore(name, query);

  // A built-in's best over its name and aliases. An alias counts only as
  // the very name or a prefix, so `/s` doesn't bring up `/new` for `reset`.
  int? best(GaiaPaletteItem item) {
    final scores = [
      score(item.name),
      for (final alias in item.builtin?.aliases ?? const <String>{})
        if (score(alias) case final s? when s <= 0) s,
    ].nonNulls;
    return scores.isEmpty ? null : scores.reduce((a, b) => a < b ? a : b);
  }

  // Within a kind of match, the most recently used first; never used, in
  // [items]' order.
  int order(int index, GaiaPaletteItem item) {
    final used = recent.indexOf(item.name);
    return used == -1 ? recent.length + index : used;
  }

  final scored =
      [
        for (final (index, item) in items.indexed)
          if (best(item) case final s?) (s, order(index, item), index, item),
      ]..sort(
        (a, b) => a.$1 != b.$1
            ? a.$1 - b.$1
            // Rows of one name share an order: [items]' order settles it, as
            // the sort isn't stable.
            : a.$2 != b.$2
            ? a.$2 - b.$2
            : a.$3 - b.$3,
      );
  return [for (final (_, _, _, item) in scored) item];
}

/// How well [name] matches [query]: -1 the very name, 0 a prefix, 1 a
/// substring, 2 the letters in order, null not at all.
int? _fuzzyScore(String name, String query) {
  // So an alias like `q` isn't lost under the `/queue` it's a prefix of.
  if (name == query) return -1;
  final q = query.toLowerCase();
  final n = name.toLowerCase();
  if (n.startsWith(q)) return 0;
  if (n.contains(q)) return 1;
  var i = 0;
  for (final char in n.split('')) {
    if (i < q.length && char == q[i]) i++;
  }
  return i == q.length ? 2 : null;
}

/// The `/word` being typed at the caret, for the palette: its query (what's
/// after the slash) and where it is. [whole] when it's the whole draft, as
/// a user's command must be; a built-in, a tier or an alias can be anywhere.
typedef GaiaPaletteToken = ({String query, int start, int end, bool whole});

/// [value]'s [GaiaPaletteToken]: a whole token, at the start or after
/// whitespace, ending at the caret (the end when there's none), and not
/// inside code. Null otherwise.
GaiaPaletteToken? gaiaPaletteToken(TextEditingValue value) {
  final text = value.text;
  final selection = value.selection;
  if (selection.isValid && !selection.isCollapsed) return null;
  final end = selection.isValid ? selection.end : text.length;
  // Not with a word running on past the caret.
  if (end < text.length && text[end].trim().isNotEmpty) return null;
  final match = RegExp(
    r'(?:^|\s)/([\w-]*)$',
  ).firstMatch(text.substring(0, end));
  if (match == null) return null;
  final query = match.group(1)!;
  final start = end - query.length - 1;
  if (gaiaInCode(text, start)) return null;
  return (
    query: query,
    start: start,
    end: end,
    whole: start == 0 && end == text.length,
  );
}

/// What a user command in [draft] expands to on send, or null when the
/// draft doesn't start with one. `/name the rest`: `$ARGUMENTS` is the rest,
/// `$1`…`$9` its words, `$CLIPBOARD` the clipboard's text, `$SELECTION`
/// the text selected where Gaia was summoned from, and `$DATE` today's
/// date.
String? expandGaiaCommand(
  String draft,
  List<GaiaCommand> commands, {
  required String clipboard,
  required DateTime now,
  String selection = '',
}) {
  final match = RegExp(
    r'^/([\w-]+)(?:\s+([\s\S]*))?$',
  ).firstMatch(draft.trim());
  if (match == null) return null;
  final command = commands.where((c) => c.name == match.group(1)).firstOrNull;
  if (command == null) return null;
  final arguments = (match.group(2) ?? '').trim();
  final words = arguments.isEmpty
      ? const <String>[]
      : arguments.split(RegExp(r'\s+'));
  return command.template.replaceAllMapped(
    RegExp(r'\$(ARGUMENTS|CLIPBOARD|SELECTION|DATE|[1-9])'),
    (m) => switch (m.group(1)!) {
      'ARGUMENTS' => arguments,
      'CLIPBOARD' => clipboard,
      'SELECTION' => selection,
      'DATE' => DateFormat('yyyy-MM-dd').format(now),
      final n => int.parse(n) <= words.length ? words[int.parse(n) - 1] : '',
    },
  );
}

/// What `/remember <text>` in [draft] saves (§11): the text after it, or
/// null when the draft doesn't start with `/remember` and some text.
String? gaiaRememberText(String draft) {
  final match = RegExp(r'^/remember\s+(\S[\s\S]*)$').firstMatch(draft.trim());
  return match?.group(1)!.trim();
}

/// `/remember`'s [text] without its leading flags, in any order, possibly
/// empty: `--global` keeps it out of the chat's project
/// (GAIA_MEMORY_TOPICS_HLD.md §5) and `--pin` pins it (§3.3).
({String text, bool global, bool pin}) gaiaRememberOptions(String text) {
  var rest = text.trim();
  var global = false;
  var pin = false;
  final flag = RegExp(r'^--(global|pin)(?:\s+|$)');
  for (
    var match = flag.firstMatch(rest);
    match != null;
    match = flag.firstMatch(rest)
  ) {
    if (match.group(1) == 'global') {
      global = true;
    } else {
      pin = true;
    }
    rest = rest.substring(match.end).trim();
  }
  return (text: rest, global: global, pin: pin);
}

/// What `/queue <text>` in [draft] queues (§13): the text after it, or null
/// when the draft doesn't start with `/queue` and some text.
String? gaiaQueueText(String draft) {
  final match = RegExp(r'^/queue\s+(\S[\s\S]*)$').firstMatch(draft.trim());
  return match?.group(1)!.trim();
}

/// What `/btw <question>` in [draft] asks (GAIA_BTW_HLD.md §3): the text
/// after it, or null when the draft doesn't start with `/btw` and some text.
String? gaiaBtwText(String draft) {
  final match = RegExp(r'^/btw\s+(\S[\s\S]*)$').firstMatch(draft.trim());
  return match?.group(1)!.trim();
}

/// `/project` or `/move` and a space starting [draft] (GAIA_PROJECTS_HLD.md
/// §7.5): the rest of its line, to filter the projects by, and where the
/// line ends, its newline included, to take it out once one is picked. Null
/// otherwise.
({String query, int end})? gaiaProjectPick(String draft) {
  final match = RegExp(r'^/(?:project|move)[ \t]+').firstMatch(draft);
  if (match == null) return null;
  final newline = draft.indexOf('\n');
  final lineEnd = newline == -1 ? draft.length : newline;
  return (
    query: draft.substring(match.end, lineEnd).trim(),
    end: newline == -1 ? draft.length : newline + 1,
  );
}

/// `/project`'s rows for [query] (GAIA_PROJECTS_HLD.md §7.5): the projects
/// of [listed], in the sidebar's order, but the chat's [current] one, that
/// match it as the palette matches names, best first; then null, for
/// Remove from project, when it has a [current] one and the query is empty or
/// matches that.
List<GaiaProject?> gaiaProjectRows(
  List<GaiaProject> listed,
  String? current,
  String query,
) {
  final scored = [
    for (final (index, project) in listed.indexed)
      if (project.id != current)
        if (_fuzzyScore(project.name, query) case final s?) (s, index, project),
  ]..sort((a, b) => a.$1 != b.$1 ? a.$1 - b.$1 : a.$2 - b.$2);
  return [
    for (final (_, _, project) in scored) project,
    if (current != null &&
        (query.isEmpty || _fuzzyScore('Remove from project', query) != null))
      null,
  ];
}

/// What's left of [draft] after a leading `/this` (§15.5) and some text, to
/// send with the control attached; null when it doesn't start that way.
String? gaiaThisRest(String draft) {
  final match = RegExp(r'^/this\s+(\S[\s\S]*)$').firstMatch(draft.trim());
  return match?.group(1)!.trim();
}

/// What's left of [draft] after a leading `/stash` and some text, to stash;
/// null when it doesn't start that way.
String? gaiaStashRest(String draft) {
  final match = RegExp(r'^/stash\s+(\S[\s\S]*)$').firstMatch(draft.trim());
  return match?.group(1)!.trim();
}

/// The built-in [draft] is, alone; null otherwise.
GaiaBuiltin? gaiaBuiltinIn(String draft) {
  final text = draft.trim();
  return GaiaBuiltin.values
      .where((b) => b.names.any((n) => '/$n' == text))
      .firstOrNull;
}

/// Where the `/word` starting [draft] is, when it's a command that stays in
/// the draft until it's sent: a built-in that doesn't fire inline, a user's
/// command, or one of the CLI's own. Not a tier or an account's alias, which
/// fire as soon as they're typed. [natives] is only asked when Gaia's own
/// don't name the word, as asking may start reading the CLI's.
TextRange? gaiaDraftCommand(
  String draft, {
  required List<GaiaCommand> commands,
  required List<GaiaAccount> accounts,
  required List<GaiaNativeCommand>? Function() natives,
}) {
  final match = RegExp(r'^\s*/([\w-]+)(?=\s|$)').firstMatch(draft);
  if (match == null) return null;
  final word = match.group(1)!;
  final range = TextRange(start: match.end - word.length - 1, end: match.end);
  if (GaiaTier.values.any((tier) => tier.command == '/$word') ||
      accounts.any((account) => account.alias == word)) {
    return null;
  }
  if (GaiaBuiltin.values.any(
        (builtin) =>
            !gaiaInlineBuiltins.contains(builtin) &&
            builtin.names.contains(word),
      ) ||
      commands.any((command) => command.name == word) ||
      (natives() ?? const []).any((native) => native.name == word)) {
    return range;
  }
  return null;
}

/// The composer's draft, drawing the command [command] finds starting it in
/// the accent. Only its colour: anything that changed the width would move
/// the caret off the text.
class GaiaDraftController extends TextEditingController {
  GaiaDraftController(this.command);

  final TextRange? Function(String text) command;

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final range = command(text);
    if (range == null) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }
    // The IME's underline, as the default draws it.
    final composing =
        withComposing &&
            value.isComposingRangeValid &&
            !value.composing.isCollapsed
        ? value.composing
        : TextRange.empty;
    final accent = TextStyle(color: Theme.of(context).colorScheme.primary);
    const underline = TextStyle(decoration: TextDecoration.underline);
    final cuts = {
      0,
      range.start,
      range.end,
      if (composing.isValid) ...[composing.start, composing.end],
      text.length,
    }.toList()..sort();
    return TextSpan(
      style: style,
      children: [
        for (var i = 0; i + 1 < cuts.length; i++)
          TextSpan(
            text: text.substring(cuts[i], cuts[i + 1]),
            style:
                (cuts[i] >= range.start && cuts[i] < range.end
                        ? accent
                        : const TextStyle())
                    .merge(
                      cuts[i] >= composing.start && cuts[i] < composing.end
                          ? underline
                          : null,
                    ),
          ),
      ],
    );
  }
}

/// The CLI command (GAIA_NATIVE_COMMANDS.md) [draft] starts with: `/name`,
/// then a space or the end. Null when it starts with none of [natives].
GaiaNativeCommand? gaiaNativeIn(String draft, List<GaiaNativeCommand> natives) {
  final name = RegExp(r'^/([\w-]+)(?:\s|$)').firstMatch(draft.trim());
  if (name == null) return null;
  return natives.where((n) => n.name == name.group(1)).firstOrNull;
}

/// A `/word` starting [draft] that no row of [items] names (GAIA_NATIVE_COMMANDS.md
/// §7), with the closest one's name as [suggestion]; null when the draft
/// doesn't start with a `/word`, or one of [items] is it. A word with a
/// second slash in it, as a path's `/usr/bin`, isn't a `/word`.
({String word, String? suggestion})? gaiaUnknownCommand(
  String draft,
  List<GaiaPaletteItem> items,
) {
  final match = RegExp(r'^/([\w-]+)(?:\s|$)').firstMatch(draft.trim());
  if (match == null) return null;
  final word = match.group(1)!;
  if (items.any(
    (item) =>
        item.name == word || (item.builtin?.names.contains(word) ?? false),
  )) {
    return null;
  }
  return (
    word: word,
    suggestion:
        filterGaiaPalette(items, word).firstOrNull?.name ??
        gaiaClosestName(word, [for (final item in items) item.name]),
  );
}

/// The one of [names] fewest edits from [word], when it's at most two away:
/// a typo's like `/qeueu`, which [filterGaiaPalette] wouldn't match.
String? gaiaClosestName(String word, List<String> names) {
  int distance(String a, String b) {
    var row = List.generate(b.length + 1, (i) => i);
    for (var i = 1; i <= a.length; i++) {
      final next = [i, ...List.filled(b.length, 0)];
      for (var j = 1; j <= b.length; j++) {
        next[j] = [
          row[j] + 1,
          next[j - 1] + 1,
          row[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1),
        ].reduce((x, y) => x < y ? x : y);
      }
      row = next;
    }
    return row[b.length];
  }

  String? best;
  var bestDistance = 3;
  for (final name in names) {
    final d = distance(word.toLowerCase(), name.toLowerCase());
    if (d < bestDistance) {
      best = name;
      bestDistance = d;
    }
  }
  return best;
}
