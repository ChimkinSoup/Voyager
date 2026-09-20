# LeetCode Scratch Starter — Entry Methods vs Helpers

Filter the scratch-pad starter so it keeps the LeetCode **entry shape** and drops user-defined **helper methods**, without breaking design problems that expose several public API methods.

Status: **design** (not implemented). Companion to [LEETCODE_SCRATCH_PAD.md](LEETCODE_SCRATCH_PAD.md) § Starter template. Implementation lives in `lib/features/leetcode/leetcode_scratch_starter.dart`.

---

## Problem

`deriveLeetCodeStarterFromCode` already drops nested helper **types** (nested `class` / `struct`), but it keeps every callable on the outer class. A solution like:

```java
class Solution {
    private int helper(int n) { ... }

    public int[] twoSum(int[] nums, int target) { ... }
}
```

opens the pad with stubs for both `helper` and `twoSum`. The pad cannot tell a helper from the problem entry method by syntax alone today.

---

## Goal

- Starter shows only signatures the user is expected to implement for that problem.
- Bodies stay emptied (no answer leak) — unchanged.
- Nested helper types stay dropped — unchanged.
- Design problems (Min Stack, LRU Cache, …) still stub **all** public API methods.

## Non-goals

- Perfect AST parsing or compiling the stub.
- Dropping helpers that the user marked `public` on purpose (accepted limitation).
- Schema changes or a separately stored “entry method” field.
- Changing Go / Rust (they already take the language fallback).
- Rewriting scratch already stored for a session (`templateInitialized` / crash recovery).

---

## Locked decisions

| Topic | Decision |
| --- | --- |
| Primary visibility languages | **C++ / Java / C#** |
| Multiple public methods | **Keep all publics** — design questions need them; do not title-match to drop public helpers |
| Default access before first specifier | Follow language defaults: `class` → private, `struct` → public |
| Python dunders | Keep **only** `__init__` |
| Top-level Python `def`s (no class) | **Keep all**, same as today |
| Existing / recovered pads | Filter **only** when deriving a **new** starter |

---

## Rule

When a callable would otherwise be kept, apply a language-aware **entry-shaped?** filter.

### Java / C# / C++ (visibility)

| Keep | Drop |
| --- | --- |
| `public` methods | `private` / `protected` methods |
| Public constructors (or under `public:`) | Non-public constructors |

**C++ access sections:** track the current `public:` / `protected:` / `private:` specifier while walking the outer class. Methods inherit the active section.

**Default before any specifier:** `class` members are private until a section says otherwise; `struct` members are public. (LeetCode `class Solution` almost always opens with `public:`, so this rarely bites.)

Keep every public method — never reduce to a single signature. A `public` helper next to `twoSum` stays; that is an accepted edge case.

### Python

**Inside a class**

1. **Title / slug name match** — derive candidate names from `LeetCodeProblem.title` / `titleSlug` (e.g. `Two Sum` → `twoSum`, `two_sum`) and keep matching `def`s. Always keep `__init__` when present.
2. **Fallback when nothing matches** — keep non-underscore methods; drop `def _…`; among dunders keep **only** `__init__`.

Thread the problem (or a precomputed name set) into the derive path; today `deriveLeetCodeStarterFromCode` only sees raw code + language.

**Top-level `def`s** (no enclosing class): keep all, unchanged from today. Do not apply title-match or underscore filtering at module scope.

### JavaScript / TypeScript

Usually a single free function or one class method. Leave current behavior unless multi-method class stubs show up in practice.

### Go / Rust

Unchanged — still `null` → `leetCodeStarterFallback`.

---

## What not to do

- **Do not** keep only the first or last method. Helpers often appear above the entry method.
- **Do not** keep only a single method on brace languages. That breaks Min Stack–style APIs.
- **Do not** use title-match on Java / C# / C++ to drop public methods.
- **Do not** rewrite pads that already have `templateInitialized` (including crash-restored sessions).

---

## Examples

**Algorithm + private helper → helper dropped**

```java
// saved
class Solution {
    private int helper(int n) { return n * 2; }
    public int[] twoSum(int[] nums, int target) { return new int[0]; }
}

// starter
class Solution {
    public int[] twoSum(int[] nums, int target) {
    }
}
```

**Design problem → all public kept**

```java
// starter still includes push / pop / top / getMin (and public ctor)
class MinStack {
    public MinStack() {
    }
    public void push(int val) {
    }
    // ...
}
```

**Python title match (class methods)**

```python
# problem title "Two Sum"
class Solution:
    def helper(self, n): ...
    def twoSum(self, nums, target): ...

# starter
class Solution:
    def twoSum(self, nums, target):
        pass
```

**Top-level Python — unchanged**

```python
def helper(n):
    pass
def solve(n):
    pass
```

---

## Implementation sketch

1. Add an “entry-shaped?” predicate used when a callable is about to be emitted in `_derivePython` / `_deriveBraces`.
2. Pass `LeetCodeProblem` (or `{title, titleSlug}`) into `deriveLeetCodeStarter` → `deriveLeetCodeStarterFromCode` for Python name candidates.
3. Apply the filter only on the derive path used when creating a **new** scratch entry — session restore / `templateInitialized` already skips re-derive today; leave that alone.
4. Update tests in `test/leetcode_scratch_starter_test.dart`:
   - Flip “keeps every method” cases that expect private helpers.
   - Keep Min Stack / multi-public API coverage.
   - Add private-helper + public-entry cases for Java / C# / C++.
   - Python: title-match class methods; keep all top-level defs; only `__init__` among dunders.
5. Note the “public helper stays” limitation next to the existing imperfect-stub caveat.

No persistence / session / sync changes — starter derivation only.
