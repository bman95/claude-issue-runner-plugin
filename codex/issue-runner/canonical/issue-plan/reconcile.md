# Reconciliation sources

Step 2 of [SKILL.md](SKILL.md) gathers existing work from these four sources. The Gather paragraph there still governs every listing: a source the repository lacks is skipped silently, the plan itself is never a candidate, a listing that returns exactly its `--limit` is truncated (ask; count it with a `+`), and a listing that exits non-zero is `not scanned`, never zero.

## Contents

- Open issues
- Open PRs
- Design and RFC documents
- Recently completed work

## Open issues

`gh issue list --state open --limit 200 --json number,title,body,labels`.

A tracking issue from an earlier `/issue-plan` (body with a `## Slices` line and no `## What to build` line — the runner's own test; the `Plan: ` title is only a hint) is a plan, not a task: read its `## Decisions` and `## Slices`, and find its published slices by their `Part of #P` line (Step 5's test: `gh issue list --state all --limit 200 --json number,title,body`, keeping the issues with exactly one line that, trimmed, is `Part of #P` — the runner's own test; a plain listing, not `--search`, because the search index lags a fresh create by minutes) — a slice still open is planned work; a slice its `## Slices` names that this open listing lacks is closed, and `gh issue view N --json state,stateReason,closedByPullRequestsReferences` tells whether a merged PR finished it — the plain view omits the field, `stateReason` is `COMPLETED` for a hand-close too, and the array lists every PR whose closing keywords name the issue, open or not, from this repository or another (`repository` says — a `Closes owner/repo#N` in another repository's PR closes this issue too; only this repository's PRs count, since a bare foreign number read here is the wrong PR), so a listed PR proves the finish only when `gh pr view P --json state,baseRefName` says `MERGED` into the default branch; otherwise the slice was abandoned, not finished; a closed slice the list never recorded (a Step 5 edit that failed and was not fixed by hand) is invisible here — the recent-merges listing and the Step 1 exploration are what catch its work.

## Open PRs

`gh pr list --state open --limit 100 --json number,title,body,headRefName,baseRefName,isDraft,files,changedFiles,closingIssuesReferences,isCrossRepository`. Work in flight:

- `closingIssuesReferences` ties a PR to its issues — GitHub's resolution of `Closes`, `Fixes` and `Resolves`, the same three keywords the runner's Step 3a searches, so a PR is issue-less only when GitHub says so — counting only references to this repository (`repository.owner.login`/`repository.name`; a `Closes owner/other#N` names another repository's issue, which is never a `## Blocked by` edge or an in-scope issue here).
- A draft whose head branch is on the runner's contract (`/issue-N-`, gh-issue Step 4; `isCrossRepository` false — a fork's branch is never the runner's) is an unfinished orchestrated PR, the exception Step 6 names — a crashed implementer's plan (`## Plan`) or a run that stopped in review (`## Changes`, a draft until gh-issue Step 9) — which runner Step 3a resumes by that branch alone, whatever its body says, so its issue is the `N` in the branch even when GitHub lists no reference (a `Closes #N` lost in a body refresh).
- `files` lists the paths it will land on — the first 100 only, with no marker, so when `changedFiles` is larger, `gh pr diff N --name-only` gives the full list.
- `baseRefName` says whether it lands on the default branch — a PR into a release or feature branch does not (the merged-PR rule under "Recently completed work"), so it is `covered` or `depends` only when its base is the head of an open PR of this repository (`isCrossRepository` false — a fork PR's head is a branch of the fork, so it is never another PR's base, however its name reads) that lands on the default branch, directly or through further such PRs — a stack in flight toward it, where Step 6's merge-first means the whole stack — and neither when no such PR exists (a release or backport branch, or a feature branch with no PR toward the default branch yet).

## Design and RFC documents

Whatever the Step 1 exploration found: design notes, RFCs, ADRs, decision logs, the architecture or decisions sections of README, CLAUDE.md or AGENTS.md — located by the exploration, never by a hardcoded path or file name. Read the entries whose subject overlaps the input. A status line (proposed, parked, rejected, implemented), an options list with a recommendation, and open-question bullets are the parts that decide the classification in Step 2.

## Recently completed work

`gh pr list --state merged --limit 100 --search "merged:>=<date> sort:updated-desc" --json number,title,body,files,changedFiles,mergedAt,baseRefName`, `<date>` being 90 days before today, or the input's own creation date when it is an issue older than that.

The `merged:` window is what bounds the listing — a merge older than it is already in the code the Step 1 exploration read — and `--limit` is only the Gather paragraph's truncation guard (a count alone cannot define "recent": the default order is creation time, and GitHub search has no merge-date sort — `sort:updated-desc` is the closest order, so a truncated listing drops the longest-untouched merges first).

Kept only when merged into the default branch — `baseRefName` says; a PR merged into a feature or release branch has not landed, and a stacked PR's work is carried by the open PR above it — and directly relevant to the input's scope (same feature, same files — `files` is what that test reads, completed by `gh pr diff N --name-only` when `changedFiles` exceeds its 100; a merged PR's body rarely names its paths — same contract); older or unrelated history is not scanned. Recent merges are where the code has moved since the input was written, so the plan builds on what landed rather than on what the input remembers.
