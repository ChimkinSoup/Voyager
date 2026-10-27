import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:voyager/core/dev/fps_monitor_controller.dart';
import 'package:voyager/features/gaia/adapters/gaia_agent_runner.dart';

/// The streaming speeds the debug menu offers, in characters a second.
const kGaiaDebugStreamSpeeds = [25, 50, 100, 200, 400, 800, 1600, 6400];

/// The Gaia debug menu's toggles. Local to this desktop and never synced:
/// kept in a JSON [file] beside Gaia's other files. Null in tests, which
/// keep nothing.
class GaiaDebug extends ChangeNotifier {
  GaiaDebug({this.file});

  final File? file;

  /// A message that is a script's command (`/msg1`) gets [gaiaDebugScripts]'
  /// reply, played through the real reply path, instead of a CLI run.
  var scriptedReplies = false;

  /// Every other message gets [gaiaDummyScript]'s reply too, and nothing
  /// reaches a provider: not the agent, nor the utility model's router or
  /// titles.
  var dummyMode = false;

  /// How long a scripted reply waits before its first word: the time a real
  /// one spends thinking.
  var replyDelay = const Duration(milliseconds: 1500);

  /// How long each of a sent message's images waits before it's attached,
  /// to see the message's images uploading.
  var attachDelay = Duration.zero;

  /// One of [kGaiaDebugStreamSpeeds].
  var streamSpeed = 400;

  var showFps = false;

  /// Every animation at a tenth of its speed ([timeDilation]).
  var slowAnimations = false;

  /// Gaia's window shows in screenshots and screen shares, which it's
  /// otherwise excluded from (GAIA_HLD.md §3.2).
  var allowScreenshots = false;

  /// Runs while [showFps] is on.
  final fps = FpsMonitorController();

  Future<void> load() async {
    final file = this.file;
    if (file == null || !await file.exists()) return;
    try {
      // Read whole before any of it is kept: a bad value leaves all defaults.
      final json = jsonDecode(await file.readAsString()) as Map;
      final delayMs =
          (json['replyDelayMs'] as int?) ?? replyDelay.inMilliseconds;
      final attachMs = (json['attachDelayMs'] as int?) ?? 0;
      scriptedReplies = json['scriptedReplies'] == true;
      dummyMode = json['dummyMode'] == true;
      replyDelay = Duration(milliseconds: delayMs);
      attachDelay = Duration(milliseconds: attachMs);
      if (json['streamSpeed'] case final int speed
          when kGaiaDebugStreamSpeeds.contains(speed)) {
        streamSpeed = speed;
      }
      showFps = json['showFps'] == true;
      slowAnimations = json['slowAnimations'] == true;
      allowScreenshots = json['allowScreenshots'] == true;
    } catch (error) {
      debugPrint('[gaia] debug settings unreadable, using defaults: $error');
    }
    _apply();
    notifyListeners();
  }

  // Each completes once saved.

  Future<void> setScriptedReplies(bool value) =>
      _set(() => scriptedReplies = value);

  Future<void> setDummyMode(bool value) => _set(() => dummyMode = value);

  /// Not [save]d mid-drag: the slider saves once it's let go.
  Future<void> setReplyDelay(Duration value, {bool save = true}) =>
      _set(() => replyDelay = value, save: save);

  Future<void> setAttachDelay(Duration value, {bool save = true}) =>
      _set(() => attachDelay = value, save: save);

  Future<void> setStreamSpeed(int value, {bool save = true}) =>
      _set(() => streamSpeed = value, save: save);

  Future<void> setShowFps(bool value) => _set(() => showFps = value);

  Future<void> setSlowAnimations(bool value) =>
      _set(() => slowAnimations = value);

  Future<void> setAllowScreenshots(bool value) =>
      _set(() => allowScreenshots = value);

  /// The script [prompt] calls for, while [scriptedReplies] is on, else
  /// [gaiaDummyScript] while [dummyMode] is.
  GaiaDebugScript? scriptFor(String prompt) {
    final script = scriptedReplies
        ? gaiaDebugScripts[prompt.trim().toLowerCase()]
        : null;
    return script ?? (dummyMode ? gaiaDummyScript : null);
  }

  Future<void> _set(void Function() change, {bool save = true}) {
    change();
    _apply();
    notifyListeners();
    if (!save) return _saved;
    // In turn, so an older write never lands after a newer one.
    return _saved = _saved.then((_) => _save());
  }

  var _saved = Future<void>.value();

  void _apply() {
    timeDilation = slowAnimations ? 10 : 1;
    if (showFps) {
      fps.start();
    } else {
      fps.stop();
    }
  }

  Future<void> _save() async {
    final file = this.file;
    if (file == null) return;
    try {
      await file.parent.create(recursive: true);
      await file.writeAsString(
        jsonEncode({
          'scriptedReplies': scriptedReplies,
          'dummyMode': dummyMode,
          'replyDelayMs': replyDelay.inMilliseconds,
          'attachDelayMs': attachDelay.inMilliseconds,
          'streamSpeed': streamSpeed,
          'showFps': showFps,
          'slowAnimations': slowAnimations,
          'allowScreenshots': allowScreenshots,
        }),
      );
    } catch (error) {
      debugPrint('[gaia] debug settings not saved: $error');
    }
  }

  @override
  void dispose() {
    fps.dispose();
    super.dispose();
  }
}

/// A canned reply: what it shows off, and the steps it plays.
class GaiaDebugScript {
  const GaiaDebugScript(this.description, this.steps);

  final String description;
  final List<GaiaDebugStep> steps;
}

sealed class GaiaDebugStep {
  const GaiaDebugStep();
}

/// A text block, streamed at the menu's speed.
class GaiaDebugText extends GaiaDebugStep {
  const GaiaDebugText(this.text);

  final String text;
}

/// A tool call, which takes [duration].
class GaiaDebugTool extends GaiaDebugStep {
  const GaiaDebugTool(this.name, [this.duration = const Duration(seconds: 1)]);

  final String name;
  final Duration duration;
}

class GaiaDebugPause extends GaiaDebugStep {
  const GaiaDebugPause(this.duration);

  final Duration duration;
}

/// Ends the turn as the CLI reports a failure: an error result.
class GaiaDebugError extends GaiaDebugStep {
  const GaiaDebugError(this.message);

  final String message;
}

/// Ends the turn as a CLI that died does.
class GaiaDebugCrash extends GaiaDebugStep {
  const GaiaDebugCrash();
}

/// Never ends the turn: only Stop or Abort does.
class GaiaDebugHang extends GaiaDebugStep {
  const GaiaDebugHang();
}

/// Plays [GaiaDebugScript]s as an agent runner runs turns: the same
/// events, a [GaiaTurnResult] at the end, and an error when stopped or
/// killed. No process, no tokens.
class GaiaScriptedRunner {
  final _active = <String, Completer<GaiaTurnResult>>{};

  Future<GaiaTurnResult> send({
    required String chatId,
    required GaiaDebugScript script,
    required Duration replyDelay,
    required int streamSpeed,
    required void Function(GaiaAgentEvent event) onEvent,
  }) async {
    final turn = _active[chatId] = Completer<GaiaTurnResult>();
    unawaited(_play(turn, script, replyDelay, streamSpeed, onEvent));
    try {
      return await turn.future;
    } finally {
      if (_active[chatId] == turn) _active.remove(chatId);
    }
  }

  static const _tick = Duration(milliseconds: 30);

  Future<void> _play(
    Completer<GaiaTurnResult> turn,
    GaiaDebugScript script,
    Duration replyDelay,
    int streamSpeed,
    void Function(GaiaAgentEvent event) onEvent,
  ) async {
    // False once the turn was stopped, or ended.
    Future<bool> wait(Duration duration) async {
      await Future<void>.delayed(duration);
      return !turn.isCompleted;
    }

    if (!await wait(replyDelay)) return;
    final reply = StringBuffer();
    for (final step in script.steps) {
      switch (step) {
        case GaiaDebugText(:final text):
          onEvent(const GaiaTextStart());
          // What's due by the clock, so a speed below one character a tick
          // isn't rounded up to one.
          final clock = Stopwatch()..start();
          var sent = 0;
          while (sent < text.length) {
            if (!await wait(_tick)) return;
            final due = (streamSpeed * clock.elapsedMicroseconds / 1e6)
                .floor()
                .clamp(0, text.length);
            if (due <= sent) continue;
            final chunk = text.substring(sent, due);
            sent = due;
            reply.write(chunk);
            onEvent(GaiaTextDelta(chunk));
          }
        case GaiaDebugTool(:final name, :final duration):
          onEvent(GaiaToolUse(name));
          if (!await wait(duration)) return;
        case GaiaDebugPause(:final duration):
          if (!await wait(duration)) return;
        case GaiaDebugError(:final message):
          turn.complete(
            GaiaTurnResult(sessionId: '', isError: true, text: message),
          );
          return;
        case GaiaDebugCrash():
          turn.completeError(GaiaRunException('Claude Code exited (code 1)'));
          return;
        case GaiaDebugHang():
          return;
      }
    }
    turn.complete(
      GaiaTurnResult(sessionId: '', isError: false, text: reply.toString()),
    );
  }

  bool isRunning(String chatId) => _active.containsKey(chatId);

  void stop(String chatId) => _fail(_active.remove(chatId));

  void killAll() {
    final active = [..._active.values];
    _active.clear();
    active.forEach(_fail);
  }

  static void _fail(Completer<GaiaTurnResult>? turn) {
    if (turn == null || turn.isCompleted) return;
    turn.completeError(GaiaRunException('Claude Code exited (code 1)'));
  }
}

/// Dummy mode's reply, to every message.
const gaiaDummyScript = GaiaDebugScript('Dummy mode', [
  GaiaDebugText(
    'Dummy reply: dummy mode is on, so this never reached a provider.',
  ),
]);

/// The scripts, by command.
final Map<String, GaiaDebugScript> gaiaDebugScripts = {
  '/help': GaiaDebugScript('Lists these commands', [
    GaiaDebugText(
      'Scripted replies, for testing Gaia without a Claude Code run:\n\n'
      '${[for (final MapEntry(:key, :value) in _scripts.entries) '- `$key`: ${value.description}'].join('\n')}',
    ),
  ]),
  ..._scripts,
};

const _scripts = {
  '/msg1': GaiaDebugScript(
    'Markdown: headings, emphasis, lists, quotes, a table',
    [GaiaDebugText(_markdown)],
  ),
  '/msg2': GaiaDebugScript('LaTeX: inline and display maths', [
    GaiaDebugText(_latex),
  ]),
  '/msg3': GaiaDebugScript('Code blocks in several languages, and long lines', [
    GaiaDebugText(_code),
  ]),
  '/msg4': GaiaDebugScript('Tool calls between text blocks, with pauses', [
    GaiaDebugText("I'll look at the project first."),
    GaiaDebugTool('Glob'),
    GaiaDebugTool('Read'),
    GaiaDebugTool('Read'),
    GaiaDebugTool('Grep', Duration(milliseconds: 600)),
    GaiaDebugText(
      'Found it: the timer is never cancelled in `dispose`. Running the '
      'tests before changing anything.',
    ),
    GaiaDebugTool('Bash', Duration(seconds: 3)),
    GaiaDebugPause(Duration(seconds: 1)),
    GaiaDebugTool('Edit'),
    GaiaDebugTool('Bash', Duration(seconds: 2)),
    GaiaDebugTool('Bash', Duration(seconds: 2)),
    GaiaDebugText(
      'Fixed. `dispose` now cancels the timer, and all 48 tests pass.',
    ),
  ]),
  '/msg5': GaiaDebugScript('A long reply, for scrolling', [
    GaiaDebugText(_long),
  ]),
  '/msg6': GaiaDebugScript('Ends on a question ("Gaia has a question")', [
    GaiaDebugText(
      'I can do this two ways:\n\n'
      '1. **Patch the parser** so it skips empty lines. Small, but it leaves '
      'the format loose.\n'
      '2. **Tighten the format** and migrate the old files. More work, and '
      'stricter from then on.\n\n'
      'Which would you rather I do?',
    ),
  ]),
  '/msg7': GaiaDebugScript('Edge cases: emoji, CJK, RTL, unbroken text', [
    GaiaDebugText(_edges),
  ]),
  '/slow': GaiaDebugScript('Ten seconds of thinking, then a short reply', [
    GaiaDebugPause(Duration(seconds: 10)),
    GaiaDebugText('Sorry for the wait. Here is the answer: 42.'),
  ]),
  '/error': GaiaDebugScript('An error Claude Code reports as its result', [
    GaiaDebugText('Let me check that'),
    GaiaDebugError(
      'There\'s an issue with the selected model (claude-opus-5-5). It may '
      'not exist or you may not have access to it.',
    ),
  ]),
  '/crash': GaiaDebugScript('Claude Code dies mid-reply', [
    GaiaDebugText('Starting on it. First I will read the config and then'),
    GaiaDebugCrash(),
  ]),
  '/hang': GaiaDebugScript('Streams a little, then never finishes (Stop it)', [
    GaiaDebugText('Working on it. This is going to take a while.'),
    GaiaDebugTool('Bash'),
    GaiaDebugHang(),
  ]),
};

const _markdown = r'''# A heading

Some **bold**, some *italic*, some ***both***, some ~~struck~~ text, and some `inline code`. A [link](https://example.com) too.

## Lists

- A bullet
- Another, with a nested list:
  - Nested one
  - Nested two
- A last one

1. First
2. Second
3. Third

- [x] A done task
- [ ] One still to do

### A quote

> Quoted text, which can run over several lines when it's long enough to wrap in a floater.
>
> A second paragraph in the quote.

## A table

| Command | What it does | Speed |
|---|---|---:|
| `/msg1` | Markdown | Fast |
| `/msg2` | LaTeX | Fast |
| `/slow` | Waits | 10 s |

---

A closing paragraph after a rule.''';

const _latex =
    r'''Inline maths sits in a sentence, like $e^{i\pi} + 1 = 0$ or \(a^2 + b^2 = c^2\), and should line up with the text around it.

Display maths gets its own line:

$$
\int_{-\infty}^{\infty} e^{-x^2}\,dx = \sqrt{\pi}
$$

\[
\sum_{n=1}^{\infty} \frac{1}{n^2} = \frac{\pi^2}{6}
\]

A matrix, and an aligned derivation:

$$
A = \begin{pmatrix} 1 & 2 & 3 \\ 4 & 5 & 6 \\ 7 & 8 & 9 \end{pmatrix}
$$

$$
\begin{aligned}
(x + 1)^2 &= (x + 1)(x + 1) \\
&= x^2 + 2x + 1
\end{aligned}
$$

Cases: $f(x) = \begin{cases} x & x \ge 0 \\ -x & x < 0 \end{cases}$, and a price that isn't maths: it costs $5 or $10.''';

const _code = r'''Here's the fix in Dart:

```dart
class Debouncer {
  Debouncer(this.delay);

  final Duration delay;
  Timer? _timer;

  void call(void Function() action) {
    _timer?.cancel();
    _timer = Timer(delay, action);
  }

  void dispose() => _timer?.cancel();
}
```

The same idea in Python:

```python
import threading

def debounce(delay):
    def wrap(fn):
        timer = None
        def call(*args):
            nonlocal timer
            if timer: timer.cancel()
            timer = threading.Timer(delay, fn, args)
            timer.start()
        return call
    return wrap
```

A shell command with a very long line that won't fit:

```powershell
Get-ChildItem -Path C:\Users\Juno\Code\Voyager\lib -Recurse -Filter *.dart | Where-Object { $_.Length -gt 50000 } | Sort-Object Length -Descending | Select-Object -First 10 FullName, Length
```

And a code block with no language:

```
plain text
  indented
```''';

const _long =
    '''This is a long reply, to check scrolling, the small floater's last-three-turns cut, and how a reply this size performs while it streams.

Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat.

Duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur. Excepteur sint occaecat cupidatat non proident, sunt in culpa qui officia deserunt mollit anim id est laborum.

Sed ut perspiciatis unde omnis iste natus error sit voluptatem accusantium doloremque laudantium, totam rem aperiam, eaque ipsa quae ab illo inventore veritatis et quasi architecto beatae vitae dicta sunt explicabo.

Nemo enim ipsam voluptatem quia voluptas sit aspernatur aut odit aut fugit, sed quia consequuntur magni dolores eos qui ratione voluptatem sequi nesciunt.

Neque porro quisquam est, qui dolorem ipsum quia dolor sit amet, consectetur, adipisci velit, sed quia non numquam eius modi tempora incidunt ut labore et dolore magnam aliquam quaerat voluptatem.

Ut enim ad minima veniam, quis nostrum exercitationem ullam corporis suscipit laboriosam, nisi ut aliquid ex ea commodi consequatur? Quis autem vel eum iure reprehenderit qui in ea voluptate velit esse quam nihil molestiae consequatur.

At vero eos et accusamus et iusto odio dignissimos ducimus qui blanditiis praesentium voluptatum deleniti atque corrupti quos dolores et quas molestias excepturi sint occaecati cupiditate non provident.

Similique sunt in culpa qui officia deserunt mollitia animi, id est laborum et dolorum fuga. Et harum quidem rerum facilis est et expedita distinctio.

Nam libero tempore, cum soluta nobis est eligendi optio cumque nihil impedit quo minus id quod maxime placeat facere possimus, omnis voluptas assumenda est, omnis dolor repellendus.

Temporibus autem quibusdam et aut officiis debitis aut rerum necessitatibus saepe eveniet ut et voluptates repudiandae sint et molestiae non recusandae.

The end.''';

const _edges =
    '''Emoji: 🌍 🚀 👩🏽‍💻 🏳️‍🌈 ❤️‍🔥 (some are several code points joined)

CJK: 日本語のテキスト、中文文本，한국어 텍스트.

Right to left: שלום עולם, مرحبا بالعالم, mixed with English in one line.

An unbroken run: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

A long URL: https://example.com/a/very/long/path/that/keeps/going/and/going/until/it/has/to/wrap/somewhere?query=string&with=parameters

Lines with trailing spaces
and blank lines between them:



Tabs:	one	two	three

Combining marks: e\u0301 a\u0308 n\u0303, and zero-width joiners: a\u200db.

Symbols: → ← ↑ ↓ ≤ ≥ ≠ ∞ ∑ √ π © ® ™ ° ± × ÷''';
