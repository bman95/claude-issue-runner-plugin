#!/usr/bin/env bash
#
# Fixtures for issue-runner's integration contract, slice 1 of
# docs/integration-rfc.md: the bundled script
# skills/issue-runner/scripts/integration.sh, which discovers
# `.issue-runner/integration` on the base branch's tip, sends the lifecycle
# hints its `hint:` command declares, and runs `--flush`.
# `docs/scenarios.md` rows 67–71 are the human-readable contract (row 72, the
# changed-mode gate, is fixtured in test-validation-contract.sh and
# test-merge-ready.sh). This script
# is their executable form for the part that is pure shell: the grammar, the
# trust rule (the base tip's copy, never the working tree's), the environment
# table (RFC §5.5), the bound, and the rule that a failing hint is a report line
# and never a failure.
#
# The hint command under test is a dump script that writes its ISSUE_RUNNER_*
# environment to a file named after the hint. A stub `gh` on PATH answers the
# `merged --pr` query.
#
# Run directly, or from scripts/lint.sh (and so from CI). Dependency-free:
# bash + git + coreutils. Exits non-zero on the first-or-any failure.

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/skills/issue-runner/scripts/integration.sh"

fail=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Hermetic git: no user/system config.
export HOME="$TMP" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
unset XDG_CONFIG_HOME
export INTEGRATION_HINT_BOUND=60

ok()  { printf 'ok:   %s\n' "$1"; }
err() { printf 'FAIL: %s\n' "$1" >&2; fail=1; }

if [ ! -f "$SCRIPT" ]; then err "integration.sh not found"; exit 1; fi
if bash -n "$SCRIPT" 2>"$TMP/parse.err"; then ok "integration.sh parses (bash -n)"
else err "integration.sh does not parse:"; cat "$TMP/parse.err" >&2; fi

# --- Stub gh ------------------------------------------------------------------
# `gh pr view P` prints $GH_STUB/view-P (the line gh's --jq would produce), or fails.
mkdir -p "$TMP/bin" "$TMP/gh"
export GH_STUB="$TMP/gh"
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
[ "$1 $2" = "pr view" ] && [ -f "$GH_STUB/view-$3" ] && { cat "$GH_STUB/view-$3"; exit 0; }
exit 1
EOF
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"

# --- The hint command: dumps its environment ------------------------------------
DUMPS="$TMP/dumps"
mkdir -p "$DUMPS"
cat > "$TMP/dump.sh" <<EOF
#!/usr/bin/env bash
env | grep '^ISSUE_RUNNER_' | sort > "$DUMPS/\${ISSUE_RUNNER_HINT:-none}"
pwd > "$DUMPS/\${ISSUE_RUNNER_HINT:-none}.cwd"
exit \${DUMP_EXIT:-0}
EOF
DUMP_CMD="bash $TMP/dump.sh"

# --- Repositories ---------------------------------------------------------------
ORIGIN="$TMP/origin.git"
REPO="$TMP/repo"
WORK="$TMP/work"
git init -q --bare "$ORIGIN"
git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
git init -q "$WORK"
git -C "$WORK" symbolic-ref HEAD refs/heads/main
git -C "$WORK" commit -q --allow-empty -m base
git -C "$WORK" remote add origin "$ORIGIN"
git -C "$WORK" push -q origin main
git clone -q "$ORIGIN" "$REPO"

# set_contract CONTENT: commit CONTENT as the base tip's contract ("-" removes it).
# CONTENT is printf'd with %b, so \r and \0 reach the file.
set_contract() {
  if [ "$1" = - ]; then
    git -C "$WORK" rm -q --ignore-unmatch .issue-runner/integration
  else
    mkdir -p "$WORK/.issue-runner"
    printf '%b' "$1" > "$WORK/.issue-runner/integration"
    git -C "$WORK" add .issue-runner/integration
  fi
  git -C "$WORK" commit -q --allow-empty -m "contract" && git -C "$WORK" push -q origin main
}

OUT="$TMP/out" RC=0
run() { (cd "$REPO" && bash "$SCRIPT" "$@") >"$OUT" 2>"$TMP/stderr"; RC=$?; }

# expect NAME EXIT TEXT: exit status and a substring of stdout.
expect() {
  if [ "$RC" -ne "$2" ]; then err "$1: exit $RC, expected $2 (stdout: $(cat "$OUT"); stderr: $(cat "$TMP/stderr"))"; return; fi
  if [ -n "$3" ] && ! grep -qF -- "$3" "$OUT"; then err "$1: stdout lacks '$3' (got: $(cat "$OUT"))"; return; fi
  ok "$1"
}
# expect_empty NAME: exit 0 and nothing on stdout.
expect_empty() {
  if [ "$RC" -ne 0 ] || [ -s "$OUT" ]; then err "$1: expected silence and exit 0, got exit $RC: $(cat "$OUT")"; else ok "$1"; fi
}

# --- Row 68: not configured ------------------------------------------------------
run discover main
expect "row 68: no file on the base tip → integration: not configured" 0 "integration: not configured"
mkdir -p "$REPO/.issue-runner"; printf 'hint: %s\n' "$DUMP_CMD" > "$REPO/.issue-runner/integration"
run discover main
expect "row 68: a working-tree copy is never read (trust rule)" 0 "integration: not configured"
rm -rf "$REPO/.issue-runner"

# --- Row 67: configured — the grammar's valid shapes ------------------------------
set_contract "# comment\n\nhint: $DUMP_CMD\n"
run discover main;   expect "row 67: hint only" 0 "integration: hint"
set_contract "status: true\n"
run discover main;   expect "row 67: status only" 0 "integration: status"
set_contract "hint: true\nstatus: true\n"
run discover main;   expect "row 67: both keys" 0 "integration: hint, status"

# --- Row 69: invalid — disabled loudly, never a stop --------------------------------
set_contract "hint: true\nnonsense\n"
run discover main;   expect "row 69: a stray line" 0 "integration: contract invalid (stray line: nonsense) — integration disabled for this run"
set_contract "hint: true\nhint: false\n"
run discover main;   expect "row 69: a duplicated key" 0 "contract invalid (duplicated key: hint)"
set_contract "hint: # TODO\n"
run discover main;   expect "row 69: a comment-only command is a placeholder" 0 "contract invalid (stray line: hint: # TODO)"
set_contract "# nothing yet\n\n"
run discover main;   expect "row 69: comments only — no command declared" 0 "contract invalid (no hint: or status: line)"
set_contract "hint: true\r\n"
run discover main;   expect "row 69: CRLF line endings" 0 "contract invalid (CRLF line endings)"
set_contract "hint: tr\0ue\n"
run discover main;   expect "row 69: a NUL byte (judged on the blob)" 0 "contract invalid (NUL byte)"
run discover nope;   expect "unresolvable base: disabled, exit 0, never a stop" 0 "integration: unresolvable (cannot fetch origin/nope) — integration disabled for this run"
run discover "";     expect "empty default branch → usage error" 2 ""
run bogus;           expect "unknown mode → usage error" 2 ""

# --- State recording ------------------------------------------------------------------
# new_state: a state dir with run-id, invocation, scope and a DAG, as run-state.sh
# init and Step 1 leave it. Issue statuses are set per fixture.
SD="$TMP/state"
new_state() {
  rm -rf "$SD"; mkdir -p "$SD"
  printf 'repo-key@2026-09-27T10:00:00Z\n' > "$SD/run-id"
  printf '2026-09-27T11:00:00Z\n' > "$SD/invocation"
  printf '1\n2\n3\n4\n5\n6\n7\n' > "$SD/scope.txt"
  printf '1:\n2: 1\n3:\n4:\n5:\n6: 1\n7: 4\n' > "$SD/dag.txt"
  local n; for n in 1 2 3 4 5 6 7; do mkdir -p "$SD/issue-$n"; done
  rm -f "$DUMPS"/*
}
setst() { printf '%s\n' "$2" > "$SD/issue-$1/status"; }
# env_of HINT VAR: the value the hint command saw, or <absent>.
env_of() {
  local v
  v=$(grep -E "^$2=" "$DUMPS/$1" 2>/dev/null | head -n 1)
  if [ -n "$v" ]; then printf '%s' "${v#*=}"; else printf '<absent>'; fi
}
# check_env NAME HINT VAR=VALUE…: every pair must hold (VALUE <absent> for absent).
check_env() {
  local name=$1 hint=$2 pair var want got bad=""
  shift 2
  [ -f "$DUMPS/$hint" ] || { err "$name: the $hint hint never ran"; return; }
  for pair in "$@"; do
    var=${pair%%=*} want=${pair#*=}
    got=$(env_of "$hint" "$var")
    [ "$got" = "$want" ] || bad="$bad $var=$got (want $want);"
  done
  if [ -n "$bad" ]; then err "$name:$bad"; else ok "$name"; fi
}

set_contract "hint: $DUMP_CMD\n"
new_state
run discover main "$SD"
expect "discover with a state dir prints the same line" 0 "integration: hint"
if [ -f "$SD/integration-contract" ] && [ "$(cat "$SD/integration-base")" = main ] \
   && [ "$(cat "$SD/integration-mode")" = merge ] && [ "$(cat "$SD/integration-discovery")" = "integration: hint" ]; then
  ok "discover records the contract, base, mode and line"
else err "discover did not record its state files"; fi

# --- Row 67: the environment table (RFC §5.5) ---------------------------------------
# 1 done, 2 implementing at step=9, 3 pending, 4 blocked, 5 implementing at step=8.1,
# 6 ready (dep 1 done), 7 ready (dep 4 blocked).
setst 1 done; setst 2 implementing; setst 3 pending; setst 4 blocked; setst 5 implementing; setst 6 ready; setst 7 ready
printf 'step=9 pr=#12\n' > "$SD/issue-2/progress"
printf 'step=8.1 iter=2 pr=#15\n' > "$SD/issue-5/progress"
export ISSUE_RUNNER_STALE=leak ISSUE_RUNNER_ISSUE=99
run hint "$SD" run-start
unset ISSUE_RUNNER_STALE ISSUE_RUNNER_ISSUE
expect "run-start launches and returns at once" 0 "integration: hint run-start launched"
MERGE1=1111111111111111111111111111111111111111
printf '%s main 21\n' "$MERGE1" > "$SD/issue-1/merge-oid"
run hint "$SD" merged 1
expect "merged launches" 0 "integration: hint merged #1 launched"
MERGE6=6666666666666666666666666666666666666666666666666666666666666666
printf 'MERGED %s release\n' "$MERGE6" > "$GH_STUB/view-26"
setst 6 done
run hint "$SD" merged 6 --pr 26 --untried "6 7"
expect "merged --pr launches" 0 "integration: hint merged #6 launched"
run run-complete "$SD" completed
expect "run-complete drains and reports every hint" 0 "integration: hint run-complete: sent (exit 0)"
grep -qF "integration: hint run-start: sent (exit 0)" "$OUT" && grep -qF "integration: hint merged #1: sent (exit 0)" "$OUT" \
  && grep -qF "integration: hint merged #6: sent (exit 0)" "$OUT" && ok "run-complete collected run-start and both merged hints" \
  || err "run-complete did not collect every hint: $(cat "$OUT")"
check_env "row 67: run-start environment" run-start ISSUE_RUNNER_HINT_VERSION=1 ISSUE_RUNNER_HINT=run-start \
  ISSUE_RUNNER_RUN=repo-key@2026-09-27T10:00:00Z ISSUE_RUNNER_INVOCATION=2026-09-27T11:00:00Z ISSUE_RUNNER_RUN_STATE=active \
  ISSUE_RUNNER_BASE=main ISSUE_RUNNER_REMAINING=3 "ISSUE_RUNNER_REVISION=<absent>" "ISSUE_RUNNER_ISSUE=<absent>" \
  "ISSUE_RUNNER_REASON=<absent>" "ISSUE_RUNNER_NEAR_COMPLETE=<absent>" "ISSUE_RUNNER_STALE=<absent>"
[ "$(cat "$DUMPS/run-start.cwd")" = "$(cd "$REPO" && pwd -P)" ] && ok "the hint runs from the repository root" \
  || err "the hint ran from $(cat "$DUMPS/run-start.cwd"), not the repository root"
check_env "row 67: merged environment (REMAINING excludes blocked and ready; NEAR_COMPLETE reads step=9)" merged \
  ISSUE_RUNNER_HINT=merged ISSUE_RUNNER_RUN_STATE=active ISSUE_RUNNER_BASE=release ISSUE_RUNNER_REVISION="$MERGE6" \
  ISSUE_RUNNER_ISSUE=6 ISSUE_RUNNER_PR=26 ISSUE_RUNNER_REMAINING=3 ISSUE_RUNNER_NEAR_COMPLETE=1 "ISSUE_RUNNER_REASON=<absent>"
[ "$(cat "$SD/issue-6/merge-oid" 2>/dev/null)" = "$MERGE6 release 26" ] && ok "merged --pr records merge-oid from GitHub's answer" \
  || err "merged --pr recorded: $(cat "$SD/issue-6/merge-oid" 2>/dev/null)"
check_env "row 67: run-complete environment (REVISION and BASE of the last merged sent)" run-complete \
  ISSUE_RUNNER_HINT=run-complete ISSUE_RUNNER_RUN_STATE=complete ISSUE_RUNNER_REMAINING=0 ISSUE_RUNNER_REASON=completed \
  ISSUE_RUNNER_REVISION="$MERGE6" ISSUE_RUNNER_BASE=release "ISSUE_RUNNER_ISSUE=<absent>" "ISSUE_RUNNER_PR=<absent>" \
  "ISSUE_RUNNER_NEAR_COMPLETE=<absent>"

# REMAINING counts the --untried issues still ready with their dependencies done.
new_state; run discover main "$SD" >/dev/null
setst 1 done; setst 6 ready; setst 7 ready; setst 4 blocked; setst 3 done; setst 2 done; setst 5 done
printf '%s main 21\n' "$MERGE1" > "$SD/issue-1/merge-oid"
run hint "$SD" merged 1 --untried "6 7"
run run-complete "$SD" paused
check_env "--merge-ready pass: REMAINING counts untried ready issues whose dependencies are done" merged ISSUE_RUNNER_REMAINING=1
check_env "run-complete carries its reason" run-complete ISSUE_RUNNER_REASON=paused ISSUE_RUNNER_REVISION="$MERGE1" ISSUE_RUNNER_BASE=main

# An invocation that sent no merged: run-complete names no revision.
new_state; run discover main "$SD" >/dev/null
printf '2026-09-27T09:00:00Z %s main\n' "$MERGE1" > "$SD/integration-last-merged"   # an earlier invocation's
run run-complete "$SD" stopped
check_env "run-complete with no merged from this invocation: REVISION absent, BASE the default branch" run-complete \
  "ISSUE_RUNNER_REVISION=<absent>" ISSUE_RUNNER_BASE=main ISSUE_RUNNER_REASON=stopped

# --no-merge: both counts are 0.
new_state; run discover main "$SD" --no-merge >/dev/null
setst 1 done; setst 2 implementing; setst 3 pending
printf 'step=9.2 pr=#12\n' > "$SD/issue-2/progress"
printf '%s main 21\n' "$MERGE1" > "$SD/issue-1/merge-oid"
run hint "$SD" run-start
run hint "$SD" merged 1
run run-complete "$SD" completed
check_env "--no-merge: run-start REMAINING is 0" run-start ISSUE_RUNNER_REMAINING=0
check_env "--no-merge: merged REMAINING and NEAR_COMPLETE are 0" merged ISSUE_RUNNER_REMAINING=0 ISSUE_RUNNER_NEAR_COMPLETE=0

# No merge record: the merged hint is not sent, and says so.
new_state; run discover main "$SD" >/dev/null
run hint "$SD" merged 3
expect "merged without a merge-oid is not sent, and says why" 0 "integration: hint merged #3 not sent (no merge commit recorded)"
printf 'OPEN - main\n' > "$GH_STUB/view-30"
printf '%s main 21\n' "$MERGE1" > "$SD/issue-3/merge-oid"
run hint "$SD" merged 3 --pr 30
[ ! -e "$SD/issue-3/merge-oid" ] && grep -qF "not sent (no merge commit recorded)" "$OUT" \
  && ok "merged --pr on a PR that is not MERGED records nothing and sends nothing" \
  || err "merged --pr on an open PR: $(cat "$OUT"); merge-oid: $(cat "$SD/issue-3/merge-oid" 2>/dev/null)"
run run-complete "$SD" completed
grep -qF "integration: hint merged #3: not sent (no merge commit recorded)" "$OUT" \
  && ok "the unsent merged hint is reported at Step 5" || err "unsent hint missing from run-complete: $(cat "$OUT")"

# --- Row 70: a failing or hung hint command is reported, never a failure -------------
set_contract "hint: exit 3\n"
new_state; run discover main "$SD" >/dev/null
run hint "$SD" run-start
run run-complete "$SD" completed
expect "row 70: a failing hint command is reported, exit 0" 0 "integration: hint run-start: adapter exited 3"
grep -qF "integration: hint run-complete: adapter exited 3" "$OUT" && ok "row 70: run-complete's own failure is reported too" \
  || err "run-complete's failure missing: $(cat "$OUT")"

export INTEGRATION_HINT_BOUND=2
set_contract "hint: sleep 30\n"
new_state; run discover main "$SD" >/dev/null
START=$(date +%s)
run run-complete "$SD" completed
ELAPSED=$(( $(date +%s) - START ))
expect "row 70: a hung hint is killed at the bound and reported as timed out" 0 "integration: hint run-complete: timed out"
[ "$ELAPSED" -lt 15 ] && ok "the bound held ($ELAPSED s)" || err "a hung hint took $ELAPSED s"

set_contract "hint: trap '' TERM; sleep 30\n"
new_state; run discover main "$SD" >/dev/null
START=$(date +%s)
run run-complete "$SD" completed
ELAPSED=$(( $(date +%s) - START ))
expect "a hint that ignores TERM is KILLed at the bound" 0 "timed out"
[ "$ELAPSED" -lt 15 ] && ok "the TERM-ignoring hint still ended within the bound ($ELAPSED s)" || err "took $ELAPSED s"

set_contract "hint: sleep 30 & echo \$! > $TMP/worker.pid; exit 0\n"
new_state; run discover main "$SD" >/dev/null
run run-complete "$SD" completed
expect "a hint that detaches a worker still reports its own exit" 0 "integration: hint run-complete: sent (exit 0)"
WPID=$(cat "$TMP/worker.pid" 2>/dev/null)
sleep 1
if [ -n "$WPID" ] && ! kill -0 "$WPID" 2>/dev/null; then ok "the sweep killed the detached worker"
else err "the detached worker $WPID outlived the wrapper"; kill "$WPID" 2>/dev/null; fi
export INTEGRATION_HINT_BOUND=60

# A launched hint still running when Step 5 starts is drained, not abandoned.
set_contract "hint: sleep 2; exit 0\n"
new_state; run discover main "$SD" >/dev/null
run hint "$SD" run-start
run run-complete "$SD" completed
grep -qF "integration: hint run-start: sent (exit 0)" "$OUT" && ok "Step 5 drains a hint still running" \
  || err "the running hint was not drained: $(cat "$OUT")"

# The foreground variant (the Codex edition): delivered before the call returns.
set_contract "hint: $DUMP_CMD\n"
new_state; run discover main "$SD" >/dev/null
INTEGRATION_HINT_FOREGROUND=1 run hint "$SD" run-start
expect "INTEGRATION_HINT_FOREGROUND=1 delivers before returning" 0 "integration: hint run-start delivered"
[ -f "$DUMPS/run-start" ] && ok "the foreground hint already ran when the call returned" || err "the foreground hint had not run"
run run-complete "$SD" completed
grep -qF "integration: hint run-start: sent (exit 0)" "$OUT" && ok "a foreground hint is reported at Step 5 like any other" \
  || err "foreground hint missing from run-complete: $(cat "$OUT")"

# --- Rows 68 and 69 at the call sites: nothing configured, or disabled -----------------
set_contract -
new_state; run discover main "$SD" >/dev/null
printf 'MERGED %s main\n' "$MERGE1" > "$GH_STUB/view-40"
run hint "$SD" run-start;                   expect_empty "row 68: not configured → run-start sends nothing, prints nothing"
run hint "$SD" merged 3 --pr 40;            expect_empty "row 68: not configured → merged sends nothing, prints nothing"
[ "$(cat "$SD/issue-3/merge-oid" 2>/dev/null)" = "$MERGE1 main 40" ] && ok "merge-oid is still recorded on merge proof" \
  || err "merge-oid not recorded when unconfigured"
run run-complete "$SD" completed;           expect_empty "row 68: not configured → Step 5 prints nothing"
[ -z "$(ls "$DUMPS")" ] && ok "row 68: no command ran" || err "a command ran with no contract: $(ls "$DUMPS")"

set_contract "hint: $DUMP_CMD\nbogus\n"
new_state; run discover main "$SD" >/dev/null
run hint "$SD" run-start;                   expect_empty "row 69: invalid → no hint sent"
run run-complete "$SD" completed
expect "row 69: invalid → the disabled line is repeated at Step 5" 0 "integration: contract invalid (stray line: bogus) — integration disabled for this run"
[ -z "$(ls "$DUMPS")" ] && ok "row 69: no command ran" || err "a command ran from an invalid contract"

# --- Row 71: --flush ----------------------------------------------------------------------
RR="$TMP/runroot"; mkdir -p "$RR/state"
set_contract -
run flush "$RR" main;   expect "row 71: flush with no contract is not sent, exit 1" 1 "flush: not sent (no hint command)"
grep -qF "integration: not configured" "$OUT" && ok "flush prints its discovery line first" || err "flush discovery line missing"
set_contract "status: true\n"
run flush "$RR" main;   expect "row 71: flush with a status-only contract is not sent" 1 "flush: not sent (no hint command)"
set_contract "hint: true\nbogus\n"
run flush "$RR" main;   expect "row 71: flush on an invalid contract prints the disabled spelling" 1 "integration: disabled (contract invalid: stray line: bogus)"
run flush "$RR" nope;   expect "row 71: flush on an unresolvable base" 1 "integration: disabled (unresolvable: cannot fetch origin/nope)"
set_contract "hint: $DUMP_CMD\n"
rm -f "$DUMPS"/*
run flush "$RR" main;   expect "row 71: flush sends and says so" 0 "flush: sent (exit 0)"
TIP=$(git -C "$REPO" rev-parse origin/main)
check_env "row 71: flush outside a live run" flush ISSUE_RUNNER_HINT=flush ISSUE_RUNNER_RUN=none ISSUE_RUNNER_RUN_STATE=complete \
  ISSUE_RUNNER_BASE=main ISSUE_RUNNER_REVISION="$TIP" "ISSUE_RUNNER_REMAINING=<absent>"
printf '%s\n' "$$" > "$RR/lock"; printf 'repo-key@2026-09-27T10:00:00Z\n' > "$RR/state/run-id"
run flush "$RR" main
check_env "row 71: flush during a live run carries its run id" flush ISSUE_RUNNER_RUN=repo-key@2026-09-27T10:00:00Z ISSUE_RUNNER_RUN_STATE=active
[ ! -e "$RR/state/integration-hints" ] && [ ! -e "$RR/state/integration-discovery" ] && ok "flush writes no run state" \
  || err "flush wrote run state"
rm -f "$RR/lock"
DUMP_EXIT=4 run flush "$RR" main
expect "row 71: flush reports the adapter's exit, never silently" 1 "flush: adapter exited 4"
run flush relative main; expect "flush needs an absolute run root" 2 ""

if [ "$fail" -ne 0 ]; then
  printf '\ntest-integration-contract: FAILED\n' >&2
  exit 1
fi
printf '\ntest-integration-contract: OK\n'
