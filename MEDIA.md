# Media / Images — High-Level Design

## Status

Accepted design (pre-implementation). Captures product decisions from the media design discussion.

## Goals

- Add first-class image support via a **shared media module**, not feature-specific upload code.
- Surfaces in v1: **Journal** (inline), **Todo** (main tasks only, gallery strip), **Study** (inline on front/back; not LeetCode), and a future **Rankings** page (gallery only — e.g. restaurant food photos).
- Images sync across devices with offline queueing; devices download bytes so content remains usable offline after the last successful sync.
- Paste (`Ctrl`/`Cmd+V`), drag-and-drop, and (galleries only) file picker — no camera.
- Full-screen / lightbox viewer with zoom and ordered swipe.
- Import/export of all app data includes image binaries.
- User settings for remote upload, background offline prefetch, and on-demand remote download, plus low-disk warning.

## Non-goals (v1)

- Captions / alt text
- List / deck thumbnails
- Rotate-before-save
- Camera capture
- GIF support
- Images on todo subtasks, todo notes (inline), LeetCode, or journal attachment galleries
- Max image count per parent

---

## Architecture overview

```
┌─────────────────────────────────────────────────────────────┐
│ Features (journal / todo / study / rankings)                │
│  - Inline embed renderer + paste hooks                      │
│  - Gallery strip widget                                     │
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

Embed syntax (Obsidian-like) uses the media id, not a URL:

```text
![[media:<mediaId>|<widthPx>]]
```

Example: `![[media:a1b2c3d4|480]]`

---

## Per-surface behavior

| Surface | Placement | Paste / DnD | File picker |
|---|---|---|---|
| Journal body | Inline at caret (text above/below) | Yes | No |
| Journal title | Text only | Text only; image-only clipboard → no-op | — |
| Todo main task | Gallery strip on edit panel | Onto strip / panel (not into notes) | Yes |
| Todo notes / title / subtasks | No images | Text only; image-only → no-op | — |
| Study card front / back | Inline in that side’s text | Yes when that field focused | No |
| Rankings (future) | Gallery only (not inline) | Onto gallery | Yes |

### Clipboard rules

| Focus | Clipboard | Result |
|---|---|---|
| Image-capable field | Text | Paste text |
| Image-capable field | Image | Paste / insert image |
| Image-capable field | Text + image | Paste **both** (text + image embed / gallery add) |
| Non-image field | Text or text+image | Paste **text only** |
| Non-image field | Image only | **No-op** |
| Nothing relevant focused | Any | **Ignore** |

### Inline vs gallery

- **Inline:** embed token in text; rendered as a block image at the token’s position; width from `|widthPx`.
- **Gallery:** ordered list of `MediaReference`s on the parent; strip UI; no file-picker clutter in inline editors.

The media module supports both modes; each feature opts into one.

---

## Data model

### `MediaAsset` (blob, deduped)

One row per unique content hash per user account (local DB; mirrored metadata in Firestore as needed).

| Field | Notes |
|---|---|
| `id` (`mediaId`) | Stable UUID used in embeds and refs |
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
| `facet` | Optional: `front` \| `back` \| `gallery` \| `inline` |
| `sortOrder` | Gallery / swipe order |
| `displayWidthPx` | For gallery items; inline width lives in the embed token |
| `createdAt` / `deletedAt` | Soft-delete with parent or when unreferenced |

Inline embeds in text are the **canonical** placement for journal/study; references still exist so sync, GC, swipe order, and progress badges have a structured index. Creating an inline embed creates/updates a reference; removing the last embed/ref starts unreferenced retention.

### Parent documents

- **Journal / study:** body (or front/back) may contain `![[media:…\|width]]` tokens. CRDT/text sync carries tokens like any other characters; binary bytes sync via the media pipeline.
- **Todo / rankings:** no inline tokens; gallery = reference list only.

---

## Ingest pipeline

1. Accept bytes from paste, drag-and-drop, or file picker (gallery only).
2. **Reject** if decoded size **> 10 MB** (pre-compress). Show warning: image too large; do not attach.
3. Allowed inputs: **PNG, JPEG, WebP, HEIC**. **No GIF.**
4. **HEIC → JPEG** on ingest; do not keep the HEIC original.
5. **Auto compress / downscale** to a sensible max dimension (implementation detail; target: good quality on phone + desktop, stay under 10 MB post-ingest).
6. Hash post-ingest bytes → dedupe → write local file → create/reuse `MediaAsset` → create `MediaReference` → insert embed or append to gallery.
7. If **remote upload** setting is on → enqueue upload. If off → `uploadState = localOnly` forever (until setting enabled and a future re-queue policy is run — v1: new/queued uploads only while setting is on; local-only assets stay local unless user re-enables and triggers sync repair).

### Display width

- Default: `min(imageWidth, 480)` px.
- User-resizable via `|widthPx` token and/or hover chrome.
- Hard cap: `min(editorWidth, 1200)` px.

### Inline image chrome

- Hover (pointer) shows a **small control icon** top-right on the image.
- Click opens an editor for image aspects (at least: width; **replace image** keeping position / width when possible).
- `|widthPx` remains editable in source text where the editor exposes raw text.

### Replace image

- Picks/ingests a new blob (or reuses deduped asset).
- Keeps embed position and display width when replacing inline; keeps gallery slot and width when replacing in a strip.

---

## Sync & offline

### Upload queue

- Independent of Firestore document outbox (`PendingUploadsTable`), but drained on the same connectivity lifecycle.
- Persist pending uploads locally; retry with backoff; surface **progress** and **pending sync** badges on the image / parent.
- Metadata (asset row + references + embed tokens in parent docs) still syncs through existing document sync so other devices learn that an image exists.

### Download / prefetch

Default product intent: **all images for all synced docs** end up local after sync, subject to settings:

| Setting | Effect |
|---|---|
| **Remote image uploads** | Off → never upload; images stay **device-local forever**. Other devices may see embeds/refs but cannot obtain bytes from this device’s cloud path. |
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
| Remove embed / remove from gallery | Drop reference; if unreferenced, mark asset soft-deleted (or `unreferencedAt`) |
| 30 days after soft-delete | **Permanent** delete locally + remote Storage object (when uploads were used) on all devices that learn the purge |
| Parent + images | Same clock: journal page and its images purge together after 30 days |

Unreferenced files are **not** deleted immediately; they follow the **30-day** unreferenced/soft-delete window, then purge.

---

## UI

### Lightbox / viewer

- Dimmed scrim; image centered; zoom in/out (pinch / scroll / controls as platform-appropriate).
- Tap outside or Esc closes.
- **Swipe:** ordered by parent’s image list (inline order in document + gallery order as applicable). Opening image **B** in `[A,B,C]` starts on B; swipe left → A, right → C.
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
- Import restores binaries + refs + embed tokens so images round-trip.
- Same rules apply for all features that use the media module (journal, todo, study, rankings when present).

---

## Modular integration checklist (adding images to a new page)

1. Choose mode: **inline**, **gallery**, or (rarely) both — rankings = gallery only.
2. Pass `collection` + `documentId` (+ `facet` if needed) into shared widgets/services.
3. Wire paste/DnD only on image-capable foci; add file picker only for galleries.
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

- Thumbnails in lists/decks
- Captions / alt text
- Rotate on ingest
- Camera
- GIF
- Journal under-entry gallery
