---
name: issue-runner
version: 0.5.0
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
- `/issue-runner --max-parallel N` — concurrency cap (default 10); `--sequential` ≡ `--max-parallel 1`
- `/issue-runner --max-codex-iterations N` — Codex gate cap passed to every implementer (default 2)
- `/issue-runner --no-llm-refine` — skip the LLM dependency-refinement pass

Re-runs are fresh orchestrations, not resumes: re-invoke with **only** the failed issue numbers, and close a blocked run's leftover PR (`gh pr close`) before re-running its issue, or you get two PRs for the same issue.

## State

`STATE_DIR=/tmp/issue-runner/state` — initialized only for orchestrated runs (scope ≥ 2); the single-issue fast path and a `--plan` exit never touch it. Single-host, single-user: concurrent runs collide on this path.

```bash
find /tmp/issue-runner -maxdepth 1 -name 'state.prev.*' -mtime +7 -exec rm -rf {} + 2>/dev/null || true
[ -d /tmp/issue-runner/state ] && mv /tmp/issue-runner/state "/tmp/issue-runner/state.prev.$(date +%s)"
mkdir -p /tmp/issue-runner/state
```

Run level: `dag.json` (issue → list of dep issue numbers), `scope.txt` (issue numbers in run order), `gh_issue_skill_path`. Per issue under `issue-N/`: `details.json`, `status` (`pending`/`implementing`/`blocked`/`done`/`failed`/`skipped`), `error`, optional `guidance.md`, `worktree` (recorded for failed/skipped only).

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

- **Triage integration (optional).** If the repo's labels include `ready-for-agent` (the `/triage` state machine), ask the user one question: scope to `ready-for-agent` issues only *(recommended when triage is in use — the agent brief travels in the issue comments and becomes implementer context for free)*, or use the full open list.
- **Parked labels.** Partition by parked labels — exact match, case/separator-insensitive: `on-hold`, `wontfix`, `parking-lot`, `blocked`, `discussion-only`, `needs-info`, `stale`, `duplicate`. If any are parked, ask via `AskUserQuestion`: skip parked *(recommended)* / include all / pick. Never auto-include a parked issue. No parked issues → no question. (`duplicate` usually wants `gh issue close`, not implementation — say so if the user includes one.)

**Single-issue fast path.** If scope size == 1: do not initialize state. Read `$GH_ISSUE_SKILL` and follow the procedure inline as an interactive run (plan confirmation applies). Never `Skill("gh-issue")` — see Hard rules.

**Dirty-tree audit.** `git status --porcelain=v1 -uall`. If anything is reported, show every line and ask: stash / commit / discard / proceed-as-is. Never start orchestration on a dirty tree without an explicit choice. Keep the output as a snapshot for Step 5's clean check.

**Initialize state** (scope ≥ 2): run the State block, write `scope.txt` and `gh_issue_skill_path`, then save each issue's details:

```bash
for N in $SCOPE; do
  mkdir -p "$STATE_DIR/issue-$N"
  gh issue view "$N" --json number,title,body,labels,assignees,comments > "$STATE_DIR/issue-$N/details.json"
done
```

### Step 2 — build the DAG

Heuristic pass over each issue's body + comments: `depends on #X` / `blocked by #X` → edge N→X; `blocks #X` → edge X→N.

**Out-of-scope edges are never dropped silently.** For each edge pointing outside `scope.txt`, ask the user: **extend** (pull the prerequisite into scope), **drop-issue** (remove the dependent), or **override** (prerequisite satisfied externally; record in `$STATE_DIR/overrides.txt`).

**LLM refinement** (skip if `--no-llm-refine`): dispatch one `Plan` subagent with all issue bodies; it returns one JSON edge per line — `{"kind":"depends","from":X,"on":Y,"reason":"…"}` or `{"kind":"conflict","a":X,"b":Y,"reason":"…"}`. Parsing is best-effort: log unparseable or out-of-scope lines to `$STATE_DIR/refinement-rejects.txt` and continue; never fail the run on bad refinement output. Serialize each conflict as a `depends` edge using scope.txt order (earlier runs first) and record it in `$STATE_DIR/conflicts.json`.

Persist `dag.json`. **Print the plan**: one line per issue (number, deps, title) plus a section for conflicts forced into serial order. To override an order, the user re-invokes with explicit numbers in the desired order. If `--plan`, exit here.

### Step 3 — execute

Set `MAX_PARALLEL` (default 10). Mark every issue `pending`, then loop until all statuses are terminal (`done`/`failed`/`skipped`) or paused (`blocked`):

1. **Cascade skip.** Any `pending` issue with a `failed`/`skipped` dep → `skipped`, error `"dependency failed: #X"`. Repeat until stable. A `blocked` dep pauses its dependents (they stay `pending`); it does not skip them.
2. **Ready set** = `pending` ∧ all deps `done` ∧ not in flight.
3. **Fill slots** up to `MAX_PARALLEL` with dispatches (Step 3a); mark `implementing`.
4. **Wait** for any in-flight agent to complete.
5. **Process the result.** Check `gh issue view N --json state`:
   - `CLOSED` → `done`.
   - Open + agent returned a blocker → `blocked`; save its message as `error`. Handle via Step 4 when convenient (other pipelines keep running).
   - Open + environmental failure (credentials, irresolvable conflict) → `failed`.
   - Agent crashed or emitted no `worktree:` line → `failed`.
6. **Cycle check.** Nothing in flight, nothing ready, `pending` issues remain after the cascade → DAG cycle. Mark them `skipped` with `error="cycle: depends on #X"` (cite a real offending dep) and exit the loop.

### Step 3a — implementer dispatch

One `Agent` call per issue. Substitute `<N>`, `<GH_ISSUE_SKILL>`, `<MAX_CODEX_ITERATIONS>`:

```
subagent_type: general-purpose
isolation: worktree
run_in_background: true
description: "Implement issue #<N>"
prompt: |
  Implement GitHub issue #<N> end-to-end by following the procedure in
  <GH_ISSUE_SKILL> (read that file first; the path is already absolute).

  Inputs (read before starting):
  - /tmp/issue-runner/state/issue-<N>/details.json — the issue
  - /tmp/issue-runner/state/issue-<N>/guidance.md — per-issue guidance, only if it exists

  You run in an isolated worktree; branch off the default branch. You can
  spawn your own subagents — use them where gh-issue says to (Explore for
  codebase mapping, fresh reviewers for the review loop).

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

Read the agent's error message, then ask the user. Escalations, cheapest first:

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

For `failed`/`skipped` issues, leave worktree and branch in place for forensics; record the path in `$STATE_DIR/issue-N/worktree`. Then `git worktree prune`, and sweep the Agent tool's leftover scratch branches with the safe flag:

```bash
git for-each-ref --format='%(refname:short)' refs/heads/ | grep -E '^worktree-agent-' \
  | while read -r b; do git branch -d "$b" 2>/dev/null || true; done
```

**Verify the main repo is clean**: rerun `git status --porcelain=v1 -uall`, diff against the Step 1 snapshot, and surface anything new — never auto-discard.

**Summary table**: number, status, title, error. Group `blocked` (paused on user input) separately from `failed` (terminal). Treat any `failed` as a non-zero outcome in your closing message.

## Hard rules

- **No Python orchestrator.** The runtime is you plus subagents.
- **State goes through files.** Reference paths in prompts; don't paste file contents.
- **Never `Skill()` for `gh-issue`, `/review`, or `/codex:review`.** `gh-issue` is `disable-model-invocation: true` (refused); the review skills are terminal-output producers (they take over the turn and the steps after them never run). Inline the procedures; run codex via Bash.
- **Single-issue scope → inline fast path.** No state, no worktree, no DAG.
- **Worktree isolation only via the Agent tool.** Don't hand-manage worktrees outside Step 5 cleanup.
- **The parent never enters a worktree.** All in-worktree work (fixes, re-reviews, merges) belongs to implementer subagents. This keeps the parent's cwd and `git status` trustworthy and makes Step 5 cleanup safe.
- **Single-host, single-user state.** Concurrent `/issue-runner` runs collide on `/tmp/issue-runner/state` — don't run two at once.
