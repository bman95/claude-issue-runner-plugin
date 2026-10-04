# Reading `result.json`, `progress` and the resume pointers

Read before Step 3 item 5 processes the first result, before any hang check (Step 3 item 4), and before Step 5 reads `result.json` or `progress` (SKILL.md, State). These rules say what each file may and may not decide. Rationale: [REFERENCE.md](REFERENCE.md).

## `result.json`

Its keys are the shape line in SKILL.md, State.

It is **advisory for status, authoritative for telemetry** (why: Why `result.json` is advisory for status decisions and authoritative for telemetry). `merged` and `ready` are claims until item 5's script confirms them against GitHub, anchored on the worktree's git state, never the file's `branch` or `pr`. **Unreadable** — anything but one JSON object with an `outcome` of `merged`/`blocker`/`failed`/`ready` and a non-empty `worktree` — counts as absent. The telemetry keys (`phase1_*`, `gate_*`, `checks`, `checkpoint`, `security_lens`, `review_profile`) are read only from this file, never from the Step 10 report text.

## `progress`

`progress` is **informational only** (why: Why the progress file is best-effort and never proof; Why the hang rule reads the file's mtime but not its content). Its content never changes a status and is never evidence of merge or convergence; print its first line verbatim. Its mtime feeds only the hang threshold, which only triggers a stop; `failed` is the only status the hang rule itself contributes. A stale file with no agent in flight means nothing.

## Resume pointers

`session` and `agent` are the only **resume pointers**, never status inputs (why: Why resume pointers are written at dispatch, not at failure): `agent` only locates a hung implementer's worktree; `session` only decides the heartbeat bypass, rotation and `heartbeat` ownership.

## `profile` and `external`

`profile` (`prose flag` or `prose escalation`) is written only by Step 1 (`--prose-gate`) or Step 4 (the user's explicit answer); it survives retries and a same-session re-entry, never a new run, and is never recovered from GitHub. `external` (dag.md, "External edges") persists the same way.
