---
name: issue-runner
version: 0.7.0
disable-model-invocation: true
description: "Multi-issue GitHub workflow orchestrator. Builds a dependency DAG over the open-issue queue and dispatches each issue to an autonomous, worktree-isolated implementer subagent that follows the bundled gh-issue procedure end-to-end (explore → implement → PR → review → merge), parallelizing independent issues and cascade-skipping dependents on failure. Trigger: the user types /issue-runner. Do not auto-invoke."
---

# Issue Runner

You are the orchestrator. Implementers are `general-purpose` subagents in isolated worktrees. They can spawn their own subagents (Explore for codebase mapping, fresh reviewers for the review loop), so they gather their own context and converge their own PRs — your job is scope, DAG, dispatch, blocker handling, and cleanup. You never enter a worktree yourself.

For troubleshooting and the rationale behind the defensive recipes, see [REFERENCE.md](REFERENCE.md).

## Arguments

- `/issue-runner` — all open issues (label-filtered, Step 1)
- `/issue-runner 42 43 44` — exactly these issues; label filters bypassed
- `/issue-runner --plan` — build and print the DAG, then exit
- `/issue-runner --max-parallel N` — concurrency cap (default 5); `--sequential` ≡ `--max-parallel 1`
- `/issue-runner --max-codex-iterations N` — Codex gate cap passed to every implementer (default 2)
- `/issue-runner --no-llm-refine` — skip the LLM dependency-refinement pass

Re-runs are fresh orchestrations, not resumes: re-invoke with **only** the failed issue numbers, and close a blocked run's leftover PR (`gh pr close`) before re-running its issue, or you get two PRs for the same issue.

## State

`STATE_DIR=/tmp/issue-runner/<repo-key>/state`, where `<repo-key>` is derived from the repository root so runs in **different repos never share state**. Resolve it once (below) and use the resolved absolute path everywhere after — subagents don't inherit it, so substitute the literal path into dispatch prompts (Step 3a), exactly as with `GH_ISSUE_SKILL`. Initialized only for orchestrated runs (scope ≥ 2); the single-issue fast path and a `--plan` exit never touch it. Single-host, single-user: two concurrent runs *in the same repo* still collide on this path — runs in different repos are isolated.

```bash
# Namespace state by repo root so different repos never collide on a shared /tmp path.
# The orchestrator never enters a worktree, so the toplevel is stable for the whole run.
REPO_ROOT=$(git rev-parse --show-toplevel)
REPO_KEY=$(basename "$REPO_ROOT")-$(printf '%s' "$REPO_ROOT" | sha1sum | cut -c1-8)
RUN_ROOT=/tmp/issue-runner/$REPO_KEY
STATE_DIR=$RUN_ROOT/state

find "$RUN_ROOT" -maxdepth 1 -name 'state.prev.*' -mtime +7 -exec rm -rf {} + 2>/dev/null || true
[ -d "$STATE_DIR" ] && mv "$STATE_DIR" "$RUN_ROOT/state.prev.$(date +%s)"
mkdir -p "$STATE_DIR"
```

Run level: `dag.json` (issue → list of dep issue numbers), `scope.txt` (issue numbers in run order), `gh_issue_skill_path`. Per issue under `issue-N/`: `details.json`, `status` (`pending`/`implementing`/`blocked`/`done`/`failed`/`skipped`/`closed-externally`), `error`, optional `guidance.md`, `worktree` (recorded for `failed`/`skipped`/`closed-externally`).

## Workflow

### Step 0 — resolve the gh-issue skill

```bash
GH_ISSUE_SKILL=""
for c in "${CLAUDE_PLUGIN_ROOT:-/nonexistent}/skills/gh-issue/SKILL.md" \
         "$HOME/.claude/skills/gh-issue/SKILL.md"; do
  [ -f "$c" ] && GH_ISSUE_SKILL="$c" && break
done
[ -n "$GH_ISSUE_SKILL" ] || { echo "gh-issue skill not found" >&2; exit 1; }
```

Always pass the resolved absolute path into dispatch prompts — subagents do not inherit `CLAUDE_PLUGIN_ROOT`.

### Step 1 — determine scope

**Explicit numbers passed** → that is the scope verbatim; skip to the fast-path check.

**No arguments** → `gh issue list --state open --json number,title,body,labels,assignees,comments --limit 50`. If the repo has more than 50 open issues, tell the user rather than silently truncating. Then filter:

- **Parked labels.** Partition by parked labels — exact match, case/separator-insensitive: `on-hold`, `wontfix`, `parking-lot`, `blocked`, `discussion-only`, `needs-info`, `stale`, `duplicate`. If any are parked, ask via `AskUserQuestion`: skip parked *(recommended)* / include all / pick. Never auto-include a parked issue. No parked issues → no question. (`duplicate` usually wants `gh issue close`, not implementation — say so if the user includes one.)

**Single-issue fast path.** If scope size == 1: do not initialize state or build a DAG. Read `$GH_ISSUE_SKILL` and follow the procedure inline as an interactive run (plan confirmation applies). Isolation still happens — gh-issue's interactive mode creates its own worktree in Step 4 and tears it down in Step 9 — so the orchestrator's state and Step 5 cleanup are not needed here. Never `Skill("gh-issue")` — see Hard rules.

**Dirty-tree audit.** `git status --porcelain=v1 -uall`. If anything is reported, show every line and ask: stash / commit / discard / proceed-as-is. Never start orchestration on a dirty tree without an explicit choice. Keep the output as a snapshot for Step 5's clean check.

**Initialize state** (scope ≥ 2): run the State block, write `scope.txt` and `gh_issue_skill_path`, then save each issue's details:

```bash
for N in $SCOPE; do
  mkdir -p "$STATE_DIR/issue-$N"
  gh issue view "$N" --json number,title,body,labels,assignees,comments > "$STATE_DIR/issue-$N/details.json"
done
```

### Step 2 — build the DAG

**Primary source — the `## Blocked by` section** emitted by `/to-issues`: every bullet referencing `#X` is an edge N→X; a literal "None - can start immediately" means no deps. **Fallback heuristic** for issues without that section — scan body + comments for inline phrases: `depends on #X` / `blocked by #X` → edge N→X; `blocks #X` → edge X→N.

**Out-of-scope edges are never dropped silently.** For each edge pointing outside `scope.txt`, ask the user: **extend** (pull the prerequisite into scope), **drop-issue** (remove the dependent), or **override** (prerequisite satisfied externally; record in `$STATE_DIR/overrides.txt`).

**LLM refinement** (skip if `--no-llm-refine`): dispatch one `Plan` subagent with all issue bodies; it returns one JSON edge per line. When every in-scope issue carries a `## Blocked by` section, ask the agent for `conflict` edges only — the dependencies are already explicit — `{"kind":"depends","from":X,"on":Y,"reason":"…"}` or `{"kind":"conflict","a":X,"b":Y,"reason":"…"}`. Parsing is best-effort: log unparseable or out-of-scope lines to `$STATE_DIR/refinement-rejects.txt` and continue; never fail the run on bad refinement output. Serialize each conflict as a `depends` edge using scope.txt order (earlier runs first) and record it in `$STATE_DIR/conflicts.json`.

Persist `dag.json`. **Print the plan**: one line per issue (number, deps, title) plus a section for conflicts forced into serial order. To override an order, the user re-invokes with explicit numbers in the desired order. If `--plan`, exit here.

### Step 3 — execute

Set `MAX_PARALLEL` (default 5). Mark every issue `pending`, then loop until all statuses are terminal (`done`/`failed`/`skipped`/`closed-externally`) or paused (`blocked`):

1. **Cascade skip.** Any `pending` issue with a `failed`/`skipped` dep → `skipped`, error `"dependency failed: #X"`. Any `pending` issue with a `closed-externally` dep → `skipped`, error `"dependency closed externally without merge proof: #X"` — the dep is terminal but its work is unverified, so dependents must not build on it (and must not be mislabeled as a cycle). Repeat until stable. A `blocked` dep pauses its dependents (they stay `pending`); it does not skip them.
2. **Ready set** = `pending` ∧ all deps `done` ∧ not in flight.
3. **Fill slots** up to `MAX_PARALLEL` with dispatches (Step 3a); mark `implementing`.
4. **Wait** for any in-flight agent to complete.
5. **Process the result.** A `CLOSED` issue is `done` **only with positive merge proof** — the implementer's own PR actually merged. `CLOSED` alone is not proof: the issue may have been closed by hand or by an unrelated PR's `Closes #N` mid-run. Derive the branch from the returned worktree (read-only; never `cd` into it) and look for a merged PR on it:

   ```bash
   ISSUE_STATE=$(gh issue view "$N" --json state -q .state)
   WT_BRANCH=$(git -C "$WT" rev-parse --abbrev-ref HEAD 2>/dev/null)
   MERGED_PR=$(gh pr list --head "$WT_BRANCH" --state merged --json number -q '.[0].number')
   ```

   - **`CLOSED` + `MERGED_PR` non-empty** → `done`. This is the only status that authorizes Step 5's `git branch -D` (positive proof of merge).
   - **`CLOSED` + no merged PR on that branch** → `closed-externally`: closed out-of-band, **not** merge proof. Save an `error` note ("closed without a merged implementer PR"), **keep the worktree and branch**, and flag it in the Step 5 summary for human review. Never `-D` its branch.
   - Open + agent returned a blocker → `blocked`; save its message as `error`. Handle via Step 4 when convenient (other pipelines keep running).
   - Open + environmental failure (credentials, irresolvable conflict) → `failed`.
   - Agent crashed or emitted no `worktree:` line → `failed`.
6. **Cycle check.** When nothing is in flight and nothing is ready but `pending` issues remain after the cascade, distinguish two cases before declaring a cycle:
   - **Waiting on a blocked chain** — a remaining `pending` issue has a `blocked` ancestor in the DAG (a transitive dependency that is currently `blocked`). It is *paused*, not deadlocked: leave it `pending` and go resolve the upstream `blocked` issue(s) via Step 4. Resolving a blocker to `done` re-opens the ready set; resolving it to `failed`/`skipped` lets the cascade (item 1) skip its dependents on the next pass. Never mark a blocked-chain waiter `skipped` as a cycle.
   - **True cycle** — *no* remaining `pending` issue has a `blocked` ancestor, yet none can ever become ready. That is a real DAG cycle: mark those issues `skipped` with `error="cycle: depends on #X"` (cite a real offending dep) and exit the loop.

### Step 3a — implementer dispatch

One `Agent` call per issue. Substitute `<N>`, `<GH_ISSUE_SKILL>`, `<MAX_CODEX_ITERATIONS>`, and `<STATE_DIR>` (the resolved absolute path — subagents don't inherit it):

```
subagent_type: general-purpose
isolation: worktree
run_in_background: true
description: "Implement issue #<N>"
prompt: |
  Implement GitHub issue #<N> end-to-end by following the procedure in
  <GH_ISSUE_SKILL> (read that file first; the path is already absolute).

  Inputs (read before starting):
  - <STATE_DIR>/issue-<N>/details.json — the issue
  - <STATE_DIR>/issue-<N>/guidance.md — per-issue guidance, only if it exists

  You run in an isolated worktree; branch off the default branch. You can
  spawn your own subagents — Explore, Plan, general-purpose helpers and
  reviewers — per gh-issue's "Your subagents" section. Helpers inherit your
  worktree (never give them worktree isolation) and must not spawn further
  subagents.

  This is an ORCHESTRATED run — gh-issue's orchestrated-mode rules apply:
  - Plan confirmation is pre-approved. Stop only for genuine spec ambiguity
    (missing/contradictory requirements) — return a blocker, don't guess.
  - Codex gate cap: MAX_CODEX_ITERATIONS=<MAX_CODEX_ITERATIONS>. Hitting the
    cap unconverged is a blocker, never a license to continue.
  - Merge yourself ONLY on a converged review loop (defined in gh-issue
    Step 8). If bouncing: push your fixes, refresh the PR body, return a
    blocker citing the findings. Never merge if uncertain.
  - Your final message must include one line: `worktree: <absolute path>`
    (from `git rev-parse --show-toplevel`) — even when returning a blocker.

  Never invoke gh-issue, /review, /security-review, or /codex:review via
  the Skill tool — inline the procedures; run codex via Bash.
```

`general-purpose` is required: it is the only built-in type with the full tool surface (Bash, Edit, Agent — typed `Explore`/`Plan` agents are read-only and cannot push or merge).

Per-issue guidance (retry context, scope limits, "do not edit X" lists) always goes in `$STATE_DIR/issue-N/guidance.md` and is referenced by path — never pasted into the prompt body.

### Step 4 — handle blocked / failed issues

Read the agent's error message. **Try to resolve it yourself first** — you hold run-wide context the implementer lacks: the DAG, the other issues' status, freshly merged PRs, the whole repo. If the blocker is coordination or context (e.g. "dependency #X just merged — read its changes from the default branch", a question answerable from another issue's body or the code), write the answer to `$STATE_DIR/issue-N/guidance.md` and retry the implementer without involving the user.

**Escalate to the user only** for decisions that change scope, product behavior, or accept risk: merging despite open findings, dropping or skipping an issue, picking between contradictory requirements, spending more budget. When escalating, present the blocker, the latest findings, and your recommendation. Escalations, cheapest first:

- **Retry the implementer.** Write the user's guidance plus any finding text to `$STATE_DIR/issue-N/guidance.md` (append a `## Retry N` section). Re-dispatch per Step 3a, additionally passing: the existing worktree path (continue on the same branch — no new worktree isolation) and the existing PR number (push to the same PR). The retried implementer runs its own review/codex passes and spawns its own helpers — the parent never enters the worktree.
- **Hand off to `/codex:rescue`** for a fresh investigation; pass the worktree path and the latest review log.
- **Mark `failed`** and let the cascade skip dependents.
- **Bump the Codex cap and re-run** — only for a converged-but-unverified cap-stop: `/issue-runner <N> --max-codex-iterations M`. Fresh orchestration: close the existing PR first (see Arguments).

### Step 5 — cleanup and summary

Resolve the default branch first; deletions below must never target it:

```bash
DEFAULT_BRANCH=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@')
[ -n "$DEFAULT_BRANCH" ] || DEFAULT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
```

For each `done` issue (worktree path comes from the agent's `worktree:` line):

```bash
WT_BRANCH=$(git -C "$WT" rev-parse --abbrev-ref HEAD 2>/dev/null)
git worktree unlock "$WT" 2>/dev/null || true        # Agent tool locks its worktrees
git worktree remove -f "$WT" || git worktree remove -f -f "$WT"
# -D, not -d: squash merges break -d's ancestry check; done = positive proof of merge
if [ -n "$WT_BRANCH" ] && [ "$WT_BRANCH" != HEAD ] && [ "$WT_BRANCH" != "$DEFAULT_BRANCH" ]; then
  git branch -D "$WT_BRANCH" 2>/dev/null || true
fi
```

For `failed`/`skipped`/`closed-externally` issues, leave worktree and branch in place for forensics (a `closed-externally` branch may hold unmerged work the external close discarded); record the path in `$STATE_DIR/issue-N/worktree`. Then `git worktree prune`, and sweep the Agent tool's leftover scratch branches with the safe flag:

```bash
git for-each-ref --format='%(refname:short)' refs/heads/ | grep -E '^worktree-agent-' \
  | while read -r b; do git branch -d "$b" 2>/dev/null || true; done
```

**Verify the main repo is clean**: rerun `git status --porcelain=v1 -uall`, diff against the Step 1 snapshot, and surface anything new — never auto-discard.

**Summary table**: number, status, title, error. Group `blocked` (paused on user input) and `closed-externally` (closed out-of-band, branch kept for review) separately from `failed` (terminal). Treat any `failed` **or `closed-externally`** as a non-zero outcome in your closing message — a `closed-externally` issue needs a human to confirm whether its work was really merged.

## Hard rules

- **No Python orchestrator.** The runtime is you plus subagents.
- **State goes through files.** Reference paths in prompts; don't paste file contents.
- **Never `Skill()` for `gh-issue`, `/review`, or `/codex:review`.** `gh-issue` is `disable-model-invocation: true` (refused); the review skills are terminal-output producers (they take over the turn and the steps after them never run). Inline the procedures; run codex via Bash.
- **Single-issue scope → inline fast path.** No orchestrator state, no DAG, no Step 5. The run still isolates in a worktree, but gh-issue's interactive mode owns it (creates it in Step 4, removes it in Step 9).
- **The orchestrator never hand-manages worktrees.** In an orchestrated run, isolation comes only from dispatching implementers with the Agent tool; the parent touches worktrees solely in Step 5 cleanup. (The single-issue fast path is not orchestrated — gh-issue creates and removes its own worktree directly.)
- **The orchestrator never enters a worktree.** In an orchestrated run all in-worktree work (fixes, re-reviews, merges) belongs to implementer subagents, so the parent's cwd and `git status` stay trustworthy and Step 5 cleanup is safe.
- **Single-host, single-user state.** State is namespaced per repo (`/tmp/issue-runner/<repo-key>/state`), so runs in different repos are isolated. Two concurrent runs *in the same repo* still collide — don't run two at once in one repo.
