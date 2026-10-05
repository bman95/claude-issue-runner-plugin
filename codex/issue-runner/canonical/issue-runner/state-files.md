# Per-issue files, `result.json`, `progress` and the resume pointers

The full rules behind SKILL.md's State section (the decisive one, what makes `result.json` unreadable, is stated there and enforced by `summary.sh`). They say what each file may and may not decide. Rationale: [REFERENCE.md](REFERENCE.md).

## Per-issue files

Per issue, `issue-N/`: `details.json`, `error`, optional `guidance.md`; `status` (`pending`/`implementing`/`blocked`/`done`/`failed`/`skipped`/`closed-externally`/`ready`, the last only under `--no-merge`); `worktree` (Step 3 items 4–5); `progress` (gh-issue "Progress marker", e.g. `step=8.1 iter=2 pr=#123`); `retries` (Step 4 re-dispatches, absent = 0); `result.json` (gh-issue "Result file"); `notification` (item 5); `branch` (Step 3a, non-contract resumes only); `agent` (the dispatch's agent id, Step 3a); `pr` (item 5, `ready` only); `outcome` and `blocker` (item 5's inputs); `merge-oid` (`<oid> <base> <P>`, recorded on merge proof). `profile` (`prose flag`/`prose escalation`): rules below. `reviewers` (`2`–`4`, written by Step 2 on every run that reaches it, `2` without `--reviewers`), `codex-model` (the `--codex-model` slug, written by Step 2 with the flag and removed otherwise; both files stay as they are for an issue already dispatched when a same-session re-entry reaches Step 2; Step 3a rewrites them at each dispatch). Step 3a clears the per-attempt files at every dispatch (`branch`, `worktree` and `error` only when the resume check ran; a Step 4 retry with a known worktree keeps them).

## `result.json`

Its keys are the shape line in SKILL.md, State.

It is **advisory for status, authoritative for telemetry** (why: Why `result.json` is advisory for status decisions and authoritative for telemetry). `merged` and `ready` are claims until item 5's script confirms them against GitHub, anchored on the worktree's git state, never the file's `branch` or `pr`. **Unreadable** — anything but one JSON object with an `outcome` of `merged`/`blocker`/`failed`/`ready` and a non-empty `worktree` — counts as absent. The telemetry keys (`phase1_*`, `gate_*`, `checks`, `checkpoint`, `security_lens`, `review_profile`, `deferred`, `hook_bypass`) are read only from this file, never from the Step 10 report text. `deferred` is an array of objects with exactly the two non-empty string members `finding` and `reason`; `[]`, `null` or absent means none. Any other well-formed JSON value, or an array with a bad entry, only prints `deferred unreadable` and keeps the telemetry; broken JSON makes the file unreadable like anywhere else (`summary.sh` documents the rule).

## Interim notifications

A completion notification is **final** when `result.json` is readable, or when it carries no interim marker (the host's "Agent finished" fires for any agent that stops with background children still running, so the notification alone proves nothing). Without a readable `result.json`, it is **interim** when the host's note ("This agent stopped with background work of its own still running") is the first non-blank line of `issue-N/notification`, or one of the last 5 non-blank lines (host trailer lines may follow) is gh-issue's fixed `interim: waiting on <what>`, and no line starts `worktree: ` (every real exit has one; why: Why an interim notification is not a result). Write the file with the host's note first (when the host sent one), then the implementer's message; a marker quoted anywhere else is just text. `classify.sh notification` makes the call. A notification is discarded unwritten (no file, no status, `progress`, `outcome`, `blocker`, `error` or `agent` change) unless the issue is `implementing` and it comes from the agent recorded in `issue-N/agent` (an absent or empty `agent` file filters nothing: a genuine final notification is never dropped for a missed pointer write; a late one from a `TaskStop`ped agent, even after the issue was re-dispatched, is another attempt's). Exit 1 (the file is missing, unreadable or empty, so the write failed) is no verdict: rewrite the file and re-run once, never treat it as `final` or classify from prose; if it fails again, leave the issue `implementing` and tell the user. (hung.md's wake-time check is the exception: there an empty file is stale, removed, and the ordinary rule applies.) An interim notification decides nothing: the issue stays `implementing`, no `outcome`, `blocker`, `error` or status is written, nothing cascades to dependents, and `progress` is neither written nor read for content, its mtime keeps feeding the hang check. A `final` verdict is processed through item 5 as usual and the file is then removed (`rm -f`, item 5); the hung route (hung.md) removes it before item 5 and never runs this check, so a stale marker cannot hold a dead agent's issue `implementing`.

## `progress`

`progress` is **informational only** (why: Why the progress file is best-effort and never proof; Why the hang rule reads the file's mtime but not its content). Its content never changes a status and is never evidence of merge or convergence; print its first line verbatim. Its mtime feeds only the hang threshold, which only triggers a stop; `failed` is the only status the hang rule itself contributes. A stale file with no agent in flight means nothing.

## Resume pointers

`session` and `agent` are the only **resume pointers**, never status inputs (why: Why resume pointers are written at dispatch, not at failure): `agent` only locates a hung implementer's worktree and tells which notifications count (compared with item 4's normalisation, `agent-…` or bare); `session` only decides the heartbeat bypass, rotation and `heartbeat` ownership.

## `hook-bypass`

`hook-bypass` (the line `authorized <run-id>`, the run's `run-id`) is written only by the orchestrator, after the user's explicit yes to bypassing that issue's repository hooks (host-environment.md). Step 3a reads it alone to add the dispatch line, and `summary.sh` reads it to flag a result that claims `authorized` without it. It survives retries and a same-session re-entry, never a new run, and is never recovered from GitHub.

## `profile`

`profile` (`prose flag` or `prose escalation`) is written only by Step 1 (`--prose-gate`) or Step 4 (the user's explicit answer); it survives retries and a same-session re-entry, never a new run, and is never recovered from GitHub.
