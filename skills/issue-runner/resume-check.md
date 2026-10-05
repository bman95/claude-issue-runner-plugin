# Step 3a — resume-check outcomes

Read at Step 3a whenever `resume-check.sh` prints anything but a lone `none` line, or exits non-zero (SKILL.md, Step 3a). Then return to Step 3a's clear-and-dispatch.

The branch contract is not sufficient alone (why: Why dispatch resumes open PRs), so the script probes three things: the branch contract (a draft checkpoint is an open PR), closing keywords (open PRs from anywhere whose body closes `#N`; one PR may close several issues), and orphan branches. Act on its output:

- **Exit 1** → never dispatch on a blind check: retry once; still failing → `blocked` with error `resume check failed: <stderr>`, for Step 4.
- **`probe3-failed <reason>`** with no `pr` line → do not dispatch: `blocked` with error `probe 3 failed (auth/transport): <reason>` (never leave it `pending`: the Step 3 loop would have no exit), for Step 4 (its retry has no worktree, so it re-runs this check). With a `pr` line, resume it.
- **`keyword-unconfirmed #P <B> draft=… worktree=…`** → read `gh pr view <P> --json body` before counting matches. Closes `#N` in a form the script does not read (`owner/repo#N` naming this repository, an issue URL, a keyword in markdown emphasis) → treat as a `pr #P <B> … via=keyword` line with the same fields; only mentions `#N` → drop it (nothing else printed → `none`).
- **`none`** → dispatch the template (SKILL.md, Step 3a) as-is (fresh branch, new PR).
- **Branch only** (`branch <B> <tip> …` lines, no `pr` line):
  - **`stale #P`** → `git push --force-with-lease=refs/heads/<B>:<tip> origin :refs/heads/<B>`, then dispatch fresh.
  - **`ask (…)`** → ask the user: resume it, or delete the branch and dispatch fresh.
  - **`orphan worktree=…`** → resume on that branch like a one-match dispatch (minus its "skip the Step 4 checkpoint" clause, reading `worktree=` the same way), naming the branch and stating there is no PR yet. Never dispatch fresh over an orphan.
- **One `pr` line** (`pr #P <B> …`) → resume, don't duplicate: the prompt says continue on `B`, skip the Step 4 checkpoint, skip only `gh pr create` in gh-issue Step 7 (the body rewrite still applies), push to PR `#P`.
  - `worktree=` a path (not `-`) → dispatch **without** `isolation: worktree`, record the path in `$STATE_DIR/issue-N/worktree`, and tell the agent to `cd` there first. Otherwise keep `isolation: worktree` and tell it to check out `B` (fetch first, no new branch).
  - `via=keyword` → write `B` to `$STATE_DIR/issue-N/branch` after the clear (SKILL.md, Step 3a) (item 5's merge proof accepts it alongside the contract, nothing else).
  - `draft=true` resumes like any other; the implementer starts from the body's plan (gh-issue Step 3), except a `Contract-first stop` plan, which is never executed (gh-issue `resume.md`).
- **Several `pr` lines** → ask the user which PR to resume and close the rest.
- **Matched only by closing keyword** (`via=keyword`) → assume nothing: read `gh pr view <P> --json state,mergeable,mergeStateStatus,isDraft,files,body` and `gh pr checks <P>`. Already implements the issue → do **not** dispatch; show the user its check status and ask: review-and-merge, or close and rebuild. A PR closing several in-scope issues is one decision; mark every issue it covers.
