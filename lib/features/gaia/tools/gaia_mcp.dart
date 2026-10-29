/// Gaia's own tools (GAIA_HLD.md §5.3), served as an MCP server to every
/// agent, whatever its CLI: Claude Code gets it in-process over its
/// stream-json control channel, Codex through the `voyager.exe --gaia-mcp`
/// shim. Both hand each JSON-RPC message to [gaiaMcpAnswer], bound to the
/// turn it came from.
library;

/// The server's name, which the CLIs put before each tool's
/// (`mcp__gaia__ask_user`).
const kGaiaMcpServer = 'gaia';

/// The tools a turn can call, bound to its chat and run.
abstract interface class GaiaTurnTools {
  /// A `tools/call`: the result's text, and whether it's an error the agent
  /// should see as one.
  Future<GaiaToolResult> call(String name, Map<String, Object?> arguments);

  /// A permission prompt from the CLI itself (§10.1): may [tool] run with
  /// [input]? Claude Code only; Codex can't ask in `exec`.
  Future<GaiaPermission> permit({
    required String tool,
    required Map<String, Object?> input,
    required String description,
  });
}

typedef GaiaToolResult = ({String text, bool isError});

/// A tool call that failed in a way the agent should be told, in [message].
class GaiaToolException implements Exception {
  GaiaToolException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// [message] says why not, when the user said.
typedef GaiaPermission = ({bool allow, String message});

/// How long `ask_user` and a permission card hold the agent (§10.1). The
/// CLIs' MCP tool timeouts are set past it.
const kGaiaCardHold = Duration(hours: 1);

/// The CLIs' MCP tool timeout: past [kGaiaCardHold], so a card's wait ends
/// before the CLI's own.
const kGaiaMcpToolTimeout = Duration(hours: 1, minutes: 5);

/// Every tool's definition, as `tools/list` gives it. Names carry no dots:
/// the Messages API allows only letters, digits, `_` and `-`.
const kGaiaToolDefinitions = <Map<String, Object?>>[
  {
    'name': 'ask_user',
    'description':
        'Ask the user a question and wait for their answer. Use this '
        'whenever you need the user to decide something or to fill in '
        'something you can\'t work out, rather than guessing or ending '
        'your turn with a question. Offer options when the answer is one '
        'of a few choices; the user can always type their own answer too. '
        'Their answer comes back as this tool\'s result. If they haven\'t '
        'answered within an hour the result says so: end your turn then, '
        'and their answer comes as their next message.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'question': {
          'type': 'string',
          'description': 'The question, complete on its own.',
        },
        'options': {
          'type': 'array',
          'description':
              'Choices to offer, at most 9. Leave out for a free '
              'answer only.',
          'items': {
            'type': 'object',
            'properties': {
              'label': {'type': 'string', 'description': '1 to 5 words.'},
              'description': {
                'type': 'string',
                'description': 'What picking it means.',
              },
            },
            'required': ['label'],
          },
        },
        'multi_select': {
          'type': 'boolean',
          'description': 'The user may pick more than one option.',
        },
        'recommended': {
          'type': 'string',
          'description': 'The label of the option you recommend, if any.',
        },
      },
      'required': ['question'],
    },
  },
  {
    'name': 'voyager_todos',
    'description':
        "Read the user's todo lists from Voyager: open tasks with their "
        'list, due date, notes, subtasks and id.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'due_by': {
          'type': 'string',
          'description': 'YYYY-MM-DD: only tasks due on or before this day.',
        },
        'list': {
          'type': 'string',
          'description': "A list's name: only that list's tasks.",
        },
        'include_completed': {
          'type': 'boolean',
          'description': 'Completed tasks too.',
        },
      },
    },
  },
  {
    'name': 'voyager_calendar',
    'description':
        "Read the user's calendar from Voyager: events from one day to "
        'another, at most 62 days, repeating ones on each day they occur, '
        'each with its id.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'from': {'type': 'string', 'description': 'YYYY-MM-DD, inclusive.'},
        'to': {'type': 'string', 'description': 'YYYY-MM-DD, inclusive.'},
      },
      'required': ['from', 'to'],
    },
  },
  {
    'name': 'voyager_journal',
    'description':
        "Read the user's journal entries from Voyager, from one day to "
        'another, at most 31 days, each with its id.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'from': {'type': 'string', 'description': 'YYYY-MM-DD, inclusive.'},
        'to': {'type': 'string', 'description': 'YYYY-MM-DD, inclusive.'},
      },
      'required': ['from', 'to'],
    },
  },
  {
    'name': 'voyager_workouts',
    'description':
        "Read the user's workouts from Voyager: sessions from one day to "
        'another, at most 62 days, with each exercise\'s sets.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'from': {'type': 'string', 'description': 'YYYY-MM-DD, inclusive.'},
        'to': {'type': 'string', 'description': 'YYYY-MM-DD, inclusive.'},
      },
      'required': ['from', 'to'],
    },
  },
  {
    'name': 'propose_todo',
    'description':
        'Propose a new task in Voyager, or a change to one. Nothing is '
        'written until the user accepts it: they see it in an editor, can '
        'change any field, and accept or turn it down. The result says what '
        'was saved, with their edits, or what they want changed instead; '
        'propose again with those changes. Pass "id" (from voyager_todos) '
        'to change a task, with only the fields that change.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'id': {
          'type': 'string',
          'description': "An existing task's id, to change it.",
        },
        'title': {'type': 'string'},
        'list': {
          'type': 'string',
          'description': "A list's name. Leave out for the default list.",
        },
        'due': {
          'type': ['string', 'null'],
          'description':
              'YYYY-MM-DD, or YYYY-MM-DDTHH:mm for a time; null clears it.',
        },
        'notes': {'type': 'string'},
        'starred': {'type': 'boolean'},
        'completed': {
          'type': 'boolean',
          'description': 'Mark it done, or not done.',
        },
      },
    },
  },
  {
    'name': 'propose_calendar_event',
    'description':
        'Propose a new calendar event in Voyager, or a change to one. '
        'Nothing is written until the user accepts it in an editor, where '
        'they can change any field. The result says what was saved, with '
        'their edits, or what they want changed instead; propose again with '
        'those changes. Pass "id" (from voyager_calendar) to change an '
        "event, with only the fields that change. Repeating events can't be "
        'changed this way.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'id': {
          'type': 'string',
          'description': "An existing event's id, to change it.",
        },
        'title': {'type': 'string'},
        'start': {
          'type': 'string',
          'description':
              'YYYY-MM-DD for an all-day event, YYYY-MM-DDTHH:mm (local '
              'time) for a timed one.',
        },
        'end': {
          'type': 'string',
          'description':
              'Same form as start; the last day of an all-day event. '
              'Leave out for one day, or an hour.',
        },
        'calendar': {
          'type': 'string',
          'description': "A calendar's name. Leave out for the default.",
        },
        'notes': {'type': 'string'},
      },
    },
  },
  {
    'name': 'propose_journal_entry',
    'description':
        'Propose a new journal entry in Voyager, or a change to one. '
        'Nothing is written until the user accepts it in an editor, where '
        'they can change any of it. The result says what was saved, with '
        'their edits, or what they want changed instead. Pass "id" (from '
        "voyager_journal) to change an entry; a new body replaces the whole "
        'entry, so include everything it should keep.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'id': {
          'type': 'string',
          'description': "An existing entry's id, to change it.",
        },
        'title': {'type': 'string'},
        'body': {'type': 'string', 'description': 'The entry itself.'},
        'date': {
          'type': 'string',
          'description':
              'When it was written: YYYY-MM-DDTHH:mm (local time), or '
              'YYYY-MM-DD. Leave out for now.',
        },
        'journal': {
          'type': 'string',
          'description': "A journal's name. Leave out for the default.",
        },
        'mood': {'type': 'integer', 'minimum': 0, 'maximum': 10},
      },
    },
  },
];

/// The `voyager_*` read tools: the main instance answers them.
bool isGaiaVoyagerRead(String name) => name.startsWith('voyager_');

/// The protocol version answered when the client names none.
const _protocolVersion = '2025-06-18';

/// The response to one JSON-RPC [message], or null for a notification.
/// [tools] is the turn the call belongs to; a call outside one fails.
Future<Map<String, Object?>?> gaiaMcpAnswer(
  Map<String, Object?> message,
  GaiaTurnTools? tools,
) async {
  final id = message['id'];
  if (id == null) return null;
  final params = (message['params'] as Map?)?.cast<String, Object?>() ?? {};
  Map<String, Object?> result(Object? value) => {
    'jsonrpc': '2.0',
    'id': id,
    'result': value,
  };
  switch (message['method']) {
    case 'initialize':
      return result({
        'protocolVersion': params['protocolVersion'] ?? _protocolVersion,
        'capabilities': {'tools': <String, Object?>{}},
        'serverInfo': {'name': kGaiaMcpServer, 'version': '1'},
      });
    case 'ping':
      return result(<String, Object?>{});
    case 'tools/list':
      return result({'tools': kGaiaToolDefinitions});
    case 'tools/call':
      final name = params['name'];
      final GaiaToolResult answer;
      if (name is! String ||
          !kGaiaToolDefinitions.any((tool) => tool['name'] == name)) {
        answer = (text: 'Unknown tool: $name', isError: true);
      } else if (tools == null) {
        answer = (text: 'No Gaia run is active.', isError: true);
      } else {
        answer = await tools.call(
          name,
          (params['arguments'] as Map?)?.cast<String, Object?>() ?? {},
        );
      }
      return result({
        'content': [
          {'type': 'text', 'text': answer.text},
        ],
        'isError': answer.isError,
      });
    default:
      return {
        'jsonrpc': '2.0',
        'id': id,
        'error': {
          'code': -32601,
          'message': 'Method not found: ${message['method']}',
        },
      };
  }
}
