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

/// A tool's answer: its text, whether it's an error the agent should see as
/// one, and any image, as `os_screenshot` has.
class GaiaToolResult {
  const GaiaToolResult({
    required this.text,
    required this.isError,
    this.image,
    this.mimeType,
  });

  final String text;
  final bool isError;

  /// In base64.
  final String? image;
  final String? mimeType;

  @override
  bool operator ==(Object other) =>
      other is GaiaToolResult &&
      other.text == text &&
      other.isError == isError &&
      other.image == image &&
      other.mimeType == mimeType;

  @override
  int get hashCode => Object.hash(text, isError, image, mimeType);
}

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
  {
    'name': 'memory_search',
    'description':
        "Search what the user has asked Gaia to remember about them: "
        'preferences, people, projects, facts about their life. Returns '
        'each matching memory in full. Your instructions list the memories '
        'saved when this chat started; search for the full text of one, '
        'or for any saved since.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'query': {
          'type': 'string',
          'description':
              'Words to look for; a memory matching more ranks '
              'higher.',
        },
        'tags': {
          'type': 'array',
          'items': {'type': 'string'},
          'description': 'Only memories with every one of these tags.',
        },
      },
    },
  },
  {
    'name': 'memory_propose',
    'description':
        'Offer a memory: one short fact about the user worth keeping '
        'across chats, such as a lasting preference, a person or project '
        'in their life, or a decision they made. Not for passing details '
        'of this chat. It waits in the user\'s memory inbox until they '
        'approve it. Use it when the user asks you to remember something, '
        'or when you learn something they would want remembered.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'text': {
          'type': 'string',
          'description':
              'The fact, complete on its own, in the first person as the '
              'user would put it, and at most 500 characters: "I prefer '
              'metric units", not "They said yes".',
        },
        'tags': {
          'type': 'array',
          'items': {'type': 'string'},
          'description': 'A few one-word topics, such as "food" or "work".',
        },
      },
      'required': ['text'],
    },
  },
  {
    'name': 'os_focused_window',
    'description':
        "Say which window the os_ tools read: the app in front of the user, "
        "or the one under Gaia when Gaia is in front. Gaia's own windows are "
        'never read. Works only if the user has turned on "can see screen" '
        "for this chat; if it hasn't, tell them they can, with the eye button "
        'under the composer.',
    'inputSchema': {'type': 'object', 'properties': <String, Object?>{}},
  },
  {
    'name': 'os_read_screen',
    'description':
        "Read that window's controls as text: each one's type, name, value "
        'and position. Exact, cheap, and it shows what can be clicked, so try '
        'this before os_screenshot. Password, card and one-time code fields '
        'are never read. Refused for apps and sites the user has excluded, '
        'and unless "can see screen" is on for this chat.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'region': {
          'type': 'object',
          'description':
              'Only controls touching this rectangle, in physical screen '
              'pixels. Leave out for the whole window.',
          'properties': {
            'left': {'type': 'integer'},
            'top': {'type': 'integer'},
            'width': {'type': 'integer'},
            'height': {'type': 'integer'},
          },
          'required': ['left', 'top', 'width', 'height'],
        },
      },
    },
  },
  {
    'name': 'os_screenshot',
    'description':
        "Take a picture of that window, for what os_read_screen can't "
        'describe: canvases, images, games, some Electron apps. Password, card '
        'and one-time code fields are blacked out. Refused for apps and sites '
        'the user has excluded, and unless "can see screen" is on for this '
        'chat. Called from a script, its result is a string whose last line '
        'is a data: URL. To see it, pass that line to image() in the same '
        'script, as image(r.split("\\n").pop()); never retype the data.',
    'inputSchema': {'type': 'object', 'properties': <String, Object?>{}},
  },
  {
    'name': 'os_windows',
    'description':
        "List the windows open on the user's screen, front first: each one's "
        'id, app, title and position, or that it is minimized, and which one '
        "the os_ tools work on. Pass an id to os_focus. Apps the user has "
        'excluded show only as excluded. Works only if "can see screen" is on '
        'for this chat.',
    'inputSchema': {'type': 'object', 'properties': <String, Object?>{}},
  },
  {
    'name': 'os_click',
    'description':
        'Click in the window the os_ tools work on. Name the control as '
        "os_read_screen shows it; use x and y alone only for what it can't "
        'describe. Runs at once or after the user approves a card, depending '
        "on the chat's mode, and the result says what ran. Works only if the "
        'user has turned on "can control" for this chat, with the hand button '
        'under the composer. After any action, read the screen again rather '
        "than assuming it worked. Before anything irreversible the user didn't "
        'clearly ask for, such as sending, buying or deleting, ask them with '
        'ask_user first.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        ..._controlTarget,
        'button': {
          'type': 'string',
          'enum': ['left', 'right'],
          'description': 'Left if left out.',
        },
        'double': {'type': 'boolean', 'description': 'A double click.'},
        ..._anywhere,
        ..._readAfter,
      },
    },
  },
  {
    'name': 'os_scroll',
    'description':
        'Scroll the mouse wheel over a control or point, or over the middle of '
        'the window with neither. Approved or not like os_click.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        ..._controlTarget,
        'direction': {
          'type': 'string',
          'enum': ['up', 'down', 'left', 'right'],
        },
        'amount': {
          'type': 'integer',
          'minimum': 1,
          'maximum': 50,
          'description': 'Wheel notches. 3 if left out.',
        },
        ..._readAfter,
      },
      'required': ['direction'],
    },
  },
  {
    'name': 'os_type',
    'description':
        'Type text, at most 2000 characters, into a named control, which is '
        'clicked first, or with none, into whatever has focus. Password, card '
        'and one-time code fields are refused. Approved or not like os_click.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        ..._controlTarget,
        'text': {'type': 'string'},
        ..._readAfter,
      },
      'required': ['text'],
    },
  },
  {
    'name': 'os_key',
    'description':
        'Press a key or a chord in that window: "Enter", "Ctrl+S", "Alt+F4", '
        '"Shift+Tab". The Windows key, as "Win" or "Win+R", works only in a '
        'chat in Auto, where Start or the box it opens becomes the window the '
        'os_ tools work on. Approved or not like os_click.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'keys': {'type': 'string'},
        ..._readAfter,
      },
      'required': ['keys'],
    },
  },
  {
    'name': 'os_steps',
    'description':
        'Several actions in one list, at most 20, run at once or approved by '
        "the user together or one at a time, depending on the chat's mode. "
        'Prefer this to calling os_click and the others in turn. A control '
        "that isn't on screen yet, as in a menu an earlier step opens, can be "
        'named too, but when approving, each step then needs its own approval. '
        'When a step opens a dialog, a run that needed approving stops: read '
        'the screen and send the rest as a new list. One that ran at once acts '
        'on the dialog from then on, and the result says so.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'steps': {
          'type': 'array',
          'items': {
            'type': 'object',
            'properties': {
              'action': {
                'type': 'string',
                'enum': ['click', 'scroll', 'type', 'key'],
              },
              ..._controlTarget,
              'button': {
                'type': 'string',
                'enum': ['left', 'right'],
              },
              'double': {'type': 'boolean'},
              'direction': {
                'type': 'string',
                'enum': ['up', 'down', 'left', 'right'],
              },
              'amount': {'type': 'integer'},
              'text': {'type': 'string'},
              'keys': {'type': 'string'},
              ..._anywhere,
            },
            'required': ['action'],
          },
        },
        ..._readAfter,
      },
      'required': ['steps'],
    },
  },
  {
    'name': 'os_open',
    'description':
        'Open an app, a file or folder, or a web page, bring its window to the '
        'front, and make it the window the os_ tools work on. Use this rather '
        "than starting a program from the shell, whose window Gaia can't tell "
        'apart. The result names the window it opened. Refused for apps and '
        'sites the user has excluded. Approved or not like os_click.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'target': {
          'type': 'string',
          'description':
              "An installed app's name as the Start menu shows it "
              '("Notepad", "Google Chrome"), a full path, or a URL with its '
              'scheme ("https://…", "mailto:…", "ms-settings:").',
        },
        ..._readAfter,
      },
      'required': ['target'],
    },
  },
  {
    'name': 'os_focus',
    'description':
        'Bring an open window to the front, restoring it if minimized, and '
        'make it the window the os_ tools work on. Approved or not like '
        'os_click.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'window': {
          'type': 'string',
          'description':
              "An id from os_windows, or words from the window's title.",
        },
        ..._readAfter,
      },
      'required': ['window'],
    },
  },
];

/// What an action tool can aim at. With a name and a point, the point picks
/// among controls of that name.
const _controlTarget = <String, Object?>{
  'name': {
    'type': 'string',
    'description': "The control's name, as os_read_screen shows it.",
  },
  'type': {
    'type': 'string',
    'description': "The control's type, as os_read_screen shows it: Button.",
  },
  'x': {'type': 'integer', 'description': 'Physical screen pixels.'},
  'y': {'type': 'integer', 'description': 'Physical screen pixels.'},
};

/// A click outside the window (GAIA_AUTONOMY_HLD.md §5.5).
const _anywhere = <String, Object?>{
  'anywhere': {
    'type': 'boolean',
    'description':
        'A click at x and y outside the window: the taskbar, the tray, '
        'another window. Only in a chat in Auto. Whatever opens in front '
        'becomes the window the os_ tools work on.',
  },
};

/// The screen read with an action's result (§5.6).
const _readAfter = <String, Object?>{
  'read_after': {
    'type': 'boolean',
    'description':
        'Also return the window as os_read_screen reads it once this has '
        'run, which saves a call. Needs "can see screen".',
  },
};

/// The `voyager_*` read tools: the main instance answers them.
bool isGaiaVoyagerRead(String name) => name.startsWith('voyager_');

/// The `memory_*` tools (§11): the main instance answers them too.
bool isGaiaMemoryTool(String name) => name.startsWith('memory_');

/// The `os_*` read tools (§15.6): the main instance answers them too.
bool isGaiaOsRead(String name) => const {
  'os_focused_window',
  'os_read_screen',
  'os_screenshot',
  'os_windows',
}.contains(name);

/// The `os_*` action tools (§15.6): each is a step list the user approves.
bool isGaiaOsControl(String name) => const {
  'os_click',
  'os_scroll',
  'os_type',
  'os_key',
  'os_steps',
  'os_open',
  'os_focus',
}.contains(name);

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
        answer = GaiaToolResult(text: 'Unknown tool: $name', isError: true);
      } else if (tools == null) {
        answer = GaiaToolResult(text: 'No Gaia run is active.', isError: true);
      } else {
        answer = await tools.call(
          name,
          (params['arguments'] as Map?)?.cast<String, Object?>() ?? {},
        );
      }
      return result({
        'content': [
          {'type': 'text', 'text': answer.text},
          if (answer.image case final image?)
            {'type': 'image', 'data': image, 'mimeType': answer.mimeType},
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
