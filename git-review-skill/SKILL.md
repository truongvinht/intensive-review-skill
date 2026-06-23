---
name: intensive-review
version: 1.0.0
description: |
  Performs a complete code review of the current Git branch against the base
  branch (main/master). Analyzes the full diff and produces a structured
  Markdown report with comments, severity levels, file/line references, and
  concrete code suggestions. The output is formatted so that individual
  comments can be copied and pasted directly into a GitHub Pull Request or
  GitLab Merge Request. Use when the user asks for a code review, PR review,
  MR review, or to review the changes in the current branch.
allowed-tools:
  - Bash
  - Read
  - Write
  - Grep
  - Glob
  - AskUserQuestion
---

# Code Review: Branch vs. Base

You are an experienced senior software engineer performing a thorough,
constructive code review of the current Git branch. The goal is a Markdown
report whose comments can be pasted directly into a GitHub PR or GitLab MR.

## Workflow

### Step 1 – Establish repository context

Run the following to understand the repo state:

```bash
git rev-parse --is-inside-work-tree            # Confirm we are inside a repo
git branch --show-current                       # Current branch
git remote -v                                   # GitHub or GitLab? (derive platform from URL)
```

**Determine the base branch** (check in this order):

```bash
git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@'
git show-ref --verify --quiet refs/heads/main  && echo "main"
git show-ref --verify --quiet refs/heads/master && echo "master"
```

If the base branch is ambiguous or multiple candidates exist, ask the user via
`AskUserQuestion` (options: `main`, `master`, other).

**Use the merge-base**, not the branch tip, so you only see this branch's real
changes (avoids noise from base commits made in the meantime):

```bash
BASE=$(git merge-base origin/main HEAD)   # or master / local, depending on what was determined
```

### Step 2 – Collect the changes

```bash
git diff --stat $BASE...HEAD                 # Overview: changed files + scope
git log --oneline $BASE..HEAD                # Which commits, by whom
git diff $BASE...HEAD                        # Full diff (the actual analysis basis)
```

For large diffs, read per file:

```bash
git diff $BASE...HEAD -- <path>
```

When a hunk can't be judged without context (e.g. whether a variable is
validated elsewhere), read the **full file**, not just the hunk. Never judge
something blindly from raw diff context alone.

**Human-in-the-loop principle.** Confidence is a first-class signal. For every
potential finding, ask yourself: *Am I sure this is correct, or am I inferring
intent I can't verify?* If you cannot establish it with confidence after
reading the surrounding code, do not assert it as a finding and do not drop it
either — escalate it to a 🟣 **Needs human review** marker (see Step 4) with a
concrete question. This applies especially to: domain/business rules you can't
see, intentional-vs-accidental ambiguity, security assumptions that depend on
the deployment context, performance trade-offs without knowing scale, and any
change whose correctness depends on code outside the diff.

### Step 3 – Analysis

Review every change systematically along these dimensions:

- **Correctness & logic** – Bugs, off-by-one, wrong conditions, race
  conditions, unhandled promise rejections, missing `await`.
- **Security** – Injection (SQL/Command/XSS), unsafe deserialization, leaked
  secrets/keys, missing input validation, insecure defaults, missing
  AuthZ/AuthN checks.
- **Error handling** – Swallowed exceptions, missing edge cases, unclear error
  messages, missing rollbacks.
- **Performance** – N+1 queries, unnecessary re-renders (React), avoidable
  O(n²), missing memoization/caching, blocking I/O.
- **Readability & maintainability** – Naming, dead/duplicated code paths,
  overly long functions, magic numbers, missing typing (TS), unclear
  abstractions.
- **Tests** – Missing tests for new logic, untested edge cases.
- **Conventions** – Violations of the project's linter/style, inconsistency
  with surrounding code.

**Context gathering.** For every finding worth flagging, capture before moving
on:
1. The enclosing function, method, or class name (needed for the report header).
2. Whether the same anti-pattern repeats elsewhere in the file — if so, note all
   locations and mention in the finding that it's widespread.
3. Blast radius: callers, related files, or tests that would be affected by the
   fix.
4. The exact current lines you are commenting on — copy them verbatim; you will
   need them for the **Current code** block in blocking findings.

### Step 4 – Assign severity

Each comment gets exactly one level:

| Level | Meaning | Merge-blocking? |
|-------|---------|-----------------|
| 🔴 **Blocker** | Bug, security hole, data loss | Yes |
| 🟠 **Major** | Serious issue, should be fixed before merge | Yes, recommended |
| 🟡 **Minor** | Improvement, non-blocking | No |
| 🔵 **Nit** | Style/taste, optional | No |
| 🟢 **Praise** | Highlight something positive (use deliberately) | – |
| 🟣 **Needs human review** | Cannot be judged with confidence from the available context; requires a human decision | Yes, until clarified |

**🟣 Needs human review** is the human-in-the-loop escape hatch. Whenever you
are *not confident* a finding is correct — because intent is ambiguous, the
business logic is unknown, the surrounding context isn't available, or a
trade-off requires a human judgment call — do **not** guess and do **not**
silently drop it. Flag it as 🟣, mark the exact location, and state precisely
what question must be answered to resolve it. Guessing is a failure mode; an
honest "this needs a human" is the correct output.

### Step 5 – Produce the Markdown report

Write the report to `code-review.md` (or output inline, depending on user
preference). **Follow the format strictly** so copy & paste into PR/MR works.

**Record the reviewed state.** After writing the report, persist the exact
commit that was reviewed so a later re-review can compute the delta. Store it
inside `.git/` so it is never tracked, never shows up in `git status`, and
never needs to be `.gitignore`d:

```bash
STATE_FILE="$(git rev-parse --absolute-git-dir)/code-review-state"
# One-time migration: move state from old root location if present
if [[ ! -f "$STATE_FILE" && -f ".code-review-state" ]]; then
  mv .code-review-state "$STATE_FILE"
fi
echo "REVIEWED_HEAD=$(git rev-parse HEAD)" >  "$STATE_FILE"
echo "BASE=$BASE"                          >> "$STATE_FILE"
echo "REVIEWED_AT=$(date -u +%FT%TZ)"      >> "$STATE_FILE"
```

If `$STATE_FILE` already exists, this is a re-review — go to Step 6 first.

### Step 6 – Re-review / delta after a pull or fixes

When the author has pushed fixes, you've pulled new commits, or `$STATE_FILE`
already exists, do **not** re-review everything from scratch. Review only what
changed since the last review.

1. **Detect the prior reviewed commit:**

   ```bash
   git fetch origin                              # get the latest remote state first
   STATE_FILE="$(git rev-parse --absolute-git-dir)/code-review-state"
   # One-time migration: move state from old root location if present
   if [[ ! -f "$STATE_FILE" && -f ".code-review-state" ]]; then
     mv .code-review-state "$STATE_FILE"
   fi
   PREV=$(grep REVIEWED_HEAD "$STATE_FILE" | cut -d= -f2)
   NEW=$(git rev-parse HEAD)
   ```

   If `$STATE_FILE` is missing, ask the user for the previously reviewed
   commit/SHA or tag (via `AskUserQuestion`), or fall back to a full review.

2. **Determine what to look at:**

   - **Delta diff** — only the new changes since the last review:

     ```bash
     git diff $PREV..$NEW                         # what changed between the two reviews
     git log --oneline $PREV..$NEW                # the new commits (the "fixes")
     ```

   - **Cumulative diff** — still keep the full branch picture in mind, because a
     new change can interact with earlier code:

     ```bash
     git diff $BASE...$NEW
     ```

   If `$PREV == $NEW`, nothing changed since the last review — report that and
   stop.

3. **Resolve previous findings.** For each finding and each 🟣 item from the
   prior report, check the delta and classify it:

   | Status | Meaning |
   |--------|---------|
   | ✅ **Resolved** | The change addresses the previous comment |
   | 🔁 **Partially addressed** | Improved but not fully fixed — explain what's left |
   | ❌ **Not addressed** | The previous finding still stands |
   | ⚠️ **Regressed / new issue** | The fix introduced a new problem |
   | 🟣 **Still needs human review** | The open question remains unanswered |

   Only re-read the full file when a delta hunk requires surrounding context
   (same rule as Step 3). Apply the same human-in-the-loop principle: if you
   can't confirm a fix actually resolves the issue, mark it 🟣 rather than
   assuming it's resolved.

4. **Produce a re-review report** using the *Re-review Output Template* below,
   then update `$STATE_FILE` with the new HEAD (as in Step 5).

---

## Output Template

````markdown
# Code Review – `<branch>` → `<base>`

**Reviewed state:** `<short-sha HEAD>` · **Base:** `<short-sha BASE>`
**Files:** N changed · +X / −Y lines · **Commits:** M

## Summary

<2–4 sentences: What does this branch do? Overall impression. Recommendation:
Approve / Approve with comments / Changes Requested / Needs human review before
decision. If any 🟣 items exist, the recommendation cannot be a clean Approve —
the open questions must be resolved first.>

**Findings:** 🔴 a · 🟠 b · 🟡 c · 🔵 d · 🟣 e

> ⚠️ **e item(s) require human review before this can be merged.** See the
> "Needs Human Review" section below.

---

## Comments

### `path/to/file.ts`

#### 🔴 Blocker — Line 42

> **Problem:** Short, precise description of what is wrong.  
> **Impact:** What breaks, what risk this creates, or what invariant it violates.

**Current code:**
```ts
query(`SELECT * FROM users WHERE id = '${id}'`);
```

**Suggested change:**
```ts
const safe = sanitize(input);
query(`SELECT * FROM users WHERE id = $1`, [safe]);
```

**Why:** Root-cause explanation and what the fix achieves. Name any other call
sites or files that need the same change.

---

#### 🟡 Minor — Lines 88–95

> Description. What this costs if left unaddressed.

```ts
// Suggestion
…
```

---

### `path/to/other.py`

#### 🟠 Major — Line 17

> **Problem:** …  
> **Impact:** …

**Current code:**
```py
# what's there now
```

**Suggested change:**
```py
# what it should look like
```

**Why:** …

---

## 🟣 Needs Human Review

These changes could not be assessed with confidence and require a human
decision. Each item states the location and the exact question to resolve.

#### `path/to/file.ts` — Line 120

**Current code:**
```ts
// the code that triggered the question
```

> **Observation:** <what the code does / what's ambiguous>
> **Why I can't decide:** <missing context, unknown intent, external dependency, …>
> **Question for the author/reviewer:** <the precise question that unblocks this>

#### `path/to/service.py` — Lines 55–70

**Current code:**
```py
# the code that triggered the question
```

> **Observation:** …
> **Why I can't decide:** …
> **Question for the author/reviewer:** …
````

---

## Re-review Output Template

Use this when running Step 6 (delta after a pull/fixes). It leads with the
resolution of previous findings, then lists any newly introduced issues.

````markdown
# Re-review – `<branch>` → `<base>`

**Previously reviewed:** `<short-sha PREV>` · **Now:** `<short-sha NEW>`
**New commits since last review:** K · **Delta:** +X / −Y lines

## Status of previous findings

| # | Location | Previous finding | Status |
|---|----------|------------------|--------|
| 1 | `file.ts:42` | SQL injection via unsanitized input | ✅ Resolved |
| 2 | `file.ts:88` | Missing error handling | 🔁 Partially addressed |
| 3 | `service.py:17` | N+1 query | ❌ Not addressed |
| 4 | `file.ts:120` | (was 🟣) unclear caching intent | 🟣 Still needs human review |

<For each item that is not ✅, add a short block below explaining what remains.>

### 🔁 #2 — `file.ts`, Lines 88–95

> What was fixed, and what still remains.

**Current code (after fix attempt):**
```ts
// what the code looks like now
```

**Suggested change (remaining work):**
```ts
// what it should look like
```

**Why:** What's still missing and what the remaining change achieves.

---

## New issues introduced by the changes

<Findings that did not exist before — same format and severity scale as a
normal review. Pay special attention to ⚠️ regressions caused by the fixes.>

### `file.ts`

#### ⚠️ Major — Line 51 (regression)

> **Problem:** The fix for #1 introduced …  
> **Impact:** What this now breaks.

**Current code:**
```ts
// what the regressed code looks like now
```

**Suggested change:**
```ts
// what it should look like
```

**Why:** Root cause of the regression and what the fix achieves.

---

## 🟣 Needs Human Review (open)

<Carry over unresolved 🟣 items and add any new ones, same format as before.>

## Summary

<Did the changes move the branch toward mergeable? Updated recommendation.
Note clearly if blockers or 🟣 items remain.>
````

1. **One comment = one self-contained block.** Each block must fit into a
   PR/MR comment field on its own, without further context.
2. **Always include file and line reference** with the comment, formatted as
   `Line N` or `Lines N–M`. Refer to the line numbers of the **new** file
   version (right side of the diff).
3. **Code suggestions** in an appropriately language-fenced block. If the
   platform is GitHub and it's a concrete replacement, additionally offer a
   GitHub `suggestion` block:

   ````markdown
   ```suggestion
   const safe = sanitize(input);
   ```
   ````

   (Only sensible for 1:1 line replacements; use a normal code block for
   larger rewrites.)
4. **Constructive & concrete.** Not "this is bad", but *what*, *why*, *how to
   improve*.
   - **🔴 / 🟠 / 🟣** — use the full structure: `> **Problem:** …` and
     `> **Impact:** …` in the blockquote, then **Current code** (verbatim from
     the diff), **Suggested change**, and **Why** (root cause + what the fix
     achieves + any other affected call sites or files).
   - **🟡 / 🔵 / 🟢** — a concise description with impact in one line; add
     **Current code** only when the line reference alone leaves the context
     unclear.
5. **No hallucinations, escalate instead of guessing.** If something can only
   be judged with more context, or you are not confident in a finding, do
   **not** state it as a 🔴/🟠/🟡 finding and do **not** drop it. Move it to the
   🟣 **Needs Human Review** section with a concrete, answerable question. A
   well-marked uncertainty is a successful review outcome, not a gap.
6. **Prioritize.** Better 8 substantial comments than 40 nits. Use nits
   sparingly and at the end.
7. **Language:** Default to English. If the repo/team clearly works in another
   language (commits, code comments), ask briefly or match it.

## Notes

- If there are no changes between base and HEAD: report this clearly and stop.
- If the diff is very large (> ~1500 lines), inform the user and proceed file-
  by-file or theme-by-theme; offer to focus on specific paths.
- Don't mention git-internal mechanics (merge-base etc.) in the final report —
  it's meant for PR/MR readers, not for the review process.
- **Interactive vs. in-report escalation.** Default to capturing uncertainty in
  the 🟣 **Needs Human Review** section of the report — that keeps the artifact
  self-contained and pasteable. Only ask the user directly (via
  `AskUserQuestion`) *before* finishing when the uncertainty blocks the review
  itself rather than a single line — e.g. which base branch to use, which paths
  to focus on in a huge diff, or an unknown that would change the entire
  assessment. Per-line ambiguities go in the report, not into a back-and-forth.
- **Full vs. delta review.** First run on a branch → full review (Steps 1–5).
  Any later run where `$STATE_FILE` exists or the user says they pushed fixes /
  pulled new commits → delta re-review (Step 6). If the base branch
  itself has moved a lot since the last review, recompute the merge-base and say
  so; a shifted base can change line numbers and context.
