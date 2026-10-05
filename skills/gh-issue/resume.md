# gh-issue — resume runs

A resume continues work an earlier run left on a branch: orchestrated, the branch and PR (or worktree) your dispatch names; interactive, in-flight work the user chose to resume at the interactive in-flight check. SKILL.md Steps 3 and 4 say when to read this file. Rationale is in [REFERENCE.md](REFERENCE.md), named by `(why: <entry>)` pointers.

## Step 3 — what the branch already holds

Inspect the branch before the PR body (why: Why resume reads the branch before the body):
- Reused worktree: `git log --oneline origin/<default-branch>..HEAD` plus `git status --porcelain`.
- Fresh worktree: `git fetch origin '+refs/heads/<default-branch>:refs/remotes/origin/<default-branch>' '+refs/heads/<branch>:refs/remotes/origin/<branch>'`, then `git log --oneline origin/<default-branch>..origin/<branch>`.

The commits decide:
- Only the lone `chore: checkpoint plan for #<number>` commit, clean tree → start from the `## Plan` in the PR body (`gh pr view <PR> --json isDraft,body`), verified against the acceptance criteria and current code; drop anything the issue does not ask for.
- More than the checkpoint (commits or uncommitted changes) → continue where it stopped; never re-execute. If Step 7 already replaced `## Plan`, reconstruct the intent from `## Changes`, `## Review notes` and the branch diff.
- No checkpoint commit → derive your own plan.
- Either way, rebuild `deferred` from the PR body's `Deferred:` lines (result.json is cleared per dispatch), splitting each at its first " — " after the prefix, one entry per finding text, dropping any since fixed.
- A branch with no PR (orphan) → derive your own plan, stay on that branch, and open its draft in Step 4 (only the `gh pr create --draft` line).

## Step 4 — the existing branch or worktree (orchestrated)

Instead of Step 4's `git checkout -b` line:

- Dispatch names an existing branch (**resume**) → `git fetch origin <branch> && git checkout <branch>` instead; push to the named PR. PR exists → skip `gh pr create` in Step 7 (the body rewrite still applies) and SKILL.md Step 4's checkpoint. Orphan (pushed, no PR) → run only the checkpoint's `gh pr create --draft` (SKILL.md Step 4), with your Step 3 plan, before implementing.
- Dispatch names an existing worktree but no PR (retry of a pre-PR blocker) → keep its branch; create the feature branch only if it is still the `worktree-agent-*` scratch branch. `git ls-remote --exit-code --heads origin "$(git rev-parse --abbrev-ref HEAD)"`: a hit with no open PR → the orphan case; a miss → the full checkpoint (SKILL.md Step 4) (a leftover branch its guard reported last time is still a blocker until a human clears it).
