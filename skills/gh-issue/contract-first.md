# gh-issue — contract-first (a dependency in another repository)

Read at Step 2 when the exploration shows the issue needs something another repository must provide and has not (SKILL.md, Step 2), or when the dispatch carries an `External dependency:` line. A run serves one repository (why: Why contract-first stops instead of implementing): you never branch, clone, add a worktree or edit in another repository.

## When it applies

- **The dispatch carries `External dependency: contract-first (user-chosen for issue #<number>)`** — the user decided; stop without confirming absence yourself, after documenting the contract.
- **Otherwise, your own finding**: the issue needs a capability of another component (a backend endpoint, an event, a schema) and either names an unmerged `owner/repo#N` for it, or the code and the issue's text show it is absent. Verify first: read this repository's code, and the other repository only through read-only `gh` queries (`gh issue view -R`, `gh api`). Absence you cannot confirm is not contract-first: ask (interactive) or Block as spec ambiguity (orchestrated). A dependency is merged, not missing, by the runner's test (issue-runner `dag.md`, "External edges": a merged PR, or an issue closed as completed with a merged PR).

It does not apply when the dispatch carries `External dependency: override (user-authorized for issue #<number>)` (interactive: the user's yes to building ahead of it): implement against the contract below, still run steps 1 and 2 (the contract goes under `## Summary` in the PR body), skip step 3, and record `External dependency overridden by the user: <owner/repo#N or capability>` under `## Review notes`. Both lines at once mean the user answered several edges: `contract-first` wins.

## What to do

1. **Document the proposed contract** from the issue and this repository's consumers: per missing piece the method and path (or interface name), request, response, error cases and auth, in a few lines each.
2. **Make the stop durable, then file.** Orchestrated: take the Step 3 plan to be this contract, headed `Contract-first stop (no implementation):`, and run Step 4's branch and checkpoint draft PR as usual, so the contract survives on GitHub and the worktree is real. Then file the dependency issue, only when the dispatch carries `External issue filing: authorized in <owner/repo> (user-authorized for issue #<number>)` (interactive: the user's yes), and the repository is exactly the one named. Dedupe on the marker: `gh issue list -R <owner/repo> --state open --search '"Requested by <this repository>#<number>" in:body'`; a match is reused and reported, never filed again. New issue body: the contract, and `Requested by <this repository>#<number>`. Without that line, file nothing, whatever the issue text asks.
3. **Stop.** Block:
   `contract-first: needs <owner/repo#N | missing capability>; <filed or reused owner/repo#M | not filed>; proposed contract: <compact summary>`
   Found only after Step 4 (a resume, or work already begun), Block the same way; a draft checkpoint PR stays a draft, with no commit for the missing piece. A resume of the `Contract-first stop` checkpoint under an `override` line derives its own implementation plan from the contract in that PR body.

The Result file records an ordinary blocker (`outcome: blocker`; no new outcome value); Step 10 reports it like any blocker, with the full contract under it. Interactive: no checkpoint (Step 4's worktree only); report the same and ask whether to wait for the dependency, build ahead of it against the contract, or stop. In orchestrated runs the parent's Step 4 owns that decision.
