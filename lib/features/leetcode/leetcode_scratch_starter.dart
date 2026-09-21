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
  return deriveLeetCodeStarterFromCode(
        source.code,
        language,
        pythonEntryNames: _pythonEntryNames(problem),
      ) ??
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
String? deriveLeetCodeStarterFromCode(
  String code,
  String language, {
  Set<String> pythonEntryNames = const {},
}) {
  final cleaned = stripLeetCodeTrailingBlankLine(
    stripLeetCodeLineComments(
      stripLeetCodeBlockComments(code, language),
      language,
    ),
  );
  if (cleaned.trim().isEmpty) return null;
  final lines = cleaned.split('\n');
  return switch (language) {
    'python' => _derivePython(lines, pythonEntryNames),
    'java' ||
    'cpp' ||
    'csharp' ||
    'javascript' ||
    'typescript' => _deriveBraces(lines, language),
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
final _pythonDef = RegExp(r'^\s*(?:async\s+)?def\s+(\w+)');

/// The method names the pad expects the user to write for [problem], derived
/// from its LeetCode slug: "Two Sum" gives `twoSum` and `two_sum`.
///
/// Only Python needs these — it has no visibility keyword to tell a helper from
/// the entry method, so the problem's own name is the next best signal.
Set<String> _pythonEntryNames(LeetCodeProblem problem) {
  final words = leetCodeIdentityKey(
    problem,
  ).split('-').where((word) => word.isNotEmpty).toList();
  if (words.isEmpty) return const {};
  final camel = words.first + words.skip(1).map(_capitalize).join();
  return {camel, words.join('_')};
}

String _capitalize(String word) => word[0].toUpperCase() + word.substring(1);

/// Whether a `def` inside a class is the problem's entry method rather than a
/// helper.
///
/// `__init__` is always kept — design problems are constructed before they are
/// used. Past that: when some method in the class carries the problem's own
/// name, only the named ones are the entry shape; when none does (a renamed
/// solution, or a title that never matches), fall back to Python's own
/// convention that a leading underscore means private.
bool _isPythonEntryShaped(
  String name,
  Set<String> entryNames,
  bool matchedByName,
) {
  if (name == '__init__') return true;
  if (matchedByName) return entryNames.contains(name);
  return !name.startsWith('_');
}

/// Skip a nested `class` and every line indented past it. Returns the index of
/// the first line at or shallower than [classIndent] (or past the end).
int _skipPythonNestedClass(List<String> lines, int start, int classIndent) {
  var i = start + 1;
  while (i < lines.length) {
    final body = lines[i];
    if (body.trim().isEmpty) {
      i++;
      continue;
    }
    if (_indentOf(body) <= classIndent) break;
    i++;
  }
  return i;
}

/// Python's blocks are its indentation, so a body is every line indented past
/// the `def` that opened it — including the blank lines inside it, which is why
/// a blank is only treated as the end of a body once a *shallower* line follows.
///
/// Nested classes (any `class` indented under another) are implementation
/// helpers, not part of the LeetCode shape, so they are dropped entirely. So are
/// helper methods on the class itself — see [_isPythonEntryShaped]. A `def` at
/// module scope is kept whatever it is called: without a class there is no
/// entry shape to tell it apart from.
String? _derivePython(List<String> lines, Set<String> entryNames) {
  final out = <String>[];
  var keptDef = false;
  var i = 0;
  // Whether any method in a class carries the problem's name, which decides
  // between the two filters in [_isPythonEntryShaped]. Read up front because a
  // helper can sit above the entry method.
  final matchedByName = lines.any((line) {
    final match = _pythonDef.firstMatch(line);
    return match != null &&
        _indentOf(line) > 0 &&
        entryNames.contains(match.group(1));
  });

  while (i < lines.length) {
    final line = lines[i];
    if (_pythonClass.hasMatch(line)) {
      final indent = _indentOf(line);
      // Indented `class` means nested under an outer class — skip it.
      if (indent > 0) {
        i = _skipPythonNestedClass(lines, i, indent);
        continue;
      }
      out.add(line.trimRight());
      i++;
      continue;
    }
    final def = _pythonDef.firstMatch(line);
    if (def == null) {
      i++;
      continue;
    }

    final indent = _indentOf(line);
    final keep =
        indent == 0 ||
        _isPythonEntryShaped(def.group(1)!, entryNames, matchedByName);
    // A signature can run over several lines; it ends at the `:` that closes
    // it, which is the first `:` reached with the parens balanced.
    var depth = 0;
    while (i < lines.length) {
      final sig = lines[i];
      if (keep) out.add(sig.trimRight());
      depth += _parenDelta(sig);
      i++;
      if (depth <= 0 && sig.trimRight().endsWith(':')) break;
    }
    if (keep) {
      out.add('${' ' * (indent + 4)}pass');
      keptDef = true;
    }

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

/// Languages that say who a member is for. Java and C# mark each member; C++
/// marks a section and every member under it inherits that. JavaScript and
/// TypeScript declare class methods with no visibility at all, so nothing here
/// applies to them and every callable they declare is kept.
const _visibilityLanguages = {'java', 'cpp', 'csharp'};

final _nonPublicModifier = RegExp(r'\b(private|protected)\b');
final _publicSection = RegExp(r'^\s*public\s*:');
final _nonPublicSection = RegExp(r'^\s*(private|protected)\s*:');
final _declaresClass = RegExp(r'\bclass\b');

/// Whether a line is a field carrying an initialiser —
/// `Map<String, List<Data>> m = new HashMap<>();`. The parens in
/// `new HashMap<>()` would otherwise read as a parameter list and the line
/// would be emitted as a signature, handing the user the data structure the
/// saved solution chose. The tell is an `=` before the first paren: a
/// signature has none.
///
/// Only the visibility languages ask. JavaScript spells a free function
/// `var twoSum = function(nums, target) {` — the LeetCode shape itself — so
/// there the `=` means nothing.
bool _isInitialisedField(String line, String language) {
  if (!_visibilityLanguages.contains(language)) return false;
  final paren = line.indexOf('(');
  return paren > 0 && line.substring(0, paren).contains('=');
}

/// Whether a callable declaration is part of the shape the user is meant to
/// fill in, rather than a helper the saved solution happened to need.
///
/// Public is the whole test. Design problems (Min Stack, LRU Cache) expose
/// several public methods and all of them are the entry shape, so this never
/// reduces a class to one signature — which also means a helper the user marked
/// `public` stays, an accepted miss.
///
/// [sectionIsPublic] carries the C++ `public:` / `private:` section the
/// declaration sits under. A free function — anything outside a class — is kept
/// whatever it is called.
bool _isEntryShaped(
  String line,
  String language,
  bool insideContainer,
  bool sectionIsPublic,
) {
  if (!insideContainer || !_visibilityLanguages.contains(language)) return true;
  final paren = line.indexOf('(');
  final head = paren < 0 ? line : line.substring(0, paren);
  if (_nonPublicModifier.hasMatch(head)) return false;
  // C++ marks visibility by section, not per member, so an unmarked C++ method
  // takes whichever section it is under — private until a `class` says
  // otherwise, public in a `struct`.
  return language != 'cpp' || sectionIsPublic;
}

/// Whether [trimmed] is only closing braces (and an optional trailing `;`),
/// e.g. `}`, `};`, `}}`. Used so an indent-based early exit does not treat the
/// nested type's own closer as a sibling member of the outer class.
bool _isOnlyClosers(String trimmed) {
  if (trimmed.isEmpty) return false;
  var end = trimmed.length;
  if (trimmed[end - 1] == ';') end--;
  if (end == 0) return false;
  for (var i = 0; i < end; i++) {
    if (trimmed[i] != '}') return false;
  }
  return true;
}

/// Advance past the nested container that [start] opens. Returns the index of
/// the first line after that block (or [lines.length] if it never closes).
///
/// Prefers brace depth, but also stops at a sibling declaration at or shallower
/// than the nested type's indent while still inside the block. That recovers
/// when the saved solution has unbalanced braces inside the nested type (a
/// missing `}` would otherwise swallow the outer class's methods).
int _skipNestedContainer(List<String> lines, int start) {
  final openIndent = _indentOf(lines[start]);
  var depth = 0;
  var i = start;
  while (i < lines.length) {
    final line = lines[i];
    final trimmed = line.trim();
    if (i > start &&
        depth > 0 &&
        trimmed.isNotEmpty &&
        _indentOf(line) <= openIndent &&
        !_isOnlyClosers(trimmed)) {
      break;
    }
    depth += _braceDelta(line);
    i++;
    if (depth <= 0) break;
  }
  return i;
}

/// Brace languages: a body is the block a callable declaration opens. Classified
/// per line rather than by nesting depth, so a method is stubbed wherever it
/// sits and the container lines around it come through exactly as written.
///
/// Nested classes/structs (a container opened while already inside one) are
/// implementation helpers — not the LeetCode entry shape — so the whole nested
/// block is dropped. So are non-public methods on the outer class, which is the
/// other half of the same idea; see [_isEntryShaped].
String? _deriveBraces(List<String> lines, String language) {
  final out = <String>[];
  var keptFunction = false;
  var i = 0;
  // How many kept class/struct/namespace containers currently enclose us.
  // Nested containers are skipped, not counted.
  var containerDepth = 0;
  // The C++ access section the current line sits in. Set when a container
  // opens — `class` members are private until a section says otherwise, a
  // `struct`'s are public — and moved by each specifier after that.
  var sectionIsPublic = true;

  while (i < lines.length) {
    final line = lines[i];
    if (line.trim().isEmpty) {
      i++;
      continue;
    }

    if (_opensContainer(line)) {
      // Nested helper type inside an outer class — drop the whole block.
      if (containerDepth > 0) {
        i = _skipNestedContainer(lines, i);
        continue;
      }
      out.add(line.trimRight());
      containerDepth += _braceDelta(line);
      if (containerDepth < 0) containerDepth = 0;
      sectionIsPublic = !_declaresClass.hasMatch(line);
      i++;
      continue;
    }

    // Stray closers and access specifiers are structure rather than a body,
    // so they come through as written. Everything else with no argument list
    // — and every field that only looks like it has one — is a loose
    // statement, and is dropped.
    final delta = _braceDelta(line);
    if (delta < 0 || _isAccessSpecifier(line)) {
      out.add(line.trimRight());
      if (_publicSection.hasMatch(line)) sectionIsPublic = true;
      if (_nonPublicSection.hasMatch(line)) sectionIsPublic = false;
      if (delta < 0) {
        containerDepth += delta;
        if (containerDepth < 0) containerDepth = 0;
      }
      i++;
      continue;
    }
    if (!line.contains('(') || _isInitialisedField(line, language)) {
      i++;
      continue;
    }

    // A callable declaration. Its signature may run over several lines, ending
    // at the `{` that opens the body or the `;` that says there isn't one.
    final indent = ' ' * _indentOf(line);
    final keep = _isEntryShaped(
      line,
      language,
      containerDepth > 0,
      sectionIsPublic,
    );
    var opened = false;
    // How deep the signature's own line leaves us. Usually 1 — the `{` that
    // opens the body — but a one-line member (`ListNode() : val(0) {}`) opens
    // and closes on the same line and leaves 0.
    var bodyDepth = 0;
    while (i < lines.length) {
      final sig = lines[i];
      if (keep) out.add(sig.trimRight());
      i++;
      if (sig.contains('{')) {
        opened = true;
        bodyDepth = _braceDelta(sig);
        break;
      }
      if (sig.trimRight().endsWith(';')) break;
    }
    if (keep) keptFunction = true;
    if (!opened) continue;
    // Already closed on its own line: there is no body to skip, and adding a
    // closer would eat the *enclosing* container's `}` instead — which would
    // leave [containerDepth] stuck and make the real Solution class read as a
    // nested helper.
    if (bodyDepth <= 0) continue;

    // Skip the body, then close the block ourselves at the signature's indent.
    // Method bodies do not affect [containerDepth] — their braces never reach
    // the outer loop.
    while (i < lines.length && bodyDepth > 0) {
      bodyDepth += _braceDelta(lines[i]);
      i++;
    }
    if (keep) out.add('$indent}');
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
