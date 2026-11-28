# Gaia — Routines (HLD)

Status: **R0's control fixes (§15) and R1 built 2026-11-26, R2 built 2026-11-27**, unit-tested.
R0's control fixes passed a live fixture pass on 2026-11-27, with two bugs
(§3.8). The R0 spike on real sites is deferred to later testing. R1's live fixture run passed on
2026-11-27 (qa/PROGRESS.md), with BUG-442 (Esc during a tool call failed the item and the run went
on) since fixed. R2's live fixture run passed on 2026-11-27 (qa/PROGRESS.md), with BUG-444 (the Resume hotkey was never released) and BUG-445 (an account page was handed off with its email unfilled) fixed the same day. Where the build differs from this design is in §17.1
and §17.2. Its questions were settled with Juno the same day (§19).
Open questions are in §20.

## 1. Summary

A **routine** is a saved set of instructions that Gaia runs over a list of **items**, one at a
time, adapting to each one. The first routine is a job applier: each item is a job posting URL,
and for each one Gaia reads the posting, fills the application from Juno's materials, submits
it or hands it back, and records what happened.

The pieces:

1. **A routine** (§5, §6): instructions, a project for its materials, skip rules, a submit
   policy, a tier, a per-item budget and a Google account. Edited in a new Routines tab.
2. **A run** (§7, §8): `/routine <name>` in any chat opens a launch card. You paste URLs or
   import open Chrome tabs, and Ctrl+Enter starts it. **Dart code drives the loop**, not the
   model: each item gets a fresh, temporary chat in the routine's project, and the turn must
   end with `report_outcome`.
3. **Handoffs** (§9): when Gaia can't go on (a password, a verification code, a question with no
   answer), it reports `needs_you`. Unattended runs (the default) park the item, keep its tab
   open and move on. Attended runs wait, with the screen border lit, until you press Resume.
4. **A side panel** (§11) shows the live run. **A summary** (§12) is posted in the launch chat
   at the end. Submitted applications **go straight into the Jobs tracker** (§13), an exception
   to proposals needing review.
5. **Usage guards** (§8.8): a token cap per routine, and a wrap-up line on the 5-hour and weekly
   limits. The Routines tab shows what routines have spent.

It's built on what exists: Auto and the `os_*` tools (GAIA_AUTONOMY_HLD.md), projects and
their folders (GAIA_PROJECTS_HLD.md), temporary chats (GAIA_TEMP_HLD.md), proposal cards
(GAIA_HLD.md §10) and the Jobs tracker. It is **not** an extension system (§19, decision 1).

## 2. Goals and non-goals

Goals:
- Paste 20 job URLs, start a run, walk away. Come back to: N submitted, the rest parked or
  skipped with a one-line reason each, every parked tab still open, a summary, and the submitted
  ones already in the Jobs tracker.
- Gaia never types a password or a one-time code, never creates an account with a password, and
  never invents an answer to a factual question (sponsorship, salary, start date,
  demographics, attestations).
- Gaia never clicks Submit on an application it was unsure about (§8.6). That's enforced in
  code, not just prompted.
- A run survives Gaia restarting, Esc, and a crash: it resumes at the next item.
- A run can't eat a plan limit: it stops at its token cap, and wraps up as the 5-hour or weekly
  limit nears (§8.8).

Non-goals (v1):
- An extension or plugin framework (§19).
- Running items in parallel. Real input needs the front, so it's one at a time.
- Background runs. They come with §13 of GAIA_AUTONOMY_HLD.md, later (§16.2).
- Tailored resumes (§16.1).
- Starting a run from Jobs tracker entries (§16.3).
- LinkedIn Easy Apply. Automating it breaks LinkedIn's terms and risks the account.

## 3. What exists, and what the test run showed

### 3.1 What it reuses

| Need | Exists as | Where |
|---|---|---|
| Acting on a page without cards | Auto on the hand | GAIA_AUTONOMY_HLD.md §4, §5 |
| Reading and filling forms | `os_read_screen` (with `offscreen`), `os_steps`, `os_type`, `os_click`, `read_after` | `gaia_mcp.dart`, `gaia_os_control.dart` |
| Keeping the run on its window | The pinned target and adoption | GAIA_AUTONOMY_HLD.md §5.2 |
| Stopping | Esc, Stop, Revoke, Abort | GAIA_AUTONOMY_HLD.md §5.3 |
| Juno's materials | A project and its folder, injected as `<gaia_project>` | GAIA_PROJECTS_HLD.md §4, §5.2 |
| Chats that stay off the sidebar and out of memory | Temporary chats | GAIA_TEMP_HLD.md |
| Saving to Voyager | Proposal cards, with Undo in the Actions tab. Routines skip the card (§13). | GAIA_HLD.md §10, `gaia_proposals.dart` |
| Plan usage per account | 5-hour and weekly windows, read every 10 minutes and after runs | `gaia_usage.dart`, `gaia_controller.dart` `_readUsage` |
| Token counts by source | `GaiaTokenRow` (account, source, model, count) | `gaia_tokens.dart` |
| A summary written by a model outside the chat | The utility runner | `gaia_utility.dart` |
| A lit screen edge | The aurora edge | `gaia_aurora_edge.dart` |
| Job records | `JobApplication` (company, title, status, dateApplied, applicationUrl, notes, seasonIds) | `job_models.dart` |
| Denying a CLI's shell and edit tools | `GaiaChatTools.permit` | GAIA_AUTONOMY_HLD.md §5.7 |

### 3.2 The test run (2026-11-25)

Chat "Test Fill: Job Application Without Submitting": Auto, Haiku, a Strava internship form on
one long page, random data, no submit. Read from the chat's stored parts.

| Measure | Value |
|---|---|
| Time | 2 min 39 s |
| Tool calls | 31: 10 `os_scroll`, 8 `os_steps`, 5 `os_read_screen`, 4 `os_click`, 3 `os_type`, 1 `os_key` |
| Steps | 53 (what the control card listed) |
| Context at the end | 114,179 tokens |
| Result | Every field filled, nothing submitted, a sensible report |

What went wrong, and what each points to:

| Seen | Cause | Fix |
|---|---|---|
| "The control 'Phone Number *' is not on screen." The phone then went into the email box, and needed a fix-up. | A named control below the fold is refused (`gaia_os_control.dart`, `_matchOf` returns null). The agent fell back to typing "into what has focus". | Scroll a named control into view (§15.1). Routine guidance to always name the field (§8.3). |
| Scroll down 10, 8, 12, 8, 8, then up 26, 4, 4 | No way to reach a control except scrolling by guesses. Overshoots, then scrolls back to re-read. | Same as above. With scroll-into-view, the agent reads the whole form once with `offscreen` and fills it by name. |
| Ticked "Black / Of African descent" by mistake, then unticked it | Clicks by coordinates after a scroll | Same. By-name steps after scroll-into-view. |
| Resume already attached (Chrome autofill) | | The file upload is still untested (§17, R0). |

**Budget.** 31 calls for a long one-page form, about a third of them wasted on scrolling. The
default item budget is **80 tool calls or 15 minutes**, whichever comes first (§8.5). It's one
setting on the routine, to tune after R0.

### 3.3 The second test run (2026-11-26)

Chat "Job Application Form Test Run": Auto, Sonnet, a Lucid Motors internship on Greenhouse,
the R0 spike prompt with a fake profile and a real resume path, no submit.

| Measure | Value |
|---|---|
| Time | 5 min 10 s |
| Tool calls | 68: 24 `os_click`, 14 `os_screenshot`, 11 `os_steps`, 6 `os_scroll`, 5 `os_type`, 4 `os_read_screen`, 3 `os_key`, 1 `os_focused_window` |
| Steps | 70 |
| Context at the end | 196,256 tokens |
| Result | Stopped as `needs_you` with 4 required questions unanswered, Submit visible and not clicked. The upload dialog worked from a typed path. |

| Seen | Cause | Fix |
|---|---|---|
| Read the posting and clicked Apply in the same turn. You couldn't tell it had read anything. | Nothing asks for the read to be shown before the form is touched. | The posting check (§8.3): `report_posting` before any control step. |
| Filled a form for an Amsterdam role that needs Netherlands residency, for a Toronto applicant | The skip rules only named US work authorization | A default skip rule for location, residency and enrollment (§5.1, §8.3). |
| Country and city typeaheads redone several times, then coordinate clicks and "type into what has focus" for the rest of the form | MyGreenhouse autofilled the form partway through and changed both values. Chrome's own address popup covered the city list. | Let autofill settle, read again, recheck at the end (§8.9). A typeahead action that verifies the value (§15.3). A failed named step is followed by a read, not an unnamed type (§15.2). |
| Cleared the autofilled education start year, a required field | The rule "use only facts from the materials" read an uncovered prefilled value as unsupported | Prefilled values (§8.9): kept unless the materials contradict them. A required field is never cleared. |
| Recalled "previously worked at Sony" into the item | Memory recall runs in the item chat | No recall in item chats (§14). |
| 14 screenshots and a 196k-token context on one item | Coordinate work after the typeahead fight needs a picture per step | Per-item context ceiling (§8.5). Reads over screenshots (§15.2). |

### 3.4 The third test run (2026-11-26)

Chat "Filling Job Application Form Test": Auto, Sonnet, an Intel internship on Workday (7 pages),
a fresh Chrome profile with no autofill, already signed in to a Workday account made beforehand.
Two turns: the first stopped as `needs_you` on page 3, you answered in the chat, the second
reached Review with Submit visible.

| Measure | Value |
|---|---|
| Time | 9 min 31 s of turns (4:09 and 5:22) |
| Tool calls | 140: 44 `os_click`, 32 `os_screenshot`, 19 `os_scroll`, 17 `os_steps`, 13 `os_read_screen`, 7 `Bash` (`sleep`), 4 `ask_user`, 2 `os_key`, 1 `os_type`, 1 `os_focused_window` |
| Steps | 121 (47 and 74) |
| Context at the end | 166,717, then 313,491 tokens |
| Result | Every page filled and saved, Review reached, nothing submitted. Upload worked. 9 questions in the first report and 4 `ask_user` questions in the second. |

| Seen | Cause | Fix |
|---|---|---|
| No POSTING or FIT line. It read the posting and clicked Apply in one go, as in §3.3. | Asked for in the prompt only | `report_posting` enforced in code (§8.3). |
| The prompt's hard rule said never click "Apply", yet the posting's Apply button is how the form opens | The submit words overlap with the words that open a form | Bare "Apply" isn't a submit word (§8.6). |
| 7 `Bash sleep 4` calls to wait for the next page | No wait outside the shell that the agent knows to use | Item chats have no shell (§14). Wait with `os_read_screen` and `until` (§15.2). |
| Workday's dropdowns (a button that opens a list) and three text boxes clicked by position, with a screenshot after most | Question boxes with no accessible name, and long button names | Labels for unnamed fields (§15.4). `os_pick` covers click-to-open lists too (§15.3). |
| Immigration questions 11c and 11d answered by picking the "closest" option, marked uncertain | Nothing separates a deduction from a guess | Rule: a value must follow from the materials. Picking the nearest option is a guess (§8.2). |
| Asked about the terms checkbox, which declares the application true and consents to data use | No standing answer for attestations | An answer-bank entry from setup (§6). Without it, a handoff (§9.1). |
| 13 required questions not in the materials, found page by page | Workday shows follow-ups only after earlier answers and pages | Standard questions in the setup interview (§6). One handoff per page, with all its questions together (§9.1). |
| The account's email (fixed by Workday) differed from the profile's | Test setup: your account, fake profile | Nothing for real runs. An account email that doesn't match the profile is reported `uncertain`. |
| 313k tokens of context on one item | 32 screenshots over 7 pages | Fewer screenshots (§15.2). The context ceiling's default raised (§8.5). |

Workday notes for the design:
- **Each company's Workday site has its own account** (intel.wd1 is Intel's alone). With no
  passwords (§19, decision 6), every new Workday company is a handoff at its sign-up page,
  unless you made the account beforehand or the site offers "Sign in with Google".
- **"Save and Continue" stores each page in the account**, so a stopped item leaves a draft
  on the company's server, as an upload does.

### 3.5 The fourth test run (2026-11-26)

Chat "Job Application Routine Test Run": Auto, Sonnet, a Neuralink internship on Greenhouse,
the revised prompt from §3.4. Two turns: the first gave POSTING and FIT and asked about the start
date, the second filled the form.

| Measure | Value |
|---|---|
| Tool calls | 56: 22 `os_click`, 9 `os_read_screen`, 7 `os_type`, 7 `os_steps`, 5 `os_scroll`, 4 `os_screenshot`, 1 `os_key`, 1 `os_focused_window` |
| Context at the end | 154,443 tokens |
| Result | Stopped as `needs_you` before "Submit application", POSTING and FIT given before any click, no shell waits. |

| Seen | Cause | Fix |
|---|---|---|
| The form ran its submit check and flagged every empty required field | The resume was picked by double-clicking it in the Open dialog, which closed the dialog. The next call, `os_key Enter` meant for the dialog, reached the page. Enter in a form field submits the form. | `permit` refuses Enter on a browser page in an item chat (§8.6). |
| The report said Enter was pressed "to pick a dropdown option" | The agent explains from memory, not from its own log | Test reviews read the tool log, not the report's account. |

A full form would have been sent by that Enter. The submit-word refusal only covers clicks.

### 3.6 The first batch (2026-11-26)

Six chats titled "ROUTINE TEST: …", Auto, Sonnet, the §3.4 prompt plus a prompt rule against
pressing keys on the page. Each run used about 1% of the weekly limit and 10–20% of the 5-hour
limit. Time is wall time, including your replies.

| Site | Platform | Calls | Context | Time | Result |
|---|---|---|---|---|---|
| Integrate | Ashby | 19 | 109k | 3 min | Skipped correctly ("US person status … is a required qualification"). Filled after you overrode it, `needs_you` on one question. |
| Commonwealth Fusion | Lever | 30 | 131k | 4 min | Skipped correctly ("authorized to work in the United States for any employer"). Filled after the override. |
| Northrop Grumman | Workday | 147 | 279k | 15 min | Skipped correctly ("U.S. citizenship is a pre-requisite"). After the override, stopped on page 2: the school search needs Enter. |
| Motorola Solutions | Workday | 154 | 308k | 15 min | Reached Review (`ready`) after 3 handoffs. |
| NVIDIA | Workday | 110 | 261k | 17 min | Reached Review (`ready`) after 3 handoffs, one of them to fix a field by hand. |
| Lucid Motors | Greenhouse | 75 | 182k | 6 min | `needs_you` on one question. FIT was go: the Netherlands residency appears only as form questions, not in the posting, and the report flagged it. |

| Seen | Cause | Fix |
|---|---|---|
| "Juno SungAlex Rivera" (Lever), a garbled phone number (NVIDIA), right-click menus opened again and again (Motorola) | `os_type` adds to what the field holds. With keys banned, the agent cleared fields through the right-click menu's Select all, or couldn't clear them at all | `os_type` replaces a field's text by default, in code (§15.5). |
| The school search on Workday never ran (Northrop) | Workday's school field searches only on Enter | `os_pick` presses Enter itself in a search field that shows no list after typing (§15.3). The raw Enter refusal stays (§8.6). |
| Enter inside the Open dialog and Ctrl+A in a field were blocked, though the prompt allowed them or you approved | Claude Code's auto mode check enforced the prompt's wording against keys more broadly than meant | The key gate lives in `permit` (§8.6), and the item prompt doesn't forbid keys. |
| The Open dialog stayed open after a double-click (Ashby, Motorola, Lucid), and once you clicked Open yourself | A double-click on a list item doesn't always confirm a file dialog | `os_upload` sets the path and confirms the dialog in code (§15.6). |
| The LinkedIn box was typed into by position, and the type was refused as possibly sensitive (NVIDIA) | The box has no name, and the focus check fails closed on a field it can't identify | Labels for unnamed fields (§15.4). |
| An optional "What interested you" box was left empty while its required twin was filled (Lever) | The prompt reads "required" as the bar | Optional questions the materials answer are filled (§8.2). |
| Every Workday run stopped on page 1 for Phone Device Type, address or postal code, and 555 numbers failed Workday's phone check | Test data gaps | The test profile gets them. The setup interview asks for a phone type and a full address (§6). |
| Resume autofill (Lever) put your real name, email and current company into the form | The test resume isn't Alex Rivera's | Use a test resume for test runs. In real runs the resume and the profile agree. |

The skip rule worked on all three explicit postings, quoting the posting's words, and a posting
that said nothing came back as a go.

### 3.7 The second batch (2026-11-26)

Two chats titled "ROUTINE TEST 2: …", the §3.6 prompt changes and the Alex Rivera test resume.
The profile in both had no phone or address line.

| Site | Platform | Calls | Context | Time | Result |
|---|---|---|---|---|---|
| Lockheed Martin | Eightfold | 70 | 180k | 6 min | Skipped correctly ("Clearance Required to Start: Interim Secret"). After your override, `needs_you` on one question (willing to do a security prescreen). 14 screenshots. |
| Microsoft | Microsoft Careers | 52 | 157k | 5 min | Skipped correctly ("Currently enrolled in a Doctorate Degree program"). After the override and your sign-in, `needs_you` on address and postal code. |

| Seen | Cause | Fix |
|---|---|---|
| "AlexAlexAlex" in a field, even after Ctrl+A (Microsoft) | The step after Ctrl+A was a named type, which clicks the field first and drops the selection | `os_type`'s replace selects after its own click, in one action, and reads back (§15.5). |
| The skip read only the Summary tab; the Job Description tab was never opened (Lockheed) | The posting is split across tabs, and clicks are refused before `report_posting` | Tabs and "show more" controls may be clicked before `report_posting` (§8.3). |
| Radio buttons and dropdowns with long names only worked by a shortened name (Lockheed, and Veteran on NVIDIA in §3.6) | UI Automation cuts long names with "…", and steps match the full text | A step's name matches a cut-off name by its prefix, when that's unique (§15.7). |
| Three checkboxes all named "Yes", clicked by position (Microsoft) | Same names, told apart only by their question | Duplicate names get their question as the inferred label (§15.4). |
| Dropdown options missing from reads, so screenshots (Lockheed, 14) | The list renders its options where a read with the given region didn't reach, or after a delay | `os_pick` waits for the options in code (§15.3). |
| Autofill split the resume's phone into "+1 416" and "5550134", kept as prefilled | The profile had no phone, so nothing contradicted it | Phone numbers compare on their digits (§8.9). With a phone in the profile, the split value is replaced. |
| Read the resume PDF with the Read tool (Microsoft) | To check autofilled values against it | `Read` is allowed only on the routine's uploads (§14). |
| The form asked US applicants to remove attendance and graduation dates from the resume (Microsoft) | A per-company resume rule | Reported, not acted on. Tailored resumes are later (§16.1). |

### 3.8 The fixture pass for §15 (2026-11-27)

A live check of the R0 control fixes that the R1 fixture runs hadn't reached: scroll into view
(§15.1), `os_type` replacing (§15.5), labels for unnamed and shared-name fields (§15.4) and
cut-off names (§15.7). `os_pick`, `os_upload` and the Enter gate were checked in the R1 fixture
runs (BUG-429 … BUG-432). It ran in `gaiaqa` on a plain Auto chat (Standard, Sonnet) against
`qa/fixtures/routines/7-controls.html` in a scratch Chrome. The page has a long posting above the
form, prefilled name and email, a phone field that formats as you type, two text boxes with no
name under a question, three checkboxes named "Yes", and two radio buttons over 200 characters long.

**The real-site spike is deferred** (Juno, 2026-11-27): it fills real employers' forms, uploads
the test resume to them and leaves Workday drafts. R0's "done when" (a table per site, and the
budget, context and tier decisions) is still open.

Turn 1, "fill every field from the test profile, don't submit":

| Measure | Value |
|---|---|
| Time | 31 s |
| Tool calls | 7: 2 `os_read_screen` (both `offscreen`), 2 `os_click`, 1 `os_steps` (7 steps), 1 `os_screenshot`, 1 `os_windows` |
| Context at the end | 74k tokens |
| Result | Every field right, nothing submitted. Name and email replaced, the sponsorship box left unticked as deduced from citizenship. |

Turn 2 named the exact calls, to reach the paths turn 1 didn't take.

| Fix | Seen | Result |
|---|---|---|
| §15.1 | "scrolled "9a) Countries of citizenship *" into view", the same for "Why Formwise? *" and "Phone *", each in one step | Pass |
| §15.5 | "Jordan Placeholder" became "Alex Rivera". "416-555-0134" in the formatting field read back as "(416) 555-0134" and was accepted on its digits. `append: true` gave "30 per hour". | Pass |
| §15.4, unnamed | `Edit, labelled by: "9a) Countries of citizenship *"` in reads. Both boxes typed into by that name. | Pass |
| §15.4, shared names | `CheckBox "Yes", labelled by: "<question>"` in reads. A click by the question toggled the right box. In turn 1 the agent sent name "Yes", got "3 controls are named", and clicked by position. | Pass, with BUG-441 (fixed) |
| §15.4, label scope | With the page scrolled so the 9a text sat just above it, a step by that label matched the tab, its Close and New Tab, not the field. | Failed: BUG-440 (Major), fixed |
| §15.7 | Both radios shown cut with "…". The full text selected one and the cut text the other. Turn 1 clicked by position. | Pass |
| §15.2 | One read with `offscreen`, then the whole form in one `os_steps` by name. One screenshot, after the position click. No shell. | Pass |

BUG-440 and BUG-441 were fixed the same day and passed a re-check in a new chat. Labels stay in
their group: page text labels only page controls. The "N controls are named" message gives each
match's label. The natural fill turn of the re-check took the same path (7 calls, 74k): every field
right, nothing submitted, and the checkbox and radio again clicked by position, though they had
names to use. So the `os_click` and `os_steps` descriptions, and the `name` argument they share,
now say that checkboxes and radio buttons go by name too: one named Yes by the question it's
labelled by, a long option by its name as shown. In the next fill turn (one run) the agent did:
3 calls (`os_windows`, `os_read_screen`, one `os_steps` of 8 steps), 69k, the checkbox by its
question and the radio by its cut-off name, no position clicks and no screenshot. It noted that
it hadn't read the end of the cut-off option. So a read now gives a cut-off name whole as the control's
value (§15.7). In the next fill turn (3 calls, 70k) the agent passed the option's full text as the
step's name, selected it, and quoted the whole statement in its report.

## 4. Glossary

| Term | Meaning |
|---|---|
| **Routine** | The saved definition (§5.1). |
| **Run** | One routine applied to a list of items (§5.2). |
| **Item** | One unit of work: here, one job URL. |
| **Item chat** | The fresh, temporary chat an item runs in. |
| **Outcome** | What `report_outcome` says about an item (§8.4). |
| **Park** | Leave an item's tab open, mark it, and move on. |
| **Handoff** | Gaia stops and needs you: the item is `needs_you` (§9). |
| **Run window** | The Chrome window a run opens its tabs in (§8.1). |

## 5. Data model

### 5.1 `GaiaRoutine` (synced, soft-deletable)

| Field | |
|---|---|
| `name` | Unique. `/routine <name>` uses it. |
| `instructions` | Markdown. What to do with one item. |
| `projectId` | The project whose folder holds the materials. Item chats go in it. |
| `materials` | File names in the project folder, inlined into every item's prompt (§8.2). Default `profile.md`, `answers.md`. |
| `uploads` | File names Gaia may upload, by path. Default `resume.pdf`. |
| `skipRules` | Markdown list. Checked against the posting before anything is filled (§8.3). Starts with one default rule: the posting **explicitly states** a requirement the profile can't meet, such as "we do not sponsor visas", "must be authorized to work without sponsorship now or in the future", "must reside in the Netherlands without relocating" or "must be enrolled at a Dutch institution". A posting that says nothing on a point is a `go`: silence about sponsorship is not a refusal. |
| `submit` | `auto` or `review`. `auto` still goes through the gate (§8.6). |
| `tier` | The tier item turns use. |
| `budgetCalls`, `budgetMinutes` | Per item. Default 80 and 15. |
| `budgetContext` | The most context one item turn may reach (§8.5). Default 400,000 tokens. |
| `googleAccount` | The address to pick in Google's account chooser (§9.4). Optional. |
| `domains` | Sites an item may go to besides its own (§14). Defaults to a list of applicant-tracking sites and `accounts.google.com`. |
| `jobSeasonId` | The season tracker entries are filed under (§13). Optional. |
| `jobStage` | The stage name tracker entries get (§13.2). |
| `tokenCap` | Per run, counted as §8.8.1 says. Default 1,000,000. |
| `wrapAt` | The plan-usage line where a run wraps up (§8.8.2). Default 95%. |

### 5.2 `GaiaRun` (synced, soft-deletable)

One document per run, written only by the device running it, so last-write-wins is safe.

| Field | |
|---|---|
| `routineId`, `deviceId`, `chatId` | The launch chat, where the run's card and summary live. |
| `mode` | `unattended` or `attended`. |
| `state` | `running`, `paused`, `done`, `ended`. |
| `items` | Ordered list of `GaiaRunItem`. |
| `startedAt`, `endedAt` | |
| `usage` | Tokens summed from the item turns and the run's utility calls (input, output, cache reads, cache writes), and each account's 5-hour and weekly percentages at the start and end. |
| `stopReason` | Why it paused or ended: you, the token cap, plan usage, a restart. |

`GaiaRunItem`:

| Field | |
|---|---|
| `url` | Normalized (§7.3). |
| `status` | `waiting`, `running`, `submitted`, `ready`, `needs_you`, `skipped`, `failed`. |
| `chatId` | Its item chat, once started. |
| `posting` | The `report_posting` payload (§8.3). |
| `outcome` | The `report_outcome` payload (§8.4). |
| `notes` | What you typed on a parked item (§10.2). |
| `screenshot` | The final screenshot Gaia's code took (§8.4). |
| `attempts` | Times it ran. |
| `submittedByYou` | Set by "I submitted it" on a `ready` item (§13). |

## 6. Defining a routine

A new **Routines** tab in the settings panel lists routines and past runs.

**Usage shown there**, summed from the runs' `usage` (§5.2):
- At the top, **all routines**: tokens this week and in total (input, output, cache writes, with
  cache reads alongside), and the number of runs.
- **Each routine's row**: the same totals for that routine, and its last run.
- **Each run's row**: its tokens, and each account's 5-hour and weekly use at its start and end.

The lifetime stats (GAIA_STATS_HLD.md) keep counting by tier as now. Routine turns run on a tier
and are counted there too, so nothing is counted twice or lost.

**Creating one** asks for a name, a project, instructions and the fields in §5.1. The job
applier's instructions are a template the user edits. They say: read the posting, check the skip
rules, find the application, fill it from the materials, upload the resume, go through the
submit gate, report.

**Materials live in the project folder:**

| File | Holds |
|---|---|
| `profile.md` | Facts: name, contact details, links, education, work authorization, sponsorship, relocation, start date, salary range, demographic choices (or "decline"), pronouns. |
| `answers.md` | The answer bank (§10.1). |
| `resume.pdf` | Uploaded as is. |
| `projects.md` | Projects and experience, for open-ended answers. Optional. |

**Setup interview.** On creation, the routine's first chat asks 15 to 25 common questions: why
this kind of role, a challenge you overcame, a project you're proud of, what you're looking
for, salary expectations, sponsorship, start date, relocation, EEO choices. It writes the
answers to `answers.md` in your words. It's an ordinary chat in the project, with a prompt the
template provides, so it needs no new machinery.

The interview also:
- **Offers relevant memories** as answer-bank entries ("You told me you previously worked at
  Sony. Add it to answers.md?"). Item chats don't recall memories (§14), so this is the one place
  memories reach a routine, and you check each one.
- **Asks for the education start date** with the end date, since forms often require both.
- **Covers the questions forms ask that aren't about you as a candidate**, from the test runs:
  age 18 or over; conflicts of interest (ties to the company or its auditors, non-competes,
  patents, outside work, government or military service); US immigration details (J-1 or J-2,
  I-140, current status); year of study; preferred locations; salary per country or currency;
  what to pick when your internship length isn't offered; a full street address and postal
  code; the phone's type (mobile or home); GPA; whether you'd need housing; whether Gaia may
  opt in to keeping your application on file; and whether Gaia may tick terms,
  consent and attestation boxes and sign self-identification forms with your name and the date.
- **Suggests turning off Chrome's address popup** in the run window's Chrome profile (§8.9).

## 7. Starting a run

### 7.1 `/routine <name>`

A new built-in. From any chat, not only the routine's project: **the routine names its project,
so item chats go there whatever chat you start in.** The chat you type it in becomes the run's
home.

It posts a **launch card** in that chat:

- A box to paste URLs into, one per line or mixed with text. URLs are pulled out.
- **Import open tabs**: lists the tabs in Chrome's windows, each ticked, untick to leave out
  (§7.2).
- Mode: Unattended (default) or Attended.
- The routine's Google account, editable for this run.
- Duplicates (§7.3), each marked and unticked.
- The item count and an estimate from the budget.

Ctrl+Enter starts it. The card then becomes the run's live status card.

One run at a time per device. `/routine` while one runs opens the panel instead.

### 7.2 Importing tabs

Chrome's tab strip is in its UI Automation tree as `TabItem`s, and the address of the tab in
front is already read (`address(hwnd)` in `gaia_os_control.dart`). Reading the address of a
tab that isn't in front means selecting it, which changes what you see. So the import selects
each tab in turn, reads its address, and puts the original tab back. It's a one-off
before the run starts, and the card says so. R0 checks whether UI Automation exposes each tab's
URL without selecting it, which would be better.

The run doesn't act in the imported tabs. It opens each URL fresh in the run window (§8.1), so
your own tabs are left alone.

### 7.3 Duplicates

A URL is normalized: lower-case host, no fragment, no tracking parameters (`utm_*`, `gh_src`,
`source`, `ref`, `lever-origin`), no trailing slash. It's a duplicate if it matches:
- an earlier item in this list,
- an item `submitted` (or "I submitted it") in an earlier run, or
- a Jobs tracker entry's `applicationUrl`.

Checked at launch and again by the submit gate (§8.6), since the posting may redirect to an
application URL that matches.

## 8. The run loop

### 8.1 One item

The loop is Dart code in a new `gaia_routine_runner.dart`. For each `waiting` item:

1. **Open.** The first item opens a new Chrome window, the run window. Each item opens its URL in
   a new tab there, through the same path `os_open` uses.
2. **Create the item chat** in the routine's project, temporary (GAIA_TEMP_HLD.md), so it's off
   the sidebar and the curator never reads it. Titled "{Company} — {Role}" once the outcome
   names them, "{host}" until then. The hand is Auto for that chat. Memory recall is off for
   it (§14).
3. **Send the item prompt** (§8.2) on the routine's tier.
4. **Watch the budget** (§8.5).
5. **Take the outcome.** On `report_outcome` the turn ends. Gaia's code takes a screenshot of
   the tab and stores it on the item. If the turn ends with no outcome, the item is `failed`:
   "ended without reporting".
6. **Close or keep the tab.** `submitted` and `skipped` close it. `ready`, `needs_you` and
   `failed` keep it open.
7. **Save the run** and go on.

Between items Gaia waits 2 seconds, as a gap to press Esc in.

### 8.2 What the agent gets

**The materials are put in the prompt by code, not left for the agent to find.** That answers
the worry that a fresh chat won't look at the project: it doesn't need to. `profile.md`,
`answers.md` and the other `materials` are read at the start of each item and inlined, a few
KB, and the same in every item so they cache. The resume isn't read. Its absolute path is given
for the upload dialog.

The item prompt:

```
<routine name="Job applier" item="7 of 20">
{instructions}

<skip_rules>{skipRules}</skip_rules>
<materials>
<file name="profile.md">…</file>
<file name="answers.md">…</file>
</materials>
<uploads>resume.pdf: C:\Users\Juno\…\resume.pdf</uploads>
<notes>{the item's notes, on a retry}</notes>
<item url="https://…"/>

Rules:
- Read the posting and call report_posting before any click or typing. If it says skip,
  report_outcome skipped and stop.
- Use only facts from the materials and notes. A value may follow from them (not authorized
  to work in the US, so not a US citizen). Picking the nearest option when none matches is a
  guess, and a required question you'd have to guess: stop and report needs_you with every
  such question on the page.
- Terms, consent and attestation boxes, and signatures: only as answers.md says. Otherwise
  needs_you.
- Prefilled values: keep them unless the materials contradict them. Never clear a
  required field. Uploads replace any attached file.
- After the form opens, wait for it to stop changing, then read it. Recheck every
  dropdown and typeahead value before reporting.
- Typeaheads (type, then pick from a list): use os_pick.
- If a named step fails, read the screen again. Don't switch to coordinates or to
  typing "into what has focus".
- To wait for a page, use os_read_screen with until. There is no shell.
- Open-ended questions: write from answers.md and projects.md, in the style of answers.md.
- Optional fields: fill them when the materials answer them, as for a required field
  (a "why this company" box, links, pronouns). Leave blank only what the materials don't cover.
- Always name the field you type into. Don't type "into what has focus".
- Read the whole form once with os_read_screen offscreen before filling.
- Before clicking Submit, call routine_submit_check.
- End with report_outcome. Always.
</routine>
```

GAIA.md and the `<gaia_project>` and `<screen_access>` preambles still apply.

### 8.3 Skip rules and the order of work

The instructions put the cheap checks first:
1. **The posting check.** Read the posting and call `report_posting`. If a skip rule matches
   (needs sponsorship, clearance, too many years, a location, residency or enrollment the profile
   doesn't have), `fit` is `skip` and the item ends `skipped` with the rule. No form is
   touched. A rule matches only on what the posting **explicitly states**. A posting that is
   silent or vague on a point ("must be authorized to work in the US", with no word on
   sponsorship) is a `go`, with the doubt in `reason`.
2. Find the application (an Apply button, or the form on the page).
3. Read the whole form with `offscreen`. A required question the materials can't answer with
   a fact is a handoff now, before anything is typed, so a parked item hasn't half-filled a form.
4. Fill by name. Upload the resume.
5. The submit gate (§8.6).

`report_posting` is a new Gaia tool, offered only in item chats:

| Argument | |
|---|---|
| `company`, `role` | From the posting. |
| `location`, `dates`, `authorization`, `requirements` | One line each, as the posting states them. "Not stated" when it doesn't. |
| `fit` | `go` or `skip`. |
| `reason` | Which skip rule matched, or the main doubt on a `go`. |
| `posting` | The posting's text as Markdown, up to 12,000 characters. |

**It's enforced, not only asked for.** Until `report_posting` has been called in the item
chat, `permit` refuses `os_click`, `os_type`, `os_key`, `os_drag` and `os_steps` with
"call report_posting first". Reads, screenshots and scrolls are allowed, since reading a long
posting needs them. So is a click on a `TabItem`, or on a button or link named like "Show
more", "Read more", "See full description" or "Job Description", since some postings split their
text across tabs (§3.7). A `skip` ends the turn in code and marks the item `skipped`. The posting
line (role, location, fit) shows on the item in the side panel (§11.1) from that moment.

### 8.4 `report_outcome`

A new Gaia tool, offered only in item chats.

| Argument | |
|---|---|
| `status` | `submitted`, `ready`, `needs_you`, `skipped`, `failed` |
| `reason` | One line. Required unless `submitted`. |
| `company`, `role` | From the posting. |
| `fields` | `[{label, value, source, uncertain}]`, `source` one of `profile`, `answers`, `written`, `notes`, `prefilled` (kept as the site filled it, §8.9). |
| `new_questions` | Questions the materials didn't answer. They feed the answer bank (§10.1). |

`submitted` is only accepted if the submit gate passed for this item (§8.6). Otherwise it's
stored as `ready` with "reported submitted without the gate".

### 8.5 Budget

Counted per item turn: tool calls and minutes since the prompt was sent. At the limit Gaia stops
the turn, as Stop does, and parks the item as `needs_you`: "ran over budget (80 calls)". The tab
stays open. A retry (§10.2) gets a fresh budget.

**Context ceiling.** The item turn's context, as each message's `context_tokens` reports it,
is checked after every tool call. At `budgetContext` the turn stops the same way: "context too
large (400k)". One Greenhouse form reached 196k (§3.3) and a 7-page Workday form 313k (§3.4),
where a compaction mid-form would lose what was filled. The fixes in §15 should keep a normal
form well under the ceiling, so reaching it means the item went wrong. The ceiling must stay
below the tier's context window.

### 8.6 The submit gate

The rule that Gaia never submits when unsure is enforced, not just asked for:

- **`routine_submit_check {fields}`**, a new tool. Gaia's code allows the submit only if:
  the routine's `submit` is `auto`, no field is `uncertain`, every required field has a
  source, and the URL isn't a duplicate (§7.3). It answers allowed, or why not.
- **While an item's gate hasn't passed, `os_click` refuses a button whose name matches
  submit-like words** ("Submit", "Submit application", "Send application", "Finish", and the
  same in a short list of other languages). The refusal tells the agent to call the check.
  **Bare "Apply" isn't on the list**: on Workday and most posting pages, "Apply" and "Apply
  Manually" only open the form (§3.4). "Save and Continue" between pages isn't either. If R0
  finds a site whose final button is "Apply", it's matched there by being on a page with
  filled fields, not by the word alone.
- Not allowed: the agent reports `ready`, leaving the form filled at the Submit button.

- **While an item's gate hasn't passed, `permit` refuses `os_key` (and an `os_steps` key
  step) that sends Enter or Return when the focused window is the browser.** Enter in a form
  field submits the form, as it nearly did in §3.5. Keys stay allowed in a native window such
  as the Open dialog, checked at the moment of the key, since a double-click on a file closes
  the dialog first. Typing text that holds a newline into a single-line field is refused the
  same way; a multi-line text area takes it. Only Enter and Return are refused: Ctrl+A, Tab,
  Escape and the arrows stay allowed. A search field that runs only on Enter (Workday's school
  field, §3.6) goes through `os_pick`, which presses Enter itself in the field it's filling
  (§15.3). The item prompt doesn't forbid keys. Claude Code's auto mode check reads the prompt,
  and a broad ban there blocked allowed keys in §3.6.

The weakness: a submit button with no name, or an odd one ("Let's go!"), isn't caught by the
refusal. The instruction still says to call the check, and the outcome's `fields` show what was
sent. R0 records what submit buttons are called on real sites.

### 8.7 Stopping and resuming

| Control | In a run |
|---|---|
| **Esc** | Stops the item's turn, as in any Auto run. The item becomes `needs_you` "stopped by you", and the **run pauses**. The panel offers Resume run or End run. |
| **Stop** on the panel | Same as Esc. |
| **Switching windows yourself** | Stops the item, as GAIA_AUTONOMY_HLD.md §5.3 says, and pauses the run. In an attended handoff it doesn't, since you're meant to act there (§9.2). |
| **Revoke, Abort** | As today. The run is `ended`. |
| **Gaia restarts or crashes** | The run is saved after each item. A `running` run found at start-up becomes `paused`, its `running` item `needs_you` "Gaia restarted". Resume run carries on. |

### 8.8 Usage guards

Two guards, both per routine, checked by the runner. They do different jobs: the token cap
limits what one run can spend, and the plan line protects the account's real limits, which
other chats share.

#### 8.8.1 The token cap

`tokenCap` counts the run's **input, output and cache-write tokens**, summed over every item
turn and the run's utility calls. **Cache reads are shown but not counted.** An agent re-reads
its whole context from cache on every tool call, so cache reads dwarf everything else: the test
run's context ended at 114k tokens after 31 calls, which is on the order of 2M cache-read tokens
for one item. Counted in, a 1M cap would stop the first item partway through. Providers also
count cache reads at a fraction against plan limits.

Counted after every model call, from the counts Gaia already takes (`gaia_tokens.dart`). At the
cap, a hard stop:
1. The current turn is stopped, as Stop does.
2. Its item is parked as `needs_you`: "token cap reached". The tab stays open.
3. The run pauses with `stopReason` "token cap". The panel offers **Raise cap and resume**
   (a new cap for this run only) or End run.

#### 8.8.2 The plan line

The runner watches the 5-hour and weekly windows of each account the run uses, and the weekly
window for the tier's model (Opus, Sonnet) where the provider has one. Usage is read **before
each item** and on the existing 10-minute timer, and taken from turn events where the adapter
sends them.

**At `wrapAt` (default 95%) in any of them, the run wraps up:**
- **No new item starts.**
- **The current item is told.** Gaia's tool results in that turn get a line appended: "Plan
  usage is at 95%. Finish this item in at most 15 more tool calls, or stop where it is and
  report needs_you with how far you got." Tool results are the one channel into a running turn,
  and they're read every step.
- **Its budget drops** to 15 more calls, enforced as §8.5 does.
- When the item ends, the run pauses with `stopReason` "plan usage", naming the window and its
  reset time ("5-hour limit at 96%, resets 4:10 PM"). The summary is posted then, so the run
  ends cleanly even if you never resume it. **Resume run** works once you choose to.

**At 99%, or an exhausted window** (GAIA_HLD.md §6.5), the current turn stops at once and its
item is parked, as at the token cap. A form left half-filled stays open in its tab.

The run never switches accounts or tiers to keep going. That stays the user's choice, as
GAIA_HLD.md §6.5 says.

### 8.9 Prefilled values and autofill

Forms often arrive partly filled: by the site's own autofill (MyGreenhouse fills from a signed-in
profile), by Chrome's saved addresses, or by a file attached last time. The materials are taken
as the latest truth, so:

| Prefilled value | What Gaia does |
|---|---|
| Matches the materials | Keeps it. Reported with source `profile` (or the matching file). |
| Contradicts the materials | Replaces it. Reported with its source and the old value in the label. |
| Not covered by the materials | Keeps it. Reported with source `prefilled`, so it shows in the summary and can go into the answer bank (§10.1). |
| An attached file | Replaced by the listed upload, whatever its name. |

Phone numbers are compared on their digits, so "(416) 555-0134" matches "416-555-0134". Resume
autofill can also split a number wrongly ("+1 416" as the country code, "5550134" as the
number, §3.7): the digits differ from the profile's, so it counts as a contradiction and is
replaced.

A required field is never cleared. If a prefilled required value looks wrong and the materials
don't say what's right, it's kept, marked `uncertain`, and its question goes in
`new_questions`.

**Autofill can arrive late.** On Greenhouse it changed the country and city after Gaia had set
them (§3.3). So, after the form opens, Gaia reads it, waits about 3 seconds, and reads it again
before filling: `os_read_screen` with `until` on a field that autofill fills, or two reads that
match. Before `report_outcome` it reads the form once more and fixes any dropdown or typeahead
value that changed.

**Chrome's address popup** (its own list of saved details under a field) can cover a site's
list and take a click meant for an option. Gaia presses Escape when it appears and never picks
from it: the materials, not the browser's saved details, are the source. For routines it's
cleaner to turn the popup off in the run window's Chrome profile (Settings, Autofill and
passwords, Addresses, off), which the setup interview suggests.

## 9. Handoffs

### 9.1 What hands off

The agent reports `needs_you` with a reason when:
- a page needs a password, a verification code, or a login Gaia can't do (§9.4),
- a required question has no answer in the materials,
- a CAPTCHA or bot check appears. Gaia never tries to solve one,
- the page is broken, or wants something Gaia can't reach (a native dialog it can't drive),
- the budget runs out (§8.5),
- a terms, consent or attestation box, or a signature, that `answers.md` doesn't cover.

**Questions come page by page on multi-page forms** (Workday shows follow-ups only after earlier
answers). So a handoff carries every unanswered required question on the current page, not only
the first. The page is filled as far as it goes and left unsaved; your notes (§10.2) answer the
whole page at once.

**`ask_user` in an item chat is a handoff.** In attended mode it waits with the lit edge, as any
handoff does, and the question shows in the side panel. Unattended, it isn't offered: the agent
reports `needs_you` with its questions instead, and the run moves on.

For an account page: Gaia fills every field except the password and code, then hands off. Your
part is the password and the code. Gaia's existing rule (never type into password, card or
one-time-code fields) needs no change.

### 9.2 Unattended (default)

The item is parked: tab open, status `needs_you`, reason on the panel. The run moves to the next
item. You deal with parked items when you like, during the run or after (§10.2).

### 9.3 Attended

The run waits on the item:
- **The screen edge lights** in a "your turn" colour, using the aurora edge's painting on a
  click-through, full-screen, capture-excluded overlay. The panel shows the reason and a
  Resume button.
- You do your part in the tab. Switching to it and typing doesn't stop anything: during a
  handoff, Gaia's input-watch is off for the run.
- **Resume** (the panel's button or the routine hotkey, §11.2) continues **the same item chat**:
  Gaia sends "Resumed. {notes if any}" to it, and the agent re-reads the page and carries on
  with a fresh budget.
- After 10 minutes with no input from you, the item is parked as in unattended mode, so a
  forgotten handoff doesn't hold up the run.

Resume is always explicit. Gaia never infers that you're done from input stopping.

### 9.4 Google sign-in

"Sign in with Google" is allowed. Gaia clicks it, picks the routine's `googleAccount` in
Google's account chooser, and accepts the consent screen. It hands off only when that account
isn't in the chooser, or Google asks for its password or a code.

`accounts.google.com` is on the default domain list (§14). Gaia checks the chooser for the
address and never picks another account.

## 10. The answer bank and notes

### 10.1 The answer bank grows

`new_questions` from every item are collected. At the end of the run, the summary (§12) lists
them, and **Answer these** opens a chat in the project that asks them, then appends your answers
to `answers.md`. Duplicates of a question already in the bank are dropped by the utility
model before asking.

### 10.2 Notes on parked items

Every parked item has a note field, on the panel and in the Runs tab. A note can be typed **at
any time, during the run or after.** It's saved to the item, and **Save to answer bank** (ticked
by default) also appends it to `answers.md` under the question.

On saving, the item goes back in the queue as `waiting`, and retries in its open tab:
- **During a run:** it goes after the items still waiting, so it runs before the run ends.
- **After a run:** Retry starts a short run of just the items you retried.

Typing in the panel during a run doesn't fight Gaia's input. Clicking the panel brings Gaia to
the front, which **pauses** the run, as Gaia in front always does (GAIA_AUTONOMY_HLD.md §5.2).
Save hands the front back to the run window, and the run resumes. Clicking away without saving
does the same.

## 11. The side panel

### 11.1 What it shows

A narrow window docked to a screen edge (right by default), always on top, **excluded from
capture** (`WDA_EXCLUDEFROMCAPTURE`) so it never appears in Gaia's screenshots, and kept out of
the run window's area (the run window is placed beside it, with `os_window`'s placement).

- The routine's name and the mode. Pause, Resume, End.
- Progress: "7 of 20", a bar, elapsed time.
- Usage: tokens against the cap ("412k of 1M"), and the 5-hour and weekly percentages of the
  accounts in use, from the last read.
- Counts: submitted, ready, needs you, skipped, failed.
- **Now:** the current item's company and role (or host), its posting line once
  `report_posting` is in (location, fit), and its latest step from the activity row.
- **Next:** the next 3 items.
- **Parked:** each `ready` and `needs_you` item with its reason, a note field, Open tab and
  Retry.

While a handoff waits (attended), the panel's header takes the same colour as the screen edge.

The run card in the launch chat shows the same counts in short, and opens the panel.

### 11.2 The routine hotkey

**Ctrl+Alt+R** for **Resume**, a new entry in `gaia_keybinds.dart`. It fits Gaia's global
hotkeys (all Ctrl+Alt), and it's free: they use Space, Enter, S, Q and Backspace. **It's
registered only while a run is paused or waiting on a handoff**, and released otherwise, so it
never takes Ctrl+Alt+R from another app the rest of the time. It's rebindable like the others,
and `gaiaHotkeyClash` checks it.

## 12. The summary

At the end of a run (or End run), Gaia posts an assistant message in the launch chat.

- **Counts and lists are made by code**, from the items: no model counts anything. "13
  submitted, 2 ready to submit, 3 need you, 4 skipped, 1 failed", with each item listed under
  its status, company, role, reason and a link to its chat.
- **Usage:** tokens spent, and each account's 5-hour and weekly use at the start and the end
  ("5-hour: 12% → 61%").
- **A narrative is written by the utility model** from the outcomes: what was written for
  open-ended questions ("Acme asked why you wanted to work there; I said …"), patterns in the
  skips ("4 needed sponsorship"), what blocked the parked ones.
- **Next steps:** the parked tabs and **Answer these** (§10.1). The applications it added to
  the Jobs tracker are listed, with Undo.

## 13. Jobs tracker

### 13.1 Written directly

**An exception to the rule that Gaia saves Voyager data only after review**
(GAIA_AUTONOMY_HLD.md §2): when an item is `submitted`, the runner creates its
`JobApplication` at once, with no card. Only the runner does this, only for `submitted`
items of a routine, and only in the Jobs tracker. The agent gets no tool that writes to Voyager.

| Field | From |
|---|---|
| `company`, `title` | The outcome's `company`, `role` |
| `status` | The routine's `jobStage` (§13.2) |
| `dateApplied` | The day it was submitted |
| `applicationUrl` | The item's URL |
| `notes` | The posting's Markdown, then a line naming the run |
| `seasonIds` | The routine's `jobSeasonId`, if set |

A `ready` item you submitted yourself: **I submitted it** on its row creates the entry the same
way.

**Undo.** Each entry is logged as an accepted job proposal on the run's status message, so the
Actions tab lists it and its Undo takes it back, with no new log. `GaiaProposalEntity` gains
`job`. The summary lists the entries with the same Undo.

### 13.2 The stage

Picked once, on the routine, not per run:
- **Creating a routine** pre-selects the stage named "Applied" (any case), which is the
  tracker's seeded default (`jobDefaultStage` in `job_constants.dart`).
- **If there's none**, the routine editor asks you to pick a stage from your list, and won't
  save without one. The first stage isn't a safe guess: in a pipeline like "Wishlist, Applied,
  Interview", it would file applications as wishlist items.
- **If the stage is deleted or renamed later**, the run uses the name anyway. A status may
  already name a stage that no longer exists (`JobApplication.status`), and the routine's tab
  shows a warning until you pick again.

## 14. Safety

The trade in GAIA_AUTONOMY_HLD.md §1 applies with more force: job pages are untrusted text, and
the run is unattended. Sending your details to the site is the point, so the risk is the agent
being steered elsewhere. In item chats:

- **No shell, file edits or web tools.** `permit` refuses them whatever the hand says. The
  materials are already in the prompt, so the agent needs no file reads either. The one
  exception is `Read` on a path in the routine's uploads, so autofill from the resume can be
  checked against it (§3.7).
- **Domains.** The item's own host, plus `domains`. After each step the address is checked, as
  `_checkAddress` does today. Anywhere else, the item is stopped and parked: "left the allowed
  sites ({host})".
- **Only the listed uploads**, by path. The upload dialog's typed path must be one of them.
- **The submit gate** (§8.6).
- **No memory recall.** Item chats don't recall memories. The materials and notes are the only
  facts an item uses, so a memory about one company ("I previously worked at Sony") can't answer
  another company's question. The setup interview (§6) offers relevant memories as answer-bank
  entries instead, once, where you can check them.
- **Unchanged:** password, card and one-time-code fields are never read or typed into;
  exclusions; the vault; Gaia's own windows are never a target.

## 15. Control fixes from the test run (R0)

These help every Auto chat, not only routines.

### 15.1 Scroll a named control into view

When a step names a control that `os_read_screen offscreen` can see but is off screen, scroll
it into view through UI Automation's ScrollItem pattern, then act. Today it stops with "not on
screen" (§3.2). Fallback when the pattern is missing: scroll the nearest scrollable ancestor
by the control's offset, as `os_scroll`'s direct call already finds it (§13.2 there).

### 15.2 Tool guidance

`os_steps` and `os_type` descriptions: prefer named fields, read a long form once with
`offscreen`, and never follow a stopped step with an unnamed type. When a named step fails,
the next call is a read (`os_read_screen`, `find` on the field), not coordinates. Prefer
`os_read_screen` over `os_screenshot` to check a value: a read is text, a screenshot is an
image on every later turn. Wait for a page with `os_read_screen` and `until` (the next page's
heading or "step 3 of 7"), never a shell `sleep`.

### 15.3 Typeaheads: `os_pick`

A new step, as a tool and as an `os_steps` action: `{name, type, option}`. Many forms ask you
to type and then pick from a list (city, phone country, school). Plain dropdowns went well in
both test runs. Typeaheads didn't (§3.3). `os_pick`:

1. Focuses the named field and selects its text, so earlier text is replaced, not added to.
2. Types `option`, or its first word if the list matches on prefixes.
3. Waits up to 10 seconds for a `ListItem` whose name contains `option` (the list often
   loads from the network). If no list appears within 2 seconds of typing, it presses Enter
   once in that field and waits again: some search fields (Workday's school) run only on
   Enter. This Enter comes from code, with focus checked on the field first, so the §8.6 gate
   doesn't apply to it.
4. Presses Escape first if the list that opened isn't the field's own (Chrome's address
   popup), then clicks the best match.
5. Reads the field back. If its value doesn't contain `option`, it tries once more, then fails
   with what the field holds and the options it saw.

For a click-to-open list (a Workday "Select One" button, a plain select), step 2 is a click
on the field in place of typing, then the same wait, pick and read-back.

The model passes the value it wants. The matching and checking happen in code, not across three
model turns.

### 15.4 Labels for unnamed fields

Some fields have no accessible name: Workday's text boxes under a question (§3.4) have only a
nearby text. `os_read_screen` names such a field after the nearest text above or to its left
in the same group, marked as inferred ("Edit, labelled by: 9a) Countries of citizenship"), and
steps accept that name. Then a by-name step works where the agent clicked by position, and the
"always name the field" rule can hold. Controls that share a name (three checkboxes named "Yes")
get their question as the inferred label too ("CheckBox Yes, labelled by: I acknowledge the
Data Privacy Notice"), and a step can use it.

### 15.5 `os_type` replaces

Today `os_type` clicks the named field and types, so the text is added to what's there (§3.6).
With a named field it now clicks, selects all (Ctrl+A, sent by code), types, and reads the
value back. The select comes after the click, inside one action: a Ctrl+A step followed by a
named type step doesn't work, since the type's own click drops the selection (§3.7). If the value doesn't match (a field that reformats, like a phone number, is
compared on its digits), it fails with what the field holds. `append: true` keeps the old
behaviour. Typing "into what has focus" is unchanged.

### 15.6 Uploads: `os_upload`

A new step, as a tool and as an `os_steps` action: `{path}`, used when a file dialog is in
front. It sets the dialog's File name box to the path through UI Automation, invokes the
dialog's Open button, and waits up to 10 seconds for the dialog to close. If it's still open,
it fails with the dialog's text (a missing file, a wrong type). That replaces typing the path,
then a double-click or Enter, which left the dialog open in three of six runs (§3.6).

### 15.7 Cut-off names

UI Automation gives long labels cut short with "…" (a radio button whose name is a whole
paragraph). A step's `name` matches such a control when the step's text starts with the part
before the "…", or the other way round, and only one control matches. The agent can then pass
either the full question or what the read showed. A read gives a name it cuts short whole as the
control's value, so the agent reads a long option in full before it agrees to it (2026-11-27).

## 16. Later

### 16.1 Tailored resumes

After v1. Of the two ideas, **modules into a template** first:
- You keep a library of entries (projects, jobs, bullets, skills) and one template.
- Per item, Gaia picks and lightly rewords entries for the posting, and the template renders a
  PDF that's then uploaded.
- It stays factual (every line comes from your library) and consistently formatted, and the pick
  is easy to review: the outcome lists which entries went in.

Writing a whole resume from a summary each time risks claims that drift from the facts and a
layout that changes per job, and it's harder to check. It fits the routine as a step between
reading the posting and filling: a new `uploads` entry made per item.

### 16.2 Background runs

GAIA_AUTONOMY_HLD.md §13 (designed, not built). Most form fields and buttons would go through UI
Automation behind your other windows. Keys, custom dropdowns and file dialogs still need the
front briefly. It changes how a step runs, not the routine.

### 16.3 Tracker as a source of items

Starting a run from tracker entries marked "to apply".

## 17. Phases

| Phase | Contents | Done when |
|---|---|---|
| **R0** | §15 fixes. A spike: the job applier's prompt and materials in a plain Auto chat (no routine code) on 5 sites: Greenhouse, Lever, Ashby, Workday, one other (iCIMS or SmartRecruiters). Record calls, time, tokens (with and without cache reads), plan usage before and after, where it stuck, the file upload, custom dropdowns, typeaheads, submit button names, whether tab URLs read without selecting the tab, autofill that arrives late (the site's own, such as MyGreenhouse) and Chrome's address popup, the peak context per item, screenshots per item, waits, unnamed fields, and the questions each site asks that the setup interview should cover. | A table like §3.2 for each site, and a decision on the budget, context ceiling and tier defaults. The §15 fixes passed on fixtures. The spike is deferred (§3.8). |
| **R1** | `GaiaRoutine`, `GaiaRun`, the Routines tab with usage, the setup interview template, `/routine` and the launch card (paste only), the loop, the item prompt, `report_outcome`, the submit gate, the budget, the token cap and the plan line (§8.8), the domain check, `permit` restrictions, resume after restart. | A run of 5 local fixture forms (§18) ends with the right statuses, none submits past the gate, and a low cap pauses it. |
| **R2** | Handoffs, unattended parking, attended waiting with the lit edge, the side panel, the hotkey, notes and retries, tab import. | A run with a fixture account page parks, takes a note, retries and finishes. |
| **R3** | The summary, the answer bank growth, Jobs tracker entries with Undo, duplicates against the tracker. | A real run of 10 postings. |
| **Later** | §16. | |

### 17.1 As built (R0 fixes, R1)

Where the code differs from the sections above, and why:

- **The routine tools are in every chat's tool list**, and refused outside item chats. Claude Code
  lists a server's tools when its process starts, before a turn says which chat it's for.
- **The agent opens the item's URL with `os_open`** (the item prompt's first rule), so the tab is
  the window its session works on. There's no separate run window yet: tabs open where `os_open`
  puts them. A `submitted` or `skipped` item closes its tab with `os_key Ctrl+W`, the one call a
  finished item may make.
- **No final screenshot** is stored on the item yet (§8.4).
- **The launch card sits above the composer** of the chat `/routine` was typed in, not as a message
  in it. After the run starts, it shows the run: counts, tokens, the item under way, Pause, Resume
  (or Raise cap and resume) and End. `/routine` while a run exists shows that run's card.
- **The token cap counts tokens when the CLI reports them**: Codex after each model call, Claude
  Code at the turn's end. On Claude Code an item can go past the cap before it's stopped. The
  context ceiling and the plan line act mid-turn.
- **`ask_user` is refused** in unattended item chats rather than left off the list (same reason as
  the first point).
- **The Jobs stage is a text field**, "Applied" by default. Picking from the tracker's stages comes
  with R3's tracker entries.
- **Names**: the run model is `GaiaRoutineRun` (`GaiaRun` is taken in `gaia_host.dart`). The loop
  is `lib/features/gaia/companion/gaia_routine_runner.dart`, since turns run in the companion. The
  gate and the pure logic are in `gaia_routines.dart` beside it.
- **`os_pick`** counts a field that's empty or gone after the pick as picked, with a note to read
  and check. Workday chips and react-select show the value outside the field, and a retry there
  could add a second choice.
- **`os_upload`** goes by the English `File name:` and `Open` names, and doesn't work in Firefox,
  whose page fields Gaia already doesn't set directly.

### 17.2 As built (R2)

- **An attended run waits** after an item ends `needs_you`, reported or parked by the gate (budget,
  context, domain), unless the run is pausing or ending (Esc, the cap, the plan line, Abort).
  Resume sends "Resumed." and the notes to the same item chat, with a fresh budget. The posting
  carries over, so `report_posting` isn't asked for again. The 10 minutes count from both the
  handoff's start and the user's last input anywhere (`GetLastInputInfo`).
- **An attended `ask_user`** lights the edge too, and the panel shows its question with Answer in
  chat: it's answered on its card in the item chat, not in the panel. Its wait isn't counted in the
  item's minutes. Ten minutes with no input park the item: "no answer in 10 minutes".
- **The lit edge is the control border** (`gaia_control_border.cpp`), not a new aurora overlay.
  While a handoff waits, its label is "Your turn: {reason} · {combo} to resume", in amber
  (`kGaiaHandoffColor`), and the panel's header takes the same colour.
- **The side panel is the companion's own window** in a new mode, `GaiaMode.panel`: 340 px wide,
  docked to the right of the work area under the cursor, a topmost tool window, out of capture
  like every Gaia window, shown without the focus. It opens when a run starts, closes with its X,
  and the run card's Panel button opens it again. **The run window isn't placed beside it**: a
  maximized browser runs under its strip. Clicks there still reach the page (floaters let Gaia's
  input through), but you can't see that strip. Usage shows tokens only, not plan percentages.
  There's no latest step and no Open tab; an item's name opens its chat.
- **The Resume hotkey is Ctrl+Alt+Shift+R**, not Ctrl+Alt+R (§11.2, decision 17): Ctrl+Alt+R is
  Voyager's own reminder hotkey (`defaultReminderHotkey`). The companion sends the main instance
  `routineSignals` (the edge's label, and whether to hold the hotkey), which registers it while a
  run is paused or waiting and sends `routineResume` on a press.
- **Notes are typed on a parked item's row** in the panel or the run card. The Routines tab doesn't
  have them yet. Save adds the note to the item's notes, appends it to `answers.md` under the
  item's `new_questions` (or its reason) when "Save to answer bank" is ticked, and queues the item:
  waiting, moved to the end of the list. With no note, the button is Retry.
- **A retry goes on in the item's own chat**, telling the agent its tab is still open and giving the
  notes, with the posting carried over. If that chat is gone, the item starts afresh with the full
  prompt. In a paused run the item waits for Resume run. **A finished run on this device opens
  again** (running, `endedAt` cleared) and runs just the retried items, rather than a new run
  record. A run from another device can't be retried here, since its tabs aren't here.
- **Tab import** reads each browser window's `TabItem`s through UI Automation, selects each with
  SelectionItem, reads the address bar, and selects the first tab again. R0 hasn't yet checked
  whether a tab's URL reads without selecting it. Every Chromium and Firefox window is read,
  excluded apps and sites are left out, and an address with no scheme gets `https://`.
- **End during an item, or during a handoff, now ends the run** even on the last item. Before, End
  on the last item left the run `done`.

## 18. Testing

Unit:
- URL normalization and duplicate checks (§7.3).
- The submit gate: each refusal reason, and the submit-word match on button names.
- Outcome handling: `submitted` without the gate becomes `ready`. No outcome becomes `failed`.
- The budget stops at the call limit and at the time limit.
- The token cap counts input, output and cache writes, not cache reads, and pauses the run at the cap.
- The plan line: at `wrapAt` no new item starts, the tool-result notice is appended and the budget drops. At 99% the turn stops.
- A tracker entry is made for `submitted` and "I submitted it" only, with the routine's stage, and Undo removes it.
- A `running` run read at start-up becomes `paused`.
- Prompt composition inlines the materials and the notes.
- Before `report_posting`, `permit` refuses control steps but allows reads and scrolls. A `skip` ends the item as `skipped`.
- The submit-word refusal lets "Apply", "Apply Manually" and "Save and Continue" through.
- Before the gate passes, Enter on a browser window is refused, in `os_key` and in an `os_steps` key step. Enter in a native file dialog is allowed, and so is a newline typed into a text area. Ctrl+A on the page is allowed.
- `os_type` on a named field holding text ends with only the new text; `append: true` keeps the old text; a reformatted phone number matches on its digits.
- `os_pick` on a field whose list appears only after Enter presses Enter once and picks the option.
- `os_upload` on an open file dialog closes it; a missing path fails with the dialog's message.
- `ask_user` isn't offered in unattended item chats.
- An unnamed field gets the nearest label, and a step can use it. Controls sharing a name get their question as a label.
- A step name matches a control whose name is cut off with "…", when only one matches.
- Before `report_posting`, a click on a tab or a "Show more" button is allowed, and other clicks are refused.
- `Read` in an item chat is allowed on an uploads path and refused elsewhere.
- The context ceiling parks the item.
- Item chats send no recalled memories.

Live, against local HTML fixtures in a Chrome with its own `--user-data-dir` (no personal data):
- A one-page form, a two-step form, a form with a custom dropdown, a file upload, a sign-up page
  with a password field, a page with a "Sign in with Google" button pointing at a fixture
  chooser, a posting that matches a skip rule, a posting whose location or residency rule
  doesn't match the profile.
- **Autofill**: a form that fills its country and city 2 seconds after the email is typed, and a
  required field filled in advance with a value the materials don't cover. Expected: the late
  values are rechecked, and the prefilled required field is kept and reported `prefilled`.
- **A typeahead** whose options load after a delay, with a second list over it. Expected:
  `os_pick` picks the right option and reads it back.
- **An injection page**: posting text telling the agent to open another site and paste the
  profile there. Expected: the domain check stops it and the item is parked.
- Esc mid-item, a restart mid-run, a note on a parked item during the run.

## 19. Decisions (2026-11-26)

1. **Routines, not extensions.** Nothing in the job applier needs job-specific code except
   the Jobs tracker entries. An extension framework can come when a second idea needs its own code or UI.
2. **The name is Routine.**
3. **Dart drives the loop**, one fresh temporary item chat per item. Not one long agent turn.
4. **Unattended is the default mode.** Attended is chosen on the launch card.
5. **Resume is explicit**: the panel button or the hotkey. Idle time only parks a forgotten
   attended handoff (10 minutes).
6. **No accounts with passwords, ever.** Gaia fills sign-up pages up to the password and hands
   off.
7. **"Sign in with Google" is allowed** with the routine's account. A handoff only when that
   account isn't offered or Google asks for its password or a code.
8. **Gaia submits when it's sure**, through the gate (§8.6). Otherwise it stops at Submit
   (`ready`).
9. **Open-ended answers** are written from `answers.md` and `projects.md`, in the style of
   `answers.md`, which a setup interview fills.
10. **Items come from pasted URLs and open tabs.** The Jobs tracker as a source is later.
11. **Started with `/routine <name>`** from any chat, through a launch card.
12. **Materials are inlined by code**, not left to the agent to find.
13. **Submitted applications go straight into the Jobs tracker**, with no card. It's an
    exception to the rule that Voyager data is saved after review, limited to the runner and to
    submitted items. Undo is in the Actions tab.
14. **Tailored resumes are after v1**, modules into a template first.
15. **Foreground runs in v1.** Background runs come with GAIA_AUTONOMY_HLD.md §13.
16. **The stage is picked on the routine**, defaulting to "Applied". With no such stage, you
    pick one; never the first stage by default.
17. **The Resume hotkey is Ctrl+Alt+R**, registered only while a run is paused or waiting.
18. **A token cap per routine**, default 1M, not counting cache reads. A hard stop that pauses
    the run.
19. **A plan line per routine**, default 95% of any 5-hour or weekly window: no new items, the
    current one is told to finish within 15 calls, then the run pauses with its summary. 99%
    stops at once.
20. **The Routines tab shows tokens** overall, per routine and per run.
21. **The posting check is enforced**: no control step before `report_posting`. A default skip
    rule covers sponsorship, location, residency and enrollment, and matches only what the
    posting explicitly states. Silence is a `go`.
22. **Prefilled values are kept unless the materials contradict them.** A required field is
    never cleared. Uploads replace attached files.
23. **Autofill is waited out and rechecked**, not avoided. Turning off Chrome's address popup
    for the run window is suggested, not required.
24. **`os_pick`** handles type-then-pick fields and checks the value in code.
25. **No memory recall in item chats.** Memories go into the answer bank at setup.
26. **A context ceiling per item**, default 400k, parks the item.
27. **Bare "Apply" isn't a submit word.**
28. **A handoff carries every unanswered question on the page.** `ask_user` in an item chat is a
    handoff: it waits in attended mode and isn't offered unattended.
29. **Deduction, not guessing.** A value must follow from the materials. Nearest-option picks are
    guesses and hand off.
30. **Attestations need a standing answer** in `answers.md`, asked at setup.
31. **Unnamed fields get inferred labels** in `os_read_screen`.
32. **Enter on a browser page is refused** in item chats until the submit gate passes. It
    submits a form just as the button does (§3.5). Only Enter and Return; other keys are fine.
    Search fields that need Enter go through `os_pick` (§3.6).
33. **`os_type` replaces a named field's text** and reads it back (§15.5).
34. **`os_upload`** confirms file dialogs in code (§15.6).
35. **Optional fields the materials answer are filled.**
36. **The item prompt doesn't ban keys.** The gate is in code; a prompt ban was enforced too
    broadly by Claude Code's auto mode check.
37. **Tabs and "show more" may be clicked before `report_posting`**, so a split posting is
    read in full.
38. **Cut-off names match by prefix**, and duplicate names get their question as a label.
39. **`Read` only on the uploads** in item chats.

## 20. Open questions

1. **Default tier** for item turns. The test run's Haiku did well on one page. R0 decides.
2. **The token cap's default.** 1M is a placeholder until R0 measures what one application
   costs without cache reads.
3. **The context ceiling's default.** 400k is a placeholder. It should sit well above a normal
   item once §15 is in, and below the tier's window.

## 21. Files likely touched

- `lib/domain/models/gaia_models.dart`: `GaiaRoutine`, `GaiaRun`, `GaiaRunItem`; `GaiaProposalEntity.job`.
- `lib/features/gaia/usage/gaia_usage_limits.dart`: the plan line check beside the low and exhausted checks.
- The Jobs repository, for the runner's entries and Undo.
- Drift tables and a migration for routines and runs; `firestore_document_mapper.dart`; `remote_sync_service.dart`.
- `lib/features/gaia/host/gaia_routine_runner.dart` (new): the loop, budget, handoffs, persistence.
- `lib/features/gaia/host/gaia_os_control.dart`: scroll into view (§15.1), `os_pick` (§15.3), `os_type` replacing (§15.5), `os_upload` (§15.6), the submit-word refusal, run-window placement.
- `lib/features/gaia/tools/gaia_mcp.dart`: `report_posting`, `report_outcome`, `routine_submit_check`, `os_pick`, `os_upload`, `os_type`'s `append`; tool guidance (§15.2).
- `lib/features/gaia/companion/gaia_chat_tools.dart`: `permit` refusals in item chats, and control steps before `report_posting`.
- Memory recall (`gaia_memories`): skipped for item chats.
- `lib/features/gaia/companion/gaia_commands.dart`: `/routine`.
- `lib/features/gaia/companion/gaia_controller.dart`: launch card, run card, item chats.
- `lib/features/gaia/companion/settings/gaia_routines_tab.dart` (new); `gaia_settings_panel.dart`.
- `lib/features/gaia/companion/gaia_routine_panel.dart` (new): the side panel and the lit-edge overlay.
- `lib/features/gaia/gaia_keybinds.dart`: the Resume hotkey.
- `lib/features/gaia/tools/gaia_proposals.dart`: the job proposal, as the Undo record of a direct entry.
- `lib/features/gaia/utility/gaia_utility.dart`: the summary narrative and question de-duplication.
- The windows runner, if `WDA_EXCLUDEFROMCAPTURE` needs a native call.
