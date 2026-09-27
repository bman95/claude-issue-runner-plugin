#!/usr/bin/env bash
#
# integration.sh — issue-runner's integration contract, slice 1 of
# docs/integration-rfc.md §14: discover `.issue-runner/integration` on the base
# branch's tip (§5.1, §5.3, §5.6), send the lifecycle hints its `hint:` command
# declares (§5.5, §6.1), and `--flush`. SKILL.md calls this script at its call
# sites and prints its output. The rules live here and in the RFC, which is
# also where the rationale is.
#
# Hints are advisory. No outcome here stops a run or changes an issue's
# status: a failing, hung or unsent hint is a report line. A project without
# the file sees nothing, because every hint call prints nothing and sends nothing.
#
# Run from the target repository (the orchestrator's own cwd, never a
# worktree). Commands run through `bash -c` from its root.
#
# Usage:
#   integration.sh discover <default-branch> [<state-dir> [--no-merge]]
#     Read the contract from the freshly fetched tip of origin/<default-branch>
#     and print one line (below). With <state-dir>, also record it for this
#     invocation's hints: `integration-discovery` (the line), `integration-base`
#     (<default-branch>), `integration-mode` (`no-merge` with --no-merge, else
#     `merge`), and `integration-contract` (the checked file, only when valid).
#
#   integration.sh hint <state-dir> run-start
#   integration.sh hint <state-dir> merged <N> [--pr <P>] [--untried "<N …>"]
#     Build the hint's environment now, then detach its bounded wrapper and
#     return at once. The command's exit is collected by `run-complete`. With
#     INTEGRATION_HINT_FOREGROUND=1 in the environment (the Codex edition,
#     whose host ends a shell call's descendants), the wrapper runs in the
#     foreground instead, under the same bound, and prints `delivered`. Without
#     --pr, `merged` reads issue-N/merge-oid, which classify.sh records on merge
#     proof. With --pr (the --merge-ready pass), it first records merge-oid
#     from GitHub's answer for PR <P>, which must be MERGED; it records it even
#     when no hint command is declared. --untried lists the eligible issues the
#     --merge-ready pass has not tried yet. Each one still `ready` with every
#     dag.txt dependency `done` counts toward REMAINING.
#
#   integration.sh run-complete <state-dir> <completed|paused|stopped>
#     Step 5, in the foreground. It drains every hint wrapper still running,
#     each within its own bound. It then sends `run-complete`, bounded, and
#     waits for it. Last it prints this invocation's integration lines: a
#     disabled discovery line, then one line per hint.
#
#   integration.sh flush <run-root> <default-branch> [<lock-ttl-minutes>]
#     `/issue-runner --flush`. It never locks, rotates, initializes or writes
#     run state. It runs its own discovery and sends `flush` for the tip of
#     origin/<default-branch>, in the foreground. <run-root> is `run-state.sh
#     resolve`'s. The run counts as live while its lock holds a live PID or
#     its mtime is younger than <lock-ttl-minutes> (default 120).
#
# Output — lines on stdout:
#   discover:
#     integration: not configured
#     integration: hint | integration: status | integration: hint, status
#     integration: contract invalid (<reason>) — integration disabled for this run
#     integration: unresolvable (<reason>) — integration disabled for this run
#   hint (nothing at all when no hint command is declared):
#     integration: hint <label> launched   (or `delivered` in the foreground)
#     integration: hint <label> not sent (<reason>)
#   run-complete: the disabled discovery line if any, then one line per hint
#   this invocation sent, in the order they finished:
#     integration: hint <label>: sent (exit 0) | adapter exited <code> | timed out
#     integration: hint <label>: not collected (its wrapper ended without a result)
#     integration: hint <label>: not collected (still running at Step 5)
#     integration: hint <label>: not sent (cannot create the watchdog directory)
#     integration: hint <label>: not sent (<reason>)
#   flush: the discovery line, spelled `integration: disabled (contract invalid:
#   <reason>)` or `integration: disabled (unresolvable: <reason>)` for the two
#   failures, then one of:
#     flush: sent (exit 0) | flush: adapter exited <code> | flush: timed out
#     flush: not sent (no hint command)
#     flush: not sent (cannot create the watchdog directory)
#   <label> is `run-start`, `merged #N` or `run-complete`.
#
# Grammar (§5.1): the validation contract's. It allows `#` comment lines and
# blank lines, plus at most one `hint: <command>` line and at most one
# `status: <command>` line, and at least one of the two. A command that is only
# a `#` comment is not a command. Any other line, CRLF line endings or a NUL
# byte makes the file invalid. An invalid or unreadable contract disables
# integration for the run and never stops it (§5.6).
#
# Environment (§5.5), set by this script alone and never inherited. Every
# inherited ISSUE_RUNNER_* variable is unset first:
#   ISSUE_RUNNER_HINT_VERSION  1
#   ISSUE_RUNNER_HINT          run-start | merged | run-complete | flush
#   ISSUE_RUNNER_RUN           <state-dir>/run-id (run-state.sh init). flush
#                              uses the live run's run-id, else `none`
#   ISSUE_RUNNER_INVOCATION    <state-dir>/invocation (run-state.sh init). flush
#                              uses the time of the call
#   ISSUE_RUNNER_RUN_STATE     `active`. run-complete sends `complete`. flush
#                              sends `active` while the run's lock is live,
#                              else `complete`
#   ISSUE_RUNNER_BASE          merged: the base branch from merge-oid.
#                              run-complete: the base of the last `merged` this
#                              invocation sent, else the default branch.
#                              run-start and flush: the default branch
#   ISSUE_RUNNER_REVISION      merged: the merge commit. flush: the tip of
#                              origin/<default-branch>. run-complete: the last
#                              `merged` revision this invocation sent. The
#                              variable is absent when this invocation sent none
#   ISSUE_RUNNER_ISSUE, ISSUE_RUNNER_PR     merged only
#   ISSUE_RUNNER_REMAINING     run-start and merged: scope.txt issues `pending`
#                              or `implementing`, plus the --untried ones counted
#                              above. The count is read when the call is made,
#                              so the caller writes `done` first. It is 0 under
#                              `integration-mode` no-merge. run-complete: 0
#   ISSUE_RUNNER_NEAR_COMPLETE merged only: `implementing` issues whose progress
#                              marker reads step=9 or step=9.2. It is 0 under
#                              no-merge
#   ISSUE_RUNNER_REASON        run-complete only
#
# The bound (§5.5). The command runs in its own process group (`set -m`) with
# stdin, stdout and stderr on /dev/null, because its output is ignored. A
# watchdog sleeps BOUND seconds, a fixed 60 in both editions (tests set
# INTEGRATION_HINT_BOUND), then sends TERM to the whole group and, 2 s later,
# KILL. After a normal exit the wrapper kills the watchdog and sweeps the
# group anyway, TERM then KILL, so detached work never outlives the bound. A
# killed command reads `timed out`.
#
# State files in <state-dir>, besides those `discover` records:
#   integration-hints        one line per hint result: <invocation><TAB><text>
#   integration-pending/     one marker per wrapper not yet collected (`<inv> <label>`,
#                            plus `<marker>.pid` once the wrapper starts)
#   integration-last-merged  <invocation> <oid> <base>, rewritten by each `merged`
#
# Exit status: 0 with the lines above, since every hint outcome is a report
# line and never a failure. flush exits 1 unless the hint was sent and exited 0.
# 2 is a usage error.
#
# Dependencies: bash 3.2, coreutils, grep, sed, awk, git; gh for `merged --pr`.

# shellcheck disable=SC1010,SC2015,SC2100,SC2155 # `done` is a status word here, A && B || C is intended, `i-2`-like text is a label, and the exports read their own values
set -u
set +e +o pipefail   # every exit status below is read explicitly

SELF=${BASH_SOURCE[0]}
BOUND=${INTEGRATION_HINT_BOUND:-60}
CONTRACT_PATH=.issue-runner/integration

usage() { echo "integration.sh: $1" >&2; exit 2; }
posint() { case $1 in ''|*[!0-9]*|0*) return 1 ;; esac; return 0; }
posint "$BOUND" || usage "INTEGRATION_HINT_BOUND must be a positive integer, got '$BOUND'"
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
first_line() { [ -f "$1" ] && head -n 1 "$1" 2>/dev/null | tr -d '\r'; }
full_oid() { printf '%s' "$1" | grep -qE '^([0-9a-f]{40}|[0-9a-f]{64})$'; }

TOP=$(git rev-parse --show-toplevel 2>/dev/null) || TOP=""
[ -n "$TOP" ] || TOP=$(pwd)

# discover_core BRANCH: sets D_KIND (none|valid|invalid|unresolvable), D_REASON,
# D_TEXT (the checked file), D_KEYS (`hint`, `status` or `hint, status`) and
# D_TIP (the fetched tip).
discover_core() {
  local b=$1 i fetched=0 entry n_hint n_status stray
  D_KIND=unresolvable D_REASON="" D_TEXT="" D_KEYS="" D_TIP=""
  for i in 1 2 3; do
    git -C "$TOP" fetch -q origin "+refs/heads/$b:refs/remotes/origin/$b" </dev/null 2>/dev/null && { fetched=1; break; }
    [ "$i" -lt 3 ] && sleep 1
  done
  [ "$fetched" -eq 1 ] || { D_REASON="cannot fetch origin/$b"; return; }
  D_TIP=$(git -C "$TOP" rev-parse -q --verify "refs/remotes/origin/$b^{commit}" 2>/dev/null) && [ -n "$D_TIP" ] \
    || { D_TIP=""; D_REASON="no origin/$b"; return; }
  entry=$(git -C "$TOP" ls-tree --full-tree "$D_TIP" -- "$CONTRACT_PATH" 2>/dev/null) \
    || { D_REASON="cannot read the tree of origin/$b"; return; }
  if [ -z "$entry" ]; then D_KIND=none; return; fi
  D_TEXT=$(git -C "$TOP" show "$D_TIP:$CONTRACT_PATH" 2>/dev/null) \
    || { D_TEXT=""; D_REASON="cannot read $CONTRACT_PATH from origin/$b"; return; }
  D_KIND=invalid
  # The NUL test reads the blob, never $D_TEXT: a command substitution drops NUL bytes.
  if [ "$(git -C "$TOP" show "$D_TIP:$CONTRACT_PATH" | tr -d '\000' | wc -c)" -ne "$(git -C "$TOP" show "$D_TIP:$CONTRACT_PATH" | wc -c)" ]; then
    D_REASON="NUL byte"; return
  fi
  if printf '%s\n' "$D_TEXT" | grep -q $'\r'; then D_REASON="CRLF line endings"; return; fi
  stray=$(printf '%s\n' "$D_TEXT" | grep -vE '^[[:space:]]*(#|$)' | grep -vE '^(hint|status):[[:space:]]*[^[:space:]#]' | head -n 1)
  n_hint=$(printf '%s\n' "$D_TEXT" | grep -cE '^hint:[[:space:]]*[^[:space:]#]')
  n_status=$(printf '%s\n' "$D_TEXT" | grep -cE '^status:[[:space:]]*[^[:space:]#]')
  if [ -n "$stray" ]; then D_REASON="stray line: $stray"; return; fi
  if [ "$n_hint" -gt 1 ]; then D_REASON="duplicated key: hint"; return; fi
  if [ "$n_status" -gt 1 ]; then D_REASON="duplicated key: status"; return; fi
  if [ "$n_hint" -eq 0 ] && [ "$n_status" -eq 0 ]; then D_REASON="no hint: or status: line"; return; fi
  D_KIND=valid
  if [ "$n_hint" -eq 1 ] && [ "$n_status" -eq 1 ]; then D_KEYS="hint, status"
  elif [ "$n_hint" -eq 1 ]; then D_KEYS=hint
  else D_KEYS=status; fi
}

discover_line() {
  case $D_KIND in
    none)    echo "integration: not configured" ;;
    valid)   echo "integration: $D_KEYS" ;;
    invalid) echo "integration: contract invalid ($D_REASON) — integration disabled for this run" ;;
    *)       echo "integration: unresolvable ($D_REASON) — integration disabled for this run" ;;
  esac
}

# hint_cmd TEXT: the declared hint command, empty when there is none.
hint_cmd() { printf '%s\n' "$1" | sed -nE 's/^hint:[[:space:]]*//p' | head -n 1; }

clear_env() {
  local v
  for v in $(compgen -e); do case $v in ISSUE_RUNNER_*) unset "$v" ;; esac; done
}

# run_bounded CMD: run CMD under the bound. Sets RB_RC to its exit status and
# RB_TIMED_OUT to 1 when the watchdog killed it.
run_bounded() {
  local flagdir flag pid w=""
  RB_ERR=""
  # The watchdog's flag lives in a private directory: a guessable name in a
  # shared /tmp could be planted as a symlink for the `: >` below to truncate.
  flagdir=$(mktemp -d "${TMPDIR:-/tmp}/integration-timeout.XXXXXX" 2>/dev/null) || flagdir=""
  if [ -z "$flagdir" ]; then RB_ERR="not sent (cannot create the watchdog directory)"; RB_RC=1; RB_TIMED_OUT=0; return; fi
  flag="$flagdir/timed-out"
  set -m   # job control: the background job below gets its own process group
  ( cd "$TOP" && exec bash -c "$1" ) </dev/null >/dev/null 2>&1 &
  pid=$!
  set +m
  # Killed or interrupted mid-wait (a host tool timeout, Ctrl-C): take the
  # command's own process group down too, so it never outlives this call.
  # The watchdog goes too, so it never signals a process group id reused later.
  # (A SIGKILL of this call cannot be trapped: the adapter then outlives it.)
  trap 'kill -TERM -- -"$pid" 2>/dev/null; sleep 1; kill -KILL -- -"$pid" 2>/dev/null; [ -n "$w" ] && kill "$w" 2>/dev/null; rm -rf "$flagdir"; exit 143' TERM INT HUP
  ( trap 'kill "$S" 2>/dev/null; exit 0' TERM
    sleep "$BOUND" & S=$!
    wait "$S" && { : > "$flag"; kill -TERM -- -"$pid" 2>/dev/null; sleep 2; kill -KILL -- -"$pid" 2>/dev/null; } ) >/dev/null 2>&1 &
  w=$!
  { wait "$pid"; RB_RC=$?; } 2>/dev/null   # no job notice ("Killed") on stderr
  kill "$w" 2>/dev/null; wait "$w" 2>/dev/null
  # The sweep: whatever the command left in its group (a detached `worker &`).
  if kill -0 -- -"$pid" 2>/dev/null; then
    kill -TERM -- -"$pid" 2>/dev/null; sleep 1; kill -KILL -- -"$pid" 2>/dev/null
  fi
  trap - TERM INT HUP
  RB_TIMED_OUT=0
  [ -e "$flag" ] && RB_TIMED_OUT=1
  rm -rf "$flagdir"
}

result_text() {
  if [ -n "${RB_ERR:-}" ]; then echo "$RB_ERR"
  elif [ "$RB_TIMED_OUT" -eq 1 ]; then echo "timed out"
  elif [ "$RB_RC" -eq 0 ]; then echo "sent (exit 0)"
  else echo "adapter exited $RB_RC"; fi
}

log_result() {  # SD INV TEXT
  printf '%s\t%s\n' "$2" "$3" >> "$1/integration-hints" 2>/dev/null
}

# The per-run values every hint shares.
load_run() {  # SD
  RUN=$(first_line "$1/run-id"); [ -n "$RUN" ] || RUN=none
  INV=$(first_line "$1/invocation"); [ -n "$INV" ] || INV=none
  DEFAULT=$(first_line "$1/integration-base")
  MODE=$(first_line "$1/integration-mode")
  HCMD=""
  [ -f "$1/integration-contract" ] && HCMD=$(hint_cmd "$(cat "$1/integration-contract" 2>/dev/null)")
}

status_of() { first_line "$1/issue-$2/status"; }

scope_issues() { tr -s ' \t\r,' '\n' < "$1/scope.txt" 2>/dev/null | grep -E '^[0-9]+$'; }

deps_done() {  # SD N
  local deps d
  deps=$(tr -d '\r' < "$1/dag.txt" 2>/dev/null | awk -v n="$2" -F: '$1 == n { print $2; exit }')
  for d in $deps; do [ "$(status_of "$1" "$d")" = done ] || return 1; done
  return 0
}

remaining() {  # SD UNTRIED
  local c=0 n
  [ "$MODE" = no-merge ] && { echo 0; return; }
  for n in $(scope_issues "$1"); do
    case $(status_of "$1" "$n") in pending|implementing) c=$((c + 1)) ;; esac
  done
  for n in $2; do
    posint "$n" || continue
    [ "$(status_of "$1" "$n")" = ready ] && deps_done "$1" "$n" && c=$((c + 1))
  done
  echo "$c"
}

near_complete() {  # SD
  local c=0 n
  [ "$MODE" = no-merge ] && { echo 0; return; }
  for n in $(scope_issues "$1"); do
    [ "$(status_of "$1" "$n")" = implementing ] || continue
    first_line "$1/issue-$n/progress" | grep -qE '^step=9(\.2)?([[:space:]]|$)' && c=$((c + 1))
  done
  echo "$c"
}

# launch SD LABEL: detach the bounded wrapper for HCMD with the environment
# already exported. The marker is written before the fork, so a drain that
# starts right after this call still sees the hint. The wrapper then puts its
# own PID in the marker.
launch() {
  local sd=$1 label=$2 marker
  if ! mkdir -p "$sd/integration-pending" 2>/dev/null; then
    log_result "$sd" "$INV" "hint $label: not sent (cannot write $sd/integration-pending)"
    echo "integration: hint $label not sent (cannot write $sd/integration-pending)"; return 1
  fi
  marker="$sd/integration-pending/$(date +%s).$$.$RANDOM"
  # Written whole, then moved into place: the drain never reads a half-written marker.
  if ! { printf -- '%s %s\n' "$INV" "$label" > "$marker.tmp" 2>/dev/null && mv -f "$marker.tmp" "$marker" 2>/dev/null; }; then
    rm -f "$marker.tmp"
    log_result "$sd" "$INV" "hint $label: not sent (cannot write its marker)"
    echo "integration: hint $label not sent (cannot write its marker)"; return 1
  fi
  if [ "${INTEGRATION_HINT_FOREGROUND:-}" = 1 ]; then
    # A host that ends a shell call's descendants when the call returns (Codex)
    # would kill a detached wrapper: deliver in the foreground, still bounded.
    INTEGRATION_DELIVER_CMD=$HCMD bash "$SELF" _deliver "$sd" "$marker" "$INV" "$label" </dev/null >/dev/null 2>&1
    echo "integration: hint $label delivered"; return
  fi
  INTEGRATION_DELIVER_CMD=$HCMD nohup bash "$SELF" _deliver "$sd" "$marker" "$INV" "$label" </dev/null >/dev/null 2>&1 &
  echo "integration: hint $label launched"
}

cmd_deliver() {  # SD MARKER INV LABEL (the detached wrapper)
  local cmd=${INTEGRATION_DELIVER_CMD:-}
  unset INTEGRATION_DELIVER_CMD
  [ -f "$2" ] || exit 0   # Step 5's drain already gave up on this hint: never run after it
  printf '%s\n' "$$" > "$2.pid.tmp" 2>/dev/null && mv -f "$2.pid.tmp" "$2.pid" 2>/dev/null
  run_bounded "$cmd"
  log_result "$1" "$3" "hint $4: $(result_text)"
  rm -f "$2" "$2.pid" "$2.pid.tmp"
}

# drain SD: wait, bounded, for this invocation's wrappers. Each marker is
# `<invocation> <label>`, and `<marker>.pid` names its wrapper once it starts.
#   - an earlier invocation's marker is dropped at once, unreported;
#   - a marker older than the bound plus 15 s is dead by construction, whatever
#     `kill -0` says of a (possibly reused) PID;
#   - a started wrapper that is gone without a result: `not collected`;
#   - a wrapper not started yet, or still running, stays pending until the
#     deadline; then it is reported `not collected (still running at Step 5)`
#     and its marker removed, so it never runs a command afterwards.
drain() {
  local sd=$1 deadline m inv label pid pending mtime now final=0
  [ -d "$sd/integration-pending" ] || return 0
  deadline=$(( $(date +%s) + BOUND + 10 ))
  while :; do
    pending=0 now=$(date +%s)
    [ "$now" -ge "$deadline" ] && final=1
    for m in "$sd"/integration-pending/*; do
      case $m in *.pid|*.tmp) continue ;; esac
      [ -f "$m" ] || continue
      inv="" label=""
      read -r inv label < "$m" 2>/dev/null
      if [ -n "$inv" ] && [ "$inv" != "$INV" ]; then rm -f "$m" "$m.pid"; continue; fi
      mtime=$(stat -c %Y "$m" 2>/dev/null || stat -f %m "$m" 2>/dev/null || echo 0)
      pid=""; [ -f "$m.pid" ] && pid=$(head -n 1 "$m.pid" 2>/dev/null)
      if [ $(( now - mtime )) -le $(( BOUND + 15 )) ] && [ "$final" -eq 0 ]; then
        if [ -z "$pid" ] || kill -0 "$pid" 2>/dev/null; then pending=1; continue; fi
      fi
      [ -f "$m" ] || continue   # finished between the read and here
      if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
        log_result "$sd" "$INV" "hint ${label:-?}: not collected (its wrapper ended without a result)"
      else
        log_result "$sd" "$INV" "hint ${label:-?}: not collected (still running at Step 5)"
      fi
      rm -f "$m" "$m.pid"
    done
    [ "$pending" -eq 0 ] && return 0
    sleep 1
  done
}

record_merge() {  # SD N P: record issue-N/merge-oid from GitHub's answer for PR P
  local view state oid base tmp
  view=$(gh pr view "$3" --json state,mergeCommit,baseRefName \
    --jq '"\(.state) \(.mergeCommit.oid // "-") \(.baseRefName)"' </dev/null 2>/dev/null) || return 1
  read -r state oid base <<EOF_VIEW
$view
EOF_VIEW
  [ "$state" = MERGED ] && full_oid "$oid" && [ -n "$base" ] || return 1
  tmp="$1/issue-$2/merge-oid.tmp.$$"
  printf '%s %s %s\n' "$oid" "$base" "$3" > "$tmp" 2>/dev/null && mv -f "$tmp" "$1/issue-$2/merge-oid" 2>/dev/null \
    || { rm -f "$tmp"; return 1; }
}

cmd_discover() {
  local b=$1 sd=${2:-} mode=merge line tmp
  [ -n "$b" ] || usage "empty default branch"
  [ "${3:-}" = --no-merge ] && mode=no-merge
  discover_core "$b"
  line=$(discover_line)
  if [ -n "$sd" ]; then
    [ -d "$sd" ] || usage "not a directory: $sd"
    rm -f "$sd/integration-contract"
    { printf '%s\n' "$line" > "$sd/integration-discovery" \
      && printf '%s\n' "$b" > "$sd/integration-base" \
      && printf '%s\n' "$mode" > "$sd/integration-mode"; } 2>/dev/null \
      || line="integration: unresolvable (cannot write $sd) — integration disabled for this run"
    if [ "$D_KIND" = valid ] && [ "${line#integration: unresolvable}" = "$line" ]; then
      tmp="$sd/integration-contract.tmp.$$"
      printf '%s\n' "$D_TEXT" > "$tmp" 2>/dev/null && mv -f "$tmp" "$sd/integration-contract" 2>/dev/null \
        || { rm -f "$tmp"; line="integration: unresolvable (cannot write $sd) — integration disabled for this run"; }
    fi
    printf '%s\n' "$line" > "$sd/integration-discovery" 2>/dev/null
  fi
  echo "$line"
}

cmd_hint() {
  local sd=$1 kind=$2 n="" p="" untried="" label rec oid base pr
  [ -d "$sd" ] || usage "not a directory: $sd"
  shift 2
  case $kind in
    run-start) [ $# -eq 0 ] || usage "run-start takes no arguments" ;;
    merged)
      n=${1:-}; posint "$n" || usage "merged needs an issue number, got '$n'"
      shift
      while [ $# -gt 0 ]; do
        case $1 in
          --pr) p=${2:-}; posint "$p" || usage "--pr needs a PR number, got '$p'"; shift 2 ;;
          --untried) [ $# -ge 2 ] || usage "--untried needs a list"; untried=$2; shift 2 ;;
          *) usage "unknown merged option '$1'" ;;
        esac
      done ;;
    *) usage "unknown hint '$kind' (expected run-start or merged)" ;;
  esac
  load_run "$sd"
  if [ "$kind" = merged ]; then
    label="merged #$n"
    [ -z "$p" ] || record_merge "$sd" "$n" "$p" || rm -f "$sd/issue-$n/merge-oid"
    [ -n "$HCMD" ] || return 0
    rec=$(first_line "$sd/issue-$n/merge-oid")
    read -r oid base pr <<EOF_REC
$rec
EOF_REC
    if ! full_oid "${oid:-}" || [ -z "${base:-}" ] || ! posint "${pr:-}"; then
      log_result "$sd" "$INV" "hint $label: not sent (no merge commit recorded)"
      echo "integration: hint $label not sent (no merge commit recorded)"; return 0
    fi
    clear_env
    export ISSUE_RUNNER_HINT_VERSION=1 ISSUE_RUNNER_HINT=merged ISSUE_RUNNER_RUN="$RUN" \
      ISSUE_RUNNER_INVOCATION="$INV" ISSUE_RUNNER_RUN_STATE=active ISSUE_RUNNER_BASE="$base" \
      ISSUE_RUNNER_REVISION="$oid" ISSUE_RUNNER_ISSUE="$n" ISSUE_RUNNER_PR="$pr" \
      ISSUE_RUNNER_REMAINING="$(remaining "$sd" "$untried")" ISSUE_RUNNER_NEAR_COMPLETE="$(near_complete "$sd")"
  else
    label=run-start
    [ -n "$HCMD" ] || return 0
    clear_env
    export ISSUE_RUNNER_HINT_VERSION=1 ISSUE_RUNNER_HINT=run-start ISSUE_RUNNER_RUN="$RUN" \
      ISSUE_RUNNER_INVOCATION="$INV" ISSUE_RUNNER_RUN_STATE=active ISSUE_RUNNER_BASE="$DEFAULT" \
      ISSUE_RUNNER_REMAINING="$(remaining "$sd" "")"
  fi
  launch "$sd" "$label" || return 0
  # Only a hint that actually went out is "the last merged this invocation sent".
  [ "$kind" = merged ] && printf '%s %s %s\n' "$INV" "$oid" "$base" > "$sd/integration-last-merged" 2>/dev/null
  return 0
}

cmd_run_complete() {
  local sd=$1 reason=$2 disc last linv loid lbase
  [ -d "$sd" ] || usage "not a directory: $sd"
  case $reason in completed|paused|stopped) ;; *) usage "reason must be completed, paused or stopped, got '$reason'" ;; esac
  load_run "$sd"
  disc=$(first_line "$sd/integration-discovery")
  case $disc in *'integration disabled for this run') echo "$disc" ;; esac
  [ -n "$HCMD" ] || return 0
  drain "$sd"
  clear_env
  export ISSUE_RUNNER_HINT_VERSION=1 ISSUE_RUNNER_HINT=run-complete ISSUE_RUNNER_RUN="$RUN" \
    ISSUE_RUNNER_INVOCATION="$INV" ISSUE_RUNNER_RUN_STATE=complete ISSUE_RUNNER_BASE="$DEFAULT" \
    ISSUE_RUNNER_REMAINING=0 ISSUE_RUNNER_REASON="$reason"
  last=$(first_line "$sd/integration-last-merged")
  read -r linv loid lbase <<EOF_LAST
$last
EOF_LAST
  if [ -n "$last" ] && [ "$linv" = "$INV" ] && full_oid "${loid:-}" && [ -n "${lbase:-}" ]; then
    export ISSUE_RUNNER_REVISION="$loid" ISSUE_RUNNER_BASE="$lbase"
  fi
  run_bounded "$HCMD"
  log_result "$sd" "$INV" "hint run-complete: $(result_text)"
  awk -F'\t' -v inv="$INV" '$1 == inv { sub(/^[^\t]*\t/, ""); print "integration: " $0 }' "$sd/integration-hints" 2>/dev/null
}

cmd_flush() {
  local rr=$1 b=$2 ttl=${3:-120} lock pid live=0 run=none cmd
  case $rr in /*) ;; *) usage "run root must be an absolute path, got '$rr'" ;; esac
  [ -n "$b" ] || usage "empty default branch"
  posint "$ttl" || usage "lock TTL must be a positive integer (minutes), got '$ttl'"
  discover_core "$b"
  case $D_KIND in
    invalid)      echo "integration: disabled (contract invalid: $D_REASON)" ;;
    unresolvable) echo "integration: disabled (unresolvable: $D_REASON)" ;;
    *)            discover_line ;;
  esac
  cmd=""
  [ "$D_KIND" = valid ] && cmd=$(hint_cmd "$D_TEXT")
  [ -n "$cmd" ] || { echo "flush: not sent (no hint command)"; exit 1; }
  lock="$rr/lock"
  if [ -s "$lock" ]; then
    pid=$(first_line "$lock")
    if { posint "$pid" && kill -0 "$pid" 2>/dev/null; } || [ -z "$(find "$lock" -mmin +"$ttl" 2>/dev/null)" ]; then live=1; fi
  fi
  if [ "$live" -eq 1 ]; then
    run=$(first_line "$rr/state/run-id"); [ -n "$run" ] || run=none
  fi
  clear_env
  export ISSUE_RUNNER_HINT_VERSION=1 ISSUE_RUNNER_HINT=flush ISSUE_RUNNER_RUN="$run" \
    ISSUE_RUNNER_INVOCATION="$(now)" ISSUE_RUNNER_BASE="$b" ISSUE_RUNNER_REVISION="$D_TIP"
  if [ "$live" -eq 1 ]; then export ISSUE_RUNNER_RUN_STATE=active; else export ISSUE_RUNNER_RUN_STATE=complete; fi
  run_bounded "$cmd"
  echo "flush: $(result_text)"
  [ "$RB_TIMED_OUT" -eq 0 ] && [ "$RB_RC" -eq 0 ] || exit 1
}

MODE_ARG=${1:-}
[ $# -gt 0 ] && shift
case $MODE_ARG in
  discover)
    [ $# -ge 1 ] && [ $# -le 3 ] || usage "discover needs <default-branch> [<state-dir> [--no-merge]]"
    [ $# -lt 3 ] || [ "$3" = --no-merge ] || usage "unknown discover option '$3' (expected --no-merge)"
    cmd_discover "$@" ;;
  hint)
    [ $# -ge 2 ] || usage "hint needs <state-dir> <run-start|merged> …"
    cmd_hint "$@" ;;
  run-complete)
    [ $# -eq 2 ] || usage "run-complete needs <state-dir> <completed|paused|stopped>"
    cmd_run_complete "$@" ;;
  flush)
    [ $# -ge 2 ] && [ $# -le 3 ] || usage "flush needs <run-root> <default-branch> [<lock-ttl-minutes>]"
    cmd_flush "$@" ;;
  _deliver)
    [ $# -eq 4 ] || usage "_deliver is internal"
    cmd_deliver "$@" ;;
  *) usage "unknown mode '$MODE_ARG' (expected discover, hint, run-complete or flush)" ;;
esac
