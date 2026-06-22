# git-review-skill

An AI coding-agent skill that performs a thorough, structured code review of the current Git branch against its base branch and produces a Markdown report ready to paste into a GitHub Pull Request or GitLab Merge Request.

## Features

- **Full branch review** — diffs against the true merge-base so only your branch's changes are analysed
- **Structured severity levels** — every comment is tagged with one of six levels:

  | Level | When to use |
  |-------|-------------|
  | 🔴 **Blocker** | Bug, security hole, or data loss — merge-blocking |
  | 🟠 **Major** | Serious issue, should be fixed before merge |
  | 🟡 **Minor** | Improvement, non-blocking |
  | 🔵 **Nit** | Style / taste, optional |
  | 🟢 **Praise** | Something done particularly well |
  | 🟣 **Needs human review** | Cannot be assessed confidently without more context |

- **Human-in-the-loop principle** — when the reviewer can't determine intent with confidence it flags 🟣 with a precise question rather than guessing
- **PR/MR-ready output** — each comment is a self-contained block with file path, line reference, and code suggestion (including GitHub `suggestion` syntax where applicable)
- **Delta re-review** — after fixes are pushed, re-running the skill reviews only the new changes and tracks the resolution status of every previous finding
- **Automatic base branch detection** — checks `origin/HEAD`, then `main`, then `master`; asks the user when ambiguous

## Installation

Copy `git-review-skill/SKILL.md` into your agent's skills directory.
Refer to your agent's documentation for the exact path (global vs. project-local).

```bash
cp git-review-skill/SKILL.md <your-agent-skills-dir>/intensive-review.md
```

## Usage

Trigger the skill with a slash command or a natural-language request:

```
/intensive-review
```

or

```
Review the current branch
PR review
Code review my changes
```

The agent matches the description and runs the full workflow automatically.

### First review

The agent will:
1. Detect the base branch and compute the merge-base
2. Collect the full diff and commit log
3. Analyse every change across correctness, security, error handling, performance, readability, tests, and conventions
4. Write the report to `code-review.md` and record the reviewed commit to `.code-review-state`

### Re-review after fixes

After pushing new commits, run the skill again. The agent detects `.code-review-state`, diffs only the new commits, and produces a resolution table for every previous finding plus a list of newly introduced issues.

You can add `.code-review-state` to `.gitignore`:

```bash
echo ".code-review-state" >> .gitignore
```

## Output example

```markdown
# Code Review – `feature/auth-tokens` → `main`

**Reviewed state:** `a1b2c3d` · **Base:** `e4f5g6h`
**Files:** 4 changed · +120 / −18 lines · **Commits:** 3

## Summary

This branch replaces plain-text session storage with signed JWTs.
The approach is sound but there is one blocker (secret key hard-coded in
tests leaking to CI logs) and two questions that require human input.
**Recommendation: Changes Requested.**

**Findings:** 🔴 1 · 🟠 0 · 🟡 2 · 🔵 1 · 🟣 2

---

## Comments

### `src/auth/token.ts`

#### 🔴 Blocker — Line 12

> `JWT_SECRET` is hard-coded as a string literal and will be visible in
> CI logs and version history.

```ts
// suggestion
const secret = process.env.JWT_SECRET;
if (!secret) throw new Error("JWT_SECRET env var is required");
```

...
```

## Requirements

- An AI coding agent that supports skills / slash commands (e.g. Claude Code, Cursor, Continue, or similar)
- A Git repository with at least one branch to compare

## License

MIT — see [LICENSE](LICENSE).
