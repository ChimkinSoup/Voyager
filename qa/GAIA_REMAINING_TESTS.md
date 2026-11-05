# Gaia: remaining tests

Written 2026-11-02, after Phase 9A-9C were marked Done. This lists everything about Gaia that hasn't been checked live, plus the open and part-tested bugs. Non-Gaia plans (`TEST_PLAN.md`, `MULTI_DEVICE_SYNC_TEST_PLAN.md`) aren't reviewed here.

Tick items as you go. If one fails, add it to `qa/BUGS.md` (the last ID is BUG-349) and note the ID here.

Expected results come from `GAIA_HLD.md` (section numbers given) or the code. **Observe** means nothing specifies the result: write down what happens and decide whether it's right.

## Results of the 2026-11-02 pass

Run on `gaiaqa` (qa-128) from a fresh debug build of the working tree. A ticked item was run, and its note gives any failure. An unticked item wasn't run. No fixes were made in that pass; the decisions and fixes that followed are listed next.

**Decisions and fixes (2026-11-02, later):**
- **C4:** black out neighbouring sensitive fields. Crops already did, through `_printWindow`. Seen on Electron, Chrome and Firefox, on first reads too. No code change.
- **C and D:** refuse while the vault is unlocked, wherever Voyager's windows are. Run with a real vault: no capture file, and a toast says why.
- **F5:** the guard is per window, with up to 4 at once. Run: a healthy window reads while another is stuck, and at the cap it says another window's read is stuck.
- **Titles (B):** taken from the later exchange after a stopped first reply. Accepted.
- **Signed-out line (B):** a login check that finds a login now re-reads that account's usage. Unit-tested, and the re-read reached the real companion. Not run with a real log-back-in.
- **"1 steps" (A):** the agent's tool text now uses the singular. Unit-tested.
- **Ctrl+Enter after coming back:** works by hand, tried by Juno. The harness failure was the harness.
- **BUG-344 to BUG-349:** fixed and run in the app; see each entry in `qa/BUGS.md`.
- Still open: another profile's vault limit (C3). `/this` keeps its own global guards at summon (`_controlReading`, `_elementCropping`), which F5's change didn't touch.

**New bugs from that pass:** BUG-344 to BUG-349, all since fixed. Three were Major (security): BUG-344, BUG-345 and BUG-347.

**Not run, and why:**
- **Phone (D, F3, the phone items in A, B, E3, E5 and H):** not run, because sign-in on the emulator failed with "There was an error while trying to get your package certificate hash". No longer blocked. On 2026-11-04 that error reproduced only on Continue with Google (`INVALID_CERT_HASH`), because the Firebase Android app had no SHA certificates. Email sign-in worked on the same build, so use a qa account. This PC's debug SHA-1 is now registered, which clears that error. Google sign-in then failed on a deleted OAuth client (`deleted_client`, `74426781900-h9kkkd0l...`); Juno set a new web client (`74426781900-4vjcp49d...`) in Firebase, and a full Google sign-in on the emulator then succeeded. Whether the 2026-11-02 failure was on the Google path wasn't confirmed.
- **E1 edge cases:** declining UAC, the three approval cards, and a missing `[windows] sandbox`.
- **E2:** typing into Notes on a fresh browser, as opposed to an awake page.
- **E3:** a multi-step Run all over 30 s.
- **E4:** the `exec` fallback, which needs a forced switch.
- **E5:** needs a second Codex login. The passive usage update wasn't checked either.
- **F1:** an elevated window needs another UAC approval.
- **F2:** needs a second monitor.
- **F4:** hotkeys C and D capture the real screen, with your private windows on it, and then upload. Left for you to run with those closed.
- **G:** needs an account that has really run out.
- **H:** rare paths, and real power actions.
- **C2 edge cases:** a hidden tab, and the welcome dialog. The real-turn `os_screenshot` check wasn't run with a model.
- **C1:** whether `/this <question>` stays in the draft on a refusal. A minimized target wasn't reached.

**Left in place on `gaiaqa`, on purpose:**
- The `default` Codex home's sandbox, which took a real UAC approval. `session_end.ps1` and `reset.ps1` wipe it.
- The Codex Sol agent on the deep tier.
- A vault on qa-128 with the made-up password `gaiaqa-vault-madeup`.
- About 30 test chats.
- A sandbox marker in `gaia\codex\cxout`, from a UAC approval spent there by mistake. Its account has been removed.

## Suggested order

| # | Section | Why this position | Needs |
|---|---|---|---|
| 1 | [A. BUG-341 and BUG-342](#a-bug-341-and-bug-342-part-tested-fixes) | Quick, finishes today's fixes | Rebuilt app |
| 2 | [B. BUG-334 to 336](#b-bug-334-to-bug-336-fixed-part-tested) | Quick; finishes these fixes | Rebuilt app |
| 3 | [C. Security checks](#c-security-checks-still-open) | A failure here exposes secrets or sends input where it shouldn't | An Electron app with a password field, a vault |
| 4 | [D. Phone history](#d-phone-shows-no-older-messages) | Could be a real bug; never investigated | Phone or emulator |
| 5 | [E. Codex](#e-codex) | Do the sandbox first: the rest depends on it | Your UAC approval, ideally a second Codex login |
| 6 | [F. Phase 9 edge cases](#f-phase-9-edge-cases) | Lower risk | Second monitor, an elevated app |
| 7 | [G. Real limit errors](#g-real-limit-errors-phase-8) | Can't be forced; do it whenever an account runs out | An exhausted account |
| 8 | [H. Older phases](#h-older-gaia-phases) | Rare paths | Varies |
| 9 | [I. Autonomy Phase 5](#i-autonomy-phase-5-os_window-os_drag-os_clipboard) | Built with the display off; the Done-when is unchecked live | Display on, a password manager |

## Before you start

- **Rebuild first.** The fixes for BUG-337 to BUG-343 are uncommitted in the working tree. A running build has none of them until you rebuild; hot restart won't pick up native changes such as the border.
- **Use a test profile for anything risky.** `gaiaqa` (companion `gaiaqac`) is the usual one. It has its own data, and `qa-128` is its test account.
- **Use throwaway targets.** Use made-up passwords and card numbers such as `4242 4242 4242 4242`, on a local test page. Agents can read the screen in these tests, so close anything private first.
- **Use a new chat per card scenario.** Haiku won't retry a click it was told was declined.
- **Fresh browser means a new scratch profile that nothing has read yet.** The sleeping-page bugs only show on a first read.
  - Chrome: `--user-data-dir=<scratch folder>`. Add `--disable-features=CalculateNativeWinOcclusion --disable-backgrounding-occluded-windows` if the window may be covered, or the page never enters the accessibility tree.
  - Firefox: set `browser.preonboarding.enabled=false` and the `termsofuse.*` prefs, or its welcome dialog blocks the page. Check for leftover scratch-profile processes afterwards, as they can take the foreground.
- **Test page.** A local HTML file with a password field, a card number field, a one-time code field and an ordinary Notes field.
- **Automated runs.** Harness recipes are in `qa/PROGRESS.md` (top of the 2026-11-02 entries). Scripted card runs need the terminal in front for foreground rights.

## A. BUG-341 and BUG-342 (part-tested fixes)

### BUG-341: clicking the eye or hand takes focus from the composer

Only a widget test covers the fix. Real clicks didn't register in the last run.

**Setup:** move the floater so its whole composer row is above the taskbar.

- [x] Click in the composer, type some text, click the **eye**. The caret stays; keep typing and the text lands in the composer.
- [x] Same with the **hand**.
- [x] Click the eye, then press Ctrl+Enter without touching the composer. The message sends.
- [x] Same with the hand.

Edge cases:
- [x] Turning each one **off** as well as on.
- [x] Empty composer, then click the eye and type.
- [x] Eye then hand in a row, then type.
- [x] The eye's warning appears beside it: focus still stays in the composer, and the layout doesn't shift the hand out from under the cursor. **Result (2026-11-02):** The hand stays at the same x with the warning up.
- [x] Composer not focused before the click, such as just after switching back from another app. **Observe:** the click shouldn't do anything odd with focus. **Result (2026-11-02):** Result: the click toggles the eye and focus goes to the composer, so typing lands there. Looks right.
- [x] The full Gaia window, the small floater, and the Gaia page in the main window, if they show these buttons. **Result (2026-11-02):** Floater and full window pass. The Gaia page in the main window has no eye or hand.
- [x] A new chat, where the grant waits for the first message. **Result (2026-11-02):** The grant applied to the chat made by the first message.
- [x] **Observe, possible separate bug:** in the last run, the floater's saved position put this row under the taskbar. Check whether a saved position can really leave the composer unreachable, and whether it recovers. **Result (2026-11-02):** Result: not a bug. A saved position is clamped to the work area on reshow (y 1600 came back at 880). The taskbar is auto-hide, so the work area is the whole screen, and the taskbar can cover the row only while it's up. Real clicks landed at the clamped position.

### BUG-342: "Ran 1 of 1 steps" in the action log

Not looked at since the fix, and nothing tests it.

**Where:** main window, Gaia page, **Actions** tab. You need to be signed in there, which is why it wasn't checked last time.

- [x] A one-step card that runs: "Ran 1 of 1 step in <app>".
- [x] A two-step card, both run: "Ran 2 of 2 steps in <app>".

Edge cases:
- [x] Two steps, one run by Next step and then stopped: "Ran 1 of 2 steps", with "stopped" in the line below. **Result (2026-11-02):** FAILED in part: BUG-348. "Ran 1 of 2 steps" is right; "stopped" is missing below it when the rest is denied. **Fixed 2026-11-02:** re-run, "stopped" shows.
- [x] A card denied with nothing sent: no entry at all.
- [ ] A long window title: it's cut off cleanly.
- [ ] On the phone, if it shows the log (see also section H).
- [x] The agent's own tool text said "1 steps" (`gaia_chat_tools.dart`). **Result (2026-11-02):** Fixed to the singular, including "Sent the step". Unit-tested, not read from a real turn.

## B. BUG-334 to BUG-336 (fixed, part-tested)

Fixed 2026-11-02. Ticked items were checked in the app or by the contract check. The rest are still to run.

### BUG-334 (Minor): Codex 0.166.0 is shown as untested

After the fix:
- [x] Setup says "A tested version" on 0.166.0.
- [x] The chat header shows no "Untested Codex" chip on 0.166.0.
- [x] A version outside the new range (0.166.0 up to 0.167.0) still shows the chip, and the chat still runs (§5.1). **Result (2026-11-02):** Chip appears at a forced 0.165.0 and 0.167.0 and goes back at 0.166.0. That the chat still runs is not checked: turns need the sandbox (E1).
- [x] The fixtures were re-recorded on 0.166.0, after the contract check passed.
- [ ] If Codex has updated by then, repeat with the newer version.

### BUG-335 (Minor): a chat whose first reply fails keeps its raw prompt as its title

Titling now runs on the chat's first reply to finish, while the title is still the first message's first line.

After the fix, a proper title appears in each of these:
- [ ] First reply hits a usage limit, then a resend on another account succeeds (§6.5). A limit can be forced by eval; see `gaia-limits-live-check` in memory.
- [x] First reply fails with an ordinary error (a signed-out account), then a retry on a real login succeeds.
- [x] First reply stopped by the user, then another message succeeds. As built, this titles the chat. **Observe:** is that right? **Result (2026-11-02):** Result: titled from the later exchange ("Plum Word Request"), so the title reflects the second message, not the stopped first one. Accepted as a fine drawback (2026-11-02).

Edge cases:
- [x] A title you set by hand before the resend isn't overwritten. Covered by a unit test, not yet run live.
- [x] A chat titled this way gets exactly one title, not a second one on a later reply.
- [x] A failed first reply with no resend: the chat keeps the prompt text and nothing errors.
- [ ] The new title syncs to the phone.

### BUG-336 (Cosmetic): a signed-out account says so twice on the Setup tab

After the fix, the message shows once, still with the login command and folder, for:
- [x] A signed-out Claude Code account.
- [x] A signed-out Codex account, with a Codex agent set so its usage is read. Without one, only the login row can show, so this needs the sandbox from section E. **Result (2026-11-02):** "Not logged in" once, no "signed out" line, 25 s after adding the account. A later usage read was not waited for.
- [x] An expired token, which reads as `stale`, not signed out (§6.4 table; `~/.claude` has this).
- [ ] Logging back in clears the message. **Fixed 2026-11-02, needs a real log-back-in:** a login check that finds a login now re-reads that account's usage, on "Check again" or on opening the page, so "signed out" no longer waits up to 10 minutes. Unit-tested, and the re-read reached the real companion.

## C. Security checks still open

### C1. Electron app with a real sensitive field

Chrome and Firefox are covered, but the only Electron app tried (Cursor) had no sensitive field. Use one with a real password field on its first screen, such as a logged-out Discord or Bitwarden, or a tiny test Electron app. Start it fresh for each check, with nothing having read it. **Use made-up values only.**

- [x] `os_screenshot` as the first read: the password field is blacked out, or the shot is refused. It must never show in clear.
- [x] `os_type` with no target, password field focused: refused, nothing typed.
- [x] `os_type` naming the field: refused, nothing typed. **Result (2026-11-02):** Refused at plan when the tree is awake. On a first read the plan shows "not on screen yet" and the run refuses.
- [x] `os_type` into an ordinary field in the same app: it types.
- [x] `/this` on the password field, on a first read: refused, with `/this <question>` left unsent in the draft. **Result (2026-11-02):** FAILED: BUG-346. Attaches a big control or an empty chip; not refused. The crop had the fields blacked out. **Fixed 2026-11-02:** re-run, refused, through a real summon too. Whether `/this <question>` stays in the draft on a refusal is still not run.
- [x] `/this` on an ordinary field, first read: chip and crop, or no control at all. Never a big unnamed control with a crop showing the password field. **Result (2026-11-02):** FAILED: BUG-346. **Fixed 2026-11-02:** re-run, `Edit "Notes"` with its crop.

Edge cases:
- [x] Ctrl+V in the password field: refused. Tab, Enter and Esc there: allowed (§15.6). **Result (2026-11-02):** Ctrl+V refused at run; Tab, Enter and Esc sent.
- [x] App minimized, or fully covered by another window, when the read comes in. **Result (2026-11-02):** Covered by the floater: bars on the fields. Minimized was not reached: the script could not find the window to minimize it. By the code, a minimized window is skipped and the next window is the target.
- [x] Focus moved to the password field between plan and run: refused at run.
- [x] A card or one-time code field, if the app has one.
- [x] A dialog or second window in the app that holds the field.
- [x] `os_read_screen`: the field is listed as sensitive, with no value. **Result (2026-11-02):** Electron only. Firefox fails: BUG-345. **Fixed 2026-11-02:** re-run on Firefox, Chrome and Electron, all listed as sensitive.

### C2. `/this` on Firefox

Only Chrome's first read was re-checked after BUG-343. Use a fresh scratch Firefox.

- [x] Password field, first read: refused. **Result (2026-11-02):** FAILED: BUG-346. **Fixed 2026-11-02:** re-run, refused.
- [x] Card and one-time code fields, first read: refused. **Result (2026-11-02):** FAILED: BUG-346. **Fixed 2026-11-02:** re-run, refused.
- [x] Notes field: chip and crop, or no control at all, with no unnamed control whose crop shows a neighbouring password field. **Result (2026-11-02):** FAILED: BUG-346. The crop is the whole window, with the fields blacked out. **Fixed 2026-11-02:** re-run, `Edit "Notes"` with its crop.
- [x] A second read of the same page: the real control. **Result (2026-11-02):** Notes gets its Edit; the password field is refused.

Edge cases:
- [x] Firefox refused when a site is on the exclusion list, since its address can't be read (§19, 9B). Check whether `/this` follows that rule, and that the excluded site gets no crop. **Result (2026-11-02):** FAILED: BUG-347. `/this` and `os_read_screen` refuse, with no crop. `os_screenshot` passes on a first read. **Fixed 2026-11-02:** re-run, all refuse on Firefox and Chrome, and the address off the list is the real one.
- [ ] A hidden tab, or a covered window.
- [ ] The welcome dialog still up: no control or a refusal, with no hang.
- [ ] Also confirm Firefox's page fields under `os_screenshot` with a real turn in the app. The 9B pass couldn't, as its welcome dialog covered them; the later first-shot check did see both barred.

### C3. Real vault unlock

Only forced by setting the flag so far. Unlock a real vault in the test profile.

- [x] Vault unlocked, a Voyager window in front or as the target: `os_read_screen`, `os_screenshot` and `os_focused_window` all refuse. It refuses rather than moving on to the next window (§19, 9B).
- [x] Same for a card with `os_click`, `os_type`, `os_key` and `os_scroll`.
- [x] Lock the vault again: the same reads work.

Edge cases:
- [x] Vault unlocked between plan and run: the run refuses, with nothing sent.
- [x] Vault unlocked during a read: the result doesn't reach the agent, as it's checked again after the read. **Result (2026-11-02):** Refused, with the read and the unlock fired together. The timing could not be proved to fall inside the read.
- [x] Vault locked by its auto-lock, if it has one: the state updates without a restart. **Result (2026-11-02):** Locks after 5 idle minutes, and reads work with no restart.
- [x] Decrypted note or photo on screen: other apps' windows still read, with Voyager not in the picture. **Result (2026-11-02):** Another app's window reads with the vault unlocked. No note was on screen.
- [x] `/this` and hotkeys C and D over a Voyager window with the vault unlocked. **Observe:** the rule is written for `os_*` tools only, so decide whether these should refuse too. **Result (2026-11-02):** From the code, not run: `/this` refuses (`vault`). C and D had no vault check, so a capture could show decrypted content. **Fixed 2026-11-02:** C and D now refuse while the vault is unlocked. Run with a real vault: no capture file, and the toast says why.
- [x] Another profile's instance with its own vault unlocked: known limit, this instance can't see it. Confirm and accept, or file it. **Result (2026-11-02):** From the code, not run: the check only covers this instance's own PID. Confirm and accept, or file it.

### C4. Decision: a neighbouring field's value in a `/this` crop

The crop is the control plus 48 px around it. In the Phase 9 pass, a one-time code beside the pointed field reached the agent in the crop and landed in the image's **synced caption**.

- [x] Decide: black out nearby sensitive fields in the crop as `os_screenshot` does. **Result (2026-11-02):** Decided, and crops already do it, as they now come from `_printWindow`. With the cursor on the "One-time code" label, the password, card and one-time code fields in the crop are black on Electron, Chrome and Firefox, including first reads. §15.5 corrected.

## D. Phone shows no older messages

Seen once in the Phase 9 pass, in one chat: the phone showed only the new messages. Nobody looked into it, and which chat it was wasn't recorded.

- [ ] Long chat started on the desktop before the phone was paired: open it on the phone. Older messages appear.
- [ ] Same chat, send from the phone: the older ones are still there alongside the new ones.
- [ ] Send from the desktop while the chat is open on the phone.

Edge cases:
- [ ] Chat opened while the desktop is offline or the companion isn't running.
- [ ] Chat with images, cards or `/this` chips in its history.
- [ ] Scrolling up in a chat longer than one page: does it page in older messages?
- [ ] Force-close the phone app and reopen the chat.
- [ ] A fresh install and pairing, as in the Phase 9 pass, compared with an existing one.
- [ ] A chat with messages from two accounts.
- [ ] A chat restored from the trash.
- [ ] If it reproduces: compare the message count in the desktop's database with what the phone has, to tell a sync gap from a display bug.

## E. Codex

### E1. The sandbox itself (do this first)

No test turn has made a shell call, and the marker was copied in rather than set up. **It needs your UAC approval**, so do it at the screen. Each Codex home needs its own approval.

- [x] Before setup: a Codex turn fails at once and points to Setup (§5.1).
- [x] Setup → **Set up**: UAC appears, you approve, and the step shows done. **Result (2026-11-02):** UAC came up and was approved; the step shows done. Run for both `cxout` (by mistake, see below) and `default`.
- [x] A turn that runs a harmless shell command, such as listing a folder: it runs and returns output.
- [x] A later turn needs no approval again.

Edge cases:
- [ ] Decline the UAC prompt: a clear failure with no hang, and it can be retried.
- [x] A write outside what the sandbox allows: refused, or asks you (§5.1, §10.1). **Result (2026-11-02):** Refused with "Access to the path is denied". The agent mangled the path, so the write was aimed inside `gaia\ws`; nothing was created at the target. No approval card came up.
- [ ] A command, a file change and a permissions request each raising a card, and each answered.
- [ ] `[windows] sandbox` missing from your config.toml: every shell command is refused, with a clear message.

### E2. A Codex card since the fixes

Today's re-runs of the card used the Claude quick tier. Repeat on Codex, with the target **behind Gaia**:

- [x] A real click on **Run**: the target comes up, and the step is sent.
- [x] **Ctrl+Enter** from the composer. **Result (2026-11-02):** Works straight after a summon. After the harness re-activates Gaia, the chord does nothing, at 10 s and 45 s. That was the harness: it works by hand after switching away and back (Juno, 2026-11-02).
- [x] **Next step**, then **Run**, across two steps.
- [x] **Deny**, and a typed reason.
- [x] `os_type` on a fresh Chrome: password refused, Notes typed. **Result (2026-11-02):** Fresh Chrome, focus in the password field: refused. The Notes half is covered by the named `os_type` cards above, on an awake page.
- [x] The same on a fresh Firefox. **Result (2026-11-02):** Password refused with Gaia in front. With Firefox already in front it types: BUG-344. Notes not typed on a fresh Firefox here. **Fixed 2026-11-02:** re-run by host calls with Firefox in front: password refused, Notes named types. Not re-run as a real card with Gaia in front.

### E3. Codex's 30-second card wait

A held card should be voided when the turn stops waiting on the tool (§19, 9C).

- [x] Get a Codex card, leave it for over 30 s: the card shows voided, and no input is sent. **Result (2026-11-02):** The wait is about 60 s on Codex 0.166.0, not 30 s: open and live at 45 s, voided at 63 s and 66-96 s in two runs, with nothing sent. §19 should say so. The agent then says "Approval is still pending", which is out of date.
- [x] Click Run or press Ctrl+Enter on it after that: nothing is sent. **Result (2026-11-02):** Ctrl+Enter on a voided card sends nothing. No Run button was tried once voided.

Edge cases:
- [x] Approve just before 30 s, at about 25 s: it runs normally. **Result (2026-11-02):** Runs at 25 s, and also at 45 s by a real click on Run.
- [x] Next step, then wait over 30 s before the next step. **Observe:** do the remaining steps void? **Result (2026-11-02):** The remaining step stays open past 45 s, and the card ends up voided with `ran: 1`. Nothing more is sent. The Ctrl+Enter tried at 45 s was the inconclusive kind (E2).
- [ ] Multi-step Run all that takes longer than 30 s. **Observe.**
- [x] The voided card doesn't appear in the action log.
- [x] The agent can ask again in a later turn.
- [ ] The phone shows the same state.

### E4. The `exec` fallback's images

Untested since Phase 9B; the app-server path is what's been checked. The fallback is `codex exec` in `codex_runner.dart`, used when app-server isn't. It may need a forced switch to reach.

- [ ] `os_screenshot` on the fallback: the model sees the image and answers correctly about it.
- [ ] The answer doesn't retype the data, or hold base64 as text (§19, 9B).

Edge cases:
- [ ] A large screenshot past the 3.5 MB JPEG switch.
- [ ] A sensitive field in the shot: still blacked out.
- [ ] A control card: §10.1 says this fallback can't surface approvals. **Observe:** it should refuse cleanly, not run or hang.

### E5. Codex accounts and usage (Phase 8)

`~/.codex` is the only login so far, and `~/.codex-2` has none. These need E1 done for each home, and the second-login items need another Codex account.

- [ ] A real turn: the usage rings update from the turn itself, with no poll (passive update).
- [ ] A Codex turn on a second account.
- [ ] A session copied between two real Codex logins resumes; so far it's only been tried on one login in two homes. Check both directions, and that the agent remembers a codeword from before the switch.

Edge cases:
- [ ] The divider appears where the account changed, on the phone too.
- [ ] Each account's usage is kept apart.
- [ ] Switching mid-chat back to the first account resumes its own session, caught up, rather than copying again.
- [x] A signed-out second account: a clear message, not a hang. **Result (2026-11-02):** No hang, but the message is raw: "unexpected status 401 Unauthorized: Missing bearer or basic authentication…". BUG-349. **Fixed 2026-11-02:** re-run with a real turn: says the account is signed out, with its login command.

## F. Phase 9 edge cases

### F1. Elevated target window

Windows blocks input to an elevated window without saying so, so a run reports "sent" and nothing happens (§19, 9C). Use an elevated Notepad or terminal.

- [ ] `os_click` and `os_type` on it: reports "sent", and nothing reaches the window. No hang, and no input lands elsewhere.
- [ ] The tool's text tells the agent to read the screen, and a read shows nothing changed.

Edge cases:
- [ ] `os_read_screen` and `os_screenshot` of it. **Observe:** do they read, refuse or come back empty?
- [ ] `/this` over it. **Observe.**
- [ ] Hold a modifier, or press Esc, during a run: Esc still stops it, and no key is left down.
- [ ] A UAC prompt appearing mid-run (secure desktop): the run stops as "another window in front", with nothing typed.
- [ ] Bringing it up from behind Gaia: `SetForegroundWindow` to an elevated window. **Observe.**

### F2. Several monitors

Your laptop has one display, so this needs an external monitor. Try the second monitor at a different scale from the first (say 100% and 200%), and placed to the **left** of the primary so its coordinates are negative.

- [ ] Border: four strips on each monitor, and the label on the primary only.
- [ ] Click and scroll on a window on the second monitor land at the right spot.
- [ ] `os_screenshot` there: bars line up with the fields.
- [ ] Hotkey D captures the right screen, and C's crop overlay works there.
- [ ] `/this`: the crop stays within its monitor, and is the right place.

Edge cases:
- [ ] A window spanning both monitors: click, shot and bars.
- [ ] A window dragged across during a run. **Observe:** at most it should stop.
- [ ] Unplugging the monitor, or changing its scale, while the border shows: the border redraws with no stray strips.
- [ ] Plugging one in while the border shows.
- [ ] The floater and full-screen modes on the cursor's monitor.
- [ ] A step whose coordinates are outside the window, across a monitor boundary: refused.

### F3. Empty send on the phone with a card open

The phone can deny but not approve (§19, 9C). By the code, an empty send does nothing.

- [ ] Control card open on the phone, press send with nothing typed: nothing runs and nothing is denied. "Waiting for approval at the desktop" stays.
- [ ] Typed reason from the phone: denies with that reason.
- [ ] Deny from the phone: nothing is sent.

Edge cases:
- [ ] Only whitespace typed.
- [ ] Other card kinds open on the phone: an empty send behaves as they're meant to.
- [ ] Approve at the desktop just after the phone's Deny, and the reverse: one wins, and both agree on which.
- [ ] A phone offline when pressing send, then reconnecting: nothing fires late.
- [ ] A phone on an older build opening a chat with a control card: §19 says it needs updating first. **Observe** how it fails.

### F4. Hotkey D with a BMP

BUG-340's fix was re-run for `/this` only. D takes the same path.

- [ ] Press D, then keep the draft and restart the companion before sending: the image is still in the draft.
- [ ] `companion.log` has no new "draft image not kept" line.
- [ ] Sends and uploads normally, and shows on the phone.
- [ ] Same with C (region), to be sure.

Edge cases:
- [ ] D twice before sending: both kept, or replaced as designed.
- [ ] Removing the image from the draft: the temporary file is gone from the captures folder.

### F5. Read and control leftovers

- [x] **A stuck read refuses later reads until it returns.** Hang a window (a suspended process works) and read it, then read a healthy window. It should refuse at 8 s, say to try again, and work again after recovery. **Decide** whether blocking every window for one stuck read is acceptable. **Result (2026-11-02):** Refused at about 9 s; a healthy window then refused at once; worked 3 s after resuming. **Fixed 2026-11-02:** the guard is per window, with up to 4 at once. Re-run: the hung window refused at 9 s and again at once, and a healthy window read in about 1 s while it was stuck. With 4 other windows' reads held, the healthy window said "Another window's read is stuck", and it read again once they ended.
- [ ] **Firefox under `flutter_tester`:** a fresh Firefox's UI Automation can block for 30 s or more in tests, and it hasn't happened in the app. It only causes a refusal, so it's safe. If you ever see a slow Firefox read in the app, note it, as that would change this.

## G. Real limit errors (Phase 8)

No account has actually run out, so all of this was forced. The CLI wording in `usage/gaia_usage_limits.dart` comes from reading the binaries (Claude Code 2.1.316, Codex 0.166.0), and it may not match a real error. **Do this when an account really runs out, on either CLI.** Save the exact error text; if it isn't recognised, the regex there is the fix.

- [ ] Claude Code: a real limit error mid-reply. The partial answer is kept and marked "Stopped at the usage limit: …", and the card replaces the composer.
- [ ] Codex: the same.
- [ ] The resend on another account works, and the prompt's images, files and quotes go with it.

Card cases on screen (2 and 3 have widget tests only, §6.5):
- [ ] Case 1: another account for the same agent has headroom: "Switch to account B".
- [ ] Case 2: no account left, and a tier on a different provider isn't out: only those tiers are offered.
- [ ] Case 3: all tiers on one provider, or everything out: "Usage has run out", with each account on its own line, soonest reset first.

Edge cases:
- [ ] A transient 429: an ordinary error, with no card and no change to the account's state.
- [ ] A per-model limit: Opus out leaves Sonnet on the same account usable.
- [ ] Restart after a limit error: only the numbers say it's out, since the mark is held in memory.
- [ ] Dismiss the card: it stays dismissed for that account until it recovers or hits a limit again, and the next message fails if it's still out.
- [ ] Reset time passes: the account recovers with no restart.
- [ ] Low banner at the real floor: under 10% of the session with the reset over 45 minutes away, and under 5% weekly.
- [ ] Limit hit during a queued drain: the drain stops.
- [ ] The phone shows the failed reply and its error, with no card or banner.
- [x] **Ctrl+Enter after coming back to the window** with a real keyboard. Harness-posted Ctrl chords can't reach it, so only a widget test covers this. **Result (2026-11-02):** Juno tried it by hand on a card, focusing another window and coming back: it ran.

## H. Older Gaia phases

Rare paths, listed as "not checked live" in `GAIA_HLD.md` §19.

**Phase 4:**
- [ ] A permission card from your own Auto mode.
- [ ] The hour's expiry on a held card, for real. Unit-tested with a short hold.
- [ ] The shim's connection being dropped for a process Gaia didn't start.
- [ ] Save all on several proposals (Codex only, as Claude Code's come one at a time).
- [ ] The phone's action log.

**Phase 7:**
- [ ] Real sleep, shutdown and lid changes from the phone. Dev profiles don't do these, so it needs a real install. **Save your work first; these act on the PC for real.**

**Phase 6:**
- [ ] Typing in Vim's Normal mode, by real keyboard (background input also types the characters).
- [ ] Clicking a link in a chat.

## I. Autonomy Phase 5: `os_window`, `os_drag`, `os_clipboard`

Built 2026-11-04 with the display off (`GAIA_AUTONOMY_HLD.md` §11.7). Unit tests and the real-Win32 clipboard and window probes pass. Everything below needs the display on, and the app rebuilt.

**First, the probe that couldn't run:**
- [ ] `flutter test --run-skipped test/tool/gaia_more_tools_live_test.dart` with the display on and nobody touching the PC. Expected: all 6 pass. Its two `os_drag` tests failed with the display off at `os_focus`'s "Windows refused the input", before any drag. They drag a real TrackBar's thumb to its end, then stop a drag mid-way and check `GetAsyncKeyState(VK_LBUTTON)` and WinForms' `MouseButtons` show no button held.

**The Done-when, in the app (Auto chat, Haiku):**
- [ ] **A stopped drag leaves no button down.** Ask Gaia to drag something slow to drag (a long file list's item onto a folder in a scratch Explorer window, or a slider on a local page), and press Esc while it's moving. Expected: the turn ends `cancelled`; the item is back where it was or never dropped (Gaia lets go where the drag started); and clicking and selecting text afterwards works normally, with no button stuck. Repeat with Alt+Tab mid-drag instead of Esc, and with Stop on the phone.
- [ ] **A password manager's copy is refused on read.** With a real password manager (KeePass, Bitwarden or 1Password's desktop app), copy a made-up entry's password, then ask Gaia to read the clipboard. Expected: "What is on the clipboard was marked private…", and the password never in the reply. The probe covers the formats (`ExcludeClipboardContentFromMonitorProcessing`, `CanIncludeInClipboardHistory = 0`) set from PowerShell, not a real manager. **Observe** which managers set them: one that sets neither is read unless it's on the exclusion list (where it's refused as the clipboard's owner, if it owns it).

**`os_window`:**
- [ ] Ask mode: a card for each action; approving runs it, with the window outline flash at the window's old place. Minimize, maximize, restore, move, resize, close on a scratch Notepad.
- [ ] Auto: `close` on Notepad with unsaved text. Expected: its "Do you want to save?" prompt adopts as a window Gaia caused, and the agent can answer it. Then on a window with no prompt: the next window in front adopts and the agent is told.
- [ ] Auto: `minimize` of the pinned window with Gaia's floater next behind it. Expected: no "Paused" in the notch, and the agent's next action says to `os_open` or `os_focus` a window, rather than waiting 5 minutes.
- [ ] Auto: `restore` of a minimized Store app (Calculator). Expected: not stopped as "The user switched to another window" (BUG-351's case, through this tool).
- [ ] `move` of a maximized window, and of one on a second monitor at another scale: lands at the asked frame, as `os_windows` reports frames (invisible borders accounted for).
- [ ] An elevated window (F1's setup): **Observe** what `move` and `close` do. UIPI should block both silently; the result says "Sent", which isn't a check that it worked.
- [ ] `close` on Voyager's own window is refused before a card.

**`os_drag`:**
- [ ] A real drag lands, in Ask (the card shows the start's marker) and in Auto. While it runs, the drag trail below plays in about 330 ms. Check it keeps pace with the cursor and is gone soon after the button comes up.
- [ ] Debug menu → control showcase → **Drag**, in each of Current, Astral, Echo and Glide. Check that:
  - the style's click plays on "Mark as read" to take hold;
  - the style's marker travels to the empty spot, with a trail behind it brightest at its head. The marker is Astral's orbits, Echo's ring and wavefront, Glide's square and chevron, or Current's dot and chevron;
  - the marker grows as it travels and arrives at the size of the start click's halo, no larger. The chevron or wave ahead keeps clear of it as it grows;
  - at the end it holds there fully lit for a moment (~300 ms; Astral's orbits keep spinning), then fades (~250 ms). There's no second click. In Current, its ring opens out on the way;
  - in Astral, each click study changes the starting click;
  - the effect stays smooth over a long, diagonal drag.

  Ending all flashes at once (`stopFlashes`) was tested in-app on 2026-11-05 with `flutter test integration_test/gaia_flash_stop_test.dart -d windows`, passing 11 of 11, three runs in a row. That run covered:
  - every kind in every style, ended by one call, with nothing coming back;
  - play after a stop;
  - windows still waiting to hide;
  - 30 stop/play rounds, with the pool kept at no more than 16 windows;
  - a real `os_drag` on a WinForms trackbar, stopped partway: its trail was gone within 300 ms, the button came up, and the value didn't move;
  - a real `os_drag` run to the end: it landed, and its trail played out on its own in about 1.2 s.

  That test counts windows; nobody has looked at how the effect looks.
- [ ] A drag whose end gets covered mid-drag (a window opening over it): stopped, let go at the start.
- [ ] An OLE drag (file from Explorer to another Explorer folder): **Observe** whether the 10 moves over ~0.3 s are enough for Explorer to start a drag, and whether letting go at the start after a stop is a no-op.
- [ ] A drag in `os_steps` alongside clicks.

**`os_clipboard`:**
- [ ] Write in Ask (a card naming the text, cut at 200 characters) and in Auto (a row on the activity card, which keeps the app it named before). Then Ctrl+V in Notepad pastes it.
- [ ] Gaia's own write reads back, though it's marked out of clipboard history; Win+V doesn't list it.
- [ ] A read from Chrome with a site on the exclusion list: refused as "from a browser". **Decide** whether that's too strict.
- [ ] A read with the vault unlocked: refused.
- [ ] A real Codex and Claude Code turn choosing `os_clipboard` write plus Ctrl+V over a long `os_type`.

## Cleanup when you're done

- [ ] Empty `build/p9qa` (`build/p9qa2` is already gone).
- [ ] `qa-128`: remove the trusted "Phone" device (uninstalled) and test chats.
- [ ] `gaiaqa`: test chats and a stray `[image 1]` in its draft.
- [ ] Scratch build copy (about 544 MB) and browser profiles in `C:\Users\Juno\AppData\Local\Temp\claude\C--Users-Juno-Code-Voyager\dfd7f6ce-b0eb-4f61-aae4-37c3196e4ab2\scratchpad`.
- [ ] Any sandbox marker or Codex home you set up only for testing.
