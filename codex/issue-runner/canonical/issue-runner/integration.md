# Integration calls

Read at Step 0 of every run but `--plan` and `--status`, and when `--flush` is passed (SKILL.md, Arguments and Step 0). It lists every `integration.sh` call the run makes; `docs/integration-rfc.md` has the design.

## Step 0 — integration probe

**Integration probe** (not `--plan`/`--status`/`--flush`): `bash "<INTEGRATION_SCRIPT>" discover "<default branch>"`, `INTEGRATION_SCRIPT` being `$(dirname "<GH_ISSUE_SKILL>")/../issue-runner/scripts/integration.sh` (resolved absolute in every mode); print its line. `contract invalid`, `unresolvable` or a missing script disables integration for the run, never stops it.

## After `init` — discover and hints

**Integration.** After `init` exits 0 (not `--plan`): `bash "<INTEGRATION_SCRIPT>" discover "<default branch>" "$STATE_DIR"`, plus `--no-merge` under `--no-merge`; its line supersedes Step 0's. Then send `hint "$STATE_DIR" run-start` once Step 3 marks issues `pending`, and `hint "$STATE_DIR" merged <N>` after each `done` is written (item 5, Step 4's **Mark `done`**; the `--merge-ready` pass adds `--pr <P> --untried "<`ready` issues not yet tried>"`). Hints return at once; their outcome is never a blocker.

## Step 5 — run complete

**Integration first**: `bash "<INTEGRATION_SCRIPT>" run-complete "$STATE_DIR" <reason>` (tool timeout ≥ 150 s) (`paused` while `$RUN_ROOT/paused` exists, `stopped` after a Step 4 abort, else `completed`); print its lines atop the summary (a missing script: say integration was disabled).

## `--flush`

`/issue-runner --flush` — ask the project's CI to validate the default branch's tip now: read-only like `--status` (its State block), then `bash "<INTEGRATION_SCRIPT>" flush "<RUN_ROOT>" "<default branch>" <LOCK_TTL_MINUTES>` (branch resolved as Step 5 does); print its output, exit with its status.
