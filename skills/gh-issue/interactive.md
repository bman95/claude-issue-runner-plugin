# gh-issue — interactive-only recipes

What an interactive run (`/gh-issue N`, or issue-runner's single-issue fast path) does that an orchestrated one does not: the in-flight check before planning, the dedicated worktree, and the teardown after the merge. SKILL.md Steps 3, 4 and 9 say when to read each part.

## In-flight check (before the Step 3 plan)

Check for in-flight work: an open PR whose head matches `/issue-<number>-` (`gh pr list --state open --json number,headRefName,isDraft`; a draft is an orchestrated checkpoint), or a remote branch without one (`git ls-remote --exit-code --heads origin '*/issue-<number>-*'`), classified as SKILL.md Step 4's leftover-branch guard does — merged at its `headRefOid` → offer to delete it (the guard's same lease); moved on, or closed → say so, the user decides; none → a true orphan. If one exists, ask: resume it (fetch the branch, add the worktree on it without `-b`, skip only `gh pr create` in Step 7 when the PR exists, push to that PR) or start fresh (`gh pr close <PR> --delete-branch`, or `git push origin --delete <branch>` for an orphan).

## The worktree (Step 4)

Create a dedicated worktree off the default branch and enter it; every later step runs from there, never the main checkout:

```bash
DEFAULT_BRANCH=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@')
[ -n "$DEFAULT_BRANCH" ] || DEFAULT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
ROOT=$(git rev-parse --show-toplevel)
BRANCH=<type>/issue-<number>-<short-slug>            # fix/ feat/ docs/ chore/
WT="$ROOT/../$(basename "$ROOT")-issue-<number>"

# Pre-flight: clear an aborted earlier run's worktree dir and registration.
if [ -e "$WT" ] || git worktree list --porcelain | grep -qxF "worktree $WT"; then
  git worktree remove -f "$WT" 2>/dev/null || git worktree remove -f -f "$WT" 2>/dev/null || true
  [ -e "$WT" ] && rm -rf "$WT"     # leftover dir with no live registration
  git worktree prune
fi

git worktree add "$WT" -b "$BRANCH" "$DEFAULT_BRANCH"
cd "$WT"
```

No Agent-tool lock: Step 9's teardown is a plain remove. Helpers inherit this cwd ("Your subagents"). If `git worktree add -b` refuses because the aborted run's branch survived, it holds unmerged work: resume on it (`git worktree add "$WT" "$BRANCH"`) or delete it by hand only after confirming its PR merged — never force-delete it blind.

## Teardown (Step 9, after the merge is verified)

Leave your worktree, then remove it:

```bash
WT=$(git rev-parse --show-toplevel)                                          # the worktree you are in
BRANCH=$(git rev-parse --abbrev-ref HEAD)
MAIN=$(git worktree list --porcelain | sed -n 's/^worktree //p' | head -1)   # first entry = main checkout (space-safe)
DEFAULT_BRANCH=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@')
cd "$MAIN"                                                                    # leave before removing
git worktree remove -f "$WT"
# -D only on positive merge proof: the PR reports MERGED (-D: squash breaks -d). Not merged → keep the branch.
if [ "$(gh pr view "$PR_NUM" --json state -q .state)" = MERGED ] \
   && [ -n "$BRANCH" ] && [ "$BRANCH" != "$DEFAULT_BRANCH" ] && [ "$BRANCH" != HEAD ]; then
  git branch -D "$BRANCH" 2>/dev/null || true
fi
git fetch --prune                                                            # drop the now-stale origin/<branch> ref
```
