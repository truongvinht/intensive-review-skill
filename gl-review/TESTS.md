# Tests – gl-review skill

Manual test cases for verifying correct skill behaviour. These assume a
throwaway GitLab project reachable through a configured `@zereight/mcp-gitlab`
server, plus a local clone with `origin` pointing at it. Run `intensive-review`
first where a test depends on an existing `code-review.md`.

---

## TC-01 · Happy path — publish a fresh report

**Goal:** All findings from a clean report are posted inline, plus one
summary note.

**Setup:**
- A branch with an open MR against `main`
- `code-review.md` present with 1 🔴, 1 🟡, 1 🟣 finding, no prior publish state

**Trigger:** `/gl-review` (or "publish this review to the MR")

**Expected behaviour:**
- Skill reads `code-review.md`, resolves the MR by current branch
- Shows a preview (3 inline comments, 1 summary note) and asks for confirmation
- After confirming, posts 1 summary note + 3 inline threads
- Writes `$(git rev-parse --absolute-git-dir)/gitlab-review-published-state`

**Pass criteria:**
- [ ] Confirmation prompt appears before any GitLab write call
- [ ] MR shows 3 inline discussion threads at the correct file/line
- [ ] MR shows 1 top-level note with the summary + findings count
- [ ] `gitlab-review-published-state` contains `PUBLISHED_HEAD`, `MR_IID`, `PROJECT_ID`, `PUBLISHED_AT`

---

## TC-02 · No report found

**Goal:** Skill refuses to publish when `code-review.md` is missing.

**Setup:** Branch with no `code-review.md` in the repo root.

**Trigger:** `/gl-review`

**Expected behaviour:**
- Skill detects the missing report and stops
- Asks whether to run `intensive-review` now or abort

**Pass criteria:**
- [ ] No GitLab tool is called before a report exists
- [ ] User is prompted, not silently blocked

---

## TC-03 · No open MR for the branch

**Goal:** Skill asks for help instead of guessing when no MR matches.

**Setup:** Branch with a valid `code-review.md` but no MR opened yet for that
branch.

**Trigger:** `/gl-review`

**Expected behaviour:**
- `get_merge_request` and the `list_merge_requests` fallback both return
  nothing
- Skill asks the user for an explicit MR IID (or to abort)

**Pass criteria:**
- [ ] No inline comment is attempted without a resolved MR
- [ ] User is asked, not shown an unhandled tool error

---

## TC-04 · Multiple open MRs for the branch

**Goal:** Skill disambiguates instead of picking one arbitrarily.

**Setup:** Two open MRs both sourced from the same branch (e.g. targeting
different base branches).

**Trigger:** `/gl-review`

**Expected behaviour:**
- Skill lists both MRs (IID + title) and asks the user to choose

**Pass criteria:**
- [ ] Both candidate MRs are shown with enough detail to distinguish them
- [ ] Publishing proceeds only against the chosen MR

---

## TC-05a · Finding on an unchanged context line still goes inline

**Goal:** A finding whose line is an unchanged context line inside a diff
hunk (not a `+` line) still gets a correctly-positioned inline comment,
instead of silently falling back.

**Setup:** A branch where `intensive-review` flagged a line that is shown in
the MR's diff (within a hunk) but wasn't itself added or removed — e.g. an
existing line right next to a new one, where the finding is about the
interaction between old and new code.

**Trigger:** `/gl-review`

**Expected behaviour:**
- Step 4's diff-position index classifies that new-file line as `context`
- The resulting `create_merge_request_thread` call includes **both**
  `old_line` and `new_line` in `position`
- The comment posts inline on the first try — it does not appear in the
  fallback/general-note count

**Pass criteria:**
- [ ] The finding appears as an inline thread, not a general comment
- [ ] Terminal summary counts it under "posted inline", not "fallback"

---

## TC-05 · Unmappable line falls back to a general note

**Goal:** A finding whose line is no longer part of the diff (stale report,
file since changed again) does not abort the run.

**Setup:** `code-review.md` references `src/old.ts:42`, but the file has
since been renamed/edited so that position no longer exists in the MR diff.

**Trigger:** `/gl-review`

**Expected behaviour:**
- `create_merge_request_thread` fails for that finding
- Skill falls back to `create_merge_request_note` with the
  "⚠️ Could not attach inline" prefix and the original `path:line`
- All other findings still post normally

**Pass criteria:**
- [ ] The MR has a general comment quoting `src/old.ts:42` for that finding
- [ ] The remaining findings appear as normal inline threads
- [ ] Final terminal summary lists this item under "fallback", not "failed"

---

## TC-06 · Re-publish guard (idempotency)

**Goal:** Running the skill twice against the same reviewed commit warns
before duplicating comments.

**Setup:** Continue from TC-01 without any new commits or re-review.

**Trigger:** `/gl-review` again

**Expected behaviour:**
- Skill reads `gitlab-review-published-state`, sees `PUBLISHED_HEAD` already
  matches the current `REVIEWED_HEAD`
- Asks the user to confirm before publishing again

**Pass criteria:**
- [ ] Warning/question appears before any GitLab write call
- [ ] Declining leaves the MR unchanged

---

## TC-07 · Needs Human Review items posted inline

**Goal:** 🟣 findings are posted the same way as other findings — inline, no
special summary-only handling.

**Setup:** `code-review.md` contains a `## 🟣 Needs Human Review` section with
one item at `payment.py:5`.

**Trigger:** `/gl-review`

**Expected behaviour:**
- The 🟣 item is posted as an inline thread on `payment.py` line 5, with the
  observation/question text preserved verbatim

**Pass criteria:**
- [ ] Inline thread exists at the correct line
- [ ] Comment body includes "Question for the author/reviewer"

---

## TC-08 · Re-review report — still-open and new findings

**Goal:** Skill correctly parses the re-review template, not just the
initial-review template.

**Setup:** `code-review.md` is a `# Re-review – ...` report with:
- one ❌ Not addressed item in "Status of previous findings"
- one new 🟠 Major finding under "New issues introduced by the changes"
- one ✅ Resolved item

**Trigger:** `/gl-review`

**Expected behaviour:**
- The ❌ item and the new 🟠 finding are both posted inline
- The ✅ Resolved item is skipped entirely — no comment posted for it

**Pass criteria:**
- [ ] Exactly 2 inline threads posted (not 3)
- [ ] No thread references the ✅ Resolved finding's location

---

## TC-09 · Non-GitLab remote

**Goal:** Skill refuses gracefully on a GitHub remote instead of guessing.

**Setup:** `git remote set-url origin https://github.com/example/repo.git`

**Trigger:** `/gl-review`

**Expected behaviour:**
- Skill detects the host is not GitLab and stops with a clear message

**Pass criteria:**
- [ ] No GitLab MCP tool is called
- [ ] User sees a message explaining this skill is GitLab-only

---

## TC-10 · Confirmation gate cannot be bypassed

**Goal:** No GitLab write call happens before the user explicitly confirms.

**Setup:** Any valid report + resolvable MR (reuse TC-01 setup).

**Trigger:** `/gl-review`, then answer "no" to the confirmation prompt

**Expected behaviour:**
- Skill stops immediately after a "no" answer
- No note or thread is created on the MR

**Pass criteria:**
- [ ] MR has zero new comments after declining
- [ ] No publish-state file is written
