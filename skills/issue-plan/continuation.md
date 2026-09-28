# Continuing an existing plan

Read this when the user chose to **continue** an earlier `/issue-plan` tracking issue (Step 1 of [SKILL.md](SKILL.md), or Step 3's continue-or-fresh question for a Step 2 `extend`). It is Step 5's continuation rule: it replaces the fresh-plan create of the tracking issue, and everything else in Step 5 — the `## Slices` line format, the plan-file entry per slice, the `gh issue edit <tracking> --body-file` after each slice, the failed-edit report — applies as written there and in [templates.md](templates.md).

## Enumerate the published slices

A continuation enumerates the published slices from the ground truth, not from the list: `gh issue list --state all --limit 200 --json number,title,body`, keeping the issues with exactly one line that, trimmed, is `Part of #P` (the runner's own test, so both sides agree on what a slice is; a plain listing, not `--search`, because the search index lags a fresh create by minutes) — a slice carrying that line is published whatever the list says, and a list entry already naming `#N` is verified with `gh issue view N`, never demoted because the listing missed it.

## Reconcile the list and the plan file

Reconcile the list with it, and the plan file with the same ground truth:

- an entry for a published slice stays as written (it records what was planned, and a hand edit since is the drift the runner reports);
- a published slice with no entry (a failed edit) gets one from its current body;
- an entry for an issue that is not a published slice of this plan is dropped;
- a plan that predates the plan file gains the section after `## Slices`, built from the slices' current bodies;
- a block the runner would report as `ignored` (invalid JSON, a version-1 schema error such as a duplicated `n`, a second `## Plan file` heading, no block directly under the heading, an unclosed block) is rebuilt the same way in place, leaving exactly one heading and one block (say so at hand-off);
- a block with a version other than 1 was written by another planner: leave it untouched, never downgrade it, and say so at hand-off.

Show the result for approval, then create only the slices still `(unpublished)` and update the list and the plan file as above. Read the tracking body from GitHub (`gh issue view <P> --json body -q .body`), never from a local file, so edits made since survive.

## Continuing from new input

A continuation begun from new input (Step 2's `extend`) first appends the newly approved Step 4 slices under `## Slices` as `(unpublished)` entries — in dependency order, after the existing lines — before any of them is created, so the list's size is known before the first create and a partial publish describes itself exactly as on a fresh plan (the create-only-`(unpublished)` rule above then covers them).

It appends that input under `## Input` as a further `> `-quoted block (unless an identical block is already there — a retried continuation appends nothing twice) — under the same 65,536-character budget as a fresh create: the new block is quoted up to what fits after the appended decisions, the rewritten `## Existing work`, the full slice list and the plan file at its final size (its reconciled entries plus one per new slice), cut with the same truncation marker, and an edit that would still not fit stops before any slice is created — so the request behind the new slices is on record too.

New decisions append to `## Decisions`.

The re-run Step 2 rewrites `## Existing work` in its place between `## Decisions` and `## Slices` (adding the section when the plan predates it) — open items re-classified, and prior entries whose reference has since closed (a superseded issue the user closed) kept as they were, so the record of a replacement does not vanish with the issue it replaced; the no-overlap line stands alone only when nothing is kept, otherwise the counts line follows the kept entries.
