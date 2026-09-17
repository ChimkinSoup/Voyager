# Multiline field scroll insets and caret clipping

Issue note only — no fix implemented here. Desired behavior and constraints are locked in from product review; implement later against this doc.

## Symptoms

### 1. Caret draws past the bottom border

On a multiline text box (reproduced on the journal entry body), when the caret sits on the last visible line and the field auto-scrolls to keep it on screen, the blinking caret can extend slightly past the bottom edge of the field border.

Reproduced with the normal insert caret. Vim Normal-mode’s block caret is slightly shorter vertically, so the overflow is not currently visible there — but any fix must still guard Vim carets so a taller overlay caret cannot paint past the border later.

### 2. Permanent vertical gaps that do not scroll away

Flutter’s `InputDecoration.contentPadding` frames the field’s **internal scrollable viewport**. It does not travel with the paragraph. Large top/bottom padding therefore leaves a permanent blank strip between the border and the first/last *visible* line whenever the body is scrolled.

Observed:

| Surface | Widget | Current vertical padding | What you see |
|---|---|---|---|
| Journal page body | `_PlainJournalEditor` → `TagHighlightedTextField` | `EdgeInsets.fromLTRB(16, 16, 16, 6)` | Permanent gap at the **top** when scrolled; bottom already nearly flush (which is why the caret can kiss/overrun the border) |
| Search → open journal entry dialog body | `TagHighlightedTextField` (default padding) | `EdgeInsets.all(16)` from `TagHighlightedTextField` | Permanent gap at **both** top and bottom when scrolled |

The journal body comment in `journal_page.dart` already documents this framing behavior and the intentional top/bottom asymmetry. That tradeoff is no longer acceptable: scrolled text should read flush to the border.

## Desired behavior

1. **Flush when scrolled.** Once the user scrolls (or the field auto-scrolls the caret), text must run up to the top and bottom borders — no permanent blank strip from `contentPadding` on the scroll axis.
1a. **Same caret room top and bottom.** A caret moved past either edge of a scrolled body stops the same distance from that border, so the vertical `contentPadding` stays symmetric. At the very end of a document the last line therefore rests that far above the bottom border, mirroring the first line at the start.
2. **Small indent at rest for the first line.** An empty or short body (nothing scrolled yet) should still give the first line a small top inset so it does not sit glued under the border. That inset must scroll *with* the content, not frame the viewport.
3. **Clip overflow.** Nothing — caret, selection highlight, spellcheck squiggles, tag/emphasis overlays, Vim caret — may draw past the field border. Prefer clipping over adding a permanent bottom inset just for the caret. Accept that descenders on the last visible line may clip at the border; flush text is the priority.
4. **All multiline fields.** Scope is every expanding / multiline Voyager field that shares this chrome (`TagHighlightedTextField`, `LabeledTextField`, `VoyagerTextField`, and any other multiline `TextField` wrapped the same way), not journal alone. Search’s journal dialog is a known second repro; other multiline fields should get the same treatment even if they have not been manually tested yet.
5. **Vim included.** Even though Normal-mode caret height currently avoids the overflow, the clip/guard must cover Vim overlay carets as well.

Horizontal padding is out of scope for this issue unless a fix accidentally changes it.

## Relevant code (starting points)

- Journal body padding / prior rationale: `lib/features/journal/journal_page.dart` (`contentPadding: EdgeInsets.fromLTRB(16, 16, 16, 6)` and the comment above it).
- Search entry body (defaults to `EdgeInsets.all(16)`): `lib/features/search/search_page.dart` (dialog `TagHighlightedTextField`).
- Shared field widgets: `lib/core/widgets/tag_highlighted_text_field.dart`, `labeled_text_field.dart`, `voyager_text_field.dart`.
- Caret scroll inset (already zeroed app-wide to avoid caret-driven overscroll): `lib/core/widgets/field_scroll_padding.dart` (`kVoyagerFieldScrollPadding`).
- Overlay geometry that mirrors padding / caret strip: `withCaretMargin` / density shift in `lib/core/widgets/spell_check_field_support.dart` (overlays must stay aligned if padding model changes).
- Shared chrome notes: `TEXTBOX_WIDGET.md`.

## Implementation constraints (for whoever fixes this)

Do not “fix” the permanent gap by only shrinking `contentPadding` to zero on an expanding field without replacing the at-rest top inset. Zero vertical `contentPadding` alone would make the first line flush even when unscoped/unscrolled, which violates desired behavior (2).

A correct approach must separate:

- **Scroll-axis breathing room that moves with the text** (e.g. padding inside the scrollable / leading-trailing scroll content), from
- **Viewport framing** (`contentPadding`), which must not leave a lasting top/bottom gutter once scrolled.

Clipping at the field (or notched border) boundary must apply to the editable caret *and* every overlay painted above it (tags, squiggles, Vim, selection), or those layers will still spill past a clipped `EditableText`.

Preserve existing horizontal padding and label/notch alignment (`NotchedFieldBorder` positions the floating label from `contentPadding`).

`kVoyagerFieldScrollPadding` is already `EdgeInsets.zero` to stop caret ticks from rubber-banding ancestor scrollables — do not reintroduce non-zero `scrollPadding` as a substitute for clipping without re-checking that overscroll regression.

## Acceptance checks

- Journal body, long entry: scroll to top → first visible line flush to top border; scroll to the middle and move the caret past the bottom edge → it stops as far from the bottom border as it does from the top when moved past the top edge; caret on last line does not paint past the bottom border while blinking.
- Journal body, empty/short: first line still has a small top indent before any scroll.
- Search → open a journal entry with a long body: same flush-when-scrolled behavior top and bottom (today both sides show a permanent gap).
- Spot-check other multiline fields that use the shared text widgets (notes, dialogs, etc.): no caret spill past the border; no permanent scroll-axis gutter from content padding.
- Vim Normal mode: caret still cannot paint past the border (guard present even if current caret is shorter).
- Tag pills, spellcheck squiggles, emphasis highlights, and selection remain aligned with the text after the padding model changes.
