# Emphasis & Inline Formatting (HLD)

Lightweight inline formatting for Voyager prose: **bold**, *italic*, `__underline__`, and `==highlight==`, stored as plain-text markers in the document and rendered natively in every multiline editor and read surface. Delimiters follow Obsidian Live Preview semantics — hidden while reading/editing at a distance, revealed when the caret or selection touches the span.

This is a high-level design. It records product decisions and the intended architecture against the existing field stack (`VoyagerTextField`, `TagHighlightedTextField`, `LabeledTextField`), spellcheck/autocorrect (`AUTOCORRECT.md`), tag highlighting, inline code (`leetcode_inline_code.dart`), and study LaTeX (`StudyRichText`, `STUDY_IMAGES.md`). It is not an implementation checklist.

Status: **implemented** (2026-09-02). All eight phases of §13 are in: the
parser, span builder and editing controller; the three shared field widgets and
the raw-`TextField` prose bodies; every overlay layer laying out against the
field's own paragraph; spellcheck and autocorrect exclusions; the read
surfaces; and HTML smart paste. What remains is §16's open questions and the
manual QA §13 phase 8 asks for on a real machine.

Related: `lib/core/text/styled_runs.dart`, `lib/core/widgets/tag_highlighted_text_field.dart`, `lib/core/widgets/voyager_text_field.dart`, `lib/core/widgets/labeled_text_field.dart`, `lib/core/widgets/spell_check_squiggle_layer.dart`, `lib/core/spellcheck/`, `lib/features/leetcode/leetcode_inline_code.dart`, `lib/features/study/study_rich_text.dart`, `lib/core/widgets/search_highlight_text.dart`, `AUTOCORRECT.md`, `SNIPPET.md`, `VIM.md`.

---

## 1. Goals

- **Native everywhere:** formatted text looks correct while editing and in every read surface (journal list previews, search results, todo notes, study cards, LeetCode prose, notifications, rankings, jobs notes, dream journal, etc.).
- **Plain-text storage:** markers (`**`, `*`, `__`, `==`) are persisted in the document string. No schema migration; sync/CRDT continues to diff plain text.
- **Obsidian-style Live Preview editing:** paired delimiters are **hidden** when the caret and selection are outside the span; **revealed** when the caret is inside or any part of the span is selected.
- **Conservative exclusions:** no formatting inside LeetCode code fields, `` `inline code` ``, `$...$` LaTeX, snippet-editor fields, or dictionary word fields. Tags remain fully functional when wrapped in emphasis.
- **Spellcheck & autocorrect keep working** inside emphasized text; delimiter characters act as word/token boundaries.
- **No settings toggle** — always on in eligible fields.
- **Markers only** for input — no toolbar, no Ctrl+B/Ctrl+I in v1.

### Non-goals (v1)

- Block-level markdown (headings, block quotes, fenced code blocks).
- Links (`[text](url)`).
- Strikethrough (`~~text~~`).
- Regex / snippet-style triggers for formatting.
- Per-field opt-out beyond the explicit exclusion list.
- Rich clipboard round-trip (copy as HTML).
- Replacing or duplicating study LaTeX (`$...$`) or LeetCode syntax-highlighted code.

---

## 2. Syntax

| Style | Delimiters | Example stored text | Rendered (delimiters hidden) |
| --- | --- | --- | --- |
| Bold | `**` … `**` | `**important**` | **important** |
| Italic | `*` … `*` | `*emphasis*` | *emphasis* |
| Underline | `__` … `__` | `__key point__` | underlined |
| Highlight | `==` … `==` | `==remember==` | highlighted background |

### 2.1 Nesting

Nesting is allowed. Inner spans inherit outer styles where styles compose (e.g. bold + italic + highlight). Examples:

- `**bold *and italic* bold**`
- `***bold italic***` (equivalent to bold wrapping italic)
- `**bold ==highlighted==**`

### 2.2 Unclosed delimiters

Unclosed or mismatched delimiters are **literal text** — no partial styling. Examples:

- `**hello` → shows `**hello` with no bold until the closing `**` is typed.
- `*one **two*` → parses greedily left-to-right with standard precedence; invalid tails stay literal.

### 2.3 Parsing precedence

A single shared parser (`parseProseMarkup` or equivalent) tokenizes the document into **exclusion zones** first, then applies emphasis rules only in prose zones.

**Zone priority (outermost wins — no emphasis inside):**

1. `$...$` — study LaTeX (paired `$`, same rules as `StudyRichText` today).
2. `` `...` `` — inline code (paired backticks on the **same line**, same rules as `parseInlineCode` today).
3. `#tag` spans — tag body is opaque to *italic* parsing (see §4.3).

**Within prose zones, delimiter matching order:**

1. `**` (bold)
2. `__` (underline)
3. `==` (highlight)
4. `*` (italic) — evaluated last so `**` is never split into two italics.

**Flanking (resolved 2026-09-02).** A delimiter run only pairs when it sits
against text rather than space, simplified from CommonMark:

- an opener may not be *followed* by whitespace, and may not end the document;
- a closer may not be *preceded* by whitespace, and may not start it;
- `__` additionally has to sit at a word edge on its outer side.

That one rule settles most of §11 without special cases. `2 * 3` stays
arithmetic because the opener is followed by a space. `snake_case__names` and
`a__b__c` stay literal because `__` is inside a word — while `foo**bar**baz`
still bolds, since `*` has no such restriction. And §2.4's bullet rule falls out
for free: a line-start `* ` is followed by a space, so it can never open.

When a closer matches an opener, every delimiter opened *after* that opener is
dropped. This is what keeps the result a properly nested forest rather than a
pile of half-overlapping ranges — `*a ==b* c==` gives italic `a ==b` and a
literal tail, per §2.2's "invalid tails stay literal".

The parser produces a properly nested forest of `EmphasisSpan` records:
`{start, end, kind, delimiterLength}` on the **stored** string offsets. Spans
nest but never partially overlap.

### 2.4 List bullets vs italic

Voyager list editing (`list_text_editing.dart`) treats line-start `* ` (asterisk + space, after optional indent) as a **bullet marker**, not an italic opener.

| Text | Result |
| --- | --- |
| `* item one` | Bullet list line; `*` is literal marker |
| `not *italic*` | Italic on `italic` |
| `* item with *emphasis*` | Bullet line; mid-line `*emphasis*` is italic |

Rule: an opening `*` at position 0 or immediately after `(indent)(bullet prefix)` of a bullet line is never an italic opener. Only `*` pairs **mid-line** (or after bullet content) open italic.

---

## 3. Editing UX — Live Preview reveal

### 3.1 Hidden vs revealed

| Caret / selection state | Delimiter visibility | Text appearance |
| --- | --- | --- |
| Outside all emphasis spans | Hidden | Styled (bold / italic / underline / highlight) |
| Caret inside a span, or selection overlaps a span | Revealed for **every** emphasis span that contains the caret or overlaps the selection | Styled + visible delimiter glyphs |

**Reveal trigger:** caret anywhere inside the span **or** any part of the span is selected (including partial selection).

**Reveal scope:** all containing emphasis spans, innermost to outermost. In `**bold *italic* end**` with the caret in `italic`, reveal both `**…**` and `*…*`.

**Implementation sketch:** the field's `buildTextSpan` (or equivalent) receives `(text, selection, revealSpans)` and emits:

- styled runs for content between delimiters;
- delimiter glyphs in `style` (muted color, e.g. `onSurface` at 40% opacity) when `revealSpans` includes that span;
- no delimiter glyphs when hidden.

Delimiters always occupy space in the stored string; hiding is a **rendering**
choice only. Caret offsets remain stable against stored text.

**Hidden means zero-width, not absent (resolved 2026-09-02).**
`TextEditingController.buildTextSpan`'s contract is one paragraph character per
character of the stored value — Flutter's own overrides (obscured text, the
composing region) both preserve length, and `RenderEditable` maps stored offsets
straight onto the paragraph. Omitting the `**` glyphs would therefore land every
caret past them on the wrong letter: the offset desync §3.5 lists as a bug, not
a trade-off. So a hidden delimiter is emitted at `fontSize: 0` with
`letterSpacing: 0` (Voyager's body styles carry tracking, which would otherwise
leave a visible gap) and a transparent colour.

The consequence the §3.5 alternatives table raised is real and accepted: the
caret can rest at an offset with no visible glyph, and one arrow press moves
through each hidden character. That is unavoidable for any honest "hidden"
state, and matches §3.2's recommendation of single-character steps.

A line holding *only* hidden delimiters would collapse to zero height without a
strut. Both flavours in use protect it: `EditableText` falls back to
`StrutStyle.fromTextStyle(style, forceStrutHeight: true)` when a field passes no
strut, and `TagHighlightedTextField`'s explicit strut acts as a floor.

### 3.2 Caret navigation

- Arrow keys move through hidden delimiters as zero-width for movement purposes **or** as single-character steps — pick one and test heavily. **Recommendation:** single-character steps through stored offsets (simpler for Vim/sync); hidden delimiters are still reachable with one arrow press.
- Selecting across a hidden delimiter expands to include the delimiter offsets in the selection, which triggers reveal.

### 3.3 No auto-pairing

Typing `**` does not auto-insert a closing pair. User types both delimiters manually.

### 3.4 Visual styles

| Style | Rendering |
| --- | --- |
| **Bold** | `FontWeight.bold` on base field style |
| *Italic* | `FontStyle.italic` on base field style |
| Underline | A straight **black** horizontal line drawn beneath the text baseline (not wavy, not theme-colored). Use `TextDecoration.underline` with `decorationColor: Colors.black` and `TextDecorationStyle.solid`, or an equivalent custom paint if the squiggle layer needs to stay distinct. |
| Highlight | Background fill using the field's **accent color** (`accentColor` on the widget, falling back to `theme.colorScheme.primary`) at low opacity (~20–30% alpha) behind the glyphs, corners rounded 4px. |

Delimiter glyphs (when revealed) use muted body color (`onSurface` at ~40% opacity), not accent.

**Rounded highlight (resolved 2026-09-02).** `TextStyle.backgroundColor` only
ever fills a hard rect and exposes no radius, so the highlight's fill is not in
the paragraph at all. A highlighted run carries `kProseHighlightMark` — a
transparent sentinel colour — and the fill is painted separately:
`ProseHighlightLayer` beneath an editable field, laying out the same
metrics paragraph as every other layer (§8), and `ProseHighlightUnderlay`
beneath a read surface, which borrows the `RenderParagraph` the child already
laid out rather than measuring a second copy — the only way to place a fill on
the surfaces whose text is chopped up by `WidgetSpan` tag pills or `$…$` math.

The fill covers the content, never the delimiters, and is drawn as one `Path`
per surface: the colour is translucent, so separate rects would double-blend
into visible seams wherever two touched. A highlight that wraps gets one
rounded rect per line.

**Dark mode (resolved 2026-09-02, open question 2 closed):** black on light
surfaces as specified, `colorScheme.onSurface` in dark, where black against the
surface is all but invisible. This is the documented exception the v1 note asked
for rather than a silent switch.

### 3.5 Delimiter reveal reflow

When delimiters are **hidden**, the reader sees only the styled word — e.g. `important` rendered bold. When the caret enters that span, the stored text `**important**` becomes visible: four extra characters (`**` on each side) appear in the layout.

That almost always changes how the paragraph wraps.

#### Why it happens

Reflow is not a bug — it is a consequence of showing characters that were always in the document but omitted from layout. There is no way to reveal `**` honestly (so the user can edit or delete them) without those glyphs occupying horizontal space.

Example on a narrow line:

```
Hidden:  … the most important thing we …
Revealed: … the most **important** thing …
                      ^ line may break here instead of after "important"
```

Bold itself can also change wrap (wider glyphs), but that is **stable** — it applies whenever the span is rendered styled. Reveal reflow is the **extra** shift from delimiter glyphs appearing and disappearing as the caret moves.

#### When users will notice it

| Situation | Severity |
| --- | --- |
| Caret moves into a word mid-paragraph | Low — one line may gain/lose a word at the margin; text below usually unchanged |
| Formatted word sits near the right edge of a wrapped line | **High** — the line often re-breaks; content below can jump vertically |
| Nested spans (`**bold *x* **`) | Medium — multiple delimiter pairs appear at once; larger width swing |
| Long journal entry, caret far from viewport | None — off-screen reveal does not disturb what the user sees |
| Tag pill alignment | Medium — pill rects must recompute when bold + revealed delimiters change width (§8) |

#### What Obsidian does

Obsidian Live Preview uses the same trade-off: markers appear on cursor entry and the line layout adjusts. Users learn to expect a small jump when entering formatted text near a wrap boundary. Voyager should match that expectation rather than fight it.

#### Alternatives considered

| Approach | Why not (for v1) |
| --- | --- |
| **Zero-width delimiters** — render `**` in 0px width | Caret lands in invisible positions; double-tap confusion; inaccessible |
| **Overlay delimiters** — float markers above the line without affecting wrap | Misaligns with caret; breaks Vim offset semantics; tag/squiggle stacks already complex |
| **Reserve delimiter width always** — leave blank space where hidden markers would be | Defeats the purpose of hiding; prose looks gappy |
| **Reflow only on explicit "edit markup" mode** | Extra mode to learn; conflicts with "native everywhere" |

#### Decision: reflow is acceptable

**Yes — minor reflow when delimiters appear or disappear is acceptable and expected.**

Rationale:

1. **Correctness over stability** — showing real stored characters while editing markup is more important than keeping the paragraph pixel-stable.
2. **Caret-stable offsets** — stored string indices never change; only glyph layout shifts. Sync, undo, and Vim stay correct.
3. **Bounded impact** — reflow is local to the paragraph (Flutter line breaking does not reshuffle distant lines unless wrap count changes). Most caret moves do not cross a wrap boundary.
4. **Industry precedent** — Obsidian, Notion markdown mode, and similar editors accept this.

**Mitigations (implement, but do not eliminate reflow):**

- Recompute layout synchronously on reveal toggle so the jump is one frame, not a staggered repaint.
- Keep revealed delimiters in the **same font size** as body text (muted color only) — do not shrink them to reduce shift.
- Scroll caret into view after reveal (`bringCursorIntoView`) so a re-wrap does not leave the caret off-screen.
- Tag pill and squiggle layers must relayout in the same frame as the field (already required by §8).

**Not acceptable (treat as bugs):**

- Caret offset desync after reflow (typing inserts at wrong index).
- Horizontal scroll position jumping in a scrolled field with no caret involvement.
- Persistent layout oscillation (reveal/hide thrashing on a single caret position).

---

## 4. Exclusion rules

### 4.1 Field-level exclusions (no parser)

These fields store and display **plain text only** — no `buildTextSpan` formatting, no reveal logic:

| Field | Reason |
| --- | --- |
| `LeetCodeCodeField` | Syntax-highlighted code editor |
| Snippet editor (`snippet_editor.dart`) | Triggers/replacements are literal |
| Dictionary word fields (`dictionary_dialog.dart`) | Dictionary entries are literal |

All other multiline prose fields participate, including journal body, todo notes, search entry title/body, study card front/back, LeetCode **prose** fields (hints, notes — not the code box), notifications, rankings notes, jobs notes, dream journal, analytics notes, etc.

### 4.2 Inline code spans

Inside `` `inline code` `` (paired on same line, per `parseInlineCode`):

- No bold, italic, underline, or highlight.
- Delimiter backticks are literal.
- Existing syntax highlighting for LeetCode prose (`LeetCodeProseText`) continues; emphasis parsing runs **around** code ranges, not inside them.

Unclosed backtick: emphasis parsing is suppressed from the opening backtick to end of document (consistent with autocorrect inline-code exclusion semantics).

### 4.3 LaTeX spans

Inside `$...$` (study LaTeX, per `StudyRichText`):

- No emphasis parsing.
- `*` is literal (multiplication / LaTeX syntax).
- Study card editor and review surfaces share the same exclusion.

### 4.4 Tags

**Resolved rule (supersedes early "tags cannot be bolded" wording):**

- Outer wrappers apply to tags: `**#project-alpha**` renders the tag **bold** with hidden `**` when unfocused.
- The tag remains a functional `#tag` — pill highlight, click/completion behavior, tag extraction via `journalTagPattern`.
- Inside the `#tag` token body, `*` is **never** an italic opener (literal). Tag names cannot contain `*` per `journalTagPattern` anyway.
- `**` wrapping a tag applies bold weight to the tag text; the tag pill overlay must use the **bold** `TextStyle` when measuring (`TextPainter`) so pills stay aligned (see §8).

---

## 5. Architecture

### 5.1 Unified prose parser

New module: `lib/core/text/prose_markup.dart` (name TBD).

```
parseProseMarkup(String source) → ProseMarkupDocument
  - storedText: String (same as input)
  - exclusionZones: List<Zone>  // latex, inlineCode, tags
  - emphasisSpans: List<EmphasisSpan>  // bold/italic/underline/highlight
  - revealMask(selection) → Set<EmphasisSpan>  // which delimiters to show
```

Used by:

| Consumer | Purpose |
| --- | --- |
| `ProseEditingController` (TBD) | `buildTextSpan` for the three field widgets |
| `SpellCheckSquiggleLayer` | styled underline runs aligned with visible glyphs |
| `tokenizeWords` | which words are prose at all (§6.1) |
| `AutocorrectSession` | boundary detection, exclusion checks |
| `VoyagerProseText` | read-mode rendering on the plain surfaces |
| `StudyRichText` | delegate prose portions to shared parser; keep `$...$` math |
| `LeetCodeProseText` | layer emphasis around existing inline-code ranges |
| `searchHighlightedText` | layer emphasis around tag pills + keyword hits |

### 5.2 Field widget changes

All three shared widgets gain:

1. A `ProseEditingController` (extends `TextEditingController`, overrides `buildTextSpan`).
2. Selection listener → recompute `revealMask` → `notifyListeners`.
3. Existing overlay stack unchanged in structure; layers receive the same
   `TextSpan` the controller renders (not just its `TextStyle`) for measurement.

**The controller wraps, it does not replace (resolved 2026-09-02).**
`ProseEditingController` proxies the caller's controller — `value` reads and
writes straight through — and each field builds one for itself in `initState`.
Nothing at the ~50 call sites changes type, so autosave listeners, tag
completion rewrites and Vim's edits keep working against the object the caller
already owns, and there is still exactly one source of truth.

Wrapping in the widget rather than at the call site is also what makes §1's
"always on in eligible fields" true by construction: an opt-in controller type
would make a forgotten import a silently unformatted field, and the same widget
serves both single-line (excluded) and multiline (included) fields, so no
compile-time check could catch it.

**The §4.1 exclusions need no flag.** Every field on that list is either
single-line — the snippet trigger and replacement boxes, the dictionary word
boxes — and so already excluded by §10's single-line rule, or a different widget
entirely (`LeetCodeCodeField` is `flutter_code_editor`'s `CodeField`). Emphasis
is gated on exactly the existing `isMultilineField` predicate that gates
spellcheck.

**Four prose bodies are not built from the shared widgets** — the dream sticky
note, the bucket-list note dialog, the pinned-notification editor, and (already
covered) the todo notes panel. The first three stack `VimOverlayHost` over a raw
`TextField`, so each wraps its own controller the same way; `VimOverlayHost`
forwards the span builder to the layers it mounts.

**Do not** implement emphasis via a separate transparent overlay (unlike tag pills). Font weight changes glyph metrics; the `TextField` must render styled glyphs directly.

`TagHighlightedTextField` additionally:

- Passes bold/italic/underline/highlight styles into `_TagHighlightLayer` / `_TagHighlightPainter` so pill rects match bold tag text.

### 5.3 Display widget

New `VoyagerProseText` (name TBD): read-mode `Text.rich` with delimiters hidden, exclusions applied, optional keyword highlighting and tag pills.

Replace or wrap plain `Text` / `keywordHighlightedText` call sites where stored prose is shown.

**One widget was not enough (resolved 2026-09-02).** `VoyagerProseText` is a
drop-in for a plain `Text`, and that is all it is — the journal and dream list
previews, the pinned-note row, the dream stats line. The richer surfaces
already slice their text up for reasons of their own (tag pills, `$…$` math,
`` `code` `` chips) and could not be replaced by it.

So the shared piece is `proseReadRanges(text, theme)` instead: the emphasis of
a *whole* document flattened into sorted, non-overlapping `StyledRange`s, with
every delimiter at zero width and nesting already merged into one style per
run. `applyStyledRanges` layers those onto spans a surface built for itself,
which is what lets `searchHighlightedText`, `StudyRichText` and
`LeetCodeProseText` keep their own structure. Parsing the *slices* instead
would have been the obvious shortcut and is wrong at exactly the interesting
place: a `**` pair wrapping a tag has one delimiter on each side of the split.

`LeetCodeProseText` is the one that needs care, because it works on text whose
backticks have already been removed — so a `**` inside a snippet would read as
prose. It parses a copy with the code characters replaced by a letter: same
length, so every offset still lines up, and nothing inside a snippet can open,
close or exclude anything.

### 5.4 Styled runs helper

Extend `lib/core/text/styled_runs.dart` or add `prose_text_span.dart` to compose:

- exclusion-skipped ranges;
- nested emphasis styles;
- reveal-mode delimiter spans;
- keyword / search highlight overlays.

---

## 6. Spellcheck & autocorrect

### 6.1 Spellcheck

- Tokenize with existing `wordTokenPattern` (`[A-Za-z]+(?:'[A-Za-z]+)*`).
- Emphasis delimiters are **not** part of words; tokens inside emphasized spans **are** spellchecked.
- Exclude tokens inside `#tag`, `` `inline code` ``, and `$...$` (extend `spell_check_tokenizer.dart` — today only tags are excluded).

**The zones come from the parser (resolved 2026-09-02),** so a code span ends
in the same place for the squiggles as it does for emphasis. Two exceptions
were kept deliberately:

- An **unclosed** backtick still leaves the rest of the entry spellchecked. It
  suppresses emphasis to end of document (§4.2) and always did the same to
  autocorrect, but one stray backtick taking the squiggles off everything below
  it in a long entry is a far louder failure than a squiggle inside
  half-written code.
- `tokenizeWords` takes a **window** — bounds into the whole string, not a
  substring. The incremental spell check re-scans only the region around an
  edit, and a zone can open before that region; a substring has no way to know
  it is inside one. Offsets come back absolute either way.
- `SpellCheckSquiggleLayer` must lay out squiggles with the same styled `TextSpan` tree the field renders (bold italic changes metrics). Reuse the controller's `buildTextSpan` output with transparent glyphs + red wavy decoration (existing technique).

### 6.2 Autocorrect

- Add `*` to `kAutocorrectBoundaryChars` (and treat closing `**`, `__`, `==` as boundary events when the closing delimiter is typed).

**How the three differ (resolved 2026-09-02).** `*` is an ordinary boundary
character: it is never inside a word, so `*wtih*` and `**wtih**` both finish
the word on the first closing `*`. `_` and `=` cannot be — `snake_case` and
`x = 5` would autocorrect their first halves — so only the *second* character
of `__` or `==` counts, and only when the word ends where the run begins. That
needs the tracked "word the user typed into" to survive one keystroke past its
own end, which is the single exception to the caret leaving a token ending the
run.
- Autocorrect **inside** emphasized spans: **yes**, same gates as plain prose.
- Exclude autocorrect inside `#tag`, `` `inline code` ``, `$...$` (extend `autocorrect_engine.dart` — inline code already excluded for autocorrect). The
  engine's two hand-rolled predicates are gone; it asks `ProseMarkup` for the
  zones, last of the gates since it is the only one that scans the document.
  `$…$` gets no unclosed-to-end-of-document rule the way a backtick does: an
  unpaired `$` is a price, not the start of an equation.
- ALL CAPS, snippet triggers, paste, and Vim Normal mode rules unchanged (`AUTOCORRECT.md`).

### 6.3 Word-boundary semantics

The user's intent ("treat `*` as word boundaries") is satisfied by:

1. Delimiters not being word characters → `*hello*` tokenizes as `hello`.
2. Typing a closing `*` after a typo triggers autocorrect at that boundary (new).
3. Spellcheck squiggles underline `hello` inside `*hello*`, not the asterisks.

---

## 7. Paste — smart paste

When pasting into an eligible prose field:

1. If clipboard is **plain text** → insert as-is (markers preserved).
2. If clipboard is **rich HTML** (Word, browser, etc.) → convert to Voyager markers:
   - `<b>`, `<strong>` → `**…**`
   - `<i>`, `<em>` → `*…*`
   - `<u>` → `__…__`
   - `<mark>` → `==…==`
   - Strip other HTML; do not invent markers for unsupported styles.
3. Programmatic paste still counts as paste for autocorrect (no autocorrect on pasted tokens).

Nested HTML → nested markers. HTML tags inside excluded zones (if pasting into a selection inside code/latex) → paste plain text only.

**Where the hook lives (resolved 2026-09-02).** `EditableText` installs its own
`PasteTextIntent` action *inside* itself, and an intent is resolved from the
focused element upward — so no ancestor can override it. The key is claimed
instead, in the same ancestor `Focus` that already claims Backspace and Ctrl+Z
for autocorrect, and on the same two flags emphasis rides on: multiline, and
not one of §4.1's literal-text boxes.

That collides with `MediaPasteScope`, which claims Ctrl+V for the image
gallery on six pages — including the journal body. The field's `Focus` sits
*below* that scope's `Shortcuts` and so would win the key, and a pasted
screenshot would never reach the gallery again. The scope now publishes a
marker; inside it the field leaves the key alone and the scope routes the text
half through the same converter. One owner either way.

**Style attributes count as tags (resolved 2026-09-02).** §11 names Google
Docs, which ships no `<b>` at all — every run is a `<span>` carrying an inline
`font-weight`. So `font-weight` ≥ 600, `font-style: italic` and
`text-decoration: underline` are read wherever they appear, alongside the tags
above. `<style>` blocks, comments and conditional Word markup are skipped
outright, and a marker is never written against a space (`<b>word </b>` →
`**word** `), which the flanking rule would leave literal.

Rule 3 comes for free: the insert goes through
`userUpdateTextEditingValue`, and a multi-character insert is not typing, so
autocorrect leaves the pasted tokens alone.

---

## 8. Tag pill alignment (critical)

`TagHighlightedTextField` paints tag pills with `CustomPaint` + `TextPainter.getBoxesForSelection`. Bold text is wider than regular.

**This is not only the pills (resolved 2026-09-02).** Five layers stack around a
field, and every one of them laid its paragraph out as a flat
`TextSpan(text: text, style: style)`: the tag pills, the spellcheck squiggles,
the selection highlight, the autocorrect flash, and the Vim overlay. Any of them
left flat drifts the moment a glyph goes bold or a `**` collapses — measured at
240px against the field's 176px on one short line, with the caret box 32px out.

So each takes a `ProseSpanBuilder`, and the field hands them all the *same*
builder its own `TextField` renders with, under a metrics-only theme: weight and
slant (which move glyphs) are kept, colour and underline (which do not) are
dropped, so a layer contributes no ink of its own. The one exception is the
highlight's `kProseHighlightMark`, which a metrics-only theme still emits: it
is transparent, so it is still no ink, and it is what lets `ProseHighlightLayer`
read its ranges off the paragraph it already builds instead of parsing the
entry a seventh time. A property test
asserts the metrics paragraph and the painted one wrap identically.

The pill layer's *text* stays debounced at 200 ms, but its reveal does not: it
now repaints with the caret, since showing a `**` moves every glyph after it on
that line.

**Six, counting the wrap marks (resolved 2026-09-02).** The pinned-notification
row draws a mark beside every soft-wrapped line, positioned from its own
`TextPainter`. A wrap point is exactly what bold moves, so that layer takes the
span builder too — in both of its states, since the row shows the same note
whether it is being edited or read.

**Requirement:** when a tag is inside `**…**`, the highlight painter must:

1. Build the same styled `TextSpan` tree the field uses (including `FontWeight.bold` on the tag).
2. Layout with identical `maxWidth`, `strutStyle`, `textScaler`, `textHeightBehavior`.
3. Recompute on every emphasis reveal/hide and font-weight change.

Failure mode to avoid: pills drifting right of bold tag text (reported Obsidian-class bug when overlay uses regular weight).

For underline/highlight on tags, pills should encompass the decoration or sit behind it — match Obsidian: pill background + bold tag text + optional highlight fill inside pill.

---

## 9. Vim, snippets, lists

### 9.1 Vim

- Stored offsets unchanged — Vim operations (`dw`, `cw`, visual yank) see raw markers when revealed, and operate on stored text regardless.
- Normal-mode `*` (search forward) unchanged — only fires outside Insert mode.
- Visual selection across formatted text includes delimiter offsets when revealed.
- No new text objects in v1 (`vi*` etc.).
- **Ctrl+V splits by mode (resolved 2026-09-02).** Smart paste (§7) claims it
  only where the field is behaving as an insert surface, which is exactly where
  Vim's own Normal-mode `<C-v>` paste is not. So Normal mode keeps Vim's paste,
  unconverted, and Insert mode gets markers. The `p` register paste is likewise
  untouched: it puts back text Voyager itself yanked, which already carries
  whatever markers it had.

### 9.2 Snippets

- Snippet triggers may contain `*`, `**`, `__`, `==` — expanded text is literal.
- Formatting does not interact with `$0` tabstops beyond storing literal `$` in prose (study `$...$` exclusion is separate).

### 9.3 List editing

- `applyListEditing`, Tab indent, Enter continuation unchanged.
- Bullet `*` at line start is never parsed as italic opener (§2.4).

---

## 10. Surface coverage matrix

| Surface | Edit formatting | Read formatting |
| --- | --- | --- |
| Journal body (`TagHighlightedTextField`) | Yes | List preview via `VoyagerProseText` |
| Todo notes (`LabeledTextField`) | Yes | Edit panel only (row shows icon) |
| Search title/body (`TagHighlightedTextField`) | Yes | `searchHighlightedText` → shared parser |
| Study card front/back (`VoyagerTextField`) | Yes | `StudyRichText` → shared prose portion |
| LeetCode prose (`VoyagerTextField` / `LeetCodeProseText`) | Yes | `LeetCodeProseText` |
| LeetCode code field | **No** | N/A |
| Notifications multiline | Yes | Popover display |
| Rankings / jobs / dream journal notes | Yes | Wherever body text is shown |
| Snippet editor | **No** | N/A |
| Dictionary dialog | **No** | N/A |
| Single-line fields (`maxLines: 1`) | **No** (v1) | Plain text |

---

## 11. Edge cases & resolved behavior

| Case | Behavior |
| --- | --- |
| `**#tag**` | Bold tag, hidden `**` when unfocused, pill aligned to bold metrics |
| `#tag` with caret inside tag | No italic parsing inside tag body |
| `* item` at line start | Bullet, not italic |
| `` `code **not bold**` `` | Literal inside code span |
| `$x * y$` | Literal `*` inside LaTeX |
| `**unclosed` | Literal until closed |
| `***triple***` | Bold + italic |
| `2 * 3` (spaces) | Three tokens; middle `*` literal (no italic pair) |
| `2*3` | Literal asterisks unless paired — `*3` is not a valid italic pair |
| `__underline__` next to `**bold**` | Independent spans |
| Remote sync merge mid-word | Markers are plain characters; CRDT merges normally |
| Selection spanning reveal boundary | Reveal all touched spans |
| Copy | Copy **stored** text (with markers), not rendered glyphs |
| Smart paste from Google Docs | HTML → markers per §7 |

---

## 12. Logic risks & mitigations

| Risk | Mitigation |
| --- | --- |
| Bold changes line wrap vs squiggle/tag overlay | Single `buildTextSpan` source of truth; overlays read it |
| Reveal toggling causes layout jump | Expected (§3.5); single-frame relayout + caret scroll-into-view; not a bug unless offsets desync |
| Parser divergence across surfaces | One `parseProseMarkup`; property tests |
| `*` bullet vs italic ambiguity | Line-start bullet rule (§2.4) |
| Study `$` vs highlight `==` | `$` zones parsed first; no overlap |
| Performance on long journal entries | One parse per string per frame, shared through a two-entry cache on the controller (see below); debounce reveal repaints like tag highlight (200 ms) |
| Flutter `buildTextSpan` + spellcheck branch | Keep `SpellCheckConfiguration.disabled()` (existing pattern) |

**The cache holds two entries, not one (resolved 2026-09-02).** The six
consumers in a frame do not all read the same string — the `#tag` pills work
from a debounced copy — so a frame asks for the new text, then the old, then
the new again, and a single slot re-scans the whole entry on each switch. Two
slots bring a keystroke on a 120-paragraph entry down to two parses, which a
counting test holds it to.

---

## 13. Implementation phases (suggested)

1. **Parser + tests** — exclusion zones, nesting, bullets, unclosed, precedence.
2. **ProseEditingController + VoyagerProseText** — render-only, delimiter hiding, reveal on selection.
3. **Wire three field widgets** — replace `TextEditingController` in prose fields.
4. **Spellcheck + autocorrect** — boundary chars, tokenizer exclusions, styled squiggle layout.
5. **Tag pill bold alignment** — `TagHighlightedTextField` painter update.
6. **Display surfaces** — journal preview, search, study, LeetCode prose.
7. **Smart paste** — HTML clipboard converter.
8. **Polish** — Vim manual QA, sync merge QA, long-document perf.

---

## 14. Test plan

### Unit

- Parser: nesting, overlap, unclosed, bullet lines, exclusions, `***`, precedence.
- Reveal mask: caret inside, selection overlap, multiple containing spans.
- Tokenizer: words inside `**…**` and `*…*`; exclusions.
- HTML paste converter.

### Widget

- Bold text + tag pill alignment (golden or pixel tests).
- Squiggle position inside bold italic word.
- Reveal toggling on caret move.

### Integration

- Journal autosave preserves markers.
- Remote body merge with formatting markers intact.
- List Enter on `* item **bold**` line.
- Study card: `$x^2$` beside `**bold**`.
- LeetCode prose: `` `**not bold**` `` literal.

---

## 15. Decisions log

| Date | Decision |
| --- | --- |
| 2026-09-02 | Syntax: `**`, `*`, `__`, `==`; nesting allowed; unclosed = literal |
| 2026-09-02 | Live Preview reveal: show delimiters when caret inside or span selected; hide otherwise |
| 2026-09-02 | Tags can receive outer bold/italic; `*` inside tag body is literal |
| 2026-09-02 | Line-start `* ` = bullet, not italic |
| 2026-09-02 | Code field exclusion: `LeetCodeCodeField` only; snippet + dictionary excluded |
| 2026-09-02 | Inline code + LaTeX exclusions in prose |
| 2026-09-02 | Study cards + search included |
| 2026-09-02 | Spellcheck + autocorrect active inside emphasis; `*` added as autocorrect boundary |
| 2026-09-02 | Smart paste from HTML; copy stores raw markers |
| 2026-09-02 | v1 also includes underline + highlight; no links/strikethrough |
| 2026-09-02 | Always on; markers-only input (no shortcuts) |
| 2026-09-02 | Highlight fill: field accent color (~20–30% alpha), corners rounded 4px, painted by a layer rather than `backgroundColor` (§3.4) |
| 2026-09-02 | Underline: solid black line beneath text |
| 2026-09-02 | Delimiter reveal reflow: acceptable (§3.5) |
| 2026-09-02 | Pairing uses simplified CommonMark flanking; `__` may not sit inside a word (§2.3) |
| 2026-09-02 | A closer drops every delimiter opened after its opener, so spans are a properly nested forest (§2.3) |
| 2026-09-02 | Hidden delimiters render at `fontSize: 0`, never omitted — `buildTextSpan` must stay one character per stored character (§3.1) |
| 2026-09-02 | Underline: black on light, `onSurface` on dark — open question 2 closed (§3.4) |
| 2026-09-02 | `ProseEditingController` proxies the caller's controller; fields wrap it themselves, no call-site type change (§5.2) |
| 2026-09-02 | §4.1 exclusions need no opt-out flag: all are single-line or a different widget (§5.2) |
| 2026-09-02 | All five overlay layers share the field's span, not only the tag pills (§8) — six, with the pinned note's wrap marks |
| 2026-09-02 | Spellcheck zones come from the parser, except that an unclosed backtick still leaves the entry checked (§6.1) |
| 2026-09-02 | `tokenizeWords` takes a window into the whole string, so the incremental check can see a zone that opened before it (§6.1) |
| 2026-09-02 | `*` is a plain autocorrect boundary; `__` and `==` only on their second character (§6.2) |
| 2026-09-02 | Autocorrect's exclusions are `ProseMarkup` zones; the engine's own tag and backtick predicates are gone (§6.2) |
| 2026-09-02 | Read surfaces layer `proseReadRanges` onto their own slices; `VoyagerProseText` is only for the plain `Text` call sites (§5.3) |
| 2026-09-02 | LeetCode prose parses a copy with code characters masked, since its backticks are already stripped (§5.3) |
| 2026-09-02 | Smart paste claims Ctrl+V in the field's ancestor `Focus`, and stands down inside a `MediaPasteScope`, which routes the text half itself (§7) |
| 2026-09-02 | The HTML converter reads inline `style` attributes as well as tags, for Google Docs (§7) |
| 2026-09-02 | Parse cache holds two entries, for the frame that asks new/old/new (§12) |

---

## 16. Open questions

1. **Single-line fields:** excluded in v1 — revisit if titles should support `**bold**`?
2. ~~**Underline in dark mode.**~~ Closed 2026-09-02: black on light,
   `onSurface` on dark (§3.4).
3. **Uncontrolled fields.** A `VoyagerTextField` given no `controller` builds
   one inside `TextField`, which cannot be wrapped — so a multiline field with
   no controller of its own gets no emphasis. Not currently reachable by any
   prose surface; revisit if one appears.
