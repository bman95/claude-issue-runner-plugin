# gh-issue — Step 9, merge

Step 9's stages in order, each with its recipe and outcomes. SKILL.md Step 9 says when to read this file and holds the rules that frame it: interactive confirmation, the orchestrated merge authority and the Draft invariant (every orchestrated blocker in this step first reverts the PR to draft). Rationale is in [REFERENCE.md](REFERENCE.md), named by `(why: <entry>)` pointers.

## Contents

- Full validation and the contract-change check, before ready
- Mark the PR ready first
- Base freshness next
- Checks gate
- No-merge stop, or merge
- Verify

## Full validation and the contract-change check, before ready

Orchestrated: write `step=9 pr=#P` immediately before. Run the validation script with `full`, unconditionally, once per head, on the converged head (it reports `full not declared` itself); under a standing fallback authorization, validate by the conventions instead (still run `changed`). Failure → exactly a preflight failure: the Validation contract outcomes apply (for exit 1, fix and re-run first); unfixable → Block `full validation failed (exit N): <command>`. Then run it with `changed`:

- exit 0 (`contract unchanged in this PR`) → continue.
- exit 2 or 7 → the script's `failed` class; a git failure is never "unchanged".
- exit 5 (`contract changed in this PR`, or `integration contract changed …` for `.issue-runner/integration`) → interactive: show the printed diff and get an explicit confirmation naming the contract change (the merge confirmation alone is not enough); orchestrated, any merge mode: blocker `validation contract changed in this PR — a human must review and merge` (`integration contract …` when only that file changed). (why: Why full validation and the contract check precede ready)

## Mark the PR ready first

The only place the draft flag comes off. A failed `gh pr ready` is a blocker (interactive: report it). For `READIED=1`, the bounded poll lets CI register before "no checks" or "all skipped" can mean "no CI":

```bash
READIED=1   # "this PR was ever a draft": set 0 only for a PR created plain at Step 7 (checkpoint: refused)
            # and for an interactive PR that never was a draft. Carry the value forward yourself.
if [ "$(gh pr view "$PR_NUM" --json isDraft -q .isDraft)" = true ]; then
  if ! gh pr ready "$PR_NUM"; then echo "gh pr ready failed" >&2; exit 1; fi   # blocker — do not continue
fi
if [ "$READIED" -eq 1 ]; then
  # Wait, bounded, until checks exist and every skipped name has a non-skipped twin.
  for _ in 1 2 3 4 5 6; do
    TOTAL=$(gh pr checks "$PR_NUM" --json bucket -q 'length' 2>/dev/null | tail -1)
    NEVER_RERAN=$(gh pr checks "$PR_NUM" --json name,bucket \
      -q '[.[] | select(.bucket=="skipping") | .name] - [.[] | select(.bucket!="skipping") | .name] | length' 2>/dev/null | tail -1)
    [ "${TOTAL:-0}" -gt 0 ] && [ "${NEVER_RERAN:-0}" -eq 0 ] && break
    sleep 10
  done
fi
```

The target repo's CI must run on drafts or include `ready_for_review` (README, Requirements). (why: Why the registration poll after `gh pr ready`)

## Base freshness next

Merge and re-test whenever the base moved, never gated on file overlap (why: issue-runner REFERENCE.md, Why merge waits for CI checks):

```bash
git fetch origin "$BASE_BRANCH"
MB=$(git merge-base HEAD "origin/$BASE_BRANCH")
if [ "$(git rev-list --count "$MB..origin/$BASE_BRANCH")" -gt 0 ]; then
  if git diff --name-only "$MB" "origin/$BASE_BRANCH" \
      | grep -qxFf <(git diff --name-only "$MB" HEAD); then
    echo "base freshness: file overlap with $BASE_BRANCH — a textual conflict is likely" >&2   # warning only, never gates the merge below
  fi
  if ! git merge "origin/$BASE_BRANCH"; then
    CONFLICTS=$(git diff --name-only --diff-filter=U)
    if [ -n "$CONFLICTS" ]; then
      printf 'base freshness: merge conflict in:\n%s\n' "$CONFLICTS" >&2   # print now, before the abort erases it
    else
      echo "base freshness: merge did not start (working tree not clean, or another non-conflict git-merge failure — see its own error above)" >&2
    fi
    git merge --abort 2>/dev/null || true   # "no merge to abort" is expected when the merge never actually started
  fi
fi
```

- Merge failed → never resolve it yourself. Read the printed output, then Block naming it (interactive: ask how to proceed).
- Clean merge → re-run the validation that gated ready (`preflight`, then `full`; else the project's tests, or the conventions under a standing fallback authorization). Failure → interactive: ask; orchestrated: push the merge commit, then blocker citing the failing validation. Never merge over it.
- Passing → push; while the prose profile holds, re-run the revoke-only guard block (review-profile.md; a revocation here is Step 8's); for `READIED=1`, repeat the registration poll; then the checks gate. Never push after the gate passes. (why: Why base freshness runs before the checks gate)

## Checks gate

`gh pr merge` enforces only required checks, so gate on CI yourself (why: issue-runner REFERENCE.md, Why merge waits for CI checks). Orchestrated: write `step=9.2 pr=#P` first.

```bash
if gh pr checks "$PR_NUM" --watch; then CHECKS=pass
elif gh pr checks "$PR_NUM" 2>&1 | grep -qi 'no checks reported'; then
  CHECKS=none   # no CI configured for this branch — proceed, note it in the Step 10 report
else CHECKS=fail
fi
# Count the rollup `--watch` actually judged (the honesty rules below read these).
TOTAL=$(gh pr checks "$PR_NUM" --json bucket -q 'length' 2>/dev/null | tail -1)
SKIPPED=$(gh pr checks "$PR_NUM" --json bucket -q '[.[] | select(.bucket=="skipping")] | length' 2>/dev/null | tail -1)
NEVER_RERAN=$(gh pr checks "$PR_NUM" --json name,bucket \
  -q '[.[] | select(.bucket=="skipping") | .name] - [.[] | select(.bucket!="skipping") | .name] | length' 2>/dev/null | tail -1)
```

`pass` or `none` → merge; for `READIED=1`, report these instead of plain `pass` / "no CI configured" (first matching row wins; all still merge; orchestrated: surface them to the parent):

| Result | Step 10 wording | `checks` |
|---|---|---|
| `none` | `no checks reported after gh pr ready (CI may be draft-filtered)` | `none-after-ready` |
| `pass`, `TOTAL` > 0, `SKIPPED` = `TOTAL` | `all checks skipped after gh pr ready (CI is draft-filtered)` | `all-skipped` |
| `pass`, `NEVER_RERAN` > 0 | `skipped runs never re-ran after gh pr ready (CI may be draft-filtered)` | `unchanged-after-ready` |

(why: Why the checks gate reports draft-filtered CI)

`fail` → interactive: report the failing checks and ask; orchestrated, any merge mode: push, refresh the PR body, then blocker citing the failing checks. Never merge over a failing check without explicit user authorization.

## No-merge stop, or merge

`pass` or `none` under `Merge mode: no-merge` → no `gh pr merge`. Refresh the PR body (Step 8's discipline), write `"outcome":"ready"` in the result file (`pr`, `branch`, `worktree` as usual), skip the merge and teardowns, and at Step 10 return `ready: PR #<PR_NUM>`: success, not a blocker. Change nothing on the PR or branch after this point.

Otherwise (every other orchestrated run, and every interactive run once the user confirms) → merge:

```bash
gh pr merge --squash --delete-branch --match-head-commit "$(git rev-parse HEAD)" "$PR_NUM" \
  --subject "$(gh pr view --json title -q .title)" \
  --body "$(gh pr view --json body -q .body | awk '/^## Review notes$/{exit} {print}')"
```

A refusal because the head moved is never retried against the new head: interactive — report it; orchestrated — Block `PR head moved after the checks gate — a human must review and merge`. (why: Why the merge is pinned to the validated head)

## Verify

`gh pr view "$PR_NUM" --json state -q .state` must be `MERGED` and `gh issue view <number> --json state` `CLOSED`. The merged PR, not the closed issue, is the proof `git branch -D` needs.

Then the teardown SKILL.md Step 9 names for your mode.
