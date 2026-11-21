# Gaia tool calls: suggested fixes

Reviewed 2026-11-20. Two ideas were proposed:
1. Bigger tools for common chains, such as "focus and read" or a wait with a timeout, so the model makes one call instead of three.
2. Filter or query arguments on the read tools, so the tool cuts the output down before the model sees it.

**Short answer:** idea 2 helps, but only for `os_read_screen`. Idea 1 is mostly built already: `os_steps`, `read_after`, and `os_open`/`os_focus` making their window the target. The combined tool that's actually missing is a **wait**.

## Evidence

The figures come from 349 Claude Code sessions in the Gaia workspaces (`~/.claude-2/projects/*-gaia-ws`): the main profile plus the QA profiles (`gaiaqa`, `qa`, `p7a`, …). Together they hold 1,340 tool calls, 507 of them Gaia tools. QA runs make up a good share, so the counts lean toward the `os_*` tools.

Result sizes, in characters of the tool result:

| Tool | Median | p90 | Max |
|---|---|---|---|
| `os_read_screen` | 2.3k | **25k** | **33.5k** |
| action + `read_after` (`os_type`, `os_click`, `os_open`) | ~0.1–0.9k | 3–6k | **~19k** |
| `os_screenshot` (base64 image) | 226k | 381k | 561k |
| `os_windows` | 1.1k | 1.3k | 1.5k |
| `memory_search` | 0.8k | 1.8k | 1.8k |
| `voyager_*`, `project_*` | under 1.2k | | |

The most common back-to-back pairs of Gaia tools:

| Chain | Count |
|---|---|
| `os_read_screen → os_click` / `os_click → os_read_screen` | 23 / 23 |
| `os_open → os_windows` | 22 |
| `os_scroll → os_screenshot` / `os_screenshot → os_scroll` | 16 / 15 |
| `os_read_screen → os_read_screen` (mostly the same `{}` arguments) | 14 |

## 1. Bigger tools for common chains

### Don't add "focus and read"
`os_focus {read_after: true}` already does it. The problem is that `read_after` goes unused: only 94 of 279 action calls set it, and the model reads the screen in a separate call afterwards anyway (`os_click → os_read_screen` 23 times, `os_open → os_windows` 22 times).

**Change:** make `read_after` default to true on `os_click`, `os_type`, `os_key` and `os_steps`. Every one of them already tells the model to "read the screen again". The cost is a screen read added to each result, so do this after the filter in §2.

### Do add a wait
- In the main profile, Gaia skipped `os_open` and ran `Start-Process chrome "https://mail.google.com/..." ; Start-Sleep -Seconds 6` in PowerShell, because nothing in Gaia can wait for a page to load.
- In QA sessions it ran `sleep 6`, `sleep 12` or `sleep 20` and then read the screen again.
- `os_read_screen → os_read_screen` with the same `{}` arguments came up 14 times, which is polling by hand.
- `read_after` waits a fixed 300 ms (`_readSettle`, `lib/features/gaia/companion/gaia_chat_tools.dart:251`). That's fine after a click but far too short for a page load.

**Change (arguments rather than a new tool):**
- On `os_read_screen`: add `until` (text that must appear in a control's name or value), `gone` (wait for it to disappear instead) and `timeout` in seconds (capped at around 30). It polls, then returns the read, or says it ran out of time and returns the last read.
- On `read_after`: accept the same `until`, so `os_open {target, read_after: {until: "Inbox"}}` is one call instead of open, sleep, read.

## 2. Filter/query arguments on read tools

### Only `os_read_screen` needs this
The `voyager_*`, `memory_*`, `project_*` and `os_windows` results are already small (see the table), and most already have filters (`list`, `tracker`, `topic`, `limit`). Leave them as they are.

### New arguments on `os_read_screen`
- **`find`** (text): return only controls whose name or value contains it, each with its chain of parent controls so the result still says where it is. Today the only filter is `region`, which needs pixel coordinates from a previous full read.
- **`types`** (for example `["Button","Edit","Link"]`): return only controls the model can act on.

### `read_after` ignores filters
It always reads the whole window with no arguments, `screen('os_read_screen', const {})` (`gaia_chat_tools.dart:626`), and doesn't even pass `region`. Let it take the same `find`/`types`/`region`, or a default `read_after` will bring 19k-character results.

### Fix the output itself (no new argument)
In `_readScreen` (`lib/features/gaia/host/gaia_os_reads.dart:197`), the largest read (Gmail inbox, 33.5k characters) is mostly repetition:
- Each email row repeats the same ~200-character text four times: on the `DataItem`, a child `DataItem`, the `CheckBox` and the `Link`.
- There are nameless controls with no size: `DataItem [0,0 0x0]`.

Leaving out a name that's the same as its parent's, and dropping nameless controls with no size, would shrink every large read without the model asking. Not measured yet: check it against a saved Gmail read.

### Smaller item: `os_screenshot` region
Screenshots have a median of about 226k characters of base64, and `os_scroll ↔ os_screenshot` loops happened 16 times. Image tokens grow with pixel area, so a `region` argument like `os_read_screen`'s would let the model capture only the part it needs.

## Outside both ideas: ToolSearch round-trips

There were **148 ToolSearch calls against 507 Gaia tool calls**. Claude Code defers MCP tools, so nearly every session spends a round-trip loading Gaia's schemas before its first `os_*` or `memory_*` call. That's more wasted round-trips than any of the chains above. Nothing in `lib/` changes this.

**To try:** launch the CLI with `ENABLE_TOOL_SEARCH=false` so the tools load upfront. This variable hasn't been checked against current Claude Code, so test it first. The cost is the token weight of all ~31 tool definitions (`kGaiaToolDefinitions`, `lib/features/gaia/tools/gaia_mcp.dart`) in every turn.

## Suggested order
1. ~~Collapse repeated names and drop empty controls in the `os_read_screen` output.~~ Done 2026-11-20: Gmail reads of about 32k characters drop to about 19k.
2. ~~Add `find` and `types` to `os_read_screen`, and let `read_after` take them (and `region`) too.~~ Done 2026-11-20.
3. ~~Add `until` / `gone` / `timeout` to `os_read_screen` and `read_after`.~~ Done 2026-11-20; Abort or turning off "can see screen" stops a wait.
4. ~~Make `read_after` default to true on `os_click`, `os_type`, `os_key` and `os_steps`.~~ Done 2026-11-20; `read_after: false` turns it off.
5. ~~Try turning off tool deferral for Gaia.~~ Done 2026-11-20: `ENABLE_TOOL_SEARCH=false` on the CLI; checked on 2.1.330 with the contract check.
6. Optional: `region` on `os_screenshot`.
