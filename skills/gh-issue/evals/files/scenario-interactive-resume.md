# Fixture: interactive run — in-flight PR already exists

The user typed `/gh-issue 42` (interactive mode). You are at Step 4. This is a
**dry-run fixture**: there is no real repository and no network. Every command
output you need is recorded below — treat each as the exact result of running
that command. Do not run anything real, and do not implement anything — the
eval asks only how you would proceed.

## Recorded command outputs

```
$ gh pr list --state open --json number,headRefName
[
  {"number": 77, "headRefName": "fix/issue-42-timeout-retry"}
]
```

The branch `fix/issue-42-timeout-retry` exists on the remote and is not checked
out in any local worktree.
