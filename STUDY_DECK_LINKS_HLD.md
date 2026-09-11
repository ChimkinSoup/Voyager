# Study — Deck Links HLD

Link whole study decks into another deck so their cards are **live-included** in Study / Cram sessions of the parent, with shared SRS (one card record), source-deck context on foreign cards, and workbench UI for managing links without leaving the parent.

Related: `STUDY.md` (workbench, sessions, cram, SRS, nested folders), `lib/domain/models/study_models.dart` (`StudyDeck`, `StudyCard`), `study_srs_engine.dart`, deck workbench / session pages under `lib/features/study/`.

This document **extends** `STUDY.md` for deck composition. Folder nesting rules are unchanged. Cards still have a single home `deckId`; links do **not** duplicate card rows.

Status: **implemented** (2026-09-11). Resolution lives in `lib/domain/services/study_deck_graph.dart`; link actions in `lib/features/study/study_deck_link_actions.dart`.

---

## 1. Goals

- Let a hub deck (e.g. System Design) **link** topic decks (Docker, AWS, Kubernetes) so those cards appear in the hub’s Study / Cram queues.
- Keep **one SRS state per card** — grading from the hub updates the same card as studying the source deck.
- Show **source-deck context** (live name) on cards only when they appear via a link (not on native home-deck sessions).
- Manage links from the parent workbench: placeholder rows, enable toggles, popup inspector, right-click actions (study subset, fork, visit).
- Block link cycles; allow unbounded nested links; **dedupe by card id** when the same card is reachable on multiple acyclic paths.

## 2. Non-goals (v1)

- Physical copies of cards on link (except explicit **Fork**)
- Weighted mixing by source deck
- Per-card / tag exclude lists on a link
- Linking folders (decks only)
- Always-on context for native cards
- Chrome chips / floating chrome for context (plain text on the card face only)
- Add-card / multi-select / import inside the linked-deck popup
- Bidirectional link creation UI beyond “Included in” readout on the source
- Cap on nest depth (cycles blocked instead)

---

## 3. Product decisions (locked)

| Decision | Choice |
|----------|--------|
| **Inclusion model** | **Live reference** — parent stores links to other decks; sessions resolve cards by walking enabled links. Not a snapshot copy. |
| **SRS** | Single `StudyCard` row; grade from any session writes that row. Unlink does not change SRS. |
| **Cycles** | **Forbidden** (same failsafe idea as folder moves). Nested links **allowed**, **no depth cap**. |
| **Dedupe** | Session queues + due aggregation **dedupe by card id**. |
| **Nesting** | Parent → Docker → NestedDeck: NestedDeck cards are included when Docker is enabled on the parent **and** NestedDeck is enabled on Docker (each link’s own toggle). |
| **Own + linked** | Hub may have native cards **and** links. |
| **Queue** | One shuffled pool of native + recursively resolved linked cards (enabled links only). No per-deck weights. |
| **Link toggle** | **Persistent** on the **parent** link row. Off → placeholder still visible; cards excluded from due counts and sessions until on again. |
| **Workbench list** | Linked decks appear as **placeholder rows** (same footprint as a card tile, not a flashcard). Label = linked deck name + enable toggle. |
| **Placeholder click** | Opens a **popup** inspector of that deck’s card list (edit existing cards). Does **not** navigate away; dismiss → still on parent workbench. |
| **Popup capabilities** | View list, edit card, soft-delete card, **Study / Cram**. **No** add-card, multi-select, or import. |
| **Edit / delete from composite or popup** | Writes through to the source card. **Delete = soft-delete source card**. |
| **Unlink** | Removes membership only; source deck and SRS unchanged. |
| **Delete source deck** | Soft-delete source → link disappears from composites immediately. Attempting delete warns if deck is linked from other decks (“Included in: …”). |
| **Rename source** | Context text uses **live** deck name. |
| **Due (deck workbench)** | Own cards + cards from **enabled** recursive links (deduped). |
| **Due (global hub)** | Each due card counted **once** (by card id), even if reachable via multiple hubs. |
| **Context UI** | Only when card’s home deck ≠ session’s framing deck (see §7). **Muted plain text, clear background, top-left on the card face**; survives flip (same text on front and back faces / not tied to flip side). Not a chip. |
| **Included in** | Source deck workbench shows which parents link it. |
| **Fork** | Right-click one linked-deck placeholder → copy all of that deck’s **own** cards into the parent as new native cards (new ids, **independent SRS**), then **remove the link**. One linked deck per fork. |
| **Study linked subset** | Right-click placeholder on **parent workbench only** → session framed as parent, queue = that linked deck’s effective card set only; context labels apply. |
| **Visit** | Right-click placeholder → navigate into that deck’s workbench (leave parent). |
| **Cram** | Same as today (in-memory buckets, no SRS writes). Respects enabled-link resolution + optional subset session. |

---

## 4. Domain model

### 4.1 `StudyDeckLink` (new)

Membership edge: parent deck includes child deck.

| Field | Notes |
|-------|--------|
| `id` | Link row id |
| `parentDeckId` | Hub / composite deck |
| `childDeckId` | Linked source deck |
| `enabled` | Persistent toggle on parent; default `true` |
| Soft-delete / version / timestamps | Same sync pattern as other study entities |

Constraints:

- `parentDeckId != childDeckId`
- Unique `(parentDeckId, childDeckId)` among non-deleted links
- **Cycle check** before create (and before any future “move link” if added): walk ancestors / descendants; refuse if adding the edge would create a cycle

Cards are **not** copied. No `deckId` change on link.

### 4.2 `StudyCard` (unchanged ownership)

- Still exactly one `deckId` (home deck).
- SRS fields (`interval`, `ease`, `dueAt`, `reviewCount`) remain on the card.
- “Appears in System Design” is derived from link graph + home `deckId`, not stored per card.

### 4.3 Resolution

**Effective card set** for deck `D` (for stats / Study / Cram):

1. Start with non-deleted cards where `deckId == D`.
2. For each non-deleted link `D → C` with `enabled == true`, recursively union `effectiveCardSet(C)`.
3. Dedupe by card `id` (first wins; order only matters for stable shuffle seeding if needed).
4. Soft-deleted cards / decks / disabled links contribute nothing.

Cycle guard on write means resolution need not detect cycles at runtime, but a defensive visited-deck set during walk is still recommended.

### 4.4 Move semantics (existing Move + links)

| Action | Result |
|--------|--------|
| Move card from AWS → Deck B | Card’s `deckId` becomes B. It **leaves** System Design’s effective set (unless B is also linked into System Design, or B is System Design). |
| Move card from AWS → System Design | Card becomes **native** to System Design. AWS no longer owns it; if user later disables the AWS link, the card **remains** (it is owned by System Design). |
| Unlink AWS from System Design | AWS cards vanish from System Design’s effective set; AWS + SRS unchanged. |

### 4.5 Fork

For link `Parent → Child`:

1. For each non-deleted card with `deckId == Child` only (**not** Child’s further linked cards — v1 forks the child’s **own** cards; nested composition stays as links on Child if any).
2. Insert new cards with `deckId == Parent`, new ids, **fresh SRS** (baseline ease/interval/due like new cards), copied front/back (and media if study images are attached — follow existing duplicate/copy helpers if any).
3. Soft-delete (or hard-remove) the `StudyDeckLink` row.

**Clarify for implementers:** Fork does **not** flatten nested grandchildren into Parent; only Child’s native cards. Nested decks remain Child’s concern. If product later wants “fork entire tree,” that is a separate decision.

### 4.6 Delete deck warning

Before soft-deleting deck `X`, query links where `childDeckId == X` (and optionally where `parentDeckId == X`). If `X` is a **child** of other decks, warn with parent names (“Also linked from: System Design, …”). On confirm, soft-delete `X`; dependents’ resolution drops `X` immediately. Orphan link rows to deleted children should be ignored by queries and cleaned or soft-deleted with the deck.

---

## 5. Workbench UX

### 5.1 Card list composition

Scrollable list mixes:

1. **Native card tiles** (existing behavior).
2. **Linked-deck placeholders** — same approximate row footprint as a card tile; show linked deck **name**, **enabled** toggle, and affordance that it is a link (not a flashcard). No front/back flip.

Sort / placement (v1 recommendation): placeholders grouped **above** or **below** native cards as a dedicated block (implementation can pick one; prefer **below title/actions, above or integrated in list with a subtle section**). Exact visual polish follows existing study workbench language — not a new card chrome system.

### 5.2 Placeholder interactions

| Input | Behavior |
|-------|----------|
| Primary click / tap | Open **linked-deck popup** (inspector). |
| Enable toggle | Persist `StudyDeckLink.enabled`; refresh due counts / session eligibility. |
| Right-click / context menu | **Study this linked subset** · **Fork into this deck** · **Visit deck** · **Unlink** (Unlink implied by product; include unless already covered elsewhere). |

### 5.3 Linked-deck popup

- Modal / overlay over the **parent** workbench; closing returns to parent (no navigation stack change to child).
- Shows child deck name (live), card list with existing preview/edit patterns.
- Actions: open card editor, soft-delete card, **Study**, **Cram**.
- **Not** in popup: add card, multi-select batch bar, import.

**Study / Cram from popup:** session framed as the **child deck** (home session), drawing on the child’s **own cards only** — the same set the popup lists and counts. What the child links in turn is neither listed, counted nor studied in the popup; no context labels appear. After session, user should return to parent workbench with popup dismissible/restored per existing modal session patterns — prefer: closing session returns to parent; popup can be reopened.

### 5.4 Study linked subset (context menu)

- Session **framed as parent** (`sessionDeckId = parent`).
- Queue = effective card set of the **child only** (child’s native + child’s enabled nested links), not the full parent pool.
- Context text shows for cards whose home deck ≠ parent (typical for all cards in this mode).

### 5.5 Visit deck

Navigate to child workbench (same transition as opening a deck from the library). Leaves parent.

### 5.6 Included in

On a deck’s workbench header/meta area: if any parents link this deck, show quiet text e.g. `Included in: System Design, Interview Prep` (live names). Optional: tap a name to visit that parent (nice-to-have; not required for v1).

### 5.7 Adding a link

From parent workbench: control to **Link deck…** (exact control placement: control bar near Add card / import). Picker lists other decks; excludes self and any deck that would create a cycle; excludes already-linked children. Creating a link inserts a placeholder row with `enabled: true`.

---

## 6. Sessions

### 6.1 Study (SRS)

- Build queue from `effectiveCardSet(sessionDeck)` (or subset — §5.4).
- Filter due / new / learning per existing SRS session rules.
- Shuffle as today among the eligible pool (no per-source weighting).
- Grading calls existing SRS engine and persists the **same** `StudyCard`.

### 6.2 Cram

- Same effective set (or subset); in-memory buckets; **no** SRS writes — unchanged from `STUDY.md`.
- Enabled-link toggles still gate which cards enter the pool.

### 6.3 Session start toggles

Workbench `enabled` flags are the **only** persistent gate (locked). No separate session-start override UI in v1 unless already implied by “Study linked subset” / popup Study.

---

## 7. Context label

| Condition | Show context? |
|-----------|----------------|
| Studying deck D, card.home == D | **No** |
| Studying deck D (full or subset), card.home ≠ D | **Yes** — live name of `card.deckId`’s deck |
| Studying from popup as child C (own cards only, so card.home == C) | **No** |

**Presentation:** Top-left of the **card face**, both front and back (or a single overlay sibling that does not move with the flip axis — implementation detail). Plain text, transparent/clear background, muted style. Not a chip, not floating chrome outside the card.

---

## 8. Stats

| Surface | Rule |
|---------|------|
| Parent workbench due / totals | Native + enabled recursive links, **deduped by card id** |
| Global study hub due / reviewed aggregates | **Dedupe by card id** globally so one AWS card due is not counted once per hub that links AWS |
| Disabled link | Excluded from parent stats until re-enabled |

---

## 9. Sync & edge cases

| Case | Behavior |
|------|----------|
| Soft-deleted child deck | Treated as missing; no cards; placeholder removed or shown as broken then cleaned — **prefer drop placeholder** when child soft-deleted |
| Soft-deleted link | Ignored |
| Soft-deleted card | Ignored everywhere |
| Rename child | Placeholder title + context text update live |
| CRDT concurrent link create that would cycle | Last-write / version rules + cycle validation on apply; reject illegal edge |
| Orphan link (child gone) | Ignore in resolution; UI omits placeholder |
| Ghost parent folders | Unrelated; existing folder orphan rules unchanged |

---

## 10. Right-click menu summary (linked placeholder)

1. **Study this linked subset** — parent-framed session, child effective set only  
2. **Fork into this deck** — copy child’s native cards → parent, independent SRS, remove link  
3. **Visit deck** — open child workbench  
4. **Unlink** — remove link only  

---

## 11. Implementation sketch (non-binding)

- Table / Drift entity for `StudyDeckLink` + repository methods: list by parent, list parents by child, upsert, soft-delete, cycle check.
- Resolver service: `effectiveCardsForDeck(deckId) → List<StudyCard>` with visited set + enabled filter + id dedupe.
- Wire workbench list, stats providers, session queue builders through resolver.
- Context: pass `sessionDeckId` + card into `StudyCardFace` / flip card; render top-left label when homes differ.
- Tests: cycle rejection, nested enable/disable, dedupe two paths, move out of linked source, move onto parent, fork independence, global due dedupe, context visibility matrix (§7).

---

## 12. Open implementation details (non-product)

These do not change product intent; choose during build:

- Exact placeholder sort order vs native cards — **built:** placeholders lead the grid, oldest link first; a search filters them by deck name.
- Whether “Included in” names are tappable in v1 — **built:** tappable, same path as Visit.
- Fork copy of study card images / media attachments — **built:** follows Duplicate (`duplicateReferencesForOwner`).
- Popup Study session return path — **built:** the popup closes, the session opens from the parent, closing it lands on the parent.

Also settled during the build:

- **Link id** is `parentDeckId__childDeckId`, not random: the unique-pair constraint holds across devices by construction, and relinking revives the tombstone (version + 1).
- **Sync cycle** (§9): after a link pull, links are admitted oldest first (`createdAt`, then id) and any that would close a loop is tombstoned and pushed — the newest edge of each cycle, identically on every device.
- **Deck delete** tombstones the deck's links on both sides; folder delete does the same for every deck inside and warns about parents outside the folder.
- **Hub deck tile badge** counts the effective set (own + enabled links), like the workbench header.
- **Hub-wide session** (“Study N due”) has no framing deck and shows no source labels.
- **Unlink** raises the usual undo toast; Undo restores the link as it stood — toggle and grid position (original `createdAt`) — unless relinking would now close a loop or either deck was deleted meanwhile.
- **Fork** warns in its confirm dialog when the parent still reaches the child through another enabled link: the copies have new ids, so the originals arriving that way are not deduped against them.
- **Backup import** breaks any loop the restored links close with local ones, by the same newest-edge rule as a sync pull, and uploads the tombstones with the restored rows.

---

## 13. Decision log

| Topic | Decision |
|-------|----------|
| Copy vs link | Live link; one card / one SRS |
| Context everywhere | No — only when home ≠ session frame |
| Context chrome | Plain top-left text on card face, not a chip |
| Cycles / depth | Block cycles; unlimited nest depth |
| Multi-path same card | Dedupe by card id |
| Toggle | Persistent on parent link; off keeps placeholder |
| Nested include | Recursive; respect each link’s enabled flag |
| Workbench link UI | Placeholder row + popup inspector |
| Popup | Edit/delete/Study/Cram; no add/import/multi-select |
| Delete card | Soft-delete source |
| Delete deck | Warn if linked from others; then soft-delete drops from composites |
| Global due | Count each card once |
| Fork | Child native cards → parent copies; drop link; one link at a time |
| Study subset | Parent workbench context menu only |
| Visit | Context menu → open child deck |
| Skipped features | Weights, folder links, exclude filters, pin colors, progress-by-source bar |
