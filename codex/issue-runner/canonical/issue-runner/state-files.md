# Per-issue files, `result.json`, `progress` and the resume pointers

The full rules behind SKILL.md's State section (the decisive one, what makes `result.json` unreadable, is stated there and enforced by `summary.sh`). They say what each file may and may not decide. Rationale: [REFERENCE.md](REFERENCE.md).

## Per-issue files

Per issue, `issue-N/`: `details.json`, `error`, optional `guidance.md`; `status` (`pending`/`implementing`/`blocked`/`done`/`failed`/`skipped`/`closed-externally`/`ready`, the last only under `--no-merge`); `worktree` (Step 3 items 4–5); `progress` (gh-issue "Progress marker", e.g. `step=8.1 iter=2 pr=#123`); `retries` (Step 4 re-dispatches, absent = 0); `result.json` (gh-issue "Result file"); `branch` (Step 3a, non-contract resumes only); `agent` (the dispatch's agent id, Step 3a); `pr` (item 5, `ready` only); `outcome` and `blocker` (item 5's inputs); `merge-oid` (`<oid> <base> <P>`, recorded on merge proof). `profile` (`prose flag`/`prose escalation`): rules below. `reviewers` (`2`–`4`, written by Step 2 on every run, `2` without `--reviewers`), `codex-model` (the `--codex-model` slug, written by Step 2 with the flag and removed otherwise; both files stay as they are for an issue already dispatched when a same-session re-entry reaches Step 2). Step 3a clears the per-attempt files at every dispatch (`branch`, `worktree` and `error` only when the resume check ran; a Step 4 retry with a known worktree keeps them).

## `result.json`

Its keys are the shape line in SKILL.md, State.

It is **advisory for status, authoritative for telemetry** (why: Why `result.json` is advisory for status decisions and authoritative for telemetry). `merged` and `ready` are claims until item 5's script confirms them against GitHub, anchored on the worktree's git state, never the file's `branch` or `pr`. **Unreadable** — anything but one JSON object with an `outcome` of `merged`/`blocker`/`failed`/`ready` and a non-empty `worktree` — counts as absent. The telemetry keys (`phase1_*`, `gate_*`, `checks`, `checkpoint`, `security_lens`, `review_profile`) are read only from this file, never from the Step 10 report text.

## `progress`

`progress` is **informational only** (why: Why the progress file is best-effort and never proof; Why the hang rule reads the file's mtime but not its content). Its content never changes a status and is never evidence of merge or convergence; print its first line verbatim. Its mtime feeds only the hang threshold, which only triggers a stop; `failed` is the only status the hang rule itself contributes. A stale file with no agent in flight means nothing.

## Resume pointers

`session` and `agent` are the only **resume pointers**, never status inputs (why: Why resume pointers are written at dispatch, not at failure): `agent` only locates a hung implementer's worktree; `session` only decides the heartbeat bypass, rotation and `heartbeat` ownership.

## `profile`

`profile` (`prose flag` or `prose escalation`) is written only by Step 1 (`--prose-gate`) or Step 4 (the user's explicit answer); it survives retries and a same-session re-entry, never a new run, and is never recovered from GitHub.
