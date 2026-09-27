#!/usr/bin/env bash
#
# validation-contract.sh — gh-issue's "Validation contract" recipe: discover
# `.issue-runner/validation` on the base branch's tip and check it, run it, or
# report whether this PR edited it.
#
# Usage: bash validation-contract.sh <mode> [<base-branch>]
#   run from anywhere inside the worktree (it cds to the worktree root itself)
#   <mode>         check     discovery and grammar only, nothing runs
#                  changed   did this PR (HEAD vs its merge-base with the base) edit the file,
#                            or the integration contract `.issue-runner/integration`?
#                  preflight run the contract's `preflight:` command
#                  full      run the contract's `full:` command (if declared)
#   <base-branch>  optional; skips the `gh` lookup. Default: the open PR's base
#                  branch (`gh pr view`), else the repository's default branch
#                  (`gh repo view`). Passed but empty → exit 2, never the default.
#   Extra arguments are ignored.
#
# Trust rule: the contract is always read from the freshly fetched tip of
# `origin/<base>`, never from the working tree, the index or a cached
# remote-tracking ref. The command it names runs in this checkout, via
# `bash -c` from the worktree root; only its exit status is read.
#
# Grammar: `#` comment lines and blank lines, plus lines `preflight: <command>`
# (exactly one) and `full: <command>` (at most one). A command must not be only
# a `#` comment. Any other line, CRLF line endings or a NUL byte anywhere makes
# the file invalid.
#
# Output: plain-text lines prefixed `validation: ` (preflight/full also print
# `validation: running <mode>: <command>` before the command's own output).
# Exit status — unlike the bundled-script convention (non-zero only for an
# environment failure), 1, 3, 4 and 5 are verdicts: the codes predate the
# extraction and gh-issue branches on them, so they are kept as they were:
#   0  check:     `validation: contract ok (preflight declared; full declared|not declared)`
#                 or `validation: fallback (no contract at .issue-runner/validation on <base>)`
#      changed:   `validation: contract unchanged in this PR` (neither file changed)
#      preflight/full: `validation: <mode> passed`, `validation: <mode> not declared`
#                 (full only) or the fallback line above
#   1  `validation: <mode> failed (exit N): <command>` — the command exited with
#      anything but 0, 126 or 127 (its own 2-6 included: a command cannot forge
#      the exits below)
#   2  `validation: cannot resolve the base branch: ...`, `validation: cannot
#      resolve the worktree root`, `validation: cannot resolve the merge-base
#      with origin/<base>` or `validation: cannot diff ...` — an environment
#      failure, never a verdict on the change and never a fallback
#   3  `validation: invalid contract (.issue-runner/validation on <base>): ...`
#   4  `validation: <mode> command not runnable (exit 126|127): <command>`
#   5  `validation: contract changed in this PR (...)` and/or `validation: integration
#      contract changed in this PR (...)`, each followed by its diff (changed only)
#   6  `validation: unknown MODE '<mode>'`
#
# Dependencies: bash 3.2, coreutils, grep, sed, git; gh unless <base-branch> is given.

MODE=${1:-}   # check | changed | preflight | full (the exit-6 message keeps its historical `MODE` wording)
set +e +o pipefail   # the script reads every exit status itself; an inherited -e/pipefail would turn "no full: line" (grep -c exits 1) into a silent exit 1
# shellcheck disable=SC2015   # A && B && C || D is intended: the error branch must run when any link fails, the cd included
TOP=$(git rev-parse --show-toplevel 2>/dev/null) && [ -n "$TOP" ] && cd "$TOP" || { echo "validation: cannot resolve the worktree root" >&2; exit 2; }   # a pathspec (the `changed` diff) is cwd-relative: from a subdirectory it would match nothing and read as "unchanged"; chained on rev-parse's own status, never on its output: `cd ""` is a no-op that exits 0 in bash
case $MODE in check|changed|preflight|full) ;; *) echo "validation: unknown MODE '$MODE'" >&2; exit 6 ;; esac
CONTRACT_PATH=.issue-runner/validation
INTEGRATION_PATH=.issue-runner/integration   # `changed` mode only: issue-runner reads and checks this one
if [ $# -ge 2 ] && [ -z "$2" ]; then   # an explicit but empty base (an unset variable in the caller) must never fall back to the gh lookup on whatever branch this checkout is on
  echo "validation: cannot resolve the base branch: empty base argument" >&2; exit 2
fi
BASE_BRANCH=${2:-}
if [ -z "$BASE_BRANCH" ]; then
  BASE_BRANCH=$(gh pr view --json baseRefName,state -q 'select(.state=="OPEN") | .baseRefName' 2>/dev/null) && [ -n "$BASE_BRANCH" ] \
    || BASE_BRANCH=$(gh repo view --json defaultBranchRef -q .defaultBranchRef.name)   # OPEN only: on a branch, gh pr view also resolves its last closed or merged PR (gh-issue Step 7's rule), whose base may differ
fi
FETCHED=0; for i in 1 2 3; do git fetch -q origin "+refs/heads/$BASE_BRANCH:refs/remotes/origin/$BASE_BRANCH" 2>/dev/null && { FETCHED=1; break; }; [ "$i" -lt 3 ] && sleep 1; done   # three tries: linked worktrees share this ref, and a sibling implementer's simultaneous fetch can hold its lock for a moment
[ "$FETCHED" -eq 1 ] \
  || { echo "validation: cannot resolve the base branch: cannot fetch origin/${BASE_BRANCH:-?}" >&2; exit 2; }   # never read a cached origin/<base> instead: it may be stale (a fix on the base branch unread, a stale error recurring); explicit destination: a single-branch clone would otherwise fetch only into FETCH_HEAD
CONTRACT_REF=$(git rev-parse -q --verify "refs/remotes/origin/$BASE_BRANCH^{commit}" 2>/dev/null) && [ -n "$CONTRACT_REF" ] \
  || { echo "validation: cannot resolve the base branch: no origin/${BASE_BRANCH:-?}" >&2; exit 2; }   # never fall through to the index (":$CONTRACT_PATH" would read the working tree's copy)
if [ "$MODE" = changed ]; then
  MB=$(git merge-base HEAD "$CONTRACT_REF" 2>/dev/null) && [ -n "$MB" ] \
    || { echo "validation: cannot resolve the merge-base with origin/$BASE_BRANCH" >&2; exit 2; }
  CHANGED=0
  for P in "$CONTRACT_PATH" "$INTEGRATION_PATH"; do   # the integration contract gets the same gate (docs/integration-rfc.md §5.3)
    K=contract; [ "$P" = "$CONTRACT_PATH" ] || K="integration contract"
    git diff --quiet "$MB" HEAD -- "$P"; RC=$?   # 0 = same, 1 = differs, anything else = git failed — never read as "unchanged"
    case $RC in
      0) ;;
      1) CHANGED=1; echo "validation: $K changed in this PR ($P differs from the merge-base $MB):"; git --no-pager diff "$MB" HEAD -- "$P" ;;
      *) echo "validation: cannot diff $P against $MB (git exit $RC)" >&2; exit 2 ;;
    esac
  done
  [ "$CHANGED" -eq 1 ] && exit 5
  echo "validation: contract unchanged in this PR"; exit 0
fi
ENTRY=$(git ls-tree --full-tree "$CONTRACT_REF" -- "$CONTRACT_PATH" 2>/dev/null) || { echo "validation: cannot resolve the base branch: cannot read the tree of origin/$BASE_BRANCH" >&2; exit 2; }   # ls-tree lists the path without reading its blob: `cat-file -e` fails the same way for an absent path and for a missing or corrupt object, and the second must never read as "no contract"
if [ -z "$ENTRY" ]; then
  echo "validation: fallback (no contract at $CONTRACT_PATH on $BASE_BRANCH)"   # the project's conventions decide
else
  CONTRACT=$(git show "$CONTRACT_REF:$CONTRACT_PATH") || { echo "validation: cannot resolve the base branch: cannot read $CONTRACT_PATH from origin/$BASE_BRANCH" >&2; exit 2; }   # an unreadable object is not an invalid contract
  STRAY=$(printf '%s\n' "$CONTRACT" | grep -vE '^[[:space:]]*(#|$)' | grep -vE '^(preflight|full):[[:space:]]*[^[:space:]#]')   # a value that is only a `#` comment is a placeholder, not a command: `bash -c '# TODO'` exits 0 and would report "passed"
  N_PRE=$(printf '%s\n' "$CONTRACT" | grep -cE '^preflight:[[:space:]]*[^[:space:]#]')
  N_FULL=$(printf '%s\n' "$CONTRACT" | grep -cE '^full:[[:space:]]*[^[:space:]#]')
  if [ "$(git show "$CONTRACT_REF:$CONTRACT_PATH" | tr -d '\000' | wc -c)" -ne "$(git show "$CONTRACT_REF:$CONTRACT_PATH" | wc -c)" ]; then   # judged on the blob, never on $CONTRACT: a command substitution drops NUL bytes, so `tr<NUL>ue` would read as `true` and pass
    echo "validation: invalid contract ($CONTRACT_PATH on $BASE_BRANCH): NUL byte" >&2; exit 3
  elif printf '%s\n' "$CONTRACT" | grep -q $'\r'; then
    echo "validation: invalid contract ($CONTRACT_PATH on $BASE_BRANCH): CRLF line endings" >&2; exit 3
  elif [ -n "$STRAY" ] || [ "$N_PRE" -ne 1 ] || [ "$N_FULL" -gt 1 ]; then
    echo "validation: invalid contract ($CONTRACT_PATH on $BASE_BRANCH): preflight lines=$N_PRE, full lines=$N_FULL, first stray line: $(printf '%s\n' "$STRAY" | head -1)" >&2
    exit 3
  fi
  if [ "$MODE" = check ]; then
    echo "validation: contract ok (preflight declared; full $([ "$N_FULL" -eq 1 ] && echo declared || echo not declared))"; exit 0
  fi
  CMD=$(printf '%s\n' "$CONTRACT" | sed -nE "s/^$MODE:[[:space:]]*//p")
  if [ -z "$CMD" ]; then
    echo "validation: $MODE not declared"   # only `full` can be undeclared — nothing to run
  else
    echo "validation: running $MODE: $CMD"
    bash -c "$CMD"; RC=$?   # from the worktree root (the cd above)
    case $RC in
      0)       echo "validation: $MODE passed" ;;
      126|127) echo "validation: $MODE command not runnable (exit $RC): $CMD" >&2; exit 4 ;;   # the command itself is missing or not executable — the contract, or what this PR did to what it names
      *)       echo "validation: $MODE failed (exit $RC): $CMD" >&2; exit 1 ;;   # every other command exit, the script's own 2–6 included — a command can never forge those
    esac
  fi
fi
