# `--status` mode

Read when `--status` is passed (SKILL.md, Arguments). Read-only: never locks, rotates or initializes.

Run the State block with `bash "$RUN_STATE_SCRIPT" resolve` in place of its `init` line. Print, then exit:

- whenever `$RUN_ROOT` exists, the session pointer (even with no state dir): `$RUN_ROOT/session` absent or blank → `no session id recorded`; else the id and `matches this session`, `recorded by another session`, or (variable unset) `current session id unavailable`;
- `$RUN_ROOT/paused` verbatim if present (`paused: <reason>: <timestamp>`);
- no state dir → say so, naming the resolved path; otherwise, for each issue in `scope.txt` (never the directory listing): number, `status`, `error`, title from `details.json`; `implementing` adds the `progress` line and its mtime age (`step=8.1 iter=2 pr=#123 (age 12m)`, Step 3 item 4's `stat` fallback) or `no progress recorded` if absent or empty; `blocked`/`done`/`failed`/`closed-externally`/`ready` add `outcome` and `pr` from `result.json` (for `ready`, `pr` is `$STATE_DIR/issue-N/pr`) or `no result recorded` if absent or unreadable.
