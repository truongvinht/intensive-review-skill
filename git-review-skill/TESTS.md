# Tests – intensive-review skill

Manual test cases for verifying correct skill behaviour. Each test describes the
setup, the expected skill output, and how to verify it. Run them on a throwaway
Git repository unless noted otherwise.

---

## Setup helpers

```bash
# Create a scratch repo used by most tests
mkdir /tmp/skill-test && cd /tmp/skill-test
git init
git commit --allow-empty -m "chore: initial commit"
git remote add origin https://github.com/example/repo.git
```

---

## TC-01 · Happy path — clean branch with minor issues

**Goal:** Skill produces a well-formed report for a normal feature branch.

**Setup:**
```bash
git checkout -b feature/add-greeting
cat > greet.py << 'EOF'
def greet(name):
    print("Hello, " + name)   # minor: use f-string
EOF
git add greet.py && git commit -m "feat: add greeting function"
```

**Trigger:** `/intensive-review` (or "review my branch")

**Expected behaviour:**
- Step 1 detects base branch (`main` or `master`) without asking
- Step 2 produces a one-file diff stat
- Report written to `code-review.md`
- At least one 🟡 Minor comment on the string concatenation
- No 🔴 Blockers
- State file created at `$(git rev-parse --absolute-git-dir)/code-review-state` with `REVIEWED_HEAD`, `BASE`, `REVIEWED_AT`

**Pass criteria:**
- [ ] `code-review.md` exists and contains the `# Code Review` heading
- [ ] Findings line shows `🔴 0`
- [ ] `$(git rev-parse --absolute-git-dir)/code-review-state` exists and `REVIEWED_HEAD` matches `git rev-parse HEAD`

---

## TC-02 · Security blocker — SQL injection

**Goal:** Skill identifies a 🔴 Blocker for unsanitized SQL.

**Setup:**
```bash
git checkout -b feature/user-lookup
cat > db.py << 'EOF'
import sqlite3

def get_user(username):
    conn = sqlite3.connect("app.db")
    cur = conn.cursor()
    cur.execute("SELECT * FROM users WHERE name = '" + username + "'")
    return cur.fetchone()
EOF
git add db.py && git commit -m "feat: add user lookup"
```

**Trigger:** "code review"

**Expected behaviour:**
- Report contains `🔴 **Blocker**` pointing to the `cur.execute` line
- Suggestion uses a parameterised query (`?` placeholder)
- Summary recommendation is **Changes Requested**

**Pass criteria:**
- [ ] `🔴` appears in `code-review.md`
- [ ] Suggestion block shows parameterised query

---

## TC-03 · Ambiguous base branch — asks the user

**Goal:** When both `main` and `master` exist, skill asks before proceeding.

**Setup:**
```bash
git checkout -b master && git checkout -b main   # both branches exist locally
git checkout -b feature/test-ambiguous
echo "x=1" > file.py && git add . && git commit -m "test"
```

**Trigger:** `/intensive-review`

**Expected behaviour:**
- The agent prompts the user to choose between `main`, `master`, or other
- After the user selects an option, review proceeds normally

**Pass criteria:**
- [ ] An interactive prompt appears before any diff is collected
- [ ] Review completes successfully after the user answers

---

## TC-04 · No changes — branch equals base

**Goal:** Skill reports cleanly when there is nothing to review.

**Setup:**
```bash
git checkout main
git checkout -b feature/empty   # no commits added
```

**Trigger:** "review my PR"

**Expected behaviour:**
- Skill reports that there are no changes between base and HEAD
- No `code-review.md` written (or written with a "no changes" notice)
- No state file created at `$(git rev-parse --absolute-git-dir)/code-review-state`

**Pass criteria:**
- [ ] Output contains a message like "no changes" or "nothing to review"
- [ ] Process stops early without producing a findings table

---

## TC-05 · Re-review after fixes

**Goal:** Second run reviews only new commits and resolves previous findings.

**Setup (continue from TC-02):**
```bash
# Fix the SQL injection
cat > db.py << 'EOF'
import sqlite3

def get_user(username):
    conn = sqlite3.connect("app.db")
    cur = conn.cursor()
    cur.execute("SELECT * FROM users WHERE name = ?", (username,))
    return cur.fetchone()
EOF
git add db.py && git commit -m "fix: use parameterised query"
```

**Trigger:** `/intensive-review` (state file from TC-02 exists in `.git/`)

**Expected behaviour:**
- Skill detects `$(git rev-parse --absolute-git-dir)/code-review-state` and uses Step 6 (delta re-review)
- Re-review report uses the *Re-review Output Template*
- Previous SQL injection finding shows `✅ Resolved`
- New `REVIEWED_HEAD` in the state file matches the fix commit

**Pass criteria:**
- [ ] Output contains `# Re-review` heading
- [ ] `✅ Resolved` appears next to the previous SQL injection finding
- [ ] State file `REVIEWED_HEAD` updated to the new commit

---

## TC-06 · Human-in-the-loop escalation

**Goal:** Ambiguous business logic is escalated to 🟣, not guessed.

**Setup:**
```bash
git checkout -b feature/payment
cat > payment.py << 'EOF'
RATE = 0.029   # is this the right rate for EU customers?

def charge(amount, customer_region):
    fee = amount * RATE
    return amount + fee
EOF
git add payment.py && git commit -m "feat: add payment charge"
```

**Trigger:** "review the branch"

**Expected behaviour:**
- The magic number `0.029` is either flagged 🔵 Nit or escalated 🟣 with a
  question about whether the rate varies by region
- The skill does **not** assert it is wrong with high confidence
- If `customer_region` is never used, that may be a 🟠 Major or 🟣 depending
  on whether the skill can determine intent

**Pass criteria:**
- [ ] No false-positive 🔴 Blocker about the rate value
- [ ] Either a 🟣 with an answerable question OR a 🔵 Nit is present
- [ ] The unused `customer_region` parameter is noted

---

## TC-07 · Large diff — file-by-file processing

**Goal:** Skill handles diffs exceeding ~1 500 lines without crashing or
silently truncating.

**Setup:**
```bash
git checkout -b feature/bulk-add
# generate 20 files with ~100 lines each
for i in $(seq 1 20); do
  python3 -c "
for j in range(100):
    print(f'def func_{j}(): return {j}')
" > "module_${i}.py"
done
git add . && git commit -m "feat: add generated modules"
```

**Trigger:** `/intensive-review`

**Expected behaviour:**
- Skill informs the user the diff is large and proceeds file-by-file or
  theme-by-theme
- Report is produced (possibly condensed) without error
- No silent truncation

**Pass criteria:**
- [ ] Output includes a notice about diff size
- [ ] `code-review.md` is written and non-empty

---

## TC-08 · GitLab platform detection

**Goal:** Skill detects GitLab from the remote URL and omits GitHub `suggestion`
blocks.

**Setup:**
```bash
git remote set-url origin https://gitlab.com/example/repo.git
# reuse any branch with changes from a previous test
```

**Trigger:** "MR review"

**Expected behaviour:**
- Code suggestions use plain fenced code blocks, not ` ```suggestion ` blocks
- Report heading uses neutral language ("Code Review"), not "Pull Request"

**Pass criteria:**
- [ ] No ` ```suggestion ` block appears in the report
- [ ] Review completes successfully

---

## TC-09 · Trigger phrase coverage

**Goal:** All documented trigger phrases activate the skill.

| Phrase | Expected result |
|--------|-----------------|
| `/intensive-review` | Full review starts |
| `review my branch` | Full review starts |
| `PR review` | Full review starts |
| `code review` | Full review starts |
| `MR review` | Full review starts |
| `review the changes` | Full review starts |

**Pass criteria:**
- [ ] Each phrase triggers the skill without the user needing to specify the skill explicitly

---

## TC-10 · State file content validation

**Goal:** State file always contains the three required keys, stored inside `.git/`.

**Setup:** Run any successful review (e.g. TC-01).

**Check:**
```bash
STATE_FILE="$(git rev-parse --absolute-git-dir)/code-review-state"
grep -E "^(REVIEWED_HEAD|BASE|REVIEWED_AT)=" "$STATE_FILE" | wc -l
# expected: 3
```

**Pass criteria:**
- [ ] All three keys present
- [ ] `REVIEWED_HEAD` is a valid full SHA (`git cat-file -t <sha>` returns `commit`)
- [ ] `REVIEWED_AT` is in ISO 8601 UTC format (`YYYY-MM-DDTHH:MM:SSZ`)
