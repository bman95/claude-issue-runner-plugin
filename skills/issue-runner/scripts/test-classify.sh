#!/usr/bin/env bash
#
# Golden fixtures for scripts/classify.sh: issue-runner Step 3 item 5's merge
# proof (`result`) and Step 5's unfinished-PR shape (`pr-shape`).
# `docs/scenarios.md` is the human-readable contract; this script is its
# executable form for the rows listed in IN_SCOPE_ROWS at the bottom.
#
# `gh` is a stub on PATH that answers from per-fixture files and logs every
# call, so the empty-branch guard (`gh pr list --head ""` must never run) is
# asserted on the calls themselves. git is real: a bare origin, a clone the
# script runs in (the orchestrator's cwd), and worktrees on feature branches.
#
# Run directly, or from scripts/lint.sh (and so from CI). Dependency-free:
# bash + git + coreutils. Exits non-zero on the first-or-any failure.

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="$ROOT/skills/issue-runner/scripts/classify.sh"
SCENARIOS="$ROOT/docs/scenarios.md"

fail=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Hermetic git: no user/system config.
export HOME="$TMP" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
unset XDG_CONFIG_HOME

ok()  { printf 'ok:   %s\n' "$1"; }
err() { printf 'FAIL: %s\n' "$1" >&2; fail=1; }

if [ ! -f "$SCRIPT" ]; then err "classify.sh not found"; exit 1; fi

# --- Stub gh ------------------------------------------------------------------
# Answers from files in $GH_STUB (branch names have `/` replaced by `_`):
#   issue-state          `gh issue view N`            (absent → the call fails)
#   merged-<branch>      `gh pr list --head B --state merged`  "number oid" lines
#   open-<branch>        `gh pr list --head B --state open`    "number isDraft" lines
#   open-all             `gh pr list --state open`             "number branch isDraft" lines
#   all-<branch>         `gh pr list --head B --state all`     "number" lines (absent = no PR)
#   view-<P>             `gh pr view P`                        isDraft line, then the body
#   fail-prlist          any `gh pr list` fails
#   fail-prlist-<state>  `gh pr list --state <state>` fails
# Every call is appended to $GH_STUB/log as `[arg][arg]…`.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
d=$GH_STUB
{ for a in "$@"; do printf '[%s]' "$a"; done; printf '\n'; } >> "$d/log"
case "$1 $2" in
  "issue view") [ -f "$d/issue-state" ] || exit 1; cat "$d/issue-state"; exit 0 ;;
  "pr view")    [ -f "$d/view-$3" ] || exit 1; cat "$d/view-$3"; exit 0 ;;
  "pr list")
    [ -f "$d/fail-prlist" ] && exit 1
    head="" state=""; shift 2
    while [ $# -gt 0 ]; do
      case $1 in --head) head=$2; shift ;; --state) state=$2; shift ;; esac; shift
    done
    [ -f "$d/fail-prlist-$state" ] && exit 1
    if [ -z "$head" ]; then f="$d/open-all"; else f="$d/$state-$(printf '%s' "$head" | tr / _)"; fi
    [ -f "$f" ] && cat "$f"; exit 0 ;;
esac
exit 1
EOF
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"

# --- Repositories -------------------------------------------------------------
# One origin for the result fixtures: `main`, plus worktrees on branches.
ORIGIN="$TMP/origin.git"
REPO="$TMP/repo"
git init -q --bare "$ORIGIN"
git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
git init -q "$REPO"
git -C "$REPO" symbolic-ref HEAD refs/heads/main
git -C "$REPO" commit -q --allow-empty -m base
git -C "$REPO" remote add origin "$ORIGIN"
git -C "$REPO" push -q origin main

# wt NAME BRANCH -> a worktree of $REPO on a new BRANCH with one commit; prints its path
wt() {
  local p="$TMP/wt-$1"
  git -C "$REPO" worktree add -q -b "$2" "$p" main >/dev/null 2>&1 \
    && git -C "$p" commit -q --allow-empty -m "work on $2" && printf '%s\n' "$p"
}
head_of() { git -C "$1" rev-parse HEAD; }

W_CONTRACT=$(wt contract feat/issue-7-slug)
W_SCRATCH=$(wt scratch worktree-agent-abc123)
W_OTHER=$(wt other someone/unrelated-name)
W_SEVENTY=$(wt seventy feat/issue-70-slug)
H_CONTRACT=$(head_of "$W_CONTRACT")
H_OTHER=$(head_of "$W_OTHER")
H_SEVENTY=$(head_of "$W_SEVENTY")
OLD_OID=0123456789abcdef0123456789abcdef01234567

# stub_reset: a fresh stub directory
stub_reset() { rm -rf "$TMP/stub"; mkdir -p "$TMP/stub"; export GH_STUB="$TMP/stub"; : > "$GH_STUB/log"; }
stub() { printf '%s\n' "$2" > "$GH_STUB/$1"; }

# check NAME EXPECTED_EXIT EXPECTED_STDOUT -- ARGS…   (run from $CWD, default $REPO)
check() {
  local name="$1" want_rc="$2" want_out="$3"; shift 4
  local out rc
  out=$(cd "${CWD:-$REPO}" && bash "$SCRIPT" "$@" 2>"$TMP/stderr"); rc=$?
  if [ "$rc" = "$want_rc" ] && [ "$out" = "$want_out" ]; then
    ok "$name"
  else
    err "$name (exit $rc, want $want_rc)"
    printf '%s\n' "$want_out" | sed 's/^/  expected> /' >&2
    printf '%s\n' "$out" | sed 's/^/  actual  > /' >&2
    sed 's/^/  stderr  > /' "$TMP/stderr" >&2
  fi
}

# rcheck NAME EXPECTED_EXIT "STATUS PR" EXPECTED_ERROR WORKTREE RECORDED OUTCOME BLOCKER
#   Lays out $STATE_DIR/issue-7 the way the orchestrator does (worktree,
#   branch, outcome and blocker files; "" = no file — the blocker is always a
#   file, never an argument), runs `result 7 <dir>`, and checks the stdout line
#   and the `error` file left behind ("" = no file). On a non-zero exit `error`
#   must be exactly as it was (a pre-existing sentinel), and `blocker` is never
#   modified.
ID="$TMP/state/issue-7"
lay_out() {   # lay_out WORKTREE RECORDED OUTCOME BLOCKER
  rm -rf "$ID"; mkdir -p "$ID"
  [ -n "$1" ] && printf '%s\n' "$1" > "$ID/worktree"
  [ -n "$2" ] && printf '%s\n' "$2" > "$ID/branch"
  [ -n "$3" ] && printf '%s\n' "$3" > "$ID/outcome"
  [ -n "$4" ] && printf '%s\n' "$4" > "$ID/blocker"
  printf 'sentinel from an earlier step\n' > "$ID/error"
  return 0
}
rcheck() {
  local name="$1" want_rc="$2" want_out="$3" want_err="$4"
  local out rc got_err got_blk want_file
  lay_out "$5" "$6" "$7" "$8"
  out=$(cd "$REPO" && bash "$SCRIPT" result 7 "$ID" 2>"$TMP/stderr"); rc=$?
  if [ -e "$ID/error" ]; then got_err=$(cat "$ID/error"); else got_err="<no file>"; fi
  if [ -e "$ID/blocker" ]; then got_blk=$(cat "$ID/blocker"); else got_blk=""; fi
  want_file=$want_err; [ -n "$want_file" ] || want_file="<no file>"
  [ "$rc" = 0 ] || want_file="sentinel from an earlier step"
  if [ "$rc" = "$want_rc" ] && [ "$out" = "$want_out" ] && [ "$got_err" = "$want_file" ] && [ "$got_blk" = "$8" ]; then
    ok "$name"
  else
    err "$name (exit $rc, want $want_rc)"
    printf '%s | error: %s\n' "$want_out" "$want_file" | sed 's/^/  expected> /' >&2
    printf '%s | error: %s | blocker: %s\n' "$out" "$got_err" "$got_blk" | sed 's/^/  actual  > /' >&2
    sed 's/^/  stderr  > /' "$TMP/stderr" >&2
  fi
}
# no_head_query NAME: no `gh pr list --head` call was made at all
no_head_query() {
  if grep -qF '[--head]' "$GH_STUB/log"; then err "$1: a --head query ran:"; sed 's/^/  call> /' "$GH_STUB/log" >&2
  else ok "$1"; fi
}
# no_empty_head NAME: never `--head ""`
no_empty_head() {
  if grep -qF '[--head][]' "$GH_STUB/log"; then err "$1: gh pr list --head \"\" ran"
  else ok "$1"; fi
}

MERGED_OPEN="PR #11 merged but issue still open — confirm and close by hand"
HANG="implementer hung (no completion): progress unchanged for 47m (--hang-minutes 30)"
CLOSED_EXT="closed without a merged implementer PR"

# --- result: rows 5, 6 ----------------------------------------------------------
stub_reset; stub issue-state CLOSED; stub merged-feat_issue-7-slug "11 $H_CONTRACT"
rcheck "row 5: CLOSED + merged PR carrying the worktree's HEAD -> done" 0 "done 11" "" \
  "$W_CONTRACT" "" merged ""
rcheck "row 21: hung after the merge, issue CLOSED -> done, the hang string cleared" 0 "done 11" "" \
  "$W_CONTRACT" "" hung "$HANG"

stub_reset; stub issue-state CLOSED
rcheck "row 6: CLOSED + no merged PR -> closed-externally" 0 "closed-externally -" "$CLOSED_EXT" \
  "$W_CONTRACT" "" merged ""

# --- result: row 11, the empty-branch guard ---------------------------------------
stub_reset; stub issue-state CLOSED; stub merged- "99 $H_CONTRACT"   # what an unfiltered --head "" would match
rcheck "row 11: CLOSED + worktree gone -> closed-externally, never done" 0 "closed-externally -" "$CLOSED_EXT" \
  "$TMP/gone" "" merged ""
no_empty_head "row 11: worktree gone never runs gh pr list --head \"\""
no_head_query "row 11: worktree gone runs no --head query at all"

stub_reset; stub issue-state CLOSED; stub merged- "99 $H_CONTRACT"
rcheck "row 11: CLOSED + no worktree path at all -> closed-externally" 0 "closed-externally -" "$CLOSED_EXT" \
  "" "" none ""
no_empty_head "row 11: an empty worktree path never runs gh pr list --head \"\""

stub_reset; stub issue-state OPEN
rcheck "row 11: open + worktree gone, blocker -> failed" 0 "failed -" "Codex gate cap-stop" \
  "$TMP/gone" "" blocker "Codex gate cap-stop"
rcheck "row 15: open + no worktree, agent crashed -> failed" 0 "failed -" "agent crashed" \
  "" "" none "agent crashed"

# --- result: row 14, an unproven merged claim --------------------------------------
stub_reset; stub issue-state OPEN
rcheck "row 14: open + outcome merged + no merged PR -> failed" 0 "failed -" \
  "result.json claims merged but no merged PR on feat/issue-7-slug" "$W_CONTRACT" "" merged ""
rcheck "row 14: worktree gone names the branch (none)" 0 "failed -" \
  "result.json claims merged but no merged PR on (none)" "$TMP/gone" "" merged ""
stub_reset; stub issue-state CLOSED
rcheck "row 14: CLOSED + outcome merged + no merged PR -> closed-externally" 0 "closed-externally -" "$CLOSED_EXT" \
  "$W_CONTRACT" "" merged ""

# --- result: row 16, merged but still open (and its suffixes) ----------------------
stub_reset; stub issue-state OPEN; stub merged-feat_issue-7-slug "11 $H_CONTRACT"
rcheck "row 16: open + merged PR, outcome merged -> blocked, no suffix" 0 "blocked 11" "$MERGED_OPEN" \
  "$W_CONTRACT" "" merged "a merged claim's message is no suffix"
rcheck "row 16: open + merged PR, outcome blocker -> blocked with the blocker suffix" 0 "blocked 11" \
  "$MERGED_OPEN: base freshness conflict" "$W_CONTRACT" "" blocker "base freshness conflict"
rcheck "row 21: hung after merge, issue still open -> blocked with the hang suffix" 0 "blocked 11" \
  "$MERGED_OPEN: $HANG" "$W_CONTRACT" "" hung "$HANG"
rcheck "row 16: open + merged PR, no error at all -> blocked, no suffix" 0 "blocked 11" "$MERGED_OPEN" \
  "$W_CONTRACT" "" none ""

# --- result: the merge-oid record (integration RFC §8.1) ---------------------------
# mcheck NAME WANT: after the last rcheck, issue-7/merge-oid holds WANT ("" = no file).
mcheck() {
  local got="<no file>"
  [ -e "$ID/merge-oid" ] && got=$(cat "$ID/merge-oid")
  [ "$got" = "${2:-<no file>}" ] && ok "$1" || err "$1: merge-oid is '$got', want '${2:-<no file>}'"
}
MC=cccccccccccccccccccccccccccccccccccccccc
stub_reset; stub issue-state CLOSED; stub merged-feat_issue-7-slug "11 $H_CONTRACT $MC main"
rcheck "merge proof with its merge commit -> done" 0 "done 11" "" "$W_CONTRACT" "" merged ""
mcheck "done records merge-oid: the merge commit, the base branch and the PR" "$MC main 11"
grep -qF 'mergeCommit,baseRefName' "$GH_STUB/log" && ok "the merged-PR query asks for mergeCommit and baseRefName" \
  || err "the merged-PR query lacks mergeCommit/baseRefName"
stub_reset; stub issue-state OPEN; stub merged-feat_issue-7-slug "11 $H_CONTRACT $MC release"
rcheck "row 16 with its merge commit -> blocked" 0 "blocked 11" "$MERGED_OPEN" "$W_CONTRACT" "" merged ""
mcheck "row 16 records merge-oid on the proof, before Step 4's answer" "$MC release 11"
stub_reset; stub issue-state CLOSED; stub merged-feat_issue-7-slug "11 $H_CONTRACT abc123 main"
rcheck "an abbreviated merge commit still classifies done" 0 "done 11" "" "$W_CONTRACT" "" merged ""
mcheck "an abbreviated merge commit records no merge-oid" ""
stub_reset; stub issue-state CLOSED
rcheck "no merge proof -> closed-externally" 0 "closed-externally -" "$CLOSED_EXT" "$W_CONTRACT" "" merged ""
mcheck "no merge proof records no merge-oid" ""

# --- result: row 17, a branch outside the contract ---------------------------------
stub_reset; stub issue-state CLOSED
rcheck "row 17: scratch branch, CLOSED -> closed-externally" 0 "closed-externally -" "$CLOSED_EXT" \
  "$W_SCRATCH" "" merged ""
no_head_query "row 17: scratch branch runs no --head query"
stub_reset; stub issue-state OPEN
rcheck "row 17: scratch branch, open, blocker -> blocked" 0 "blocked -" "Agent tool unavailable" \
  "$W_SCRATCH" "" blocker "Agent tool unavailable"
no_head_query "row 17: scratch branch (open) runs no --head query"
stub_reset; stub issue-state CLOSED; stub merged-feat_issue-70-slug "70 $H_SEVENTY"
rcheck "row 17: #70's worktree never proves #7 (trailing dash)" 0 "closed-externally -" "$CLOSED_EXT" \
  "$W_SEVENTY" "" merged ""
no_head_query "row 17: #70's branch runs no --head query for #7"
stub_reset; stub issue-state CLOSED; stub merged-someone_unrelated-name "31 $H_OTHER"
rcheck "row 17: the branch Step 3a recorded is accepted as proof branch" 0 "done 31" "" \
  "$W_OTHER" "someone/unrelated-name" merged ""

# --- result: row 18, a previous run's merged PR on the same name --------------------
stub_reset; stub issue-state OPEN; stub merged-feat_issue-7-slug "9 $OLD_OID"
rcheck "row 18: merged PR with another headRefOid, open, blocker -> blocked" 0 "blocked -" "checks failed" \
  "$W_CONTRACT" "" blocker "checks failed"
stub_reset; stub issue-state CLOSED; stub merged-feat_issue-7-slug "9 $OLD_OID"
rcheck "row 18: merged PR with another headRefOid, CLOSED -> closed-externally" 0 "closed-externally -" "$CLOSED_EXT" \
  "$W_CONTRACT" "" merged ""
stub_reset; stub issue-state CLOSED; stub merged-feat_issue-7-slug "$(printf '9 %s\n12 %s' "$OLD_OID" "$H_CONTRACT")"
rcheck "row 18: the PR carrying this HEAD wins among several" 0 "done 12" "" \
  "$W_CONTRACT" "" merged ""

# --- result: rows 21, 15 — the other open outcomes ---------------------------------
stub_reset; stub issue-state OPEN
rcheck "row 21: hung, open, no merged PR -> failed with the hang string" 0 "failed -" "$HANG" \
  "$W_CONTRACT" "" hung "$HANG"
rcheck "open + outcome failed -> failed" 0 "failed -" "validation: cannot resolve the base branch" \
  "$W_CONTRACT" "" failed "validation: cannot resolve the base branch"
rcheck "a multi-line error is kept verbatim" 0 "failed -" $'line one\nline two' \
  "$W_CONTRACT" "" failed $'line one\nline two'
# Untrusted text: it reaches the script as a file, so nothing in it ever runs.
# shellcheck disable=SC2016 # literal on purpose: the text must never expand
INJECT='revert to draft failed: `touch '"$TMP"'/pwned` $(touch '"$TMP"'/pwned2) "quoted" \ back'
rcheck "shell metacharacters in the error are data, kept verbatim" 0 "blocked -" "$INJECT" \
  "$W_CONTRACT" "" blocker "$INJECT"
if [ -e "$TMP/pwned" ] || [ -e "$TMP/pwned2" ]; then err "an error string executed a command"
else ok "no command in the error string ran"; fi

# --- result: row 35, the ready claim ------------------------------------------------
stub_reset; stub issue-state OPEN; stub open-feat_issue-7-slug "12 false"
rcheck "row 35: open, non-draft PR on the branch -> ready" 0 "ready 12" "" "$W_CONTRACT" "" ready ""
stub_reset; stub issue-state OPEN; stub open-feat_issue-7-slug "12 true"
rcheck "row 35: the PR is a draft -> failed" 0 "failed -" \
  "result.json claims ready but no open, non-draft PR on feat/issue-7-slug" "$W_CONTRACT" "" ready ""
stub_reset; stub issue-state OPEN
rcheck "row 35: no open PR -> failed" 0 "failed -" \
  "result.json claims ready but no open, non-draft PR on feat/issue-7-slug" "$W_CONTRACT" "" ready ""
stub_reset; stub issue-state OPEN; stub open-worktree-agent-abc123 "12 false"
rcheck "row 35: scratch branch is no proof branch -> failed" 0 "failed -" \
  "result.json claims ready but no open, non-draft PR on worktree-agent-abc123" "$W_SCRATCH" "" ready ""
no_head_query "row 35: scratch branch runs no --head query"

# --- result: re-runs, detached HEAD, several open PRs ------------------------------
stub_reset; stub issue-state OPEN; stub merged-feat_issue-7-slug "11 $H_CONTRACT"
lay_out "$W_CONTRACT" "" blocker "base freshness conflict"
first=$(cd "$REPO" && bash "$SCRIPT" result 7 "$ID" 2>/dev/null; cat "$ID/error")
second=$(cd "$REPO" && bash "$SCRIPT" result 7 "$ID" 2>/dev/null; cat "$ID/error")
if [ "$first" = "$second" ] && [ "$(cat "$ID/blocker")" = "base freshness conflict" ]; then
  ok "re-running result classifies the same inputs again (no double suffix)"
else
  err "re-running result is not idempotent:"; printf '%s\n---\n%s\n' "$first" "$second" | sed 's/^/  > /' >&2
fi

DETACHED="$TMP/wt-detached"
git -C "$REPO" worktree add -q --detach "$DETACHED" main >/dev/null 2>&1
stub_reset; stub issue-state OPEN
rcheck "detached HEAD is a real worktree without a proof branch: blocker -> blocked" 0 "blocked -" "checks failed" \
  "$DETACHED" "" blocker "checks failed"
no_head_query "detached HEAD runs no --head query"

stub_reset; stub issue-state OPEN; stub open-feat_issue-7-slug "$(printf '12 true\n13 false')"
rcheck "row 35: the first open PR is a draft -> failed" 0 "failed -" \
  "result.json claims ready but no open, non-draft PR on feat/issue-7-slug" "$W_CONTRACT" "" ready ""
stub_reset; stub issue-state OPEN
rcheck "row 35: ready with the worktree gone names the branch (none)" 0 "failed -" \
  "result.json claims ready but no open, non-draft PR on (none)" "$TMP/gone" "" ready ""
no_head_query "row 35: ready with the worktree gone runs no --head query"

stub_reset; stub issue-state OPEN; stub open-someone_unrelated-name "31 false"
rcheck "row 35: ready on the branch Step 3a recorded -> ready" 0 "ready 31" "" \
  "$W_OTHER" "someone/unrelated-name" ready ""
stub_reset; stub issue-state OPEN; stub merged-feat_issue-7-slug "11 $H_CONTRACT"
rcheck "outcome ready, but a merged PR and the issue still open -> blocked, no suffix" 0 "blocked 11" "$MERGED_OPEN" \
  "$W_CONTRACT" "" ready ""

# --- result: same-named PRs on other heads (a fork's, an older run's) ----------------
stub_reset; stub issue-state CLOSED; stub merged-feat_issue-7-slug "40 $OLD_OID"
rcheck "a same-named merged PR on another head is no proof" 0 "closed-externally -" "$CLOSED_EXT" \
  "$W_CONTRACT" "" merged ""
# `ready` keeps the spec's check: the first open PR on the proof branch, not
# anchored on HEAD (a pushed-to PR stays ready; a fork's same-named PR is a follow-up).
stub_reset; stub issue-state OPEN; stub open-feat_issue-7-slug "$(printf '40 false\n12 false')"
rcheck "ready reads the first open PR on the branch, as the spec's .[0] does" 0 "ready 40" "" "$W_CONTRACT" "" ready ""
# --- result: failures and usage ------------------------------------------------------
stub_reset
rcheck "issue state query fails -> exit 1, no classification, error file untouched" 1 "" "" \
  "$W_CONTRACT" "" blocker "kept as it was"
stub_reset; stub issue-state CLOSED; : > "$GH_STUB/fail-prlist"
rcheck "merged-PR query fails -> exit 1, never read as no proof" 1 "" "" "$W_CONTRACT" "" merged ""
stub_reset; stub issue-state OPEN; : > "$GH_STUB/fail-prlist-open"
rcheck "ready's open-PR query fails -> exit 1" 1 "" "" "$W_CONTRACT" "" ready ""
stub_reset; stub issue-state MERGED
rcheck "unexpected issue state -> exit 1" 1 "" "" "$W_CONTRACT" "" merged ""
stub_reset; stub issue-state OPEN
rcheck "unknown outcome -> exit 2" 2 "" "" "$W_CONTRACT" "" success ""
rcheck "missing outcome file -> exit 2" 2 "" "" "$W_CONTRACT" "" "" ""
if [ "$(id -u)" = 0 ]; then
  ok "error file cannot be written: skipped as root (permissions do not bind root)"
else
  lay_out "$W_CONTRACT" "" failed "x"; chmod 0555 "$ID"
  rcheck_ro=$(cd "$REPO" && bash "$SCRIPT" result 7 "$ID" 2>/dev/null); rc=$?
  chmod 0755 "$ID"
  if [ "$rc" = 1 ] && [ -z "$rcheck_ro" ] && [ "$(cat "$ID/error")" = "sentinel from an earlier step" ]; then
    ok "error file cannot be written -> exit 1, nothing printed, error untouched"
  else
    err "unwritable issue dir: exit $rc, stdout '$rcheck_ro'"
  fi
fi
check "non-numeric issue -> exit 2" 2 "" -- result 7x "$ID"
check "issue 0 -> exit 2" 2 "" -- result 0 "$ID"
check "missing issue-dir argument -> exit 2" 2 "" -- result 7
check "issue dir that does not exist -> exit 2" 2 "" -- result 7 "$TMP/no-such-dir"
check "unknown mode -> exit 2" 2 "" -- classify 7
check "unknown mode is reported before the issue number" 2 "" -- classify

# --- hang: Step 3 item 4's threshold rule (row 21) --------------------------------------
HD="$TMP/state/issue-8"; rm -rf "$HD"; mkdir -p "$HD"
check "row 21: no progress file -> nothing (the relative-silence rule is the orchestrator's)" 0 "" -- hang 8 "$HD" 30
printf 'step=8.1 iter=2 pr=#12\n' > "$HD/progress"
check "a fresh progress file -> not hung" 0 "" -- hang 8 "$HD" 30
touch -t "$(date -d '-3 hours' +%Y%m%d%H%M 2>/dev/null || date -v-3H +%Y%m%d%H%M)" "$HD/progress"
out=$(cd "$REPO" && bash "$SCRIPT" hang 8 "$HD" 30 2>&1)
case $out in "implementer hung (no completion): progress unchanged for 18"[0-9]"m (--hang-minutes 30)") ok "row 21: progress older than the threshold -> the hung line, age rounded up" ;;
  *) err "row 21: hung line: '$out'" ;; esac
: > "$HD/progress"; touch -t "$(date -d '-3 hours' +%Y%m%d%H%M 2>/dev/null || date -v-3H +%Y%m%d%H%M)" "$HD/progress"
check "an empty progress file is no progress file -> nothing" 0 "" -- hang 8 "$HD" 30
check "hang minutes must be a positive integer -> exit 2" 2 "" -- hang 8 "$HD" 0

# --- notification: Step 3 item 5's final-or-interim question (row 76) --------------------
# An interim "Agent finished" (the implementer stopped with a gate pass of its own
# running in the background) with no result.json and a fresh progress marker must
# change nothing: no status, no outcome, no blocker, no error, no progress write.
# Every case below writes its own notification text and result.json state.
ND="$TMP/state/issue-9"; rm -rf "$ND"; mkdir -p "$ND"
printf 'implementing\n' > "$ND/status"
printf 'step=8.2 pass=1 pr=#12\n' > "$ND/progress"
touch -t "$(date -d '-2 minutes' +%Y%m%d%H%M 2>/dev/null || date -v-2M +%Y%m%d%H%M)" "$ND/progress"
nd_snapshot() { ( cd "$ND" && for f in *; do printf '%s %s %s\n' "$f" "$(cat "$f")" "$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f")"; done ); }
HOST_NOTE='This agent stopped with background work of its own still running. It may resume on its own when that work completes.'
# ncase NAME WANT NOTIFICATION RESULT_JSON ("" = no file / no notification file)
ncase() {
  rm -f "$ND/notification" "$ND/result.json"
  [ -z "$3" ] || printf '%s\n' "$3" > "$ND/notification"
  [ -z "$4" ] || printf '%s\n' "$4" > "$ND/result.json"
  check "$1" 0 "$2" -- notification 9 "$ND"
}
GOOD_RESULT='{"outcome":"blocker","pr":12,"worktree":"/w","blocker":"x"}'
# Snapshot BEFORE the first call: the call itself must change nothing.
rm -f "$ND/notification" "$ND/result.json"
printf '%s\n' "$HOST_NOTE"$'\nGate pass 1 is running with gpt-6.1-sol; I will check the results when it finishes.' > "$ND/notification"
nd_before=$(nd_snapshot)
check "row 76: the host's note as the first line, no result.json -> interim" 0 "interim" -- notification 9 "$ND"
check "row 76: the same state leaves a fresh progress marker un-hung" 0 "" -- hang 9 "$ND" 30
check "row 76: ... and re-running the call is idempotent" 0 "interim" -- notification 9 "$ND"
[ "$(nd_snapshot)" = "$nd_before" ] && ok "row 76: an interim notification changes no state file (status stays implementing, progress mtime untouched)" \
  || err "row 76: the notification mode modified the issue directory"
ncase "row 76: the fixed form 'interim: waiting on <what>' as the only line -> interim" interim \
  "interim: waiting on codex gate pass 1" ""
ncase "the fixed form after other text, as the last non-blank line -> interim" interim \
  $'Pass 1 launched.\ninterim: waiting on codex gate pass 1\n\n' ""
ncase "the fixed form with CRLF line endings -> interim" interim \
  $'interim: waiting on codex gate pass 1\r' ""
ncase "the fixed form followed by host trailer lines (within the last 5) -> interim" interim \
  $'Pass 1 launched.\ninterim: waiting on codex gate pass 1\n\nagent_id: a1\n<usage>tokens: 5</usage>\n' ""
ncase "the fixed form buried under more than 4 trailer lines -> final (outside the window)" final \
  $'interim: waiting on x\na\nb\nc\nd\ne' ""
ncase "the host's note after a blank or wrapper-free leading blank line -> interim" interim \
  $'\n\n'"$HOST_NOTE" ""
ncase "the fixed form with nothing after it is not a marker -> final" final \
  "interim: waiting on " ""
ncase "the fixed form with only trailing spaces after it is not a marker -> final" final \
  "interim: waiting on   " ""
ncase "the fixed form quoted mid-message, not last -> final" final \
  $'interim: waiting on codex gate pass 1\nBlocker: spec ambiguity.\nworktree: /w' ""
ncase "the fixed form indented -> final" final \
  "  interim: waiting on x" ""
ncase "the host's phrase quoted on a later line of a final message -> final" final \
  $'Blocker: the agent stopped with background work of its own still running\nworktree: /w' ""
ncase "the host's phrase not at the start of the first line -> final" final \
  "Blocker: This agent stopped with background work of its own still running" ""
ncase "row 76: the host's note leading a final blocker message with a worktree: line -> final" final \
  "$HOST_NOTE"$'\nBlocker: spec ambiguity.\nworktree: /w' ""
ncase "a worktree: line beats the fixed form too -> final" final \
  $'Blocker: x\nworktree: /w\ninterim: waiting on y' ""
ncase "'worktree:' must start a line to count -> the host's note still wins" interim \
  "$HOST_NOTE"$'\nsee worktree: /w' ""
ncase "the host's note leading a crash message with no worktree: line stays interim (fail safe: hung.md's bound ends it)" interim \
  "$HOST_NOTE"$'\nError: connection reset' ""
ncase "row 76: a final message with no marker, no result.json -> final (prose classification)" final \
  $'Blocker: spec ambiguity.\nworktree: /w' ""
rm -f "$ND/notification" "$ND/result.json"
check "no notification file and no result.json is an error, never a verdict" 1 "" -- notification 9 "$ND"
: > "$ND/notification"
check "an empty notification file and no result.json is an error too" 1 "" -- notification 9 "$ND"
printf ' \n\n' > "$ND/notification"
check "a whitespace-only notification file and no result.json is an error too" 1 "" -- notification 9 "$ND"
printf '%s\n' "$GOOD_RESULT" > "$ND/result.json"
check "an empty notification file does not matter once result.json is readable -> final" 0 "final" -- notification 9 "$ND"
rm -f "$ND/result.json"
ncase "row 76: a readable result.json wins over the host's note -> final" final \
  "$HOST_NOTE" "$GOOD_RESULT"
ncase "row 76: a readable result.json wins over the fixed form -> final" final \
  "interim: waiting on codex gate pass 1" "$GOOD_RESULT"
ncase "row 76: result.json with an empty worktree is unreadable -> interim" interim \
  "interim: waiting on codex gate pass 1" '{"outcome":"blocker","pr":12,"worktree":"","blocker":"x"}'
ncase "result.json with an unknown outcome is unreadable -> interim" interim \
  "interim: waiting on codex gate pass 1" '{"outcome":"weird","pr":12,"worktree":"/w"}'
ncase "a truncated result.json is unreadable -> interim" interim \
  "interim: waiting on codex gate pass 1" '{"outcome":"blocker","pr":12,'
ncase "a valid result.json with a \\u-escaped outcome is readable -> final" final \
  "interim: waiting on codex gate pass 1" '{"outcome":"\u0072eady","pr":12,"worktree":"/w"}'
ncase "a valid result.json with escapes in the worktree string is readable -> final" final \
  "interim: waiting on codex gate pass 1" '{"outcome":"merged","pr":12,"worktree":"C:\\w\"x\/\n"}'
ncase "an escaped outcome that decodes to an unknown word is unreadable -> interim" interim \
  "interim: waiting on codex gate pass 1" '{"outcome":"m\u0065rged!","pr":12,"worktree":"/w"}'
ncase "an escaped worktree that decodes to nothing printable still counts as non-empty -> final" final \
  "interim: waiting on codex gate pass 1" '{"outcome":"failed","pr":12,"worktree":"\u00e9"}'
ncase "a duplicate top-level outcome with a non-string value is unreadable (last key wins) -> interim" interim \
  "interim: waiting on codex gate pass 1" '{"outcome":"merged","outcome":5,"worktree":"/w"}'
ncase "a duplicate top-level worktree with a non-string value is unreadable -> interim" interim \
  "interim: waiting on codex gate pass 1" '{"outcome":"merged","worktree":"/w","worktree":5}'
ncase "a raw DEL byte inside a string is legal JSON -> final" final \
  "interim: waiting on codex gate pass 1" "$(printf '{"outcome":"merged","pr":1,"worktree":"/w\177x"}')"
ncase "an invalid escape in a string is unreadable -> interim" interim \
  "interim: waiting on codex gate pass 1" '{"outcome":"ready","pr":12,"worktree":"\x"}'
ncase "a second object after the first is not one JSON object -> interim" interim \
  "interim: waiting on codex gate pass 1" '{"outcome":"blocker","worktree":"/w"}{}'
ncase "a second object on the next line is not one JSON object -> interim" interim \
  "interim: waiting on codex gate pass 1" $'{"outcome":"blocker","pr":12,"worktree":"/w"}\n{}'
ncase "trailing text after the object -> interim" interim \
  "interim: waiting on codex gate pass 1" '{"outcome":"blocker","worktree":"/w"} x'
ncase "a nested outcome and worktree are not top-level fields -> interim" interim \
  "interim: waiting on codex gate pass 1" '{"extra":{"outcome":"blocker","worktree":"/w"}}'
ncase "a top-level outcome but a nested worktree -> interim" interim \
  "interim: waiting on codex gate pass 1" '{"outcome":"blocker","extra":{"worktree":"/w"}}'
ncase "a missing comma between fields -> interim" interim \
  "interim: waiting on codex gate pass 1" '{"outcome":"blocker" "worktree":"/w"}'
ncase "not an object (an array) -> interim" interim \
  "interim: waiting on codex gate pass 1" '[{"outcome":"blocker","worktree":"/w"}]'
ncase "a trailing comma is invalid JSON -> interim" interim \
  "interim: waiting on codex gate pass 1" '{"outcome":"blocker","worktree":"/w",}'
ncase "mismatched delimiters are invalid JSON -> interim" interim \
  "interim: waiting on codex gate pass 1" '{"outcome":"blocker","worktree":"/w"]'
ncase "a missing value is invalid JSON -> interim" interim \
  "interim: waiting on codex gate pass 1" '{"outcome":"blocker","pr":,"worktree":"/w"}'
ncase "a missing colon is invalid JSON -> interim" interim \
  "interim: waiting on codex gate pass 1" '{"outcome":"blocker","pr" 12,"worktree":"/w"}'
ncase "an unterminated string is invalid JSON -> interim" interim \
  "interim: waiting on codex gate pass 1" '{"outcome":"blocker","worktree":"/w}'
ncase "an array with a trailing comma inside is invalid JSON -> interim" interim \
  "interim: waiting on codex gate pass 1" '{"outcome":"blocker","worktree":"/w","a":[1,2,]}'
ncase "a bad escape is invalid JSON -> interim" interim \
  "interim: waiting on codex gate pass 1" '{"outcome":"blocker","worktree":"/w\x","a":1}'
ncase "a leading-zero number is invalid JSON -> interim" interim \
  "interim: waiting on codex gate pass 1" '{"outcome":"blocker","worktree":"/w","pr":01}'
ncase "a truncated nested object is invalid JSON -> interim" interim \
  "interim: waiting on codex gate pass 1" '{"outcome":"blocker","worktree":"/w","a":{"b":1}'
ncase "an outcome that is not a string -> interim" interim \
  "interim: waiting on codex gate pass 1" '{"outcome":12,"worktree":"/w"}'
ncase "numbers, literals, unicode escapes and empty containers are valid -> final" final \
  "interim: waiting on codex gate pass 1" '{"outcome":"merged","worktree":"/wé","n":-1.5e+3,"t":true,"f":false,"z":null,"o":{},"a":[]}'
ncase "a readable result with a nested object and braces inside a string -> final" final \
  "interim: waiting on codex gate pass 1" '{"outcome":"merged","pr":12,"extra":{"a":[1,{"b":"}"}]},"worktree":"/w {x}","blocker":null}'
ncase "a pretty-printed single object is still one JSON object -> final" final \
  "interim: waiting on codex gate pass 1" $'{\n  "outcome": "failed",\n  "pr": null,\n  "worktree": "/w"\n}'
ncase "an escaped quote in a string does not end it -> final" final \
  "interim: waiting on codex gate pass 1" '{"blocker":"say \"hi\", {x}","outcome":"ready","worktree":"/w"}'
check "notification: missing issue dir -> exit 2" 2 "" -- notification 9 "$TMP/no-such-dir"
check "notification: missing issue-dir argument -> exit 2" 2 "" -- notification 9

# --- worktree: Step 3 item 4's worktree for a stopped implementer ----------------------
WD="$TMP/state/issue-7"; rm -rf "$WD"; mkdir -p "$WD"
printf '%s\n' "$W_OTHER" > "$WD/worktree"
check "a recorded worktree that still exists wins" 0 "$W_OTHER" -- worktree 7 "$WD"
printf '%s\n' "$TMP/gone" > "$WD/worktree"
check "a recorded worktree that is gone -> the /issue-N- branch's worktree" 0 "$W_CONTRACT" -- worktree 7 "$WD"
[ "$(cat "$WD/worktree")" = "$W_CONTRACT" ] && ok "the resolved worktree is recorded" || err "worktree not recorded: $(cat "$WD/worktree")"
rm -f "$WD/worktree"; printf 'agent-abc12\n' > "$WD/agent"
git -C "$REPO" worktree lock --reason "claude agent agent-abc123 (pid 1)" "$W_SCRATCH"
check "an agent id that is only a prefix of the locking one never matches" 0 "$W_CONTRACT" -- worktree 7 "$WD"
rm -f "$WD/worktree"; printf 'abc123\n' > "$WD/agent"
check "the worktree locked by the recorded agent id wins over the branch" 0 "$W_SCRATCH" -- worktree 7 "$WD"
git -C "$REPO" worktree unlock "$W_SCRATCH"
rm -f "$WD/worktree" "$WD/agent"
check "no match at all -> nothing, nothing recorded" 0 "" -- worktree 71 "$WD"
[ ! -e "$WD/worktree" ] && ok "nothing recorded when nothing matched" || err "a worktree was recorded with no match"

# --- pr-shape ---------------------------------------------------------------------------
# A second origin whose `main` advances after the clone: a branch forked from
# the advanced main holds one commit, but counts two against the clone's stale
# origin/main unless the script fetches both refs.
PO="$TMP/pr-origin.git"; PR_REPO="$TMP/pr-repo"; PUSHER="$TMP/pusher"
git init -q --bare "$PO"; git -C "$PO" symbolic-ref HEAD refs/heads/main
git init -q "$PUSHER"; git -C "$PUSHER" symbolic-ref HEAD refs/heads/main
git -C "$PUSHER" commit -q --allow-empty -m base
git -C "$PUSHER" remote add origin "$PO"; git -C "$PUSHER" push -q origin main
git clone -q --single-branch "$PO" "$PR_REPO"                   # origin/main = base; fetches only main
git -C "$PUSHER" commit -q --allow-empty -m "sibling merge"      # main advances
git -C "$PUSHER" push -q origin main
push_branch() {   # push_branch BRANCH NCOMMITS — forked from the advanced main
  git -C "$PUSHER" checkout -q -B "$1" main
  local i=0; while [ "$i" -lt "$2" ]; do git -C "$PUSHER" commit -q --allow-empty -m "c$i"; i=$((i + 1)); done
  git -C "$PUSHER" push -q -f origin "$1"; git -C "$PUSHER" checkout -q main
}
push_branch feat/issue-7-slug 1
push_branch fix/issue-8-slug 3
push_branch feat/issue-9-orphan 1
push_branch feat/issue-70-slug 1
PLAN_BODY=$'## Summary\n\nDraft checkpoint.\n\nCloses #7\n\n## Plan\n\n1. Do it.'
IMPL_BODY=$'## Summary\n\nDone.\n\n## Changes\n\n- it'

CWD="$PR_REPO"
stub_reset
stub open-all "$(printf '21 feat/issue-7-slug true\n22 fix/issue-8-slug true\n70 feat/issue-70-slug true')"
stub view-21 "true"$'\n'"$PLAN_BODY"
stub view-22 "true"$'\n'"$PLAN_BODY"
check "checkpoint-only branch count: draft, ## Plan, one commit ahead of a refreshed stale base -> draft (checkpoint)" 0 \
  "pr #21 feat/issue-7-slug draft (checkpoint)" -- pr-shape 7 main
check "row 24: draft with ## Plan but three commits -> draft (implemented, not ready)" 0 \
  "pr #22 fix/issue-8-slug draft (implemented, not ready)" -- pr-shape 8 main
stub view-21 "true"$'\n'"$IMPL_BODY"
check "draft, one commit, body rewritten (no ## Plan) -> draft (implemented, not ready)" 0 \
  "pr #21 feat/issue-7-slug draft (implemented, not ready)" -- pr-shape 7 main
stub view-21 "false"$'\n'"$IMPL_BODY"
check "row 25: non-draft implemented PR -> non-draft (implemented, not ready)" 0 \
  "pr #21 feat/issue-7-slug non-draft (implemented, not ready)" -- pr-shape 7 main
stub view-21 "false"$'\n'"$PLAN_BODY"
check "non-draft checkpoint (drafts refused) -> non-draft (checkpoint)" 0 \
  "pr #21 feat/issue-7-slug non-draft (checkpoint)" -- pr-shape 7 main
stub view-21 "true"$'\n## Summary\r\n\r\n## Plan \r\n\r\n1. Do it.\r'
check "a CRLF body with a trailing-space ## Plan heading is still the checkpoint" 0 \
  "pr #21 feat/issue-7-slug draft (checkpoint)" -- pr-shape 7 main
stub view-21 "true"$'\n## Summary\n\n## Planning notes\n'
check "## Planning is not the ## Plan heading" 0 \
  "pr #21 feat/issue-7-slug draft (implemented, not ready)" -- pr-shape 7 main

stub_reset; stub open-all "70 feat/issue-70-slug true"
check "row 23: pushed branch, no open PR -> branch only (no PR)" 0 \
  "branch feat/issue-9-orphan branch only (no PR)" -- pr-shape 9 main
check "no PR and no branch -> none" 0 "none" -- pr-shape 11 main
stub all-feat_issue-9-orphan "$(printf '41\n43')"
check "row 23: a branch whose PRs are all merged or closed is listed, not as an orphan" 0 \
  "branch feat/issue-9-orphan no open PR (only merged or closed PRs: #41 #43)" -- pr-shape 9 main

push_branch chore/issue-7-second 1
stub_reset; stub open-all "21 feat/issue-7-slug true"; stub view-21 "true"$'\n'"$PLAN_BODY"
check "an open PR and a second orphan branch -> one line each" 0 \
  "$(printf 'pr #21 feat/issue-7-slug draft (checkpoint)\nbranch chore/issue-7-second branch only (no PR)')" -- pr-shape 7 main

stub_reset; stub open-all "21 feat/issue-7-slug maybe"; stub view-21 "maybe"$'\n'"$PLAN_BODY"
check "unexpected isDraft -> exit 1" 1 "" -- pr-shape 7 main
stub_reset; stub open-all "$(printf '40 fork-user/issue-7-x false\n21 feat/issue-7-slug true')"; stub view-21 "true"$'\n'"$PLAN_BODY"
check "an open PR whose branch is not on origin gets its own line, the rest still shaped" 0 \
  "$(printf 'pr #40 fork-user/issue-7-x shape unknown (branch not on origin)\npr #21 feat/issue-7-slug draft (checkpoint)\nbranch chore/issue-7-second branch only (no PR)')" -- pr-shape 7 main
stub_reset; : > "$GH_STUB/fail-prlist-all"
check "probe 3's per-branch PR query fails -> exit 1" 1 "" -- pr-shape 9 main
stub_reset; : > "$GH_STUB/fail-prlist"
check "open-PR listing fails -> exit 1" 1 "" -- pr-shape 7 main
stub_reset
git -C "$PR_REPO" remote set-url origin "$TMP/no-such-origin.git"
check "probe 3 fails (origin unreachable) -> exit 1, never read as no branch" 1 "" -- pr-shape 9 main
stub_reset; stub open-all "21 feat/issue-7-slug true"; stub view-21 "true"$'\n'"$PLAN_BODY"
check "fetch fails -> exit 1" 1 "" -- pr-shape 7 main
check "empty default branch -> exit 2" 2 "" -- pr-shape 7 ""
unset CWD

# --- Accounting against docs/scenarios.md ----------------------------------------------
# Rows exercised above. Row 21 only for its classification (the stop and the
# worktree resolution are Step 3 item 4's); row 15 only for the no-worktree
# case; rows 23-25 only for the Step 5 label (the resume, the revert to draft
# and the crash are Step 3a's and the implementer's). Every other row is outside these two
# classifications: see test-scheduler.sh for the state machine's rows.
IN_SCOPE_ROWS="5 6 11 14 15 16 17 18 21 23 24 25 35 76"
EXPECTED_ROW_COUNT=87
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
  printf '\ntest-classify: FAILED\n' >&2
  exit 1
fi
printf '\ntest-classify: OK\n'
