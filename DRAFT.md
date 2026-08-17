# LeetCode Track Modal — Local Draft Spec

Local-only auto-draft for the **create** Track flow so exiting the modal does not lose in-progress work. No remote sync. No draft for Edit.

Status: implemented (2026-08-16). See `leetcode_track_draft.dart`,
`leetcode_track_draft_store.dart`, `leetcode_track_modal.dart`,
`leetcode_actions.dart`, `leetcode_loading_toast.dart`, and
`test/leetcode_track_draft_test.dart`.

---

## Goals

- If the user starts a new Track form and makes any change vs the opening baseline, closing the modal keeps that work in a single local draft slot.
- Clicking Track **always** runs the existing “latest accepted submission” GraphQL fetch when a username is set (draft or not). The fetch decides whether to open the draft or a fresh prefilled form.
- Match key for resume: **problem title** (draft title vs GraphQL latest-solved title). See [Open flow](#open-flow-startleetcodetrackflow).
- At most **one** draft exists at a time.
- Drafts never leave the device and never enter the LeetCode problems table / sync pipeline.
- Toasts explain resume / mismatch and offer clear-or-continue actions (see [Draft toasts](#draft-toasts)).

## Non-goals

- Drafts for Edit (`existing:` path).
- Multi-draft history or a draft list UI.
- Syncing drafts across devices.
- Showing drafts on the dashboard, review deck, cram, or analytics.
- Skipping GraphQL just because a draft exists.

---

## Entry points

| Entry | Draft behavior |
| --- | --- |
| Track button / review-deck empty CTA → `startLeetCodeTrackFlow` | Create-only. Runs GraphQL (when possible), then chooses draft vs fresh prefill + draft toast. |
| `showLeetCodeTrackModal(..., existing: problem)` from Edit | **Ignore draft entirely** — never read, write, or clear. |
| In-modal LeetCode search / Retrack while creating | Create-mode; keep all typed field values; draft autosave still applies once started. |

---

## Storage

- **Local only** — not Drift `LeetCodeProblems`, not Firestore, not outbox.
- Suggested shape: one JSON blob on disk under app support (or equivalent local key-value), single key e.g. `leetcode_track_draft`.
- Cap: one slot. Writing a draft always overwrites that slot.
- Payload rebuilds the create form **1:1 for every field** (metadata + every solution/example row, including blank added rows, difficulty, language selectors, hidden slug/questionId):
  - Metadata: title, questionFrontendId, tags text, description, examples[], difficulty, titleSlug, questionId
  - Solutions: full list of groups (algorithm, complexities, explanation, language, code, notes), preserving row count/structure
  - Bookkeeping: `savedAt` (UTC), schema/version int for forward compat
- Corrupt / unreadable blob → treat as no draft (delete slot, open normal Track flow).

Drafts are **not** `LeetCodeProblem` rows. Reuse JSON field shapes where convenient, but keep a dedicated draft DTO so SRS fields (`interval`, `ease`, `dueAt`, …) are never implied.

**Title used for matching** is the draft’s stored **problem name** string (what the user last had in the title field), compared to the GraphQL latest-accepted question’s title. Proposed compare: trim + case-insensitive. (If you want slug/`questionId` as a secondary key later, call that out; v1 is title-only per product.)

---

## What counts as “started” (dirty → may persist)

**Rule:** after the create modal finishes its initial populate for this open (GraphQL prefill, restored draft, or empty form), snapshot that full form state as **baseline**.

The form is **started** if **anything** diverges from baseline, including:

- Any text field change (prefilled or empty) — title, ID, tags, description, examples, solution boxes, etc.
- Difficulty pill change
- Code language selector change
- Adding an example or solution row (even if the new boxes are still blank)
- Removing a row that changes structure vs baseline

**Not started:** open and close with zero changes → do **not** write the draft slot (leave any previous draft untouched).

Once started, debounced autosave / close flush writes the **entire** current form into the one draft slot.

### Baseline refreshes

Re-snapshot baseline after:

- Initial open (prefill, draft hydrate, or empty)
- User chooses **Clear draft → start new** and the modal is refilled from a fresh GraphQL result
- Optionally after in-modal search/retrack applies API fields — **without** wiping typed values the user already has (see below). Dirty detection then continues vs the post-apply snapshot, *or* vs original open baseline; pick one in implementation and keep it consistent. Preferred: re-baseline after search/retrack so “started” means further edits after that apply, while still immediately marking started if search/retrack itself changed anything vs the prior baseline (it almost always will).

---

## Persistence timing

1. **Debounced autosave** while the modal is open (~300–500ms after a started change).
2. **Flush on close** — X, barrier dismiss, route pop, and app lifecycle via `PendingFlushRegistry`.
3. **Overwrite** the single slot on every flush while started.
4. **Clear the slot** when:
   - create-mode Save succeeds, or
   - user confirms **Clear draft** from the draft toast (and proceeds to a fresh entry), or
   - on close flush, the form is **empty enough** (see [Empty-enough rule](#empty-enough-rule)) — clear rather than writing a hollow draft

Never push the draft through `remoteSyncService` / `pushLeetCodeProblem`.

Primary “start fresh” paths (product intent): in-modal **Retrack**, manually clearing fields, and the toast **Clear draft** action — not a separate multi-draft system.

---

## Open flow (`startLeetCodeTrackFlow`)

GraphQL (latest accepted submission) **always runs** when a username is configured, whether or not a draft exists. The fetch is used to decide what to open and which toast to show.

```
User clicks Track
  └─ show existing “Fetching your latest submission…” toast
  └─ username missing?
        ├─ YES → treat like fetch failure (see below)
        └─ NO  → GraphQL latest accepted submission
              ├─ SUCCESS
              │    ├─ draft exists AND titles match (trim, case-insensitive)
              │    │     → open modal hydrated from DRAFT
              │    │     → show “resumed draft” toast (+ Clear draft)
              │    ├─ draft exists AND titles do NOT match
              │    │     → open modal with GraphQL PREFILL (fresh entry)
              │    │     → show “draft available” toast (offer Continue with draft)
              │    └─ no draft
              │          → open modal with GraphQL PREFILL (today’s behavior)
              │          → no draft toast
              └─ FAILURE (network/API) OR no accepted submission
                    ├─ draft exists → open DRAFT
                    │                 → show resumed-due-to-fetch-failure style toast
                    │                   (+ Clear draft → retries fresh flow)
                    └─ no draft → open empty modal (today’s failure path)
```

### Title-match example (product intent)

1. User tracks problem A (GraphQL prefills “Two Sum”), changes the title field to “Three Sum”, types notes → draft saved with title “Three Sum”.
2. Later they solve “Three Sum” on LeetCode and click Track.
3. GraphQL returns latest solved = “Three Sum”, which **matches** the draft title → open the draft (not a blank Three Sum prefill).

If instead GraphQL returns a different title than the draft’s stored title → open the new prefill, and toast offers continuing the old draft.

### Hydration

- Rebuild **every** field from the draft blob (full form snapshot).
- After hydrate (or after fresh prefill), capture baseline for dirty detection.

Edit path unchanged: `showLeetCodeTrackModal(..., existing:)` never consults the draft store.

---

## Draft toasts

Use the same visual family as the current LeetCode loading toast (`showLeetCodeToast`), extended for actions + hover linger.

### Timing / hover

- Toast remains visible for a default dwell (exact ms TBD; same ballpark as today’s ~2.6s failure toasts, or slightly longer for action toasts).
- If the pointer **hovers** the toast, it stays up.
- After hover ends, it stays for an additional short linger, then dismisses.
- Actions on the toast dismiss it when clicked (after performing the action).

### A — Titles match → draft opened

- Message: draft was resumed (wording TBD).
- Action: **Clear draft and start new**
  - Clears the local draft slot.
  - Re-runs GraphQL for latest submission (again) and replaces the modal contents with that fresh prefill (or empty on failure).
  - New baseline after refill; user is not “started” until they change something again.

### B — Titles do not match → fresh GraphQL form opened, draft still on disk

- Message: a draft exists for another title; ask whether to continue with it (wording TBD).
- Action: **Continue with draft**
  - Replaces the modal contents with the draft hydration (does not clear the slot).
  - May switch the toast to the “resumed” variant (A) including Clear draft.
- Doing nothing / letting the toast expire → stay on the fresh GraphQL prefill; **old draft remains** on disk until overwritten by a started save on this new form, cleared via Clear, or successful Save.

### C — GraphQL failed (or no username / no submission) and draft opened

- Message: could not refresh latest submission; showing your draft (wording TBD).
- Action: **Clear draft and start new** (same as A: clear slot, retry fetch / empty form).

### Fetch toast vs draft toast

Keep the existing “Fetching your latest submission…” toast for the network wait. When the fetch settles, dismiss it and show the draft toast (A/B/C) when applicable. Avoid stacking two permanent toasts.

---

## Close / discard / replace

| Event | Draft slot |
| --- | --- |
| Close create modal, form never “started” | Leave slot unchanged (do not write). |
| Close create modal, form “started” and **not** empty enough | Write/overwrite slot with full form snapshot. |
| Close create modal, form “started” but **empty enough** | **Clear** the slot (decision C). |
| Successful create Save | Clear slot. |
| Toast **Clear draft and start new** | Clear slot, then refill from new GraphQL (or empty). |
| Toast **Continue with draft** | Keep slot; hydrate UI from draft. |
| Edit modal Save / close | No draft interaction. |

If the user opens a **mismatched** fresh prefill and then edits it (started), the next flush **overwrites** the previous draft — one-slot cap — unless the new form is empty enough on close, in which case the slot is cleared.

### Empty-enough rule

On close (and any final flush), if there is **no meaningful content left**, clear the draft slot instead of persisting a hollow blob.

**Meaningful content** means any non-blank text in any text field (title, ID, tags, description, examples, algorithm, complexities, explanation, code, notes, …), after trim. Structural leftovers alone do **not** count:

- Default/empty solution row(s) with no text
- Extra blank example/solution rows the user added
- Difficulty / language left at whatever value (even if changed earlier) **without** any text — still empty enough if all text is blank

So: wipe all text → close → slot cleared → next Track is a normal GraphQL (or empty) open with no resume toast.

If any text remains, the full form snapshot is saved as usual (including blank rows, difficulty, languages).

---

## Interactions inside the create modal

### Search (pick another problem)

- Apply API metadata as today.
- **Keep all typed text** already in the form (solution boxes, notes, any fields the apply doesn’t overwrite).
- Draft payload always includes every field; once started, flushes store the merged state.

### Retrack

- Same spirit: refresh LeetCode-owned metadata; leave user writing in place where today’s retrack already does.
- User can manually delete fields if they want a clean slate without using Clear draft.

### Add / remove rows

- **Add** example/solution row ⇒ immediately **started** (even if blank).
- Remove row ⇒ started if structure/content ≠ baseline.

---

## Implementation sketch (for later)

1. Local store module — load / save / clear JSON (`leetcode_track_draft_store.dart` or similar).
2. Draft DTO = full form snapshot + `savedAt` + version.
3. Extend LeetCode toast helper for action button(s) + hover linger.
4. `startLeetCodeTrackFlow` — always fetch when possible; title-match branch; show A/B/C toast; wire Clear / Continue.
5. `_TrackModalState` (create only) — baseline, dirty = any delta, debounce save, flush registry, clear on successful `_save`, support external “replace contents with draft / with prefill” for toast actions.
6. Tests: title match/mismatch, fetch fail → draft, started = any baseline delta incl. difficulty/language/add-row, overwrite one slot, edit path isolation, toast actions, corrupt blob.

Rough effort: **medium** — logic is still local-only, but match branching + interactive toasts add UI/state work beyond a silent prefs draft.

---

## Test cases (acceptance)

- [ ] Prefill only, no changes, close → draft slot unchanged; next Track still fetches GraphQL.
- [ ] Any baseline change (title-only, difficulty, language, add blank row, code, …), close → draft saved with full form.
- [ ] Draft title matches GraphQL latest → open draft + resumed toast with Clear draft.
- [ ] Draft title differs from GraphQL latest → open GraphQL prefill + toast offering Continue with draft; ignoring toast leaves draft on disk.
- [ ] Continue with draft swaps modal to draft; Clear draft clears slot and re-fetches GraphQL into a fresh form.
- [ ] GraphQL fails / no username and draft exists → open draft + failure/resume toast.
- [ ] User changes draft title to X, later solves X on LeetCode → title match opens that draft.
- [ ] Save create succeeds → draft cleared.
- [ ] Edit existing problem never reads/writes draft.
- [ ] Started edit on a mismatched fresh form overwrites the previous draft slot.
- [ ] Wipe all text (even with extra blank rows / changed difficulty) then close → draft slot **cleared**; next Track has no resume.
- [ ] Wipe some but leave any text → draft still saved with full snapshot.
- [ ] Toast hover prevents dismiss until hover-out + linger.
- [ ] App background/kill after typing → draft still present (flush path).
- [ ] Corrupt draft → ignored; normal Track flow.

---

## Open questions

None — product decisions are locked. Toast copy and exact dwell/linger milliseconds can be chosen at implementation time.

---

## Decision log

| Date | Decision |
| --- | --- |
| 2026-08-16 | Create-only; one local draft; no sync. |
| 2026-08-16 | GraphQL latest-submission fetch **always** runs when possible; used to choose draft vs fresh prefill. |
| 2026-08-16 | Resume when draft title matches GraphQL title (trim, case-insensitive); on fetch failure, prefer draft if present. |
| 2026-08-16 | Mismatch → open GraphQL prefill; toast offers Continue with draft. Match → open draft; toast offers Clear draft → re-fetch GraphQL. |
| 2026-08-16 | Started = **any** change vs baseline (text, difficulty, language, add row). |
| 2026-08-16 | Draft stores **every** field; search/retrack keep typed text. |
| 2026-08-16 | Draft toasts: dwell + hover hold + post-hover linger; action buttons as above. |
| 2026-08-16 | **Empty-enough (C):** on close, if all text fields are blank (trim), clear the draft slot even if blank rows / difficulty / language remain. |
