# Study Card Images — High-Level Design

## Status

Accepted design. Replaces inline image embeds on study cards with per-side image galleries and a fixed image-top / text-bottom display layout.

## Summary

Study cards currently attach images via `![[media:…]]` inline tokens embedded in `frontText` / `backText`. This design removes inline images from study entirely and adopts the shared **gallery** model already used by todo and journal:

- Each card face (front / back) has an ordered gallery of images stored as `MediaReference` rows with `MediaFacet.front` or `MediaFacet.back`.
- Text fields hold prose and LaTeX only — no image tokens.
- Display surfaces (session, cram, editor preview) share one layout widget: images at the top, text at the bottom, with explicit carousel controls when a face has more than one image.

After implementation, **all inline-image support is removed** from the codebase and from `MEDIA.md`. Study was the only feature that used inline images; journal and todo already use galleries.

---

## Goals

- Simpler authoring: paste/drop/file-picker attach to a gallery strip, not into editable text.
- Predictable study layout: image(s) top, text bottom; image-only or text-only faces fill the whole card.
- Reuse existing media infrastructure (`MediaGalleryStrip`, `MediaImage`, lightbox, ingest, sync, offline states).
- No gesture conflicts with cram-mode card grading (horizontal swipe to pass/fail stays on the card; image browsing uses buttons only).
- Duplicate and reverse card operations preserve image galleries correctly.

## Non-goals (v1)

- Bulk text import (`front|back` paste) with images.
- Migrating legacy `![[media:…]]` tokens into galleries (tokens may remain in stored text but are not rendered).
- Screen-reader-specific carousel announcements.
- Keyboard navigation between carousel images (left/right keys keep current study/cram behavior).
- Captions, alt text, or per-image display-width editing on study cards.
- Max image count per side.

---

## Layout rules

All display surfaces — **SRS session**, **cram session**, and **editor preview** — use the same layout logic via a shared `StudyCardFace` widget (name TBD).

### Per-face layout (front and back are independent)

| Content on face | Layout |
|-----------------|--------|
| Text only | Text fills the entire card face (current behavior). Scrolls when content exceeds available height. |
| Image(s) only | Image fills the entire card face. Letterboxed (`BoxFit.contain`). Tap opens lightbox. |
| Image(s) + text | **Top half:** image area. **Bottom half:** text area, scrolls independently when long. |

### Image area (when images are present alongside text, or when multiple images exist on an image-only face)

- **Single image:** shown in the image region; letterboxed (`BoxFit.contain`).
- **Multiple images:** same region; user browses with **explicit previous/next arrow buttons** and **page dots** (e.g. `● ○ ○` or `2 / 5`). **No horizontal swipe** on the image carousel in session or cram.
- **Tap image:** opens the existing full-screen lightbox with zoom and ordered swipe (lightbox behavior unchanged from todo/journal).

### Image fit

- In-card display always uses **`BoxFit.contain`** (letterbox). The full image is visible, scaled down if needed.
- Lightbox is where the user inspects the image at full size.

### LaTeX

- LaTeX (`$...$`) renders only in the text region.
- No images inside LaTeX or mixed inline with math.

---

## Editor

### Structure

Replace `MediaEmbedFieldScope` on front/back text fields with:

1. A plain `VoyagerTextField` per side (LaTeX source typed as-is; no live rendering in the field).
2. A **layout preview** under each side when that side has text and/or images, using the same `StudyCardFace` rules as session/cram.
3. One **`MediaGalleryStrip` per side** with `facet: MediaFacet.front` or `MediaFacet.back`, `collection: studyCards`.

### Gallery strip visibility

- The gallery strip for a side is **hidden until that side has at least one image**.
- Before the first image exists, the user can attach via:
  - **Paste** (when the corresponding text field is focused — see Paste rules).
  - **Drag-and-drop** onto the editor modal (scoped to the focused side's gallery).
  - **File picker** (exposed via the gallery strip's existing attach affordance once visible, plus a minimal attach entry point before the strip appears — e.g. a small "Add image" control per side, or the strip's attach button shown only when empty without the full reorder UI).

### Gallery capabilities

- Reorder images (drag-reorder, same as todo).
- Remove images.
- File picker attach.
- Paste and drop (per MEDIA.md gallery rules).

### Save validation

A card is saveable when **each side has at least one of text or images**:

- Front: `frontText.trim().isNotEmpty` **or** ≥1 front image.
- Back: `backText.trim().isNotEmpty` **or** ≥1 back image.

Both sides must satisfy this. A side may be image-only or text-only.

### New card ID

Allocate a stable card `id` (`newId()`) when the editor opens for a **new** card, before first save, so `MediaGalleryStrip` can attach references immediately. On save, upsert uses that pre-allocated id (same pattern as avoiding a save-then-attach race).

### Remove inline integration

- Remove `MediaEmbedFieldScope` from the study editor.
- Remove `syncInlineEmbeds` calls on save.
- Gallery references are written directly by `MediaGalleryStrip` / `MediaService.addReference` as images are attached.

---

## Display surfaces

### SRS session (`study_session_page`)

- Replace `_SessionCardFace` + inline `StudyRichText` image rendering with `StudyCardFace`.
- Card flip (tap / space) unchanged.
- Grading row and keybinds unchanged.
- Carousel: dots + arrow buttons only.

### Cram session (`study_cram_page`)

- Same `StudyCardFace` layout as SRS.
- Horizontal **card** swipe for pass/fail unchanged (whole-card gesture).
- Image carousel does **not** use horizontal swipe — dots + arrows only, so no conflict with cram grading.

### Deck workbench grid (`study_card_tile`)

Miniature card previews use a **compact** treatment, not the full 50/50 layout:

| Face content | Mini-card behavior |
|--------------|-------------------|
| Text (with or without images on that side) | Text preview as today. Small **image icon** badge when that side has ≥1 image (no thumbnail, no carousel). |
| **Image-only** on the visible side | Show the image scaled down, **filling the whole mini-card** (letterboxed). No text, no carousel, no icon badge needed. |

Which face is shown follows existing workbench rules (front by default; flip on tap; back-only search match shows back).

### Editor preview

- Rendered preview under each text field uses `StudyCardFace` with the same rules as session/cram (not raw `StudyRichText` with inline images).

---

## Data model

### Storage

| Field | Images |
|-------|--------|
| `frontText` / `backText` | Plain text + LaTeX only. No new `![[media:…]]` tokens written. |
| `MediaReference` | Ordered gallery per side: `collection = studyCards`, `documentId = card.id`, `facet = front \| back`, `sortOrder` = carousel order. |

Remove use of `MediaFacet.inline` for study. `syncInlineEmbeds` is no longer called for study cards.

### Card operations

| Operation | Text | Images |
|-----------|------|--------|
| **Reverse** | Swap `frontText` ↔ `backText` | Swap all `MediaFacet.front` references ↔ `MediaFacet.back` references on the same `documentId` |
| **Duplicate** | Copy to new card row with new `id` | Copy all front and back references to the new card `documentId` (new reference rows, same `mediaId`s) |
| **Move** (to another deck) | Update `deckId` | No reference copy needed — same `documentId`, refs move with the card |
| **Delete** | Soft-delete card | `detachStudyCardMedia` / `removeReferencesForOwner` (existing path) |

### Legacy inline tokens

- **No migration.** Existing `![[media:…]]` strings may remain in stored text.
- **Rendering:** tokens render as **nothing** (stripped from display). Do not show raw token text on cards.
- **No new inline tokens** are created anywhere in the app after this change.

---

## Paste and drop

Paste applies only when a study editor **text field is focused**:

| Clipboard | Focused field | Result |
|-----------|---------------|--------|
| Text | Front / back field | Paste into that field's text |
| Image | Front field | Attach to **front** gallery |
| Image | Back field | Attach to **back** gallery |
| Text + image | Front / back field | Text into that field; image into that side's gallery |
| Image / text+image | Nothing focused | No-op |

Drop targets follow the same side scoping (focused side, or explicit drop zone per side in the editor).

---

## Offline and sync states

Reuse existing `MediaImage` / gallery behavior everywhere study shows an image:

- Downloading / pending: spinner or placeholder (same as todo strip and journal fan).
- Missing / failed: existing error treatment.
- Card remains usable for text when images are not yet local.

---

## Search

Unchanged and intentional:

- Search matches text only.
- Image-only fronts do not match keyword queries on the front.
- Back-only match behavior (`studyCardMatchesBackOnly`) unchanged.

---

## Accessibility

- **No change** to keyboard behavior for study/cram: left/right keys do **not** browse carousel images.
- Screen reader enhancements for carousel: **out of scope** for v1.

---

## Workbench image badge

When a face has images **and** text (or images with text on the other face making the visible side text-primary), show a small **image icon** on the mini-card indicating images are attached to that side — same affordance as today's inline indicator, without showing the actual image unless the visible side is image-only (see grid rules above).

---

## Inline image removal (codebase-wide)

After this feature ships, **delete all inline-image support**. Study was the sole consumer; journal and todo never used inline mode.

### Update `MEDIA.md`

- Remove inline as a supported integration mode.
- Remove embed token format (`![[media:…]]`), inline paste table rows, inline chrome, `syncInlineEmbeds`, `MediaFacet.inline` (if no longer referenced), and study-specific inline documentation.
- Update goals: study uses gallery per face (`front` / `back`), not inline.
- Update parent-document section: study galleries only; no tokens in text.
- Update ingest step 6: remove "insert embed" path.

### Delete or gut inline-specific code

| Area | Action |
|------|--------|
| `lib/core/media/widgets/media_embed_field.dart` | Delete |
| `lib/core/media/widgets/media_embed_layer.dart` | Delete |
| `lib/core/media/widgets/media_embed_inline_image.dart` | Delete |
| `lib/core/media/media_embed_controller.dart` | Delete |
| `lib/core/media/media_embed_layout.dart` | Delete |
| `lib/core/media/media_embed_token.dart` | Delete (or retain a minimal `legacyEmbedPattern` only if needed to strip legacy tokens from display — prefer inline regex in `StudyRichText` strip pass, then delete file) |
| `MediaService.syncInlineEmbeds` | Delete |
| `MediaFacet.inline` | Delete from enum if unused |
| `lib/features/study/study_rich_text.dart` | Remove embed rendering; optionally strip legacy tokens from displayed text |
| Vim embed caret ops (`vim_text_ops.dart`, `vim_text_overlay.dart`) | Remove embed-specific branches |
| Spell check / selection highlight embed reservations | Remove `MediaEmbedReservations` plumbing from text fields |
| `tag_highlighted_text_field.dart` | Remove `MediaEmbedLayer` / `MediaEmbedTextEditingController` integration |
| Study editor | Remove `MediaEmbedFieldScope`, `syncInlineEmbeds` on save |
| Tests: `media_embed_*`, embed-related vim/spell tests | Delete or rewrite for gallery-only study |

### Keep (shared gallery stack)

- `MediaGalleryStrip`, `MediaImage`, `MediaLightbox`, `MediaPasteScope`, `MediaDropTarget`, `MediaService` gallery APIs, import/export of image binaries at app level (unchanged; bulk study text import still has no images).

---

## New components

### `StudyCardFace`

Shared widget for session, cram, and editor preview.

**Inputs:** `text`, `images` (ordered `MediaReference` + assets), `textStyle`, optional `keywords` (workbench/search), `compact` flag (for editor preview sizing).

**Behavior:** implements layout table above; carousel with dots + arrows when `images.length > 1`; tap → lightbox; text scroll in bottom region only when combined layout applies.

### `StudyCardImageCarousel` (optional sub-widget)

Arrow buttons + dot indicator + single `MediaImage` slot. No `PageView` gesture scrolling in-card (index changes only via button taps). Lightbox may still use `PageView` internally.

### Media copy helper

`MediaService.duplicateReferencesForOwner(fromDocumentId, toDocumentId, collection)` or equivalent for duplicate-cards path — copies front and back facet references to a new card id.

### Reverse media swap

`MediaService.swapFacets(collection, documentId, facetA, facetB)` or swap front/back reference sets in `reverseStudyCard`.

---

## Implementation order (suggested)

1. **`StudyCardFace`** + carousel (dots/arrows, contain, lightbox tap).
2. **Editor:** stable new-card id, gallery strips, layout preview, relaxed save validation, remove inline scope.
3. **Session + cram:** wire `StudyCardFace`; load references per facet.
4. **Workbench tile:** icon badge + image-only full mini-card.
5. **Reverse + duplicate:** media reference swap / copy.
6. **Legacy token display:** strip `![[media:…]]` from rendered output.
7. **Inline removal:** delete inline modules, update `MEDIA.md`, remove dead tests.
8. **Tests:** layout cases (text-only, image-only, both, multi-image carousel), reverse, duplicate, paste-to-side, save validation.

---

## Test plan (acceptance)

- [ ] Text-only card: full-face text in session, cram, editor preview, workbench.
- [ ] Image-only card: full-face letterboxed image; tap opens lightbox.
- [ ] Image + text: 50/50 split; long text scrolls in bottom half only.
- [ ] Multiple images: arrows and dots change image; no in-card swipe; lightbox works.
- [ ] Cram horizontal card swipe still grades; does not change carousel index.
- [ ] Editor: gallery strip hidden until first image; reorder, remove, file picker work.
- [ ] Paste text/image/both into focused front vs back field attaches to correct side.
- [ ] Save with image-only front and text-only back (and vice versa).
- [ ] Reverse swaps text and both galleries.
- [ ] Duplicate copies both galleries to new card id.
- [ ] Move to another deck keeps images on card.
- [ ] Workbench: icon when text face has images; full image when visible side is image-only.
- [ ] Legacy `![[media:…]]` in stored text displays nothing; no new tokens created.
- [ ] Offline pending/missing states match todo/journal.
- [ ] Inline image code and `MEDIA.md` inline sections removed.

---

## Open items

None blocking — design is accepted. Implementation may choose whether the pre-first-image attach control is a per-side "Add image" button or an always-available icon separate from the hidden strip; behavior must match paste/drop/file-picker rules above.
