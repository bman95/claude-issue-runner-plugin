---
name: issue-runner
version: 0.4.0
disable-model-invocation: true
description: "Multi-issue GitHub workflow that you (Claude Code) orchestrate end-to-end with subagents. Builds a dependency DAG over the open-issue queue, runs each issue through an Explore → optional Plan → Implement-in-worktree pipeline, parallelizes independent issues up to a cap, and cascades skip on failure. Trigger: the user types /issue-runner. Do not auto-invoke."
---

# Issue Runner

You are the orchestrator. You drive the entire run yourself using subagents (`Agent`), `Bash`, `Read`, `Write`, `gh`, and `git`. Per-issue work runs in worktree-isolated subagents that follow the `gh-issue` procedure end-to-end (branch → implement → PR → review → merge).

## Arguments

- `/issue-runner` — all open issues in the current repo (label-filtered; see Step 1)
- `/issue-runner 42 43 44` — only the listed issue numbers (label filter is bypassed; the user already chose)
- `/issue-runner --plan` — build the DAG, print it, exit (no execution)
- `/issue-runner --sequential` — equivalent to `--max-parallel 1`
- `/issue-runner --max-parallel N` — concurrency cap (default 10)
- `/issue-runner --max-codex-iterations N` — pass-through cap for the gh-issue Step 8b Codex **gate** in every implementer (default 2: one gate review + one verification pass; the iterative convergence work happens in gh-issue's local adversarial loop and spends no Codex tokens). After a prior run blocker'd on cap-stop, bumping this in a subsequent `/issue-runner` invocation gives the next implementer a higher iteration budget — but that subsequent run is a **fresh orchestration** (new exploration, new branch, new PR), not a resume. The skill does not detect or reuse an existing PR for the same issue. **Operational consequence:** if the prior blocked run already opened a PR for this issue, you'll end up with two PRs for the same issue unless you `gh pr close` (or merge) the old one before re-running. Closing the old PR is usually the right move; its branch and review trail are preserved on the closed PR for forensics.
- `/issue-runner --no-llm-refine` — skip the LLM dependency-refinement pass

## State layout

State initialization is **deferred until Step 1 confirms the scope is orchestrated** (size > 1). Single-issue fast-path runs and `--plan` runs that exit before the implementation phase do not touch `/tmp/issue-runner/` at all — no rotation, no `mkdir`, no leaked `state.prev.*`.

When state is initialized, the previous run's state is preserved as `state.prev.<timestamp>` so a partial-failure rerun doesn't destroy forensics. State directories older than 7 days are auto-pruned at the same time, so `/tmp/issue-runner/` doesn't grow unbounded:

```bash
# Run only inside Step 1's "scope > 1" branch — never at the top of the skill.
find /tmp/issue-runner -maxdepth 1 -name 'state.prev.*' -mtime +7 -exec rm -rf {} + 2>/dev/null || true

STATE_DIR=/tmp/issue-runner/state
if [ -d "$STATE_DIR" ]; then
  mv "$STATE_DIR" "/tmp/issue-runner/state.prev.$(date +%s)"
fi
mkdir -p "$STATE_DIR"
```

The troubleshooting section assumes you can still read `state.prev.*` directories that haven't yet been pruned.

Per-issue subdirectory `$STATE_DIR/issue-N/`:

| File | Purpose |
|---|---|
| `details.json` | Output of `gh issue view N --json ...` |
| `exploration.md` | Output from the `Explore` subagent |
| `plan.md` | Output from the `Plan` subagent (only if planning ran) |
| `status` | One word: `pending`/`exploring`/`planning`/`implementing`/`blocked`/`done`/`failed`/`skipped`. `blocked` is non-terminal — see Step 4 step 5. |
| `error` | Failure reason if `status=failed` or `skipped` |

Run-level files in `$STATE_DIR/`:

| File | Purpose |
|---|---|
| `dag.json` | `{ "N": ["dep1", "dep2", ...], ... }` — issue → list of issue numbers it depends on |
| `scope.txt` | Newline-separated issue numbers in this run's scope |

## Workflow

### Step 0 — resolve bundled dependencies

This skill depends on the bundled `gh-issue` skill (the implementer procedure that every per-issue subagent inlines). Resolve its absolute path **once** at the start of every run, before scope determination, and reuse the resolved path for all subsequent references in this document — including in implementer dispatch prompts.

Resolution order, first hit wins:

1. **Plugin install (preferred):** `${CLAUDE_PLUGIN_ROOT}/skills/gh-issue/SKILL.md`. `CLAUDE_PLUGIN_ROOT` is set automatically by Claude Code when this skill runs as part of an installed plugin.
2. **Local development:** `${HOME}/.claude/skills/gh-issue/SKILL.md`. This works when the skill is symlinked into `~/.claude/skills/` directly from a development checkout.
3. **Fail loudly.** If neither path resolves to an existing file, stop and tell the user that `gh-issue` is missing. Do not attempt to continue with a synthetic procedure.

Concretely:

```bash
GH_ISSUE_SKILL=""
for candidate in \
    "${CLAUDE_PLUGIN_ROOT:-/nonexistent}/skills/gh-issue/SKILL.md" \
    "${HOME}/.claude/skills/gh-issue/SKILL.md"; do
  if [ -f "$candidate" ]; then
    GH_ISSUE_SKILL="$candidate"
    break
  fi
done
[ -n "$GH_ISSUE_SKILL" ] || { echo "gh-issue skill not found" >&2; exit 1; }
echo "$GH_ISSUE_SKILL"
```

Save the resolved path. Wherever the rest of this document refers to `$GH_ISSUE_SKILL` (or to "the gh-issue skill"), substitute the resolved absolute path — including when constructing implementer dispatch prompts (Step 4a). Subagents do not necessarily inherit `CLAUDE_PLUGIN_ROOT`, so always pass the resolved absolute path into the prompt rather than relying on the env var being available downstream.

For orchestrated runs, also write the resolved path to `$STATE_DIR/gh_issue_skill_path` once state is initialized in 1d, so any post-mortem inspection can see which copy was used.

### Step 1 — determine scope

Compute the working scope **before** initializing any state directory. The fast path and `--plan` exit must not leave behind a rotated `state.prev.*`.

**1a. Pick the candidate set.**

- **Explicit numbers passed** (`/issue-runner 42 43 44`): that's the scope verbatim. Skip the label filter — the user already chose.
- **No arguments — all-open branch:** list open issues:

  ```bash
  gh issue list --state open --json number,title,body,labels,assignees,comments --limit 50
  ```

  The list is capped at 50 by `gh`'s default. If the repo has more, surface that to the user before proceeding rather than silently truncating.

**1b. Default-skip parked labels (all-open branch only).** Partition the list into "active" and "parked" by label name. **Parked labels (case-insensitive exact match after trimming whitespace):** `on-hold`, `wontfix`, `parking-lot`, `blocked`, `discussion-only`, `needs-info`, `stale`, `duplicate`. Match the whole label name — don't substring-match `in-progress`, `unblocked`, etc. Hyphenated/underscored variants (`on_hold`, `On-Hold`) should still match — normalize before comparing.

> Note on `duplicate`: this is a strong "default-skip" signal, not a "safe to work automatically" one — it usually means the issue should be closed entirely and the work tracked elsewhere. The Include-all-parked option still surfaces these to the user, but in practice the right action for a `duplicate` is `gh issue close`, not implementation.

If any issues are parked, ask the user via `AskUserQuestion` (one prompt, three options):
- **"Skip parked, continue with active issues only"** *(recommended)* — leave parked out of scope.
- **"Include all parked issues too"** — fold them in.
- **"Pick which to include"** — user types a comma-separated list of issue numbers (or `none`).

If `AskUserQuestion` is not in the orchestrator's tool surface, ask the same question in a normal assistant chat turn and wait for the reply before continuing. Either way, do not auto-include parked issues without asking — auto-working an `on-hold` ticket creates unwanted PRs.

**Empty parked partition.** If no issue carries a parked label, do not surface the parked question — proceed silently to 1c.

**Scope-shaping addendum (optional).** If the bulk-list scan reveals other scope concerns the user should adjudicate before orchestration starts (decision-needed labels, target files known to be deleted/renamed, obviously obsolete issues, non-parked blocking labels), you may add at most one extra `AskUserQuestion` block in the same prompt as the parked question (or alone, if parked was empty). Keep it tight: one question, options the user can actually pick, no "I'll figure it out inline" choices unless you can in fact integrate inline answers downstream. Closing or modifying issues outside scope (`gh issue close`, label edits) is permissible only when the user explicitly chose that option in the addendum — never silently. Record any such side-effect in `$STATE_DIR/scope_actions.txt` once state is initialized in 1d (skip the file for fast-path single-issue runs).

Explicit-number runs bypass both the parked filter and the scope-shaping addendum entirely.

**1c. Single-issue fast path.** If the resulting scope size == 1, **stop here**:
- Do **not** initialize `/tmp/issue-runner/state` (no rotation, no `mkdir`, no prune).
- Read `$GH_ISSUE_SKILL` (resolved in Step 0) and follow the procedure inline on the target issue.
- Same procedure as the user typing `/gh-issue N` directly — no worktree, no state directory, no DAG.
- Because this is the **interactive** gh-issue path (not an orchestrated implementer dispatch), gh-issue Step 3 still asks the user for plan confirmation unless the issue is straightforward.

> **⚠ Do NOT call `Skill("gh-issue")`.** `gh-issue` is `disable-model-invocation: true` — `Skill()` will refuse the invocation outright. Inline the procedure instead.

**1c-pre. Audit pre-existing dirty state.** Before initializing state (and before the fast path executes), run `git status --porcelain=v1 -uall` and surface every `M`/`A`/`D`/`R`/`U`/`??` line to the user — not just the digest from `git status` short mode. Long orchestrated runs interact poorly with stale staged content: leftovers from a previous session can survive the run and look like the orchestrator left them, which costs hours of post-mortem debugging. If anything is reported, ask the user (one prompt) to choose: (a) stash, (b) commit, (c) discard, or (d) proceed and accept that the dirty state will be visible at the end. Do not start orchestration on a dirty tree without an explicit choice. A clean tree skips this prompt silently.

**1d. Initialize state (orchestrated runs only — scope size >= 2).** Run the State layout block now (prune + rotate + `mkdir`). This block has no locking — see the "single-host single-user assumption" entry under Hard rules; concurrent `/issue-runner` invocations on the same host will race here.

```bash
find /tmp/issue-runner -maxdepth 1 -name 'state.prev.*' -mtime +7 -exec rm -rf {} + 2>/dev/null || true

STATE_DIR=/tmp/issue-runner/state
if [ -d "$STATE_DIR" ]; then
  mv "$STATE_DIR" "/tmp/issue-runner/state.prev.$(date +%s)"
fi
mkdir -p "$STATE_DIR"
```

**1e. Populate per-issue `details.json`.** For each issue in scope:

```bash
for N in $SCOPE; do
  mkdir -p "$STATE_DIR/issue-$N"
  gh issue view "$N" --json number,title,body,labels,assignees,comments \
    > "$STATE_DIR/issue-$N/details.json"
done
```

For the all-open branch you may instead split the bulk-list JSON into per-issue files to avoid a second round-trip per issue.

**1f. Save `scope.txt`.** Newline-separated issue numbers in the order the run will process them.

### Step 2 — build the DAG

Heuristic pass over each issue's body + comments:

- `depends on #X` or `blocked by #X` → issue depends on X
- `blocks #X` → X depends on this issue

**Out-of-scope dependencies are not silently dropped.** If an edge points to an issue not in `scope.txt`, surface it to the user and let them choose:

- **extend** — add the prerequisite to scope (re-fetch its `details.json`, re-run the heuristic on it).
- **drop-issue** — remove the dependent from scope (its DAG edges go with it).
- **override** — keep the dependent in scope but acknowledge the prerequisite is satisfied externally (e.g., already merged on another branch). Record the override in `$STATE_DIR/overrides.txt`.

Do not proceed to the LLM pass until every out-of-scope edge is resolved.

LLM refinement pass (skip if `--no-llm-refine`): dispatch a single `Plan` subagent with all issue bodies and ask it to flag (a) hidden hard dependencies (X needs Y's code to exist) and (b) cross-issue conflicts (parallel work would collide). Have it respond with one JSON edge per line:

- `{"kind":"depends","from":X,"on":Y,"reason":"..."}`
- `{"kind":"conflict","a":X,"b":Y,"reason":"..."}` — for each conflict, the parent picks a serialization order (see below) and folds it in as a `depends` edge.

**Parsing is best-effort.** Skip lines that don't parse as JSON or reference issues outside scope. Never fail the run on a malformed refinement output — log the rejected lines to `$STATE_DIR/refinement-rejects.txt` and continue.

**Conflict ordering.** Default to "earlier-in-`scope.txt` runs first" (which preserves the user's stated order when they passed explicit numbers, and falls back to issue-number ascending for the all-open branch). For each conflict, capture `{"a":X,"b":Y,"order":"X-then-Y","reason":"..."}` in `$STATE_DIR/conflicts.json` so the printed plan can show it.

Fold the edges in. Persist to `$STATE_DIR/dag.json`.

**Print the plan to the user.** One line per issue: number, deps, title. Then a separate "Conflicts forced into serial order" section listing each conflict with its chosen order and reason. The only override mechanism is to re-invoke with explicit `/issue-runner N M ...` in the order the user wants — that populates `scope.txt` in user-specified order, and the next run's "earlier-in-`scope.txt` first" rule honors it. Editing `conflicts.json` in place would not survive the next run's state-dir rotation, so don't suggest it. If `--plan`, exit.

### Step 3 — gather context (Explore + optional Plan)

Set `MAX_PARALLEL_EXPLORE` (default 5). Read-only agents are cheaper than implementers but unbounded fan-out across a 50-issue scope still risks parent-session overload before any implementation starts. Dispatch in waves: while there are scope issues without an `exploration.md`, fill up to `MAX_PARALLEL_EXPLORE` slots with `Explore` subagents and wait for the wave to complete before dispatching the next.

```
prompt: |
  GitHub issue #N: <title>
  Body: <body>
  Comments: <comments>

  Map the parts of this codebase relevant to fixing this issue.
  Cover: related modules, existing patterns to follow, tests that
  cover the area. Keep prose under 400 words.

  At the end of your response, ALWAYS include a structured block:

      Files:
      path/to/file1.ext
      path/to/file2.ext
      ...

  One path per line, repo-relative, no other text in the block.
  This block is parsed by the orchestrator to count files touched —
  every Explore output must include it, even if the answer is a
  single file or "none".
```

Save each result to `$STATE_DIR/issue-N/exploration.md`.

Decide which issues need an explicit `Plan` pass: count the lines in the `Files:` block of `exploration.md` (`awk '/^Files:/{flag=1; next} flag && NF' exploration.md | wc -l` or equivalent). Plan if file count > 3, or if the issue has labels `feature`/`refactor`/`epic`/`complex`. Dispatch `Plan` agents in waves of `MAX_PARALLEL_EXPLORE` the same way:

```
prompt: |
  Plan the implementation for issue #N.
  Issue: <title + body>
  Exploration: <contents of exploration.md>

  Produce a concrete step-by-step plan: files to change, order of
  edits, tests to add, risks. Under 500 words.
```

Save to `$STATE_DIR/issue-N/plan.md`.

### Step 4 — execute pipelines

Set `MAX_PARALLEL` (default 10, override by flag). Mark all in-scope issues `status=pending`.

Loop until every issue has terminal status (`done`/`failed`/`skipped`):

1. **Cascade skip first.** Walk every `pending` issue and check its DAG deps. If any dep has `status=failed`/`skipped`, mark this issue `skipped` with error `"dependency failed: #X"`. Repeat until no pending issue is freshly skipped — this is required because a single failed dep can transitively skip a chain in one iteration. Skip-cascade must run before the cycle check in step 6.
2. **Compute ready set.** Issue is *ready* if `status=pending`, all its DAG deps have `status=done`, and it is not currently in flight.
3. **Fill slots.** While `len(in_flight) < MAX_PARALLEL` and ready set non-empty: pop next ready issue, dispatch its implementer agent (see below), set `status=implementing`.
4. **Wait** for any in-flight agent to complete (notification arrives).
5. **Process result.** Verify `gh issue view N --json state`:
   - Closed → `status=done`.
   - Open + agent reported a bouncing review loop per Step 4a override 3 (cap reached with unverified P1/P2 fix, contradictory iteration, re-flagged finding, or `codex review` non-zero for a reason other than credit/quota) → `status=blocked`. Save the agent's last message as `error`. **Cascade-skip in step 1 treats `blocked` as a paused dep, not failed** — `pending` issues with a `blocked` dep stay `pending` until Step 5 escalation transitions the blocked issue to `done` / `failed` / `skipped`.
   - Open + environmental block (missing credentials, irresolvable merge conflict, spec ambiguity) → `status=failed`. Save error.
   - Agent crashed, returned no usable result, or did not emit a `worktree:` line → `status=failed`. Save error.
6. **Detect cycle.** If `in_flight` is empty, ready set is empty, and pending issues remain *after* the cascade in step 1 has already fired this iteration — the only remaining cause is a true DAG cycle (every pending issue has at least one pending dep, none failed). Mark remaining `status=skipped` with `error="cycle: depends on #X"` (cite an actual offending dep) and exit the loop. Do not use `error="deadlock"` — it conflates this case with the cascade-skip case in step 1, which is already correctly attributed to its upstream failure.

### Step 4a — implementer agent dispatch

For each issue, dispatch one `Agent` call. Substitute `<N>` with the issue number and `<MAX_CODEX_ITERATIONS>` with the run-level cap (default 2, override via `/issue-runner --max-codex-iterations N`):

```
subagent_type: general-purpose
isolation: worktree
run_in_background: true
description: "Implement issue #N"
prompt: |
  Implement GitHub issue #<N> end-to-end.

  Follow the procedure in <GH_ISSUE_SKILL> exactly (the parent has
  resolved this to an absolute path before dispatching you — read
  it from the path inserted here, not from any other location):
  understand → branch → implement → commit → push → open PR → run
  the layered review (local /review inline + codex review CLI loop)
  → merge.

  Pre-gathered context — read these first:
  - Issue details: /tmp/issue-runner/state/issue-<N>/details.json
  - Exploration:   /tmp/issue-runner/state/issue-<N>/exploration.md
  - Plan (if any): /tmp/issue-runner/state/issue-<N>/plan.md

  You are running in a worktree-isolated copy of the repo. Branch
  off the default branch.

  ORCHESTRATED-RUN OVERRIDES — these supersede gh-issue where they
  conflict. Read all overrides in this section before starting.

  1. **Step 3 (plan confirmation) is pre-approved.** The parent
     already gathered the exploration and (if present) plan
     artifacts above. Do NOT pause to ask the user to confirm the
     implementation plan — those artifacts are the user's approval.
     The only exception: if the issue spec is genuinely ambiguous
     (missing requirements, contradictory comments, conflicting
     acceptance criteria) such that you cannot pick a single
     implementation path from the artifacts, stop and return a
     blocker (see Blocker conditions below) instead of guessing.

  2. **Step 8b (Codex gate) cap.** Run with
     `MAX_CODEX_ITERATIONS=<MAX_CODEX_ITERATIONS>` (gate passes only —
     gh-issue's Phase 1 local adversarial loop has its own cap and
     spends no Codex tokens). Do not silently exceed this — if the
     gate wants to continue past the cap, that is a "stop and
     surface" signal, not a license to keep going.

  3. **Merging — only on a CONVERGED review loop.** gh-issue
     assumes a human merges; in this run you are the merger, but
     the authority to merge is conditional.

     A loop is **converged** (mergeable) when ANY of the following
     hold:

     - The most recent iteration produced zero actionable findings, OR
     - The most recent iteration's findings are all (a) skip-and-document
       with explicit out-of-scope rationale (e.g. cross-spec changes
       outside this issue's scope) or (b) P3 cosmetic/nit and orthogonal
       to anything fixed earlier, OR
     - The user explicitly authorized merging despite open findings via
       a Step 5 escalation, OR
     - The Codex gate degraded on a credit/quota error AFTER Phase 1
       local convergence (gh-issue Step 8b Phase 2 step 4). The
       `## Review notes` line it records is the audit trail — verify
       it is present in the PR body before merging on this basis.

     A loop is **bouncing** (NOT mergeable) when ANY of the following
     hold:

     - A finding fixed in iter N reappears in iter N+1, OR
     - Iter N's fix introduced findings of equal or greater priority
       in iter N+1, OR
     - The cap was reached with at least one P1/P2 fix from the final
       iteration unverified by a subsequent codex pass, OR
     - `codex review` exited non-zero for any reason OTHER than
       credit/quota (auth, network, schema — those still block; only
       the credit/quota path is allowed to degrade to local convergence).

     "Cap reached with only P3/skip-documented findings on the final
     iteration" is **converged**, not bouncing — the previous version
     of this rule conflated the two and rejected mergeable PRs.

     If converged, merge the PR yourself:

         PR_NUM=$(gh pr view --json number -q .number)
         gh repo view --json mergeCommitAllowed,squashMergeAllowed,rebaseMergeAllowed
         gh pr merge --squash --delete-branch "$PR_NUM"   # or --merge / --rebase

     **Squash-commit message comes from the PR body.** Without an
     explicit `--body`, `gh pr merge --squash` uses the current PR
     title as the commit subject and the current PR body as the
     commit body. If the PR body accumulated reviewer-facing notes
     during the Codex loop (per gh-issue Step 8b's PR-body refresh
     instruction, those notes live under a `## Review notes` heading
     whose name is locked there), strip them by passing an explicit
     `--body` constructed from everything above that canonical
     heading:

         gh pr merge --squash --delete-branch "$PR_NUM" \
           --subject "$(gh pr view --json title -q .title)" \
           --body "$(gh pr view --json body -q .body | awk '/^## Review notes$/{exit} {print}')"

     The single-source-of-truth heading is defined in gh-issue Step
     8b — change it there and update this `awk` pattern to match.

     The merged PR's `Closes #<N>` closes the issue. Verify with
     `gh issue view <N> --json state` (must be `CLOSED`) before
     reporting done.

     `gh pr merge --squash --delete-branch` may print
     `fatal: 'main' is already used by worktree at ...` when run
     from inside an Agent-tool worktree (the parent has `main`
     checked out elsewhere). The server-side merge and remote
     branch deletion both succeed regardless; the local-branch-delete
     failure is cosmetic and Step 6's cleanup loop reconciles it via
     `git worktree prune`. Don't treat this message as a merge failure.

     If the loop is bouncing (per the bouncing list above) — **DO
     NOT MERGE**. Push all your fixes so the PR reflects the latest
     state, refresh the PR body via `gh pr edit "$PR_NUM" --body ...`
     so the merger sees the unresolved state, and return a blocker
     under the Blocker conditions below. The user will pick a Step 5
     escalation (retry, parent-side codex re-review, parent-applied
     inline fix, fail, rescue, or bump-and-rerun).

  4. **Worktree path in your final message.** Output your worktree
     path on its own line as `worktree: <absolute-path>`. Use
     `git rev-parse --show-toplevel` to get it. The parent uses
     this line for cleanup (done issues) or forensics
     (failed/skipped issues).

  5. **Per-issue guidance lives in files, not the prompt.** All
     issue-specific instructions — file targets, anti-scope-creep
     callouts, dependency context (e.g. "#119 just merged, read
     it from main first"), explicit "do not edit X" lists, codex
     finding text being addressed on a retry — must be written to
     `$STATE_DIR/issue-<N>/guidance.md` and referenced by path in
     the dispatch prompt. The dispatch prompt may name the path
     and give a one-line summary, but must not paste the body.
     This honors the Hard rule "State always goes through files."
     The implementer reads `guidance.md` immediately after
     `details.json` / `exploration.md` / `plan.md`. Skip the file
     when no per-issue guidance exists; do not write empty
     placeholders.

  Blocker conditions — stop and return a clear blocker message
  (still emit the `worktree:` line) when ANY of these hold:
  - Spec ambiguity per override 1.
  - Missing credentials, irresolvable merge conflict, or other
    environmental block.
  - Codex gate (or Phase 1 local loop) is bouncing per override 3.
  Cite the specific finding(s) and termination reason. Do not
  invent answers. Do not merge if uncertain.

  END ORCHESTRATED-RUN OVERRIDES.

  Do NOT call Skill("gh-issue") or Skill("review") or
  Skill("codex:review"). The exact reasons differ — `gh-issue` has
  `disable-model-invocation: true` so Skill() will refuse it;
  `review` and `codex:review` are terminal-output producers, so
  Skill() hands them the rest of your turn and the steps after the
  review never run. Either way, inline the procedures and run codex
  via Bash (`codex review -c model=gpt-5.4 --base "$BASE_BRANCH"`).
```

Why `general-purpose` and not a typed agent: `general-purpose` is the only built-in subagent type that exposes `Tools: *` (the full tool surface — Bash, Edit, Write, plus everything else). The typed `Explore` and `Plan` agents are explicitly read-only and cannot run `gh pr create`, `git push`, file edits, or `gh pr merge`. Verify before changing this — if a future agent definition narrows `general-purpose`'s tool set, the implementer dispatch breaks at Step 4a.

### Step 5 — handle blocked / failed agents

If an implementer returns a blocker (status `blocked` per Step 4 step 5) or fails:

1. Read its message and the most recent codex log under `$STATE_DIR/issue-N/`.
2. Ask the user directly with the issue number, the blocker reason, the latest codex finding(s), and any context the agent collected. Do **not** retry blindly.
3. Based on the user's answer, pick one of the supported escalations below. They are listed in order of typical preference (cheapest to heaviest).

**Retry the implementer** — re-dispatch with corrected context. See "Re-dispatch prompt shape" below. The implementer reuses its existing worktree and pushes additional commits to its existing PR.

**Run one more codex pass from the parent** — when the user thinks the previous codex iteration was probably the last needed, but the implementer hit cap before verifying. Run codex against the implementer's worktree from a controlled cwd:

```bash
pushd "$WORKTREE" >/dev/null
codex review -c model=gpt-5.4 --base "$BASE_BRANCH" \
  > "$STATE_DIR/issue-$N/codex_rerun_$(date +%s).log" 2>&1
popd >/dev/null
```

If the new log is converged per Step 4a override 3, the parent merges from the same `pushd`/`popd` block. If it is bouncing or surfaces a new finding, ask the user again. Always restore cwd via `popd` even on error — see Step 6's cwd-verification step.

**Apply an inline fix from the parent** — only when the next finding is small, architecturally clear, and the user explicitly authorizes it. The parent edits inside the worktree, runs tests, commits, pushes, then runs codex again under the same `pushd`/`popd` discipline. This is a heavier escalation than re-dispatching the implementer because the parent now carries implementation context; reserve it for one-line fixes (e.g. wrapping a failing call in try/except) that are faster than priming a fresh subagent. Do not chain multiple inline fixes — if the next codex pass surfaces another finding, hand back to the implementer or rescue.

**Mark the issue `failed`** — let the cascade skip dependents. Use when the issue cannot be made convergent within reasonable effort and is not blocking the rest of scope.

**Hand off to `/codex:rescue`** — fresh investigation by a different agent. The parent dispatches it (subagents cannot dispatch other agents). Pass the worktree path and codex log; rescue runs in the same worktree.

**Bump the Codex cap and re-run** — only when the blocker is a converged-but-unverified cap-stop and the user wants more iteration budget. `--max-codex-iterations` is **not** a per-retry override that applies inside the current orchestration. The user must re-invoke the whole skill: `/issue-runner <failed-N> --max-codex-iterations N`. That subsequent run is a fresh orchestration (see Arguments) — the existing PR for this issue will not be reused, so close it first (`gh pr close`) or merge as-is. **Multi-issue scope warning:** if only one issue (or small subset) blocked in a prior multi-issue run while the rest completed, re-invoke with **just the failed issue numbers** — never the original full scope, which would re-implement already-completed issues and create duplicate PRs.

**Re-dispatch prompt shape (for "Retry the implementer").** When retrying, write the user's answer plus any pasted finding text to `$STATE_DIR/issue-N/guidance.md` (overwrite or append a `## Retry N` section — never paste into the prompt body). The dispatch prompt must include all of:
- existing worktree path (the implementer continues on the same branch, not a fresh worktree)
- existing PR number (additional commits go to the same PR)
- path to `$STATE_DIR/issue-N/guidance.md`
- path to the most recent codex log under `$STATE_DIR/issue-N/codex_rerun_*.log` (or the implementer's own codex log if the parent didn't re-run codex)

Per Step 4a override 5, do not paste the codex findings or the user's guidance into the prompt body — file paths only.

### Step 6 — cleanup and summary

After the loop ends:

- **Verify cwd is the main repo before cleanup.** Step 5's parent-side codex re-review and inline-fix escalations both `cd` (or `pushd`) into a worktree. If a `popd` was missed or a bare `cd` was used, the parent's cwd may still be inside a now-stale worktree, which makes Step 6 try to clean up a worktree from inside it. Restore explicitly:

  ```bash
  MAIN_REPO=$(git -C "$STATE_DIR" rev-parse --show-toplevel 2>/dev/null \
              || git -C "$(dirname "$STATE_DIR")" rev-parse --show-toplevel 2>/dev/null \
              || pwd)
  # If MAIN_REPO turns out to be a worktree (it has a .git file, not a dir),
  # resolve to the source repo:
  if [ -f "$MAIN_REPO/.git" ]; then
    MAIN_REPO=$(git -C "$MAIN_REPO" rev-parse --git-common-dir | xargs dirname)
  fi
  cd "$MAIN_REPO"
  ```

  Sanity-check by confirming `git rev-parse --is-inside-work-tree` returns `true` and `git status` shows the expected branch.

- **Resolve the default branch once** before the cleanup loop — the branch deletions below must never target it:

  ```bash
  DEFAULT_BRANCH=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@')
  [ -n "$DEFAULT_BRANCH" ] || DEFAULT_BRANCH=$(git rev-parse --abbrev-ref HEAD)   # parent stays on the default branch (Hard rules)
  ```

- **Remove worktrees for `done` issues, then delete their merged local branches.** Parse the `worktree: <path>` line out of each implementer's final message (the dispatch prompt in Step 4a requires it). The Agent tool keeps a lock file on every worktree it created (`lock reason: claude agent agent-XXX (pid <parent>)`), so plain `git worktree remove --force` is insufficient — git explicitly prints `use 'remove -f -f' to override or unlock first`. Capture the branch first (it becomes a dangling local ref once the worktree is gone), remove the worktree, then delete the branch:

  ```bash
  WT_BRANCH=$(git -C "$WT" rev-parse --abbrev-ref HEAD 2>/dev/null)
  git worktree unlock "$WT" 2>/dev/null || true
  git worktree remove -f "$WT" || git worktree remove -f -f "$WT"

  # This issue is `done` → its PR merged and closed it, so the branch is
  # merged even though `gh pr merge --delete-branch` only removed the REMOTE
  # copy. Use -D, NOT -d: a `--squash` merge (Step 4a's default) rewrites
  # history, so the branch's commits are not ancestors of the squashed
  # default-branch commit and `-d` would wrongly refuse ("not fully merged").
  # -D is safe here precisely because `done` is positive proof of merge —
  # never run this for failed/skipped. `git branch -D` still refuses a branch
  # checked out in another worktree, which protects a concurrent run's branch.
  if [ -n "$WT_BRANCH" ] && [ "$WT_BRANCH" != HEAD ] && [ "$WT_BRANCH" != "$DEFAULT_BRANCH" ]; then
    git branch -D "$WT_BRANCH" 2>/dev/null || true
  fi
  ```

  For `failed` / `skipped` issues, leave both the worktree AND its branch in place for forensics and record the path in `$STATE_DIR/issue-N/worktree`. After the per-issue loop completes, run `git worktree prune` once to reconcile any local-branch-delete leftovers from `gh pr merge --delete-branch` (see Step 4a override 3 cosmetic-failure note).

- **Sweep merged scratch branches.** The Agent tool creates each worktree on a `worktree-agent-<hash>` branch and the implementer branches off it, leaving the scratch branch behind, pointing at the base commit (a true ancestor of the default branch). The per-issue deletion above misses these — the worktree's checked-out branch was the `feat/...` branch, not the scratch one. After `git worktree prune`, sweep any that survive:

  ```bash
  git for-each-ref --format='%(refname:short)' refs/heads/ \
    | grep -E '^worktree-agent-' \
    | while read -r b; do git branch -d "$b" 2>/dev/null || true; done
  ```

  Use `-d` (not `-D`) here: these point at ancestors of the default branch, so the safe ancestry check passes for genuinely-merged scratch branches and refuses any that unexpectedly carry unmerged commits. Branches checked out in a live worktree (a concurrent run) are refused automatically. The `worktree-agent-*` name is the Agent tool's current convention — if a Claude Code version changes it, this sweep is belt-and-suspenders only; the per-`done`-issue deletion above is the primary mechanism.

- **Verify the main repo is clean.** Run `git status --porcelain=v1 -uall` and compare against the snapshot taken in Step 1c-pre. Anything new is either a leaked side-effect of orchestration (report to the user, don't auto-discard) or a continuation of pre-existing dirty state the user explicitly accepted. Surface the diff.

- Print a summary table: number, status, title, error if any. Group `blocked` issues separately from `failed` — `blocked` are paused on user input, `failed` are terminal.

- Exit non-zero (in spirit — set the closing message accordingly) if any issue is `failed`. `skipped` and `blocked` are not errors but should be highlighted.

## Hard rules

- **No Python orchestrator.** Don't reach for a script. The runtime here is you (the parent Claude Code session) plus subagents.
- **State always goes through files**, not your context. After a phase produces output, write it and reference it by path in the next subagent's prompt. Don't paste exploration.md back in if you can pass the path.
- **Never invoke `gh-issue`, `/review`, or `/codex:review` via `Skill()`.** `gh-issue` is `disable-model-invocation: true` (Skill() refuses); `/review` and `/codex:review` are terminal-output producers (Skill() steals the rest of the turn). Either way, inline the procedures or shell out (`codex review -c model=gpt-5.4 --base "$BASE_BRANCH"`).
- **Fast path for single issue.** Don't orchestrate when scope == 1. Inline `gh-issue` directly.
- **Worktree isolation** is the only way two implementers can run in parallel safely. The Agent tool's `isolation: "worktree"` does this for you — don't manage worktrees by hand unless the cleanup step requires it.
- **Single-host, single-user assumption.** `/tmp/issue-runner/state` is a single global path with no locking. Two concurrent `/issue-runner` invocations on the same host will collide on the rotate, prune, and `details.json` writes. If you need parallel orchestrated runs, run them under different `$USER`s (so `/tmp/issue-runner/$USER/state` is per-user) or wrap the State layout block in `flock /tmp/issue-runner/.lock` — this skill itself does not.
- **Parent stays in the main repo.** Bash `cd` in the parent session is sticky across tool calls — every Step 5 escalation that needs to enter a worktree (codex re-review, inline fix, parent-side merge from inside a worktree) MUST use `pushd`/`popd` paired in the same Bash invocation, not bare `cd`. Rationale: a parent that drifts into a worktree breaks Step 6's cleanup (you can't remove the worktree you're standing in) and produces misleading `git status` output (you see the worktree's state, not the main repo's). If a `pushd`/`popd` pair feels awkward, run the work inside `bash -c '...'` so the cd is scoped to that subshell.

## Troubleshooting

- **Stuck pending issues at end of run** — the DAG has a cycle. Inspect `$STATE_DIR/dag.json` and re-run with `--no-llm-refine` if the LLM pass added a bogus edge.
- **Worktrees leaking under `~/.cache/` or wherever the Agent tool put them** — `git worktree prune` in the target repo. The cleanup step in Step 6 should prevent this for `done` issues; `failed`/`skipped` issues may leave worktrees behind for forensics.
- **Merged feature branches piling up locally** — `gh pr merge --delete-branch` deletes only the *remote* branch; the local copy lingers, and after a `--squash` merge `git branch -d` refuses it (the squashed commit isn't a descendant of the branch tip, so git can't prove the branch is merged). Step 6 force-deletes each `done` issue's branch (`git branch -D`, gated on `done` = positive proof of merge) and sweeps leftover `worktree-agent-*` scratch branches with `-d`. Branches from an *aborted* run are intentionally left behind — delete them by hand after confirming their PR merged: `git branch -D <name>` (squash/rebase) or `git branch -d <name>` (merge-commit).
- **`fatal: cannot remove a locked working tree, lock reason: claude agent agent-XXX (pid <N>)`** — the Agent tool keeps a process-scoped lock on every worktree it created until the parent session exits. Step 6's recipe (`git worktree unlock` then `git worktree remove -f -f`) handles it. If a leftover lock survives the session entirely, `rm -rf "$WT/.git"` then `git worktree prune` from the main repo as last resort.
- **`gh pr merge --delete-branch` printed `fatal: 'main' is already used by worktree at ...`** — cosmetic. The server-side merge and remote branch deletion both succeeded; only the local-branch-delete failed because the implementer was running from a worktree where `main` is checked out elsewhere by the parent. `git worktree prune` reconciles after Step 6.
- **Final summary says scope was clean but `git status` shows leftover staged files** — Step 1c-pre missed something or was skipped. Diff against `$STATE_DIR/issue-N/` to see whether the file came from an orchestrated commit (look in `git log` of each branch). If it predates the run, it's pre-existing dirty state the user accepted in 1c-pre and Step 6's "Verify the main repo is clean" step would have surfaced it.
- **An issue keeps failing the same way across retries** — escalate to `/codex:rescue` from the parent for an external investigation, or take it out of scope and handle it manually.
- **Implementer kept hitting the codex cap with cascading findings** — the symptoms are different from a true bouncing loop (each iteration's findings are *new*, not re-flagging earlier fixes). Step 4a override 3 calls this "converged" if the final iteration's findings are skip-and-document or P3. If they're P1/P2, the user has three good options under Step 5: parent-side codex re-review (cheap), parent-applied inline fix (when the next finding is small and clear), or bump-and-rerun (fresh orchestration with higher cap).
