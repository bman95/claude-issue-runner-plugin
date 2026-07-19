# Fixture: re-run dispatch — resume check

The user re-invoked `/issue-runner 42 43` after an earlier run left issue 42
blocked. You are at Step 3a, about to dispatch both issues (assume both are in
the ready set and their DAG/state bookkeeping is already done). This is a
**dry-run fixture**: there is no real repository and no network. Every command
output you need is recorded below — treat each recorded output as the exact
result of running that command. Do not run `gh` or `git` against anything real,
and do not actually dispatch agents — describe the dispatches you would make.

## Recorded command outputs

```
$ gh pr list --state open --json number,headRefName
[
  {"number": 77, "headRefName": "fix/issue-42-timeout-retry"},
  {"number": 78, "headRefName": "feat/issue-421-metrics-dashboard"}
]
```

```
$ git worktree list --porcelain
worktree /repos/acme-api
HEAD 1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b
branch refs/heads/main

worktree /repos/acme-api-issue-42
HEAD 9f8e7d6c5b4a3f2e1d0c9b8a7f6e5d4c3b2a1f0e
branch refs/heads/fix/issue-42-timeout-retry
```

There is no open PR whose head branch matches `/issue-43-`.
