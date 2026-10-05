# Step 5 — summary, telemetry and the tracking-issue post

Read at Step 5 of every orchestrated run, after `summary.sh` has printed (SKILL.md, Step 5), for what comes with it. Then return to Step 5's final release. Rationale: [REFERENCE.md](REFERENCE.md).

## What the script prints

`scripts/summary.sh` is the whole recipe for the **summary table** (number, status, title, error, and a failed issue's last `progress` line), the **telemetry** (per issue and totals, including each issue's reviewers and gate model, from each `result.json` only, never the Step 10 report text; a missing or unreadable file is `no result recorded`, never zeros), the **`!` flag lines** (`phase1_state` `cap-stop`/`bouncing`, `gate_state` `degraded`/`waived`/`cap-stop`/`errored`/`bouncing`/`unavailable`, `phase1_inline` `true`, `checkpoint` `refused` or `skipped`), the run-level checkpoint notes, the review profile (requested → effective, from `profile` and `review_profile`), the hung-after-merge note, the unfinished-PR shapes (`classify.sh pr-shape`, run when `DEFAULT_BRANCH` is passed) and the `Actual agents: … (estimate: …)` line with its caveat (why: Why the actual-spend line is best-effort). Its header documents each rule. Print its output as it is: never recompute, reorder or reword a line, and never replace an absent line with your own.

Relay in the closing message every `!` line and every `PR shape unknown`. A paused run's slot-starved issues print as `pending`: the closing message states the pause (pause.md). A `skipped` checkpoint is the implementer leaving out Step 4's draft-PR checkpoint, not a refused push, and the crash-recovery guarantee did not hold for that issue. An unfinished non-draft PR is one a human could merge by hand (why: Why the implementer opens a draft PR right after the plan).

## Grouping

Call out every `blocked` with `PR #P merged but issue still open — confirm and close by hand`: a human confirms the PR is this run's, closes the issue, resolves it to `done`. List `blocked`, `ready` and `closed-externally` apart from `failed`. Any `failed` or `closed-externally` is a non-zero outcome in the closing message.

## Ready PRs

**Ready PRs (`--no-merge` mode).** If any: list each `ready` issue in `dag.json`'s topological order with its PR URL (`gh pr view "$(cat "$STATE_DIR/issue-N/pr")" --json url -q .url`) and title, then print the re-run commands: `/issue-runner --merge-ready` (merge every eligible one and continue), or `/issue-runner <unfinished issue numbers>` (keep them `ready` for a human to merge first).

## Posting to the tracking issue

**Post the summary to the tracking issue** when all hold:
- every issue in `scope.txt` has exactly one `details.json` body line that, trimmed, matches `^Part of #[0-9]+$` (any position; two or more count as none);
- `P` is the same for all;
- `#P`'s current body (`gh issue view "$P" --json body -q .body`) passes Step 1's tracking-issue test.

Then write one line naming the scope (`issue-runner run — scope: #41 #42 #43`) and the script's output, unchanged (free text is sanitized into code spans, everything else is an enumerated word or a number), to `$STATE_DIR/summary.md` and post it, one comment per run (a partial re-run posts its own): `gh issue comment "$P" --body-file "$STATE_DIR/summary.md"`. A failed comment is reported, never fatal. Otherwise only print, plus one line saying why no comment was posted (why: Why the Step 5 summary posts to the tracking issue).
