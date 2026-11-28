import 'dart:async';
import 'dart:convert';

import 'package:voyager/domain/models/gaia_models.dart';
import 'package:voyager/features/gaia/tools/gaia_mcp.dart';

/// The job applier's instructions, a template the user edits
/// (GAIA_ROUTINES_HLD.md §6).
const kGaiaJobApplierInstructions =
    '''Apply to the job posting at the item's URL.

1. Open the URL with os_open, then read the posting in full (open its tabs or
   "Show more" if it's split) and call report_posting. If a skip rule matches,
   stop there.
2. Find the application: an Apply button, or the form on the page.
3. Read the whole form once with os_read_screen offscreen. If a required
   question can't be answered from the materials, report needs_you with every
   such question on the page before typing anything.
4. Fill it by name from the materials. Upload the resume where asked.
5. Call routine_submit_check before clicking Submit. If it allows the submit,
   submit; otherwise leave the form filled at the Submit button.
6. End with report_outcome.''';

/// The default skip rule (§5.1): only what a posting explicitly states.
const kGaiaDefaultSkipRules =
    '''- The posting explicitly states a requirement the profile can't meet, such as
  "we do not sponsor visas", "must be authorized to work without sponsorship
  now or in the future", a security clearance, more years of experience than
  the profile has, "must reside in <place> without relocating" or "must be
  enrolled at <institution>". A posting that says nothing on a point is a go:
  silence about sponsorship is not a refusal.''';

/// The setup interview's first message (§6): an ordinary chat in the
/// routine's project that fills `answers.md`.
String gaiaSetupInterviewPrompt(GaiaRoutine routine) =>
    '''This chat sets up the routine "${routine.name}", which applies to jobs from the materials in this project's folder (${routine.materials.join(', ')}). Interview me to write answers.md, the answer bank job applications are filled from.

Ask me 15 to 25 questions, a few at a time, with ask_user where it helps:
- Why this kind of role, a challenge I overcame, a project I'm proud of, what I'm looking for.
- Salary expectations (per country or currency), sponsorship and work authorization, start date, relocation and preferred locations.
- EEO and demographic choices, or "decline", and pronouns.
- My education's start and end dates, year of study and GPA.
- Questions forms ask that aren't about me as a candidate: age 18 or over; conflicts of interest (ties to the company or its auditors, non-competes, patents, outside work, government or military service); US immigration details (J-1 or J-2, I-140, current status); what to pick when my internship length isn't offered; a full street address and postal code; my phone's type (mobile or home); whether I'd need housing.
- Whether you may opt in to keeping my application on file, and whether you may tick terms, consent and attestation boxes and sign self-identification forms with my name and the date.

Then:
- Offer anything relevant you remember about me as an answer-bank entry, one at a time, and add it only if I say yes.
- Write my answers to answers.md in the project folder, in my words, under each question.
- Suggest turning off Chrome's address popup (Settings, Autofill and passwords, Addresses) in the Chrome profile the routine will use.''';

/// The URLs in pasted text, one per line or mixed with words, in order and
/// each once (§7.1).
List<String> gaiaRoutineUrls(String text) => [
  ...{
    for (final match in RegExp(r'https?://[^\s<>"]+').allMatches(text))
      match.group(0)!.replaceFirst(RegExp(r'[.,;:!?)\]]+$'), ''),
  },
];

/// Tracking parameters [gaiaNormalizeUrl] drops (§7.3).
const _tracking = {'gh_src', 'source', 'ref', 'lever-origin'};

/// [url] as duplicates are compared (§7.3): lower-case host, no fragment, no
/// tracking parameters, no trailing slash.
String gaiaNormalizeUrl(String url) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null || !uri.hasScheme) return url.trim();
  final query = {
    for (final MapEntry(:key, :value) in uri.queryParametersAll.entries)
      if (!key.startsWith('utm_') && !_tracking.contains(key)) key: value,
  };
  var path = uri.path;
  while (path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  return Uri(
    scheme: uri.scheme.toLowerCase(),
    host: uri.host.toLowerCase(),
    port: uri.hasPort ? uri.port : null,
    path: path,
    queryParameters: query.isEmpty ? null : query,
  ).toString();
}

/// The places in [urls] that are duplicates (§7.3): of an earlier one in the
/// list, or of an item submitted in an earlier run. The Jobs tracker comes
/// with R3.
Set<int> gaiaDuplicateUrls(List<String> urls, Iterable<GaiaRoutineRun> runs) {
  final submitted = gaiaSubmittedUrls(runs);
  final seen = <String>{};
  return {
    for (final (i, url) in urls.indexed)
      if (!seen.add(gaiaNormalizeUrl(url)) ||
          submitted.contains(gaiaNormalizeUrl(url)))
        i,
  };
}

/// The normalized URLs of every item [runs] submitted, or the user did.
Set<String> gaiaSubmittedUrls(Iterable<GaiaRoutineRun> runs) => {
  for (final run in runs)
    for (final item in run.items)
      if (item.status == GaiaRunItemStatus.submitted || item.submittedByYou)
        gaiaNormalizeUrl(item.url),
};

/// Item [index] (from 0) of [count]'s prompt (§8.2), the [materials] read
/// from the project folder by name and inlined, and the [uploads]' absolute
/// paths.
String gaiaItemPrompt({
  required GaiaRoutine routine,
  required GaiaRunItem item,
  required int index,
  required int count,
  required Map<String, String> materials,
  required Map<String, String> uploads,
  required GaiaRunMode mode,
}) {
  String attribute(String value) =>
      const HtmlEscape(HtmlEscapeMode.attribute).convert(value);
  return [
    '<routine name="${attribute(routine.name)}" item="${index + 1} of $count">',
    routine.instructions.trim(),
    '',
    '<skip_rules>${routine.skipRules.trim()}</skip_rules>',
    '<materials>',
    for (final MapEntry(:key, :value) in materials.entries)
      '<file name="${attribute(key)}">\n${value.trim()}\n</file>',
    '</materials>',
    '<uploads>',
    for (final MapEntry(:key, :value) in uploads.entries) '$key: $value',
    '</uploads>',
    if (item.notes case final notes? when notes.trim().isNotEmpty)
      '<notes>${notes.trim()}</notes>',
    if (routine.googleAccount case final account? when account.isNotEmpty)
      '<google_account>$account</google_account>',
    '<item url="${attribute(item.url)}"/>',
    '',
    'Rules:',
    "- Open the item's URL with os_open, then read the posting and call "
        'report_posting before any other click or typing. If it says skip, '
        'stop: the item ends skipped.',
    '- Use only facts from the materials and notes. A value may follow from '
        'them (not authorized to work in the US, so not a US citizen). Picking '
        'the nearest option when none matches is a guess, and a required '
        "question you'd have to guess: stop and report needs_you with every "
        'such question on the page.',
    '- Terms, consent and attestation boxes, and signatures: only as '
        'answers.md says. Otherwise needs_you.',
    '- Prefilled values: keep them unless the materials contradict them. '
        'Never clear a required field. Uploads replace any attached file.',
    '- After the form opens, wait for it to stop changing, then read it. '
        'Recheck every dropdown and typeahead value before reporting.',
    '- Typeaheads (type, then pick from a list): use os_pick. In a file '
        'dialog, use os_upload with a path from <uploads>.',
    "- If a named step fails, read the screen again. Don't switch to "
        'coordinates or to typing "into what has focus".',
    '- To wait for a page, use os_read_screen with until. There is no shell.',
    '- Open-ended questions: write from answers.md and projects.md, in the '
        'style of answers.md.',
    '- Optional fields: fill them when the materials answer them, as for a '
        "required field. Leave blank only what the materials don't cover.",
    '- Always name the field you type into.',
    '- Read the whole form once with os_read_screen offscreen before filling.',
    '- Sign in with Google only as the account in <google_account>. Never '
        'type a password or a one-time code, and never create an account with '
        'a password. On such a page, fill every other field from the '
        'materials (the email, a name), then report needs_you.',
    '- Before clicking Submit, call routine_submit_check.',
    if (mode == GaiaRunMode.unattended)
      "- Nobody is watching: don't ask the user anything. Report needs_you "
          'with your questions instead.',
    '- End with report_outcome. Always.',
    '</routine>',
  ].join('\n');
}

// FRAGILE(routines): submit buttons' names are each site's own words. Bare
// "Apply" and "Save and Continue" aren't here: they open a form or go to its
// next page (§8.6, §3.4).
final _submitWords = RegExp(
  r'^(submit( my)?( application)?|send( my)?( application)?|finish|'
  r'complete( my)? application|envoyer( ma candidature)?|soumettre|'
  r'enviar( solicitud| candidatura)?|absenden|invia( candidatura)?|'
  r'verzenden|indienen)\b',
  caseSensitive: false,
);

/// Whether a button named [name] would submit an application (§8.6).
bool gaiaIsSubmitWord(String name) => _submitWords.hasMatch(name.trim());

/// A control a click may reach before `report_posting` (§8.3, §3.7): one
/// that shows more of the posting.
final _showMore = RegExp(
  r'show more|read more|see more|view more|more details|see full|'
  r'full description|job description|^description$',
  caseSensitive: false,
);

/// Whether a click step only reads more of the posting: a tab, or a "Show
/// more".
bool _readsPosting(Map<String, Object?> step) =>
    '${step['type']}'.toLowerCase() == 'tabitem' ||
    _showMore.hasMatch('${step['name'] ?? ''}');

/// Whether [keys] (an `os_key` chord) sends Enter or Return.
bool _sendsEnter(Object? keys) =>
    keys is String &&
    keys.split('+').any((key) {
      final name = key.trim().toLowerCase();
      return name == 'enter' || name == 'return';
    });

/// Why `routine_submit_check` refuses a submit (§8.6), or null when it's
/// allowed. A field counts as required unless it says it isn't.
String? gaiaSubmitRefusal({
  required GaiaRoutine routine,
  required Object? fields,
  required bool duplicate,
}) {
  if (routine.submit != GaiaRoutineSubmit.auto) {
    return 'This routine stops at Submit.';
  }
  if (fields is! List || fields.isEmpty) {
    return 'Pass every field you filled, with its source.';
  }
  final uncertain = [
    for (final field in fields)
      if (field is Map && field['uncertain'] == true) '${field['label']}',
  ];
  if (uncertain.isNotEmpty) {
    return 'Some fields are uncertain: ${uncertain.join('; ')}.';
  }
  final unsourced = [
    for (final field in fields)
      if (field is Map &&
          field['required'] != false &&
          !_sources.contains(field['source']))
        '${field['label']}',
  ];
  if (unsourced.isNotEmpty) {
    return 'Some required fields have no source: ${unsourced.join('; ')}.';
  }
  if (duplicate) return 'This application was already submitted.';
  return null;
}

const _sources = {'profile', 'answers', 'written', 'notes', 'prefilled'};

/// One plan window as the runner watches it: its name ("5-hour"), the share
/// used and when it resets.
typedef GaiaPlanWindow = ({String name, double used, DateTime? resetsAt});

/// The fullest plan window of [usage] at or past [line], with its account
/// (§8.8.2); null when none is.
({String account, GaiaPlanWindow window})? gaiaPlanLine(
  Map<String, List<GaiaPlanWindow>> usage,
  double line,
) {
  ({String account, GaiaPlanWindow window})? fullest;
  for (final MapEntry(key: account, value: windows) in usage.entries) {
    for (final window in windows) {
      if (window.used >= line &&
          (fullest == null || window.used > fullest.window.used)) {
        fullest = (account: account, window: window);
      }
    }
  }
  return fullest;
}

/// Past this, the current item stops at once (§8.8.2).
const kGaiaPlanStop = 0.99;

/// Calls the current item gets once the plan line is reached (§8.8.2).
const kGaiaWrapCalls = 15;

/// How long an attended handoff waits with no input from the user before
/// its item is parked (§9.3).
const kGaiaHandoffIdle = Duration(minutes: 10);

/// The colour of a handoff waiting on the user (§9.3, §11.1): the screen
/// edge's and the side panel's header, as 0xRRGGBB.
const kGaiaHandoffColor = 0xFFB454;

/// What an attended handoff's Resume sends the item chat (§9.3).
String gaiaResumeMessage(String? notes) => [
  'Resumed.',
  if (notes case final notes? when notes.trim().isNotEmpty) notes.trim(),
  '',
  'Read the page again, then carry on with this item. End with '
      'report_outcome.',
].join('\n');

/// What a retry of a parked item sends its item chat (§10.2): its tab is
/// still open, with the form as far as it got.
String gaiaRetryMessage(String? notes) => [
  "Retry this item. Its tab is still open from the last try: go back to it "
      "rather than opening the URL again, read the page, and carry on from "
      "where it stopped.",
  if (notes case final notes? when notes.trim().isNotEmpty)
    '<notes>${notes.trim()}</notes>',
  'End with report_outcome.',
].join('\n');

/// [run] with item [index] back in the queue (§10.2): waiting, after the
/// items still waiting, with [note] added to its notes.
GaiaRoutineRun gaiaQueueRetry(GaiaRoutineRun run, int index, {String? note}) {
  final item = run.items[index];
  final added = note?.trim() ?? '';
  final notes = [
    if (item.notes case final kept? when kept.trim().isNotEmpty) kept.trim(),
    if (added.isNotEmpty) added,
  ].join('\n');
  return run.copyWith(
    items: [
      ...run.items.take(index),
      ...run.items.skip(index + 1),
      item.copyWith(
        status: GaiaRunItemStatus.waiting,
        clearReason: true,
        notes: notes.isEmpty ? null : notes,
      ),
    ],
  );
}

/// Whether [item] is parked, for a note and a retry (§10.2).
bool gaiaItemParked(GaiaRunItem item) =>
    item.status == GaiaRunItemStatus.needsYou ||
    item.status == GaiaRunItemStatus.ready ||
    item.status == GaiaRunItemStatus.failed;

/// What a note on [item] answers, as it goes under in `answers.md` (§10.2):
/// its unanswered questions, or its reason.
String gaiaNoteQuestion(GaiaRunItem item) {
  final asked = [
    for (final question in item.outcome?['new_questions'] as List? ?? const [])
      if ('$question'.trim().isNotEmpty) '$question'.trim(),
  ];
  return asked.isNotEmpty ? asked.join(' ') : (item.reason ?? item.label);
}

/// The tools only item chats are offered (§8.3, §8.4, §8.6).
const kGaiaRoutineToolDefinitions = <Map<String, Object?>>[
  {
    'name': 'report_posting',
    'description':
        "Only in a routine's item chat. Report what the job posting says, "
        'before any click or typing on '
        'the page other than opening it and reading it. fit is skip when a '
        'skip rule matches what the posting explicitly states; a posting '
        'silent on a point is a go. A skip ends the item.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'company': {'type': 'string'},
        'role': {'type': 'string'},
        'location': {
          'type': 'string',
          'description': 'As the posting states it, or "Not stated".',
        },
        'dates': {'type': 'string'},
        'authorization': {'type': 'string'},
        'requirements': {'type': 'string'},
        'fit': {
          'type': 'string',
          'enum': ['go', 'skip'],
        },
        'reason': {
          'type': 'string',
          'description': 'The skip rule that matched, or the main doubt.',
        },
        'posting': {
          'type': 'string',
          'description':
              "The posting's text as Markdown, at most 12000 characters.",
        },
      },
      'required': ['company', 'role', 'fit'],
    },
  },
  {
    'name': 'routine_submit_check',
    'description':
        "Only in a routine's item chat. Ask whether this application may be "
        'submitted, before clicking '
        'Submit. Pass every field you filled. The answer is allowed, or why '
        'not: then report ready with the form filled at the Submit button.',
    'inputSchema': {
      'type': 'object',
      'properties': {'fields': _fields},
      'required': ['fields'],
    },
  },
  {
    'name': 'report_outcome',
    'description':
        "Only in a routine's item chat. Report how the item ended. Always "
        'the last call. submitted only '
        'after routine_submit_check allowed it and the submit went through.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'status': {
          'type': 'string',
          'enum': ['submitted', 'ready', 'needs_you', 'skipped', 'failed'],
        },
        'reason': {
          'type': 'string',
          'description': 'One line. Required unless submitted.',
        },
        'company': {'type': 'string'},
        'role': {'type': 'string'},
        'fields': _fields,
        'new_questions': {
          'type': 'array',
          'items': {'type': 'string'},
          'description': "Questions the materials didn't answer.",
        },
      },
      'required': ['status'],
    },
  },
];

const _fields = <String, Object?>{
  'type': 'array',
  'items': {
    'type': 'object',
    'properties': {
      'label': {'type': 'string'},
      'value': {'type': 'string'},
      'source': {
        'type': 'string',
        'enum': ['profile', 'answers', 'written', 'notes', 'prefilled'],
      },
      'uncertain': {'type': 'boolean'},
      'required': {'type': 'boolean'},
    },
    'required': ['label', 'source'],
  },
};

bool isGaiaRoutineTool(String name) =>
    kGaiaRoutineToolDefinitions.any((tool) => tool['name'] == name);

/// How an item ended, or why it stopped.
typedef GaiaItemEnd = ({GaiaRunItemStatus status, String reason});

/// [arguments] of an item chat's [tool] with `os_type` into a named field
/// replacing its text unless the step says append (GAIA_ROUTINES_HLD.md
/// §15.5); other chats add to it by default.
Map<String, Object?> gaiaItemArguments(
  String tool,
  Map<String, Object?> arguments,
) {
  Map<String, Object?> replacing(Map<String, Object?> step) =>
      step['name'] != null && !step.containsKey('append')
      ? {...step, 'append': false}
      : step;
  return switch (tool) {
    'os_type' => replacing(arguments),
    'os_steps' => {
      ...arguments,
      'steps': [
        for (final step in arguments['steps'] as List? ?? const [])
          step is Map && step['action'] == 'type'
              ? replacing(step.cast<String, Object?>())
              : step,
      ],
    },
    _ => arguments,
  };
}

/// One item turn's gate (GAIA_ROUTINES_HLD.md §8.3 to §8.6, §14): what the
/// agent may do, and how it ended. [focused] reads the window the os_ tools
/// work on: its address, null off a browser page. [stopTurn] stops the turn,
/// as Stop does.
class GaiaRoutineGate {
  GaiaRoutineGate({
    required this.routine,
    required this.mode,
    required this.itemUrl,
    required this.uploadPaths,
    required this.isDuplicate,
    required this.focused,
    required this.stopTurn,
    this.posting,
    Duration Function()? idle,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now,
       _idle = idle ?? (() => Duration.zero),
       callLimit = routine.budgetCalls {
    startedAt = _clock();
  }

  final GaiaRoutine routine;
  final GaiaRunMode mode;
  final String itemUrl;
  final List<String> uploadPaths;
  final bool Function(String url) isDuplicate;
  final Future<String?> Function() focused;
  final void Function(String why) stopTurn;
  final DateTime Function() _clock;

  /// How long since the user's last input anywhere (§9.3).
  final Duration Function() _idle;

  /// When the item's minutes started, moved on by the time an `ask_user`
  /// waited on the user.
  late DateTime startedAt;

  /// Carried over when the turn goes on from an earlier one's (§9.3,
  /// §10.2), whose posting was already read.
  Map<String, Object?>? posting;

  /// An attended `ask_user`'s question while it waits on the user, a
  /// handoff (§9.1), and since when.
  String? asking;
  DateTime? _askedAt;

  /// Called when [asking] changes.
  void Function()? changed;
  Map<String, Object?>? outcome;

  /// Set once `routine_submit_check` allowed the submit.
  bool gatePassed = false;

  /// Tool calls so far, and the most the item may make: the budget, or
  /// fewer once the plan line is reached (§8.8.2).
  int calls = 0;
  int callLimit;

  /// Appended to each tool result while the run wraps up (§8.8.2).
  String? notice;

  /// Why the gate stopped the turn, which parks the item.
  GaiaItemEnd? stopped;

  bool get finished => outcome != null || stopped != null;

  /// How the item ended: a stop, its outcome, or "ended without reporting"
  /// (§8.1).
  GaiaItemEnd get result {
    if (stopped case final stop?) return stop;
    final reported = outcome;
    if (reported == null) {
      return (
        status: GaiaRunItemStatus.failed,
        reason: 'ended without reporting',
      );
    }
    final status = switch (reported['status']) {
      'submitted' => GaiaRunItemStatus.submitted,
      'ready' => GaiaRunItemStatus.ready,
      'skipped' => GaiaRunItemStatus.skipped,
      'failed' => GaiaRunItemStatus.failed,
      _ => GaiaRunItemStatus.needsYou,
    };
    return (status: status, reason: '${reported['reason'] ?? ''}'.trim());
  }

  /// Stops the turn and parks the item as needing you with [why].
  void park(String why) {
    if (finished) return;
    stopped = (status: GaiaRunItemStatus.needsYou, reason: why);
    stopTurn(why);
  }

  /// The plan line was reached in [window]: the item gets [kGaiaWrapCalls]
  /// more calls and is told so (§8.8.2).
  void wrapUp(String window) {
    if (notice != null) return;
    callLimit = calls + kGaiaWrapCalls;
    notice =
        'Plan usage is at $window. Finish this item in at most '
        '$kGaiaWrapCalls more tool calls, or stop where it is and report '
        'needs_you with how far you got.';
  }

  /// The context the turn holds now (§8.5).
  void context(int tokens) {
    if (tokens >= routine.budgetContext) {
      park('context too large (${routine.budgetContext ~/ 1000}k)');
    }
  }

  /// Parks the item once its minutes are up (§8.5), or an `ask_user` the
  /// user left 10 minutes without input (§9.3); called on a timer.
  void checkTime() {
    if (_askedAt case final asked?) {
      if (_clock().difference(asked) >= kGaiaHandoffIdle &&
          _idle() >= kGaiaHandoffIdle) {
        park('no answer in ${kGaiaHandoffIdle.inMinutes} minutes');
      }
      return;
    }
    if (_clock().difference(startedAt).inMinutes >= routine.budgetMinutes) {
      park('ran over budget (${routine.budgetMinutes} minutes)');
    }
  }

  static const _finished = GaiaToolResult(
    text: 'This item is finished. End your turn now.',
    isError: true,
  );

  /// Whether the item ended submitted or skipped, which closes its tab
  /// (§8.1); the others keep theirs open.
  bool get _closing =>
      stopped == null &&
      const {'submitted', 'skipped'}.contains(outcome?['status']);

  /// The one call a finished item may make: closing its tab.
  bool _closesTab(String tool, Map<String, Object?> arguments) =>
      _closing &&
      tool == 'os_key' &&
      '${arguments['keys']}'.replaceAll(' ', '').toLowerCase() == 'ctrl+w';

  String get _next => _closing
      ? 'Close the tab with os_key Ctrl+W, then end your turn.'
      : 'Leave the tab open and end your turn now.';

  /// A refusal for Gaia's [tool], or null when it may run; asked before
  /// every call but the routine's own tools'.
  Future<GaiaToolResult?> refuse(
    String tool,
    Map<String, Object?> arguments,
  ) async {
    if (finished) return _closesTab(tool, arguments) ? null : _finished;
    if (tool == 'ask_user') {
      if (mode == GaiaRunMode.unattended) {
        return const GaiaToolResult(
          text:
              'Nobody is watching this run. Report needs_you with your '
              'questions instead.',
          isError: true,
        );
      }
      // A handoff: it waits with the edge lit (§9.1, §9.3).
      asking = '${arguments['question'] ?? ''}'.trim();
      _askedAt = _clock();
      changed?.call();
      return null;
    }
    // Only the os_ tools: no Voyager writes, memories or project reads.
    if (!tool.startsWith('os_')) {
      return GaiaToolResult(text: "Item chats can't use $tool.", isError: true);
    }
    if (!isGaiaOsControl(tool, arguments)) return null;
    final steps = tool == 'os_steps'
        ? [
            for (final step in arguments['steps'] as List? ?? const [])
              if (step is Map) step.cast<String, Object?>(),
          ]
        : [
            {...arguments, 'action': tool.substring(3)},
          ];
    // Only the routine's own upload files may leave the machine (§14).
    if (steps.any(
      (step) => step['action'] == 'upload' && !_isUpload(step['path']),
    )) {
      return const GaiaToolResult(
        text: 'Only a file from <uploads> can be uploaded.',
        isError: true,
      );
    }
    if (posting == null &&
        !steps.every(
          (step) => switch (step['action']) {
            'open' || 'scroll' || 'focus' || 'window' => true,
            'click' => _readsPosting(step),
            _ => false,
          },
        )) {
      return const GaiaToolResult(
        text:
            'Call report_posting first. Until then only opening the posting, '
            "scrolling, and clicking its tabs or \"Show more\" are allowed.",
        isError: true,
      );
    }
    if (gatePassed) return null;
    if (steps.any(
      (step) =>
          step['action'] == 'click' &&
          gaiaIsSubmitWord('${step['name'] ?? ''}'),
    )) {
      return const GaiaToolResult(
        text:
            'That button looks like it submits the application. Call '
            'routine_submit_check first.',
        isError: true,
      );
    }
    // A click at a point could be on Submit, which only a name tells.
    final unnamed = steps.any(
      (step) => step['action'] == 'click' && step['name'] == null,
    );
    // Enter in a form field submits the form as the button does (§3.5); a
    // native window such as the Open dialog has no address, and takes it.
    // Text typed into a named field presses Enter at a line break too, short
    // of the length that is pasted.
    final enters = steps.any((step) {
      if (step['action'] == 'key') return _sendsEnter(step['keys']);
      final text = '${step['text'] ?? ''}';
      return step['action'] == 'type' &&
          text.contains('\n') &&
          (step['name'] == null || text.length < kGaiaPasteFrom);
    });
    if (!unnamed && !enters) return null;
    if (await focused() == null) return null;
    if (unnamed) {
      return const GaiaToolResult(
        text:
            'A click at a point on a web page could be the submit button, so '
            'it is refused until routine_submit_check allows the submit. Name '
            'the control, by its label if it has no name.',
        isError: true,
      );
    }
    return const GaiaToolResult(
      text:
          'Enter on a web page can submit the form, so it is refused until '
          'routine_submit_check allows the submit. For a search field that '
          'runs on Enter, use os_pick.',
      isError: true,
    );
  }

  /// [result] of Gaia's [tool] once it ran: counted against the budget, its
  /// window checked against the allowed sites (§14), and the plan notice
  /// added.
  Future<GaiaToolResult> ran(
    String tool,
    Map<String, Object?> arguments,
    GaiaToolResult result,
  ) async {
    calls++;
    // The wait on the user isn't the item's time (§8.5).
    if (tool == 'ask_user' && _askedAt != null) {
      startedAt = startedAt.add(_clock().difference(_askedAt!));
      asking = null;
      _askedAt = null;
      changed?.call();
    }
    if (isGaiaOsControl(tool, arguments) && !finished) {
      final url = await focused();
      if (url != null && !allowed(url)) {
        park('left the allowed sites (${Uri.tryParse(url)?.host ?? url})');
      }
    }
    if (calls >= callLimit && !finished) {
      park(
        notice != null
            ? 'plan usage reached its line while it ran'
            : 'ran over budget (${routine.budgetCalls} calls)',
      );
    }
    if (notice == null) return result;
    return GaiaToolResult(
      text: '${result.text}\n\n$notice',
      isError: result.isError,
      image: result.image,
      mimeType: result.mimeType,
    );
  }

  /// Whether [url] is on the item's own site, or one of the routine's
  /// domains (§14).
  bool allowed(String url) {
    final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
    final own = Uri.tryParse(itemUrl)?.host.toLowerCase() ?? '';
    bool under(String domain) {
      final d = domain.trim().toLowerCase();
      return d.isNotEmpty && (host == d || host.endsWith('.$d'));
    }

    return host.isEmpty || under(_site(own)) || routine.domains.any(under);
  }

  /// [host]'s site, its last two labels: jobs.acme.com allows
  /// careers.acme.com. Under a country's second level it's three, so
  /// jobs.acme.co.uk allows careers.acme.co.uk but not other.co.uk.
  static String _site(String host) {
    final labels = host.split('.');
    final keep =
        labels.length > 2 &&
            labels.last.length == 2 &&
            const {
              'ac',
              'co',
              'com',
              'edu',
              'gov',
              'ne',
              'net',
              'or',
              'org',
            }.contains(labels[labels.length - 2])
        ? 3
        : 2;
    return labels.length <= keep
        ? host
        : labels.sublist(labels.length - keep).join('.');
  }

  /// A call to one of [kGaiaRoutineToolDefinitions].
  Future<GaiaToolResult> call(
    String tool,
    Map<String, Object?> arguments,
  ) async {
    if (finished) return _finished;
    switch (tool) {
      case 'report_posting':
        final fit = arguments['fit'];
        if (fit != 'go' && fit != 'skip') {
          return const GaiaToolResult(
            text: 'fit is go or skip.',
            isError: true,
          );
        }
        final text = arguments['posting'];
        posting = {
          ...arguments,
          if (text is String && text.length > 12000)
            'posting': text.substring(0, 12000),
        };
        if (fit == 'skip') {
          outcome = {
            'status': 'skipped',
            'reason': arguments['reason'] ?? 'a skip rule matched',
            'company': ?arguments['company'],
            'role': ?arguments['role'],
          };
          return GaiaToolResult(
            text: 'The item is skipped. $_next',
            isError: false,
          );
        }
        return const GaiaToolResult(
          text: 'Recorded. Go on with the application.',
          isError: false,
        );
      case 'routine_submit_check':
        final url = await focused();
        final why = gaiaSubmitRefusal(
          routine: routine,
          fields: arguments['fields'],
          duplicate: isDuplicate(itemUrl) || (url != null && isDuplicate(url)),
        );
        gatePassed = why == null;
        return GaiaToolResult(
          text: why == null
              ? 'Allowed: submit it, then report_outcome submitted.'
              : 'Not allowed: $why Leave the form filled and report ready.',
          isError: false,
        );
      case 'report_outcome':
        final status = arguments['status'];
        if (status is! String ||
            !const {
              'submitted',
              'ready',
              'needs_you',
              'skipped',
              'failed',
            }.contains(status)) {
          return const GaiaToolResult(
            text: 'status is submitted, ready, needs_you, skipped or failed.',
            isError: true,
          );
        }
        if (status != 'submitted' &&
            '${arguments['reason'] ?? ''}'.trim().isEmpty) {
          return const GaiaToolResult(
            text: 'Give a one-line reason.',
            isError: true,
          );
        }
        // Only through the gate (§8.4).
        outcome = status == 'submitted' && !gatePassed
            ? {
                ...arguments,
                'status': 'ready',
                'reason': 'reported submitted without the gate',
              }
            : {...arguments};
        return GaiaToolResult(text: 'Recorded. $_next', isError: false);
    }
    return GaiaToolResult(text: 'Unknown tool: $tool', isError: true);
  }

  /// Whether the CLI's own [tool] may run (§14): no shell, file edits or web
  /// tools; `Read` only on an upload.
  bool permits(String tool, Map<String, Object?> input) =>
      tool == 'Read' && _isUpload(input['file_path']);

  /// Whether [path] is one of [uploadPaths].
  bool _isUpload(Object? path) {
    String key(Object? path) =>
        '${path ?? ''}'.replaceAll('/', r'\').toLowerCase();
    return uploadPaths.any((upload) => key(upload) == key(path));
  }
}
