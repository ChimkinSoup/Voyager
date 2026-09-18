# LeetCode Type Highlighting — HLD

Color **PascalCase type names** (plus single-letter generics) in LeetCode code for **Java, C#, TypeScript, and C++** using a lightweight heuristic on top of the existing `highlight` grammars — not a language server.

Related: `lib/features/leetcode/leetcode_code_field.dart` (`leetCodeHighlightMode`, `leetCodeSyntaxStyles`), `lib/features/leetcode/leetcode_inline_code.dart`, `lib/features/leetcode/leetcode_scratch_session.dart`, package `highlight` (`languages/{java,cs,typescript,cpp}.dart`), Atom One themes via `flutter_highlight`.

Status: **design** (not implemented). Product decisions in §3 are **locked**.

---

## 1. Goals

- Make **class / type names** visually distinct from ordinary identifiers across the four languages above: `List`, `HashMap`, `Solution`, `ListNode`, `vector`’s template args like `TreeNode`, TS interfaces used as types, C# `List<int>`, etc.
- Color **single-letter generics** (`T`, `E`, `K`, `V`, …).
- Leave **all-caps acronyms** plain (`UUID`, `URL`, `HTTP`, `OK`, `MAX`).
- Keep the current stack: regex `highlight` grammar + Atom One palette + `flutter_code_editor` / inline tokenizer.
- One shared injector wired through `leetCodeHighlightMode` so every surface updates together.
- Stay conservative: do not recolor strings, comments, keywords, numbers, or annotations.

### Non-goals (v1)

- True semantic highlighting (resolve imports, locals vs types, LSP).
- Python / Go / JavaScript / Rust (no PascalCase-type convention as strong, or out of this pass).
- A maintained stdlib symbol allowlist as the primary mechanism.
- Theme redesign beyond using Atom One’s existing `type` token class.
- Changing stored code text, language keys, or starters.

---

## 2. Problem (current behavior)

Voyager maps language keys → stock `highlight` modes and paints with Atom One (`leetcode_code_field.dart`). Those grammars typically special-case:

| Construct | Token class | Atom One color today |
| --- | --- | --- |
| `class` / `interface` / `struct` **declaration name** | `title` (when present) | blue |
| Method / function name in a signature | `title` | blue |
| Keywords, strings, numbers, comments, attributes | existing | as today |
| Type **usages** in signatures, generics, `new` / constructors | often none | default foreground |

So most of what readers expect to look like “a type” is plain text. A theme-only fix cannot help: those spans are never tagged.

Java prototype dump of stock grammar (abbreviated):

```text
[title] Solution          // declaration only
[function] List<Integer>  // unstyled inside the function mode
[params] (HashMap<…> m)   // unstyled
[-] ArrayList             // after `new`, still plain
```

The same nesting problem (`function` / `params` swallowing unstyled type text) appears in the C#, TypeScript, and C++ grammars Voyager already registers.

---

## 3. Product decisions (locked)

| Decision | Choice |
| --- | --- |
| **Mechanism** | Heuristic identifier → token class `type` |
| **Languages (v1)** | **Java, C#, TypeScript, C++** |
| **Surfaces** | All consumers of `leetCodeHighlightMode` for those keys |
| **Color** | Atom One’s existing **`type`** style (amber) — no custom hex |
| **Declarations** | Same amber as usages — declaration names become `type`, not `title` |
| **Single-letter generics** | **Color** (`T`, `E`, …) |
| **All-caps acronyms** | **Do not color** (`UUID`, `URL`, `HTTP`, …) |
| **`SCREAMING_SNAKE` constants** | **Leave plain** |
| **Comments / strings** | **Never** take the type color |

---

## 4. Heuristic

### 4.1 Match rule

Treat an identifier as a type when it matches:

```text
\b(?:[A-Z]|[A-Z][a-zA-Z0-9]*[a-z][a-zA-Z0-9]*)\b
```

Meaning:

1. **Single uppercase letter** — generics / type params (`T`, `E`, `K`, `V`).
2. **Or** a capital-led identifier that contains **at least one lowercase** letter — true PascalCase / mixed names (`List`, `HashMap`, `Solution`, `ListNode`, `IList`).

Explicitly **excluded**:

- All-caps acronyms (`UUID`, `URL`, `HTTP`, `OK`, `MAX`) — no lowercase letter, longer than one character.
- `SCREAMING_SNAKE` (`MAX_VALUE`) — `_` is a word character, so a partial `MAX` match fails the trailing `\b`; the full token has no lowercase-required alternative that fits.

Verified against: `T`/`List`/`HashMap`/`Solution`/`IList` → match; `UUID`/`URL`/`HTTP`/`MAX`/`MAX_VALUE`/`OK`/`foo`/`myList` → no match.

### 4.2 What it will color (examples)

| Snippet | Expected |
| --- | --- |
| `List<Integer>` | `List`, `Integer` → `type` |
| `new ArrayList<>()` | `ArrayList` → `type` |
| `class Solution` | `Solution` → `type` (amber, not blue `title`) |
| `HashMap<String, UUID>` | `HashMap`, `String` → `type`; **`UUID` plain** |
| `void foo(T x)` | `T` → `type` |
| `List<T>` / `Dictionary<TKey, TValue>` | `List`/`Dictionary`/`T`/`TKey`/`TValue` → `type` |
| `int MAX_VALUE = 1` | `MAX_VALUE` plain |
| `// see ListNode` | entire line stays `comment` |
| `"HashMap"` | stays `string` |
| `foo` / `myList` | plain (leading lower case) |

### 4.3 Known false positives / negatives

**False positives (acceptable in v1):**

- Rare PascalCase **method** names (`public void DoThing()`).
- Single-letter capitals that are not type params (uncommon as values in these languages’ LeetCode style).

**False negatives (accepted):**

- All-caps type names (`UUID`, `URL`) — **by product choice**.
- Types that violate PascalCase (`listNode` as a type name).
- Package / namespace / module segments in lowercase.
- Primitive keywords (`int`, `bool`, `void`) — already `keyword`.
- C++ STL names that are fully lowercase (`vector`, `string`, `map`) — stay plain; **template type args** that are PascalCase (`vector<TreeNode>`) still get `TreeNode` colored.

This is highlighter cosmetics for a LeetCode pad, not a compiler.

---

## 5. Architecture

### 5.1 Why not a top-level-only rule?

Prepending one `type` mode on the root `contains` list only catches identifiers the root lexer still sees. Stock grammars wrap signatures in `function` / `params` (and similar) and leave return / parameter types as plain text **inside** those modes. Java prototype: only `ArrayList` after `new` lit up; `List` / `HashMap` did not.

### 5.2 Approach: shared selective deep injection

Introduce a small shared helper that wraps any stock `Mode`:

1. Leaf rule:  
   `Mode(className: 'type', begin: r'\b(?:[A-Z]|[A-Z][a-zA-Z0-9]*[a-z][a-zA-Z0-9]*)\b', relevance: 0)`.
2. Recursively copy the mode tree (preserve `ref` nodes unresolved; copy `starts` / `variants` / `contains`).
3. **Prepend** that rule only onto modes whose `className` is an **identifier host**:
   - `null` (root)
   - `function`
   - `params`
   - `class`
4. Do **not** prepend into `comment`, `string`, `number`, `meta`, `doctag`, `meta-string`, `subst`, title-only leaves, etc. Still recurse so nested hosts receive the rule.

Stock grammars Voyager uses already expose these host class names:

| Language | Key in `leetCodeHighlightMode` | Stock mode | Hosts present |
| --- | --- | --- | --- |
| Java | `java` | `lang_java.java` | root, `function`, `params`, `class` |
| C# | `csharp` | `lang_cs.cs` | root, `function`, `params`, (+ class/title patterns) |
| TypeScript | `typescript` | `lang_typescript.typescript` | root, `function`, `params` |
| C++ | `cpp` | `lang_cpp.cpp` | root, `function`, `params`, `class` |

If implementation discovers an extra host needed for a language (e.g. a mode with `className: null` nested oddly, or TS `interface` shapes), extend the host set in one place — do not fork four copies of the injector.

Java prototype with this injector (abbreviated; acronym rule not yet applied in that run):

```text
[type] Solution
[type] List / Integer / HashMap / String / T / ArrayList
[comment] // TODO List should stay comment
[string] "HashMap"
[-] MAX_VALUE
```

Implementation must re-verify with the **locked** regex so `UUID` stays plain.

### 5.3 Where the code lives

| Piece | Location |
| --- | --- |
| Shared injector | e.g. `lib/features/leetcode/leetcode_type_highlight.dart` — `Mode injectPascalCaseTypes(Mode stock)` |
| Wiring | `leetCodeHighlightMode`: wrap `java`, `csharp`, `typescript`, `cpp`; leave `javascript`, `go`, `rust`, Python fallback unchanged |
| Styles | No change — Atom One already defines `type` |
| Inline / scratch / track / detail | Automatic via `leetCodeHighlightMode` |

Do **not** fork package `highlight` language files. Wrapping survives upgrades as long as stock modes remain walkable trees (they are today).

### 5.4 Declaration names

Prepending `type` before `title` / `UNDERSCORE_TITLE_MODE` inside `class` (and similar) hosts means `Solution` in `class Solution` becomes **`type`**. That is the locked look: declarations and usages share amber.

### 5.5 Caching

`leetcode_inline_code.dart` caches token class names per `language + source`. Bump a short cache-key version suffix (e.g. `types-v1`) when landing so hot reload during development does not serve pre-heuristic tokens.

---

## 6. Testing

Unit-level: register each wrapped mode, parse fixtures, assert leaf class names.

**Per language (java / csharp / typescript / cpp):**

1. Classic LeetCode shape with `Solution` + a PascalCase node type in a signature.
2. Generics including a single-letter param (`T` → `type`).
3. Acronym negative: `UUID` / `URL` (or language-typical all-caps) stays **not** `type`.
4. Constant negative: `MAX_VALUE` (or `constexpr` / `const` equivalent) plain.
5. Comment / string negatives: PascalCase inside `//` or `"…"` stays comment/string.
6. Method name with leading lowercase is not `type`.
7. Round-trip: concatenated leaf text equals source.

Optional: one manual glance per language in the Track modal.

---

## 7. Rollout

1. Land injector + `leetCodeHighlightMode` wiring for the four languages + tests.
2. Manually glance each language in Track / Detail / scratch / inline chip.
3. No migration, settings flag, or sync impact.
4. `graphify update .` after the Dart change.

---

## 8. Open questions

**None** — §3 decisions are locked. Implementation may still adjust the identifier-host set if a grammar edge case appears; that is an engineering detail, not a product reopen.

---

## 9. Alternatives considered

| Option | Why not (for v1) |
| --- | --- |
| Theme-only (`class` style) | Usages are not tagged `class`; Atom One lacks `class` anyway |
| Stdlib `built_in` allowlist alone | Misses `Solution` / `ListNode` / `TreeNode` |
| Color all-caps acronyms | Rejected — product choice |
| Java-only first | Rejected — ship four languages together |
| Keep declaration `title` (blue) | Rejected — unified amber |
| Post-process token stream only in inline code | Would not affect `CodeField` / `CodeController` without duplicating logic |
| Semantic / analyzer-based highlighting | Far beyond the LeetCode pad’s highlighter budget |
| Upstream PR to `highlight` grammars | Slower; Voyager-side wrap is enough |
