#!/usr/bin/env bash
# shellcheck disable=SC2016 # file-wide: `holds ... eval '…'` evaluates its conditions later, on purpose
#
# Fixtures for scripts/merge-ready.sh: the mechanical part of issue-runner's
# `--merge-ready` pass (the PR state, the refresh against the PR head and the
# base, the checks re-check, the head-pinned merge). `docs/scenarios.md` is
# the human-readable contract; this script is its executable form for the rows
# listed in IN_SCOPE_ROWS at the bottom.
#
# `gh` is a stub on PATH that answers from per-fixture files and logs every
# call. git is real: a bare origin, a clone the `gh` subcommands run in (the
# orchestrator's cwd), and a worktree on the PR branch the refresh works in.
# Validation runs through a stub validation script (every exit status the #53
# script can return) and, for two fixtures, through the real
# skills/gh-issue/scripts/validation-contract.sh against a contract on origin.
#
# Run directly, or from scripts/lint.sh (and so from CI). Dependency-free:
# bash + git + coreutils. Exits non-zero on the first-or-any failure.

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="$ROOT/skills/issue-runner/scripts/merge-ready.sh"
REAL_VC="$ROOT/skills/gh-issue/scripts/validation-contract.sh"
SCENARIOS="$ROOT/docs/scenarios.md"

fail=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Hermetic git: no user/system config.
export HOME="$TMP" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
unset XDG_CONFIG_HOME
export MERGE_READY_POLL_SLEEP=0

ok()  { printf 'ok:   %s\n' "$1"; }
err() { printf 'FAIL: %s\n' "$1" >&2; fail=1; }

if [ ! -f "$SCRIPT" ]; then err "merge-ready.sh not found"; exit 1; fi

# --- Stub gh ------------------------------------------------------------------
# Answers from files in $GH_STUB:
#   state          `gh pr view P --json state`            OPEN | MERGED | CLOSED | …
#   head           `gh pr view P --json headRefName,…`    "branch oid base"
#   head-oid       `gh pr view P --json headRefOid`       the current head
#   title, body    `gh pr view P --json title|body`
#   merge-sha      `gh pr view P --json mergeCommit`
#   checks-K       the K-th `gh pr checks P`: first line its exit status, the
#                  rest its output (the last file present repeats)
#   merge-rc       `gh pr merge` exit status (absent = 0); merge-lands: a
#                  successful call also writes MERGED to `state`
#   fail-view-<f>  `gh pr view --json <f>` fails
# Every call is appended to $GH_STUB/log as `[arg][arg]…`.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
d=$GH_STUB
{ for a in "$@"; do printf '[%s]' "$a"; done; printf '\n'; } >> "$d/log"
case "$1 $2" in
  "pr view")
    field=$5
    [ -f "$d/fail-view-${field%%,*}" ] && exit 1
    case $field in
      state) f=state ;; headRefName,*) f=head ;; headRefOid) f=head-oid ;;
      title) f=title ;; body) f=body ;; mergeCommit) f=merge-sha ;; *) exit 1 ;;
    esac
    [ -f "$d/$f" ] || exit 1; cat "$d/$f"; exit 0 ;;
  "pr checks")
    n=$(( $(cat "$d/checks-count" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$d/checks-count"
    k=$n; while [ "$k" -gt 1 ] && [ ! -f "$d/checks-$k" ]; do k=$((k - 1)); done
    [ -f "$d/checks-$k" ] || exit 1
    tail -n +2 "$d/checks-$k"; exit "$(head -n 1 "$d/checks-$k")" ;;
  "pr merge")
    rc=$(cat "$d/merge-rc" 2>/dev/null || echo 0)
    [ "$rc" = 0 ] && [ -f "$d/merge-lands" ] && echo MERGED > "$d/state"
    [ "$rc" = 0 ] || echo "merge refused by the stub" >&2
    exit "$rc" ;;
esac
exit 1
EOF
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"

stub_reset() { rm -rf "$TMP/stub"; mkdir -p "$TMP/stub"; export GH_STUB="$TMP/stub"; : > "$GH_STUB/log"; }
stub() { printf '%s\n' "$2" > "$GH_STUB/$1"; }

# --- Stub validation script -----------------------------------------------------
# `<mode>.rc` / `<mode>.out` in $VC_STUB give each mode's exit status and output
# (absent = 0 and `validation: <mode> passed`); every call's mode and base are
# appended to $VC_STUB/log.
VC="$TMP/vc/validation-contract.sh"
mkdir -p "$TMP/vc"
cat > "$VC" <<'EOF'
#!/usr/bin/env bash
d=$VC_STUB
echo "$1 $2" >> "$d/log"
[ -f "$d/$1.sleep" ] && sleep "$(cat "$d/$1.sleep")"
[ -f "$d/$1.cmd" ] && bash "$d/$1.cmd"
if [ -f "$d/$1.out" ]; then cat "$d/$1.out"; else echo "validation: $1 passed"; fi
[ -f "$d/$1.rc" ] && exit "$(cat "$d/$1.rc")"
exit 0
EOF
vc_reset() { rm -rf "$TMP/vcs"; mkdir -p "$TMP/vcs"; export VC_STUB="$TMP/vcs"; : > "$VC_STUB/log"; }
vc() { printf '%s\n' "$3" > "$VC_STUB/$1.out"; printf '%s\n' "$2" > "$VC_STUB/$1.rc"; }

# --- Repositories -------------------------------------------------------------
# Every refresh fixture starts from a fresh layout (`layout`): origin with `main`
# and the PR branch one commit ahead, the orchestrator's clone, a worktree of
# it on the PR branch, and a second clone that pushes "from elsewhere".
BR=feat/issue-7-slug
layout() {
  rm -rf "$TMP/origin.git" "$TMP/repo" "$TMP/wt" "$TMP/other"
  git init -q --bare "$TMP/origin.git"
  git -C "$TMP/origin.git" symbolic-ref HEAD refs/heads/main
  git init -q "$TMP/repo"
  git -C "$TMP/repo" symbolic-ref HEAD refs/heads/main
  echo base > "$TMP/repo/f.txt"
  git -C "$TMP/repo" add f.txt && git -C "$TMP/repo" commit -q -m base
  git -C "$TMP/repo" remote add origin "$TMP/origin.git"
  git -C "$TMP/repo" push -q origin main
  git -C "$TMP/repo" worktree add -q -b "$BR" "$TMP/wt" main 2>/dev/null
  echo work > "$TMP/wt/g.txt"
  git -C "$TMP/wt" add g.txt && git -C "$TMP/wt" commit -q -m work
  git -C "$TMP/wt" push -q origin "$BR" 2>/dev/null
  git clone -q "$TMP/origin.git" "$TMP/other" 2>/dev/null
  HEAD_OID=$(git -C "$TMP/wt" rev-parse HEAD)
  stub_reset; vc_reset
  stub head "$BR $HEAD_OID main"
}
# advance_base: a commit on main from elsewhere (FILE CONTENT)
advance_base() {
  git -C "$TMP/other" checkout -q main
  printf '%s\n' "$2" > "$TMP/other/$1"
  git -C "$TMP/other" add "$1" && git -C "$TMP/other" commit -q -m "base moves" && git -C "$TMP/other" push -q origin main
}
# push_head: a commit on the PR branch from elsewhere; updates the gh stub's head
push_head() {
  git -C "$TMP/other" fetch -q origin && git -C "$TMP/other" checkout -q -B "$BR" "origin/$BR"
  echo more > "$TMP/other/h.txt"
  git -C "$TMP/other" add h.txt && git -C "$TMP/other" commit -q -m "pushed elsewhere" && git -C "$TMP/other" push -q origin "$BR"
  HEAD_OID=$(git -C "$TMP/other" rev-parse HEAD)
  stub head "$BR $HEAD_OID main"
}
origin_tip() { git -C "$TMP/origin.git" rev-parse "refs/heads/$BR"; }

# run ARGS… -> $OUT, $RC (from the orchestrator's clone)
run() { OUT=$(cd "$TMP/repo" || exit 99; bash "$SCRIPT" "$@" 2>"$TMP/stderr"); RC=$?; }
# expect NAME EXPECTED_EXIT EXPECTED_STDOUT
expect() {
  if [ "$RC" = "$2" ] && [ "$OUT" = "$3" ]; then ok "$1"
  else
    err "$1 (exit $RC, want $2)"
    printf '%s\n' "$3" | sed 's/^/  expected> /' >&2
    printf '%s\n' "$OUT" | sed 's/^/  actual  > /' >&2
    sed 's/^/  stderr  > /' "$TMP/stderr" >&2
  fi
}
# holds NAME CONDITION…: a post-condition
holds() { local n=$1; shift; if "$@"; then ok "$n"; else err "$n"; fi; }
wt_at() { [ "$(git -C "$TMP/wt" rev-parse HEAD)" = "$1" ]; }
wt_clean() { [ -z "$(git -C "$TMP/wt" status --porcelain)" ]; }

# ================================ state ==========================================
layout; stub_reset
stub state OPEN;   run state 12; expect "row 37: state OPEN -> open" 0 open
stub state MERGED; run state 12; expect "row 37: state MERGED (merged by hand) -> merged" 0 merged
stub state CLOSED; run state 12; expect "row 37: state CLOSED (declined) -> closed" 0 closed
stub state ""; run state 12; expect "row 37: state unrecognized -> exit 1, never open" 1 ""
rm -f "$GH_STUB/state"; run state 12; expect "row 37: state query fails -> exit 1, never open" 1 ""

# ================================ refresh ========================================
# --- unchanged ---
layout; T0=$(origin_tip)
run refresh "$TMP/wt" 12 "$VC"
expect "row 37: at the PR head, base not advanced -> unchanged" 0 "unchanged $HEAD_OID"
holds "unchanged: nothing pushed" [ "$(origin_tip)" = "$T0" ]
holds "validation runs changed, preflight, full, each against the PR's base" \
  [ "$(cat "$VC_STUB/log")" = "$(printf 'check main\nchanged main\npreflight main\nfull main')" ]

# --- refreshed: fast-forward to a head pushed from elsewhere ---
layout; push_head
run refresh "$TMP/wt" 12 "$VC"
expect "row 37: a head pushed elsewhere -> fast-forwarded, refreshed" 0 "refreshed $HEAD_OID"
holds "refreshed (ff): the worktree is at the PR head" wt_at "$HEAD_OID"
holds "refreshed (ff): validation ran on that head" [ -s "$VC_STUB/log" ]

# --- refreshed: base advanced, merged in and pushed ---
layout; advance_base b.txt new
run refresh "$TMP/wt" 12 "$VC"
NEW=$(git -C "$TMP/wt" rev-parse HEAD)
expect "row 37: base advanced (no overlap) -> merged in, pushed, refreshed" 0 "refreshed $NEW"
holds "refreshed (base): origin carries the merge" [ "$(origin_tip)" = "$NEW" ]
holds "refreshed (base): the merge's first parent is the PR head" \
  [ "$(git -C "$TMP/wt" rev-parse HEAD^1)" = "$HEAD_OID" ]

# --- stuck: conflict ---
layout; advance_base g.txt conflicting; T0=$(origin_tip)
run refresh "$TMP/wt" 12 "$VC"
expect "row 37: base merge conflicts -> stuck, never resolved" 0 "stuck merge conflict with origin/main: g.txt"
# shellcheck disable=SC2016 # evaluated by holds, on purpose
holds "conflict: merge aborted, worktree clean at the PR head" eval 'wt_at "$HEAD_OID" && wt_clean'
# shellcheck disable=SC2016 # evaluated by holds, on purpose
holds "conflict: nothing pushed, no validation run beyond the contract probe" eval '[ "$(origin_tip)" = "$T0" ] && [ "$(cat "$VC_STUB/log")" = "check main" ]'

# --- stuck: validation fails after a base merge -> the merge commit is dropped ---
layout; advance_base b.txt new; T0=$(origin_tip); vc preflight 1 "validation: preflight failed (exit 1): make test"
run refresh "$TMP/wt" 12 "$VC"
expect "row 37: failing preflight -> stuck" 0 "stuck preflight validation failed (exit 1)"
holds "failing validation: own merge commit dropped, worktree back at the PR head" wt_at "$HEAD_OID"
holds "failing validation: nothing pushed" [ "$(origin_tip)" = "$T0" ]

layout; vc full 1 "validation: full failed (exit 1): make e2e"
run refresh "$TMP/wt" 12 "$VC"
expect "failing full -> stuck" 0 "stuck full validation failed (exit 1)"

# --- stuck: the push of the base merge fails -> dropped ---
layout; advance_base b.txt new; T0=$(origin_tip)
cat > "$TMP/origin.git/hooks/pre-receive" <<'EOF'
#!/bin/sh
echo "rejected by the fixture" >&2; exit 1
EOF
chmod +x "$TMP/origin.git/hooks/pre-receive"
run refresh "$TMP/wt" 12 "$VC"
expect "row 37: push of the base merge refused -> stuck" 0 "stuck push failed after refresh — a human must retry or merge by hand"
holds "failed push: merge commit dropped, worktree back at the PR head" wt_at "$HEAD_OID"
holds "failed push: origin unchanged" [ "$(origin_tip)" = "$T0" ]

# --- stuck: head sync ---
layout; echo dirty > "$TMP/wt/g.txt"
run refresh "$TMP/wt" 12 "$VC"
expect "row 37: dirty worktree -> stuck, never reset" 0 "stuck worktree dirty — a human must reconcile"
holds "dirty: the edit survives" [ "$(cat "$TMP/wt/g.txt")" = dirty ]
layout; echo stray > "$TMP/wt/untracked.txt"
run refresh "$TMP/wt" 12 "$VC"
expect "an untracked file is dirty too" 0 "stuck worktree dirty — a human must reconcile"

layout; echo local > "$TMP/wt/l.txt"; git -C "$TMP/wt" add l.txt; git -C "$TMP/wt" commit -q -m local; L=$(git -C "$TMP/wt" rev-parse HEAD)
run refresh "$TMP/wt" 12 "$VC"
expect "row 37: worktree ahead of the PR head -> stuck, never reset" 0 \
  "stuck worktree not at the PR head and cannot fast-forward to it — a human must reconcile"
holds "ahead: the local commit survives" wt_at "$L"
layout; push_head; echo local > "$TMP/wt/l.txt"; git -C "$TMP/wt" add l.txt; git -C "$TMP/wt" commit -q -m local
run refresh "$TMP/wt" 12 "$VC"
expect "row 37: worktree diverged from the PR head -> stuck" 0 \
  "stuck worktree not at the PR head and cannot fast-forward to it — a human must reconcile"

layout; rm -f "$GH_STUB/head"
run refresh "$TMP/wt" 12 "$VC"
expect "row 37: PR head query fails -> stuck under its own reason" 0 "stuck cannot resolve the PR head — query or fetch failed"
layout; git -C "$TMP/origin.git" update-ref -d "refs/heads/$BR"
run refresh "$TMP/wt" 12 "$VC"
expect "row 37: PR head ref fetch fails -> stuck under its own reason" 0 "stuck cannot resolve the PR head — query or fetch failed"
layout; stub head "$BR $HEAD_OID gone-base"
run refresh "$TMP/wt" 12 "$VC"
expect "base branch fetch fails -> stuck" 0 "stuck cannot fetch the base branch origin/gone-base"

# --- interrupted after a base merge -> the merge commit is dropped ---
layout; advance_base b.txt new; T0=$(origin_tip); echo 3 > "$VC_STUB/preflight.sleep"
(cd "$TMP/repo" && exec bash "$SCRIPT" refresh "$TMP/wt" 12 "$VC" >"$TMP/int.out" 2>/dev/null) & BGP=$!
for _ in $(seq 1 100); do grep -q '^preflight' "$VC_STUB/log" 2>/dev/null && break; sleep 0.1; done
kill -TERM "$BGP"; wait "$BGP"
OUT=$(cat "$TMP/int.out"); RC=0
expect "row 37: a refresh killed mid-validation -> stuck, interrupted" 0 "stuck refresh interrupted before it finished — re-run it"
holds "interrupted: own merge commit dropped, worktree back at the PR head" wt_at "$HEAD_OID"
holds "interrupted: nothing pushed" [ "$(origin_tip)" = "$T0" ]

# --- stopped by a process-group signal -> prompt, and rolled back ---
if command -v setsid >/dev/null 2>&1; then
layout; advance_base b.txt new; T0=$(origin_tip); echo 60 > "$VC_STUB/preflight.sleep"
(cd "$TMP/repo" && exec setsid bash "$SCRIPT" refresh "$TMP/wt" 12 "$VC" >"$TMP/int.out" 2>/dev/null) & BGP=$!
for _ in $(seq 1 100); do grep -q '^preflight' "$VC_STUB/log" 2>/dev/null && break; sleep 0.1; done
S0=$(date +%s); kill -TERM -- "-$BGP" 2>/dev/null || kill -TERM "$BGP"; wait "$BGP"; S1=$(date +%s)
OUT=$(cat "$TMP/int.out"); RC=0
expect "a refresh stopped as a process group -> stuck, interrupted" 0 "stuck refresh interrupted before it finished — re-run it"
holds "a process-group stop is prompt (well before the 60 s validation ends)" [ $((S1 - S0)) -lt 10 ]
holds "process-group stop: worktree back at the PR head" wt_at "$HEAD_OID"
else ok "setsid not installed - process-group stop fixture skipped"; fi

# --- interrupted as the base merge completes (its post-merge hook) -> undone ---
layout; advance_base b.txt new
cat > "$TMP/repo/.git/hooks/post-merge" <<'EOF'
#!/bin/sh
kill -TERM "$(cat "$MR_PIDFILE")"
EOF
chmod +x "$TMP/repo/.git/hooks/post-merge"
export MR_PIDFILE="$TMP/mr.pid"
(cd "$TMP/repo" && exec bash "$SCRIPT" refresh "$TMP/wt" 12 "$VC" >"$TMP/int.out" 2>/dev/null) & BGP=$!
echo "$BGP" > "$MR_PIDFILE"; wait "$BGP"
OUT=$(cat "$TMP/int.out"); RC=0
expect "interrupted during the base merge -> stuck, interrupted" 0 "stuck refresh interrupted before it finished — re-run it"
holds "interrupted after the merge commit (merged flag not yet set): worktree back at the PR head, clean" eval 'wt_at "$HEAD_OID" && wt_clean'
rm -f "$TMP/repo/.git/hooks/post-merge"
run refresh "$TMP/wt" 12 "$VC"
NEW=$(git -C "$TMP/wt" rev-parse HEAD)
expect "the re-run after an interrupted merge recovers -> refreshed" 0 "refreshed $NEW"

# --- a failure after a fast-forward -> back where it was, so the retry says refreshed ---
layout; push_head; W0=$(git -C "$TMP/wt" rev-parse HEAD); vc preflight 1 "validation: preflight failed (exit 1): t"
run refresh "$TMP/wt" 12 "$VC"
expect "fast-forwarded, then preflight fails -> stuck" 0 "stuck preflight validation failed (exit 1)"
holds "failure after a fast-forward: the worktree is back where this pass found it" wt_at "$W0"
rm -f "$VC_STUB/preflight.rc" "$VC_STUB/preflight.out"
run refresh "$TMP/wt" 12 "$VC"
expect "the retry still reports the pushed head as refreshed" 0 "refreshed $HEAD_OID"

# --- validation commits in the worktree -> never pushed ---
layout; advance_base b.txt new; T0=$(origin_tip)
echo 'git commit -q --allow-empty -m sneaky' > "$VC_STUB/full.cmd"
run refresh "$TMP/wt" 12 "$VC"
expect "validation moves HEAD off the base merge -> stuck, nothing pushed" 0 "stuck validation moved HEAD off the validated head — a human must reconcile"
holds "moved HEAD: origin unchanged, worktree back at the PR head" eval '[ "$(origin_tip)" = "$T0" ] && wt_at "$HEAD_OID"'
layout; echo 'git commit -q --allow-empty -m sneaky' > "$VC_STUB/full.cmd"
run refresh "$TMP/wt" 12 "$VC"
expect "validation commits with no base advance -> stuck, never unchanged" 0 "stuck validation moved HEAD off the validated head — a human must reconcile"
holds "moved HEAD (no merge): worktree back at the PR head" wt_at "$HEAD_OID"
rm -f "$VC_STUB/full.cmd"
run refresh "$TMP/wt" 12 "$VC"
expect "the re-run after a moved HEAD recovers -> unchanged" 0 "unchanged $HEAD_OID"

# --- no merge-base with the base branch ---
layout
git -C "$TMP/other" checkout -q --orphan unrelated && git -C "$TMP/other" commit -q --allow-empty -m unrelated \
  && git -C "$TMP/other" push -q origin unrelated
stub head "$BR $HEAD_OID unrelated"
run refresh "$TMP/wt" 12 "$VC"
expect "unrelated base history -> stuck, no merge-base" 0 "stuck no merge-base with origin/unrelated"

# --- the contract probe fails -> stuck before the head sync ---
layout; push_head; W0=$(git -C "$TMP/wt" rev-parse HEAD); vc check 2 "validation: cannot resolve the base branch: …"
run refresh "$TMP/wt" 12 "$VC"
expect "the contract probe cannot resolve the base -> stuck before the head sync" 0 "stuck cannot resolve the base branch (validation exit 2)"
holds "failed contract probe: the worktree has not moved" wt_at "$W0"

# --- worktree-missing ---
layout
mkdir -p "$TMP/repo/stale-dir"
run refresh "$TMP/repo/stale-dir" 12 "$VC"
expect "row 37: a leftover plain directory inside another checkout -> worktree-missing" 0 \
  "worktree-missing $TMP/repo/stale-dir no longer exists or is not a git checkout"
run refresh "$TMP/nowhere" 12 "$VC"
expect "row 37: recorded worktree gone -> worktree-missing" 0 "worktree-missing $TMP/nowhere no longer exists or is not a git checkout"
git -C "$TMP/wt" checkout -q -b someone-else
run refresh "$TMP/wt" 12 "$VC"
expect "row 37: the worktree is another checkout -> worktree-missing" 0 \
  "worktree-missing $TMP/wt is not this PR's checkout (on someone-else, the PR head is $BR)"

# --- the validation script's exit statuses ---
USTUCK="stuck validation script unavailable or miscalled — a human must fix the install"
layout; vc changed 5 "validation: contract changed in this PR (…)"
run refresh "$TMP/wt" 12 "$VC"
expect "row 37: changed exit 5 -> stuck, contract changed after ready" 0 "stuck contract changed after ready — a human must review and merge"
holds "changed exit 5: nothing after it ran" [ "$(cat "$VC_STUB/log")" = "$(printf 'check main\nchanged main')" ]
layout; vc preflight 3 "validation: invalid contract (…)"
run refresh "$TMP/wt" 12 "$VC"; expect "row 37: exit 3 -> stuck, contract invalid" 0 "stuck validation contract invalid (exit 3)"
layout; vc preflight 4 "validation: preflight command not runnable (exit 127): ./x"
run refresh "$TMP/wt" 12 "$VC"; expect "row 37: exit 4 -> stuck, not runnable" 0 "stuck validation command not runnable (exit 4): preflight"
layout; vc changed 2 "validation: cannot resolve the base branch: …"
run refresh "$TMP/wt" 12 "$VC"; expect "row 37: exit 2 -> stuck, base unresolvable" 0 "stuck cannot resolve the base branch (validation exit 2)"
layout; vc preflight 7 "validation: validation-contract.sh not found"
run refresh "$TMP/wt" 12 "$VC"; expect "exit 7 -> stuck, install" 0 "$USTUCK"
layout; vc full 5 "odd"
run refresh "$TMP/wt" 12 "$VC"; expect "exit 5 outside changed -> stuck, install" 0 "$USTUCK"
layout
run refresh "$TMP/wt" 12 "vc/validation-contract.sh"; expect "a relative validation-script path -> stuck, install" 0 "$USTUCK"
run refresh "$TMP/wt" 12 "$TMP/vc/missing.sh"; expect "a missing validation script -> stuck, install" 0 "$USTUCK"
cp "$VC" "$TMP/wt/vc.sh"
run refresh "$TMP/wt" 12 "$TMP/wt/vc.sh"; expect "a validation script inside the worktree (PR-controlled) -> stuck" 0 "$USTUCK"
holds "a refused script never ran" [ ! -s "$VC_STUB/log" ]

# --- no contract: the fallback command ---
FB="validation: fallback (no contract at .issue-runner/validation on main)"
layout; vc preflight 0 "$FB"
run refresh "$TMP/wt" 12 "$VC"; expect "no contract seen only at preflight, no --fallback-cmd -> stuck" 0 "stuck no validation contract and no --fallback-cmd given"
layout; push_head; vc check 0 "$FB"; vc preflight 0 "$FB"; W0=$(git -C "$TMP/wt" rev-parse HEAD)
run refresh "$TMP/wt" 12 "$VC"; expect "row 37: no contract, no --fallback-cmd -> stuck before the head sync" 0 "stuck no validation contract and no --fallback-cmd given"
holds "no contract: the worktree has not moved" wt_at "$W0"
run refresh "$TMP/wt" 12 "$VC" --fallback-cmd "true"
expect "row 37: the --fallback-cmd retry still reports a pushed head as refreshed" 0 "refreshed $HEAD_OID"
layout; vc preflight 0 "$FB"
run refresh "$TMP/wt" 12 "$VC" --fallback-cmd "test -f g.txt"
expect "row 37: no contract, the project's tests pass -> unchanged" 0 "unchanged $HEAD_OID"
holds "fallback: changed still ran; full did not" [ "$(cat "$VC_STUB/log")" = "$(printf 'changed main\npreflight main')" ]
layout; advance_base b.txt new; vc preflight 0 "$FB"
run refresh "$TMP/wt" 12 "$VC" --fallback-cmd "exit 3"
expect "no contract, the project's tests fail -> stuck" 0 "stuck fallback tests failed (exit 3)"
holds "fallback failure after a base merge: merge dropped" wt_at "$HEAD_OID"

# --- the real validation-contract.sh, contract on origin/main ---
layout
mkdir -p "$TMP/other/.issue-runner"
git -C "$TMP/other" checkout -q main
printf 'preflight: test -f g.txt\n' > "$TMP/other/.issue-runner/validation"
git -C "$TMP/other" add .issue-runner && git -C "$TMP/other" commit -q -m contract && git -C "$TMP/other" push -q origin main
run refresh "$TMP/wt" 12 "$REAL_VC"
NEW=$(git -C "$TMP/wt" rev-parse HEAD)
expect "real script: contract lands on the base -> merged in, preflight passes, refreshed" 0 "refreshed $NEW"
mkdir -p "$TMP/wt/.issue-runner"; printf 'preflight: true\n' > "$TMP/wt/.issue-runner/validation"
git -C "$TMP/wt" add .issue-runner && git -C "$TMP/wt" commit -q -m "edit the contract" && git -C "$TMP/wt" push -q origin "$BR"
stub head "$BR $(git -C "$TMP/wt" rev-parse HEAD) main"
run refresh "$TMP/wt" 12 "$REAL_VC"
expect "real script: the PR edits the contract -> stuck, changed after ready" 0 "stuck contract changed after ready — a human must review and merge"
layout
git -C "$TMP/other" checkout -q main
mkdir -p "$TMP/other/.issue-runner"
printf 'preflight: echo "validation: fallback (spoof)"\nfull: false\n' > "$TMP/other/.issue-runner/validation"
git -C "$TMP/other" add .issue-runner && git -C "$TMP/other" commit -q -m spoof && git -C "$TMP/other" push -q origin main
run refresh "$TMP/wt" 12 "$REAL_VC"
expect "real script: a command printing the fallback line never reads as no contract; full still runs" 0 "stuck full validation failed (exit 1)"
holds "spoofed fallback: merge dropped" wt_at "$HEAD_OID"

layout; run refresh "$TMP/wt" 12 "$VC" --fallback-cmd ""
expect "an empty --fallback-cmd -> exit 2, never an empty test run" 2 ""

# --- stuck: a base merge that fails without conflicts ---
layout; advance_base b.txt new; git -C "$TMP/wt" config user.useConfigOnly true
OUT=$(cd "$TMP/repo" && env -u GIT_AUTHOR_NAME -u GIT_AUTHOR_EMAIL -u GIT_COMMITTER_NAME -u GIT_COMMITTER_EMAIL \
  EMAIL= bash "$SCRIPT" refresh "$TMP/wt" 12 "$VC" 2>"$TMP/stderr"); RC=$?
case $OUT in
  "stuck base merge did not start: "*) [ "$RC" = 0 ] && ok "a base merge that cannot start -> stuck, base merge did not start" ;;
  *) err "a base merge that cannot start printed: $OUT (exit $RC)" ;;
esac
# shellcheck disable=SC2016 # evaluated by holds, on purpose
holds "merge that did not start: worktree clean at the PR head" eval 'wt_at "$HEAD_OID" && wt_clean'

# ================================ checks =========================================
stub_reset; stub checks-1 "0"
run checks 12; expect "row 37: checks green -> pass" 0 pass
stub_reset; stub checks-1 "$(printf '1\nno checks reported on the '\''feat/issue-7-slug'\'' branch')"
run checks 12; expect "row 37: no checks reported -> none, one query" 0 none
holds "none without --refreshed: no poll" [ "$(cat "$GH_STUB/checks-count")" = 1 ]
stub_reset; stub checks-1 "$(printf '1\nX build fail')"
run checks 12; expect "row 37: red checks -> fail" 0 fail
stub_reset; stub checks-1 "$(printf '8\n* build pending')"
run checks 12; expect "row 37: pending checks -> fail (never merged)" 0 fail
stub_reset
run checks 12; expect "gh pr checks cannot run -> fail" 0 fail
stub_reset; stub checks-1 "$(printf '1\nno checks reported')"; stub checks-3 "0"
run checks 12 --refreshed; expect "row 37: refreshed head, CI registers on the 3rd read -> pass" 0 pass
stub_reset; stub checks-1 "$(printf '1\nno checks reported')"
run checks 12 --refreshed; expect "row 37: refreshed head, still none after the bound -> none-after-refresh" 0 none-after-refresh
holds "the registration poll is bounded (1 + 6 reads)" [ "$(cat "$GH_STUB/checks-count")" = 7 ]

# ================================ merge ==========================================
OID=0123456789abcdef0123456789abcdef01234567
stub_reset; stub state OPEN; stub title "Add the thing"; stub merge-sha fedcba9876543210fedcba9876543210fedcba98; : > "$GH_STUB/merge-lands"
stub body "$(printf '## Summary\n\nDoes it.\n\n## Review notes\n\niteration chatter')"
run merge 12 "$OID"
expect "row 37: pass/none -> head-pinned squash merge, verified merged" 0 "merged fedcba9876543210fedcba9876543210fedcba98"
holds "merge: pinned to the validated oid, squash, branch deleted" \
  grep -qF "[pr][merge][--squash][--delete-branch][--match-head-commit][$OID][12][--subject][Add the thing]" "$GH_STUB/log"
holds "merge: the body stops above ## Review notes" \
  grep -qF "[--body][## Summary"$'\n\n'"Does it."$'\n'"]" "$GH_STUB/log"

stub_reset; stub state MERGED; stub title t; stub body b; stub merge-rc 1; stub merge-sha abc
run merge 12 "$OID"
expect "gh pr merge exits non-zero after the server-side merge -> still merged" 0 "merged abc"

stub_reset; stub state OPEN; stub title t; stub body b; stub merge-rc 1; stub head-oid 1111111111111111111111111111111111111111
run merge 12 "$OID"
expect "row 37: a head pushed after the refresh -> skipped, head moved" 0 "skipped head moved after validation"

stub_reset; stub state OPEN; stub title t; stub body b; stub merge-rc 1; stub head-oid "$OID"
run merge 12 "$OID"
expect "row 37: merge fails on the validated head -> skipped, never retried" 0 \
  "skipped merge did not land (state OPEN): merge refused by the stub"
holds "a failed merge is never retried" [ "$(grep -c '^\[pr\]\[merge\]' "$GH_STUB/log")" = 1 ]

stub_reset; stub state OPEN; stub title t
run merge 12 "$OID"
expect "the body cannot be read -> skipped, no merge attempted" 0 "skipped merge did not land (state unknown): cannot read the PR body"

stub_reset; stub state OPEN; stub body b
run merge 12 "$OID"
expect "the title cannot be read -> skipped, no merge attempted" 0 "skipped merge did not land (state unknown): cannot read the PR title"
# shellcheck disable=SC2016 # evaluated by holds, on purpose
holds "no merge call without a title" eval '! grep -q "^\[pr\]\[merge\]" "$GH_STUB/log"'

# ================================ usage ==========================================
run bogus; expect "unknown mode -> exit 2" 2 ""
run state; expect "state without P -> exit 2" 2 ""
run state 0; expect "PR 0 -> exit 2" 2 ""
run refresh "$TMP/wt" 12; expect "refresh without the script -> exit 2" 2 ""
run refresh "$TMP/wt" 12 "$VC" --fallback; expect "refresh with a stray flag -> exit 2" 2 ""
run checks 12 --watch; expect "checks with an unknown flag -> exit 2" 2 ""
run merge 12; expect "merge without an oid -> exit 2" 2 ""
run merge 12 'HEAD; rm -rf /'; expect "merge with a non-hex oid -> exit 2" 2 ""
run merge 12 0123abc; expect "merge with a truncated oid -> exit 2" 2 ""
stub_reset; stub state OPEN; stub title t; stub body b; : > "$GH_STUB/merge-lands"; : > "$GH_STUB/fail-view-mergeCommit"
run merge 12 0123456789abcdef0123456789abcdef01234567
expect "merged, but the merge commit oid unreadable -> merged unknown" 0 "merged unknown"

# --- Accounting against docs/scenarios.md ----------------------------------------------
# Row 37's mechanics: the PR state, every refresh outcome, the checks re-check
# and the head-pinned merge. The dependency precondition, the status writes
# and the Step 5 summary lines are the prose's.
IN_SCOPE_ROWS="37"
EXPECTED_ROW_COUNT=62
if [ -f "$SCENARIOS" ]; then
  actual_rows="$(grep -cE '^\| [0-9]+ \|' "$SCENARIOS")"
  if [ "$actual_rows" -eq "$EXPECTED_ROW_COUNT" ]; then
    ok "docs/scenarios.md row count unchanged ($actual_rows) — in scope here: $IN_SCOPE_ROWS"
  else
    err "docs/scenarios.md now has $actual_rows rows (expected $EXPECTED_ROW_COUNT) — re-check whether any new row belongs in IN_SCOPE_ROWS above and add its fixture"
  fi
else
  err "docs/scenarios.md not found at $SCENARIOS"
fi

if [ "$fail" -ne 0 ]; then
  printf '\ntest-merge-ready: FAILED\n' >&2
  exit 1
fi
printf '\ntest-merge-ready: OK\n'
