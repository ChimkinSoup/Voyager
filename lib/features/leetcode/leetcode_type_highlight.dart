import 'package:highlight/highlight_core.dart' show Mode;

/// A single capital (a generic like `T`), or a capital-led identifier with at
/// least one lowercase letter (`List`, `HashMap`, `TKey`). All-caps acronyms
/// (`UUID`) and `SCREAMING_SNAKE` constants fail both alternatives.
const _typePattern = r'\b(?:[A-Z]|[A-Z][a-zA-Z0-9]*[a-z][a-zA-Z0-9]*)\b';

/// Inside a signature, a name followed by `(` is the method (or constructor)
/// being declared — C# methods are PascalCase — so it keeps its title.
const _signatureTypePattern = '$_typePattern(?!\\s*\\()';

/// Classed modes whose plain text holds identifiers: the signature wrappers
/// the stock grammars leave return / parameter types untagged in.
const _hostClasses = {'function', 'params', 'class'};

/// C# and TypeScript declare classes / interfaces in unclassed modes that
/// carry the keyword as `beginKeywords`.
final _declarationKeywords = RegExp(r'\b(?:class|interface)\b');

/// `~contains~0~contains~4~variants~0` → `~contains~0~contains~4`.
final _variantRefKey = RegExp(r'^(.*)~variants~\d+$');

/// A copy of [stock] that tags PascalCase identifiers (and single-letter
/// generics) as `type` wherever the grammar would otherwise leave them plain.
///
/// The rule is prepended to identifier hosts — [_hostClasses], plus unclassed
/// modes outside any classed one (the root and the expression wrappers C++
/// nests code in) — so strings, comments and the like never take the colour.
/// Inside a `class` host it outranks the title rule, so declaration names
/// turn amber too; method names keep theirs. [stock] itself is left untouched.
Mode injectPascalCaseTypes(Mode stock) {
  final copies = Map<Mode, Mode>.identity();

  // A variant takes its parent's class name unless it sets its own, so an
  // unclassed variant of a `string` is still a string. [classed] marks a mode
  // nested in a classed one, where an unclassed mode is a helper (C#'s
  // method-name wrapper) rather than free code.
  Mode? copy(Mode? mode, {String? inheritedClass, bool classed = false}) {
    if (mode == null) return null;
    final existing = copies[mode];
    if (existing != null) return existing;

    final result = Mode(
      ref: mode.ref,
      aliases: mode.aliases,
      keywords: mode.keywords,
      illegal: mode.illegal,
      case_insensitive: mode.case_insensitive,
      className: mode.className,
      begin: mode.begin,
      beginKeywords: mode.beginKeywords,
      end: mode.end,
      lexemes: mode.lexemes,
      endSameAsBegin: mode.endSameAsBegin,
      endsParent: mode.endsParent,
      endsWithParent: mode.endsWithParent,
      relevance: mode.relevance,
      subLanguage: mode.subLanguage,
      excludeBegin: mode.excludeBegin,
      excludeEnd: mode.excludeEnd,
      skip: mode.skip,
      returnBegin: mode.returnBegin,
      returnEnd: mode.returnEnd,
      self: mode.self,
      disableAutodetect: mode.disableAutodetect,
    );
    copies[mode] = result;

    final className = mode.className ?? inheritedClass;
    final declaration =
        _hostClasses.contains(className) ||
        (className == null &&
            _declarationKeywords.hasMatch(mode.beginKeywords ?? ''));
    // Declaration hosts get a list even when they had none (TypeScript's
    // `interface`); an unclassed leaf keeps its own shape.
    final contains =
        mode.contains ??
        (declaration && mode.variants == null && inheritedClass == null
            ? const <Mode?>[]
            : null);
    if (contains != null) {
      final signature = className == 'function' || className == 'params';
      result.contains = [
        if (declaration || (className == null && !classed && mode.ref == null))
          Mode(
            className: 'type',
            begin: signature ? _signatureTypePattern : _typePattern,
            relevance: 0,
          ),
        for (final child in contains)
          copy(child, classed: classed || className != null),
      ];
    }
    result.variants = mode.variants
        ?.map(
          (variant) =>
              copy(variant, inheritedClass: className, classed: classed),
        )
        .toList();
    result.starts = copy(mode.starts, classed: classed);
    // Grammars hoist shared modes into `refs`; a hoisted variant finds its
    // parent's class through its key. An unknown parent counts as non-host.
    result.refs = mode.refs?.map((key, value) {
      final parentKey = _variantRefKey.firstMatch(key)?[1];
      final parentClass = parentKey == null
          ? null
          : (mode.refs![parentKey]?.className ?? '');
      return MapEntry(key, copy(value, inheritedClass: parentClass)!);
    });
    return result;
  }

  return copy(stock)!;
}
