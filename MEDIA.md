# Media / Images — High-Level Design

## Status

Accepted design (pre-implementation). Captures product decisions from the media design discussion.

## Goals

- Add first-class image support via a **shared media module**, not feature-specific upload code.
- Surfaces in v1: **Journal** (gallery, shown as a corner fan on the body — and on the Search page's entry dialog, which edits the same entry), **Todo** (main tasks only, gallery strip), **Study** (a gallery per card face — `front` / `back`; not LeetCode), and a future **Rankings** page (gallery only — e.g. restaurant food photos).
- Images sync across devices with offline queueing; devices download bytes so content remains usable offline after the last successful sync.
- Paste (`Ctrl`/`Cmd+V`), drag-and-drop, and file picker — no camera.
- Full-screen / lightbox viewer with zoom and ordered swipe.
- Import/export of all app data includes image binaries.
- User settings for remote upload, background offline prefetch, and on-demand remote download, plus low-disk warning.

## Non-goals (v1)

- Captions / alt text
- List / deck thumbnails
- Rotate-before-save
- Camera capture
- GIF support
- Images on todo subtasks, todo notes, or LeetCode
- Max image count per parent

---

## Architecture overview

```
┌─────────────────────────────────────────────────────────────┐
│ Features (journal / todo / study / rankings)                │
│  - Gallery strip / fan / card-face widgets + paste hooks     │
│  - Lightbox entry points                                    │
└───────────────────────────┬─────────────────────────────────┘
                            │ owner: (collection, documentId[, facet])
┌───────────────────────────▼─────────────────────────────────┐
│ Domain: MediaAsset, MediaReference, MediaSettings           │
│  - Content-addressed blob (hash) + refcount                 │
│  - Soft-delete aligned with 30-day purge                    │
└───────────────────────────┬─────────────────────────────────┘
                            │
┌───────────────────────────▼─────────────────────────────────┐
│ MediaService (core)                                         │
│  - Ingest (validate, HEIC→JPEG, compress, dedupe)           │
│  - Local file store                                         │
│  - Upload / download queues (Firebase Storage)              │
│  - GC / purge                                               │
└───────────────┬─────────────────────────────┬───────────────┘
                │                             │
     ┌──────────▼──────────┐       ┌──────────▼──────────┐
     │ Local disk cache    │       │ Firebase Storage    │
     │ + Drift metadata    │       │ (path by hash/uid)  │
     └─────────────────────┘       └─────────────────────┘
```

**Firebase Storage note:** Storage objects have paths and (optional) download URLs. Voyager **must not** persist ephemeral download URLs as the source of truth. Persist a stable **`mediaId`** (and content `hash`). Clients resolve local path first, then Storage path `users/{uid}/media/{hash}` when remote I/O is allowed.

Nothing about an image's placement is written into the parent's prose: a
`MediaReference` row *is* the placement, everywhere.

> **Removed:** study cards once embedded images as `![[media:<mediaId>|<widthPx>]]`
> tokens inside their own text. Inline images are gone from the app entirely
> (see STUDY_IMAGES.md); tokens left in old card text render as nothing, and no
> new ones are ever written.

---

## Per-surface behavior

| Surface | Placement | Paste / DnD | File picker |
|---|---|---|---|
| Journal body | Fan in the body's bottom-right corner | Yes | No |
| Journal title | Text only | Text only; image-only clipboard → no-op | — |
| Search result's entry dialog | Same fan, same entry | Yes | No |
| Todo main task | Gallery strip on edit panel | Onto strip / panel (not into notes) | Yes |
| Todo notes / title / subtasks | No images | Text only; image-only → no-op | — |
| Study card front / back | Gallery per face (`front` / `back` facet) | Yes when that side’s field focused | Yes |
| Rankings (future) | Gallery | Onto gallery | Yes |

### Clipboard rules

| Focus | Clipboard | Result |
|---|---|---|
| Image-capable field | Text | Paste text |
| Image-capable field | Image | Paste / insert image |
| Image-capable field | Text + image | Paste **both** (text at the caret, image onto the gallery) |
| Non-image field | Text or text+image | Paste **text only** |
| Non-image field | Image only | **No-op** |
| Nothing relevant focused | Any | **Ignore** |

### Gallery presentations

Every surface uses the same model — an ordered list of `MediaReference`s on the
parent — and differs only in how it is drawn:

- **Strip:** todo's edit panel, and each side of the study card editor.
  Thumbnails, drag to reorder, remove, attach.
- **Fan:** the journal. A stacked corner thumbnail for a surface that is mostly
  text.
- **Card face:** study's session, cram and editor preview. Image region on top,
  text underneath, browsed with arrows and dots (STUDY_IMAGES.md).

Both features that once put images *inside* an editable paragraph have moved off
it. An image inside an `EditableText` is drawn over transparent glyphs, so
selecting it selects text rather than a picture, and the size and replace chrome
it is supposed to carry has nothing to hang off; every layer stacked over the
field also had to reserve the identical line height or drift out of alignment
with it. The cost, which was accepted: an entry's or a card face's images are a
set, not a sequence interleaved with the writing.

---

## Data model

### `MediaAsset` (blob, deduped)

One row per unique content hash per user account (local DB; mirrored metadata in Firestore as needed).

| Field | Notes |
|---|---|
| `id` (`mediaId`) | Stable UUID quoted by references |
| `contentHash` | Hash of **post-ingest** bytes (after HEIC convert + compress) |
| `localPath` | Device-relative path under app media dir |
| `byteSize` | Post-ingest size |
| `mimeType` | `image/jpeg`, `image/png`, `image/webp` |
| `width` / `height` | Pixel dimensions after ingest |
| `remotePath` | e.g. `users/{uid}/media/{contentHash}` |
| `uploadState` | `localOnly` \| `pending` \| `uploading` \| `uploaded` \| `failed` |
| `downloadState` | `present` \| `pending` \| `downloading` \| `missing` \| `failed` |
| `createdAt` / `updatedAt` | |
| `deletedAt` | Soft-delete timestamp; purge with global 30-day policy |

**Dedup:** ingest computes hash; if an asset with that hash exists and is not purged, **reuse** it and add a new reference (one blob, many refs).

### `MediaReference` (ownership)

| Field | Notes |
|---|---|
| `id` | |
| `mediaId` | → `MediaAsset` |
| `collection` | e.g. `journalEntries`, `todoTasks`, `studyCards`, `rankings` |
| `documentId` | Parent entity id |
| `facet` | Optional: `front` \| `back` \| `gallery` |
| `sortOrder` | Gallery / swipe order |
| `displayWidthPx` | For gallery items, where the surface offers a width control |
| `createdAt` / `deletedAt` | Soft-delete with parent or when unreferenced |

The reference row is the placement everywhere, which is what gives sync, GC, swipe order and progress badges a structured index without parsing prose. Removing the last reference to an asset starts its unreferenced retention.

### Parent documents

- **Study:** two galleries per card, `facet = front` and `facet = back`, both keyed on the card id. `frontText` / `backText` hold prose and LaTeX only.
- **Journal / todo / rankings:** one gallery per parent; reference list only.

---

## Ingest pipeline

1. Accept bytes from paste, drag-and-drop, or file picker (gallery only).
2. **Reject** if decoded size **> 10 MB** (pre-compress). Show warning: image too large; do not attach.
3. Allowed inputs: **PNG, JPEG, WebP, HEIC**. **No GIF.**
4. **HEIC → JPEG** on ingest; do not keep the HEIC original.
5. **Auto compress / downscale** to a sensible max dimension (implementation detail; target: good quality on phone + desktop, stay under 10 MB post-ingest).
6. Hash post-ingest bytes → dedupe → write local file → create/reuse `MediaAsset` → create `MediaReference` appended to the target gallery.
7. If **remote upload** setting is on → enqueue upload. If off → `uploadState = localOnly` forever (until setting enabled and a future re-queue policy is run — v1: new/queued uploads only while setting is on; local-only assets stay local unless user re-enables and triggers sync repair).

### Fan (journal)

- Up to **3** cards, fanned from the body's bottom-right corner, floating over the text; a `+N` badge carries the rest. No cap on how many images an entry holds.
- Hidden entirely until the entry has an image.
- The whole stack is one control: it opens the lightbox on the entry's images, in order, where they are looked through and **removed**.
- The Search page's result dialog carries the identical fan on its own body field. It is the same entry, so an entry must not gain or lose pictures depending on which page it was opened from.

### Replace image

- Picks/ingests a new blob (or reuses deduped asset).
- Keeps the gallery slot and width.

---

## Sync & offline

### Upload queue

- Independent of Firestore document outbox (`PendingUploadsTable`), but drained on the same connectivity lifecycle.
- Persist pending uploads locally; retry with backoff; surface **progress** and **pending sync** badges on the image / parent.
- Metadata (asset rows + references) still syncs through existing document sync so other devices learn that an image exists.

### Download / prefetch

Default product intent: **all images for all synced docs** end up local after sync, subject to settings:

| Setting | Effect |
|---|---|
| **Remote image uploads** | Off → never upload; images stay **device-local forever**. Other devices may see the references but cannot obtain bytes from this device’s cloud path. |
| **Background offline prefetch** | Off → do not proactively download all remote images after doc sync. On → after learning new remote assets, enqueue downloads for missing locals. |
| **Remote image downloads** | Off → never download image bytes (prefetch and on-demand). Missing local → **“Download disabled”** empty state (not an infinite spinner). On → allow downloads. |

These are **three separate settings**. Prefetch is meaningless when downloads are off.

### Missing local bytes (downloads allowed)

- Show a **spinner** while download is queued/in progress.
- On failure, show a retryable error state (implementation detail).

### Multi-device / conflicts

- Two devices add different images offline → both appear after sync (ideal).
- Dedup may collapse identical bytes to one asset with multiple refs.

### Soft delete & GC (30 days)

Align with `softDeleteRetentionDays` (**30**).

| Event | Behavior |
|---|---|
| Soft-delete parent (entry / task / card / ranking item) | Soft-delete its media references; assets become unreferenced when refcount hits 0 |
| Remove from gallery | Drop reference; if unreferenced, mark asset soft-deleted (or `unreferencedAt`) |
| 30 days after soft-delete | **Permanent** delete locally + remote Storage object (when uploads were used) on all devices that learn the purge |
| Parent + images | Same clock: journal page and its images purge together after 30 days |

Unreferenced files are **not** deleted immediately; they follow the **30-day** unreferenced/soft-delete window, then purge.

---

## UI

### Lightbox / viewer

- Dimmed scrim; image centered; zoom in/out (pinch / scroll / controls as platform-appropriate).
- Tap outside or Esc closes.
- **Swipe:** ordered by the parent’s gallery (`sortOrder`). Opening image **B** in `[A,B,C]` starts on B; swipe left → A, right → C. Driven by dragging the picture itself (mouse included) or by the arrow keys; a magnified image keeps the drag for its own panning.
- The neighbouring image is read and decoded while the viewer is standing still, so it is a picture the moment the slide starts rather than one that arrives after it. Only the neighbour: a viewer opened on forty images must not read forty files.
- Actions: **Copy image**, **Save as…**.

### Progress / badges

- Per-image and/or parent-level **pending upload / download** indicators.
- Settings: **storage usage** for media cache (bytes used, counts).

### Low disk

- If free local storage **&lt; 5%**, warn the user (and ideally discourage / pause prefetch until acknowledged). Exact copy and whether new attaches are blocked is an implementation choice; warning is required.

---

## Settings (summary)

1. **Remote image uploads** — enable/disable cloud saves (off ⇒ local-only forever).
2. **Background offline image prefetch** — enable/disable automatic download of all synced images.
3. **Remote image downloads** — enable/disable any image download; off ⇒ “Download disabled” when bytes missing.
4. **Storage usage** display (and entry point to understand cache size).
5. Low-disk **&lt; 5%** warning behavior.

---

## Import / export

- Full app data export **includes image binaries** (and media metadata / references).
- Import restores binaries + references so images round-trip.
- Same rules apply for all features that use the media module (journal, todo, study, rankings when present).

---

## Modular integration checklist (adding images to a new page)

1. Pass `collection` + `documentId` (+ `facet` when the parent has more than one gallery) into the shared widgets/services.
2. Pick a presentation: strip, fan, or card face.
3. Wire paste/DnD only on image-capable foci.
4. Ensure parent soft-delete / export paths include media refs (usually automatic if GC is refcount-based and export walks `MediaReference`).
5. No new Storage or queue code in the feature module.

---

## Security & Storage layout

- Firebase Auth uid scopes all objects: `users/{uid}/media/{contentHash}`.
- Security rules: only the owner may read/write their prefix.
- Prefer authenticated SDK access over long-lived public URLs.

---

## Platform notes

- Windows + Android (and any other shipped targets) must share ingest + cache behavior.
- HEIC conversion must run on ingest wherever HEIC can appear (typically mobile paste/files); output JPEG is what every platform renders.
- Clipboard image paste is platform-specific; shared policy above is identical.

---

## Open implementation details (non-blocking)

- Exact compress/downscale targets (quality, max edge length).
- Whether enabling uploads later bulk-queues existing `localOnly` assets (recommend: yes, behind “upload pending local media”).
- Precise badge placement per feature chrome.
- Rankings schema (out of scope beyond gallery ownership + media refs).

## Explicitly deferred

- Inline images anywhere in the app (removed — see STUDY_IMAGES.md)
- Thumbnails in lists (study's deck grid does show the image of a face that has no text)
- Captions / alt text
- Rotate on ingest
- Camera
- GIF
- Journal gallery laid out under the entry (the fan in the body's corner is what shipped)
