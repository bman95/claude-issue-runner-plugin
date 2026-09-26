#!/usr/bin/env bash
#
# run-state.sh — issue-runner's run-state mechanics: where a run's state lives
# (`resolve`), taking the one-run-per-repo lock and initializing the state dir
# (`init`), keeping the lock's heartbeat fresh (`heartbeat`), and releasing it
# (`release`). SKILL.md's State section runs this script and obeys its output;
# the rules live here, and the rationale in REFERENCE.md ("Why the run lock
# uses `$PPID` plus a heartbeat", "Why state is namespaced per repo", "Why the
# run root lives under `$XDG_STATE_HOME`", "Why resume pointers are written at
# dispatch").
#
# Run from the target repository's root (the orchestrator's own cwd, never a
# worktree): the run root is keyed on `git rev-parse --show-toplevel`.
#
# Usage:
#   run-state.sh resolve
#     read-only: resolve the paths below and print them; never locks, rotates,
#     or creates anything (`--status`, and agent-trace.sh)
#
#   run-state.sh init <owner-pid> <lock-ttl-minutes> [--merge-ready]
#     take the run lock and initialize the state dir. <owner-pid> is the
#     caller's `$PPID` — the Claude Code process hosting the session, the one
#     process that lives exactly as long as the run can. It is passed in because
#     this script's own parent is the short-lived Bash tool shell. <lock-ttl-
#     minutes> is `--lock-ttl-minutes` (default 120 in SKILL.md). --merge-ready
#     keeps the previous run's state unconditionally (`--merge-ready` mode).
#
#   run-state.sh heartbeat <owner-pid>
#     refresh the lock's mtime, only when this session owns the lock
#
#   run-state.sh release [--lock-only]
#     remove the lock and the session pointer (a clean release, Step 5), or
#     the lock alone (`--plan`: a plan never finishes the run it may have
#     re-entered, so the pointer stays)
#
# Paths, derived from the repository root:
#   REPO_KEY   <basename>-<first 8 hex of git hash-object of the root path>.
#              git hash-object, not sha1sum: sha1sum is absent on stock macOS,
#              and a silent pipeline failure would collapse the key to
#              <basename>- — same-basename repos colliding.
#   RUN_ROOT   ${XDG_STATE_HOME:-$HOME/.local/state}/issue-runner/<REPO_KEY>:
#              durable per-user state, not /tmp. Must be absolute (the XDG spec
#              calls a relative XDG_STATE_HOME invalid, and dispatch prompts
#              carry the path literally, so a relative one would resolve against
#              whatever cwd reads it).
#   STATE_DIR  $RUN_ROOT/state
#   Beside state/: `lock` (the owner PID; its mtime is the heartbeat),
#   `session` (the orchestrator's $CLAUDE_CODE_SESSION_ID, one line) and
#   `paused` (written by Step 3a, cleared by `init`).
#
# Output — every line on stdout; a refusal or failure prints its reason on
# stderr and nothing more on stdout:
#   resolve, and the first three lines of init:
#     repo-key <REPO_KEY>
#     run-root <RUN_ROOT>
#     state-dir <STATE_DIR>
#   init, then exactly one of:
#     state new                                                no previous state dir
#     state rotated: <RUN_ROOT>/state.prev.<epoch>             the previous run's state,
#                                                              moved aside with a copy of
#                                                              the session pointer it was
#                                                              filed under
#     state kept: same session re-entering its unfinished run  kept in place: the pointer
#                                                              equals $CLAUDE_CODE_SESSION_ID
#                                                              (non-empty), or --merge-ready
#   heartbeat, exactly one of:
#     heartbeat refreshed
#     heartbeat skipped: <reason>        no lock, not this session's lock, or the
#                                        touch failed — best-effort, never fatal
#   release:
#     released: lock session             (or `released: lock` with --lock-only)
#     released: no lock at <path>        there was no lock to remove (the session
#                                        pointer, without --lock-only, is still
#                                        removed): a cwd other than the repository
#                                        root resolves another run root — check it
#
# Exit status: 0 with the lines above (a skipped heartbeat included); 1 — a
# refusal or an environment failure: a live lock held by another run, a run
# root that is relative or not writable, no git repository, or a lock, state
# dir or session pointer that cannot be written or moved. Stop and show the
# stderr line(s) to the user; nothing is locked or rotated by a refusal. 2 — a
# usage error.
#
# Lock rules (init):
#   - Liveness is PID-alive (kill -0 on the recorded PID) OR the lock's mtime
#     younger than <lock-ttl-minutes>. A live lock is refused, never deleted:
#     the rotation below would yank a running orchestration's state from under
#     its implementers. PID-alive alone assumes every Bash call's parent is the
#     same long-lived process; a platform that interposes a wrapper shell breaks
#     that, and the heartbeat covers it.
#   - An empty lock (the failure paths below truncate rather than delete) reads
#     as neither signal: both require a recorded PID.
#   - The same session re-entering its own unfinished run (the session pointer
#     equals a non-empty $CLAUDE_CODE_SESSION_ID) bypasses the heartbeat signal
#     only: a resumed process gets a fresh $PPID, and a recent crash's still-
#     fresh heartbeat would otherwise refuse the session that owns the lock. A
#     live PID stays refused regardless (REFERENCE.md's confirm-and-delete
#     recipe is the recovery for this process's own cut-off run).
#   - Every write after the probe is fatal on failure. Once the lock is written,
#     a failure truncates it again — only while it still holds <owner-pid>: two
#     starts that both passed the liveness check race on the write, and the
#     loser must not blank the winner's live lock.
#   - Rotation: the previous state dir is kept when the session pointer equals
#     a non-empty $CLAUDE_CODE_SESSION_ID (same session, run never released —
#     `release` removes the pointer with the lock) or under --merge-ready;
#     otherwise it moves to state.prev.<epoch>, carrying a copy of the pointer.
#     state.prev.* dirs older than 7 days are pruned first.
#   - The session pointer is written after the rotation check (never before,
#     or every start would read as a re-entry), through a per-owner temp file
#     so a failed write leaves the previous pointer intact. Empty on a host
#     that does not set CLAUDE_CODE_SESSION_ID (and empty never matches).
#
# Heartbeat rule: touch the lock only if it exists (`touch` would recreate a
# deleted lock empty — indistinguishable from a clean release to another
# session's liveness check) and this session owns it: the session pointer
# equals $CLAUDE_CODE_SESSION_ID when that is set — `$PPID` is a different,
# already-dead value on every call on exactly the wrapper-shell platform the
# heartbeat exists for — else the lock holds <owner-pid>.
#
# Dependencies: bash 3.2, coreutils, find, git.

set -u
set +e +o pipefail   # every exit status below is read explicitly

die()   { echo "run-state.sh: $1" >&2; exit 1; }
usage() { echo "run-state.sh: $1" >&2; exit 2; }

posint() { case $1 in ''|*[!0-9]*|0*) return 1 ;; esac; return 0; }

resolve_paths() {
  REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) && [ -n "$REPO_ROOT" ] \
    || die "not inside a git repository: $(pwd)"
  local h
  h=$(printf '%s' "$REPO_ROOT" | git hash-object --stdin) && [ -n "$h" ] \
    || die "cannot hash the repository root: $REPO_ROOT"
  REPO_KEY=$(basename "$REPO_ROOT")-$(printf '%s' "$h" | cut -c1-8)
  # ${HOME:-}: an unset HOME must reach the write probe's fix-it message, not abort under set -u.
  RUN_ROOT=${XDG_STATE_HOME:-${HOME:-}/.local/state}/issue-runner/$REPO_KEY
  case $RUN_ROOT in /*) ;; *) die "run root is not absolute: $RUN_ROOT" ;; esac
  STATE_DIR=$RUN_ROOT/state
}

print_paths() {
  printf 'repo-key %s\nrun-root %s\nstate-dir %s\n' "$REPO_KEY" "$RUN_ROOT" "$STATE_DIR"
}

session_matches() {  # the recorded pointer equals a non-empty current session id
  [ -n "${CLAUDE_CODE_SESSION_ID:-}" ] \
    && [ "$(cat "$RUN_ROOT/session" 2>/dev/null)" = "$CLAUDE_CODE_SESSION_ID" ]
}

# fail_locked MSG: release the lock this call took (truncate: works even where
# the directory is read-only; an empty lock reads stale) if it still holds
# OWNER, then die.
fail_locked() {
  [ "$(cat "$RUN_ROOT/lock" 2>/dev/null)" = "$OWNER" ] && true > "$RUN_ROOT/lock"
  die "$1"
}

cmd_init() {
  local lock_pid pid_alive heartbeat_fresh mtime age pid_word prev
  resolve_paths

  # Hard precondition, before the lock and the rotation: create the root and
  # write inside it. A real write probe, not -w: sandboxes deny at open(), not
  # in the mode bits (and `true`, not `:`, so a POSIX-mode shell reaches the
  # message instead of aborting on the special builtin). There is no fallback
  # root; on failure nothing is locked.
  if ! { mkdir -p "$RUN_ROOT" 2>/dev/null && true > "$RUN_ROOT/.write-probe" 2>/dev/null \
         && rm -f "$RUN_ROOT/.write-probe" 2>/dev/null; }; then
    echo "run-state.sh: run root is not writable: $RUN_ROOT" >&2
    echo "issue-runner keeps its state there and has no fallback root. Fix the permissions, or relaunch with that path writable: create ${RUN_ROOT%/*} from an unsandboxed shell, then \`codex --add-dir \"${RUN_ROOT%/*}\"\` (or list it under sandbox_workspace_write.writable_roots in config.toml); in other sandboxes allow-list the same path. Then retry." >&2
    exit 1
  fi

  if [ -f "$RUN_ROOT/lock" ]; then
    lock_pid=$(cat "$RUN_ROOT/lock" 2>/dev/null)
    pid_alive=false
    [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null && pid_alive=true
    heartbeat_fresh=false
    [ -n "$lock_pid" ] && [ -z "$(find "$RUN_ROOT/lock" -mmin +"$TTL" 2>/dev/null)" ] && heartbeat_fresh=true
    if [ "$pid_alive" = false ] && [ "$heartbeat_fresh" = true ] && session_matches; then
      heartbeat_fresh=false
    fi
    if [ "$pid_alive" = true ] || [ "$heartbeat_fresh" = true ]; then
      # GNU stat first, BSD/macOS stat as the fallback.
      mtime=$(stat -c %Y "$RUN_ROOT/lock" 2>/dev/null || stat -f %m "$RUN_ROOT/lock" 2>/dev/null)
      age=?; [ -n "$mtime" ] && age=$(( ($(date +%s) - mtime + 59) / 60 ))   # round up, like the hang check
      pid_word=dead; [ "$pid_alive" = true ] && pid_word=alive
      die "live issue-runner in this repo (lock: $RUN_ROOT/lock): pid $lock_pid $pid_word, last heartbeat ${age} min ago"
    fi
  fi
  echo "$OWNER" > "$RUN_ROOT/lock" 2>/dev/null || die "cannot write lock: $RUN_ROOT/lock"

  # A pause note from a previous invocation: reaching this line means this
  # session's own calls go through again.
  rm -f "$RUN_ROOT/paused" 2>/dev/null
  find "$RUN_ROOT" -maxdepth 1 -name 'state.prev.*' -mtime +7 -exec rm -rf {} + 2>/dev/null

  STATE_LINE="state new"
  if [ -d "$STATE_DIR" ]; then
    if [ "$MERGE_READY" = 1 ] || session_matches; then
      STATE_LINE="state kept: same session re-entering its unfinished run"
    else
      [ -f "$RUN_ROOT/session" ] && cp "$RUN_ROOT/session" "$STATE_DIR/session" 2>/dev/null
      prev=$RUN_ROOT/state.prev.$(date +%s)
      mv "$STATE_DIR" "$prev" 2>/dev/null || fail_locked "cannot rotate state: $STATE_DIR"
      STATE_LINE="state rotated: $prev"
    fi
  fi
  mkdir -p "$STATE_DIR" 2>/dev/null || fail_locked "cannot create state dir: $STATE_DIR"
  if ! { printf '%s\n' "${CLAUDE_CODE_SESSION_ID:-}" > "$RUN_ROOT/session.tmp.$OWNER" 2>/dev/null \
         && mv "$RUN_ROOT/session.tmp.$OWNER" "$RUN_ROOT/session" 2>/dev/null; }; then
    rm -f "$RUN_ROOT/session.tmp.$OWNER" 2>/dev/null
    fail_locked "cannot write session pointer: $RUN_ROOT/session"
  fi
  print_paths
  echo "$STATE_LINE"
}

cmd_heartbeat() {
  resolve_paths
  [ -f "$RUN_ROOT/lock" ] || { echo "heartbeat skipped: no lock at $RUN_ROOT/lock"; return 0; }
  if [ -n "${CLAUDE_CODE_SESSION_ID:-}" ]; then
    session_matches || { echo "heartbeat skipped: the lock belongs to another session"; return 0; }
  else
    [ "$(cat "$RUN_ROOT/lock" 2>/dev/null)" = "$OWNER" ] \
      || { echo "heartbeat skipped: the lock does not hold pid $OWNER"; return 0; }
  fi
  touch "$RUN_ROOT/lock" 2>/dev/null || { echo "heartbeat skipped: cannot touch $RUN_ROOT/lock"; return 0; }
  echo "heartbeat refreshed"
}

cmd_release() {
  resolve_paths
  if [ ! -e "$RUN_ROOT/lock" ]; then
    [ "$LOCK_ONLY" = 1 ] || rm -f "$RUN_ROOT/session" 2>/dev/null || die "cannot remove $RUN_ROOT/session"
    echo "released: no lock at $RUN_ROOT/lock"
    return 0
  fi
  if [ "$LOCK_ONLY" = 1 ]; then
    rm -f "$RUN_ROOT/lock" 2>/dev/null || die "cannot remove $RUN_ROOT/lock"
    echo "released: lock"
  else
    rm -f "$RUN_ROOT/lock" "$RUN_ROOT/session" 2>/dev/null || die "cannot remove $RUN_ROOT/lock or $RUN_ROOT/session"
    echo "released: lock session"
  fi
}

MODE=${1:-}
[ $# -gt 0 ] && shift
OWNER="" TTL="" MERGE_READY=0 LOCK_ONLY=0
case $MODE in
  resolve)
    [ $# -eq 0 ] || usage "resolve takes no arguments"
    resolve_paths; print_paths ;;
  init)
    [ $# -ge 2 ] && [ $# -le 3 ] || usage "usage: init <owner-pid> <lock-ttl-minutes> [--merge-ready]"
    OWNER=$1 TTL=$2
    posint "$OWNER" || usage "owner pid must be a positive integer, got '$OWNER'"
    posint "$TTL" || usage "lock TTL must be a positive integer (minutes), got '$TTL'"
    if [ $# -eq 3 ]; then
      [ "$3" = --merge-ready ] || usage "unknown init option '$3' (expected --merge-ready)"
      MERGE_READY=1
    fi
    cmd_init ;;
  heartbeat)
    [ $# -eq 1 ] || usage "usage: heartbeat <owner-pid>"
    OWNER=$1
    posint "$OWNER" || usage "owner pid must be a positive integer, got '$OWNER'"
    cmd_heartbeat ;;
  release)
    case $# in
      0) ;;
      1) [ "$1" = --lock-only ] || usage "unknown release option '$1' (expected --lock-only)"; LOCK_ONLY=1 ;;
      *) usage "usage: release [--lock-only]" ;;
    esac
    cmd_release ;;
  *) usage "unknown mode '$MODE' (expected resolve, init, heartbeat or release)" ;;
esac
