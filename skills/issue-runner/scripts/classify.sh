#!/usr/bin/env bash
#
# classify.sh — issue-runner's two classifications of what an unfinished or
# returned issue *is*: Step 3 item 5's merge proof (`result`) and Step 5's
# unfinished-PR shape (`pr-shape`). SKILL.md runs this script and obeys its
# output; the rules live here, and the rationale in REFERENCE.md ("Why `done`
# needs merge proof", "Why the implementer opens a draft PR right after the
# plan").
#
# Run from the target repository (the orchestrator's own cwd, never a
# worktree): the `gh` calls resolve the repository from it, and `pr-shape`
# fetches and probes its `origin`.
#
# Usage:
#   classify.sh result <N> <worktree> <recorded-branch> <outcome> [<error>]
#     <worktree>         the implementer's worktree path, or "" when none is known
#                        (never run `git -C ""`: it silently reads the cwd)
#     <recorded-branch>  $STATE_DIR/issue-N/branch (Step 3a's non-contract resume
#                        branch), or ""
#     <outcome>          merged | ready | blocker | failed — result.json's
#                        `outcome`, or the prose classification of the final
#                        message when the file is absent or unreadable;
#                        hung — stopped by Step 3 item 4;
#                        none — crashed, nothing to classify
#     <error>            the implementer's `blocker` string or message, or item
#                        4's hang string; "" when there is none. Newlines, CRs
#                        and tabs are collapsed to spaces so the line stays one line.
#
#   classify.sh pr-shape <N> <default-branch>
#     for an issue that is not `done` or `ready`: its open PR on the
#     `/issue-N-` branch contract, and its orphan branches (Step 3a probe 3)
#
# Output — `result` prints exactly one line, `<status> <pr> <error>` (<pr> is
# `#P` or `-`; <error> is the rest of the line, possibly empty):
#   done #P                     CLOSED, and a merged PR on the proof branch whose
#                               headRefOid is the worktree's HEAD — the only
#                               status that authorizes Step 5's `git branch -D`
#   closed-externally - closed without a merged implementer PR
#                               CLOSED without that proof (worktree gone, a branch
#                               outside the contract, another head's merged PR)
#   blocked #P PR #P merged but issue still open — confirm and close by hand[: <error>]
#                               open, with that proof; the suffix carries <error>
#                               when there is one, except for outcome `merged`
#   blocked - <error>           open, no proof, outcome `blocker`, worktree real
#   ready #P                    open, no proof, outcome `ready`, and an open,
#                               non-draft PR #P on the proof branch
#   failed - <error>            open, no proof, and outcome `failed`, `hung` or
#                               `none` — or outcome `blocker` with the worktree
#                               gone (an empty or unreadable branch)
#   failed - result.json claims merged but no merged PR on <branch>
#   failed - result.json claims ready but no open, non-draft PR on <branch>
#                               <branch> is the worktree's branch, `(none)` if gone
#
# `pr-shape` prints one line per open contract PR and per orphan branch, or
# `none` when there is neither:
#   pr #P <branch> draft (checkpoint)                 body still has `## Plan` and the
#                                                     branch holds only the checkpoint
#                                                     commit (1 commit ahead of the
#                                                     default branch)
#   pr #P <branch> draft (implemented, not ready)     any other draft
#   pr #P <branch> non-draft (checkpoint)             the same two shapes on a PR that is
#   pr #P <branch> non-draft (implemented, not ready) not a draft (checkpoint refused, a
#                                                     failed revert, or a crash inside
#                                                     the ready→merge window)
#   branch <B> branch only (no PR)                    a pushed `/issue-N-` branch with no
#                                                     open PR on it
#
# Exit status: 0 with the lines above. Non-zero prints nothing on stdout and
# is never a classification: 1 — a query failed (gh, the fetch, ls-remote,
# rev-list): an environment failure; 2 — a usage error.
#
# Dependencies: bash 3.2, coreutils, grep, awk, git, gh (its built-in --jq only
# projects fields; every decision is made here).

set -u
set +e +o pipefail   # every exit status below is read explicitly

die()   { echo "classify.sh: $1" >&2; exit 1; }
usage() { echo "classify.sh: $1" >&2; exit 2; }

MODE=${1:-}
N=${2:-}
case $N in ''|*[!0-9]*) usage "issue number must be a positive integer, got '${N}'" ;; esac

classify_result() {
  local wt="$1" recorded="$2" outcome="$3" error="$4"
  local state wt_branch="" wt_head="" proof_branch="" merged_pr="" list pr draft
  case $outcome in merged|ready|blocker|failed|hung|none) ;; *) usage "unknown outcome '$outcome'" ;; esac
  error=$(printf '%s' "$error" | tr '\r\n\t' '   ')

  state=$(gh issue view "$N" --json state --jq .state) || die "cannot query the state of issue #$N"
  case $state in OPEN|CLOSED) ;; *) die "unexpected state '$state' for issue #$N" ;; esac

  if [ -n "$wt" ]; then
    wt_branch=$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null) || wt_branch=""
    wt_head=$(git -C "$wt" rev-parse HEAD 2>/dev/null) || wt_head=""
  fi
  # The proof branch: the /issue-N- contract (gh-issue Step 4), or the branch
  # Step 3a recorded for a keyword-only resume. Never empty into the query:
  # `gh pr list --head ""` applies no filter and returns unrelated merged PRs.
  case $wt_branch in */issue-"$N"-*) proof_branch=$wt_branch ;; esac
  [ -n "$wt_branch" ] && [ "$wt_branch" = "$recorded" ] && proof_branch=$wt_branch
  if [ -n "$proof_branch" ] && [ -n "$wt_head" ]; then
    list=$(gh pr list --head "$proof_branch" --state merged --json number,headRefOid \
      --jq '.[] | "\(.number) \(.headRefOid)"') || die "cannot list merged PRs on $proof_branch"
    # Anchored on this attempt's commit: a previous run's merged PR on a
    # recurring branch name is not this attempt's proof.
    merged_pr=$(printf '%s\n' "$list" | awk -v h="$wt_head" '$2 == h { print $1; exit }')
  fi

  if [ "$state" = CLOSED ]; then
    if [ -n "$merged_pr" ]; then echo "done #$merged_pr"
    else echo "closed-externally - closed without a merged implementer PR"; fi
    return
  fi
  if [ -n "$merged_pr" ]; then
    local msg="PR #$merged_pr merged but issue still open — confirm and close by hand"
    [ "$outcome" != merged ] && [ -n "$error" ] && msg="$msg: $error"
    echo "blocked #$merged_pr $msg"
    return
  fi
  case $outcome in
    blocker)
      if [ -n "$wt_branch" ]; then echo "blocked - $error"; else echo "failed - $error"; fi ;;
    failed|hung|none)
      echo "failed - $error" ;;
    merged)
      echo "failed - result.json claims merged but no merged PR on ${wt_branch:-(none)}" ;;
    ready)
      if [ -n "$proof_branch" ]; then
        list=$(gh pr list --head "$proof_branch" --state open --json number,isDraft \
          --jq '.[] | "\(.number) \(.isDraft)"') || die "cannot list open PRs on $proof_branch"
        pr=$(printf '%s\n' "$list" | awk 'NF { print $1; exit }')
        draft=$(printf '%s\n' "$list" | awk 'NF { print $2; exit }')
        if [ -n "$pr" ] && [ "$draft" = false ]; then echo "ready #$pr"; return; fi
      fi
      echo "failed - result.json claims ready but no open, non-draft PR on ${wt_branch:-(none)}" ;;
  esac
}

classify_pr_shape() {
  local default="$1" list prs out="" p b view draft body count shape refs rc ref
  [ -n "$default" ] || usage "empty default branch"
  list=$(gh pr list --state open --json number,headRefName,isDraft \
    --jq '.[] | "\(.number) \(.headRefName) \(.isDraft)"') || die "cannot list open PRs"
  prs=$(printf '%s\n' "$list" | awk -v pat="/issue-$N-" 'NF && index($2, pat) { print $1, $2 }')

  while read -r p b; do
    [ -n "$p" ] || continue
    # Explicit destinations: a single-branch clone would fetch only into
    # FETCH_HEAD. Both refs: a stale default branch inflates the count.
    git fetch -q origin "+refs/heads/$default:refs/remotes/origin/$default" \
      "+refs/heads/$b:refs/remotes/origin/$b" 2>/dev/null || die "cannot fetch origin/$default and origin/$b"
    count=$(git rev-list --count "origin/$default..origin/$b" 2>/dev/null) || die "cannot count origin/$default..origin/$b"
    view=$(gh pr view "$p" --json isDraft,body --jq '.isDraft, .body') || die "cannot view PR #$p"
    draft=$(printf '%s\n' "$view" | head -n 1)
    body=$(printf '%s\n' "$view" | tail -n +2 | tr -d '\r')
    shape="implemented, not ready"
    if [ "$count" = 1 ] && printf '%s\n' "$body" | grep -qE '^## Plan[[:space:]]*$'; then shape=checkpoint; fi
    case $draft in
      true)  out="${out}pr #$p $b draft ($shape)"$'\n' ;;
      false) out="${out}pr #$p $b non-draft ($shape)"$'\n' ;;
      *)     die "unexpected isDraft '$draft' for PR #$p" ;;
    esac
  done <<EOF_PRS
$prs
EOF_PRS

  # Probe 3 (Step 3a): exit 2 = no such branch, 0 = hits, anything else = the
  # probe itself failed — never read as "no branch".
  refs=$(git ls-remote --exit-code --heads origin "*/issue-$N-*" 2>/dev/null); rc=$?
  case $rc in
    0) while read -r _ ref; do
         b=${ref#refs/heads/}
         [ -n "$b" ] || continue
         printf '%s\n' "$prs" | awk -v b="$b" '$2 == b { f = 1 } END { exit !f }' && continue
         out="${out}branch $b branch only (no PR)"$'\n'
       done <<EOF_REFS
$refs
EOF_REFS
       ;;
    2) ;;
    *) die "probe 3 failed (git ls-remote exit $rc)" ;;
  esac

  if [ -n "$out" ]; then printf '%s' "$out"; else echo none; fi
}

case $MODE in
  result)
    [ $# -ge 5 ] || usage "result needs <N> <worktree> <recorded-branch> <outcome> [<error>]"
    classify_result "$3" "$4" "$5" "${6:-}" ;;
  pr-shape)
    [ $# -ge 3 ] || usage "pr-shape needs <N> <default-branch>"
    classify_pr_shape "$3" ;;
  *) usage "unknown mode '$MODE' (expected result or pr-shape)" ;;
esac
