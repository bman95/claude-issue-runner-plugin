#!/usr/bin/env bash
#
# check.sh — the release smoke test's second half (README, "Release smoke test").
#
# After the human ran the `/issue-runner --no-merge` command setup.sh printed,
# checks the outcome from GitHub and from the run's state directory, printing
# PASS or FAIL per assertion:
#
#   - the independent issue reached `ready` with an open, non-draft, mergeable PR;
#   - the dependent issue is paused as `--no-merge` defines it: still `pending`
#     behind its `ready` dependency (no result.json, no PR on its /issue-N-
#     branch), never dispatched while that dependency is unmerged;
#   - the conflicting pair was serialized: recorded in conflicts.json, and the
#     conflicting issue paused behind the independent one the same way (a
#     conflict is a `depends` edge, runner Step 2);
#   - every PR body carries `## Review notes` and a validation line naming
#     the contract's preflight (gh-issue Step 7);
#   - every dispatched issue's result.json exists and parses.
#
# Run it right after the --no-merge run, before anything merges: once the
# independent PR is merged (by hand or by --merge-ready) the outcome above no
# longer holds, and the script exits 2 instead of judging it.
#
# Usage: scripts/smoke/check.sh <repo>   (<name> or <owner>/<name>, as setup.sh printed)
#
# Reads $ISSUE_RUNNER_SMOKE_ROOT/<name>.env (default ~/issue-runner-smoke)
# written by setup.sh, and finds the run's state the way the runner does
# (skills/issue-runner/scripts/run-state.sh resolve, from the local clone).
# Read-only. Exit status: 0 all PASS, 1 any FAIL, 2 usage or environment error.
#
# Needs: bash, git, gh (authenticated), jq.

set -u

PREFIX=issue-runner-smoke-
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SMOKE_ROOT=${ISSUE_RUNNER_SMOKE_ROOT:-$HOME/issue-runner-smoke}
RUN_STATE="$HERE/../../skills/issue-runner/scripts/run-state.sh"

die() { printf 'check: %s\n' "$1" >&2; exit 2; }

[ $# -eq 1 ] || die "usage: check.sh <repo>"
NAME=${1##*/}
case $NAME in "$PREFIX"?*) ;; *) die "'$1' is not a smoke repository (name must start with $PREFIX)" ;; esac
for c in git gh jq; do command -v "$c" >/dev/null 2>&1 || die "$c not found"; done
META="$SMOKE_ROOT/$NAME.env"
[ -f "$META" ] || die "$META not found (written by setup.sh; set ISSUE_RUNNER_SMOKE_ROOT if you moved it)"

meta() { sed -n "s/^$1=//p" "$META" | head -1; }
REPO=$(meta repo) CLONE=$(meta clone)
A=$(meta independent) B=$(meta dependent) C=$(meta conflict)
[ -n "$REPO" ] && [ -n "$CLONE" ] && [ -n "$A" ] && [ -n "$B" ] && [ -n "$C" ] || die "$META is incomplete"
case $1 in */*) [ "$1" = "$REPO" ] || die "'$1' does not match $META's repo=$REPO" ;; esac
STATE_DIR=$( (cd "$CLONE" && bash "$RUN_STATE" resolve) | sed -n 's/^state-dir //p')
[ -n "$STATE_DIR" ] || die "cannot resolve the run's state dir from $CLONE"

npass=0 nfail=0
pass() { printf 'PASS: %s\n' "$1"; npass=$((npass + 1)); }
fail() { printf 'FAIL: %s\n' "$1"; nfail=$((nfail + 1)); }

[ -d "$STATE_DIR" ] || die "no run state at $STATE_DIR (was the run started from $CLONE?)"

status_of() {  # absent or empty = pending, as the scheduler reads it
  local s
  s=$(cat "$STATE_DIR/issue-$1/status" 2>/dev/null)
  printf '%s\n' "${s:-pending}"
}
# PR numbers on issue N's branch contract (/issue-N-), any state.
prs_of() {
  gh pr list --repo "$REPO" --state all --limit 100 --json number,headRefName \
    --jq ".[] | select(.headRefName | test(\"/issue-$1-\")) | .number"
}

# An open, non-draft, mergeable PR. GitHub computes mergeability lazily:
# UNKNOWN is re-asked for up to a minute.
check_pr_ready() {  # <issue> <pr>
  local j state draft mergeable i
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    j=$(gh pr view "$2" --repo "$REPO" --json state,isDraft,mergeable) || { fail "#$1: PR #$2 cannot be read"; return; }
    mergeable=$(jq -r .mergeable <<<"$j")
    [ "$mergeable" = UNKNOWN ] && [ "$i" -lt 12 ] && { sleep 5; continue; }
    break
  done
  state=$(jq -r .state <<<"$j") draft=$(jq -r .isDraft <<<"$j")
  if [ "$state" = OPEN ] && [ "$draft" = false ] && [ "$mergeable" = MERGEABLE ]; then
    pass "#$1 reached ready with an open, non-draft, mergeable PR #$2"
  else
    fail "#$1: PR #$2 is state=$state isDraft=$draft mergeable=$mergeable (want OPEN, false, MERGEABLE)"
  fi
}

# This judges the --no-merge outcome only: refuse once the independent PR merged.
A_PRS=$(prs_of "$A") || die "cannot list #$A's PRs"
for p in $A_PRS; do
  [ "$(gh pr view "$p" --repo "$REPO" --json state --jq .state)" = MERGED ] \
    && die "#$A's PR #$p is already merged: check.sh judges the --no-merge run before anything merges"
done
[ "$(status_of "$A")" = "done" ] && die "#$A is already done: check.sh judges the --no-merge run before anything merges"

echo "repo $REPO; state $STATE_DIR"
echo "independent #$A, dependent #$B, conflict #$C"

# 1. The independent issue is ready, its PR open, non-draft and mergeable.
SA=$(status_of "$A")
if [ "$SA" = ready ]; then
  PA=$(cat "$STATE_DIR/issue-$A/pr" 2>/dev/null)
  if [ -n "$PA" ]; then check_pr_ready "$A" "$PA"; else fail "#$A is ready but issue-$A/pr is missing"; fi
else
  fail "#$A (independent) reached ready (status: $SA)"
fi

# 2. Ordering: under --no-merge a dependent of a `ready` issue (Blocked by, or
# the serialized conflict) stays pending, never dispatched (runner Step 3).
check_waited() {  # <issue> <label>
  local n=$1 s prs
  s=$(status_of "$n")
  prs=$(prs_of "$n") || { fail "#$n: cannot list PRs"; return; }
  if [ "$s" = pending ] && [ -z "$prs" ] && [ ! -e "$STATE_DIR/issue-$n/result.json" ]; then
    pass "#$n $2: paused behind ready #$A (pending, never dispatched)"
  else
    fail "#$n $2: dispatched while #$A was unmerged (status: $s; PRs: ${prs:-none})"
  fi
}
check_waited "$B" "(dependent)"
if [ -f "$STATE_DIR/conflicts.json" ] \
   && jq -e --arg a "$A" --arg c "$C" \
        'any(.[]; ((.a|tostring) == $a and (.b|tostring) == $c) or ((.a|tostring) == $c and (.b|tostring) == $a))' \
        "$STATE_DIR/conflicts.json" >/dev/null 2>&1; then
  pass "conflicts.json records #$A/#$C"
else
  fail "conflicts.json records #$A/#$C (the Files likely touched: overlap)"
fi
check_waited "$C" "(conflict)"

# 3. PR bodies.
PRS=$(gh pr list --repo "$REPO" --state all --limit 100 --json number --jq '.[].number') || PRS=""
[ -n "$PRS" ] || fail "the run opened at least one PR"
for p in $PRS; do
  body=$(gh pr view "$p" --repo "$REPO" --json body --jq .body) || { fail "PR #$p body cannot be read"; continue; }
  if grep -qx '## Review notes' <<<"$body"; then pass "PR #$p carries ## Review notes"
  else fail "PR #$p carries ## Review notes"; fi
  # gh-issue Step 7: the Test plan names the validation that ran.
  if awk '/^## /{f = ($0 == "## Test plan")} f' <<<"$body" | grep -qi 'preflight'; then
    pass "PR #$p carries a validation line (its Test plan names the contract's preflight)"
  else fail "PR #$p carries a validation line (its Test plan names the contract's preflight)"; fi
done

# 4. result.json of every dispatched issue.
for n in "$A" "$B" "$C"; do
  s=$(status_of "$n")
  f="$STATE_DIR/issue-$n/result.json"
  if [ "$s" = pending ] && [ ! -e "$f" ]; then continue; fi   # never dispatched
  if [ ! -f "$f" ]; then
    fail "#$n result.json exists (status: $s)"
  elif ! jq -e 'type == "object" and has("outcome")' "$f" >/dev/null 2>&1; then
    fail "#$n result.json parses as a result object"
  elif [ "$s" = ready ] && [ "$(jq -r .outcome "$f")" != ready ]; then
    fail "#$n result.json outcome is ready (got $(jq -r .outcome "$f"))"
  else
    pass "#$n result.json exists and parses"
  fi
done

printf '\n%d passed, %d failed\n' "$npass" "$nfail"
[ "$nfail" -eq 0 ]
