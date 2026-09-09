import 'package:voyager/domain/models/todo_models.dart';

/// The in-page filter behind the Todo page's ephemeral search bar
/// (TODO_LIST_SEARCH_HLD.md). Pure so the matching rules can be tested
/// without pumping the page.

/// The composer command that hands off to the search bar.
const todoSearchCommand = '/search';

/// Matches the command only at a word boundary, so `/searchmilk` stays an
/// ordinary task title. Case-sensitive: `/Search` is a title too.
final _todoSearchCommandPattern = RegExp('^$todoSearchCommand(\$| )');

/// The query [text] hands to the search bar, or null when it isn't the
/// `/search` command at all.
///
/// Returns the empty string for a bare `/search` (or `/search `), which opens
/// the bar with no filter rather than doing nothing.
String? todoSearchCommandQuery(String text) {
  if (!_todoSearchCommandPattern.hasMatch(text)) return null;
  return text.substring(todoSearchCommand.length).trimLeft();
}

/// The lowercased tokens of [query]. Every one of them has to match somewhere
/// in a task for that task to be a result — the same AND semantics the journal
/// search page uses.
List<String> todoSearchTokens(String query) => query
    .toLowerCase()
    .split(RegExp(r'\s+'))
    .where((token) => token.isNotEmpty)
    .toList(growable: false);

/// Everything about [task] a query can match: its title, its notes, and the
/// titles of its subtasks, folded to lower case.
///
/// Built per call rather than cached the way the journal search page folds
/// entry bodies: a task's corpus is a title, a short note and a handful of
/// subtask titles, not a thousand-word entry.
String todoSearchCorpus(
  TodoTask task, {
  List<String> subtaskTitles = const [],
}) {
  final buffer = StringBuffer(task.title);
  final notes = task.notes;
  if (notes != null && notes.isNotEmpty) {
    buffer
      ..write(' ')
      ..write(notes);
  }
  for (final subtaskTitle in subtaskTitles) {
    buffer
      ..write(' ')
      ..write(subtaskTitle);
  }
  return buffer.toString().toLowerCase();
}

/// Whether [task] survives a filter of [tokens], which must already be folded
/// by [todoSearchTokens] — the corpus is lowercased here, the needles are not.
///
/// A match on a subtask or on the notes keeps the *parent row* — subtasks are
/// never rows of their own here, so there is nothing else to show.
bool todoTaskMatches(
  TodoTask task,
  List<String> tokens, {
  List<String> subtaskTitles = const [],
}) {
  if (tokens.isEmpty) return true;
  final corpus = todoSearchCorpus(task, subtaskTitles: subtaskTitles);
  return tokens.every(corpus.contains);
}

/// [tasks] filtered by [tokens], in the order they came in — the filter runs
/// after the page's own sort, so display order is untouched.
///
/// [subtaskTitles] maps a parent task id to the titles of its subtasks; a task
/// missing from it is matched on title and notes alone, which is what happens
/// for the frames between the bar opening and that query landing.
List<TodoTask> filterTodoTasks(
  List<TodoTask> tasks,
  List<String> tokens, {
  Map<String, List<String>> subtaskTitles = const {},
}) {
  if (tokens.isEmpty) return tasks;
  return [
    for (final task in tasks)
      if (todoTaskMatches(
        task,
        tokens,
        subtaskTitles: subtaskTitles[task.id] ?? const [],
      ))
        task,
  ];
}
