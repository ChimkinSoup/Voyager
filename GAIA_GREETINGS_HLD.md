# Gaia — New-Chat Greetings (HLD)

Status: **Built (2026-11-15).** Unit, controller and widget tests (§8) pass, and the live
pass passed the same day in `gaiaqa` (dummy mode). The lines in §6 are still a draft for
review.

## 1. Summary

A new chat in Gaia currently opens on a single fixed line, "What can I help with?". This change
replaces it with a line drawn from a pool of 66. Some lines use your name, and some only
appear at certain times of day.

- **A fixed pool in code**, in three kinds (§6): 28 general lines, 14 that use your name, and
  24 time-of-day lines. The time-of-day lines are 6 per window (morning, afternoon, evening,
  late night), 3 plain and 3 that use your name.
- **Your name is a Gaia setting.** You set "Your name" in the Gaia Settings tab, and it syncs
  to all your devices. While it's empty, the lines that use it are never drawn (§3).
- **A shuffle bag per kind, picked by weight** (§4): general 55%, your name 30%, the current
  time window 15%. Each bag shows every one of its lines before any of them repeats.
- **Each chat keeps its line.** A chat's line is drawn once. If you leave the chat and come
  back, the same line is still there (§5).
- **The agents are not told your name.** Your name is used only for the greeting. GAIA.md is
  still the place to tell the agents about yourself.

## 2. Where it shows

Only in `_EmptyChat` (`lib/features/gaia/companion/gaia_app.dart:3105`). That's the line
shown over a chat with no messages, when the window is at least 200 px tall. The hint row
under it (`/` commands, `Ctrl+V` paste an image, the send key) stays as it is. The in-app
Gaia page has no empty-chat line, so it doesn't change.

`_EmptyChat` takes the line it should show as a `String`. It doesn't pick one itself: it's
rebuilt on every keystroke and resize, so picking there would make the line change while
you look at it.

## 3. Your name

**Model.** Add a `userName` field to `GaiaSettings`, a `String` that defaults to `''`. It
follows the same path `splitGaiaRight` took:

| Where | Change |
|---|---|
| `lib/domain/models/gaia_models.dart` | the field, `copyWith`, and `'userName'` in the map sent to the companion |
| `lib/data/database/app_database.dart` | a `userName` text column (default `''`) on `gaia_settings_table`; schema 197 → 198 with `_addColumnIfNotExists` |
| `lib/data/repositories/drift_repositories.dart` | write and read the column |
| `lib/core/sync/firestore_document_mapper.dart` | `'userName'` to and from Firestore, falling back to the local value |
| `lib/features/gaia/companion/gaia_controller.dart` | `_applySettings` reads `settings['userName']`, trimmed |

**Settings UI.** A "Your name" section goes at the top of the Settings tab
(`gaia_page.dart:2153`), above GAIA.md. It has a single-line `VoyagerTextField` with a
24-character limit, and a Save button that works like GAIA.md's: it's enabled only while
the field differs from what's saved. Pressing Enter also saves. The helper text reads:
*"Gaia uses it to greet you in a new chat. Synced to all your devices."*

A name that's empty or only spaces counts as no name.

## 4. Choosing a line

A new file, `lib/features/gaia/companion/gaia_greetings.dart`, holds the pool and the bags.

### 4.1 The bags

There are six bags: one for general lines, one for name lines, and one for each time window.

| Bag | Lines | Weight |
|---|---|---|
| General | 28 | whatever's left: 55% with a name set, 85% without |
| Your name | 14 | 30%, only while a name is set |
| Morning, 5:00–11:59 | 6 (3 named) | 15% during its window |
| Afternoon, 12:00–16:59 | 6 (3 named) | 15% during its window |
| Evening, 17:00–21:59 | 6 (3 named) | 15% during its window |
| Late night, 22:00–4:59 | 6 (3 named) | 15% during its window |

Hours use the device's local clock. Exactly one time window holds at any hour, so a draw
chooses among at most three bags: general, your name, and the current window.

### 4.2 A draw

1. **Pick a bag by weight.** The current window gets 15%. The name bag gets 30% if a name is
   set. General gets the rest.
2. **Draw from that bag.** Each bag holds its lines' indices in shuffled order. Take the
   first line in the bag that can be shown and remove it. In a window bag, a named line
   can't be shown while no name is set, so it's skipped and keeps its place.
3. **Refill when needed.** If nothing left in the bag can be shown, put all its lines back,
   reshuffle and draw again. Without a name, a window bag cycles through its 3 plain lines.
   The line the bag showed last is kept out of the first 3 draws after a refill (the first
   2 when only 3 lines can be shown), so a refill doesn't repeat it straight away.

Each bag refills on its own, so a bag never repeats a line until it has shown every line it
can show. The bags live only in the companion's memory, so restarting Gaia starts every
shuffle fresh.

```dart
enum GaiaGreetingKind { general, named, morning, afternoon, evening, lateNight }

class GaiaGreeting {
  const GaiaGreeting(this.kind, this.text);
  final GaiaGreetingKind kind;
  final String text; // may contain {name}
  bool get named => text.contains('{name}');
}
```

### 4.3 What that works out to

With a name set, about 37% of new chats use your name: 30% from the name bag, plus half of
the 15% that come from the time bag. Lines repeat at roughly these gaps:

| Bag | Repeat gap |
|---|---|
| General | about every 50 new chats |
| Your name | about every 45 new chats |
| A time window | about every 40 new chats opened in that window (20 without a name) |

## 5. Each chat keeps its line

`GaiaController` keeps a map from chat key to the line drawn for it. The key is
`_keyOf(currentChatId)`, which is `GaiaDraft.newChatId` (`'new'`) for the unsaved new chat.

- **Asking for a chat's line** (`greetingFor(key)`): return the chat's held line, or draw one
  and hold it. It returns the line with `{name}` replaced by your current name.
- **Leaving and coming back:** the held line is still there. Pressing New chat while you're
  already on an empty new chat keeps it too, because it's the same chat.
- **Sending the first message:** the `'new'` entry is dropped, so the next new chat draws a
  fresh line. Once a chat has messages it never shows a line again.
- **Your name is cleared while a named line is held:** that line can no longer be shown, so
  a new one is drawn for that chat. If your name changes instead, the held line stays and
  shows the new name.
- **The hour changes while a line is held:** the line stays. A "Good morning" left open past
  noon still says good morning. Swapping it out would break the "keeps its line" rule, and
  this is rare enough not to matter.

The held lines live in memory only, so restarting Gaia draws new ones. A chat that already
existed but has no messages (rare: for example, a fork with nothing copied into it) gets a
line held under its own id in the same way.

## 6. The pool (draft)

`{name}` is replaced by your name. Every line is at most 40 characters with a 12-character
name, so lines stay on one or two lines in a narrow companion window.

### General (28)

1. What can I help with?
2. What are we working on?
3. What's on your mind?
4. Ready when you are.
5. Where should we start?
6. What's next?
7. Let's make something.
8. Ask me anything.
9. What are we building today?
10. Got a question? I've got time.
11. Point me at a problem.
12. What needs doing?
13. Fresh page. What goes on it?
14. Let's figure it out together.
15. What's the plan?
16. I'm all ears.
17. Throw me something tricky.
18. What can I take off your plate?
19. Start anywhere. I'll keep up.
20. What are you curious about?
21. One thing at a time. What's first?
22. Say the word.
23. Let's get into it.
24. What's bugging you?
25. Big idea or small fix?
26. Tell me what you're after.
27. Something to untangle?
28. Let's think this through.

### With your name (14)

1. Hi, {name}. What's up?
2. What are we working on, {name}?
3. Good to see you, {name}.
4. Welcome back, {name}.
5. Ready when you are, {name}.
6. What's on your mind, {name}?
7. Where to, {name}?
8. Hey {name}, what's next?
9. At your service, {name}.
10. Let's get to it, {name}.
11. {name}, what can I help with?
12. Missed me, {name}?
13. Your move, {name}.
14. What's the plan, {name}?

### Morning, 5:00–11:59 (6)

| Plain | With your name |
|---|---|
| Good morning. What's first? | Morning, {name}. Coffee first? |
| Morning. Where do we start? | Good morning, {name}. |
| Early start? Let's go. | Rise and shine, {name}. |

### Afternoon, 12:00–16:59 (6)

| Plain | With your name |
|---|---|
| Good afternoon. What's next? | Afternoon, {name}. How's it going? |
| Afternoon. What's on the list? | Good afternoon, {name}. |
| Halfway through the day. What's up? | Back at it, {name}? |

### Evening, 17:00–21:59 (6)

| Plain | With your name |
|---|---|
| Good evening. What's left to do? | Evening, {name}. Winding down? |
| Evening. Anything to wrap up? | Good evening, {name}. |
| One more thing before tonight? | Long day, {name}? |

### Late night, 22:00–4:59 (6)

| Plain | With your name |
|---|---|
| Up late? Let's make it count. | Still up, {name}? I'm here. |
| Burning the midnight oil? | Night owl mode, {name}? |
| Late one tonight. What's up? | Can't sleep, {name}? |

## 7. Out of scope

- Telling the agents your name, for example in their system prompt.
- Editing the pool or the weights from Settings.
- A greeting on the in-app Gaia page or on the phone.
- Keeping held lines or the bags across restarts.

## 8. How it's checked

**Unit tests** (`test/gaia_greetings_test.dart`), with a seeded `Random` and a given hour:
- Every line, filled in with a 12-character name, is at most 40 characters.
- With no name set, no `{name}` line is ever drawn. Draw 1,000 times to check.
- Only the current window's time lines are drawn, including the late-night window that wraps
  past midnight (test at 23:00 and 3:00).
- Each bag: drawing as many times as the bag has showable lines never repeats a line.
- Bag weights over 10,000 draws land within 2 points of the target: 55 / 30 / 15 with a name
  set, 85 / 15 without.

**Controller tests:**
- `greetingFor('new')` returns the same line across repeated calls and after switching to
  another chat and back.
- After the first message is sent, the next new chat gets a different line.
- Clearing your name re-draws a held named line. Renaming keeps the line and shows the new
  name.

**Widget test:** pump the companion on an empty chat, type in the composer and resize the
window. The line doesn't change.

**Live, in `gaiadev` (dummy mode):**
- Set a name in Settings, open several new chats and see general, named and time lines.
- Clear the name and see that named lines stop appearing.
- Launch with `TZ` shifted to get the morning and late-night lines.
- Check that a long name wraps cleanly at the narrowest companion width.
