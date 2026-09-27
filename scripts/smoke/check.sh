#!/usr/bin/env bash
#
# check.sh — the release smoke test's second half (README, "Release smoke test").
#
# After the human ran the `/issue-runner --no-merge` command setup.sh printed,
# checks the outcome from GitHub and from the run's state directory, printing
# PASS or FAIL per assertion:
#
#   - the independent issue reached `ready` with an open, non-draft, mergeable PR;
#     so did every other issue that reached `ready`, and none reached another
#     terminal or blocked status;
#   - the dependent issue is paused as `--no-merge` defines it (still `pending`
#     behind a `ready` dependency: no result.json, no PR on its /issue-N-
#     branch), or was dispatched only after its dependency's PR merged;
#   - the conflicting pair was serialized: recorded in conflicts.json, and the
#     conflicting issue is paused, or dispatched only after the independent
#     one's PR merged (a conflict is a `depends` edge, runner Step 2);
#   - every PR body carries `## Review notes` and a validation line naming
#     the contract's preflight (gh-issue Step 7);
#   - every dispatched issue's result.json exists and parses.
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

echo "repo $REPO; state $STATE_DIR"
echo "independent #$A, dependent #$B, conflict #$C"
[ -d "$STATE_DIR" ] || fail "state dir $STATE_DIR exists (was the run started from $CLONE?)"

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

# 1. Ready issues and their PRs.
SA=$(status_of "$A")
if [ "$SA" = ready ]; then
  PA=$(cat "$STATE_DIR/issue-$A/pr" 2>/dev/null)
  if [ -n "$PA" ]; then check_pr_ready "$A" "$PA"; else fail "#$A is ready but issue-$A/pr is missing"; fi
else
  fail "#$A (independent) reached ready (status: $SA)"
fi
for n in "$B" "$C"; do
  s=$(status_of "$n")
  case $s in
    ready)
      p=$(cat "$STATE_DIR/issue-$n/pr" 2>/dev/null)
      if [ -n "$p" ]; then check_pr_ready "$n" "$p"; else fail "#$n is ready but issue-$n/pr is missing"; fi ;;
    pending) ;;   # judged by the ordering assertions below
    *) fail "#$n reached ready or stayed paused (status: $s)" ;;
  esac
done

# 2. Ordering: a dependent of the independent issue (Blocked by, or the
# serialized conflict) is paused while it is `ready`, or was dispatched only
# after its PR merged.
A_MERGED=""
[ -n "${PA:-}" ] && A_MERGED=$(gh pr view "$PA" --repo "$REPO" --json mergedAt --jq '.mergedAt // "" | if . == "" then "" else fromdateiso8601 end')
check_waited() {  # <issue> <label>
  local n=$1 s prs first created
  s=$(status_of "$n")
  prs=$(prs_of "$n") || { fail "#$n: cannot list PRs"; return; }
  if [ "$s" = pending ] && [ -z "$prs" ] && [ ! -e "$STATE_DIR/issue-$n/result.json" ]; then
    pass "#$n $2: paused behind #$A (pending, never dispatched)"
    return
  fi
  if [ -z "$prs" ]; then
    fail "#$n $2: status $s with no PR - neither paused nor dispatched after #$A merged"
    return
  fi
  first=$(printf '%s\n' "$prs" | sort -n | head -1)
  created=$(gh pr view "$first" --repo "$REPO" --json createdAt --jq '.createdAt | fromdateiso8601') \
    || { fail "#$n: cannot read PR #$first"; return; }
  if [ -n "$A_MERGED" ] && [ "$created" -ge "$A_MERGED" ]; then
    pass "#$n $2: dispatched only after #$A's PR merged"
  else
    fail "#$n $2: PR #$first opened while #$A was unmerged (dispatched too early)"
  fi
}
check_waited "$B" "(dependent)"
if [ -f "$STATE_DIR/conflicts.json" ] \
   && jq -e --argjson a "$A" --argjson c "$C" \
        'any(.[]; (.a == $a and .b == $c) or (.a == $c and .b == $a))' "$STATE_DIR/conflicts.json" >/dev/null 2>&1; then
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
  if grep -qi 'preflight' <<<"$body"; then pass "PR #$p carries a validation line (names the contract's preflight)"
  else fail "PR #$p carries a validation line (names the contract's preflight)"; fi
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
