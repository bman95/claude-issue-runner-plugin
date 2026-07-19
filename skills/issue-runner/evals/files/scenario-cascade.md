# Fixture: mid-run scheduler state — cascade pass

You are the orchestrator mid-run, entering a Step 3 scheduling pass. This is a
**dry-run fixture**: there is no real repository and no network. Every command
output you need is recorded below — treat each recorded output as the exact
result of running that command. Do not run `gh` or `git` against anything real.

Nothing is currently in flight (no dispatch slots occupied). `MAX_PARALLEL=5`.

## dag.json

Key = issue number, value = list of issue numbers it depends on:

```json
{"10": [], "11": [], "12": ["10"], "13": ["11"], "14": []}
```

## Current statuses (from $STATE_DIR/issue-N/status and error)

| issue | status | error |
|-------|--------|-------|
| 10 | failed | `implementer hung (no completion)` |
| 11 | closed-externally | `closed without a merged implementer PR` |
| 12 | pending | — |
| 13 | pending | — |
| 14 | pending | — |
