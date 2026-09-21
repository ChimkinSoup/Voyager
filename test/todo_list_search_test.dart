// The matching rules behind the Todo page's ephemeral list search
// (TODO_LIST_SEARCH_HLD.md), pinned here rather than through the page: the
// command boundary and the AND-across-fields semantics are the parts a
// refactor is most likely to quietly loosen.

import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/domain/models/todo_models.dart';
import 'package:voyager/features/todo/todo_list_search.dart';

TodoTask _task(String title, {String? notes, String id = 'a'}) {
  final now = DateTime.utc(2026, 9, 2);
  return TodoTask(
    id: id,
    listId: 'list',
    title: title,
    notes: notes,
    createdAt: now,
    updatedAt: now,
  );
}

void main() {
  group('todoSearchCommandQuery', () {
    test('a bare /search hands off with no query', () {
      expect(todoSearchCommandQuery('/search'), '');
      expect(todoSearchCommandQuery('/search '), '');
    });

    test('everything after the command becomes the query', () {
      expect(todoSearchCommandQuery('/search buy milk'), 'buy milk');
      expect(todoSearchCommandQuery('/search   buy milk'), 'buy milk');
    });

    test('only triggers on a word boundary', () {
      expect(todoSearchCommandQuery('/searchmilk'), isNull);
      expect(todoSearchCommandQuery('/search-milk'), isNull);
    });

    test('is case-sensitive and anchored at the start', () {
      expect(todoSearchCommandQuery('/Search milk'), isNull);
      expect(todoSearchCommandQuery('buy /search milk'), isNull);
      expect(todoSearchCommandQuery(''), isNull);
    });
  });

  group('todoSearchTokens', () {
    test('folds case and drops empty tokens', () {
      expect(todoSearchTokens('  Buy   MILK '), ['buy', 'milk']);
      expect(todoSearchTokens('   '), isEmpty);
    });
  });

  group('todoTaskMatches', () {
    test('an empty query matches everything', () {
      expect(todoTaskMatches(_task('anything'), const []), isTrue);
    });

    test('matches a substring of the title, whatever it was typed as', () {
      expect(todoTaskMatches(_task('Buy milk'), ['ilk']), isTrue);
      // The needles arrive folded from todoSearchTokens; the title is folded
      // here, so an uppercase title still matches.
      expect(
        todoTaskMatches(_task('Buy MILK'), todoSearchTokens('Milk')),
        isTrue,
      );
      expect(todoTaskMatches(_task('Buy milk'), ['bread']), isFalse);
    });

    test('matches the notes, and a subtask title', () {
      expect(
        todoTaskMatches(_task('Groceries', notes: 'oat milk'), ['milk']),
        isTrue,
      );
      expect(
        todoTaskMatches(
          _task('Groceries'),
          ['milk'],
          subtaskTitles: const ['buy milk'],
        ),
        isTrue,
      );
    });

    test('every token must match, but they may land in different fields', () {
      expect(
        todoTaskMatches(
          _task('Groceries', notes: 'for brunch'),
          ['brunch', 'milk'],
          subtaskTitles: const ['buy milk'],
        ),
        isTrue,
      );
      expect(
        todoTaskMatches(
          _task('Groceries', notes: 'for brunch'),
          ['brunch', 'bread'],
          subtaskTitles: const ['buy milk'],
        ),
        isFalse,
      );
    });
  });

  group('filterTodoTasks', () {
    test('keeps the order it was given', () {
      final tasks = [
        _task('milk first', id: 'a'),
        _task('bread', id: 'b'),
        _task('milk second', id: 'c'),
      ];
      expect(filterTodoTasks(tasks, ['milk']).map((t) => t.id), ['a', 'c']);
    });

    test('resolves subtask titles per parent', () {
      final tasks = [_task('Groceries', id: 'a'), _task('Chores', id: 'b')];
      final filtered = filterTodoTasks(
        tasks,
        ['milk'],
        subtaskTitles: const {
          'a': ['buy milk'],
        },
      );
      expect(filtered.map((t) => t.id), ['a']);
    });

    test('an empty query is the identity', () {
      final tasks = [_task('a', id: 'a')];
      expect(identical(filterTodoTasks(tasks, const []), tasks), isTrue);
    });
  });
}
