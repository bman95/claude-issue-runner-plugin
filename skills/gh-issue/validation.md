# gh-issue — running the validation contract

How to run the validation script, and every outcome's full handling. SKILL.md's "Validation contract" section says when to read this file and summarizes the outcomes; rationale is in [REFERENCE.md](REFERENCE.md), named by `(why: <entry>)` pointers.

## Resolution and the call

**The script.** `scripts/validation-contract.sh`, bundled beside SKILL.md, is the whole recipe: run it and obey its output and exit status; never restate or re-implement its logic (its header documents grammar, discovery and exit codes). Every "run the validation script with `<mode>`" is this one tool call from the worktree, resolution included. First candidate: the directory of the SKILL.md you are following (orchestrated: of the gh-issue path your dispatch prompt names; interactive: the skill's base directory, or on issue-runner's single-issue fast path, of the resolved `GH_ISSUE_SKILL`). A candidate counts only as an absolute path outside this worktree (why: Why the script never comes from the worktree):

```bash
VALIDATION_CONTRACT_SCRIPT=""; TOP=$(git rev-parse --show-toplevel 2>/dev/null)
for c in "<directory of this SKILL.md>/scripts/validation-contract.sh" \
         "${CLAUDE_PLUGIN_ROOT:-/nonexistent}/skills/gh-issue/scripts/validation-contract.sh" \
         "$HOME/.claude/skills/gh-issue/scripts/validation-contract.sh"; do
  case $c in /*) ;; *) continue ;; esac                        # never a relative path
  [ -n "$TOP" ] && case $c in "$TOP"/*) continue ;; esac       # never the PR's own copy
  [ -f "$c" ] && VALIDATION_CONTRACT_SCRIPT="$c" && break
done
[ -n "$VALIDATION_CONTRACT_SCRIPT" ] || { echo "validation: validation-contract.sh not found" >&2; exit 7; }
bash "$VALIDATION_CONTRACT_SCRIPT" <mode>   # check | changed | preflight | full
```

## Outcomes

Modes: `check` (Step 3), `changed` (Step 9), `preflight`, `full`. Outcomes:

- **`fallback (no contract)`** — Step 5's project conventions (CLAUDE.md, README, linter and test configuration) decide; what you ran as you went is the preflight. Not an error; Step 10 reports it.
- **`contract ok`**, **`contract unchanged in this PR`**, **passed** — continue.
- **failed** (exit 1) — fix and re-run. If `origin/<base>` is ahead of the merge-base (`git rev-list --count "$(git merge-base HEAD origin/<base>)..origin/<base>"` non-zero), the fix includes merging `origin/<base>` in (Step 9's base-freshness recipe in merge.md, run early) and re-running. (why: Why the base is merged in before a validation verdict) If it still cannot pass (not caused by this change, or a reasonable fix fails): interactive — show the output and ask (fix by hand, or stop); orchestrated — blocker `preflight validation failed (exit N): <command>` (or `full validation failed (exit N): <command>`), the PR still a draft or reverted to draft (Step 9's recipe). Never open, ready or merge over it; never edit the contract to make it pass.
- **invalid contract** (exit 3) or **not runnable** (exit 4) — never degrades silently into "no validation". For exit 4, first rule out, in order: (1) this PR — if `git diff --name-only "$(git merge-base HEAD "origin/<base>")" HEAD` (`<base>` re-resolved as the script does: the open PR's base, else the default branch) touches what the command runs (its script, anything that invokes, a tool it installs), it is a plain **failed**; (2) a stale checkout — base ahead (the `rev-list` above) → merge it in (Step 9's base-freshness recipe in merge.md) and re-run. Only then is the contract broken on the base branch (why: Why a broken contract never means no validation):
  - **Interactive** — ask: fix the file on the base branch as its own change, or proceed on the conventions fallback, recorded in Step 10 as `validation: fallback (contract invalid — user authorized)` (not-runnable included). A yes is a **standing fallback authorization** (granted at Step 3 for invalid, Step 5 or 8 for not runnable): for the rest of the run Steps 5, 8 and 9 validate by the conventions instead of `preflight`/`full`; Step 9's `changed` still runs.
  - **Orchestrated** — blocker `validation contract invalid: <reason>` or `validation command not runnable (exit N): <command>`; a human fixes the base branch (the runner never re-dispatches on it within a run, issue-runner Step 4).
- **`contract changed in this PR`** (exit 5) — Step 9.
- **`full` not declared** — Step 9 still runs `full` (it re-reads the base tip); nothing else runs there beyond the preflight re-run its base refresh may need.
- **base unresolvable** (exit 2) — an environment failure, never a verdict or a fallback: fix the fetch and re-run. Interactive: report; orchestrated: the result file's `failed` class, `validation: cannot resolve the base branch`, not a blocker (Step 3 re-runs once first). (why: Why an unresolvable base is a failure, not a blocker)
- **script not found** (exit 7, `validation: validation-contract.sh not found`) — a broken install, never "no contract" or a skipped validation: interactive, report; orchestrated, the `failed` class with that message. Exit 6 (`unknown MODE`): fix the call. Any other exit (e.g. 126): the same `failed` class. None of these is ever a pass or "no contract".

## Relation to CI

Validation never replaces the Step 9 checks gate: a red check blocks the merge whatever the preflight said, a green one never excuses a skipped or failing preflight. With `checks: none`, Step 10 says the contract's validation was the only automated verification. (why: Why preflight never replaces CI)
