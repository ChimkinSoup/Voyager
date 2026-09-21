# Session Resume — High-Level Design

Incomplete Study and Cram sessions (LeetCode **and** Study flashcards) survive any exit — app kill, Back to deck, navigation away — until the user finishes the queue or explicitly discards via a resume toast. On the next Study / Cram entry for that scope, Voyager offers to restore the prior run with full draft state (queue position, undo/redo history, and for LeetCode scratch code when enabled).

North star: leaving mid-session never throws away work. Resume is opt-in via toast; Start over is one tap away **on that toast** and rebuilds from live SRS / current deck membership.

This document locks product decisions from the 2026-09-20 design review. It is a high-level design, not an implementation checklist.

Related: `LEETCODE_SCRATCH_PAD.md` (current session-scoped scratch + crash recovery — **superseded for lifecycle** by this HLD; scratch payload shape is reused), `lib/features/study/study_session_page.dart`, `lib/features/study/study_cram_page.dart`, `lib/features/leetcode/leetcode_session_page.dart`, `lib/features/leetcode/leetcode_cram_page.dart`, `lib/features/leetcode/leetcode_scratch_session.dart`, Jobs / Track draft stores (device-local JSON pattern).

Status: **implemented** 2026-09-20.

---

## 1. Goals

- Persist **incomplete** sessions across every exit path, not only crashes.
- On next Study or Cram open for the same scope, show a toast: user is **resuming**; offer **Start over**.
- Restore **queue / buckets**, **session undo/redo navigation history**, and (LeetCode only, when enabled) **scratch drafts** (code, language, expanded/collapsed).
- Card face always lands on **front** after resume.
- When the live due / membership set has grown, **keep remaining queue order** and **append a shuffled tail of new cards**. Deleted cards drop out of the restored queue and history.
- **Start over** = discard checkpoint and open a fresh session: shuffle **all** currently eligible cards (including newcomers), using **live SRS** values — same spirit as reshuffling the deck today.
- Keep forever until finished or discarded. **Device-local only** — no Firestore sync.
- Cover four surfaces: LeetCode Study, LeetCode Cram, Study Session, Study Cram.

### Non-goals (v1)

- Syncing checkpoints across devices.
- Persisting Vim undo stacks or caret position inside the scratch editor.
- Persisting which face was showing (always front).
- Auto-resume without a toast.
- Resume toast on Review Deck / Hub browse — only when the user actually opens Study or Cram.
- Replaying grades that were never written to disk (grades already commit on each rate; see §4.3).
- Changing SRS algorithms, cram bucket rules, or grading UX beyond restore / discard.
- One global “any incomplete session” badge outside the Study / Cram entry flow.

---

## 2. Product decisions (locked)

| Decision | Choice |
|----------|--------|
| **Surfaces** | LeetCode Study + Cram; Study Session + Cram. |
| **Incomplete exit** | Any leave that is not “session finished”: Back to deck / ✕ / route pop / app kill / process death. |
| **Finished** | Queue empty with nothing left to undo into (Study complete screen → done), or Cram all-in-bucket-2 complete → done. Clears checkpoint. |
| **Resume UX** | Toast on Study / Cram open when a checkpoint exists for that scope. Copy makes clear this is the previous session. Primary continue is implicit (hydrate and proceed). Explicit **Start over** button on the toast — and nowhere else; see §7. |
| **Start over** | Delete checkpoint; build a brand-new session from the **current** eligible set (due / filtered visible / deck roster), shuffled — same as today’s fresh open, including new cards. Does **not** reverse grades already committed this session. |
| **Card face** | Always front on resume (and after Start over). |
| **Scratch** | LeetCode only, when `leetCodeEnableScratchCode`. Same per-problem entries as today’s scratch session. Study flashcards: no scratch fields. |
| **Stale membership** | Drop missing ids; append shuffled **new** eligible ids to the end of the remaining queue (Study) or into cram bucket 0 (Cram). |
| **TTL** | No expiry. Survives until finish or Start over / Discard. |
| **Storage** | Device-local JSON files (Track / scratch draft store pattern). Not synced. |
| **Scratch lifecycle change** | Incomplete exit **keeps** scratch with the session checkpoint. Normal finish / Start over / discard **wipes** scratch for that session. Crash-only orphan recovery in `LEETCODE_SCRATCH_PAD.md` is replaced by this unified resume toast. |

---

## 3. Why undo/redo needs grade steps (Study)

Study and LeetCode **Study** undo is not “go back one card index.” Each undoable step is a `_GradeStep`:

- SRS snapshot **before** and **after** the grade  
- Review-log row (tombstone on undo, revive on redo)  
- Full **queueBefore** / **queueAfter** (so Fail re-queue is undoable)

Those grades are **already written** to the DB when the user rates a card. Persisting the step list does not re-grade on resume; it preserves the ability to **reverse / re-apply** the same mutations after the app restarts.

**Cram** is different: `_CramStep` is only bucket id lists. No SRS, no review log. Persist bucket snapshots only.

**Conclusion:** v1 **does** persist Study grade-step history (before/after + log identity + queue snapshots). Skipping that would make undo after resume lie or no-op. Cram history stays bucket-only.

---

## 4. Checkpoint model

### 4.1 Scope keys

One active incomplete checkpoint per scope. Opening Study must not steal Cram’s checkpoint and vice versa.

| Kind | Scope key (conceptual) | Built from |
|------|------------------------|------------|
| `leetcodeStudy` | Fixed kind (deck is the filtered Review Deck set at session start; see §5) | `problemIds` snapshot + queue |
| `leetcodeCram` | Fixed kind | same |
| `studySession` | `hub` **or** `deck:<deckId>` (use `frameDeckId`; hub when null) | `cardIds` + queue |
| `studyCram` | `deck:<deckId>` | `deckId` / `cardIds` + buckets |

Entering Study on Hub never offers a deck workbench checkpoint, and vice versa. LeetCode Study vs Cram never share a file.

### 4.2 Shared envelope

```text
SessionCheckpoint
├── version: int
├── kind: leetcodeStudy | leetcodeCram | studySession | studyCram
├── scopeKey: string
├── sessionId: uuid
├── startedAt / updatedAt: DateTime UTC
├── sourceIds: Set<id>          // membership when session opened (or last reconciled)
├── remainingQueue: List<id>    // Study: head = current card
│   OR buckets: {0,1,2: List<id>}  // Cram
├── graded: List<GradeStepDto>  // Study only
├── undone: List<GradeStepDto>  // Study only
├── decided: List<CramStepDto>  // Cram only
├── undoneCram: List<CramStepDto>
└── scratch?: LeetCodeScratchSession blob  // LeetCode only; omit / null for Study
```

`GradeStepDto` stores enough to rebuild `_GradeStep`: before/after serializations (or id + versioned SRS fields), review-log id + payload needed to tombstone/revive, and queue id lists (resolve to live rows on hydrate via `refreshFromLive`).

`CramStepDto`: three id lists.

Scratch blob: reuse `LeetCodeScratchSession` shape from `LEETCODE_SCRATCH_PAD.md` (per-problem code / language / expanded, `lastLanguage`, etc.). Checkpoint **owns** scratch lifecycle; do not keep a parallel orphan-only scratch file with different semantics.

### 4.3 What is not in the checkpoint

- Card face (always front).  
- Vim undo / selection / scroll.  
- In-flight swipe animation / grading lock flags.  
- Fresh “re-apply all grades” — disk already has them.

---

## 5. Lifecycle

```text
Open Study/Cram for scope
        │
        ├─ no checkpoint → fresh session (today’s behavior)
        │
        └─ checkpoint exists → show resume toast
                ├─ Continue (default / dismiss-as-continue) → hydrate §6
                └─ Start over → delete checkpoint → fresh shuffle of live eligible set
```

### Persist triggers

Debounced write on: grade / cram decide, undo, redo, queue mutation, scratch edit (existing 400 ms), problem advance, and **flush on every incomplete dispose** (Back, ✕, route pop).

App pause is not a dispose — the page stays alive and the process can be killed from there without ever waking up. The checkpoint controller registers with `PendingFlushRegistry`, the same hook the Track and journal drafts use, so a pause flushes whatever the debounce is still holding.

### Clear triggers

- Session finished (complete → leave).  
- Start over.  
- Explicit Discard if toast ever exposes it as separate from Start over (v1: Start over is enough).  
- Hydrate finds checkpoint unusable (corrupt / unknown version) → delete and fresh session + quiet failure or single error toast.

### Relationship to today’s scratch wipe

`LEETCODE_SCRATCH_PAD.md` says normal exit deletes scratches; crash leaves an orphan. **This HLD reverses that for incomplete exits:** Back to deck keeps the checkpoint (including scratch). Only finish / Start over / discard clears it.

---

## 6. Hydrate (Resume)

1. Load checkpoint for kind + scope.  
2. Resolve ids against live data (`refreshFromLive` / problem map).  
3. **Drop** ids that no longer exist. Prune grade/cram steps that reference only missing cards; drop empty steps as needed so undo stays coherent.  
4. Compute **newcomers**: currently eligible ids not in `sourceIds` ∪ remaining queue/buckets.  
5. **Study:** keep `remainingQueue` order (minus dropped); **append** newcomers in a fresh shuffle (`sessionShuffleRandomProvider` or equivalent).  
6. **Cram:** keep bucket membership for surviving ids; append newcomers to **bucket 0**, shuffled among themselves (or shuffled into the end of bucket 0 — pick one and keep it consistent in implementation).  
7. Restore `graded` / `undone` or `decided` / `undoneCram`.  
8. Restore scratch map if LeetCode + setting on; if setting off, keep scratch on disk but do not show pad until enabled (or drop scratch UI only — prefer keep data so toggling on later in a future session still has drafts; v1 simplest: restore into controller only when setting is on, else leave blob in checkpoint untouched).  
9. Set flip to **front**.  
10. Update `sourceIds` to the reconciled set and flush.

Eligible set for newcomers / Start over:

| Surface | Eligible |
|---------|----------|
| LeetCode Study | Due problems within the entry’s `problemIds` filter (same as `_syncQueue` today) |
| LeetCode Cram | Problems in the entry’s `problemIds` still present |
| Study Session | Due cards within the entry’s `cardIds` |
| Study Cram | Cards in the cram roster for that deck |

---

## 7. Resume toast UX

- Show once when the session route opens and a checkpoint was loaded (or offered).  
- Copy (directional): *Resuming your previous session* (optional: card count left).  
- Action: **Start over** — discards checkpoint and rebuilds a fresh shuffled session from the live eligible set (includes new cards).  
- Continuing is the default path: hydrate already applied before or as the toast shows so the user sees the restored card immediately.  
- **The toast is the only way to discard.** It dwells ~10 s; once it goes, the round is the one the user is in, and the ways out are finishing it or re-entering to catch the toast again. This is deliberate — discarding a session is a destructive act aimed at the moment of *"this isn't the round I wanted"*, not a control to leave sitting in the session chrome where a mis-tap costs a round's progress. A resumed round is also never a trap: it is always finishable, and Start over is one re-entry away. No persistent Start over / Discard affordance in the session UI, the Review Deck, or the Hub.  
- Follow existing Voyager toast patterns (`showVoyagerToast` / soft-delete style action chip). Do not block the session behind a modal.  
- Escape / session keybinds unchanged; toast is non-modal.

---

## 8. Architecture sketch

### Modules (expected)

| Piece | Role |
|-------|------|
| `session_checkpoint.dart` | DTOs + versioning |
| `session_checkpoint_store.dart` | File read/write/clear per kind+scope; memory fake for tests |
| `session_checkpoint_controller.dart` | Debounce, envelope, discard; owns the `PendingFlushRegistry` registration so all four surfaces get the pause flush from one place |
| Session pages (4) | Serialize on mutation / dispose; hydrate on init when Continue |
| Entry points (Review Deck, Hub, Deck Workbench) | Unchanged navigation; pages own detect + toast |
| Scratch host / session | Checkpoint embeds scratch; retire orphan-only recovery toast in favor of §7 |

Prefer **one store abstraction** with four filenames or a small directory keyed by `kind_scopeKey`, not four divergent stores.

### Ownership

Checkpoint controller lives with the session page (same as today’s scratch session ownership), not a global “always watching” provider. Entry points do not need to know resume details beyond navigating to the same pages they already open.

### Concurrency

Single writer per file; chain writes like Track draft (debounce must not race dispose flush). No cross-device merge.

---

## 9. Edge cases

| Case | Behavior |
|------|----------|
| User graded mid-session, left, Start over | Prior grades stay on disk; new queue = currently due under live SRS |
| User graded, left, Resume, Undo | Undo uses restored grade steps; SRS + log return to `before` |
| Problem/card deleted while away | Dropped from queue/buckets/history; resume continues |
| New due cards while away | Appended shuffled to end (Study) / bucket 0 (Cram) |
| Filter changed on Review Deck | Scope is the new `problemIds` at entry; if checkpoint kind matches but source set is unrelated, still resume surviving overlap + append new eligible under **current** filter (treat filter as eligible set). If zero overlap and empty remaining after prune, treat as fresh-worthy: toast Start over strongly, or auto-clear — prefer show toast with empty-ish session avoided by falling through to Start-over-equivalent if remaining queue empty and no undo stack |
| Scratch disabled, LeetCode resume | Restore queue/history; no pad UI |
| Hub session vs deck session | Different `scopeKey`; never cross-offer |
| Two incomplete kinds (Study + Cram) | Both may exist; each entry point only sees its kind |
| Corrupt JSON | Delete file; fresh session |
| Complete screen with undo still possible | Still incomplete until user leaves without undo stack needing the checkpoint — same as today: keep checkpoint until route pop after true done, or clear when queue empty **and** user confirms done. Prefer: clear when leaving complete with empty graded-need — match current “session complete” leave |
| App pause mid-grade | Flush after grade completes; in-flight `_grading` not checkpointed |

---

## 10. Testing (acceptance)

- Leave mid Study (LeetCode + Study) via Back; reopen → toast; land on same card index; undo still reverses last grade.  
- Leave mid Cram; reopen → buckets restored; undo/redo decisions work.  
- Scratch code + language + expanded restore on LeetCode when setting on.  
- Face is front after resume.  
- Add a new due card while away → appears at end (Study) / bucket 0 (Cram), shuffled among newcomers only.  
- Delete a queued card while away → skipped; no crash.  
- Start over → new shuffle of full live eligible set; checkpoint gone; scratch cleared.  
- Finish session → no toast next time.  
- Device-local: no sync payload fields.  
- Hub vs deck checkpoints do not collide.  
- Study flashcard sessions never require scratch fields in the file.

---

## 11. Migration / supersession

- Supersedes the **orphan-only crash recovery** UX in `LEETCODE_SCRATCH_PAD.md` (§Storage recovery toast). Incomplete sessions are first-class; the resume toast in §7 is the single user-facing recovery.  
- Existing on-disk scratch orphan files (if any) may be one-shot imported into a checkpoint or discarded on first run after ship — implementation choice; document in the PR. Prefer discard-with-optional-import only if cheap.  
- No DB schema / Firestore migration (device-local files only).

---

## 12. Open implementation notes (not product locks)

- Exact toast copy and whether Continue is an explicit button vs dismiss-to-continue.  
- Whether newcomers shuffle uses a seeded RNG stored in the checkpoint for reproducibility in tests.  
- Whether `GradeStepDto` stores full problem/card JSON or id + SRS field deltas (full snapshots are simpler and match in-memory `_GradeStep`).  
- Complete-screen timing for `clearCheckpoint` vs “undo from complete still works after process death” — if that edge matters, keep checkpoint until the complete route is popped.
