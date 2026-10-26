import 'package:intl/intl.dart';
import 'package:voyager/domain/models/gaia_models.dart';

/// Gaia's own commands (GAIA_HLD.md §9.2) that run rather than expand. The
/// others the HLD lists come with their phases.
enum GaiaBuiltin {
  newChat('new', 'Start a new chat'),
  stop('stop', 'Stop the reply in progress');

  const GaiaBuiltin(this.name, this.description);

  final String name;
  final String description;
}

/// One row of the `/` palette: a built-in, a tier, or a user's command.
typedef GaiaPaletteItem = ({
  String name,
  String description,
  GaiaBuiltin? builtin,
  GaiaTier? tier,
  GaiaCommand? command,
});

List<GaiaPaletteItem> gaiaPaletteItems(List<GaiaCommand> commands) => [
  for (final builtin in GaiaBuiltin.values)
    (
      name: builtin.name,
      description: builtin.description,
      builtin: builtin,
      tier: null,
      command: null,
    ),
  for (final tier in GaiaTier.values)
    (
      name: tier.command.substring(1),
      description: 'Switch to ${tier.label}',
      builtin: null,
      tier: tier,
      command: null,
    ),
  for (final command in commands)
    (
      name: command.name,
      description: command.description.isEmpty
          ? command.template.split('\n').first
          : command.description,
      builtin: null,
      tier: null,
      command: command,
    ),
];

/// [items] that fuzzily match [query] (what's typed after the slash),
/// best first: a prefix, then a substring, then the letters in order.
List<GaiaPaletteItem> filterGaiaPalette(
  List<GaiaPaletteItem> items,
  String query,
) {
  final q = query.toLowerCase();
  int? score(String name) {
    final n = name.toLowerCase();
    if (n.startsWith(q)) return 0;
    if (n.contains(q)) return 1;
    var i = 0;
    for (final char in n.split('')) {
      if (i < q.length && char == q[i]) i++;
    }
    return i == q.length ? 2 : null;
  }

  final scored = [
    for (final (index, item) in items.indexed)
      if (score(item.name) case final s?) (s, index, item),
  ]..sort((a, b) => a.$1 != b.$1 ? a.$1 - b.$1 : a.$2 - b.$2);
  return [for (final (_, _, item) in scored) item];
}

/// The palette's query while the draft is a lone `/word` being typed;
/// null otherwise.
String? gaiaPaletteQuery(String draft) {
  final match = RegExp(r'^/([\w-]*)$').firstMatch(draft);
  return match?.group(1);
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

/// The built-in [draft] is, alone; null otherwise.
GaiaBuiltin? gaiaBuiltinIn(String draft) {
  final text = draft.trim();
  return GaiaBuiltin.values.where((b) => '/${b.name}' == text).firstOrNull;
}
