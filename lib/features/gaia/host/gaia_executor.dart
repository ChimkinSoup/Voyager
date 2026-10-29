import 'package:flutter/foundation.dart';
import 'package:voyager/core/utils/all_view_destination.dart';
import 'package:voyager/core/utils/calendar_days.dart';
import 'package:voyager/core/utils/ids.dart';
import 'package:voyager/core/utils/journal_tags.dart';
import 'package:voyager/domain/models/calendar_models.dart';
import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/domain/models/journal_models.dart';
import 'package:voyager/domain/models/soft_deletable.dart';
import 'package:voyager/domain/models/todo_models.dart';
import 'package:voyager/domain/repositories/repositories.dart';
import 'package:voyager/domain/todo/todo_task_sorting.dart';
import 'package:voyager/features/calendar/calendar_list_actions.dart';
import 'package:voyager/features/gaia/host/gaia_voyager_reads.dart';
import 'package:voyager/features/gaia/tools/gaia_mcp.dart';
import 'package:voyager/features/gaia/tools/gaia_proposals.dart';

/// How a commit reaches Voyager's data: the same saves and deletes its own
/// pages make, so each write syncs and the open pages show it. The app
/// wires these to its providers; tests to fakes.
abstract interface class GaiaVoyagerWrites {
  /// A task, and the siblings whose order moved with it.
  Future<void> saveTasks(List<TodoTask> tasks);
  Future<void> deleteTask(TodoTask task);
  Future<void> saveEvent(CalendarEvent event);
  Future<void> deleteEvent(String id);
  Future<void> createEntry(JournalEntry entry);
  Future<void> editEntry(
    String id,
    JournalEntry Function(JournalEntry current) apply,
  );
  Future<void> deleteEntry(String id);
}

/// What a commit wrote, for the card ([record]) and the agent ([text]).
typedef GaiaCommitted = ({Map<String, Object?> record, String text});

/// The main instance's action executor (GAIA_HLD.md §10): the only path by
/// which Gaia writes Voyager data. [prepare] fills in a `propose_*` call as
/// a card's [GaiaProposal] and remembers it; [commit] writes it once the
/// user accepted it in the companion, which issued the approval token, and
/// only once; [undo] takes a commit back from the action log. Every row it
/// creates gets [kGaiaOrigin].
///
/// It never trusts the companion's copy of a proposal: what's written to
/// and from which version are the ones [prepare] kept, and only the fields
/// come from the card, checked again here.
class GaiaExecutor {
  GaiaExecutor({
    required this.todos,
    required this.calendar,
    required this.journal,
    required this.settings,
    required this.writes,
    DateTime Function()? now,
    @visibleForTesting String Function()? newRowId,
  }) : _now = now ?? DateTime.now,
       _newId = newRowId ?? newId;

  final TodoRepository todos;
  final CalendarRepository calendar;
  final JournalRepository journal;
  final SettingsRepository settings;
  final GaiaVoyagerWrites writes;
  final DateTime Function() _now;
  final String Function() _newId;

  /// Prepared and not yet committed, by card id, with when. One the
  /// companion never dropped, its pipe gone at the time, is forgotten once
  /// its card can't be waiting any more.
  final _prepared = <String, ({GaiaProposal proposal, DateTime at})>{};

  /// Turns [tool]'s [arguments] into the proposal card [cardId] shows, and
  /// keeps it for [commit]. Throws a [GaiaReadException] the agent is shown
  /// when the call doesn't make sense.
  Future<GaiaProposal> prepare(
    String cardId,
    String tool,
    Map<String, Object?> arguments,
  ) async {
    final entity =
        kGaiaProposalTools[tool] ??
        (throw GaiaReadException('Unknown tool: $tool'));
    final id = switch (arguments['id']) {
      final String id when id.trim().isNotEmpty => id.trim(),
      _ => null,
    };
    final proposal = switch (entity) {
      GaiaProposalEntity.todo => await _prepareTodo(id, arguments),
      GaiaProposalEntity.event => await _prepareEvent(id, arguments),
      GaiaProposalEntity.journal => await _prepareJournal(id, arguments),
    };
    // What the agent proposed may not be committable as it stands, a
    // missing title say; the user can fix it in the editor. Nothing at all
    // changed is the agent's mistake, though.
    if (proposal.isEdit &&
        gaiaProposalChanged(proposal, proposal.fields).isEmpty) {
      throw GaiaReadException(
        'That changes nothing: pass the fields that should change.',
      );
    }
    final now = _now();
    _prepared
      ..removeWhere((_, p) => now.difference(p.at) > kGaiaMcpToolTimeout)
      ..[cardId] = (proposal: proposal, at: now);
    return proposal;
  }

  /// Forgets card [cardId]'s proposal: turned down, voided or expired.
  void drop(String cardId) => _prepared.remove(cardId);

  /// Writes card [cardId]'s proposal with the user's [fields]. Throws a
  /// [GaiaReadException] when it can't: not prepared here, already
  /// committed, no [token], fields that don't make sense, or a row changed
  /// since it was proposed.
  Future<GaiaCommitted> commit(
    String cardId,
    String token,
    Map<String, Object?> fields,
  ) async {
    if (!isGaiaApprovalToken(token)) {
      throw GaiaReadException('Not approved.');
    }
    // Taken out first: a second commit of the same card finds nothing.
    final proposal =
        _prepared.remove(cardId)?.proposal ??
        (throw GaiaReadException('This proposal is no longer open.'));
    final checked = GaiaProposal(
      entity: proposal.entity,
      targetId: proposal.targetId,
      baseVersion: proposal.baseVersion,
      before: proposal.before,
      choices: proposal.choices,
      fields: {
        for (final key in gaiaProposalFieldKeys(proposal.entity))
          key: fields[key],
      },
    );
    if (gaiaProposalProblem(checked, checked.fields) case final problem?) {
      throw GaiaReadException(problem);
    }
    final record = switch (proposal.entity) {
      GaiaProposalEntity.todo => await _commitTodo(checked),
      GaiaProposalEntity.event => await _commitEvent(checked),
      GaiaProposalEntity.journal => await _commitJournal(checked),
    };
    return (
      record: record,
      text: _committedText(checked, proposal.fields, record),
    );
  }

  /// Takes back the commit [record] describes (an accepted card's
  /// `committed`, with its `entity`): a new row goes to the trash, a change
  /// is put back. Refused when the row changed since.
  Future<void> undo(Map<String, Object?> record) async {
    final entity = GaiaProposalEntity.values.byName(
      record['entity']! as String,
    );
    final id = record['id']! as String;
    final version = (record['version']! as num).toInt();
    final before = (record['before'] as Map?)?.cast<String, Object?>();
    switch (entity) {
      case GaiaProposalEntity.todo:
        final task = _live(await todos.getTask(id), version);
        if (before == null) {
          await writes.deleteTask(task);
        } else {
          await writes.saveTasks(await _placed(_applyTodo(task, before)));
        }
      case GaiaProposalEntity.event:
        final event = _live(await calendar.getEvent(id), version);
        if (before == null) {
          await writes.deleteEvent(id);
        } else {
          await writes.saveEvent(_applyEvent(event, before));
        }
      case GaiaProposalEntity.journal:
        _live(await journal.getEntry(id), version);
        if (before == null) {
          await writes.deleteEntry(id);
        } else {
          await writes.editEntry(
            id,
            (current) => _applyJournal(current, before),
          );
        }
    }
  }

  static T _live<T extends SoftDeletable>(T? row, int version) {
    if (row == null || row.deletedAt != null) {
      throw GaiaReadException("It's gone already.");
    }
    if (row.version != version) {
      throw GaiaReadException(
        "It's been changed since, so undoing would lose that change.",
      );
    }
    return row;
  }

  // ---- Todo ----

  Future<GaiaProposal> _prepareTodo(
    String? id,
    Map<String, Object?> arguments,
  ) async {
    final lists = await todos.listLists();
    if (lists.isEmpty) throw GaiaReadException('There are no todo lists.');
    final choices = [for (final list in lists) (id: list.id, name: list.name)];
    final listId = _choice(choices, arguments['list'], 'todo list');
    TodoTask? task;
    if (id != null) {
      task = await todos.getTask(id);
      if (task == null || task.deletedAt != null) {
        throw GaiaReadException('No task has the id "$id".');
      }
      if (task.repeats && arguments['completed'] == true) {
        throw GaiaReadException(
          "A repeating task can't be ticked off from Gaia yet.",
        );
      }
    }
    final before = task == null ? null : _todoFields(task);
    final defaults = await settings.getSettings();
    return GaiaProposal(
      entity: GaiaProposalEntity.todo,
      targetId: task?.id,
      baseVersion: task?.version,
      before: before,
      choices: choices,
      fields: {
        ...?before,
        if (before == null) ...{
          'list':
              resolveNewItemTarget(
                currentId: null,
                lastViewedId: defaults.lastViewedTodoListId,
                defaultId: defaults.defaultTodoListId,
                availableIds: [for (final list in lists) list.id],
              ) ??
              lists.first.id,
          'title': '',
          'notes': '',
          'due': null,
          'starred': false,
          'completed': false,
        },
        'list': ?listId,
        if (arguments['title'] case final String title) 'title': title.trim(),
        if (arguments['notes'] case final String notes) 'notes': notes.trim(),
        if (arguments.containsKey('due')) 'due': _when(arguments, 'due'),
        if (arguments['starred'] case final bool starred) 'starred': starred,
        if (arguments['completed'] case final bool done) 'completed': done,
      },
    );
  }

  static Map<String, Object?> _todoFields(TodoTask task) => {
    'list': task.listId,
    'title': task.title,
    'notes': task.notes ?? '',
    'due': switch (task.dueDate) {
      final due? => gaiaFormatWhen(due.toLocal(), hasTime: task.dueHasTime),
      null => null,
    },
    'starred': task.starred,
    'completed': task.completed,
  };

  Future<Map<String, Object?>> _commitTodo(GaiaProposal proposal) async {
    final fields = proposal.fields;
    final TodoTask task;
    if (proposal.targetId case final id?) {
      final current = await todos.getTask(id);
      _unchanged(current, proposal.baseVersion);
      // The editor offers Done on any change; ticking one off here would
      // end its series rather than move it on.
      if (current!.repeats &&
          !current.completed &&
          fields['completed'] == true) {
        throw GaiaReadException(
          "A repeating task can't be ticked off from Gaia yet.",
        );
      }
      task = _applyTodo(current, fields);
    } else {
      final now = utcNow();
      final due = gaiaParseWhen(fields['due']);
      task = TodoTask(
        id: _newId(),
        listId: fields['list']! as String,
        title: (fields['title']! as String).trim(),
        notes: _notes(fields['notes']),
        dueDate: due?.at.toUtc(),
        dueHasTime: due?.hasTime ?? false,
        dueDateSetAt: due == null ? null : now,
        starred: fields['starred'] == true,
        createdAt: now,
        updatedAt: now,
        origin: kGaiaOrigin,
      ).copyWith(completed: fields['completed'] == true, bumpVersion: false);
    }
    final batch = await _placed(task);
    await writes.saveTasks(batch);
    final saved = batch.firstWhere((t) => t.id == task.id);
    return _record(proposal, saved.id, saved.version);
  }

  TodoTask _applyTodo(TodoTask task, Map<String, Object?> fields) {
    final due = gaiaParseWhen(fields['due']);
    final dueChanged = !_sameWhen(task, due);
    return task.copyWith(
      listId: fields['list']! as String,
      title: (fields['title']! as String).trim(),
      notes: _notes(fields['notes']),
      clearNotes: _notes(fields['notes']) == null,
      dueDate: due?.at.toUtc(),
      dueHasTime: due?.hasTime ?? false,
      clearDueDate: due == null,
      dueDateSetAt: dueChanged && due != null ? utcNow() : null,
      clearDueDateSetAt: due == null,
      starred: fields['starred'] == true,
      completed: fields['completed'] == true,
    );
  }

  static bool _sameWhen(TodoTask task, GaiaWhen? due) {
    final current = task.dueDate;
    if (current == null || due == null) return current == null && due == null;
    return task.dueHasTime == due.hasTime && current.toLocal() == due.at;
  }

  /// [task] in its list's order, with the siblings that moved for it. A
  /// subtask or a done task keeps its place.
  Future<List<TodoTask>> _placed(TodoTask task) async {
    if (task.isSubtask || task.completed) return [task];
    final siblings = await todos.listTasks(task.listId);
    final placed = applyTaskPlacement(
      task,
      activeTopLevelTasks(siblings),
    ).tasks;
    // The batch leaves out a task whose place didn't move, whatever else
    // changed on it.
    return [...placed, if (!placed.any((t) => t.id == task.id)) task];
  }

  // ---- Calendar ----

  Future<GaiaProposal> _prepareEvent(
    String? id,
    Map<String, Object?> arguments,
  ) async {
    final calendars = await calendar.listCalendars();
    if (calendars.isEmpty) throw GaiaReadException('There are no calendars.');
    final choices = [for (final c in calendars) (id: c.id, name: c.name)];
    final calendarId = _choice(choices, arguments['calendar'], 'calendar');
    CalendarEvent? event;
    if (id != null) {
      event = await calendar.getEvent(id);
      if (event == null || event.deletedAt != null) {
        throw GaiaReadException('No event has the id "$id".');
      }
      if (event.recurrence.repeats) {
        throw GaiaReadException(
          "That event repeats, and Gaia can't change a repeating event yet. "
          'Ask the user to change it in Voyager.',
        );
      }
      if (event.source != EventSource.local) {
        throw GaiaReadException(
          "That event comes from Google Calendar; change it there.",
        );
      }
    }
    final before = event == null ? null : _eventFields(event);
    final start = arguments.containsKey('start')
        ? _when(arguments, 'start')
        : null;
    final end = arguments.containsKey('end') ? _when(arguments, 'end') : null;
    if (event == null && start == null) {
      throw GaiaReadException('"start" is required for a new event.');
    }
    final fields = <String, Object?>{
      ...?before,
      if (before == null) ...{
        'calendar':
            defaultCalendarIdFor(calendars, await settings.getSettings()) ??
            calendars.first.id,
        'title': '',
        'notes': '',
      },
      'calendar': ?calendarId,
      if (arguments['title'] case final String title) 'title': title.trim(),
      if (arguments['notes'] case final String notes) 'notes': notes.trim(),
    };
    if (start != null) {
      final parsed = gaiaParseWhen(start)!;
      fields['allDay'] = !parsed.hasTime;
      fields['start'] = start;
      // A moved event keeps its length, unless it changes between timed
      // and all-day.
      final from = gaiaParseWhen(before?['start']);
      final to = gaiaParseWhen(before?['end']);
      final DateTime endAt;
      if (from != null && to != null && from.hasTime == parsed.hasTime) {
        endAt = parsed.hasTime
            ? parsed.at.add(to.at.difference(from.at))
            : addCalendarDays(parsed.at, calendarDaysBetween(from.at, to.at));
      } else {
        endAt = parsed.hasTime
            ? parsed.at.add(const Duration(hours: 1))
            : parsed.at;
      }
      fields['end'] = end ?? gaiaFormatWhen(endAt, hasTime: parsed.hasTime);
    } else if (end != null) {
      fields['end'] = end;
    }
    return GaiaProposal(
      entity: GaiaProposalEntity.event,
      targetId: event?.id,
      baseVersion: event?.version,
      before: before,
      choices: choices,
      fields: fields,
    );
  }

  static Map<String, Object?> _eventFields(CalendarEvent event) => {
    'calendar': event.calendarId,
    'title': event.title,
    'allDay': event.isFullDay,
    'start': gaiaFormatWhen(event.start.toLocal(), hasTime: !event.isFullDay),
    'end': gaiaFormatWhen(event.end.toLocal(), hasTime: !event.isFullDay),
    'notes': event.notes,
  };

  Future<Map<String, Object?>> _commitEvent(GaiaProposal proposal) async {
    final fields = proposal.fields;
    final CalendarEvent event;
    if (proposal.targetId case final id?) {
      final current = await calendar.getEvent(id);
      _unchanged(current, proposal.baseVersion);
      event = _applyEvent(current!, fields);
    } else {
      final calendarId = fields['calendar']! as String;
      final (start, end) = _span(fields);
      final now = utcNow();
      final calendars = await calendar.listCalendars();
      event = CalendarEvent(
        id: _newId(),
        calendarId: calendarId,
        title: (fields['title']! as String).trim(),
        start: start,
        end: end,
        isFullDay: fields['allDay'] == true,
        colorValue: defaultEventColorFor(
          calendars.where((c) => c.id == calendarId).firstOrNull,
          accentColor: (await settings.getSettings()).accentColor,
        ),
        notes: (fields['notes'] as String? ?? '').trim(),
        createdAt: now,
        updatedAt: now,
        origin: kGaiaOrigin,
      );
    }
    await writes.saveEvent(event);
    return _record(proposal, event.id, event.version);
  }

  CalendarEvent _applyEvent(CalendarEvent event, Map<String, Object?> fields) {
    final (start, end) = _span(fields);
    return event.copyWith(
      calendarId: fields['calendar']! as String,
      title: (fields['title']! as String).trim(),
      // Left alone unless moved: a new start drops the event's own offset.
      start: _sameMinute(event.start, start) ? null : start,
      end: _sameMinute(event.end, end) ? null : end,
      isFullDay: fields['allDay'] == true,
      notes: (fields['notes'] as String? ?? '').trim(),
    );
  }

  /// An all-day event ends an hour into its last day, as the calendar's own
  /// panel makes one; a timed one where it says.
  static (DateTime, DateTime) _span(Map<String, Object?> fields) {
    final start = gaiaParseWhen(fields['start'])!.at;
    final end = gaiaParseWhen(fields['end'])!.at;
    return fields['allDay'] == true
        ? (start, end.add(const Duration(hours: 1)))
        : (start, end);
  }

  // ---- Journal ----

  Future<GaiaProposal> _prepareJournal(
    String? id,
    Map<String, Object?> arguments,
  ) async {
    final journals = await journal.listJournals();
    if (journals.isEmpty) throw GaiaReadException('There are no journals.');
    final choices = [for (final j in journals) (id: j.id, name: j.name)];
    final journalId = _choice(choices, arguments['journal'], 'journal');
    JournalEntry? entry;
    if (id != null) {
      entry = await journal.getEntry(id);
      if (entry == null || entry.deletedAt != null) {
        throw GaiaReadException('No journal entry has the id "$id".');
      }
    }
    final before = entry == null ? null : _journalFields(entry);
    final defaults = await settings.getSettings();
    final date = arguments.containsKey('date')
        ? _when(arguments, 'date')
        : null;
    final mood = arguments['mood'];
    if (mood != null && (mood is! int || mood < 0 || mood > 10)) {
      throw GaiaReadException('"mood" is a whole number from 0 to 10.');
    }
    return GaiaProposal(
      entity: GaiaProposalEntity.journal,
      targetId: entry?.id,
      baseVersion: entry?.version,
      before: before,
      choices: choices,
      fields: {
        ...?before,
        if (before == null) ...{
          'journal':
              resolveNewItemTarget(
                currentId: null,
                lastViewedId: defaults.lastViewedJournalId,
                defaultId: defaults.defaultJournalId,
                availableIds: [for (final j in journals) j.id],
              ) ??
              journals.first.id,
          'title': '',
          'body': '',
          'date': gaiaFormatWhen(_now(), hasTime: true),
          'mood': kDefaultMood,
        },
        'journal': ?journalId,
        if (arguments['title'] case final String title) 'title': title.trim(),
        if (arguments['body'] case final String body) 'body': body.trim(),
        // A day alone is written at noon, clear of either midnight.
        if (date != null)
          'date': gaiaParseWhen(date)!.hasTime
              ? date
              : gaiaFormatWhen(
                  gaiaParseWhen(date)!.at.add(const Duration(hours: 12)),
                  hasTime: true,
                ),
        'mood': ?mood,
      },
    );
  }

  static Map<String, Object?> _journalFields(JournalEntry entry) => {
    'journal': entry.journalId,
    'title': entry.title,
    'body': entry.body,
    'date': gaiaFormatWhen(entry.entryDate.toLocal(), hasTime: true),
    'mood': entry.mood ?? kDefaultMood,
  };

  Future<Map<String, Object?>> _commitJournal(GaiaProposal proposal) async {
    final fields = proposal.fields;
    if (proposal.targetId case final id?) {
      _unchanged(await journal.getEntry(id), proposal.baseVersion);
      await writes.editEntry(id, (current) => _applyJournal(current, fields));
      final saved = await journal.getEntry(id);
      return _record(proposal, id, saved!.version);
    }
    final now = utcNow();
    final body = (fields['body']! as String).trim();
    final entry = JournalEntry(
      id: _newId(),
      journalId: fields['journal']! as String,
      title: (fields['title']! as String).trim(),
      body: body,
      tags: extractTags(body),
      entryDate: gaiaParseWhen(fields['date'])!.at.toUtc(),
      mood: fields['mood']! as int,
      timestamp: now,
      createdAt: now,
      updatedAt: now,
      origin: kGaiaOrigin,
    );
    await writes.createEntry(entry);
    final saved = await journal.getEntry(entry.id);
    return _record(proposal, entry.id, saved?.version ?? entry.version);
  }

  static JournalEntry _applyJournal(
    JournalEntry entry,
    Map<String, Object?> fields,
  ) {
    final body = (fields['body']! as String).trim();
    final date = gaiaParseWhen(fields['date'])!.at;
    return entry.copyWith(
      journalId: fields['journal']! as String,
      title: (fields['title']! as String).trim(),
      body: body,
      tags: extractTags(body),
      // Left alone unless moved: a new date drops the entry's own offset.
      entryDate: _sameMinute(entry.entryDate, date) ? null : date.toUtc(),
      mood: fields['mood']! as int,
      bumpVersion: true,
    );
  }

  // ---- Shared ----

  /// The id of the choice named [name], case aside; null for none named.
  static String? _choice(
    List<GaiaProposalChoice> choices,
    Object? name,
    String what,
  ) {
    if (name is! String || name.trim().isEmpty) return null;
    final wanted = name.trim().toLowerCase();
    return choices
            .where((choice) => choice.name.toLowerCase() == wanted)
            .firstOrNull
            ?.id ??
        (throw GaiaReadException(
          'No $what is called "$name". There are: '
          '${choices.map((c) => c.name).join(', ')}.',
        ));
  }

  static String? _when(Map<String, Object?> arguments, String key) {
    final value = arguments[key];
    if (value == null) return null;
    final when =
        gaiaParseWhen(value) ??
        (throw GaiaReadException(
          '"$key" must be YYYY-MM-DD or YYYY-MM-DDTHH:mm.',
        ));
    return gaiaFormatWhen(when.at, hasTime: when.hasTime);
  }

  /// Whether [stored] reads as [shown] to the minute a card shows, so a
  /// time the user didn't move keeps its seconds.
  static bool _sameMinute(DateTime stored, DateTime shown) =>
      gaiaFormatWhen(stored.toLocal(), hasTime: true) ==
      gaiaFormatWhen(shown, hasTime: true);

  static String? _notes(Object? notes) => switch (notes) {
    final String text when text.trim().isNotEmpty => text.trim(),
    _ => null,
  };

  static void _unchanged(SoftDeletable? row, int? baseVersion) {
    if (row == null || row.deletedAt != null) {
      throw GaiaReadException("It's been deleted since it was proposed.");
    }
    if (row.version != baseVersion) {
      throw GaiaReadException(
        "It's been changed since it was proposed; nothing was saved.",
      );
    }
  }

  static Map<String, Object?> _record(
    GaiaProposal proposal,
    String id,
    int version,
  ) => {
    'entity': proposal.entity.name,
    'id': id,
    'version': version,
    'before': ?proposal.before,
  };

  /// What the agent is told was saved: each field, the ones the user
  /// changed from what was [proposed] marked with what it proposed, so it
  /// needn't work the difference out.
  static String _committedText(
    GaiaProposal proposal,
    Map<String, Object?> proposed,
    Map<String, Object?> record,
  ) {
    final fields = proposal.fields;
    final changed = gaiaProposalChanged(proposal, fields);
    final edited = gaiaProposalEdited(proposal.entity, proposed, fields);
    String mark(String key) => switch (key) {
      _ when !edited.contains(key) => '',
      // Its own words, too long to repeat.
      'body' => ' (changed by the user)',
      _ =>
        ' (changed by the user; you proposed '
            '${gaiaProposalValueLabel(proposal, proposed, key)})',
    };
    final lines = [
      for (final key in gaiaProposalFieldKeys(proposal.entity))
        if (!proposal.isEdit || changed.contains(key) || edited.contains(key))
          if (key != 'body' || proposal.isEdit || edited.contains(key))
            '- ${gaiaProposalFieldLabel(key)}: '
                '${gaiaProposalValueLabel(proposal, fields, key)}${mark(key)}',
    ];
    final what = switch (proposal.entity) {
      GaiaProposalEntity.todo => 'task',
      GaiaProposalEntity.event => 'event',
      GaiaProposalEntity.journal => 'journal entry',
    };
    return [
      proposal.isEdit
          ? 'The user accepted. Saved the changes to the $what '
                '(id ${record['id']}), as the user left them:'
          : 'The user accepted. Saved a new $what (id ${record['id']}), as '
                'the user left it:',
      ...lines,
    ].join('\n');
  }
}
