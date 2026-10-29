/// Proposals (GAIA_HLD.md §10), as both processes see them: what each
/// `propose_*` tool's card holds. The main instance's executor fills one in
/// and commits it (`host/gaia_executor.dart`); the companion's editor
/// changes its fields.
///
/// Fields, by entity, all plain JSON:
/// - todo: `list` (a list's id), `title`, `notes`, `due` (a when, or null),
///   `starred`, `completed`.
/// - event: `calendar` (a calendar's id), `title`, `allDay`, `start` and
///   `end` (days when all day, times otherwise), `notes`.
/// - journal: `journal` (a journal's id), `title`, `body`, `date` (a time),
///   `mood` (0–10).
///
/// A when is a day, `YYYY-MM-DD`, or a local time on one,
/// `YYYY-MM-DDTHH:mm`.
library;

import 'dart:math';

import 'package:intl/intl.dart';
import 'package:voyager/domain/models/gaia_models.dart';

/// The tool each entity is proposed through.
const kGaiaProposalTools = {
  'propose_todo': GaiaProposalEntity.todo,
  'propose_calendar_event': GaiaProposalEntity.event,
  'propose_journal_entry': GaiaProposalEntity.journal,
};

/// The `origin` every row Gaia creates gets (§10), so the trash and the
/// action log can tell it apart.
const kGaiaOrigin = 'gaia';

final _random = Random.secure();

/// An approval token (§10): the companion issues one when the user accepts
/// a proposal card, and the main instance's executor commits nothing
/// without it. It binds one acceptance to one commit of one card the
/// executor prepared; it isn't a signature, since the pipe between the two
/// is already the user's own.
String gaiaApprovalToken() => [
  for (var i = 0; i < 16; i++)
    _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
].join();

/// Whether [token] has an approval token's form.
bool isGaiaApprovalToken(Object? token) =>
    token is String && RegExp(r'^[0-9a-f]{32}$').hasMatch(token);

/// A when (see the library doc): a day, or a time on one.
typedef GaiaWhen = ({DateTime at, bool hasTime});

final _when = RegExp(r'^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2}))?$');

/// [value] as a when, or null when it isn't one.
GaiaWhen? gaiaParseWhen(Object? value) {
  if (value is! String) return null;
  final match = _when.firstMatch(value.trim());
  if (match == null) return null;
  int part(int group) => int.parse(match.group(group)!);
  final hasTime = match.group(4) != null;
  final at = DateTime(
    part(1),
    part(2),
    part(3),
    hasTime ? part(4) : 0,
    hasTime ? part(5) : 0,
  );
  // DateTime rolls 2026-02-30 over to March; that's not a date.
  if (at.month != part(2) || at.day != part(3)) return null;
  if (hasTime && (part(4) > 23 || part(5) > 59)) return null;
  return (at: at, hasTime: hasTime);
}

/// [at], a local wall clock, as a when.
String gaiaFormatWhen(DateTime at, {required bool hasTime}) =>
    DateFormat(hasTime ? "yyyy-MM-dd'T'HH:mm" : 'yyyy-MM-dd').format(at);

/// A when as the user reads it: `Thu 30 Oct 2026`, `… 14:00`.
String gaiaWhenLabel(Object? value) {
  final when = gaiaParseWhen(value);
  if (when == null) return 'none';
  return DateFormat(
    when.hasTime ? 'EEE d MMM y HH:mm' : 'EEE d MMM y',
  ).format(when.at);
}

/// The fields an [entity] proposal has, in the order the editor shows them.
List<String> gaiaProposalFieldKeys(GaiaProposalEntity entity) =>
    switch (entity) {
      GaiaProposalEntity.todo => [
        'title',
        'list',
        'due',
        'starred',
        'completed',
        'notes',
      ],
      GaiaProposalEntity.event => [
        'title',
        'calendar',
        'allDay',
        'start',
        'end',
        'notes',
      ],
      GaiaProposalEntity.journal => [
        'title',
        'journal',
        'date',
        'mood',
        'body',
      ],
    };

String gaiaProposalFieldLabel(String key) => switch (key) {
  'list' => 'List',
  'calendar' => 'Calendar',
  'journal' => 'Journal',
  'title' => 'Title',
  'notes' => 'Notes',
  'body' => 'Entry',
  'due' => 'Due',
  'starred' => 'Starred',
  'completed' => 'Done',
  'allDay' => 'All day',
  'start' => 'Starts',
  'end' => 'Ends',
  'date' => 'Written',
  'mood' => 'Mood',
  _ => key,
};

/// [fields]' [key] as the user reads it.
String gaiaProposalValueLabel(
  GaiaProposal proposal,
  Map<String, Object?> fields,
  String key,
) {
  final value = fields[key];
  return switch (key) {
    'list' || 'calendar' || 'journal' =>
      proposal.choices.where((c) => c.id == value).firstOrNull?.name ??
          'unknown',
    'due' || 'start' || 'end' || 'date' => gaiaWhenLabel(value),
    'starred' || 'completed' || 'allDay' => value == true ? 'yes' : 'no',
    'mood' => '$value/10',
    _ => switch (value) {
      final String text when text.trim().isNotEmpty => text.trim(),
      _ => 'none',
    },
  };
}

/// The fields an edit changes, in the editor's order; every field of a
/// new row.
List<String> gaiaProposalChanged(
  GaiaProposal proposal,
  Map<String, Object?> fields,
) {
  final before = proposal.before;
  return [
    for (final key in gaiaProposalFieldKeys(proposal.entity))
      if (before == null || !_same(before[key], fields[key])) key,
  ];
}

/// The fields the user changed in the editor: where [fields] differ from
/// what was [proposed], in the editor's order.
List<String> gaiaProposalEdited(
  GaiaProposalEntity entity,
  Map<String, Object?> proposed,
  Map<String, Object?> fields,
) => [
  for (final key in gaiaProposalFieldKeys(entity))
    if (!_same(proposed[key], fields[key])) key,
];

bool _same(Object? a, Object? b) =>
    a == b ||
    // Notes cleared to '' read the same as none.
    ((a == null || a == '') && (b == null || b == ''));

/// Why [fields] can't be committed for [proposal], or null when they can.
String? gaiaProposalProblem(
  GaiaProposal proposal,
  Map<String, Object?> fields,
) {
  String text(String key) => switch (fields[key]) {
    final String value => value.trim(),
    _ => '',
  };
  bool chosen(String key) => proposal.choices.any((c) => c.id == fields[key]);
  switch (proposal.entity) {
    case GaiaProposalEntity.todo:
      if (text('title').isEmpty) return 'A task needs a title.';
      if (!chosen('list')) return 'Pick a list.';
      if (fields['due'] != null && gaiaParseWhen(fields['due']) == null) {
        return 'The due date must be YYYY-MM-DD or YYYY-MM-DDTHH:mm.';
      }
    case GaiaProposalEntity.event:
      if (text('title').isEmpty) return 'An event needs a title.';
      if (!chosen('calendar')) return 'Pick a calendar.';
      final start = gaiaParseWhen(fields['start']);
      final end = gaiaParseWhen(fields['end']);
      if (start == null || end == null) {
        return 'An event needs a start and an end.';
      }
      final allDay = fields['allDay'] == true;
      if (start.hasTime == allDay || end.hasTime == allDay) {
        return allDay
            ? 'An all-day event starts and ends on days, not times.'
            : 'A timed event starts and ends at times.';
      }
      if (allDay ? end.at.isBefore(start.at) : !end.at.isAfter(start.at)) {
        return 'An event has to end after it starts.';
      }
    case GaiaProposalEntity.journal:
      if (!chosen('journal')) return 'Pick a journal.';
      if (text('body').isEmpty && text('title').isEmpty) {
        return 'A journal entry needs something written.';
      }
      if (gaiaParseWhen(fields['date']) == null) {
        return 'An entry needs the time it was written.';
      }
      final mood = fields['mood'];
      if (mood is! int || mood < 0 || mood > 10) {
        return 'Mood is 0 to 10.';
      }
  }
  if (proposal.isEdit && gaiaProposalChanged(proposal, fields).isEmpty) {
    return 'Nothing is changed.';
  }
  return null;
}

/// What [proposal] does, in a few words: `New task "Call the dentist"`.
String gaiaProposalTitle(GaiaProposal proposal, Map<String, Object?> fields) {
  final name = switch (proposal.entity) {
    GaiaProposalEntity.todo => 'task',
    GaiaProposalEntity.event => 'event',
    GaiaProposalEntity.journal => 'journal entry',
  };
  final title = switch (fields['title']) {
    final String title when title.trim().isNotEmpty => ' "${title.trim()}"',
    _ => '',
  };
  return '${proposal.isEdit ? 'Change' : 'New'} $name$title';
}
