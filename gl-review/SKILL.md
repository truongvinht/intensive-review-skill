---
name: gl-review
version: 1.0.0
description: |
  Publishes an existing code-review report (produced by the intensive-review
  skill, `code-review.md`) directly to its GitLab Merge Request using the
  GitLab MCP server (@zereight/mcp-gitlab). Posts one inline diff comment per
  finding — including 🟣 Needs Human Review items — on the exact file/line it
  refers to, plus one top-level summary note with the overall recommendation
  and findings count. Use when the user asks to publish, post, or upload a
  code review to a GitLab Merge Request, or to "put the review comments on
  the MR".
allowed-tools:
  - Bash
  - Read
  - AskUserQuestion
  - mcp__gitlab__whoami
  - mcp__gitlab__get_project
  - mcp__gitlab__get_merge_request
  - mcp__gitlab__list_merge_requests
  - mcp__gitlab__get_merge_request_diffs
  - mcp__gitlab__create_merge_request_note
  - mcp__gitlab__create_merge_request_thread
---

# Publish Code Review to GitLab Merge Request

You take an already-generated review report (from the `intensive-review`
skill) and publish it to the matching GitLab Merge Request: one inline
diff comment per finding, on the exact line it refers to, plus one
top-level summary note. This skill does **not** re-analyze the diff — if no
report exists yet, tell the user to run `intensive-review` first (or offer
to run it for them).

## Workflow

### Step 1 – Locate the report

```bash
test -f code-review.md && echo "found"
```

If `code-review.md` does not exist, stop and tell the user. Ask via
`AskUserQuestion` whether you should run the `intensive-review` skill now
(options: "Run intensive-review now", "Abort"). Only continue past this step
once a report exists.

Read the full contents of `code-review.md`.

### Step 2 – Identify the report type and parse findings

The report is either the **initial-review template** (heading `# Code Review
– ...`) or the **re-review template** (heading `# Re-review – ...`). Extract
findings from whichever sections are present:

| Section | Heading pattern | File comes from | Line(s) come from |
|---|---|---|---|
| Comments | `## Comments`, then `### \`path\`` per file, then `#### <emoji> <Severity> — Line(s) N[–M]` per finding | the enclosing `### \`path\`` heading | the `#### ...` heading |
| New issues (re-review) | `## New issues introduced by the changes` | same structure as Comments | same structure as Comments |
| Needs Human Review | `## 🟣 Needs Human Review` (or `(open)` in re-reviews) | embedded directly in the heading: `` #### `path` — Line(s) N `` | same heading |
| Still-open previous findings | `## Status of previous findings` table rows marked ❌ or 🔁, each with a prose block `### <emoji> #<n> — \`path\`, Line(s) N[–M]` | embedded in the heading | same heading |

For every finding, capture:
- **file** — exact path as it appears in the heading (strip backticks)
- **line_start** — first line number in the range (use this as the inline
  anchor; if a range like "Lines 88–95" is given, mention the full range in
  the comment body but anchor the thread on line 88)
- **severity** — the emoji + label from the heading (🔴/🟠/🟡/🔵/🟢/🟣, or the
  status emoji for still-open items)
- **body** — the full Markdown content of the block (Problem/Impact/Current
  code/Suggested change/Why, or the shorter one-liner form), verbatim

Skip ✅ Resolved rows entirely — nothing to post for those.

Also capture the **top-level summary**: the `## Summary` paragraph, the
findings-count line, and the recommendation.

### Step 3 – Resolve the GitLab project and Merge Request

Call `mcp__gitlab__whoami` first. If it errors (missing/invalid token,
unreachable server), stop immediately with that error — fail fast before
parsing anything else or showing a preview built on a server you can't
actually publish to.

```bash
git remote get-url origin
git branch --show-current
```

Parse the remote URL into a `namespace/project` path (handles both
`git@gitlab.example.com:group/proj.git` and
`https://gitlab.example.com/group/proj.git` forms). If the remote clearly
points at a non-GitLab host (e.g. `github.com`), stop and tell the user this
skill is GitLab-only.

Call `mcp__gitlab__get_merge_request` with `project_id` and
`source_branch=<current branch>`.

- **Exactly one open MR found** → use it.
- **None found** → call `mcp__gitlab__list_merge_requests` with
  `project_id`, `source_branch`, `state: "opened"` as a fallback. If still
  none, ask the user via `AskUserQuestion` for the MR IID directly, or abort.
- **More than one found** → list them (IID + title) and ask the user via
  `AskUserQuestion` to pick one.

From the resolved MR, keep: `iid`, `web_url`, `title`, and `diff_refs`
(`base_sha`, `head_sha`, `start_sha`) — the latter is required for every
inline comment's `position`.

### Step 4 – Build a diff-position index (required before any inline comment)

GitLab's diff-note position API is stricter than "give it a line number":

| Line's role in the diff | `old_line` | `new_line` |
|---|---|---|
| Added (`+` in the diff) | omit / `null` | the line number |
| Deleted (`-` in the diff) | the line number | omit / `null` |
| Unchanged context line shown in a hunk | the old-side line number | the new-side line number |
| Not part of any hunk at all | — cannot be positioned inline — | — |

`intensive-review` reads whole files for context, so a finding can legally
point at any of these — never assume a reported line is an addition.

For every distinct file that has at least one finding, call
`mcp__gitlab__get_merge_request_diffs` (scoped to that MR) and get its raw
unified diff text (the `diff` field for that file's entry). Parse each hunk
header `@@ -<old_start>,<old_len> +<new_start>,<new_len> @@` and walk the
hunk body line by line, tracking an old-line and a new-line counter starting
at `old_start`/`new_start`:

- line starts with `-` → record `{old_line: old_counter}`, type `deleted`; increment old_counter only
- line starts with `+` → record `{new_line: new_counter}`, type `added`; increment new_counter only
- otherwise (context line) → record `{old_line: old_counter, new_line: new_counter}`, type `context`; increment both

Build a lookup per file from **new-file line number → {type, old_line,
new_line}** (deleted lines have no new-file line number and are never a
valid anchor for these reports, since reports cite new-file line numbers —
see Notes).

For a finding's `line_start`, look it up:
- **Found, type `added`** → position uses `new_line` only, `old_line` omitted.
- **Found, type `context`** → position uses **both** `old_line` and `new_line`.
- **Not found in any hunk for that file** → this finding cannot be
  positioned inline at all. Mark it for the general-note fallback in Step 8
  now — don't attempt the API call.

### Step 5 – Idempotency check

```bash
STATE_FILE="$(git rev-parse --absolute-git-dir)/gitlab-review-published-state"
REVIEW_STATE_FILE="$(git rev-parse --absolute-git-dir)/code-review-state"
REVIEWED_HEAD=$(grep REVIEWED_HEAD "$REVIEW_STATE_FILE" 2>/dev/null | cut -d= -f2)
```

If `$STATE_FILE` exists and its `PUBLISHED_HEAD` equals `$REVIEWED_HEAD` for
the same MR IID, this exact report was already published. Ask the user via
`AskUserQuestion` ("Already published to MR !<iid> at <PUBLISHED_AT>. Publish
again?") before proceeding. If `$REVIEWED_HEAD` is unavailable (state file
missing), skip this check — nothing to compare against.

### Step 6 – Preview and confirm

Before calling any GitLab write tool, show the user:
- MR title and `web_url`
- Total number of inline comments about to be attempted, broken down by
  severity
- Number of findings already known (from Step 4) to require the general-note
  fallback, with their file:line
- That one summary note will also be posted

Ask for confirmation via `AskUserQuestion` ("Publish this review to the MR
above?"). Only proceed on explicit approval.

### Step 7 – Publish the summary note

Build the note body from the captured Summary section:

```markdown
## Code Review Summary

<Summary paragraph, verbatim>

**Findings:** 🔴 a · 🟠 b · 🟡 c · 🔵 d · 🟣 e

<Recommendation line>
```

Post it with `mcp__gitlab__create_merge_request_note` (`project_id`,
`merge_request_iid`, `body`).

### Step 8 – Publish inline comments

For each finding, in the order it appeared in the report:

1. Build the comment body:
   ```markdown
   **<severity emoji> <severity label>**<" — Lines N–M" if it was a range>

   <finding body, verbatim>
   ```
2. **If Step 4 classified this file:line as `added` or `context`** — call
   `mcp__gitlab__create_merge_request_thread` with:
   - `project_id`, `merge_request_iid`, `body`
   - `position`: `base_sha`/`head_sha`/`start_sha` from Step 3's `diff_refs`,
     `position_type: "text"`, `old_path` = `new_path` = the finding's file,
     plus `new_line` (and `old_line` too, if type was `context`) as
     determined in Step 4
   - **On success** — count it as posted inline.
   - **On failure regardless** (GitLab still rejects it — diff version
     mismatch, race with a new push, etc.) — fall back per point 3 below.
     One rejected position must never abort the rest of the publish run.
3. **If Step 4 found no match for this file:line, or the call in point 2
   failed** — fall back to a general comment via
   `mcp__gitlab__create_merge_request_note`:
   ```markdown
   > ⚠️ Could not attach inline — position not found in current diff
   > **Originally:** `<file>:<line_start>`

   <same comment body as above>
   ```
   Count it as posted-as-fallback, and keep going.

### Step 9 – Record publish state

```bash
STATE_FILE="$(git rev-parse --absolute-git-dir)/gitlab-review-published-state"
echo "PUBLISHED_HEAD=$REVIEWED_HEAD"        >  "$STATE_FILE"
echo "MR_IID=<iid>"                         >> "$STATE_FILE"
echo "PROJECT_ID=<project_id>"              >> "$STATE_FILE"
echo "PUBLISHED_AT=$(date -u +%FT%TZ)"      >> "$STATE_FILE"
```

### Step 10 – Report back to the user

Print a short summary: how many comments were posted inline, how many fell
back to general notes (with their file:line), any that failed outright, and
the MR's `web_url`.

## Notes

- **Never guess line numbers.** Anchor inline comments only on line numbers
  the report already stated — don't recompute or "fix" them.
- **File/line reference basis.** Reports cite line numbers from the new
  (right-hand) file version. A reported line is therefore always looked up
  as a **new-file** line number in Step 4's index — it may turn out to be an
  `added` or a `context` line there, never a pure `deleted` one.
- **Don't skip Step 4.** Sending only `new_line` for a context line is a
  quiet failure mode: GitLab rejects it, the finding silently becomes a
  fallback general note, and "mark every related line" degrades into "mark
  only the added lines" without any obvious error. Always classify before
  building a position.
- **One failure ≠ abort.** A position rejected by GitLab means fall back to
  a general note for that one finding; keep publishing the rest.
- **Renames are out of scope for v1.** If a file was renamed on this branch,
  the same path is used for both `old_path`/`new_path`, which will most
  likely fail and fall back to a general note — acceptable for now.
- **Never post without confirmation.** Step 6's confirmation gate is
  mandatory — this posts visibly to a shared Merge Request.
- **Don't duplicate work with `intensive-review`.** This skill only reads
  `code-review.md`; it never re-analyzes the diff itself.
