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
#   classify.sh result <N> <issue-dir>
#     <issue-dir> is $STATE_DIR/issue-N. Every input is read from a file there,
#     so the call is the same on every run and re-running it (a retry after a
#     failed query, Step 4's "Mark `done`") classifies the same inputs again:
#       worktree  the implementer's worktree path; absent or empty = none known
#                 (never `git -C ""`: it silently reads the cwd)
#       branch    Step 3a's recorded non-contract resume branch; absent = none
#       outcome   required, one word: merged | ready | blocker | failed —
#                 result.json's `outcome`, or the prose classification of the
#                 final message when that file is absent or unreadable;
#                 hung — stopped by Step 3 item 4; none — crashed
#       blocker   the implementer's `blocker` string or message, or item 4's
#                 hang string, verbatim; absent or empty = none. Untrusted text:
#                 the caller writes it as a file, never on a command line, where
#                 backticks and $(...) would run. Never modified here.
#     It writes one file, `error` (the final error text; removed when there is
#     none), and nothing else.
#
#   classify.sh pr-shape <N> <default-branch>
#     for an issue that is not `done` or `ready`: its open PR on the
#     `/issue-N-` branch contract, and its orphan branches (Step 3a probe 3)
#
# Output — `result` prints exactly one line, `<status> <pr>` (<pr> is the bare
# PR number, or `-`), and leaves the final error in <issue-dir>/error
# (<blocker> below is the `blocker` file's text):
#   done P               CLOSED, and a merged PR P on the proof branch whose
#                        headRefOid is the worktree's HEAD — the only status that
#                        authorizes Step 5's `git branch -D`; no error
#   closed-externally -  CLOSED without that proof (worktree gone, a branch outside
#                        the contract, another head's merged PR); error
#                        `closed without a merged implementer PR`
#   blocked P            open, with that proof; error `PR #P merged but issue still
#                        open — confirm and close by hand`, followed by `: <blocker>`
#                        when there is one, except for outcome `merged`
#   blocked -            open, no proof, outcome `blocker`, worktree real; error is
#                        <blocker>
#   ready P              open, no proof, outcome `ready`, and an open, non-draft PR P
#                        on the proof branch; no error
#   failed -             open, no proof, and outcome `failed`, `hung` or `none` — or
#                        outcome `blocker` with the worktree gone (an empty or
#                        unreadable branch); error is <blocker>. Outcome `merged`: error
#                        `result.json claims merged but no merged PR on <branch>`;
#                        outcome `ready`: `result.json claims ready but no open,
#                        non-draft PR on <branch>` (<branch> is the worktree's
#                        branch, `(none)` if gone)
#
# `pr-shape` prints one line per open contract PR and per orphan branch, or
# `none` when there is neither:
#   pr #P <branch> draft (checkpoint)                 body still has a `## Plan` heading and the
#                                                     branch holds only the checkpoint
#                                                     commit (1 commit ahead of the
#                                                     default branch)
#   pr #P <branch> draft (implemented, not ready)     any other draft
#   pr #P <branch> non-draft (checkpoint)             the same two shapes on a PR that is
#   pr #P <branch> non-draft (implemented, not ready) not a draft (checkpoint refused, a
#                                                     failed revert, or a crash inside
#                                                     the ready→merge window)
#   branch <B> branch only (no PR)                    a pushed `/issue-N-` branch with no
#                                                     PR at all, in any state (Step 3a's
#                                                     orphan)
#   branch <B> no open PR (only merged or closed PRs: #P …)
#                                                     a pushed branch whose PRs are all
#                                                     merged or closed: it may still hold
#                                                     work nobody merged
#
# Exit status: 0 with the lines above. Non-zero prints nothing on stdout,
# leaves `error` untouched, and is never a classification: 1 — a query failed
# (gh, the fetch, ls-remote, rev-list) or a state file could not be read or
# written: an environment failure; 2 — a usage error (including a missing or
# unknown `outcome`).
#
# Dependencies: bash 3.2, coreutils, grep, awk, git, gh (its built-in --jq only
# projects fields; every decision is made here).

set -u
set +e +o pipefail   # every exit status below is read explicitly

die()   { echo "classify.sh: $1" >&2; exit 1; }
usage() { echo "classify.sh: $1" >&2; exit 2; }

MODE=${1:-}
N=${2:-}
case $MODE in result|pr-shape) ;; *) usage "unknown mode '$MODE' (expected result or pr-shape)" ;; esac
case $N in ''|*[!0-9]*|0*) usage "issue number must be a positive integer, got '${N}'" ;; esac

# finish STATUS PR ERROR: rewrite the error file (through a temp file in the
# same directory, so a failed write never leaves it half-written), then print.
finish() {
  local tmp
  if [ -n "$3" ]; then
    tmp="$ERROR_FILE.classify.$$"
    # shellcheck disable=SC2015 # intended: clean up and die when either the write or the mv fails
    printf '%s\n' "$3" > "$tmp" && mv -f "$tmp" "$ERROR_FILE" \
      || { rm -f "$tmp"; die "cannot write $ERROR_FILE"; }
  else
    rm -f "$ERROR_FILE" || die "cannot remove $ERROR_FILE"
  fi
  echo "$1 $2"
}

# read_state NAME: a state file's content, "" when absent; exit 1 when unreadable
read_state() {
  [ -e "$DIR/$1" ] || return 0
  cat "$DIR/$1" || die "cannot read $DIR/$1"
}

classify_result() {
  local wt recorded outcome error
  local state wt_branch="" wt_head="" proof_branch="" merged_pr="" list pr draft
  [ -d "$DIR" ] || usage "not a directory: $DIR"
  wt=$(read_state worktree) || exit 1
  recorded=$(read_state branch) || exit 1
  outcome=$(read_state outcome) || exit 1
  error=$(read_state blocker) || exit 1
  outcome=$(printf '%s' "$outcome" | tr -d '[:space:]')
  case $outcome in merged|ready|blocker|failed|hung|none) ;; *) usage "missing or unknown outcome '$outcome' in $DIR/outcome" ;; esac

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
  [ -n "$wt_branch" ] && [ "$wt_branch" = "$(printf '%s' "$recorded" | tr -d '[:space:]')" ] && proof_branch=$wt_branch
  if [ -n "$proof_branch" ] && [ -n "$wt_head" ]; then
    list=$(gh pr list --head "$proof_branch" --state merged --json number,headRefOid \
      --jq '.[] | "\(.number) \(.headRefOid)"') || die "cannot list merged PRs on $proof_branch"
    # Anchored on this attempt's commit: a previous run's merged PR on a
    # recurring branch name is not this attempt's proof.
    merged_pr=$(printf '%s\n' "$list" | awk -v h="$wt_head" '$2 == h { print $1; exit }')
  fi

  if [ "$state" = CLOSED ]; then
    if [ -n "$merged_pr" ]; then finish "done" "$merged_pr" ""
    else finish closed-externally - "closed without a merged implementer PR"; fi
    return
  fi
  if [ -n "$merged_pr" ]; then
    local msg="PR #$merged_pr merged but issue still open — confirm and close by hand"
    [ "$outcome" != merged ] && [ -n "$error" ] && msg="$msg: $error"
    finish blocked "$merged_pr" "$msg"
    return
  fi
  case $outcome in
    blocker)
      if [ -n "$wt_branch" ]; then finish blocked - "$error"; else finish failed - "$error"; fi ;;
    failed|hung|none)
      finish failed - "$error" ;;
    merged)
      finish failed - "result.json claims merged but no merged PR on ${wt_branch:-(none)}" ;;
    ready)
      if [ -n "$proof_branch" ]; then
        list=$(gh pr list --head "$proof_branch" --state open --json number,isDraft \
          --jq '.[] | "\(.number) \(.isDraft)"') || die "cannot list open PRs on $proof_branch"
        pr=$(printf '%s\n' "$list" | awk 'NF { print $1; exit }')
        draft=$(printf '%s\n' "$list" | awk 'NF { print $2; exit }')
        if [ -n "$pr" ] && [ "$draft" = false ]; then finish ready "$pr" ""; return; fi
      fi
      finish failed - "result.json claims ready but no open, non-draft PR on ${wt_branch:-(none)}" ;;
  esac
}

classify_pr_shape() {
  local default="$1" list prs out="" p b view draft body count shape refs rc ref any
  [ -n "$default" ] || usage "empty default branch"
  list=$(gh pr list --state open --limit 1000 --json number,headRefName,isDraft \
    --jq '.[] | "\(.number) \(.headRefName) \(.isDraft)"') || die "cannot list open PRs"
  prs=$(printf '%s\n' "$list" | awk -v pat="/issue-$N-" 'NF && index($2, pat) { print $1, $2 }')

  while read -r p b; do
    [ -n "$p" ] || continue
    # Explicit destinations: a single-branch clone would fetch only into
    # FETCH_HEAD. Both refs: a stale default branch inflates the count.
    git fetch -q origin "+refs/heads/$default:refs/remotes/origin/$default" \
      "+refs/heads/$b:refs/remotes/origin/$b" </dev/null 2>/dev/null || die "cannot fetch origin/$default and origin/$b"
    count=$(git rev-list --count "origin/$default..origin/$b" </dev/null 2>/dev/null) || die "cannot count origin/$default..origin/$b"
    view=$(gh pr view "$p" --json isDraft,body --jq '.isDraft, .body' </dev/null) || die "cannot view PR #$p"
    draft=$(printf '%s\n' "$view" | head -n 1)
    body=$(printf '%s\n' "$view" | tail -n +2 | tr -d '\r')
    shape="implemented, not ready"
    if [ "$count" = 1 ] && printf '%s\n' "$body" | grep -qE '^## Plan([[:space:]]|$)'; then shape=checkpoint; fi
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
         any=$(gh pr list --head "$b" --state all --limit 1000 --json number --jq '.[] | .number' </dev/null) \
           || die "cannot list PRs on $b"
         if [ -n "$any" ]; then
           out="${out}branch $b no open PR (only merged or closed PRs: $(printf '%s' "$any" | awk 'NF { printf "%s#%s", (n++ ? " " : ""), $1 }'))"$'\n'
         else
           out="${out}branch $b branch only (no PR)"$'\n'
         fi
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
    [ $# -ge 3 ] && [ -n "$3" ] || usage "result needs <N> <issue-dir>"
    DIR=${3%/}; ERROR_FILE="$DIR/error"
    classify_result ;;
  pr-shape)
    [ $# -ge 3 ] || usage "pr-shape needs <N> <default-branch>"
    classify_pr_shape "$3" ;;
esac
