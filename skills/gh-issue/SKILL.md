---
name: gh-issue
version: 0.3.1
description: Picks up a GitHub issue, implements the required changes, runs a layered review (fresh-eyes subagents, then a Codex gate), and merges the PR that closes the issue.
disable-model-invocation: true
---

# Implement GitHub Issue

Takes a GitHub issue number, implements the changes, opens a PR, converges it through a layered review, and merges.

Two run modes, referenced throughout:
- **Interactive** — the user typed `/gh-issue N`, or `/issue-runner` took its single-issue fast path. Plan confirmation and merge confirmation apply.
- **Orchestrated** — you were dispatched as an implementer subagent by `/issue-runner`. Plan is pre-approved; you merge yourself on convergence; blockers go back to the parent.

Optional flag: `--max-codex-iterations N` — cap on Codex gate passes in Step 8 Phase 2 (default 2: one gate review + one verification pass). The iterative fix work happens in the Phase 1 local loop, which spends no Codex tokens.

> **Never invoke `/review`, `/security-review`, or `/codex:review` via the Skill tool.** They are terminal-output producers — Skill() hands them the rest of your turn and the steps after the review never run (`/codex:review` is also `disable-model-invocation: true`). Reviews run as fresh subagents or inline; codex runs via Bash. This applies to every step below.

## Workflow

### 1. Understand the issue

```bash
gh issue view <number> --json title,body,labels,assignees,comments
```

No number given → `gh issue list --state open --json number,title,body,labels,comments --limit 20`, summarize the actionable ones, recommend one, and wait for the user to pick.

Read the body and **all comments** — context lives in the discussion. Follow references to other issues/PRs. If a triage *agent brief* comment exists (posted by `/triage` on `ready-for-agent` issues), treat it as the primary spec.

### 2. Explore the codebase

Read CLAUDE.md (root and relevant subdirectories). Then dispatch an `Explore` subagent rather than trawling yourself:

```
Map the parts of this codebase relevant to this issue: <title + body summary>.
Cover related modules, existing patterns to follow, and the tests covering the
area. End with a `Files:` block, one repo-relative path per line.
```

If the Agent tool is unavailable, explore inline.

### 3. Plan

Decide what changes, in what order, with what tests. **Interactive:** share a brief plan and get confirmation (skip for trivial fixes). **Orchestrated:** pre-approved — proceed. Stop only for genuine spec ambiguity (missing or contradictory requirements): return a blocker rather than guessing.

### 4. Branch

```bash
git checkout -b <type>/issue-<number>-<short-slug>   # fix/ feat/ docs/ chore/
```

### 5. Implement

Follow project conventions (CLAUDE.md, existing patterns, linter config). Run tests and linters as you go; add tests for new behavior. If the issue body has an `## Acceptance criteria` checklist (the `/to-issues` format), treat it as the definition of done and verify every item before opening the PR.

### 6. Commit and push

Stage explicitly (no `git add .`). Commit message: `<type>: <description>` with `Closes #<number>` in the body. `git push -u origin HEAD`.

### 7. Open the PR

`gh pr create` — title under 70 chars; body with `## Summary`, `Closes #<number>`, `## Changes`, `## Test plan`.

### 8. Review loop

Capture metadata once:

```bash
PR_NUM=$(gh pr view --json number -q .number)
BASE_BRANCH=$(gh pr view --json baseRefName -q .baseRefName)
```

**Security lens:** if `git diff --name-only "$BASE_BRANCH"...HEAD` touches `auth/`, `security/`, `.env*`, `secrets*`, `credentials*`, or JWT/session/token handling, add to every reviewer prompt: "Also check: new input flows, auth bypass, token exposure, XSS sinks — report only high-confidence NEW findings."

The review output of every pass below is intermediate data, not your final answer. Do not stop until Step 9 — if you are about to write a closing summary before the PR is merged (or blocked), you have stopped too early.

#### Phase 1 — fresh-eyes loop (no Codex spend; cap 4 iterations)

Per iteration, dispatch **two reviewer subagents in parallel** — fresh contexts with no implementation bias. Give both the PR number and the touched-file list, and instruct them to read the touched files in full (invariant violations rarely show in the diff alone):

- **Reviewer A — adversarial:** "Red-team PR #N. Find the strongest reasons it should not ship: invariant violations, partial-failure paths, race conditions, rollback hazards, empty states, trust-boundary crossings. One strong finding beats five weak ones. file:line + concrete recommendation per finding."
- **Reviewer B — gate prep:** "This PR faces a final Codex review gate. Catch what a quick sign-off would miss: invariants the diff alone doesn't reveal, version skew, retries/idempotency, CLAUDE.md convention violations, test-coverage gaps. file:line + recommendation."

Union the findings, dedup by `file:line + claim`, triage (below), apply Apply-class fixes, run tests, commit `refactor: address review (iteration N)`, push, refresh the PR body. **Converged** when an iteration yields no new Apply-class findings (track findings across iterations). Cap reached while still producing Apply-class findings → cap-stop: stop and surface; do not enter Phase 2 with known-unfixed findings.

#### Phase 2 — Codex gate (the only Codex spend; cap `MAX_CODEX_ITERATIONS`, default 2)

```bash
codex review -c model=gpt-5.4 --base "$BASE_BRANCH" 2>&1 | tee "/tmp/codex-review-$PR_NUM.log"
```

(`gpt-5.4` pinned: Phase 1 already pre-cleaned the diff; 5.5's xhigh default isn't worth it here.) Output is text, not JSON. Then:

- **Zero actionable findings** → converged; go to Step 9.
- **Findings** → triage, apply Apply-class fixes, commit `fix: address codex gate findings`, push, refresh the PR body, then run **one** verification pass (the second and final gate pass). Clean → Step 9. Still producing Apply-class findings → cap-stop. Never leave a P1/P2 fix unverified by a subsequent pass.
- **Non-zero exit on credit/quota** (output matches `credit|quota|billing|insufficient|429|rate.?limit|usage.?limit`) → the gate degrades to Phase 1's verdict. Record under `## Review notes` in the PR body: `Codex gate unavailable (credit/quota); merged on local adversarial convergence (N iterations).` Go to Step 9. This is the only path that merges without Codex coverage.
- **Non-zero for any other reason** (auth, network, schema) → interactive: report and ask whether to merge without the gate; orchestrated: blocker.

#### Triage model (both phases)

- **Apply** — real bug introduced by *this PR*: edge case in new code, broken invariant, security issue, missing test for a new branch.
- **Surface, don't auto-apply** — pre-existing issue (verify with `git blame` or `git log -S` against `$BASE_BRANCH`). Note it in the PR body for a follow-up; don't fix unrelated debt.
- **Skip and document** — the reviewer misread the code. Note your 1–2-sentence rebuttal in the PR body; never drop silently.
- **Stop and ask** — convergence failure: a finding contradicts a fix from a prior iteration, or re-appears after being applied. Stop the loop, surface (interactive: ask the user; orchestrated: blocker). Do not merge.
- Nits and style preferences: skip silently.

#### Converged vs bouncing (merge authority — issue-runner defers to this)

**Converged** (mergeable) — any of: the last iteration produced zero actionable findings; OR only findings that are skip-and-documented or P3-cosmetic and orthogonal to earlier fixes; OR the user explicitly authorized merging; OR the gate degraded on credit/quota after Phase 1 convergence (verify the `## Review notes` line exists in the PR body).

**Bouncing** (not mergeable) — any of: a fixed finding re-appeared; a fix introduced equal-or-worse findings; the cap was reached with an unverified P1/P2 fix; `codex review` exited non-zero for a non-credit/quota reason.

#### PR-body discipline

The PR body becomes the squash-commit message (Step 9), so refresh Summary / Changes / Test plan on **every** push. Iteration history goes only under a heading **exactly** `## Review notes` — the merge step strips from that heading down; any other name leaks review chatter into the commit.

### 9. Merge

**Interactive:** present the converged state and confirm with the user before merging. **Orchestrated:** converged → merge yourself; bouncing → push your fixes, refresh the PR body so the unresolved state is visible, and return a blocker citing the findings.

```bash
gh pr merge --squash --delete-branch "$PR_NUM" \
  --subject "$(gh pr view --json title -q .title)" \
  --body "$(gh pr view --json body -q .body | awk '/^## Review notes$/{exit} {print}')"
```

Verify the issue closed: `gh issue view <number> --json state` must be `CLOSED`. A `fatal: '<branch>' is already used by worktree at ...` message after a successful server-side merge is cosmetic (the branch is checked out elsewhere); the orchestrator's cleanup reconciles it.

### 10. Report

PR URL plus: Phase 1 iterations and findings applied, gate passes spent (0–2), final state (clean / degraded on credit-quota / cap-stop / errored), and whether the security lens ran.

## Edge cases

- **Vague issue** — say what's unclear and ask; don't guess.
- **Large issue** — discuss splitting into smaller PRs before starting.
- **Issue blocked on unmerged work** — flag it.
- **Spec-only repos** — "implement" means editing the spec files.
