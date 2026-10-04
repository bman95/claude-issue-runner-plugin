# Reading `result.json`, `progress` and the resume pointers

Read before Step 3 item 5 processes the first result, before any hang check (Step 3 item 4), and before Step 5 reads `result.json` or `progress` (SKILL.md, State). These rules say what each file may and may not decide. Rationale: [REFERENCE.md](REFERENCE.md).

## `result.json`

Its keys are the shape line in SKILL.md, State.

It is **advisory for status, authoritative for telemetry** (why: Why `result.json` is advisory for status decisions and authoritative for telemetry). `merged` and `ready` are claims until item 5's script confirms them against GitHub, anchored on the worktree's git state, never the file's `branch` or `pr`. **Unreadable** — anything but one JSON object with an `outcome` of `merged`/`blocker`/`failed`/`ready` and a non-empty `worktree` — counts as absent. The telemetry keys (`phase1_*`, `gate_*`, `checks`, `checkpoint`, `security_lens`, `review_profile`) are read only from this file, never from the Step 10 report text.

## Interim notifications

A completion notification is **final** when `result.json` is readable, or when it carries no interim marker (the host's "Agent finished" fires for any agent that stops with background children still running, so the notification alone proves nothing). Without a readable `result.json`, it is **interim** when the host's note ("This agent stopped with background work of its own still running") is the first line of `issue-N/notification`, or the last non-blank line is gh-issue's fixed `interim: waiting on <what>`, and no line starts `worktree: ` (every real exit has one; why: Why an interim notification is not a result). Write the file with the host's note first (when the host sent one), then the implementer's message; a marker quoted anywhere else is just text. `classify.sh notification` makes the call. A notification for an issue whose status is no longer `implementing` (a late one from a `TaskStop`ped agent) is discarded unwritten. Exit 1 (the file is missing, unreadable or empty, so the write failed) is no verdict: rewrite the file and re-run once, never treat it as `final` or classify from prose; if it fails again, leave the issue `implementing` and tell the user. An interim notification decides nothing: the issue stays `implementing`, no `outcome`, `blocker`, `error` or status is written, nothing cascades to dependents, and `progress` is neither written nor read for content, its mtime keeps feeding the hang check. A `final` verdict is processed through item 5 as usual and the file is then removed (`rm -f`, item 5); the hung route (hung.md) removes it before item 5 and never runs this check, so a stale marker cannot hold a dead agent's issue `implementing`.

## `progress`

`progress` is **informational only** (why: Why the progress file is best-effort and never proof; Why the hang rule reads the file's mtime but not its content). Its content never changes a status and is never evidence of merge or convergence; print its first line verbatim. Its mtime feeds only the hang threshold, which only triggers a stop; `failed` is the only status the hang rule itself contributes. A stale file with no agent in flight means nothing.

## Resume pointers

`session` and `agent` are the only **resume pointers**, never status inputs (why: Why resume pointers are written at dispatch, not at failure): `agent` only locates a hung implementer's worktree; `session` only decides the heartbeat bypass, rotation and `heartbeat` ownership.
