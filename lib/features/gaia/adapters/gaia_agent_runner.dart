import 'package:voyager/domain/models/gaia_models.dart';

/// What every adapter reports of a turn (GAIA_HLD.md §5.1), whatever its
/// CLI or API prints: the agent's text and the tools it called.
sealed class GaiaAgentEvent {
  const GaiaAgentEvent();
}

/// A text block of the agent's own reply has started.
class GaiaTextStart extends GaiaAgentEvent {
  const GaiaTextStart();
}

class GaiaTextDelta extends GaiaAgentEvent {
  const GaiaTextDelta(this.text);

  final String text;
}

/// The agent called a tool.
class GaiaToolUse extends GaiaAgentEvent {
  const GaiaToolUse(this.name);

  final String name;
}

/// The end of a turn. [isError] covers failures the backend reports as a
/// reply, such as an unknown model, with [text] saying what went wrong.
class GaiaTurnResult {
  const GaiaTurnResult({
    required this.sessionId,
    required this.isError,
    required this.text,
  });

  /// The native session to resume next time.
  final String sessionId;
  final bool isError;
  final String text;
}

/// A turn that ended without a result: the process died, or its output
/// couldn't be read.
class GaiaRunException implements Exception {
  GaiaRunException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Runs chats on one backend. One runner per adapter; the model is chosen
/// per turn, since a chat's tier can change between turns (§7.4).
abstract interface class GaiaAgentRunner {
  /// Starts a turn in [chatId]'s session: [sessionId] resumes one, null
  /// starts one. [onEvent] gets each event of the turn; the future completes
  /// with its result, or throws a [GaiaRunException].
  Future<GaiaTurnResult> send({
    required String chatId,
    required String? sessionId,
    required String model,
    required String prompt,
    required void Function(GaiaAgentEvent event) onEvent,
  });

  bool isRunning(String chatId);

  /// GAIA.md changed (§5.2).
  Future<void> setInstructions(String text);

  /// Kills [chatId]'s run; its turn fails.
  Future<void> stop(String chatId);

  /// Kills every run this runner started.
  Future<void> killAll();
}

/// Builds a reply's parts from a turn's events: text blocks in order, with
/// each run of tool calls between them collapsed to an activity part (§8.1).
class GaiaTurnBuilder {
  final _parts = <GaiaPart>[];

  List<GaiaPart> get parts => List.unmodifiable(_parts);

  /// Applies [event]; true when [parts] changed.
  bool apply(GaiaAgentEvent event) {
    switch (event) {
      case GaiaTextStart():
        _parts.add(const GaiaTextPart(''));
      case GaiaTextDelta(:final text):
        if (_parts.lastOrNull case GaiaTextPart(text: final sofar)) {
          _parts.last = GaiaTextPart(sofar + text);
        } else {
          _parts.add(GaiaTextPart(text));
        }
      case GaiaToolUse(:final name):
        if (_parts.lastOrNull case GaiaActivityPart(:final tools)) {
          _parts.last = GaiaActivityPart([...tools, name]);
        } else {
          _parts.add(GaiaActivityPart([name]));
        }
    }
    return true;
  }

  /// [parts] without text blocks that ended up empty.
  List<GaiaPart> get finished => [
    for (final part in _parts)
      if (part is! GaiaTextPart || part.text.isNotEmpty) part,
  ];
}
