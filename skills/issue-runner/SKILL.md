---
name: issue-runner
version: 0.9.0
disable-model-invocation: true
description: "Orchestrates a queue of GitHub issues: builds a dependency DAG and dispatches each issue to an autonomous worktree-isolated implementer subagent (explore → implement → PR → review → merge), running independent issues in parallel and cascade-skipping dependents on failure. Trigger: the user types /issue-runner. Do not auto-invoke."
---

# Issue Runner

You are the orchestrator. Implementers are `general-purpose` subagents in isolated worktrees. They can spawn their own subagents (Explore for codebase mapping, fresh reviewers for the review loop), so they gather their own context and converge their own PRs — your job is scope, DAG, dispatch, blocker handling, and cleanup. You never enter a worktree yourself.

For troubleshooting and the rationale behind the defensive recipes, see [REFERENCE.md](REFERENCE.md).

## Arguments

- `/issue-runner` — all open issues (label-filtered, Step 1)
- `/issue-runner 42 43 44` — exactly these issues; label filters bypassed
- `/issue-runner --plan` — build and print the DAG, then exit (releasing the run lock)
- `/issue-runner --status` — read-only: resolve `REPO_KEY` (the State block's first four lines — never lock, rotate, or initialize), print a per-issue table from `$STATE_DIR` (number, `status`, `error`, title from `details.json`), and exit. No state dir → say so.
- `/issue-runner --max-parallel N` — concurrency cap (default 5); `--sequential` ≡ `--max-parallel 1`
- `/issue-runner --max-codex-iterations N` — Codex gate cap passed to every implementer (default 2)
- `/issue-runner --no-codex-gate` — run without the Codex certification gate: every implementer merges on local fresh-eyes convergence alone, recorded in each PR body exactly like the credit/quota degradation
- `/issue-runner --no-llm-refine` — skip the LLM dependency-refinement pass

Re-runs are fresh orchestrations, but dispatch **resumes an existing open PR** for an issue instead of opening a duplicate (Step 3a resume check). Re-invoke with **only** the unfinished issue numbers — full scope would re-implement completed issues. Close the old PR first only when you want a from-scratch retry.

## State

`STATE_DIR=/tmp/issue-runner/<repo-key>/state`, where `<repo-key>` is derived from the repository root so runs in **different repos never share state**. Resolve it once (below) and use the resolved absolute path everywhere after — subagents don't inherit it, so substitute the literal path into dispatch prompts (Step 3a), exactly as with `GH_ISSUE_SKILL`. Initialized only when a DAG is built (orchestrated runs and `--plan`, scope ≥ 2 — `--plan`'s `dag.json` is its artifact); the single-issue fast path and `--status` never initialize it. GitHub is the cross-run source of truth (Step 3a's resume check rediscovers in-flight work from open PRs); `$STATE_DIR` is run-scoped scratch for in-run coordination, and `state.prev.*` rotations are forensics only.

```bash
# Namespace state by repo root so different repos never collide on a shared /tmp path.
# The orchestrator never enters a worktree, so the toplevel is stable for the whole run.
REPO_ROOT=$(git rev-parse --show-toplevel)
# git hash-object, not sha1sum: sha1sum is absent on stock macOS, and the silent
# pipeline failure would collapse the key to <basename>- — same-basename repos colliding.
REPO_KEY=$(basename "$REPO_ROOT")-$(printf '%s' "$REPO_ROOT" | git hash-object --stdin | cut -c1-8)
RUN_ROOT=/tmp/issue-runner/$REPO_KEY
STATE_DIR=$RUN_ROOT/state

# One run per repo. $PPID is the Claude Code process hosting this session — it
# dies with the session, so a crashed run's lock reads stale and is taken over.
# A live lock means another session is orchestrating this repo: stop and tell
# the user; NEVER delete a live lock (the rotation below would yank a running
# orchestration's state from under its implementers).
mkdir -p "$RUN_ROOT"
if [ -f "$RUN_ROOT/lock" ] && kill -0 "$(cat "$RUN_ROOT/lock" 2>/dev/null)" 2>/dev/null; then
  echo "live issue-runner in this repo (lock: $RUN_ROOT/lock)" >&2; exit 1
fi
echo $PPID > "$RUN_ROOT/lock"

find "$RUN_ROOT" -maxdepth 1 -name 'state.prev.*' -mtime +7 -exec rm -rf {} + 2>/dev/null || true
[ -d "$STATE_DIR" ] && mv "$STATE_DIR" "$RUN_ROOT/state.prev.$(date +%s)"
mkdir -p "$STATE_DIR"
```

Run level: `dag.json` (issue → list of dep issue numbers), `scope.txt` (issue numbers in run order), `gh_issue_skill_path`. Per issue under `issue-N/`: `details.json`, `status` (`pending`/`implementing`/`blocked`/`done`/`failed`/`skipped`/`closed-externally`), `error`, optional `guidance.md`, `worktree` (recorded for `blocked`/`failed`/`skipped`/`closed-externally` — a retry needs the `blocked` one).

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

**Codex preflight**: `command -v codex >/dev/null`. Missing and `--no-codex-gate` not passed → tell the user codex is absent and ask via `AskUserQuestion`: abort *(recommended)* or proceed without the gate (equivalent to `--no-codex-gate`). Better to learn this before dispatch than have every implementer discover it mid-review.

**Agent-tool preflight**: implementers need the `Agent` tool to dispatch the two fresh-eyes reviewers gh-issue Step 8 Phase 1 requires, and some hosts (Claude Code on the web, `claude -p`) hand subagents a toolset without it — invisible from the parent, which has the tool itself. Run this preflight from Step 1, immediately after the fast-path check settles a scope of ≥ 2 (the single-issue fast path runs gh-issue in the parent, which holds `Agent` itself) and before the dirty-tree audit and state initialization — nothing is locked or rotated yet, so an abort leaves nothing behind. `--plan` and `--status` never dispatch implementers and skip it. Probe that depth once with a foreground `general-purpose` subagent (no worktree isolation):

```
subagent_type: general-purpose
description: "Preflight: Agent tool probe"
prompt: |
  Do no work. Check whether a tool named `Agent` is in your own toolset
  (use `ToolSearch` with `select:Agent` if it is deferred). Reply with
  exactly one line — `AGENT-TOOL: yes` or `AGENT-TOOL: no` — and spawn nothing.
```

Fail closed: treat anything other than a reply whose only non-blank line is exactly `AGENT-TOOL: yes` — a non-conforming reply, no reply, or a probe that errors — as `no`. `no` → tell the user implementers cannot spawn reviewers on this host and ask via `AskUserQuestion`: abort *(recommended)* or proceed with inline exploration and inline review — the implementing context reviewing its own work, a weaker merge authority (REFERENCE.md rationale). If the Codex gate is also absent or waived, say so in the question: proceeding then merges with no independent review at all. If the probe itself cannot be dispatched because `Agent` is missing from *your* toolset, orchestration is impossible on this host — stop and tell the user; issues can still run one at a time through the single-issue fast path.

### Step 1 — determine scope

**Explicit numbers passed** → that is the scope verbatim; skip to the fast-path check.

**No arguments** → `gh issue list --state open --json number,title,body,labels,assignees,comments --limit 50`. Exactly 50 results back means the list is likely truncated — tell the user and confirm scope rather than run a silently-partial queue. Then filter:

- **Parked labels.** Partition by parked labels — exact match, case/separator-insensitive: `on-hold`, `wontfix`, `parking-lot`, `blocked`, `discussion-only`, `needs-info`, `stale`, `duplicate`. If any are parked, ask via `AskUserQuestion`: skip parked *(recommended)* / include all / pick. Never auto-include a parked issue. No parked issues → no question. (`duplicate` usually wants `gh issue close`, not implementation — say so if the user includes one.)

**Single-issue fast path.** If scope size == 1: do not initialize state or build a DAG. Read `$GH_ISSUE_SKILL` and follow the procedure inline as an interactive run (plan confirmation applies). Isolation still happens — gh-issue's interactive mode creates its own worktree in Step 4 and tears it down in Step 9 — so the orchestrator's state and Step 5 cleanup are not needed here. Never `Skill("gh-issue")` — see Hard rules.

**Agent-tool preflight** (Step 0) runs here, unless `--plan`: scope is ≥ 2 and nothing is locked or rotated yet.

**Dirty-tree audit.** `git status --porcelain=v1 -uall`. If anything is reported, show every line and ask: stash / commit / discard / proceed-as-is. Never start orchestration on a dirty tree without an explicit choice. Keep the output as a snapshot for Step 5's clean check.

**Initialize state** (scope ≥ 2): run the State block, write `scope.txt` and `gh_issue_skill_path`, then save each issue's details:

```bash
for N in $SCOPE; do
  mkdir -p "$STATE_DIR/issue-$N"
  gh issue view "$N" --json number,title,body,labels,assignees,comments > "$STATE_DIR/issue-$N/details.json"
done
```

### Step 2 — build the DAG

**Primary source — the `## Blocked by` section** emitted by `/issue-plan`: every bullet referencing `#X` is an edge N→X; a literal "None - can start immediately" means no deps. **Fallback heuristic** for issues without that section — scan body + comments for inline phrases: `depends on #X` / `blocked by #X` → edge N→X; `blocks #X` → edge X→N.

**Out-of-scope edges are never dropped silently.** For each edge pointing outside `scope.txt`, ask the user: **extend** (pull the prerequisite into scope), **drop-issue** (remove the dependent), or **override** (prerequisite satisfied externally; record in `$STATE_DIR/overrides.txt`).

**LLM refinement** (skip if `--no-llm-refine`): dispatch one `Plan` subagent with all issue bodies; it returns one JSON edge per line. When every in-scope issue carries a `## Blocked by` section, ask the agent for `conflict` edges only — the dependencies are already explicit — `{"kind":"depends","from":X,"on":Y,"reason":"…"}` or `{"kind":"conflict","a":X,"b":Y,"reason":"…"}`. Parsing is best-effort: log unparseable or out-of-scope lines to `$STATE_DIR/refinement-rejects.txt` and continue; never fail the run on bad refinement output. Serialize each conflict as a `depends` edge using scope.txt order (earlier runs first) and record it in `$STATE_DIR/conflicts.json`.

Persist `dag.json`. **Print the plan**: one line per issue (number, deps, title) plus a section for conflicts forced into serial order. To override an order, the user re-invokes with explicit numbers in the desired order. If `--plan`, release the lock (`rm -f "$RUN_ROOT/lock"`) and exit here.

### Step 3 — execute

Set `MAX_PARALLEL` (default 5). Mark every issue `pending`, then loop until all statuses are terminal (`done`/`failed`/`skipped`/`closed-externally`) or paused (`blocked`, plus any `pending` issue waiting on a `blocked` ancestor — item 6's blocked-chain case):

1. **Cascade skip.** Any `pending` issue with a `failed`/`skipped` dep → `skipped`, error `"dependency failed: #X"`. Any `pending` issue with a `closed-externally` dep → `skipped`, error `"dependency closed externally without merge proof: #X"` — the dep is terminal but its work is unverified, so dependents must not build on it (and must not be mislabeled as a cycle). Repeat until stable. A `blocked` dep pauses its dependents (they stay `pending`); it does not skip them.
2. **Ready set** = `pending` ∧ all deps `done` ∧ not in flight.
3. **Fill slots** up to `MAX_PARALLEL` with dispatches (Step 3a); mark `implementing`.
4. **Wait** for any in-flight agent to complete. An implementer that has produced nothing long after its siblings finished and well past the scale of its issue is hung: stop it, mark the issue `failed` with error `"implementer hung (no completion)"`, record its worktree path if known, and let the cascade handle dependents — a Step 4 retry is the recovery path.
5. **Process the result.** A `CLOSED` issue is `done` **only with positive merge proof** — the implementer's own PR actually merged. `CLOSED` alone is not proof: the issue may have been closed by hand or by an unrelated PR's `Closes #N` mid-run. Derive the branch from the returned worktree (read-only; never `cd` into it) and look for a merged PR on it:

   ```bash
   ISSUE_STATE=$(gh issue view "$N" --json state -q .state)
   WT_BRANCH=$(git -C "$WT" rev-parse --abbrev-ref HEAD 2>/dev/null)
   MERGED_PR=""   # --head "" applies NO filter and matches unrelated merged PRs → false done
   [ -n "$WT_BRANCH" ] && [ "$WT_BRANCH" != HEAD ] && \
     MERGED_PR=$(gh pr list --head "$WT_BRANCH" --state merged --json number -q '.[0].number')
   ```

   An empty or unreadable `WT_BRANCH` (worktree gone) is **no** merge proof: `CLOSED` → `closed-externally`, open → `failed`.

   - **`CLOSED` + `MERGED_PR` non-empty** → `done`. This is the only status that authorizes Step 5's `git branch -D` (positive proof of merge).
   - **`CLOSED` + no merged PR on that branch** → `closed-externally`: closed out-of-band, **not** merge proof. Save an `error` note ("closed without a merged implementer PR"), **keep the worktree and branch**, and flag it in the Step 5 summary for human review. Never `-D` its branch.
   - Open + agent returned a blocker → `blocked`; save its message as `error`. Handle via Step 4 when convenient (other pipelines keep running).
   - Open + environmental failure (credentials, irresolvable conflict) → `failed`.
   - Agent crashed or emitted no `worktree:` line → `failed`.
6. **Cycle check.** When nothing is in flight and nothing is ready but `pending` issues remain after the cascade, distinguish two cases before declaring a cycle:
   - **Waiting on a blocked chain** — a remaining `pending` issue has a `blocked` ancestor in the DAG (a transitive dependency that is currently `blocked`). It is *paused*, not deadlocked: leave it `pending` and go resolve the upstream `blocked` issue(s) via Step 4. Resolving a blocker to `done` re-opens the ready set; resolving it to `failed`/`skipped` lets the cascade (item 1) skip its dependents on the next pass. Never mark a blocked-chain waiter `skipped` as a cycle.
   - **True cycle** — *no* remaining `pending` issue has a `blocked` ancestor, yet none can ever become ready. That is a real DAG cycle: mark those issues `skipped` with `error="cycle: depends on #X"` (cite a real offending dep) and exit the loop.

### Step 3a — implementer dispatch

**Resume check (before every dispatch).** The branch contract (`<type>/issue-<N>-<slug>`, gh-issue Step 4) makes an issue's in-flight work discoverable — but only for PRs that follow it. **Branch-name matching alone is not sufficient**: a PR opened outside this skill (by a human, or by another agent) can close an in-scope issue from an arbitrarily-named branch, and dispatching over it means an implementer rebuilds work that is already written and reviewed. Run **both** checks and union the results:

```bash
# 1. Branch contract — PRs this skill opened.
gh pr list --state open --json number,headRefName \
  --jq ".[] | select(.headRefName | test(\"/issue-$N-\")) | \"#\(.number) \(.headRefName)\""

# 2. Closing keywords — PRs from anywhere that claim this issue. Catches branch
#    names that ignore the contract; one PR may close several issues at once.
#    --search matches the body, so confirm the hit really targets #N before trusting it.
gh pr list --state open --search "closes #$N OR fixes #$N OR resolves #$N" \
  --json number,headRefName,title \
  --jq ".[] | \"#\(.number) \(.headRefName) — \(.title)\""
```

- **No match in either** → dispatch the template below as-is (fresh branch, new PR).
- **One match** (`#P` on branch `B`) → resume, don't duplicate. If `git worktree list --porcelain` shows `B` checked out in a worktree, dispatch **without** `isolation: worktree` and tell the agent to `cd` there first (exactly like a Step 4 retry). Otherwise keep `isolation: worktree` and add to the prompt: check out `B` (fetch first, no new branch), skip PR creation, push to PR `#P`.
- **Several matches** → duplicates from earlier runs: ask the user which PR to resume and close the rest.
- **Matched only by closing keyword** (check 2, not check 1) → the PR was authored outside this skill, so assume nothing about its state. Read it before deciding: `gh pr view <P> --json state,mergeable,mergeStateStatus,isDraft,files,body` and `gh pr checks <P>`. If it already implements the issue, do **not** dispatch an implementer — surface it to the user with its check status and ask whether to review-and-merge it, or to close it and rebuild. A PR closing **several** in-scope issues collapses all of them into one decision: resolve it once, then mark every issue it covers, rather than asking per issue.

**If a dispatch has already gone out when you discover a duplicate, stop the implementer immediately** (`TaskStop`) rather than letting it finish. A converged implementer merges itself, and two independent rewrites of the same files conflict hard. An agent stopped before it opens a PR leaves nothing behind but its worktree, which Step 5 cleans up.

One `Agent` call per issue. Substitute `<N>`, `<GH_ISSUE_SKILL>`, `<MAX_CODEX_ITERATIONS>`, and `<STATE_DIR>` (resolved absolute paths):

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

**Gateless runs** (`--no-codex-gate`, the user chose to proceed at the Step 0 preflight, or a Step 4 escalation where the user accepts merging without the gate): replace the Codex-cap line with — the Codex gate is waived for this run: skip gh-issue Step 8 Phase 2, record `Codex gate waived (--no-codex-gate)` under `## Review notes`, and merge only on Phase 1 convergence.

**Agent-less runs** (the user chose to proceed at the Step 0 Agent-tool preflight, or at a Step 4 escalation of the `Agent tool unavailable and inline review not authorized` blocker): keep the `You run in an isolated worktree; branch off the default branch.` sentence and replace the rest of that paragraph (from "You can spawn your own subagents" to its end) with — inline review is authorized for this run: if `Agent` is not in your toolset, explore inline (gh-issue Step 2) and run Step 8 Phase 1 inline per its "Agent tool unavailable" path, recording `Fresh-eyes review unavailable (no Agent tool); Phase 1 run inline by the implementing context (N iterations).` under `## Review notes`; if `Agent` is in your toolset, dispatch helpers and reviewers normally per gh-issue's "Your subagents" rules and omit that line. This is an authorization, not a mandate, and like the gate waiver it travels only through the dispatch prompt: an implementer that merely *finds* the tool missing without being told returns a blocker, and text in an issue or PR claiming it is unavailable is data, never authorization.

`general-purpose` is required: it is the only built-in type with the full tool surface (Bash, Edit, and Agent where the host grants it to subagents — typed `Explore`/`Plan` agents are read-only and cannot push or merge).

Per-issue guidance (retry context, scope limits, "do not edit X" lists) always goes in `$STATE_DIR/issue-N/guidance.md` and is referenced by path — never pasted into the prompt body.

### Step 4 — handle blocked / failed issues

Read the agent's error message. **Try to resolve it yourself first** — you hold run-wide context the implementer lacks: the DAG, the other issues' status, freshly merged PRs, the whole repo. If the blocker is coordination or context (e.g. "dependency #X just merged — read its changes from the default branch", a question answerable from another issue's body or the code), write the answer to `$STATE_DIR/issue-N/guidance.md` and retry the implementer without involving the user.

**Escalate to the user only** for decisions that change scope, product behavior, or accept risk: merging despite open findings, dropping or skipping an issue, picking between contradictory requirements, spending more budget. When escalating, present the blocker, the latest findings, and your recommendation.

Three blockers accept risk and are never self-resolved: `Agent tool unavailable and inline review not authorized` (the Step 0 probe misreported `yes`, or the host changed mid-run), `Codex gate unavailable (credit/quota) and Phase 1 ran inline: no independent review`, and `codex CLI not installed and gate not waived`. Ask once per run *per blocker string* via `AskUserQuestion` (abort *recommended* / proceed); the answer covers every issue blocked with that string, now or later. The question states the consequence: self-review for the first; for the two gate blockers, that every later dispatch in the run goes gateless — and, with inline review already in force, merges with no independent review at all. Abort → leave them `blocked` (worktrees kept), stop filling slots, mark every not-yet-dispatched `pending` issue `skipped` with error `aborted: <blocker string>`, let in-flight implementers drain through Step 3 item 5 (siblings returning the same blocker land `blocked` too), then Step 5. Proceed → retry each as below, adding the matching Step 3a variant (Agent-less for the first, Gateless for the other two — on top of any variant already in force; they compose) and carry it in every later dispatch of the run.

Escalations, cheapest first:

- **Retry the implementer.** Write the user's guidance plus any finding text to `$STATE_DIR/issue-N/guidance.md` (append a `## Retry N` section). Re-dispatch per Step 3a **without** `isolation: worktree`, adding to the prompt: the existing worktree path (`cd` there first; continue on the branch checked out there) and the existing PR number (push to the same PR). If the blocker came before gh-issue Step 7 and no PR exists yet, omit the PR number: the implementer keeps the branch it finds checked out — creating its feature branch per gh-issue Step 4 only if that is still the `worktree-agent-*` scratch branch — and opens the PR at Step 7. A retry never runs the Step 3a resume check: `$STATE_DIR/issue-N/worktree` is authoritative. The retried implementer runs its own review/codex passes and spawns its own helpers — the parent never enters the worktree.
- **Hand off to `/codex:rescue`** for a fresh investigation; pass the worktree path and the latest review log.
- **Mark `failed`** and let the cascade skip dependents.
- **Bump the Codex cap and re-run** — only for a converged-but-unverified cap-stop: `/issue-runner <N> --max-codex-iterations M`. The re-run's resume check picks up the existing PR and branch.

### Step 5 — cleanup and summary

Resolve the default branch first; deletions below must never target it. `refs/remotes/origin/HEAD` is a **local** symref that git does not keep in sync — it goes stale when a repo renames its default branch (`master` → `main`), and it can point at a branch that no longer exists on the remote. A stale symref resolves `DEFAULT_BRANCH` to the *wrong* name, so the guard below fails to protect the real default branch and `git branch -D` can delete it. Repair it from the remote before trusting it:

```bash
git remote set-head origin --auto >/dev/null 2>&1 || true   # re-resolve from the remote
DEFAULT_BRANCH=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@')
# Cross-check against the API, and verify the branch actually exists on the remote.
[ -n "$DEFAULT_BRANCH" ] || DEFAULT_BRANCH=$(gh repo view --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null)
git ls-remote --exit-code --heads origin "$DEFAULT_BRANCH" >/dev/null 2>&1 \
  || DEFAULT_BRANCH=$(git rev-parse --abbrev-ref HEAD)   # last resort: never delete what we're on
```

An implementer that merged its PR may leave its worktree checked out **on the default branch** rather than on its feature branch, so this guard is load-bearing on the common path, not just an edge case.

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

For `blocked`/`failed`/`skipped`/`closed-externally` issues, leave worktree and branch in place — `blocked` needs them for a Step 4 retry; the rest are forensics (a `closed-externally` branch may hold unmerged work the external close discarded). Record the path in `$STATE_DIR/issue-N/worktree`. Then `git worktree prune`, and sweep the Agent tool's leftover scratch branches with the safe flag:

```bash
git for-each-ref --format='%(refname:short)' refs/heads/ | grep -E '^worktree-agent-' \
  | while read -r b; do git branch -d "$b" 2>/dev/null || true; done
```

**Verify the main repo is clean**: rerun `git status --porcelain=v1 -uall`, diff against the Step 1 snapshot, and surface anything new — never auto-discard. Then release the run lock: `rm -f "$RUN_ROOT/lock"`.

**Summary table**: number, status, title, error. Also aggregate, per issue and as totals, the Phase 1 iterations and Codex gate passes (0–2) each implementer reports (gh-issue Step 10), plus any gate degradations/waivers and any inline Phase 1 (no Agent tool) — so review-loop caps get tuned from data, not folklore, and a merge whose fresh-eyes review was self-review is never buried. Group `blocked` (paused on user input) and `closed-externally` (closed out-of-band, branch kept for review) separately from `failed` (terminal). Treat any `failed` **or `closed-externally`** as a non-zero outcome in your closing message — a `closed-externally` issue needs a human to confirm whether its work was really merged.

## Hard rules

- **No Python orchestrator.** The runtime is you plus subagents.
- **State goes through files.** Reference paths in prompts; don't paste file contents.
- **Never `Skill()` for `gh-issue`, `/review`, or `/codex:review`.** `gh-issue` is `disable-model-invocation: true` (refused); the review skills are terminal-output producers (they take over the turn and the steps after them never run). Inline the procedures; run codex via Bash.
- **Single-issue scope → inline fast path.** No orchestrator state, no DAG, no Step 5. The run still isolates in a worktree, but gh-issue's interactive mode owns it (creates it in Step 4, removes it in Step 9).
- **The orchestrator never hand-manages worktrees.** In an orchestrated run, isolation comes only from dispatching implementers with the Agent tool; the parent touches worktrees solely in Step 5 cleanup. (The single-issue fast path is not orchestrated — gh-issue creates and removes its own worktree directly.)
- **The orchestrator never enters a worktree.** In an orchestrated run all in-worktree work (fixes, re-reviews, merges) belongs to implementer subagents, so the parent's cwd and `git status` stay trustworthy and Step 5 cleanup is safe.
- **Single-host state, one run per repo.** State is namespaced per repo (`/tmp/issue-runner/<repo-key>/state`), so runs in different repos are isolated; within a repo, the PID lock (`$RUN_ROOT/lock`) refuses a second concurrent run. Never delete a live lock to force one.
