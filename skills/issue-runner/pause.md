# Credit/usage-limit pause

Read when an `Agent` dispatch call itself errors (SKILL.md, Step 3a), and whenever `$RUN_ROOT/paused` exists at Step 4 or Step 5. Rationale: [REFERENCE.md](REFERENCE.md).

## Step 3a — credit/usage-limit dispatch failure

When the `Agent` call itself errors and *that error's own text* — never a normal result, blocker or PR that mentions these words — matches `credit|quota|billing|insufficient|429|rate.?limit|usage.?limit` (gh-issue's Codex-gate pattern):

- Mark the issue `blocked`, never `failed` (its dependents stay `pending`).
- Save `error`: `host credit/usage-limit exhausted mid-dispatch; wait for it to reset and re-invoke — REFERENCE.md "Run paused on host credit/usage-limit".` followed by the tool's error text verbatim, e.g. ` (agent tool error: <text>)` (data; Step 5 sanitizes it for the tracking-issue post).
- Write `$RUN_ROOT/paused`: one line, `credit/usage-limit exhausted: <ISO-8601 UTC timestamp>` (`date -u +%Y-%m-%dT%H:%M:%SZ`); a later hit overwrites it, never appends.
- Dispatch nothing more while the file exists (Step 3 items 2, 3 and 6; Step 4).

It applies to every dispatch (fresh, resume, Step 4 retry, Step 4's `/codex:rescue` hand-off) and never goes through Step 4's retry/escalation machinery. It gates dispatching only: a Step 4 resolution with no `Agent` call (the fourth-blocker ask-and-close, `Mark failed`) still happens. Best-effort (why: Why the credit/usage-limit pause keys off the `Agent` tool's own error, never the dispatched agent's report).

## Step 4 — while paused

**While `$RUN_ROOT/paused` exists, Step 4 dispatches nothing** — no retry, no `/codex:rescue`. Resolutions without an `Agent` call proceed: the fourth blocker is still asked promptly and marked `done`; `Mark failed`; the risk-blocker question (abort defers: Step 4's risk-blocker rules, escalations.md); the `contract-first:` question's **wait** and **drop** answers (its **override** answer is a dispatch: it is not asked while paused, so the resumed run asks it). Dispatching escalations wait for a fresh invocation (Recovery), which clears the file at the State block.

## Step 5 — the paused closing message

**Run paused on host credit/usage-limit (`$RUN_ROOT/paused` exists).** Open the closing message with: the pause, quoting the file's reason and timestamp; the issue(s) `blocked` on the dispatch failure; every other issue `pending` only for lack of a slot, listed as **paused**, never `skipped` or `failed` (one that reached `failed`/`skipped`/`closed-externally` through item 1's cascade keeps that status); and how to resume — after the reset, confirm no implementer is running, delete `$RUN_ROOT/lock`, re-invoke `/issue-runner` with the unfinished numbers, in this session (keeps guidance and retry history) or after `claude --resume` (Recovery) if it ended. Then finish Step 5 for issues that reached a terminal or `blocked` status, but **skip the final lock/session release** (why: Why the run lock is released last in Step 5).
