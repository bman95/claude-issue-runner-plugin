#!/usr/bin/env bash
#
# merge-ready.sh — the mechanical part of issue-runner's `--merge-ready` pass
# (Step 3): a `ready` PR's own state, the refresh of its worktree against the PR
# head and the base branch, the checks re-check, and the head-pinned merge.
# SKILL.md runs these in order and decides what each line means for the issue
# (its status, the Step 5 summary wording); the mechanics live here, and the
# rationale in REFERENCE.md ("Why `--merge-ready` refreshes before it merges").
#
# Usage:
#   merge-ready.sh state <P>
#   merge-ready.sh refresh <worktree> <P> <validation-script> [--fallback-cmd <command>]
#   merge-ready.sh checks <P> [--refreshed]
#   merge-ready.sh merge <P> <oid>
#
# `state`, `checks` and `merge` run from the target repository (the
# orchestrator's cwd): `gh` resolves the repository from it. `refresh` runs
# from anywhere — it works inside <worktree> through its own subshells and never
# changes its caller's directory.
#
# Every subcommand prints exactly one line on stdout. `refresh` streams the
# validation's own output to stderr as it runs (never buffered to the end of a
# mode: the SKILL's stall rule watches that output grow).
#
# state <P> — the PR's state:
#   open | merged | closed
#
# refresh <worktree> <P> <validation-script> [--fallback-cmd <command>]
#   <worktree>           the issue's recorded worktree ($STATE_DIR/issue-N/worktree)
#   <validation-script>  gh-issue's validation-contract.sh (the #53 script): an
#                        absolute path to an existing file outside <worktree> —
#                        a copy inside it is one the PR controls
#   --fallback-cmd       the project's own test command, run through `bash -c`
#                        from the worktree root only when the base branch carries
#                        no validation contract (the script prints its
#                        `fallback` line); `changed` still runs either way
#   In order, stopping at the first failure:
#     1. the worktree exists and is a git checkout's root, else worktree-missing
#     2. a clean tree (`git status --porcelain` empty), else stuck: a
#        fast-forward succeeds over non-overlapping edits and validation runs on
#        the working tree, so nothing later would notice them. Never reset.
#     3. the PR's headRefName/headRefOid/baseRefName (`gh pr view`); the worktree
#        must be on headRefName, else worktree-missing (another checkout).
#        Without --fallback-cmd, the script's `check` runs here: no contract
#        on the base stops the call before anything in the worktree moves, so
#        the retry with --fallback-cmd still reports a head sync as `refreshed`
#     4. head sync: fetch the head ref (three tries), and when HEAD is not
#        headRefOid, fast-forward to it only if HEAD is its ancestor; a worktree
#        that carries commits the PR does not, or has diverged, is stuck, never
#        reset
#     5. base freshness (gh-issue Step 9's recipe): fetch the base (three tries);
#        when it advanced past the merge-base, merge it in unconditionally —
#        never gated on file overlap. A conflict is aborted, never resolved.
#     6. validation on the current head, from the worktree: the script's
#        `changed`, then `preflight`, then `full` (the script itself reports
#        `full not declared`), each with the PR's base branch as its argument
#     7. push only what the base merge produced (`git push origin
#        HEAD:refs/heads/<headRefName>`, never forced)
#   From the head sync on (the tree verified clean before it), every failure —
#   and a TERM, INT or HUP — first puts the worktree back where this pass found
#   it (`git merge --abort` if one is in progress, then `git reset --hard` to
#   the starting HEAD): an unpushed merge commit left checked out would keep
#   every later pass stuck at the fast-forward, and a kept fast-forward would
#   make the re-run report `unchanged` for a head new to it. Nothing is ever
#   pushed on a failure, and the PR's draft state is never touched. The trap
#   runs once the current command returns: at once when the whole process
#   group is signalled, after the running validation step otherwise.
#   Output:
#     unchanged <oid>        already at headRefOid and the base had not advanced;
#                            validation passed; nothing pushed
#     refreshed <oid>        the sync fast-forwarded to a head pushed from
#                            elsewhere, or the base merge was pushed; validation
#                            passed on <oid>
#                            (<oid> is `git rev-parse HEAD` after the sync, after
#                            the push for `refreshed`: the merge pins it)
#     worktree-missing <reason>
#     stuck <reason>, one of:
#       worktree dirty — a human must reconcile
#       cannot resolve the PR head — query or fetch failed
#       worktree not at the PR head and cannot fast-forward to it — a human must reconcile
#       cannot fetch the base branch origin/<base>
#       no merge-base with origin/<base>
#       merge conflict with origin/<base>: <paths>
#       base merge did not start: <git's first error line>
#       contract changed after ready — a human must review and merge   (`changed` exit 5)
#       <mode> validation failed (exit 1)
#       validation contract invalid (exit 3)
#       validation command not runnable (exit 4): <mode>
#       cannot resolve the base branch (validation exit 2)
#       no validation contract and no --fallback-cmd given
#       fallback tests failed (exit <N>)
#       cannot record the validation output — temporary file failed
#       validation script unavailable or miscalled — a human must fix the install
#                            (a path that is not absolute, names no file or lies
#                            inside the worktree, or any other exit: 6, 7, 126, …)
#       validation moved HEAD off the validated head — a human must reconcile
#       push failed after refresh — a human must retry or merge by hand
#       refresh interrupted before it finished — re-run it   (TERM, INT or HUP)
#     A reason gains `; reset failed` when putting the worktree back failed.
#
# checks <P> [--refreshed] — the plain (non-`--watch`) three-way check gh-issue
# Step 9 computes: `gh pr checks` exit 0 → pass; its output matching `no checks
# reported` → none; anything else (red, or still pending) → fail. With
# --refreshed (the head is new to this run), a `none` is re-polled up to six
# times, ten seconds apart, until CI registers the new head:
#   pass | none | none-after-refresh | fail
#   (none-after-refresh: still `none` after that bound — merge as `none`, but
#   say so)
#
# merge <P> <oid> — gh-issue Step 9's merge: `gh pr merge --squash
# --delete-branch --match-head-commit <oid>`, the subject the PR title and the
# body the PR body above `## Review notes`; then `gh pr view` must report
# MERGED, whatever `gh pr merge` exited with (its local-branch delete fails
# while a worktree holds the branch, after the server-side merge). Never
# retried.
#   merged <sha>                    <sha> is the merge commit, or `unknown` when
#                                   only its oid could not be read: the PR is
#                                   still verified MERGED
#   skipped head moved after validation
#                                   the PR head is no longer <oid>: GitHub
#                                   refused a head nobody validated
#   skipped merge did not land (state <S>): <gh's first error line>
#
# Exit status: 0 with the lines above (stuck, worktree-missing and skipped are
# verdicts; a `gh pr checks` that fails for any reason is `fail`, which only
# ever defers a merge). 1 — `state` could not query GitHub or read an
# unrecognized state (an environment failure, never a verdict: an unreadable
# state is never read as open); 2 — a usage error.
#
# Dependencies: bash 3.2, coreutils, grep, awk, git, gh (its built-in --jq only
# projects fields; every decision is made here).

set -u
set +e +o pipefail   # every exit status below is read explicitly

die()   { echo "merge-ready.sh: $1" >&2; exit 1; }
usage() { echo "merge-ready.sh: $1" >&2; exit 2; }
pr_arg() { case $1 in ''|*[!0-9]*|0*) usage "PR number must be a positive integer, got '$1'" ;; esac; }

# The registration poll's pause, in seconds. Tests set it to 0.
POLL_SLEEP=${MERGE_READY_POLL_SLEEP:-10}

# fetch3 REF: fetch origin's REF into its remote-tracking ref, three tries (a
# sibling worktree's simultaneous fetch can hold the shared ref lock once)
fetch3() {
  local i
  for i in 1 2 3; do
    git fetch -q origin "+refs/heads/$1:refs/remotes/origin/$1" </dev/null 2>/dev/null && return 0
    [ "$i" -lt 3 ] && sleep 1
  done
  return 1
}

cmd_state() {
  local s
  s=$(gh pr view "$1" --json state --jq .state </dev/null) || die "cannot query the state of PR #$1"
  case $s in
    OPEN) echo open ;;
    MERGED) echo merged ;;
    CLOSED) echo closed ;;
    *) die "unexpected state '$s' for PR #$1" ;;
  esac
}

cmd_refresh() {
  local wt=$1 p=$2 vs=$3 fallback=$4 have_fallback=$5
  local top view head_ref head_oid base cur mb count merged=0 moved=0 out rc mode conflicts log
  local start_oid="" touched=0 merge_oid="" first

  # Result lines. Once this pass has touched the worktree (from the head sync
  # on, the tree verified clean before it), every failure first puts it back
  # where this pass found it: an unpushed merge commit left checked out would
  # put HEAD ahead of the PR head and every later pass would be stuck at the
  # fast-forward, and a kept fast-forward would make the re-run report
  # `unchanged` for a head that is new to it.
  stuck() {
    local reason=$1
    trap '' TERM INT HUP   # finish the rollback and print one line, whatever arrives now
    if [ "$touched" -eq 1 ]; then
      git -C "$top" merge --abort </dev/null >/dev/null 2>&1
      git -C "$top" reset -q --hard "$start_oid" </dev/null >/dev/null 2>&1 || reason="$reason; reset failed"
    fi
    echo "stuck $reason"; exit 0
  }
  # A refresh stopped mid-run does the same. Bash runs the trap once the
  # current command returns: at once when the whole process group is signalled
  # (the host's stop primitive), after the running validation step otherwise.
  trap 'stuck "refresh interrupted before it finished — re-run it"' TERM INT HUP

  # The recorded path must itself be a checkout's root: a leftover plain
  # directory inside another repository resolves to that repository.
  if [ ! -d "$wt" ] || ! top=$(git -C "$wt" rev-parse --show-toplevel 2>/dev/null) || [ -z "$top" ] \
     || [ "$(cd "$wt" && pwd -P)" != "$(cd "$top" && pwd -P)" ]; then
    echo "worktree-missing $wt no longer exists or is not a git checkout"; exit 0
  fi
  case $vs in /*) ;; *) stuck "validation script unavailable or miscalled — a human must fix the install" ;; esac
  case $vs in "$top"/*) stuck "validation script unavailable or miscalled — a human must fix the install" ;; esac
  [ -f "$vs" ] || stuck "validation script unavailable or miscalled — a human must fix the install"

  out=$(git -C "$top" status --porcelain </dev/null 2>/dev/null) || stuck "worktree dirty — a human must reconcile"
  [ -z "$out" ] || stuck "worktree dirty — a human must reconcile"

  # run_vs MODE: the validation script's MODE on the worktree, its output
  # streamed to stderr as it runs (tee) and kept only for the script's own
  # first `validation: ` line (the shell running it may print a warning
  # first; the command's output always follows the script's `running` line);
  # sets rc (the script's own exit status) and first. Fails closed: every mode
  # of the script prints such a line, so a tee that failed, or a pass with no
  # such line, never reads as a pass that hid the `fallback` line.
  tmpf=$(mktemp) || stuck "cannot record the validation output — temporary file failed"   # global: the EXIT trap runs after this function returns
  trap 'rm -f "${tmpf:-}"' EXIT
  run_vs() {
    local ts
    (cd "$top" && bash "$vs" "$1" "$base" </dev/null 2>&1) | tee "$tmpf" >&2; rc=${PIPESTATUS[0]} ts=${PIPESTATUS[1]}
    first=$(grep -m 1 '^validation: ' "$tmpf" 2>/dev/null)
    [ "$ts" -eq 0 ] || stuck "cannot record the validation output — temporary file failed"
    [ "$rc" -ne 0 ] || [ -n "$first" ] || stuck "cannot record the validation output — temporary file failed"
  }

  view=$(gh pr view "$p" --json headRefName,headRefOid,baseRefName \
    --jq '"\(.headRefName) \(.headRefOid) \(.baseRefName)"' </dev/null) \
    || stuck "cannot resolve the PR head — query or fetch failed"
  read -r head_ref head_oid base <<EOF_VIEW
$view
EOF_VIEW
  [ -n "$head_ref" ] && [ -n "$head_oid" ] && [ -n "$base" ] || stuck "cannot resolve the PR head — query or fetch failed"
  cur=$(git -C "$top" rev-parse --abbrev-ref HEAD 2>/dev/null)
  if [ "$cur" != "$head_ref" ]; then
    echo "worktree-missing $wt is not this PR's checkout (on ${cur:-?}, the PR head is $head_ref)"; exit 0
  fi

  # No contract and no fallback command: stop before touching the worktree, so
  # the retry with --fallback-cmd still sees (and reports) a head sync as
  # `refreshed`. A `check` that fails stops here too, for the same reason.
  if [ "$have_fallback" -eq 0 ]; then
    run_vs check
    case $rc in
      0) ;;
      2) stuck "cannot resolve the base branch (validation exit 2)" ;;
      3) stuck "validation contract invalid (exit 3)" ;;
      *) stuck "validation script unavailable or miscalled — a human must fix the install" ;;
    esac
    case $first in 'validation: fallback ('*) stuck "no validation contract and no --fallback-cmd given" ;; esac
  fi

  # Head sync.
  start_oid=$(git -C "$top" rev-parse HEAD 2>/dev/null) || stuck "cannot resolve the PR head — query or fetch failed"
  touched=1
  (cd "$top" && fetch3 "$head_ref") || stuck "cannot resolve the PR head — query or fetch failed"
  if [ "$(git -C "$top" rev-parse HEAD 2>/dev/null)" != "$head_oid" ]; then
    # shellcheck disable=SC2015 # intended: stuck when either the ancestry check or the fast-forward fails
    git -C "$top" merge-base --is-ancestor HEAD "$head_oid" </dev/null 2>/dev/null \
      && git -C "$top" merge -q --ff-only "$head_oid" </dev/null >/dev/null 2>&1 \
      || stuck "worktree not at the PR head and cannot fast-forward to it — a human must reconcile"
    moved=1
  fi

  # Base freshness.
  (cd "$top" && fetch3 "$base") || stuck "cannot fetch the base branch origin/$base"
  mb=$(git -C "$top" merge-base HEAD "origin/$base" 2>/dev/null) || stuck "no merge-base with origin/$base"
  count=$(git -C "$top" rev-list --count "$mb..origin/$base" 2>/dev/null) || stuck "cannot fetch the base branch origin/$base"
  if [ "$count" -gt 0 ]; then
    log=$(git -C "$top" merge --no-edit "origin/$base" </dev/null 2>&1); rc=$?
    if [ "$rc" -ne 0 ]; then
      conflicts=$(git -C "$top" diff --name-only --diff-filter=U 2>/dev/null | tr '\n' ' ' | sed 's/ *$//')
      git -C "$top" merge --abort </dev/null >/dev/null 2>&1
      [ -n "$conflicts" ] && stuck "merge conflict with origin/$base: $conflicts"
      stuck "base merge did not start: $(printf '%s\n' "$log" | awk 'NF { print; exit }')"
    fi
    merged=1
    merge_oid=$(git -C "$top" rev-parse HEAD 2>/dev/null) || stuck "base merge did not start: cannot read its commit"
  fi

  # Validation, from the worktree, against the PR's base branch.
  for mode in changed preflight full; do
    run_vs "$mode"
    case $rc in
      0) ;;
      1) stuck "$mode validation failed (exit 1)" ;;
      2) stuck "cannot resolve the base branch (validation exit 2)" ;;
      3) stuck "validation contract invalid (exit 3)" ;;
      4) stuck "validation command not runnable (exit 4): $mode" ;;
      5) [ "$mode" = changed ] && stuck "contract changed after ready — a human must review and merge"
         stuck "validation script unavailable or miscalled — a human must fix the install" ;;
      *) stuck "validation script unavailable or miscalled — a human must fix the install" ;;
    esac
    # Only the script's first `validation: ` line: with a contract it prints `running preflight:` first,
    # and the command's own output (PR-controlled) must never read as "no contract".
    if [ "$mode" = preflight ] && case $first in 'validation: fallback ('*) true ;; *) false ;; esac; then
      [ "$have_fallback" -eq 1 ] || stuck "no validation contract and no --fallback-cmd given"
      (cd "$top" && bash -c "$fallback" </dev/null >&2 2>&1); rc=$?
      [ "$rc" -eq 0 ] || stuck "fallback tests failed (exit $rc)"
      break   # no contract: `full` would print the same fallback line
    fi
  done

  # The head validation ran on is the PR head, or the base merge on top of it;
  # a validation that moved HEAD (a commit, a checkout) validated neither.
  local expect_oid=$head_oid
  [ "$merged" -eq 1 ] && expect_oid=$merge_oid
  [ "$(git -C "$top" rev-parse HEAD 2>/dev/null)" = "$expect_oid" ] \
    || stuck "validation moved HEAD off the validated head — a human must reconcile"
  # Push exactly the commit the base merge produced, nothing validation made.
  if [ "$merged" -eq 1 ]; then
    git -C "$top" push -q origin "$merge_oid:refs/heads/$head_ref" </dev/null >/dev/null 2>&1 \
      || stuck "push failed after refresh — a human must retry or merge by hand"
  fi
  trap - TERM INT HUP   # past the last step: a late signal must not print a second line
  if [ "$merged" -eq 1 ] || [ "$moved" -eq 1 ]; then
    echo "refreshed $expect_oid"
  else
    echo "unchanged $expect_oid"
  fi
}

# checks_once P -> pass | none | fail
checks_once() {
  local out rc
  out=$(gh pr checks "$1" </dev/null 2>&1); rc=$?
  if [ "$rc" -eq 0 ]; then echo pass
  elif printf '%s\n' "$out" | grep -qi 'no checks reported'; then echo none
  else echo fail
  fi
}

cmd_checks() {
  local p=$1 refreshed=$2 r i
  r=$(checks_once "$p")
  if [ "$r" = none ] && [ "$refreshed" -eq 1 ]; then
    for i in 1 2 3 4 5 6; do
      sleep "$POLL_SLEEP"
      r=$(checks_once "$p")
      [ "$r" = none ] || break
    done
    [ "$r" = none ] && r=none-after-refresh
  fi
  echo "$r"
}

cmd_merge() {
  local p=$1 oid=$2 title body log state head sha
  title=$(gh pr view "$p" --json title --jq .title </dev/null) || { echo "skipped merge did not land (state unknown): cannot read the PR title"; exit 0; }
  body=$(gh pr view "$p" --json body --jq .body </dev/null) \
    || { echo "skipped merge did not land (state unknown): cannot read the PR body"; exit 0; }
  body=$(printf '%s\n' "$body" | awk '/^## Review notes$/{exit} {print}')
  log=$(gh pr merge --squash --delete-branch --match-head-commit "$oid" "$p" \
    --subject "$title" --body "$body" </dev/null 2>&1)
  state=$(gh pr view "$p" --json state --jq .state </dev/null) || state=unknown
  if [ "$state" = MERGED ]; then
    sha=$(gh pr view "$p" --json mergeCommit --jq .mergeCommit.oid </dev/null) || sha=""
    echo "merged ${sha:-unknown}"; exit 0
  fi
  head=$(gh pr view "$p" --json headRefOid --jq .headRefOid </dev/null) || head=""
  if [ -n "$head" ] && [ "$head" != "$oid" ]; then
    echo "skipped head moved after validation"; exit 0
  fi
  echo "skipped merge did not land (state $state): $(printf '%s\n' "$log" | awk 'NF { print; exit }')"
}

MODE=${1:-}
case $MODE in
  state)
    [ $# -eq 2 ] || usage "state needs <P>"
    pr_arg "$2"; cmd_state "$2" ;;
  refresh)
    [ $# -eq 4 ] || { [ $# -eq 6 ] && [ "$5" = --fallback-cmd ]; } \
      || usage "refresh needs <worktree> <P> <validation-script> [--fallback-cmd <command>]"
    [ -n "$2" ] || usage "empty worktree path"
    pr_arg "$3"
    [ $# -eq 4 ] || [ -n "$6" ] || usage "empty --fallback-cmd (use : for a project with no tests)"
    if [ $# -eq 6 ]; then cmd_refresh "$2" "$3" "$4" "$6" 1; else cmd_refresh "$2" "$3" "$4" "" 0; fi ;;
  checks)
    { [ $# -eq 2 ] || { [ $# -eq 3 ] && [ "$3" = --refreshed ]; }; } || usage "checks needs <P> [--refreshed]"
    pr_arg "$2"
    if [ $# -eq 3 ]; then cmd_checks "$2" 1; else cmd_checks "$2" 0; fi ;;
  merge)
    [ $# -eq 3 ] || usage "merge needs <P> <oid>"
    pr_arg "$2"
    case $3 in *[!0-9a-f]*|'') usage "oid must be a 40-hex commit id, got '$3'" ;; esac
    [ ${#3} -eq 40 ] || usage "oid must be a 40-hex commit id, got '$3'"
    cmd_merge "$2" "$3" ;;
  *) usage "unknown mode '$MODE' (expected state, refresh, checks or merge)" ;;
esac
