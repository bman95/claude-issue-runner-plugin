#!/usr/bin/env bash
#
# Fixtures for scripts/run-state.sh: issue-runner's run root resolution, run
# lock (PID liveness + heartbeat TTL), heartbeat refresh, same-session
# re-entry versus rotation to state.prev.*, and release.
#
# Each fixture runs the script in a real git repository with XDG_STATE_HOME
# pointed at a fresh temp dir. A live owner is this test's own PID; a dead one
# is the PID of a background process that has already been reaped. Lock ages
# are set with `touch -t`.
#
# Run directly, or from scripts/lint.sh (and so from CI). Dependency-free:
# bash + git + coreutils. Exits non-zero on the first-or-any failure.

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="$ROOT/skills/issue-runner/scripts/run-state.sh"

fail=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export HOME="$TMP/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
mkdir -p "$HOME"
unset XDG_CONFIG_HOME CLAUDE_CODE_SESSION_ID

ok()  { printf 'ok:   %s\n' "$1"; }
err() { printf 'FAIL: %s\n' "$1" >&2; fail=1; }

if [ ! -f "$SCRIPT" ]; then err "run-state.sh not found"; exit 1; fi

REPO="$TMP/repo"
git init -q "$REPO"

LIVE=$$
sh -c 'exit 0' & DEAD=$!; wait "$DEAD"
kill -0 "$DEAD" 2>/dev/null && { err "setup: PID $DEAD is unexpectedly alive"; exit 1; }

OUT="$TMP/out" ERRF="$TMP/err" RC=0
# rs ARGS...: run the script from the repo root; stdout in $OUT, stderr in $ERRF, status in $RC
rs() { (cd "$REPO" && bash "$SCRIPT" "$@") >"$OUT" 2>"$ERRF"; RC=$?; }

# fresh NAME: a fresh XDG_STATE_HOME, and RUN_ROOT/STATE_DIR resolved through the script
fresh() {
  export XDG_STATE_HOME="$TMP/xdg-$1"
  unset CLAUDE_CODE_SESSION_ID
  rs resolve
  RUN_ROOT=$(sed -n 's/^run-root //p' "$OUT"); STATE_DIR=$(sed -n 's/^state-dir //p' "$OUT")
}

age_lock() {  # make the lock's mtime ~3 hours old (the TTL used below is 120)
  touch -t "$(date -d '-3 hours' +%Y%m%d%H%M 2>/dev/null || date -v-3H +%Y%m%d%H%M)" "$RUN_ROOT/lock"
}

expect() {  # expect NAME COND...: record ok/FAIL for a test condition
  local name=$1; shift
  if "$@"; then ok "$name"; else err "$name (rc=$RC, stdout: $(tr '\n' '|' <"$OUT"), stderr: $(tr '\n' '|' <"$ERRF"))"; fi
}
has()    { grep -qxF "$1" "$OUT"; }
errhas() { grep -qF "$1" "$ERRF"; }

# --- resolve --------------------------------------------------------------------
fresh resolve
KEY=$(basename "$REPO")-$(printf '%s' "$(cd "$REPO" && git rev-parse --show-toplevel)" | git hash-object --stdin | cut -c1-8)
expect "resolve: repo key, run root and state dir" \
  test "$RC" -eq 0 -a "$(sed -n 's/^repo-key //p' "$OUT")" = "$KEY" \
       -a "$RUN_ROOT" = "$XDG_STATE_HOME/issue-runner/$KEY" -a "$STATE_DIR" = "$RUN_ROOT/state"
expect "resolve: creates nothing" test ! -e "$XDG_STATE_HOME"

# --- fresh init -----------------------------------------------------------------
fresh init
export CLAUDE_CODE_SESSION_ID=sess-A
rs init "$LIVE" 120
expect "fresh init: exit 0, state new" eval '[ "$RC" -eq 0 ] && has "state new" && has "state-dir $STATE_DIR"'
expect "fresh init: lock holds the owner pid" test "$(cat "$RUN_ROOT/lock")" = "$LIVE"
expect "fresh init: session pointer written" test "$(cat "$RUN_ROOT/session")" = sess-A
expect "fresh init: state dir created, no temp pointer left" \
  eval '[ -d "$STATE_DIR" ] && [ -z "$(ls "$RUN_ROOT" | grep session.tmp)" ]'

# --- live lock refusal ----------------------------------------------------------
fresh live-pid
export CLAUDE_CODE_SESSION_ID=sess-A
rs init "$DEAD" 120; mkdir -p "$STATE_DIR/issue-1"
echo "$LIVE" > "$RUN_ROOT/lock"; age_lock; echo "note" > "$RUN_ROOT/paused"
export CLAUDE_CODE_SESSION_ID=sess-B
rs init "$DEAD" 120
expect "live PID (old heartbeat): refused" \
  eval '[ "$RC" -eq 1 ] && errhas "live issue-runner in this repo" && errhas "pid $LIVE alive" && [ ! -s "$OUT" ]'
expect "live PID: nothing rotated or rewritten, pause note kept" \
  eval '[ -d "$STATE_DIR/issue-1" ] && [ "$(cat "$RUN_ROOT/lock")" = "$LIVE" ] && [ "$(cat "$RUN_ROOT/session")" = sess-A ] && [ -e "$RUN_ROOT/paused" ]'
export CLAUDE_CODE_SESSION_ID=sess-A
rs init "$DEAD" 120
expect "live PID: refused even for the same session" eval '[ "$RC" -eq 1 ] && errhas "pid $LIVE alive"'

fresh live-heartbeat
export CLAUDE_CODE_SESSION_ID=sess-A
rs init "$DEAD" 120
export CLAUDE_CODE_SESSION_ID=sess-B
rs init "$DEAD" 120
expect "dead PID, fresh heartbeat, other session: refused" \
  eval '[ "$RC" -eq 1 ] && errhas "pid $DEAD dead, last heartbeat"'
unset CLAUDE_CODE_SESSION_ID
rs init "$DEAD" 120
expect "dead PID, fresh heartbeat, no session id: refused" eval '[ "$RC" -eq 1 ]'

# --- stale lock takeover --------------------------------------------------------
fresh stale
export CLAUDE_CODE_SESSION_ID=sess-A
rs init "$DEAD" 120; mkdir -p "$STATE_DIR/issue-1"; age_lock
export CLAUDE_CODE_SESSION_ID=sess-B
rs init "$LIVE" 120
expect "dead PID, heartbeat older than the TTL: taken over" \
  eval '[ "$RC" -eq 0 ] && [ "$(cat "$RUN_ROOT/lock")" = "$LIVE" ] && [ "$(cat "$RUN_ROOT/session")" = sess-B ]'

fresh empty-lock
mkdir -p "$RUN_ROOT"; : > "$RUN_ROOT/lock"
rs init "$LIVE" 120
expect "empty (truncated) lock with a fresh mtime: taken over" \
  eval '[ "$RC" -eq 0 ] && [ "$(cat "$RUN_ROOT/lock")" = "$LIVE" ]'

fresh paused
mkdir -p "$RUN_ROOT"; echo "credit/usage-limit exhausted: 2026-01-01T00:00:00Z" > "$RUN_ROOT/paused"
rs init "$LIVE" 120
expect "init clears a stale pause note" eval '[ "$RC" -eq 0 ] && [ ! -e "$RUN_ROOT/paused" ]'

# --- same-session re-entry ------------------------------------------------------
fresh reentry
export CLAUDE_CODE_SESSION_ID=sess-A
rs init "$DEAD" 120; mkdir -p "$STATE_DIR/issue-7"; echo implementing > "$STATE_DIR/issue-7/status"
rs init "$LIVE" 120
expect "same session, dead PID, fresh heartbeat: re-entry keeps state" \
  eval '[ "$RC" -eq 0 ] && has "state kept: same session re-entering its unfinished run" && [ "$(cat "$STATE_DIR/issue-7/status")" = implementing ]'
expect "re-entry: no backup made, lock taken" \
  eval '[ -z "$(ls "$RUN_ROOT" | grep state.prev)" ] && [ "$(cat "$RUN_ROOT/lock")" = "$LIVE" ]'

fresh merge-ready
export CLAUDE_CODE_SESSION_ID=sess-A
rs init "$DEAD" 120; mkdir -p "$STATE_DIR/issue-7"; age_lock
export CLAUDE_CODE_SESSION_ID=sess-B
rs init "$LIVE" 120 --merge-ready
expect "--merge-ready: another session's state kept" \
  eval '[ "$RC" -eq 0 ] && has "state kept: same session re-entering its unfinished run" && [ -d "$STATE_DIR/issue-7" ]'

# --- rotation -------------------------------------------------------------------
fresh rotate
export CLAUDE_CODE_SESSION_ID=sess-A
rs init "$DEAD" 120; mkdir -p "$STATE_DIR/issue-3"; age_lock
export CLAUDE_CODE_SESSION_ID=sess-B
rs init "$LIVE" 120
PREV=$(sed -n 's/^state rotated: //p' "$OUT")
expect "other session: previous state rotated to state.prev.*" \
  eval '[ "$RC" -eq 0 ] && case "$PREV" in "$RUN_ROOT"/state.prev.*) true;; *) false;; esac && [ -d "$PREV/issue-3" ]'
expect "rotation: backup carries the pointer it was filed under; new state empty" \
  eval '[ "$(cat "$PREV/session")" = sess-A ] && [ -d "$STATE_DIR" ] && [ -z "$(ls -A "$STATE_DIR")" ] && [ "$(cat "$RUN_ROOT/session")" = sess-B ]'

fresh released
export CLAUDE_CODE_SESSION_ID=sess-A
rs init "$LIVE" 120; mkdir -p "$STATE_DIR/issue-3"
rs release "$RUN_ROOT"
expect "release: lock and session pointer removed" \
  eval '[ "$RC" -eq 0 ] && has "released: lock session" && [ ! -e "$RUN_ROOT/lock" ] && [ ! -e "$RUN_ROOT/session" ]'
rs init "$LIVE" 120
expect "after a clean release, the same session starts a new run (rotates)" \
  eval '[ "$RC" -eq 0 ] && grep -q "^state rotated: " "$OUT"'
rs release "$RUN_ROOT" --lock-only
expect "release --lock-only keeps the session pointer" \
  eval '[ "$RC" -eq 0 ] && has "released: lock" && [ ! -e "$RUN_ROOT/lock" ] && [ -e "$RUN_ROOT/session" ]'

fresh no-session-id
unset CLAUDE_CODE_SESSION_ID
rs init "$DEAD" 120; mkdir -p "$STATE_DIR/issue-3"; age_lock
rs init "$LIVE" 120
expect "no session id (empty pointer never matches): rotates" \
  eval '[ "$RC" -eq 0 ] && grep -q "^state rotated: " "$OUT" && [ "$(cat "$RUN_ROOT/session")" = "" ]'

fresh prune
mkdir -p "$RUN_ROOT/state.prev.1" "$RUN_ROOT/state.prev.2"
touch -t "$(date -d '-8 days' +%Y%m%d%H%M 2>/dev/null || date -v-8d +%Y%m%d%H%M)" "$RUN_ROOT/state.prev.1"
rs init "$LIVE" 120
expect "init prunes state.prev.* older than 7 days, keeps newer" \
  eval '[ "$RC" -eq 0 ] && [ ! -e "$RUN_ROOT/state.prev.1" ] && [ -d "$RUN_ROOT/state.prev.2" ]'

rs release "$RUN_ROOT"; rs release "$RUN_ROOT"
expect "release with no lock says so" eval '[ "$RC" -eq 0 ] && has "released: no lock at $RUN_ROOT/lock"'

fresh fail-after-lock
mkdir -p "$RUN_ROOT"; : > "$STATE_DIR"   # a regular file where the state dir goes: mkdir fails after the lock write
export CLAUDE_CODE_SESSION_ID=sess-A
rs init "$LIVE" 120
expect "failure after taking the lock: exit 1, lock truncated (reads stale), nothing on stdout" \
  eval '[ "$RC" -eq 1 ] && errhas "cannot create state dir" && [ -f "$RUN_ROOT/lock" ] && [ ! -s "$RUN_ROOT/lock" ] && [ ! -s "$OUT" ]'
rm -f "$STATE_DIR"
rs init "$LIVE" 120
expect "after that failure, a retry takes the lock" eval '[ "$RC" -eq 0 ] && [ "$(cat "$RUN_ROOT/lock")" = "$LIVE" ]'

# --- heartbeat ------------------------------------------------------------------
fresh heartbeat
export CLAUDE_CODE_SESSION_ID=sess-A
rs init "$LIVE" 120; age_lock
rs heartbeat "$RUN_ROOT" 1
expect "heartbeat (session owns the lock): refreshed" \
  eval '[ "$RC" -eq 0 ] && has "heartbeat refreshed" && [ -z "$(find "$RUN_ROOT/lock" -mmin +1)" ]'
age_lock
export CLAUDE_CODE_SESSION_ID=sess-B
rs heartbeat "$RUN_ROOT" "$LIVE"
expect "heartbeat (another session's lock): skipped, mtime unchanged" \
  eval '[ "$RC" -eq 0 ] && grep -q "^heartbeat skipped: " "$OUT" && [ -n "$(find "$RUN_ROOT/lock" -mmin +60)" ]'
unset CLAUDE_CODE_SESSION_ID
rs heartbeat "$RUN_ROOT" "$LIVE"
expect "heartbeat (no session id, lock holds the owner pid): refreshed" \
  eval '[ "$RC" -eq 0 ] && has "heartbeat refreshed" && [ -z "$(find "$RUN_ROOT/lock" -mmin +1)" ]'
age_lock
rs heartbeat "$RUN_ROOT" "$DEAD"
expect "heartbeat (no session id, another pid): skipped" \
  eval '[ "$RC" -eq 0 ] && grep -q "^heartbeat skipped: " "$OUT" && [ -n "$(find "$RUN_ROOT/lock" -mmin +60)" ]'
rm -f "$RUN_ROOT/lock"
export CLAUDE_CODE_SESSION_ID=sess-A
rs heartbeat "$RUN_ROOT" "$LIVE"
expect "heartbeat never recreates a deleted lock" \
  eval '[ "$RC" -eq 0 ] && grep -q "^heartbeat skipped: no lock" "$OUT" && [ ! -e "$RUN_ROOT/lock" ]'

fresh drift
export CLAUDE_CODE_SESSION_ID=sess-A
rs init "$LIVE" 120; age_lock
( cd "$TMP" && bash "$SCRIPT" heartbeat "$RUN_ROOT" "$LIVE" ) >"$OUT" 2>"$ERRF"; RC=$?
expect "heartbeat from another cwd acts on the given run root" \
  eval '[ "$RC" -eq 0 ] && has "heartbeat refreshed" && [ -z "$(find "$RUN_ROOT/lock" -mmin +1)" ]'
( cd "$TMP" && bash "$SCRIPT" release "$RUN_ROOT" ) >"$OUT" 2>"$ERRF"; RC=$?
expect "release from another cwd acts on the given run root" \
  eval '[ "$RC" -eq 0 ] && has "released: lock session" && [ ! -e "$RUN_ROOT/lock" ]'

# --- unwritable and relative run roots -----------------------------------------
export XDG_STATE_HOME="$TMP/not-a-dir"; : > "$XDG_STATE_HOME"   # mkdir -p under a regular file fails, even as root
unset CLAUDE_CODE_SESSION_ID
rs init "$LIVE" 120
expect "unwritable run root: refused with the fix-it message, nothing on stdout" \
  eval '[ "$RC" -eq 1 ] && errhas "run root is not writable" && errhas "no fallback root" && [ ! -s "$OUT" ]'

export XDG_STATE_HOME=relative/state
rs resolve
expect "relative run root: resolve refused" eval '[ "$RC" -eq 1 ] && errhas "run root is not absolute"'
rs init "$LIVE" 120
expect "relative run root: init refused, nothing created" \
  eval '[ "$RC" -eq 1 ] && errhas "run root is not absolute" && [ ! -e "$REPO/relative" ]'

# --- an existing run root turned read-only (left by a wider-permission session) -
fresh read-only
export CLAUDE_CODE_SESSION_ID=sess-A
rs init "$DEAD" 120; mkdir -p "$STATE_DIR/sub"; age_lock
if [ "$(id -u)" -ne 0 ]; then
  chmod 555 "$RUN_ROOT"   # the probe cannot create its file there
  export CLAUDE_CODE_SESSION_ID=sess-B
  rs init "$LIVE" 120
  chmod 755 "$RUN_ROOT"
  expect "read-only run root: refused at the probe, lock untouched" \
    eval '[ "$RC" -eq 1 ] && errhas "run root is not writable" && [ "$(cat "$RUN_ROOT/lock")" = "$DEAD" ]'
else
  ok "read-only run root: skipped (running as root)"
fi

# --- usage ----------------------------------------------------------------------
fresh usage
usage_ok=1
for args in "" "bogus" "init" "init 12" "init x 120" "init 12 0" "init 12 abc" "init 12 120 --keep" \
            "heartbeat" "heartbeat /abs 0" "heartbeat rel/root 12" "heartbeat 12" "release" "release rel/root" "release /abs --all" "resolve extra"; do
  # shellcheck disable=SC2086 # intended: split the fixture's argument string
  rs $args
  [ "$RC" -eq 2 ] || { err "usage error for '$args' exits 2 (got $RC)"; usage_ok=0; }
done
[ "$usage_ok" -eq 1 ] && ok "usage errors exit 2"
expect "usage errors create nothing" test ! -e "$XDG_STATE_HOME"

# --- not a repository -----------------------------------------------------------
( cd "$TMP" && bash "$SCRIPT" resolve ) >"$OUT" 2>"$ERRF"; RC=$?
expect "outside a git repository: exit 1" eval '[ "$RC" -eq 1 ] && errhas "not inside a git repository"'

if [ "$fail" -ne 0 ]; then
  printf '\ntest-run-state: FAILED\n' >&2
  exit 1
fi
printf '\ntest-run-state: OK\n'
