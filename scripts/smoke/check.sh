#!/usr/bin/env bash
#
# check.sh — the release smoke test's second half (README, "Release smoke test").
#
# After the human ran the `/issue-runner --no-merge` command setup.sh printed,
# checks the outcome from GitHub and from the run's state directory, printing
# PASS or FAIL per assertion:
#
#   - the run was a --no-merge run (integration-mode) that merged nothing, over
#     exactly the three issues (scope.txt, no tracking issue), with both edges on the independent issue
#     in dag.txt (the Blocked by and the serialized conflict);
#   - the independent issue reached `ready` with an open, non-draft, mergeable PR;
#   - the dependent issue is paused as `--no-merge` defines it: still `pending`
#     behind its `ready` dependency (no result.json, no PR on its /issue-N-
#     branch), never dispatched while that dependency is unmerged;
#   - the conflicting pair was serialized: recorded in conflicts.json, and the
#     conflicting issue paused behind the independent one the same way (a
#     conflict is a `depends` edge, runner Step 2);
#   - every open PR's body carries the review notes (issue #61): under
#     `## Review notes`, gh-issue's fixed line for each state its result.json
#     shows (inline Phase 1, a degraded, waived or capped gate, a revoked
#     profile); with none, the heading is optional, since gh-issue writes it
#     only for iteration history; and a `## Test plan` naming the contract's
#     validation, `preflight` or its command (gh-issue Step 7);
#   - every dispatched issue's result.json exists and is one result object
#     (an outcome of merged/blocker/failed/ready, a non-empty worktree).
#
# A NOTE line (not an assertion) says when the independent issue's
# `checkpoint` is `refused`: the draft PR or its push was refused (GitHub
# offers draft PRs in private repositories only on some plans), so the run
# took the no-draft path; its Step 10 report gives the reason.
#
# Run it right after the --no-merge run, before anything merges: once the
# independent PR is merged after the run (by hand or by --merge-ready) the
# outcome above no longer holds, and the script exits 2 instead of judging it.
# A merge by the run itself that result.json records (outcome `merged`) is a FAIL.
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
case $SMOKE_ROOT in /*) ;; *) SMOKE_ROOT="$PWD/$SMOKE_ROOT" ;; esac   # absolute: the .env records paths
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
  s=$( { tr -d "[:space:]" <"$STATE_DIR/issue-$1/status"; } 2>/dev/null)   # CR/space-tolerant (CRLF on WSL)
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

# This judges the --no-merge outcome only. A merge after the run (by hand, or
# --merge-ready, which never rewrites result.json) leaves #A's result.json at
# `ready`: too late to judge, so refuse. A merge by the run itself (outcome
# `merged`) is a --no-merge failure and is judged below.
A_PRS=$(prs_of "$A") || die "cannot list #$A's PRs"
A_MERGED=""
for p in $A_PRS; do
  [ "$(gh pr view "$p" --repo "$REPO" --json state --jq .state)" = MERGED ] && A_MERGED=$p
done
A_OUTCOME=$(jq -r '.outcome // ""' "$STATE_DIR/issue-$A/result.json" 2>/dev/null)
if { [ -n "$A_MERGED" ] || [ "$(status_of "$A")" = "done" ]; } && [ "$A_OUTCOME" = ready ]; then
  die "#$A was merged after the run: check.sh judges the --no-merge run before anything merges"
fi

echo "repo $REPO; state $STATE_DIR"
echo "independent #$A, dependent #$B, conflict #$C"

# 0. The run was a --no-merge run over the three issues, with the expected edges.
MODE=$(head -1 "$STATE_DIR/integration-mode" 2>/dev/null)
if [ "$MODE" = no-merge ]; then pass "the run was a --no-merge run (integration-mode)"
else fail "the run was a --no-merge run (integration-mode: ${MODE:-missing})"; fi
[ -z "$A_MERGED" ] || fail "#$A's PR #$A_MERGED was merged by the run (result.json outcome: ${A_OUTCOME:-missing})"
SCOPE=$(tr -s ' \t\r,' '\n' <"$STATE_DIR/scope.txt" 2>/dev/null)   # as integration.sh reads it
for n in "$A" "$B" "$C"; do
  if grep -qx "$n" <<<"$SCOPE"; then pass "#$n is in the run's scope.txt"
  else fail "#$n is in the run's scope.txt"; fi
done
EXTRA=$(grep -vxE "$A|$B|$C" <<<"$SCOPE" | grep . | tr '\n' ' ')
if [ -z "$EXTRA" ]; then pass "scope.txt holds only the three slices (no tracking issue)"
else fail "scope.txt holds only the three slices (also: $EXTRA)"; fi
# dag.txt: one `N: dep dep …` line per issue (runner Step 2).
for n in "$B" "$C"; do
  if { awk -F: -v n="$n" '{ gsub(/\r/, ""); k = $1; gsub(/[[:space:]]/, "", k); if (k == n) print $2 }' \
         "$STATE_DIR/dag.txt"; } 2>/dev/null | tr -s ' \t' '\n' | grep -qx "$A"; then
    pass "dag.txt: #$n depends on #$A"
  else
    fail "dag.txt: #$n depends on #$A"
  fi
done

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

# 3. PR bodies of the open PRs (a closed one is an abandoned attempt).
PRS=$(gh pr list --repo "$REPO" --state open --limit 100 --json number --jq '.[].number') || die "cannot list open PRs of $REPO"
[ -n "$PRS" ] || fail "the run left at least one open PR"
for p in $PRS; do
  pj=$(gh pr view "$p" --repo "$REPO" --json body,headRefName) || { fail "PR #$p body cannot be read"; continue; }
  body=$(jq -r .body <<<"$pj" | tr -d '\r')
  # gh-issue reserves ## Review notes for iteration history and requires a line
  # there only for these result.json states (one line per state, its fixed
  # wording); with none of them a clean PR may have no such heading.
  n=$(jq -r .headRefName <<<"$pj" | sed -n 's|.*/issue-\([0-9][0-9]*\)-.*|\1|p')
  need=$(jq -r 'if .phase1_inline == true then "run inline" else empty end,
                if .gate_state == "degraded" then "Codex gate unavailable (credit/quota)" else empty end,
                if .gate_state == "waived" then "Codex gate waived" else empty end,
                if .gate_state == "cap-stop" then "Codex gate cap-stop" else empty end,
                if .review_profile == "revoked" then "Review profile prose revoked" else empty end' \
          "$STATE_DIR/issue-$n/result.json" 2>/dev/null) || need="(no readable issue-$n/result.json)"
  notes=$(awk '/^## /{f = ($0 == "## Review notes")} f' <<<"$body")
  missing=""
  while IFS= read -r line; do
    [ -n "$line" ] && ! grep -qF -- "$line" <<<"$notes" && missing="${missing:+$missing; }$line"
  done <<<"$need"
  if [ -n "$missing" ]; then fail "PR #$p's ## Review notes carry what its result.json requires (missing: $missing)"
  elif [ -n "$notes" ]; then pass "PR #$p carries ## Review notes"
  else pass "PR #$p carries the review notes its run requires (none: its result.json records no state gh-issue notes there)"; fi
  # gh-issue Step 7: the Test plan names the validation that ran.
  if awk '/^## /{f = ($0 == "## Test plan")} f' <<<"$body" | grep -Eqi 'preflight|bash test\.sh'; then
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
  elif ! jq -se 'length == 1 and (.[0] | type == "object"
                   and (.outcome == "merged" or .outcome == "blocker" or .outcome == "failed" or .outcome == "ready")
                   and ((.worktree // "") != ""))' "$f" >/dev/null 2>&1; then
    fail "#$n result.json parses as one result object (outcome, worktree)"
  elif [ "$s" = ready ] && [ "$(jq -r .outcome "$f")" != ready ]; then
    fail "#$n result.json outcome is ready (got $(jq -r .outcome "$f"))"
  else
    pass "#$n result.json exists and parses"
  fi
done

CKPT=$(jq -r '.checkpoint // ""' "$STATE_DIR/issue-$A/result.json" 2>/dev/null)
[ "$CKPT" != refused ] \
  || printf 'NOTE: #%s checkpoint: refused - the draft PR or its push was refused (see the run report), so the run took the no-draft path\n' "$A"

[ "$CKPT" != skipped ] \
  || printf 'NOTE: #%s checkpoint: skipped - the implementer did not run the Step 4 checkpoint (not a refused push)\n' "$A"

printf '\n%d passed, %d failed\n' "$npass" "$nfail"
[ "$nfail" -eq 0 ]
