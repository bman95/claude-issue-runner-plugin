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

# --- result: rows 5, 6 ----------------------------------------------------------
stub_reset; stub issue-state CLOSED; stub merged-feat_issue-7-slug "11 $H_CONTRACT"
check "row 5: CLOSED + merged PR carrying the worktree's HEAD -> done" 0 "done #11" -- \
  result 7 "$W_CONTRACT" "" merged ""

stub_reset; stub issue-state CLOSED
check "row 6: CLOSED + no merged PR -> closed-externally" 0 \
  "closed-externally - closed without a merged implementer PR" -- result 7 "$W_CONTRACT" "" merged ""

# --- result: row 11, the empty-branch guard ---------------------------------------
stub_reset; stub issue-state CLOSED; stub merged- "99 $H_CONTRACT"   # what an unfiltered --head "" would match
check "row 11: CLOSED + worktree gone -> closed-externally, never done" 0 \
  "closed-externally - closed without a merged implementer PR" -- result 7 "$TMP/gone" "" merged ""
no_empty_head "row 11: worktree gone never runs gh pr list --head \"\""
no_head_query "row 11: worktree gone runs no --head query at all"

stub_reset; stub issue-state CLOSED; stub merged- "99 $H_CONTRACT"
check "row 11: CLOSED + no worktree path at all -> closed-externally" 0 \
  "closed-externally - closed without a merged implementer PR" -- result 7 "" "" none ""
no_empty_head "row 11: an empty worktree path never runs gh pr list --head \"\""

stub_reset; stub issue-state OPEN
check "row 11: open + worktree gone, blocker -> failed" 0 "failed - Codex gate cap-stop" -- \
  result 7 "$TMP/gone" "" blocker "Codex gate cap-stop"
check "row 15: open + no worktree, agent crashed -> failed" 0 "failed - agent crashed" -- \
  result 7 "" "" none "agent crashed"

# --- result: row 14, an unproven merged claim --------------------------------------
stub_reset; stub issue-state OPEN
check "row 14: open + outcome merged + no merged PR -> failed" 0 \
  "failed - result.json claims merged but no merged PR on feat/issue-7-slug" -- result 7 "$W_CONTRACT" "" merged ""
stub_reset; stub issue-state CLOSED
check "row 14: CLOSED + outcome merged + no merged PR -> closed-externally" 0 \
  "closed-externally - closed without a merged implementer PR" -- result 7 "$W_CONTRACT" "" merged ""

# --- result: row 16, merged but still open (and its suffixes) ----------------------
stub_reset; stub issue-state OPEN; stub merged-feat_issue-7-slug "11 $H_CONTRACT"
check "row 16: open + merged PR, outcome merged -> blocked, no suffix" 0 "blocked #11 $MERGED_OPEN" -- \
  result 7 "$W_CONTRACT" "" merged ""
check "row 16: open + merged PR, outcome blocker -> blocked with the blocker suffix" 0 \
  "blocked #11 $MERGED_OPEN: base freshness conflict" -- result 7 "$W_CONTRACT" "" blocker "base freshness conflict"
check "row 21: hung after merge, issue still open -> blocked with the hang suffix" 0 \
  "blocked #11 $MERGED_OPEN: $HANG" -- result 7 "$W_CONTRACT" "" hung "$HANG"
check "row 16: open + merged PR, no error at all -> blocked, no suffix" 0 "blocked #11 $MERGED_OPEN" -- \
  result 7 "$W_CONTRACT" "" none ""

# --- result: row 17, a branch outside the contract ---------------------------------
stub_reset; stub issue-state CLOSED
check "row 17: scratch branch, CLOSED -> closed-externally" 0 \
  "closed-externally - closed without a merged implementer PR" -- result 7 "$W_SCRATCH" "" merged ""
no_head_query "row 17: scratch branch runs no --head query"
stub_reset; stub issue-state OPEN
check "row 17: scratch branch, open, blocker -> blocked" 0 "blocked - Agent tool unavailable" -- \
  result 7 "$W_SCRATCH" "" blocker "Agent tool unavailable"
no_head_query "row 17: scratch branch (open) runs no --head query"
stub_reset; stub issue-state CLOSED; stub merged-feat_issue-70-slug "70 $H_SEVENTY"
check "row 17: #70's worktree never proves #7 (trailing dash)" 0 \
  "closed-externally - closed without a merged implementer PR" -- result 7 "$W_SEVENTY" "" merged ""
no_head_query "row 17: #70's branch runs no --head query for #7"
stub_reset; stub issue-state CLOSED; stub merged-someone_unrelated-name "31 $H_OTHER"
check "row 17: the branch Step 3a recorded is accepted as proof branch" 0 "done #31" -- \
  result 7 "$W_OTHER" "someone/unrelated-name" merged ""

# --- result: row 18, a previous run's merged PR on the same name --------------------
stub_reset; stub issue-state OPEN; stub merged-feat_issue-7-slug "9 $OLD_OID"
check "row 18: merged PR with another headRefOid, open, blocker -> blocked" 0 "blocked - checks failed" -- \
  result 7 "$W_CONTRACT" "" blocker "checks failed"
stub_reset; stub issue-state CLOSED; stub merged-feat_issue-7-slug "9 $OLD_OID"
check "row 18: merged PR with another headRefOid, CLOSED -> closed-externally" 0 \
  "closed-externally - closed without a merged implementer PR" -- result 7 "$W_CONTRACT" "" merged ""
stub_reset; stub issue-state CLOSED; stub merged-feat_issue-7-slug "$(printf '9 %s\n12 %s' "$OLD_OID" "$H_CONTRACT")"
check "row 18: the PR carrying this HEAD wins among several" 0 "done #12" -- \
  result 7 "$W_CONTRACT" "" merged ""

# --- result: rows 21, 15 — the other open outcomes ---------------------------------
stub_reset; stub issue-state OPEN
check "row 21: hung, open, no merged PR -> failed with the hang string" 0 "failed - $HANG" -- \
  result 7 "$W_CONTRACT" "" hung "$HANG"
check "open + outcome failed -> failed" 0 "failed - validation: cannot resolve the base branch" -- \
  result 7 "$W_CONTRACT" "" failed "validation: cannot resolve the base branch"
check "a multi-line error stays on one line" 0 "failed - line one line two" -- \
  result 7 "$W_CONTRACT" "" failed $'line one\nline two'

# --- result: row 35, the ready claim ------------------------------------------------
stub_reset; stub issue-state OPEN; stub open-feat_issue-7-slug "12 false"
check "row 35: open, non-draft PR on the branch -> ready" 0 "ready #12" -- result 7 "$W_CONTRACT" "" ready ""
stub_reset; stub issue-state OPEN; stub open-feat_issue-7-slug "12 true"
check "row 35: the PR is a draft -> failed" 0 \
  "failed - result.json claims ready but no open, non-draft PR on feat/issue-7-slug" -- result 7 "$W_CONTRACT" "" ready ""
stub_reset; stub issue-state OPEN
check "row 35: no open PR -> failed" 0 \
  "failed - result.json claims ready but no open, non-draft PR on feat/issue-7-slug" -- result 7 "$W_CONTRACT" "" ready ""
stub_reset; stub issue-state OPEN; stub open-worktree-agent-abc123 "12 false"
check "row 35: scratch branch is no proof branch -> failed" 0 \
  "failed - result.json claims ready but no open, non-draft PR on worktree-agent-abc123" -- result 7 "$W_SCRATCH" "" ready ""
no_head_query "row 35: scratch branch runs no --head query"

# --- result: failures and usage ------------------------------------------------------
stub_reset
check "issue state query fails -> exit 1, no classification" 1 "" -- result 7 "$W_CONTRACT" "" merged ""
stub_reset; stub issue-state CLOSED; : > "$GH_STUB/fail-prlist"
check "merged-PR query fails -> exit 1, never read as no proof" 1 "" -- result 7 "$W_CONTRACT" "" merged ""
stub_reset; stub issue-state OPEN; : > "$GH_STUB/fail-prlist-open"
check "ready's open-PR query fails -> exit 1" 1 "" -- result 7 "$W_CONTRACT" "" ready ""
stub_reset; stub issue-state MERGED
check "unexpected issue state -> exit 1" 1 "" -- result 7 "$W_CONTRACT" "" merged ""
stub_reset; stub issue-state OPEN
check "unknown outcome -> exit 2" 2 "" -- result 7 "$W_CONTRACT" "" success ""
check "non-numeric issue -> exit 2" 2 "" -- result 7x "$W_CONTRACT" "" merged ""
check "missing arguments -> exit 2" 2 "" -- result 7 "$W_CONTRACT"
check "unknown mode -> exit 2" 2 "" -- classify 7

# --- pr-shape ---------------------------------------------------------------------------
# A second origin whose `main` advances after the clone: a branch forked from
# the advanced main holds one commit, but counts two against the clone's stale
# origin/main unless the script fetches both refs.
PO="$TMP/pr-origin.git"; PR_REPO="$TMP/pr-repo"; PUSHER="$TMP/pusher"
git init -q --bare "$PO"; git -C "$PO" symbolic-ref HEAD refs/heads/main
git init -q "$PUSHER"; git -C "$PUSHER" symbolic-ref HEAD refs/heads/main
git -C "$PUSHER" commit -q --allow-empty -m base
git -C "$PUSHER" remote add origin "$PO"; git -C "$PUSHER" push -q origin main
git clone -q "$PO" "$PR_REPO"                                    # origin/main = base
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
stub view-22 "false"$'\n'"$PLAN_BODY"
check "row 25: non-draft implemented PR -> non-draft (implemented, not ready)" 0 \
  "pr #21 feat/issue-7-slug non-draft (implemented, not ready)" -- pr-shape 7 main
stub view-21 "false"$'\n'"$PLAN_BODY"
check "non-draft checkpoint (drafts refused) -> non-draft (checkpoint)" 0 \
  "pr #21 feat/issue-7-slug non-draft (checkpoint)" -- pr-shape 7 main

stub_reset; stub open-all "70 feat/issue-70-slug true"
check "row 23: pushed branch, no open PR -> branch only (no PR)" 0 \
  "branch feat/issue-9-orphan branch only (no PR)" -- pr-shape 9 main
check "no PR and no branch -> none" 0 "none" -- pr-shape 11 main

push_branch chore/issue-7-second 1
stub_reset; stub open-all "21 feat/issue-7-slug true"; stub view-21 "true"$'\n'"$PLAN_BODY"
check "an open PR and a second orphan branch -> one line each" 0 \
  "$(printf 'pr #21 feat/issue-7-slug draft (checkpoint)\nbranch chore/issue-7-second branch only (no PR)')" -- pr-shape 7 main

stub_reset; stub open-all "21 feat/issue-7-slug maybe"; stub view-21 "maybe"$'\n'"$PLAN_BODY"
check "unexpected isDraft -> exit 1" 1 "" -- pr-shape 7 main
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
IN_SCOPE_ROWS="5 6 11 14 15 16 17 18 21 23 24 25 35"
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
  printf '\ntest-classify: FAILED\n' >&2
  exit 1
fi
printf '\ntest-classify: OK\n'
