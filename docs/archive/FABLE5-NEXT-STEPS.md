# FABLE5 Next Steps — claude-issue-runner-plugin

Plan date: 2026-07-01. Based on `FABLE5-AUDIT.md` (same date). Repo is 10 tracked Markdown/JSON files at v0.6.0 with substantive uncommitted spec changes in three files.

**SAFE tag** = an AI agent can implement it autonomously tonight: local edits to specs, docs, or scripts only. Nothing here touches accounts, credentials, deployments, or external systems. Actually *committing/tagging/publishing* the release is explicitly left to Bryan in every step below.

---

## Quick wins (under 30 minutes total)

| # | Action | SAFE |
|---|--------|------|
| QW1 | Fix `README.md:49`: `--max-parallel` default 10 → 5, matching `skills/issue-runner/SKILL.md:19`. | SAFE |
| QW2 | Fix `README.md:76`: replace the stale "collide on `/tmp/issue-runner/state/`" limitation with the new per-repo-key path (`/tmp/issue-runner/<repo-key>/state`) and what it does/doesn't protect against. | SAFE |
| QW3 | Remove the ineffective `/tmp/issue-runner/` entry from `.gitignore` (line 15) — gitignore patterns are repo-relative; system `/tmp` is not coverable. Add a one-line comment or drop silently. | SAFE |

These three are pure doc/hygiene fixes with zero behavioral risk and eliminate the README-vs-spec contradiction introduced by the uncommitted work.

---

## P0 — before anything else ships

### 1. Fix the Step 3 cycle-check misfire on blocked-dep chains — **SAFE**
- **Type:** spec bugfix
- **File:** `skills/issue-runner/SKILL.md` (Step 3, item 6, ~line 103)
- **Rationale:** The audit's highest-impact real-run bug. When one issue is `blocked` and its dependents are `pending` with nothing in flight, item 6's condition ("nothing in flight, nothing ready, pending remain → cycle → skip") fires and silently skips healthy dependents while the blocker awaits Step 4 escalation. A paused run becomes a partially-abandoned run with no signal.
- **Acceptance criteria:**
  - Item 6's cycle condition explicitly excludes issues that are transitively pending on any `blocked` issue (e.g. "only declare a cycle if no pending issue has a `blocked` ancestor in the DAG").
  - The spec states what happens to blocked-ancestor pending issues instead (they wait for Step 4 resolution of the blocker).
  - A dry-read of the execute loop with the scenario "A blocked, B depends on A, nothing else" ends in B waiting, not B skipped.
  - `REFERENCE.md` gains a short note distinguishing "cycle" from "blocked chain" for troubleshooting.
- **Effort:** ~30–45 min (careful spec wording, cross-check items 1/4/6 stay consistent).

### 2. Prepare the pending work as a proper v0.7.0 release — **SAFE** (file prep only; Bryan commits)
- **Type:** release hygiene
- **Files:** `CHANGELOG.md`, `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, `skills/gh-issue/SKILL.md` (frontmatter version), `skills/issue-runner/SKILL.md`
- **Rationale:** ~60 lines of substantive uncommitted spec changes (per-repo STATE_DIR, interactive worktree lifecycle, --max-parallel 10→5) violate the project's own exemplary release discipline: no version bump, no changelog entry. This is the audit's top finding. Behavior changes ⇒ 0.7.0, not 0.6.1.
- **Acceptance criteria:**
  - `CHANGELOG.md` gains a `0.7.0` entry in the house style (rationale, not just deltas) covering: per-repo STATE_DIR, interactive worktree create/teardown, --max-parallel default change, plus the Step 3 cycle fix (step 1) and the quick wins.
  - `version` is `0.7.0` in **both** `plugin.json` and `marketplace.json` (line 13), and `gh-issue` frontmatter is bumped from 0.4.0 consistently with its changes.
  - No file mentions two different defaults or versions (grep `0.6.0`, `default 10` returns nothing stale).
  - **Not done tonight:** `git commit` / tag / marketplace publish — left for Bryan to review and execute.
- **Effort:** ~30 min.

---

## P1 — fix before the next real orchestrated run

### 3. Require positive merge proof before `git branch -D` (CLOSED → done inference) — **SAFE**
- **Type:** spec bugfix (data-loss prevention)
- **Files:** `skills/issue-runner/SKILL.md` (~lines 99, 175), `skills/gh-issue/SKILL.md` (~line 170)
- **Rationale:** `gh issue view N --json state` = `CLOSED` is treated as `done`; Step 5 then force-deletes the branch. An issue closed manually or via an unrelated PR's `Closes #N` during the run destroys unmerged work.
- **Acceptance criteria:**
  - `done` requires a merged PR linked to the issue (e.g. `gh pr list --state merged --search "<branch>"` or PR `mergedAt` check), not just issue `CLOSED`.
  - `CLOSED` without a merged PR gets its own state (e.g. `closed-externally`): branch is **kept**, run report flags it for human review.
  - Cleanup recipes only use `-D` after the merged-PR proof; otherwise `-d` or no deletion.
  - `REFERENCE.md` documents the new state and why.
- **Effort:** ~45 min.

### 4. Harden the interactive worktree lifecycle in gh-issue — **SAFE**
- **Type:** spec bugfix
- **File:** `skills/gh-issue/SKILL.md` (~lines 76, 165), `REFERENCE.md`
- **Rationale:** Two audit findings in the same code path: (a) `awk '/^worktree /{print $2; exit}'` truncates the main-checkout path at the first space, making teardown `cd` to a wrong path and `git worktree remove` fail from inside the worktree; (b) `git worktree add` at `$ROOT/../<name>-issue-<n>` fails with no recovery guidance if an aborted run left the directory behind.
- **Acceptance criteria:**
  - Porcelain parsing is space-safe (e.g. `sed -n 's/^worktree //p' | head -1` or `${line#worktree }`), and any other `$2`-style parsing of porcelain output in both SKILL.md files is checked and fixed the same way.
  - Step 4 includes a pre-flight recipe: if the target worktree dir already exists, `git worktree remove --force` (or prune + rm) it before `git worktree add`, mirroring the orchestrated-leak recipe.
  - `REFERENCE.md` covers interactive-mode leftover worktrees (currently orchestrated-only).
- **Effort:** ~30–45 min.

### 5. Add a consistency lint script (drift guard) — **SAFE**
- **Type:** tooling/test
- **Files:** new `scripts/lint.sh` (or similar) + optional `.github/workflows/lint.yml`; README note
- **Rationale:** Every process bug the audit found (version drift across plugin.json/marketplace.json, README default vs spec default, missing frontmatter bump) is mechanically checkable. This is the only "test" a prompt-spec plugin can realistically have, and it eliminates the dual-maintenance version fields as a recurring failure mode.
- **Acceptance criteria:**
  - A dependency-free bash script that fails non-zero if: `plugin.json` version ≠ `marketplace.json` version; any SKILL.md frontmatter is missing name/description/version; README `--max-parallel` default ≠ SKILL.md default; CHANGELOG lacks an entry for the manifest version.
  - Running it on the current (pre-fix) tree reproduces the audit's drift findings; on the post-fix tree it passes.
  - Workflow file (if added) just runs the script on push/PR — writing the file is local; it activates only when Bryan pushes.
- **Effort:** ~1 h.

---

## P2 — worth doing, not urgent

### 6. Document prompt-injection surface and tighten the Codex-gate skip condition — **SAFE**
- **Type:** security hardening (spec/docs)
- **Files:** `skills/gh-issue/SKILL.md` (~line 127), `README.md` (Known limitations), `REFERENCE.md`
- **Rationale:** Autonomous implementers with merge authority consume issue bodies/comments verbatim; the Codex gate can be skipped on a regex match against credit/quota strings that could appear in attacker-controlled or coincidental output. Low probability today (Bryan authors the issues via `/issue-plan`) but the runner accepts arbitrary open issues.
- **Acceptance criteria:**
  - README "Known limitations" gains an explicit warning: do not point the runner at repos with untrusted issue authors; issue content is executed as instructions by agents holding merge authority.
  - The credit/quota degradation path requires the error to come from the Codex CLI invocation itself (exit code / stderr of that command), not a regex over general review output, and logs the skip prominently in the run report.
  - Optional spec line telling implementers to treat issue bodies as data (task description), never as instructions that override the SKILL procedure.
- **Effort:** ~45 min.

---

## Suggested tonight (all SAFE)

Order: QW1–QW3 → step 1 → step 3 → step 4 → step 5 → step 6 → step 2 last (so the CHANGELOG 0.7.0 entry covers everything done tonight). Leave the tree uncommitted for Bryan's morning review; the lint script from step 5 is the self-check that everything is consistent.

**Explicitly NOT for tonight:** `git commit`, tagging, pushing, or publishing 0.7.0 to the marketplace — Bryan reviews and executes the release himself.
