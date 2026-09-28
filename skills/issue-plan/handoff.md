# Handing off around existing work

Read this at Step 6 of [SKILL.md](SKILL.md) whenever Step 2's reconciliation table has any entry (anything but the single `No existing work found` line). It says what to name, and what never to offer, for each kind of existing work the plan touches. The `depends` edges, the single-slice fast path and merge-first are in Step 6 itself.

## In-flight PRs

An issue whose PR is already in flight, and a PR with no issue, must simply merge before the slice that needs them runs (until then, only the slices that do not need them can run, by explicit number — the dependent slice's edge is still asked about, and no answer is right before the merge: `extend` dispatches on the in-flight issue, `override` claims a prerequisite that has not landed) — dispatching an implementer on an issue a person is implementing resumes or duplicates their PR.

The exception is a checkpoint (Step 2: a draft on the runner's `/issue-N-` branch contract, `## Plan` or `## Changes`): a crashed or bounced implementer's PR, which cannot merge without a dispatch, so its issue (the `N` in its branch) is offered to the run — in a run of two or more the runner's Step 3a resume check picks it up from that branch, alone the fast path's gh-issue in-flight check does — and a slice that depends on it is handed off beside it, never told to wait for a merge.

## Superseded issues and departed PRs

Name every issue a slice supersedes (Step 2's `supersedes`) the same way: still open, it sits in a no-argument run's scope beside its replacement and both get implemented, so the user closes it (or parks it under a label the runner offers to skip) before such a run, or runs the slices by explicit number.

Name an in-flight PR a `conflict` answer departed from the same way: still open, it can merge beside the slices that replace it, so the user closes or redirects it before the run.

## Open issues the plan reuses

Name the open issues the plan reuses as well — a `covered` issue whose behavior is still unbuilt, and an issue a slice extends without depending on it (Step 2's `extend`): the request is finished only when they land too, so a no-argument run takes them by itself, and a run by explicit number either lists them beside the slices (with the caveats of Step 6's merge-first: no `Part of #P`, so no tracking-issue post; without `Files likely touched:`, the LLM conflict pass) or leaves them for a run of their own.

## Issues a PR already delivers

An open issue a PR already delivers (Step 2: `covered` by a merged or in-flight PR, whatever the PR body cites) is never offered: merged, the issue is stale — the user closes it, never the planner; in flight, the PR merges first (a checkpoint is resumed instead — "In-flight PRs" above) — and either way a no-argument run would still take the open issue, and the runner's resume check finds its PR only through a closing keyword or the branch contract, so say so: the user closes or parks it, or runs the slices by explicit number.

## A request found entirely covered

A request found entirely `covered` (Step 5 created no slice) hands off the covering open issues' numbers alone — never a stale one — and `/issue-runner` runs those — or, when merged PRs cover all of it, reports that nothing remains to build; an in-flight PR that covers it must merge first — until then there is nothing to dispatch, and dispatching on it would resume or duplicate it — unless it is a checkpoint, which `/issue-runner <issue>` resumes. When the input was an existing issue it is now the duplicate: say so — nothing quotes it, and a no-argument run would implement it beside the issue that covers it.
