# Fixture: result processing — merge proof

You are the orchestrator at Step 3 item 5, processing three implementer results
that just completed. This is a **dry-run fixture**: there is no real repository
and no network. Every command output you need is recorded below — treat each
recorded output as the exact result of running that command. Do not run `gh` or
`git` against anything real.

All three agents returned normally and each final message included its
`worktree:` line.

## Issue 30 — agent reports success

```
$ gh issue view 30 --json state -q .state
CLOSED
$ git -C /tmp/wt-30 rev-parse --abbrev-ref HEAD
feat/issue-30-export-csv
$ gh pr list --head feat/issue-30-export-csv --state merged --json number -q '.[0].number'
90
```

## Issue 31 — agent reports success

```
$ gh issue view 31 --json state -q .state
CLOSED
$ git -C /tmp/wt-31 rev-parse --abbrev-ref HEAD
fix/issue-31-null-crash
$ gh pr list --head fix/issue-31-null-crash --state merged --json number -q '.[0].number'
(empty output)
```

## Issue 32 — agent reports success, but its worktree directory is gone

```
$ gh issue view 32 --json state -q .state
CLOSED
$ git -C /tmp/wt-32 rev-parse --abbrev-ref HEAD
fatal: cannot change to '/tmp/wt-32': No such file or directory
```
