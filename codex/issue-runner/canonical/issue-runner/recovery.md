# Recovery

Read when the orchestrator's host process died mid-run (to resume it), before telling the user how to re-run, and at Step 3 whenever `run-state.sh init` printed `state kept: same session re-entering its unfinished run` (the recovery reconciliation). SKILL.md's Recovery section and Step 3 link here.

## Resuming the orchestrator's session

If the orchestrator's host process dies mid-run, a new session finds only what reached a branch or PR. To recover implementers' uncommitted work, resume the **same session**, on the same machine:

```bash
claude --resume "$(cat "$RUN_ROOT/session")"
```

Launch it from the repo root with **the same permission mode and allowed tools as the original run** (why: Why a resumed run needs the original permissions), then re-invoke `/issue-runner` with the unfinished issue numbers: the state is kept and Step 3's recovery reconciliation runs (why: What the recovery reconciliation is based on, and what it is not).

- Transcripts are swept after `cleanupPeriodDays` (default **30 days**); past it there is nothing to resume.
- `--no-session-persistence` silently forfeits this path: never launch an unattended orchestrated run with it.

No `$RUN_ROOT/session`, an expired transcript, or a failed resume → plain `/issue-runner` re-invocation: Step 3's recovery reconciliation tries `agent-trace.sh` as a lossy last resort, and Step 3a's resume check rediscovers pushed work — never a duplicate PR (why: Why the trace digest is strictly worse than resuming in place, never a substitute for it).

## Step 3 — recovery reconciliation

Same-session re-entry only — `run-state.sh init` printed `state kept: same session re-entering its unfinished run`. Once, before marking anything `pending` (after the `--merge-ready` pass when that mode runs), for every `implementing` issue with an `issue-N/agent` file; other statuses are untouched (why: What the recovery reconciliation is based on, and what it is not).

- **Check first**: read task notifications since resuming and `ListAgents`. Recorded agent running → leave it `implementing`. **Never re-dispatch an agent that is running.**
- **Otherwise `SendMessage` it**: the host process died; `cd` to your worktree; re-check `git status` and your PR; treat awaited helper subagents as gone and re-dispatch them; continue from your `progress` step; end with the `worktree:` line. If its `progress` reads `step=8.2 pass=K`, include whether `$STATE_DIR/issue-N/codex-pass-K.exit` and `codex-pass-K.attempt` exist and whether `codex-pass-K.head` equals `git -C <worktree> rev-parse HEAD`; it applies gh-issue Step 8, "Liveness". Leave it `implementing`.
- **Either way, touch (or rewrite the line of) `issue-N/progress` at once** — before the next issue, never waiting for a reply. It grants a `--hang-minutes` grace window, not a confirmation; item 4's hang rule catches an agent that never resumes (why: Why the hang rule reads the file's mtime but not its content).
- **Fall through when it cannot be resumed** (id unknown to `ListAgents` and `SendMessage`, `SendMessage` errors, or its transcript aged past `cleanupPeriodDays`). First try `AGENT_TRACE="$(dirname "<SCHEDULER_SCRIPT>")/agent-trace.sh"`, the absolute path substituted literally — never run an empty or relative value. Absent → report a broken install and skip the trace fallback. Present → `bash "$AGENT_TRACE" "$CLAUDE_CODE_SESSION_ID" "$N"` from the orchestrator's cwd, never the plugin root; success appends `## Recovered trace` to `guidance.md`, failure changes nothing. A fallback, never a substitute for resuming (why: Why the trace digest is strictly worse than resuming in place, never a substitute for it). Then mark it `pending`; Step 3a's resume check rediscovers its branch or PR.

Then return to Step 3: mark every issue not handled above `pending` and start the loop.

## Re-running

Re-runs are fresh orchestrations (bar a same-session re-entry), but dispatch **resumes an existing open PR** rather than opening a duplicate (Step 3a). Re-invoke with **only** the unfinished issue numbers. For a from-scratch retry, first `gh pr close <P> --delete-branch` (a surviving remote branch stops the fresh run at Step 3a's probe 3 or gh-issue's checkpoint guard).
