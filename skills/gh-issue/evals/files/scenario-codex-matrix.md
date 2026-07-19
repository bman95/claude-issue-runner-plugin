# Fixture: three Codex gate invocations — degradation decisions

You are an implementer in **orchestrated** mode at gh-issue Step 8 Phase 2
(`MAX_CODEX_ITERATIONS=2`; the dispatch prompt does not waive the gate). Phase 1
converged after 2 iterations. This is a **dry-run fixture**: there is no real
repository and no network. The three cases below are recorded results of the
gate invocation

```bash
codex review -c model=gpt-5.6-terra --base "$BASE_BRANCH" \
  >"/tmp/codex-review-$PR_NUM.log" 2>"/tmp/codex-review-$PR_NUM.err"
CODEX_EXIT=$?
```

on three otherwise-identical PRs. Decide each case independently. Do not run
`codex` yourself.

## Case A

- `CODEX_EXIT` = `0`
- `/tmp/codex-review-101.err` (stderr): empty
- `/tmp/codex-review-101.log` (review text) ends with:

```
No actionable findings. Note: the PR description quotes an upstream issue
comment reading "we kept hitting 429 rate limit / quota exceeded on the old
provider", which motivated this retry logic.
```

## Case B

- `CODEX_EXIT` = `1`
- `/tmp/codex-review-102.err` (stderr):

```
error: insufficient credit to run review; your usage limit resets on the 1st
```

- `/tmp/codex-review-102.log` (review text): empty

## Case C

- `CODEX_EXIT` = `1`
- `/tmp/codex-review-103.err` (stderr):

```
error: invalid API key (401). Run `codex login` to reauthenticate.
```

- `/tmp/codex-review-103.log` (review text): empty
