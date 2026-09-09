import 'package:voyager/domain/models/leetcode_models.dart';
import 'package:voyager/features/leetcode/leetcode_comment_stripper.dart';

/// The bare skeleton a scratch pad opens on, derived from what the problem's
/// first saved solution declares.
///
/// The point is to start the user where LeetCode itself would: with the class
/// and method signature filled in and the body empty. It reads the saved
/// solution only for its *shape* — every statement inside a body is dropped, so
/// the answer never leaks into the pad.
///
/// Best-effort by nature. A heavily refactored solution can produce a stub that
/// wouldn't compile; the pad is free text, so the user edits it. Anything the
/// extractor can't make sense of falls back to [leetCodeStarterFallback].
String deriveLeetCodeStarter(LeetCodeProblem problem, String language) {
  final source = _firstSolution(problem);
  // Only a solution written in the pad's own language has a shape worth
  // reading. Extracting a Python `def` into a Java pad produces a line that is
  // neither language, so a mismatch takes the fallback.
  if (source == null || source.codeLanguage != language) {
    return leetCodeStarterFallback(language);
  }
  return deriveLeetCodeStarterFromCode(source.code, language) ??
      leetCodeStarterFallback(language);
}

/// The problem's first non-empty solution, the same rule the deck's **Copy
/// code** menu item uses.
LeetCodeSolution? _firstSolution(LeetCodeProblem problem) {
  for (final solution in problem.solutions) {
    if (solution.code.trim().isNotEmpty) return solution;
  }
  return null;
}

/// The language of the problem's first solution, which is what a pad opens in
/// before the user has picked a language of their own this session.
String? leetCodeFirstSolutionLanguage(LeetCodeProblem problem) =>
    _firstSolution(problem)?.codeLanguage;

/// Signatures only, bodies emptied. Null when [code] holds nothing this
/// extractor recognises as a declaration — the caller then uses the fallback
/// rather than showing a stub built out of half-understood lines.
///
/// Only Python and the brace languages are extracted. Go and Rust declare
/// themselves in shapes (receivers, `impl` blocks, lifetimes) where a
/// line-oriented heuristic reliably produces a stub that doesn't parse, and a
/// wrong stub is worse than a clean default — they take the fallback.
String? deriveLeetCodeStarterFromCode(String code, String language) {
  final cleaned = stripLeetCodeTrailingBlankLine(
    stripLeetCodeLineComments(code, language),
  );
  if (cleaned.trim().isEmpty) return null;
  final lines = cleaned.split('\n');
  return switch (language) {
    'python' => _derivePython(lines),
    'java' || 'cpp' || 'csharp' || 'javascript' || 'typescript' => _deriveBraces(
      lines,
    ),
    _ => null,
  };
}

int _indentOf(String line) {
  var i = 0;
  while (i < line.length && (line[i] == ' ' || line[i] == '\t')) {
    i++;
  }
  return i;
}

final _pythonClass = RegExp(r'^\s*class\s+\w');
final _pythonDef = RegExp(r'^\s*(async\s+)?def\s+\w');

/// Python's blocks are its indentation, so a body is every line indented past
/// the `def` that opened it — including the blank lines inside it, which is why
/// a blank is only treated as the end of a body once a *shallower* line follows.
String? _derivePython(List<String> lines) {
  final out = <String>[];
  var keptDef = false;
  var i = 0;

  while (i < lines.length) {
    final line = lines[i];
    if (_pythonClass.hasMatch(line)) {
      out.add(line.trimRight());
      i++;
      continue;
    }
    if (!_pythonDef.hasMatch(line)) {
      i++;
      continue;
    }

    final indent = _indentOf(line);
    // A signature can run over several lines; it ends at the `:` that closes
    // it, which is the first `:` reached with the parens balanced.
    var depth = 0;
    while (i < lines.length) {
      final sig = lines[i];
      out.add(sig.trimRight());
      depth += _parenDelta(sig);
      i++;
      if (depth <= 0 && sig.trimRight().endsWith(':')) break;
    }
    out.add('${' ' * (indent + 4)}pass');
    keptDef = true;

    // Everything indented past the `def` is its body.
    while (i < lines.length) {
      final body = lines[i];
      if (body.trim().isEmpty) {
        // Blank lines belong to the body only if the body continues under
        // them; a blank before a shallower line ends it.
        var j = i;
        while (j < lines.length && lines[j].trim().isEmpty) {
          j++;
        }
        if (j >= lines.length || _indentOf(lines[j]) <= indent) break;
        i = j;
        continue;
      }
      if (_indentOf(body) <= indent) break;
      i++;
    }
  }

  return keptDef ? out.join('\n') : null;
}

int _parenDelta(String line) {
  var delta = 0;
  for (final ch in line.split('')) {
    if (ch == '(' || ch == '[' || ch == '{') delta++;
    if (ch == ')' || ch == ']' || ch == '}') delta--;
  }
  return delta;
}

int _braceDelta(String line) {
  var delta = 0;
  for (final ch in line.split('')) {
    if (ch == '{') delta++;
    if (ch == '}') delta--;
  }
  return delta;
}

/// Whether the block this line opens is a *container* (class, struct,
/// namespace) rather than a function. A container keeps its contents so the
/// methods inside it can be extracted in turn; a function has its body dropped.
///
/// The tell is parentheses before the brace: a declaration that takes an
/// argument list is something callable.
/// `public:` and friends — C++/C# section markers that carry no code of their
/// own but change what the declarations under them mean.
bool _isAccessSpecifier(String line) {
  final trimmed = line.trim();
  return trimmed.endsWith(':') &&
      !trimmed.contains('(') &&
      !trimmed.contains('{');
}

bool _opensContainer(String line) {
  final brace = line.lastIndexOf('{');
  if (brace < 0) return false;
  return !line.substring(0, brace).contains('(');
}

/// Brace languages: a body is the block a callable declaration opens. Classified
/// per line rather than by nesting depth, so a method is stubbed wherever it
/// sits and the container lines around it come through exactly as written.
String? _deriveBraces(List<String> lines) {
  final out = <String>[];
  var keptFunction = false;
  var i = 0;

  while (i < lines.length) {
    final line = lines[i];
    if (line.trim().isEmpty) {
      i++;
      continue;
    }

    // Container headers, stray closers, and access specifiers are structure
    // rather than a body, so they come through as written. Everything else
    // with no argument list is a loose statement, and is dropped.
    if (_opensContainer(line) ||
        _braceDelta(line) < 0 ||
        _isAccessSpecifier(line)) {
      out.add(line.trimRight());
      i++;
      continue;
    }
    if (!line.contains('(')) {
      i++;
      continue;
    }

    // A callable declaration. Its signature may run over several lines, ending
    // at the `{` that opens the body or the `;` that says there isn't one.
    final indent = ' ' * _indentOf(line);
    var opened = false;
    while (i < lines.length) {
      final sig = lines[i];
      out.add(sig.trimRight());
      i++;
      if (sig.contains('{')) {
        opened = true;
        break;
      }
      if (sig.trimRight().endsWith(';')) break;
    }
    keptFunction = true;
    if (!opened) continue;

    // Skip the body, then close the block ourselves at the signature's indent.
    var bodyDepth = 1;
    while (i < lines.length && bodyDepth > 0) {
      bodyDepth += _braceDelta(lines[i]);
      i++;
    }
    out.add('$indent}');
  }

  return keptFunction ? out.join('\n') : null;
}

/// The minimal skeleton for [language], used when a problem has no saved
/// solution to derive from — or when the one it has doesn't read as a
/// declaration.
String leetCodeStarterFallback(String language) => switch (language) {
  'java' => 'class Solution {\n    \n}',
  'cpp' => 'class Solution {\npublic:\n    \n};',
  'csharp' => 'public class Solution {\n    \n}',
  'javascript' => 'var solve = function() {\n    \n};',
  'typescript' => 'function solve(): void {\n    \n}',
  'go' => 'func solve() {\n\t\n}',
  'rust' => 'impl Solution {\n    \n}',
  _ => 'class Solution:\n    def solve(self):\n        pass',
};
