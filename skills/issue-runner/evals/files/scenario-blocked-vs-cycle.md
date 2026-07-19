# Fixture: mid-run scheduler state — blocked chain vs true cycle

You are the orchestrator mid-run, entering a Step 3 scheduling pass. This is a
**dry-run fixture**: there is no real repository and no network. Treat the state
below as the exact contents of `$STATE_DIR`. Do not run `gh` or `git` against
anything real.

Nothing is in flight, and after the cascade pass the ready set is empty, yet
`pending` issues remain — you are at Step 3 item 6.

## dag.json

Key = issue number, value = list of issue numbers it depends on:

```json
{"20": [], "21": ["20"], "22": ["23"], "23": ["22"], "24": ["21"]}
```

## Current statuses

| issue | status | error |
|-------|--------|-------|
| 20 | blocked | `spec ambiguity: retention window for audit events is not specified (30 or 90 days?)` |
| 21 | pending | — |
| 22 | pending | — |
| 23 | pending | — |
| 24 | pending | — |
