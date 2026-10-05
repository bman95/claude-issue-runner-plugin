# `--merge-ready` mode

Read when `--merge-ready` is passed. SKILL.md links here from Arguments; Step 1 and Step 3 name the two places it applies. Rationale: [REFERENCE.md](REFERENCE.md).

## Step 1 — `--merge-ready` scope

Refuse explicit issue numbers (`--merge-ready takes no issue numbers`) and `--prose-gate` (`--prose-gate has no effect with --merge-ready`); this mode writes no `profile` files. Skip the rest of Step 1 and all of Step 2: reuse the kept run's `scope.txt`, `dag.json`, `dag.txt` and `gh_issue_skill_path` verbatim, never rebuilt. Step 0's preflights and the dirty-tree audit still run. Append `--merge-ready` to the State block's `init`: state is kept as a same-session re-entry whatever the session id. Then `[ -s "$STATE_DIR/scope.txt" ]` must hold; otherwise print `nothing to merge-ready: no prior run's state found for this repo`, release the lock (as `--plan` does, Step 2) and exit. Run the merge pass (below, from Step 3's preamble), then the rest of Step 3: its recovery reconciliation, then its ordinary loop. (why: Why `--merge-ready` continues the kept run)

## Step 3 — the `--merge-ready` pass

Only when `--merge-ready` was passed; runs once, after Step 3 resolves its scripts and before its loop starts. For each `scope.txt` issue whose `status` is `ready`, in `dag.json`'s topological order (never recomputed), `P` from `issue-N/pr` (why: Why `--merge-ready` refreshes before it merges (issue #15)). "Leave it" below means: leave the issue `ready`, untouched, and note the reason in the Step 5 summary.

- **Confirm the precondition, never assume it**: every `dag.txt` dependency reads `done`, else leave it `ready` silently (a later pass retries).
- **Check the PR's own state first**, `bash "$MERGE_READY_SCRIPT" state "$P"`: **`merged`** → write `done` (then `hint … merged <N> --pr <P>`, State), no re-merge; **`closed`** → write `failed`, error `"PR #P was closed without merging (declined)"` (item 1 cascades); **`open`** → refresh; **exit 1** → leave it (query failed) — never read an unreadable state as open.
- **Refresh against the base before checks** (issue #15): dispatch a `general-purpose` subagent, without `isolation: worktree`, to run one command and report its stdout line (tell it never to bypass or disable a repository's hooks: a hook failure is reported, not worked around):

  ```bash
  bash "<MERGE_READY_SCRIPT>" refresh "<the path in $STATE_DIR/issue-N/worktree>" <P> "<VALIDATION_CONTRACT_SCRIPT>"
  ```

  Its prompt carries, literally, the absolute `MERGE_READY_SCRIPT`, the recorded worktree path, Step 0's absolute `VALIDATION_CONTRACT_SCRIPT`, and `HANG_MINUTES`, and tells it: spawn no subagents; never resolve a conflict, push, reset, or change the PR's draft state (Step 9's `READIED` poll and failure response do not apply); run the command in the background and stop it only when its stderr has not grown for `HANG_MINUTES` minutes (a stall bound, never a cap); report a stopped call that printed nothing as interrupted, never a pass; on `stuck no validation contract and no --fallback-cmd given`, determine the project's test command from its conventions (CLAUDE.md, README, test configuration) and re-run once with `--fallback-cmd "<command>"` appended (`:` when there are no tests, said in its report). Then:
  - **`unchanged <oid>`** / **`refreshed <oid>`** → checks; the merge pins `<oid>`.
  - **`stuck <reason>`** → leave it, with its reason; never merged over. Attribution: `contract changed after ready — a human must review and merge` (or `integration contract …`) is a policy change, never landed on the run's authority on any head; `validation contract invalid` and `cannot resolve the base branch` are the base branch contract's to fix; `validation script unavailable or miscalled` is the install's. `validation command not runnable (exit 4)`: if `gh pr diff "$P" --name-only` touches what the command runs (the named script, anything it invokes, its executable bit), note a failing validation, the change's to fix; an unreadable diff → not runnable, rule-out undone, for a human.
  - **`worktree-missing <reason>`** → leave it as `worktree gone — cannot refresh against base; verify the PR by hand or recreate the worktree first`.
  - Anything else (subagent failure, exit 2) → *stuck* with that text, never a pass.
- **Re-check checks on the current head**, `bash "$MERGE_READY_SCRIPT" checks "$P"` (`--refreshed` appended after `refreshed`): **`pass`**/**`none`** → merge; **`none-after-refresh`** → merge as `none`, noted `none after base refresh (CI may not have registered yet)`; **`fail`** → **never merge a `fail`**: leave it as skipped this pass (red or still pending, not "failed CI").
- **`pass` or `none` → merge**, `bash "$MERGE_READY_SCRIPT" merge "$P" <the oid the refresh reported>`: **`merged <sha>`** (or `merged unknown`) → write `done`, then the `--pr` hint; **`skipped head moved after validation`** → leave it as `head moved after validation`; **`skipped merge did not land …`** → leave it, never silently retried.

A `done` here is item 5's ordinary `done`. After one try per eligible issue, return to Step 3: its recovery reconciliation, then its loop.
