#!/usr/bin/env bash
#
# Pure deterministic scheduling transitions for issue-runner Step 3 (SKILL.md).
#
# This is the ~two-thirds of the Step 3 loop that has no judgement in it: cascade
# skip, the ready set, and the blocked-chain-vs-run-paused-vs-cycle distinction.
# Everything that DOES need judgement — dispatching an implementer, reading a
# result.json, hang detection, Step 4 blocker resolution, every AskUserQuestion —
# stays in SKILL.md prose and is never touched here.
#
# Usage: scheduler.sh STATE_DIR
#
#   STATE_DIR is $RUN_ROOT/state (issue-runner's State section). Per issue N,
#   this script reads:
#     STATE_DIR/issue-N/status   pending|implementing|blocked|done|failed|
#                                 skipped|closed-externally (absent/empty = pending)
#   and one run-level file:
#     STATE_DIR/dag.txt          "N: dep dep …" one line per in-scope issue,
#                                 written alongside dag.json in Step 2. Empty
#                                 after the colon when N has no deps.
#   and, derived from STATE_DIR (its parent is $RUN_ROOT — see the State
#   section's `STATE_DIR=$RUN_ROOT/state`):
#     RUN_ROOT/paused            written by Step 3a on a host credit/usage-limit
#                                 dispatch failure (issue #9); its mere presence,
#                                 not its content, forces the ready set empty.
#
# This script NEVER writes state — status/error files are the orchestrator's
# to write, never this script's. It prints one action per line to stdout and
# exits 0. A non-zero exit means STATE_DIR or dag.txt itself could not be read;
# nothing below was evaluated.
#
# Actions (one per line):
#   skip N <error>   cascade-skip N with this error text (Step 3 item 1)
#   dispatch N       N is ready: all deps done, not in flight (item 2)
#   cycle N <dep>    N is part of a true dependency cycle; <dep> is a real
#                    offending dependency also stuck in the cycle (item 6)
#   paused           nothing to skip/dispatch/cycle: at least one remaining
#                    `pending` issue has a `blocked` ancestor (item 6,
#                    blocked-chain case) — resolve the blocked issue(s) via
#                    Step 4, never treat this as a cycle
#   run-paused       nothing to skip/dispatch/cycle: RUN_ROOT/paused exists,
#                    so every remaining `pending` issue is paused for that one
#                    run-wide reason (item 6, run-paused case) — skip Step 4's
#                    dispatching escalations and go straight to Step 5
#   wait             nothing ready to dispatch, but an implementer is still
#                    in flight (status=implementing) — wait for it (item 4)
#   done             every issue is terminal (done/failed/skipped/
#                    closed-externally) — exit the Step 3 loop
#
# `run-paused` takes priority over the blocked-chain/cycle distinction (item 6
# checks it first): while RUN_ROOT/paused exists, no cycle is ever declared,
# even a genuine one — the fix is run-level (wait for the reset), not a retry.
# The cascade (item 1) is unaffected by RUN_ROOT/paused and always runs first.
#
# Dependency-free: bash + coreutils only (no jq, no python, no associative
# arrays — bash 3.2, stock on macOS, has neither).

set -u

STATE_DIR=${1:?usage: scheduler.sh STATE_DIR}
DAG="$STATE_DIR/dag.txt"
RUN_ROOT=$(dirname "$STATE_DIR")

if [ ! -d "$STATE_DIR" ] || [ ! -r "$STATE_DIR" ]; then
  echo "scheduler.sh: cannot read state dir: $STATE_DIR" >&2
  exit 1
fi
if [ ! -r "$DAG" ]; then
  echo "scheduler.sh: cannot read dag file: $DAG" >&2
  exit 1
fi

# All issue numbers in dag.txt, in file order.
ISSUES=$(awk -F: '{gsub(/^[ \t]+|[ \t]+$/,"",$1); if ($1 != "") print $1}' "$DAG")

# deps_of N -> space-separated dependency issue numbers (possibly empty).
deps_of() {
  local n="$1" rest
  rest=$(awk -F: -v n="$n" '{
    k=$1; gsub(/^[ \t]+|[ \t]+$/,"",k)
    if (k==n) { print $2; exit }
  }' "$DAG")
  # shellcheck disable=SC2086 # word-splitting on purpose: normalizes whitespace
  echo $rest
}

# status_of N -> the real on-disk status, defaulting to "pending".
status_of() {
  local f="$STATE_DIR/issue-$1/status"
  if [ -s "$f" ]; then
    head -n1 "$f" | tr -d '[:space:]'
  else
    echo pending
  fi
}

# --- Cascade skip (Step 3 item 1) -------------------------------------------
# A pending issue with a failed/skipped dep cascades with "dependency failed:
# #X"; one with a closed-externally dep (and no failed/skipped dep) cascades
# with "dependency closed externally without merge proof: #X". Repeat until
# stable so a multi-level chain fully cascades in one call. Recorded as an
# overlay (never written to disk here) so eff_status() below can see a
# same-pass cascade without a second script invocation.
OVERLAY=$(mktemp)
trap 'rm -f "$OVERLAY"' EXIT

eff_status() {
  local n="$1" line
  line=$(awk -F'\t' -v n="$n" '$1==n{print;exit}' "$OVERLAY")
  if [ -n "$line" ]; then
    printf '%s\n' "$line" | cut -f2
  else
    status_of "$n"
  fi
}

changed=1
while [ "$changed" -eq 1 ]; do
  changed=0
  for n in $ISSUES; do
    [ "$(eff_status "$n")" = pending ] || continue
    reason=""
    for d in $(deps_of "$n"); do
      ds=$(eff_status "$d")
      if [ "$ds" = failed ] || [ "$ds" = skipped ]; then
        reason="dependency failed: #$d"
        break
      fi
    done
    if [ -z "$reason" ]; then
      for d in $(deps_of "$n"); do
        if [ "$(eff_status "$d")" = closed-externally ]; then
          reason="dependency closed externally without merge proof: #$d"
          break
        fi
      done
    fi
    if [ -n "$reason" ]; then
      printf '%s\t%s\t%s\n' "$n" skipped "$reason" >> "$OVERLAY"
      changed=1
    fi
  done
done

# Emit skip lines now, sorted numerically for a deterministic order.
sort -t "$(printf '\t')" -k1,1n "$OVERLAY" 2>/dev/null | while IFS=$'\t' read -r n _ reason; do
  [ -n "$n" ] && printf 'skip %s %s\n' "$n" "$reason"
done

# --- Ready set (Step 3 item 2) -----------------------------------------------
# Forced empty outright while RUN_ROOT/paused exists (issue #9): dispatch is
# suspended host-wide, not just for the issue that hit the credit/usage-limit
# stop, until a fresh invocation clears the file at Step 1.
READY=""
if [ ! -f "$RUN_ROOT/paused" ]; then
  for n in $ISSUES; do
    [ "$(eff_status "$n")" = pending ] || continue
    all_done=1
    for d in $(deps_of "$n"); do
      [ "$(eff_status "$d")" = done ] || { all_done=0; break; }
    done
    [ "$all_done" -eq 1 ] && READY="$READY $n"
  done
fi
READY=$(printf '%s\n' $READY | sort -n | tr '\n' ' ')

if [ -n "${READY// /}" ]; then
  for n in $READY; do
    printf 'dispatch %s\n' "$n"
  done
  exit 0
fi

# --- Nothing ready: in flight, or item 6's three-way distinction ------------
IN_FLIGHT=0
for n in $ISSUES; do
  if [ "$(status_of "$n")" = implementing ]; then
    IN_FLIGHT=1
    break
  fi
done

if [ "$IN_FLIGHT" -eq 1 ]; then
  echo wait
  exit 0
fi

REMAINING=""
for n in $ISSUES; do
  [ "$(eff_status "$n")" = pending ] && REMAINING="$REMAINING $n"
done
REMAINING=$(printf '%s\n' $REMAINING | sort -n | tr '\n' ' ')

ANY_BLOCKED=0
for n in $ISSUES; do
  if [ "$(status_of "$n")" = blocked ]; then
    ANY_BLOCKED=1
    break
  fi
done

if [ -z "${REMAINING// /}" ]; then
  # Nothing pending, nothing in flight: fully terminal, or one lone `blocked`
  # issue with no dependent ever waiting on it (still needs Step 4 — never
  # silently "done" while a human decision is outstanding).
  if [ "$ANY_BLOCKED" -eq 1 ]; then
    echo paused
  else
    echo done
  fi
  exit 0
fi

# Step 3 item 6, checked in the spec's own order: run-paused first (never
# declare a cycle while the host is paused, even a genuine one), then the
# blocked-chain wait, then a true cycle.
if [ -f "$RUN_ROOT/paused" ]; then
  echo run-paused
  exit 0
fi

# has_blocked_ancestor N -> "yes"/"no": true if any transitive dependency of N
# currently has status=blocked. Visited-guarded so a true cycle (which this
# is specifically here to rule out) can never spin the search forever.
has_blocked_ancestor() {
  local start="$1" visited=" $1 " queue cur
  queue=$(deps_of "$start")
  while [ -n "$queue" ]; do
    # shellcheck disable=SC2086 # word-splitting on purpose
    set -- $queue
    cur=$1
    shift
    queue="$*"
    case "$visited" in *" $cur "*) continue ;; esac
    visited="$visited$cur "
    if [ "$(status_of "$cur")" = blocked ]; then
      echo yes
      return
    fi
    queue="$queue $(deps_of "$cur")"
  done
  echo no
}

paused_needed=0
for n in $REMAINING; do
  if [ "$(has_blocked_ancestor "$n")" = yes ]; then
    paused_needed=1
    break
  fi
done

if [ "$paused_needed" -eq 1 ]; then
  echo paused
  exit 0
fi

# True cycle: every remaining pending issue is stuck on another remaining
# pending issue. Cite a real offending dep — one that is itself still stuck —
# never just the first dep listed.
for n in $REMAINING; do
  offending=""
  for d in $(deps_of "$n"); do
    for r in $REMAINING; do
      if [ "$r" = "$d" ]; then
        offending="$d"
        break 2
      fi
    done
  done
  [ -n "$offending" ] || offending=$(deps_of "$n" | awk '{print $1}')
  printf 'cycle %s %s\n' "$n" "$offending"
done
