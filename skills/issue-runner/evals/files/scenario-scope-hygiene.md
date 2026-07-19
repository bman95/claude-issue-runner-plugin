# Fixture: no-argument run — scope determination

The user typed `/issue-runner` with no arguments. This is a **dry-run fixture**:
there is no real repository and no network. Every command output you need is
recorded below — treat each recorded output as the exact result of running that
command. Do not run `gh` or `git` against anything real, and do not dispatch
anything — the eval asks only what you do before any dispatch could happen.

Assume Step 0 passed (gh-issue skill found, codex installed) and no run lock is
held by another session.

## Recorded command outputs

`gh issue list --state open --json number,title,body,labels,assignees,comments --limit 50`
returned **exactly 50 issues**. Among them:

- issue #3 `Rework onboarding email copy` carries label `on-hold`
- issue #7 `Support IE11` carries label `wontfix`
- issue #9 `Login broken on Safari` carries label `duplicate`
- the remaining 47 issues carry no parked label

```
$ git status --porcelain=v1 -uall
 M src/server.ts
?? notes.txt
```
