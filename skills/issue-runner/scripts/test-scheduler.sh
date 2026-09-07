#!/usr/bin/env bash
#
# Golden fixtures for scripts/scheduler.sh, the deterministic half of
# issue-runner's Step 3 loop (cascade skip, ready set, blocked-chain-vs-
# run-paused-vs-cycle). `docs/scenarios.md` is the human-readable contract;
# this script is its executable form for the rows the scheduler actually
# covers. Every OTHER row in that table exercises Step 3 items 3/4/5,
# Step 3a, Step 4, Step 5, or Step 1/2/State — judgement or live-GitHub work
# this script deliberately does not do (see the accounting at the bottom).
#
# Run directly, or from scripts/lint.sh (and so from CI). Dependency-free:
# bash + coreutils only. Exits non-zero on the first-or-any failure.

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCHEDULER="$ROOT/skills/issue-runner/scripts/scheduler.sh"
SCENARIOS="$ROOT/docs/scenarios.md"

fail=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ok()   { printf 'ok:   %s\n' "$1"; }
err()  { printf 'FAIL: %s\n' "$1" >&2; fail=1; }

# fixture NAME DAG STATUSES PAUSED EXPECTED
#   NAME       - test label
#   DAG        - dag.txt content (may be multi-line; use $'...\n...')
#   STATUSES   - "N=status" pairs, space-separated; N gets issue-N/status=status
#   PAUSED     - "1" to create RUN_ROOT/paused, "" otherwise
#   EXPECTED   - expected stdout, one action per line ($'...\n...')
#
# Also asserts stderr is empty: the script is meant to run silently on every
# well-formed (or gracefully-degraded) input, so any stray stderr output —
# a shell error message from an unbound variable, for instance — is itself a
# failure even when stdout happens to still look right.
fixture() {
  local name="$1" dag="$2" statuses="$3" paused="$4" expected="$5"
  local run="$TMP/$(printf '%s' "$name" | tr -c 'A-Za-z0-9' '_')"
  rm -rf "$run"
  mkdir -p "$run/state"
  printf '%s\n' "$dag" > "$run/state/dag.txt"
  local pair n st
  for pair in $statuses; do
    n="${pair%%=*}"; st="${pair#*=}"
    mkdir -p "$run/state/issue-$n"
    printf '%s\n' "$st" > "$run/state/issue-$n/status"
  done
  [ "$paused" = 1 ] && : > "$run/paused"

  local actual actual_err
  actual="$(bash "$SCHEDULER" "$run/state" 2>"$run/stderr")"
  actual_err="$(cat "$run/stderr")"
  if [ "$actual" = "$expected" ] && [ -z "$actual_err" ]; then
    ok "$name"
  else
    err "$name:"
    [ "$actual" != "$expected" ] && {
      printf '%s\n' "$expected" | sed 's/^/  expected> /' >&2
      printf '%s\n' "$actual" | sed 's/^/  actual  > /' >&2
    }
    [ -n "$actual_err" ] && printf '%s\n' "$actual_err" | sed 's/^/  stderr  > /' >&2
  fi
}

# --- Rows 1-4: the historical bug fixtures (docs/scenarios.md) -------------

# Row 1: A -> B; A blocked, nothing else in flight -> B stays pending (paused).
fixture "scenario row 1: blocked-chain wait, not a cycle" \
  $'1:\n2: 1' "1=blocked 2=pending" "" \
  "paused"

# Row 2: A -> B; A ends closed-externally -> B skipped, closed-externally cascade.
fixture "scenario row 2: closed-externally cascade" \
  $'1:\n2: 1' "1=closed-externally 2=pending" "" \
  $'skip 2 dependency closed externally without merge proof: #1\ndone'

# Row 3: A -> B -> C; A ends failed -> cascade repeats until stable.
fixture "scenario row 3: cascade skip repeats until stable" \
  $'1:\n2: 1\n3: 2' "1=failed 2=pending 3=pending" "" \
  $'skip 2 dependency failed: #1\nskip 3 dependency failed: #2\ndone'

# Row 4: true 2-cycle, no blocked ancestor anywhere -> both skipped, real offending dep cited.
fixture "scenario row 4: true cycle cites a real offending dep" \
  $'1: 2\n2: 1' "1=pending 2=pending" "" \
  $'cycle 1 2\ncycle 2 1'

# --- Rows 29 & 32: the credit/usage-limit run-pause fixtures ----------------

# Row 29 (narrowed to the scheduler's own contribution): RUN_ROOT/paused
# forces the ready set empty outright; item 6 reports run-paused, never a
# cycle, for issues that are merely slot-starved.
fixture "scenario row 29: RUN_ROOT/paused forces the ready set empty" \
  $'1:\n2:' "1=pending 2=pending" 1 \
  "run-paused"

# Row 32: a genuine cascade outcome is never overridden by the pause — the
# dependent still gets skipped, only the slot-starved issue reads run-paused.
fixture "scenario row 32: cascade unaffected by RUN_ROOT/paused" \
  $'1:\n2: 1\n3:' "1=failed 2=pending 3=pending" 1 \
  $'skip 2 dependency failed: #1\nrun-paused'

# --- Action-vocabulary sanity: dispatch / wait / done / standalone paused --

fixture "dispatch: independent ready issues, sorted" \
  $'1:\n2:' "1=pending 2=pending" "" \
  $'dispatch 1\ndispatch 2'

fixture "wait: nothing ready, an implementer is in flight" \
  $'1:\n2: 1' "1=implementing 2=pending" "" \
  "wait"

fixture "done: every issue terminal" \
  $'1:\n2: 1' "1=done 2=done" "" \
  "done"

# --- Edge cases (review findings) -------------------------------------------

# A duplicate line in dag.txt (an unsanitized scope reaching Step 2's write)
# must never process the same issue twice — one dispatch, not two.
fixture "dag.txt dedup: a repeated issue number dispatches once" \
  $'1:\n1:\n2: 1' "1=pending 2=pending" "" \
  "dispatch 1"

# run-paused takes priority over even a genuine cycle: never declare one
# while the host is paused (item 6's own stated order).
fixture "run-paused suppresses a genuine cycle" \
  $'1: 2\n2: 1' "1=pending 2=pending" 1 \
  "run-paused"

# Self-dependency is a degenerate true cycle: no infinite loop, cites itself.
fixture "self-dependency is a true cycle" \
  "1: 1" "1=pending" "" \
  "cycle 1 1"

# Two disjoint true cycles in one DAG: each reports its own offending dep.
fixture "multiple disjoint true cycles" \
  $'1: 2\n2: 1\n3: 4\n4: 3' "1=pending 2=pending 3=pending 4=pending" "" \
  $'cycle 1 2\ncycle 2 1\ncycle 3 4\ncycle 4 3'

# A dependent with both a failed and a closed-externally dep: failed/skipped
# takes priority (checked first), per item 1's own ordering.
fixture "failed dep takes priority over a closed-externally dep" \
  $'1:\n2:\n3: 1 2' "1=failed 2=closed-externally 3=pending" "" \
  $'skip 3 dependency failed: #1\ndone'

# dag.txt names an issue with no issue-N/ dir at all: status_of() defaults it
# to pending rather than erroring, and it is ready when it has no deps itself.
fixture "issue with no status dir at all defaults to pending" \
  $'1:\n2: 1' "2=pending" "" \
  "dispatch 1"

# A dependency chain that bottoms out at a number with no dag.txt line of its
# own (Step 2's contract says every edge is resolved before the file is
# written, but a malformed dag.txt must still degrade cleanly, not crash):
# has_blocked_ancestor's BFS must not choke on the resulting empty deps_of()
# once its queue is otherwise drained — see scheduler.sh's queue
# re-normalization comment.
fixture "dangling dependency reference does not crash the ancestor search" \
  $'1: 2\n2: 4' "1=pending 2=pending" "" \
  $'cycle 1 2\ncycle 2 4'

# A CRLF dag.txt (git core.autocrlf, an editor default -- an easy accident on
# Windows/WSL) must not leave a trailing \r glued onto the last field of a
# line: a no-deps issue must still read as having zero deps, not one phantom
# dependency that can never resolve.
fixture "CRLF dag.txt does not wedge a zero-dep issue" \
  $'1:\r\n2: 1\r' "1=pending 2=pending" "" \
  "dispatch 1"

fixture "paused: a lone blocked issue with no dependent still needs Step 4" \
  "1:" "1=blocked" "" \
  "paused"

# --- Unreadable state: non-zero exit, no guessed status ---------------------

if bash "$SCHEDULER" "$TMP/does-not-exist" >/dev/null 2>&1; then
  err "unreadable state dir: expected non-zero exit"
else
  ok "unreadable state dir: exits non-zero"
fi

# --- Glob safety: a literal `*` in dag.txt must never expand against the ----
# --- caller's cwd (the script's whitespace-normalizing `echo $var` calls   --
# --- would otherwise glob-expand, making the result depend on unrelated    --
# --- files that happen to exist wherever scheduler.sh was invoked from).   --
glob_run="$TMP/globcwd"
rm -rf "$glob_run"
mkdir -p "$glob_run/state/issue-1" "$glob_run/state/issue-2" "$glob_run/state/issue-3" "$glob_run/state/issue-5"
printf 'pending\n' > "$glob_run/state/issue-1/status"
printf 'pending\n' > "$glob_run/state/issue-2/status"
printf 'pending\n' > "$glob_run/state/issue-3/status"
printf 'failed\n' > "$glob_run/state/issue-5/status"
printf '1:\n2:\n3: 1 *\n' > "$glob_run/state/dag.txt"
: > "$glob_run/5"   # a file named "5" that a glob expansion of "*" would match
glob_actual="$(cd "$glob_run" && bash "$SCHEDULER" ./state)"
glob_expected=$'dispatch 1\ndispatch 2'
if [ "$glob_actual" = "$glob_expected" ]; then
  ok "literal * in dag.txt does not glob-expand against the caller's cwd"
else
  err "literal * in dag.txt glob-expanded: expected:"
  printf '%s\n' "$glob_expected" | sed 's/^/  expected> /' >&2
  printf '%s\n' "$glob_actual" | sed 's/^/  actual  > /' >&2
fi

# --- Accounting against docs/scenarios.md -----------------------------------
# Every row above is one this script actually exercises. The rest of the
# table is Step 3 items 3/4/5 (dispatch, hang detection, result.json
# processing), Step 3a/Step 4/Step 5 (live GitHub state, human escalation),
# or Step 1/2/State (scope, DAG construction, the run lock) — judgement or
# live-repo work outside a pure status-files-and-dag.txt state machine, so
# there is nothing here to fixture. Pin the total row count so a scenarios.md
# edit that adds or removes a row is caught here for review, not silently.
IN_SCOPE_ROWS="1 2 3 4 29 32"
EXPECTED_ROW_COUNT=33

if [ -f "$SCENARIOS" ]; then
  actual_rows="$(grep -cE '^\| [0-9]+ \|' "$SCENARIOS")"
  if [ "$actual_rows" -eq "$EXPECTED_ROW_COUNT" ]; then
    ok "docs/scenarios.md row count unchanged ($actual_rows) — in scope here: $IN_SCOPE_ROWS; the rest is Step 3 items 3-5 / Step 3a / Step 4 / Step 5 / Step 1-2 / State, not this script"
  else
    err "docs/scenarios.md now has $actual_rows rows (expected $EXPECTED_ROW_COUNT) — re-check whether any new row belongs in IN_SCOPE_ROWS above and add its fixture"
  fi
else
  err "docs/scenarios.md not found at $SCENARIOS"
fi

if [ "$fail" -ne 0 ]; then
  printf '\ntest-scheduler: FAILED\n' >&2
  exit 1
fi
printf '\ntest-scheduler: OK\n'
