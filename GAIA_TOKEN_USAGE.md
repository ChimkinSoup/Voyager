# Gaia — Lifetime Token Usage

Status: **Built (2026-11-22). Unit and widget tests pass. Not yet checked in the running
app or against real Firestore.**

## 1. Summary

Gaia keeps a lifetime count of the tokens it uses, across every desktop. The count is
stored in Firestore and shown in `/usage` under **Lifetime tokens**.

- **Every kind of token is counted:** input, output, cache read and cache write.
- **It's split by account, then by where the tokens went** (a tier, a background utility
  job, or "Other"), **then by model.**
- **There's one overall total for everything.** Each tier and the Utility group also
  have totals of their own.
- **It's a global counter.** Every desktop adds to the same Firestore documents with
  increments, so desktops never overwrite each other's counts.

## 2. What's tracked

### 2.1 Token kinds

| Field | Meaning |
|---|---|
| `input` | Uncached input tokens |
| `output` | Output tokens |
| `cacheRead` | Input read from the prompt cache |
| `cacheWrite` | Input written to the prompt cache |

The total is the sum of all four. For Codex, `inputTokens` includes cached input, so
Gaia subtracts `cachedInputTokens` from it to get `input` and counts the cached part as
`cacheRead`.

### 2.2 Sources: where the tokens went

| Source | What it covers |
|---|---|
| `quick` / `standard` / `deep` | Chat turns on that tier, including `/btw` side questions and forks |
| `utility:<job>` | The utility model's background work, one source per job (§2.3) |
| `other` | Anything sent without a tier, such as raw sends |

### 2.3 Utility jobs

Each background job counts under its own name:

- `routing`
- `memory recall`
- `chat title`
- `chapter title`
- `handoff summary`
- `chat summary`
- `image caption`
- `memory filing`
- `memory curation`

### 2.4 Accounts

Counts go under each account's existing `GaiaAccount.key`:

- `claude_code` for the default Claude account, `claude_code/<id>` for any other.
- `codex` for the default Codex account, `codex/<id>` for any other.

Utility jobs count under the account the utility model is running on.

## 3. Where the numbers come from

### 3.1 Claude Code

Every stream-json `result` line carries `model_usage_since_last_result`: the tokens used,
per model, since that process's previous result. Gaia counts that field
(`ClaudeResult.tokens`, parsed in `claude_code_events.dart`).

`modelUsage` isn't used for counting because it's the process's running total. Adding
it up on every result would count the same tokens more than once.

The process remembers the account and tier of the turn it's running
(`_ClaudeProcess.tokensFor`). So a result that arrives between turns, and the process
that checks a rewind, still count under the right label.

### 3.2 Codex (app server)

`thread/tokenUsage/updated` gives `last`, the tokens of a single model call. Gaia counts
`last` under the account, tier and model recorded when the turn started. Added up, the
`last` values match the thread's own `total`, and the tests check this.

### 3.3 Utility model

`ClaudeUtilityRunner.generate` takes a `source` (the job's name) and counts its result
under `utility:<source>`, against the account set in `configure`.

## 4. How a count reaches Firestore

The companion process never talks to Firebase. A count goes like this:

1. A runner sees tokens and calls the global sink `gaiaTokensUsed(tokensFor, byModel)`.
2. The companion (`gaia_companion_main.dart`) sends them to the main app over GaiaPipe as
   a `tokensUsed` event.
3. `GaiaHost` passes them to `GaiaTokenCounter.add`.
4. The counter writes them with `FieldValue.increment` and a merged `set`.
5. The counter watches the collection. `GaiaHost` sends every change back to the
   companion as a `tokens` event, and the hello reply carries the current totals.
   `GaiaController.tokens` holds them for `/usage`.

### 4.1 Firestore layout

`users/{uid}/gaia_tokens/{account|source|model}` holds one document per account, source
and model. Slashes in the id become `_`, because a document id can't contain `/`.

```json
{
  "account": "claude_code/work",
  "source": "utility:chat title",
  "model": "claude-haiku-5-5",
  "input": 1234,
  "output": 56,
  "cacheRead": 7890,
  "cacheWrite": 120
}
```

- The existing Firestore rules already allow `users/{uid}/{collection}/{doc}`.
- The collection isn't part of backups. It isn't listed in `FirestoreCollections.records`.

### 4.2 Clearing the first version's counts

The first version counted by model alone, with no `source` field. When the counter reads
the collection, it deletes any document without a `source`, because there's no way to
tell which account or tier those tokens belonged to. This cleanup can be removed once
every desktop has run this version.

## 5. What `/usage` shows

```
Lifetime tokens
All                         4.07K   ← bold, with in / out / cache read / cache write under it
Claude · Default            3.17K   ← account headings appear only when 2+ accounts have usage
  Quick                       100
    claude-haiku-5-5          100
  Deep                         3K
    claude-opus-5-5            3K
  Utility                      70   ← total for all background jobs
    Image caption              50
    Chat title                 20
Codex · Work                  900
  Standard                    900
    gpt-6.1-sol               900
```

- Groups and rows are sorted biggest first.
- Numbers use `NumberFormat.compact`.
- Tier and Utility headings show the in / out / cache split under them. Model and job
  rows show it when you hover.
- Before the first read, the section shows "Not read yet".

## 6. Files

| File | Role |
|---|---|
| `lib/features/gaia/usage/gaia_tokens.dart` | `GaiaTokenCount`, `GaiaTokenRow`, `GaiaTokensFor`, the `gaiaTokensUsed` sink |
| `lib/features/gaia/remote/gaia_token_counter.dart` | Firestore reads and writes, plus clearing old documents |
| `lib/features/gaia/adapters/claude_code/claude_code_events.dart` | Parses `model_usage_since_last_result` |
| `lib/features/gaia/adapters/claude_code/claude_code_runner.dart` | Reports each Claude result's tokens |
| `lib/features/gaia/adapters/codex/codex_app_server.dart` | Reports each Codex model call's tokens |
| `lib/features/gaia/adapters/gaia_agent_runner.dart` | `send` takes the turn's `tier` |
| `lib/features/gaia/utility/claude_utility_runner.dart`, `gaia_utility.dart` | Labels each utility job |
| `lib/features/gaia/host/gaia_host.dart` | `tokensUsed` in, `tokens` out |
| `lib/features/gaia/companion/gaia_controller.dart` | Holds the totals, passes the tier to sends |
| `lib/features/gaia/companion/gaia_app.dart` | The `/usage` section (`gaiaTokenLines`) |
| `lib/app/voyager_app.dart` | Creates the counter and follows sign-in |
| `test/gaia_tokens_test.dart` | Parsing, Codex totals, the counter, and the display |

## 7. Limits

- **Codex's exec fallback isn't counted.** Only the app server reports tokens.
- **A force-killed Claude process loses its last stretch.** Tokens used after its last
  `result` are never reported.
- **Tokens used while signed out are dropped.** There's no Voyager account to count them
  under.
- **Nothing from before this feature is counted.**
