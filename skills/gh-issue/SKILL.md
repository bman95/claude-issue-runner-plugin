---
name: gh-issue
version: 0.1.0
description: Picks up a GitHub issue, implements the required changes, and opens a pull request.
disable-model-invocation: true
---

# Implement GitHub Issue

Takes a GitHub issue number, reads its details and discussion, implements the required changes in the codebase, and opens a PR that closes the issue.

## Arguments

The user may provide an issue number (e.g., `/gh-issue 42` or `/gh-issue #42`). If no number is provided, list open issues, analyze them, and propose which one(s) to work on — do NOT ask the user for a number.

Optional flags:
- `--max-codex-iterations N` — cap on Codex review/fix cycles in step 8b (default 3). Raise for high-stakes PRs; lower for trivial ones.

## Workflow

### 1. Understand the issue

If a number was provided:
```bash
gh issue view <number> --json title,body,labels,comments,assignees
```

If no number was provided, list open issues and analyze them:
```bash
gh issue list --state open --json number,title,body,labels,assignees,comments --limit 20
```

Review the open issues, considering priority labels, dependencies, and complexity. Present a brief summary of each actionable issue and recommend which to tackle next (and why). Wait for the user to pick one before proceeding.

Once an issue is selected, read the full issue body and all comments — context often lives in the discussion, not just the title. If the issue references other issues or PRs, read those too (`gh issue view`, `gh pr view`).

### 2. Understand the codebase

Read CLAUDE.md (project root and any subdirectory CLAUDE.md files) to understand conventions, architecture, and constraints. Then explore the relevant parts of the codebase — files mentioned in the issue, related modules, tests. Build enough context to plan a solid implementation.

### 3. Plan the implementation

Before writing code, think through:
- What files need to change?
- Are there existing patterns to follow?
- What tests need to be added or updated?
- Are there any cross-cutting concerns (migrations, config, docs)?

**Interactive run** (the user typed `/gh-issue N` directly, OR `/issue-runner` took the single-issue fast path and is following this procedure inline): share a brief plan with the user and get confirmation before proceeding. If the issue is straightforward (typo fix, small config change), skip the plan and just do it.

**Orchestrated implementer run** (dispatched as a subagent by `issue-runner` Step 4a, with pre-gathered exploration/plan artifacts in the dispatch prompt): the dispatch prompt's overrides explicitly pre-approve Step 3. Do not pause to ask the user to confirm — proceed with the implementation. Only stop and return a blocker if the spec is genuinely ambiguous (missing requirements, contradictory comments, conflicting acceptance criteria) such that no single implementation path can be picked from the artifacts.

### 4. Create a branch

```bash
git checkout -b fix/issue-<number>-<short-slug>
```

Use a descriptive slug derived from the issue title (e.g., `fix/issue-42-login-timeout`). Use `fix/` for bugs, `feat/` for features, `docs/` for documentation, `chore/` for maintenance.

### 5. Implement the changes

Write the code. Follow the project's conventions (from CLAUDE.md, existing patterns, linter config). Run tests and linters as you go to catch issues early. If the project has a test suite, make sure existing tests still pass and add new tests for your changes where appropriate.

### 6. Commit and push

Stage the relevant files (avoid `git add .` — be explicit about what you're committing). Write a clear commit message that references the issue:

```
<type>: <description>

Closes #<number>
```

Push the branch:

```bash
git push -u origin HEAD
```

### 7. Open the PR

```bash
gh pr create --title "<concise title>" --body "$(cat <<'EOF'
## Summary
<What this PR does and why, in 1-3 bullets>

Closes #<number>

## Changes
<List of key changes>

## Test plan
<How to verify the changes work>
EOF
)"
```

The PR title should be concise (under 70 chars). The body should link back to the issue with `Closes #<number>` so it auto-closes on merge.

### 8. Code quality review

After the PR is created, run a two-layer review locally: **Claude first, then Codex via its CLI**. Both run inside this skill — no GitHub bots, no PR-comment polling, no async waiters.

> **Flow discipline for this entire step.** Step 8 has substeps (8a → 8b → Step 9). Each substep produces intermediate output, not your turn's terminal answer. Do not stop until the PR is merged (or you've genuinely hit a blocker that requires user input). If you find yourself about to write a closing summary before Step 9, you're stopping too early — re-check which substep you're on and continue.

Capture PR metadata once before the substeps:

```bash
PR_NUM=$(gh pr view --json number -q .number)
BASE_BRANCH=$(gh pr view --json baseRefName -q .baseRefName)
```

Decide whether to also run a security pass: if `git diff --name-only "$BASE_BRANCH"...HEAD` touches paths matching `auth/`, `security/`, `**/.env*`, `**/secrets*`, `**/credentials*`, or files containing JWT/session/token handling, set `SECURITY=yes`; otherwise `SECURITY=no`.

#### 8a. Local Claude review (always)

> **⚠ DO NOT call `Skill(review)` or `Skill(security-review)` here.** Those skills are *terminal output producers* — invoking them via the Skill tool hands the turn's final output to the sub-skill, and the "apply findings + commit + push" steps below never run. You (Claude) notice the review ends and stop. This is the failure mode that reliably breaks the loop.
>
> Instead, perform the review **inline** inside this turn, following the procedure below. The review output is intermediate data, not your final answer — you must keep going.

**Inline review procedure** (the same procedure `/review` uses when a user invokes it directly):

```bash
gh pr diff "$PR_NUM"        # plus gh pr view for PR metadata
```

Analyze the diff for:
- **Correctness**: bugs, regressions, mishandled edge cases, type narrowing gaps.
- **Conventions**: CLAUDE.md rules, existing patterns, naming.
- **Performance**: hot paths, unnecessary re-renders, N+1 queries, bundle impact.
- **Security**: only surface-level here — the `/security-review` inline pass (below) covers depth.
- **Test coverage**: missing cases, regressions in existing tests.

Produce a short findings list with file:line references.

**If `SECURITY=yes`, also run the `/security-review` procedure inline** — read the diff, cross-reference against the current files, check for new input flows / auth bypass / token exposure / clear-auth gaps / new XSS sinks. Report only high-confidence (≥8) NEW findings.

**Apply findings (this is the critical step that stopping breaks):**
1. Read the affected file/lines.
2. Apply the minimal fix.
3. Skip nits and false positives — use judgment.

If you applied fixes, commit with `refactor: address local review feedback`, push, AND refresh the PR body via `gh pr edit "$PR_NUM" --body ...` so Summary, Changes, and Test plan reflect the current diff. Then immediately continue to **Step 8b** — do not stop, do not summarize for the user, do not wait for approval.

---

**Why not `Skill(review)`?** The `/review` skill is designed for the user typing `/review` at the CLI: its prompt ends at "produce the review" and the skill's job is done. When you invoke it programmatically from here, the harness injects the review skill's prompt as a new user turn — your response to that turn *is* your terminal output, and the remaining steps in this file are out of scope for that turn. The only reliable fix is to not invoke it and instead inline the procedure.

#### 8b. Codex review loop (synchronous, local)

The OpenAI Codex plugin (`openai-codex`) provides `/codex:review` for interactive use. Inside this skill we invoke the same underlying CLI directly so the turn flow stays under our control — `disable-model-invocation: true` on `/codex:review` would block dispatching it via `Skill()` anyway, and shelling out keeps the loop simple.

> **⚠ Same `Skill()` warning as 8a applies to `Skill(codex:review)`.** Don't try it. Always run via Bash as shown below.

Loop until Codex reports no actionable findings, or `MAX_CODEX_ITERATIONS` is reached (default 3, override via `--max-codex-iterations N`):

1. Run a review against the PR's base branch:
   ```bash
   codex review --base "$BASE_BRANCH"
   ```
   Capture the full stdout. The output is human-readable, not JSON — read it as text.

2. Triage findings (four-way decision model — the binary "actionable / skip" split is too coarse for repeated-review loops):

   - **Apply** — real bug introduced by *this PR*: missed edge case in new code, broken invariant, security issue, contract violation, missing test for a new branch.

   - **Surface, do not auto-apply** — pre-existing latent issue not introduced by this PR. Verify with `git log -S '<pattern>' "$BASE_BRANCH"...HEAD` (the change must be absent in `BASE_BRANCH`) or `git blame` on the cited lines (the lines must predate this branch). If pre-existing, note in the PR body so the merger can decide whether to take a follow-up; don't silently auto-fix unrelated debt.

   - **Skip and document** — Codex misread the code. Re-read the cited lines, articulate your read in 1–2 sentences, and note the disagreement in the PR body. Do not silently drop — the next reviewer needs to see why you skipped.

   - **Stop and ask** — convergence failure: a new iteration contradicts a fix applied in a prior iteration, or the same finding reappears after being applied. End the loop, surface the situation to the user (or, in an orchestrated run, return a blocker to the parent), and **do not merge**.

   - **Skip (no documentation needed)** — nits, style preferences, speculative refactors. Apply judgment; nits don't earn a PR-body mention.

3. If the iteration produced no Apply-class findings AND no Stop-and-ask trigger → break the loop, proceed to **Step 9**.

4. Apply Apply-class fixes inline. Read affected file/lines, make minimal edits.

5. Commit with `fix: address codex review findings (iteration N)`, push, AND refresh the PR body via `gh pr edit "$PR_NUM" --body ...` so Summary, Changes, and Test plan reflect the current diff (including any new tests added). The merger should not have to read the commit log to understand the PR's current state.

   **The PR body becomes the squash-commit message.** `gh pr merge --squash` (used by humans interactively, and by orchestrated `/issue-runner` runs) defaults to using the current PR body as the commit body. Keep Summary / Changes / Test plan terse and merger-facing. If you also want to record reviewer-facing iteration history, put it under a section heading **exactly equal to `## Review notes`** — no aliases, no variants. The merger's body-stripping `awk` filter (see `issue-runner` Step 4a override 3) matches that canonical heading exactly. If you name the section differently, the heading and everything below it will leak into the squash commit message.

6. Increment iteration counter. If `< MAX_CODEX_ITERATIONS` AND no Stop-and-ask trigger fired this iteration, go back to step 1. Otherwise stop and report — do not loop indefinitely.

**Failure modes — when the loop ends NOT cleanly:**
- **`codex review` exits non-zero** (auth missing, network down, etc.): report the error to the user. In an interactive run, ask whether to merge without Codex coverage. In an orchestrated run, return a blocker — do not auto-merge.
- **Cap reached with findings still pending**: stop and surface the remaining findings. The default is **NOT to merge**. The user decides whether to (a) merge anyway, (b) re-run with `--max-codex-iterations N` bumped (this is the documented re-authorization path), or (c) dispatch `/codex:rescue` for a deeper investigation. In an orchestrated run, return a blocker — never silently merge after a cap-stop.
- **Contradictory iterations** (a new iteration overturns a fix from a prior iteration): stop and surface. Don't silently re-flip your previous change. This is a Codex-loop convergence failure, not progress.
- **Re-flagged after applied** (Codex re-raises a finding you just fixed): same — stop and surface. Either Codex isn't seeing your fix (did you commit and push? did you also `gh pr edit` the body?), or its read of the fix is incompatible with the surrounding code in a way that needs a human call.

### 9. Report back

Tell the user the PR URL and a brief summary of what was done. Include the review status:
- Whether the diff touched a security path (and so `/security-review` ran inline)
- Local `/review` (and `/security-review` if applicable): findings count, applied fixes
- Codex: iterations run, total findings addressed, final state (clean / max-iterations / errored)

## Edge cases

- **Vague issue:** If the issue lacks enough detail to implement, tell the user what's unclear and ask for guidance rather than guessing.
- **Large issue:** If the issue requires many changes across many files, discuss with the user whether to break it into smaller PRs or do it all at once.
- **Blocked issue:** If the issue depends on another unmerged PR or unresolved issue, flag this to the user.
- **Spec-only repos:** If the repo has no source code (only specs/docs), implement means editing the spec files, not writing code.
