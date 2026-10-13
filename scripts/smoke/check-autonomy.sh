#!/usr/bin/env bash
#
# check-autonomy.sh — judges the --unattended run that `setup.sh --autonomy`
# printed, from GitHub and from the run's state directory, printing PASS or
# FAIL per assertion:
#
#   - the human-only issue was never in scope, never dispatched, has no PR;
#   - the independent, dependent and conflicting issues reached `done`, each
#     with a merged PR, and the dependent's and the conflict's PRs merged after
#     the independent one's (the Blocked by edge and the serialized conflict);
#   - the risky issue (it touches migrations/) reached `ready`, not `done`: its
#     PR is open, non-draft, labeled `awaiting-approval`, and its body names the
#     risk gate; nothing merged it;
#   - the summary was posted to the tracking issue.
#
# Usage: scripts/smoke/check-autonomy.sh <repo>   (<name> or <owner>/<name>)
# Read-only. Exit status: 0 all PASS, 1 any FAIL, 2 usage or environment error.
# Needs: bash, git, gh (authenticated), jq.

set -u

PREFIX=issue-runner-smoke-
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SMOKE_ROOT=${ISSUE_RUNNER_SMOKE_ROOT:-$HOME/issue-runner-smoke}
case $SMOKE_ROOT in /*) ;; *) SMOKE_ROOT="$PWD/$SMOKE_ROOT" ;; esac
RUN_STATE="$HERE/../../skills/issue-runner/scripts/run-state.sh"

die() { printf 'check-autonomy: %s\n' "$1" >&2; exit 2; }

[ $# -eq 1 ] || die "usage: check-autonomy.sh <repo>"
NAME=${1##*/}
case $NAME in "$PREFIX"?*) ;; *) die "'$1' is not a smoke repository (name must start with $PREFIX)" ;; esac
for c in git gh jq; do command -v "$c" >/dev/null 2>&1 || die "$c not found"; done
META="$SMOKE_ROOT/$NAME.env"
[ -f "$META" ] || die "$META not found (written by setup.sh)"
meta() { sed -n "s/^$1=//p" "$META" | head -1; }
REPO=$(meta repo) CLONE=$(meta clone) T=$(meta tracking)
A=$(meta independent) B=$(meta dependent) C=$(meta conflict) R=$(meta risky) H=$(meta human)
[ -n "$R" ] && [ -n "$H" ] || die "$META has no risky/human issues: was setup.sh run with --autonomy?"
STATE_DIR=$( (cd "$CLONE" && bash "$RUN_STATE" resolve) | sed -n 's/^state-dir //p')
[ -d "$STATE_DIR" ] || die "no run state at ${STATE_DIR:-?} (was the run started from $CLONE?)"

npass=0 nfail=0
pass() { printf 'PASS: %s\n' "$1"; npass=$((npass + 1)); }
fail() { printf 'FAIL: %s\n' "$1"; nfail=$((nfail + 1)); }
status_of() { local s; s=$( { tr -d "[:space:]" <"$STATE_DIR/issue-$1/status"; } 2>/dev/null); printf '%s\n' "${s:-pending}"; }
prs_of() {
  gh pr list --repo "$REPO" --state all --limit 100 --json number,headRefName \
    --jq ".[] | select(.headRefName | test(\"/issue-$1-\")) | .number"
}
merged_at() {  # <issue> -> mergedAt of its merged PR, or empty
  local p
  for p in $(prs_of "$1"); do
    gh pr view "$p" --repo "$REPO" --json state,mergedAt --jq 'select(.state=="MERGED") | .mergedAt'
  done | head -1
}

echo "repo $REPO; state $STATE_DIR"
echo "independent #$A, dependent #$B, conflict #$C, risky #$R, human #$H, tracking #$T"

# 1. human-only: excluded even though named explicitly.
SCOPE=$(tr -s ' \t\r,' '\n' <"$STATE_DIR/scope.txt" 2>/dev/null)
if grep -qx "$H" <<<"$SCOPE"; then fail "#$H (human-only) is not in scope.txt"; else pass "#$H (human-only) is not in scope.txt"; fi
if [ -z "$(prs_of "$H")" ] && [ ! -e "$STATE_DIR/issue-$H/result.json" ]; then pass "#$H was never dispatched (no PR, no result)"
else fail "#$H was never dispatched (found a PR or a result.json)"; fi

# 2. The three ordinary issues merged, in order.
for n in "$A" "$B" "$C"; do
  s=$(status_of "$n"); m=$(merged_at "$n")
  if [ "$s" = done ] && [ -n "$m" ]; then pass "#$n reached done with a merged PR ($m)"
  else fail "#$n reached done with a merged PR (status: $s; mergedAt: ${m:-none})"; fi
done
MA=$(merged_at "$A")
for n in "$B" "$C"; do
  m=$(merged_at "$n")
  if [ -n "$MA" ] && [ -n "$m" ] && [[ "$m" > "$MA" ]]; then pass "#$n merged after #$A"
  else fail "#$n merged after #$A (#$A: ${MA:-none}; #$n: ${m:-none})"; fi
done

# 3. The risky issue stopped at the risk gate.
SR=$(status_of "$R")
if [ "$SR" = ready ]; then pass "#$R (risky) landed ready, not done"; else fail "#$R (risky) landed ready, not done (status: $SR)"; fi
PR_R=$(cat "$STATE_DIR/issue-$R/pr" 2>/dev/null)
[ -n "$PR_R" ] || PR_R=$(prs_of "$R" | head -1)
if [ -n "$PR_R" ]; then
  j=$(gh pr view "$PR_R" --repo "$REPO" --json state,isDraft,labels,body) || die "cannot read PR #$PR_R"
  st=$(jq -r .state <<<"$j") dr=$(jq -r .isDraft <<<"$j")
  if [ "$st" = OPEN ] && [ "$dr" = false ]; then pass "#$R's PR #$PR_R is open and non-draft"; else fail "#$R's PR #$PR_R is open and non-draft (state=$st isDraft=$dr)"; fi
  if jq -e 'any(.labels[]; .name == "awaiting-approval")' <<<"$j" >/dev/null; then pass "PR #$PR_R is labeled awaiting-approval"; else fail "PR #$PR_R is labeled awaiting-approval"; fi
  if jq -r .body <<<"$j" | grep -q 'Risk gate: awaiting approval'; then pass "PR #$PR_R's body names the risk gate"; else fail "PR #$PR_R's body names the risk gate"; fi
else
  fail "#$R has a PR"
fi

# 4. The summary reached the tracking issue.
if gh issue view "$T" --repo "$REPO" --json comments --jq '.comments[].body' | grep -q 'issue-runner run'; then
  pass "the run summary was posted to tracking issue #$T"
else
  fail "the run summary was posted to tracking issue #$T"
fi

printf '\n%d passed, %d failed\n' "$npass" "$nfail"
[ "$nfail" -eq 0 ]
