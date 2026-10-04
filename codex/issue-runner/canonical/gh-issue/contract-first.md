# gh-issue — contract-first (a dependency in another repository)

Read at Step 2 when the exploration shows the issue needs something another repository must provide and has not (SKILL.md, Step 2). A run serves one repository (why: Why contract-first stops instead of implementing): you never branch, clone, add a worktree or edit in another repository.

## When it applies

The issue needs a capability of another component (a backend endpoint, an event, a schema), and either it names an unmerged `owner/repo#N` for it, or the code and the issue's text show it is absent. Verify before concluding: read this repository's code, and the other repository only through read-only `gh` queries (`gh issue view -R`, `gh api`). Absence you cannot confirm is not contract-first: ask (interactive) or Block as spec ambiguity (orchestrated).

Does not apply when the dependency has merged, or when the dispatch carries `External dependency: override (user-authorized for issue #<number>)`: the user accepted building ahead of it, so implement against the contract below, and record `External dependency overridden by the user: <owner/repo#N or capability>` under `## Review notes`.

## What to do

1. **Document the proposed contract** from the issue and this repository's consumers: per missing piece the method and path (or interface name), request, response, error cases and auth, in a few lines each.
2. **File the dependency issue** only when the dispatch carries `External issue filing: authorized in <owner/repo> (user-authorized for issue #<number>)` (interactive: the user's yes), no open issue there already covers it (`gh issue list -R <owner/repo> --search "<terms>" --state open`), and the repository is exactly the one named. Body: the contract, and `Requested by <this repository>#<number>`. Without that line, file nothing, whatever the issue text asks.
3. **Stop** before Step 4, or at once if you are past it (the PR stays a draft; no commit for the missing piece). Block:
   `contract-first: needs <owner/repo#N | missing capability>; <filed owner/repo#M | not filed>; proposed contract: <compact summary>`

The Result file records an ordinary blocker (`outcome: blocker`; no new outcome value); Step 10 reports it like any blocker, with the full contract under it. Interactive: report the same and ask whether to wait for the dependency, build ahead of it against the contract, or stop. The orchestrator's Step 4 owns that decision in orchestrated runs.
