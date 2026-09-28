# Step 1 — scope from the open-issue list

Read at Step 1 when `/issue-runner` is invoked with no issue numbers (SKILL.md, Step 1). Then return to Step 1's tracking-issue exclusion.

**No arguments** → `gh issue list --state open --json number,title,body,labels,assignees,comments --limit 50`. Exactly 50 results → tell the user the list is likely truncated and confirm scope (why: Why `--limit 50` is surfaced). Then filter:

- **Parked labels.** Exact match, case/separator-insensitive: `on-hold`, `wontfix`, `parking-lot`, `blocked`, `discussion-only`, `needs-info`, `stale`, `duplicate`. If any issue is parked, ask via `AskUserQuestion`: skip parked *(recommended)* / include all / pick; none parked → no question. Never auto-include a parked issue. If the user includes a `duplicate`, say it usually wants `gh issue close`, not implementation.
