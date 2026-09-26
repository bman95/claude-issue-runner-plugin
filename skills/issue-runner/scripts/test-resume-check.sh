#!/usr/bin/env bash
#
# Fixtures for scripts/resume-check.sh: issue-runner Step 3a's resume check
# (the branch-contract, closing-keyword and orphan-branch probes).
# `docs/scenarios.md` is the human-readable contract; this script is its
# executable form for the rows listed in IN_SCOPE_ROWS at the bottom.
#
# `gh` is a stub on PATH that answers from per-fixture files and logs every
# call. git is real: a bare origin carrying the probe-3 branches, and a clone
# the script runs in (the orchestrator's cwd) with worktrees on some of them.
#
# Run directly, or from scripts/lint.sh (and so from CI). Dependency-free:
# bash + git + coreutils. Exits non-zero on the first-or-any failure.

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="$ROOT/skills/issue-runner/scripts/resume-check.sh"
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

if [ ! -f "$SCRIPT" ]; then err "resume-check.sh not found"; exit 1; fi

# --- Stub gh ------------------------------------------------------------------
# Answers from files in $GH_STUB (branch names have `/` replaced by `_`):
#   open-all         `gh pr list --state open` (no --search)  "number branch isDraft" lines
#   search           `gh pr list --state open --search …`     "number branch isDraft" lines
#   body-<P>         `gh pr view P --json body`               the body
#   all-<branch>     `gh pr list --head B --state all`        "number STATE headRefOid" lines
#   fail-open        the plain open listing fails
#   fail-search      the --search listing fails
#   fail-all         every --head listing fails
# Every call is appended to $GH_STUB/log as `[arg][arg]…`.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
d=$GH_STUB
{ for a in "$@"; do printf '[%s]' "$a"; done; printf '\n'; } >> "$d/log"
case "$1 $2" in
  "pr view") [ -f "$d/body-$3" ] || exit 1; cat "$d/body-$3"; exit 0 ;;
  "pr list")
    head="" search=""; shift 2
    while [ $# -gt 0 ]; do
      case $1 in --head) head=$2; shift ;; --search) search=$2; shift ;; esac; shift
    done
    if [ -n "$head" ]; then
      [ -f "$d/fail-all" ] && exit 1
      f="$d/all-$(printf '%s' "$head" | tr / _)"
    elif [ -n "$search" ]; then
      [ -f "$d/fail-search" ] && exit 1
      f="$d/search"
    else
      [ -f "$d/fail-open" ] && exit 1
      f="$d/open-all"
    fi
    [ -f "$f" ] && cat "$f"; exit 0 ;;
esac
exit 1
EOF
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"

stub_reset() { rm -rf "$TMP/stub"; mkdir -p "$TMP/stub"; export GH_STUB="$TMP/stub"; : > "$GH_STUB/log"; }
stub() { printf '%s\n' "$2" > "$GH_STUB/$1"; }

# --- Repositories -------------------------------------------------------------
ORIGIN="$TMP/origin.git"
REPO="$TMP/repo"
git init -q --bare "$ORIGIN"
git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
git init -q "$REPO"
git -C "$REPO" symbolic-ref HEAD refs/heads/main
git -C "$REPO" commit -q --allow-empty -m base
git -C "$REPO" remote add origin "$ORIGIN"
git -C "$REPO" push -q origin main

# push_branch BRANCH -> push a one-commit BRANCH to origin; prints its tip
push_branch() {
  git -C "$REPO" branch -q "$1" main \
    && git -C "$REPO" push -q origin "$1" 2>/dev/null \
    && git -C "$REPO" rev-parse "$1"
}
# A path with a space: the worktree field is the rest of the line.
WT_SPACE="$TMP/leftover worktree"

# check NAME EXPECTED_EXIT EXPECTED_STDOUT N
check() {
  local name="$1" want_rc="$2" want_out="$3" n="$4"
  local out rc
  out=$(cd "$REPO" && bash "$SCRIPT" "$n" 2>"$TMP/stderr"); rc=$?
  if [ "$rc" = "$want_rc" ] && [ "$out" = "$want_out" ]; then
    ok "$name"
  else
    err "$name (exit $rc, want $want_rc)"
    printf '%s\n' "$want_out" | sed 's/^/  expected> /' >&2
    printf '%s\n' "$out" | sed 's/^/  actual  > /' >&2
    sed 's/^/  stderr  > /' "$TMP/stderr" >&2
  fi
}

# --- No match anywhere --------------------------------------------------------
stub_reset
check "no PR, no branch -> none (dispatch fresh)" 0 "none" 7

# --- Row 7: one open PR on the contract -----------------------------------------
T7=$(push_branch feat/issue-7-slug)
stub_reset; stub open-all "21 feat/issue-7-slug false"
check "row 7: open contract PR -> one pr line, no worktree" 0 \
  "pr #21 feat/issue-7-slug draft=false via=contract worktree=-" 7

# --- Row 8: the resume branch is checked out in a leftover worktree -------------
git -C "$REPO" worktree add -q "$WT_SPACE" feat/issue-7-slug 2>/dev/null
check "row 8: the branch is checked out -> its worktree path (spaces kept)" 0 \
  "pr #21 feat/issue-7-slug draft=false via=contract worktree=$WT_SPACE" 7

# --- Row 22: a draft checkpoint, also found by its Closes #N body ----------------
stub_reset; stub open-all "21 feat/issue-7-slug true"; stub search "21 feat/issue-7-slug true"
check "row 22: draft checkpoint found by both probes -> one line, via=both" 0 \
  "pr #21 feat/issue-7-slug draft=true via=both worktree=$WT_SPACE" 7
if grep -qF '[pr][view]' "$GH_STUB/log"; then err "a PR already found by probe 1 had its body re-read"
else ok "a probe-1 PR is not re-read for the keyword check"; fi
stub_reset
check "row 23: an orphan checked out in a leftover worktree -> its worktree path" 0 \
  "branch feat/issue-7-slug $T7 orphan worktree=$WT_SPACE" 7
git -C "$REPO" worktree remove -f "$WT_SPACE"

# --- Closing keywords: confirmed, and not ---------------------------------------
stub_reset; stub search "$(printf '31 someone/any-name false\n32 other/name false\n33 third/name false\n34 fourth/name true')"
stub body-31 "Implements the thing.

Fixes: #7"
stub body-32 "See #7 for context; closes #70."
stub body-33 "closes #7x"
stub body-34 "RESOLVED #7"
check "keyword hits: plain closing references are pr lines, the rest keyword-unconfirmed" 0 \
  "$(printf '%s\n%s\n%s\n%s\n%s' \
    "pr #31 someone/any-name draft=false via=keyword worktree=-" \
    "pr #34 fourth/name draft=true via=keyword worktree=-" \
    "keyword-unconfirmed #32 other/name draft=false worktree=-" \
    "keyword-unconfirmed #33 third/name draft=false worktree=-" \
    "branch feat/issue-7-slug $T7 orphan worktree=-")" 7
stub_reset; stub search "$(printf '35 a/b false\n36 c/d false\n37 e/f false')"
stub body-35 "Closes o/r#7"
stub body-36 "Fixes https://github.com/o/r/issues/7"
stub body-37 "**Closes** #7"
check "cross-repo, URL and emphasized forms are never dropped: unconfirmed, for the orchestrator" 0 \
  "$(printf '%s\n%s\n%s\n%s' \
    "keyword-unconfirmed #35 a/b draft=false worktree=-" \
    "keyword-unconfirmed #36 c/d draft=false worktree=-" \
    "keyword-unconfirmed #37 e/f draft=false worktree=-" \
    "branch feat/issue-7-slug $T7 orphan worktree=-")" 7
git -C "$REPO" worktree add -q -b kw/branch "$TMP/wt-kw" main 2>/dev/null
stub_reset; stub search "38 kw/branch true"; stub body-38 "Closes o/r#7"
check "an unconfirmed hit carries draft= and worktree= like a pr line" 0 \
  "$(printf '%s\n%s' \
    "keyword-unconfirmed #38 kw/branch draft=true worktree=$TMP/wt-kw" \
    "branch feat/issue-7-slug $T7 orphan worktree=-")" 7

# --- Several matches ------------------------------------------------------------
stub_reset
stub open-all "$(printf '40 feat/issue-7-a false\n21 feat/issue-7-slug true\n50 feat/issue-70-slug false')"
check "several contract PRs -> one line each, sorted; #70 never matches #7" 0 \
  "$(printf '%s\n%s' \
    "pr #21 feat/issue-7-slug draft=true via=contract worktree=-" \
    "pr #40 feat/issue-7-a draft=false via=contract worktree=-")" 7

# --- Row 23: probe 3 branch classification -------------------------------------
# feat/issue-7-slug is on origin; each fixture gives it a PR history.
stub_reset
check "row 23: branch with no PR at all -> orphan" 0 "branch feat/issue-7-slug $T7 orphan worktree=-" 7
stub_reset; stub all-feat_issue-7-slug "$(printf '9 CLOSED 1111111111111111111111111111111111111111\n12 MERGED %s' "$T7")"
check "row 23: merged PR on the current tip -> stale" 0 "branch feat/issue-7-slug $T7 stale #12" 7
stub_reset; stub all-feat_issue-7-slug "12 MERGED 1111111111111111111111111111111111111111"
check "row 23: merged PR, tip moved on -> ask" 0 "branch feat/issue-7-slug $T7 ask (#12 merged)" 7
stub_reset; stub all-feat_issue-7-slug "$(printf '9 CLOSED %s\n12 MERGED 1111111111111111111111111111111111111111' "$T7")"
check "row 23: closed PR (even on the tip) and a moved merge -> ask" 0 \
  "branch feat/issue-7-slug $T7 ask (#9 closed, #12 merged)" 7
stub_reset; stub open-all "21 feat/issue-7-slug false"
check "a branch an open PR covers gets no branch line" 0 \
  "pr #21 feat/issue-7-slug draft=false via=contract worktree=-" 7
T70=$(push_branch feat/issue-70-slug)
stub_reset
check "probe 3 for #7 ignores feat/issue-70-slug" 0 "branch feat/issue-7-slug $T7 orphan worktree=-" 7
check "probe 3 for #70 finds only feat/issue-70-slug" 0 "branch feat/issue-70-slug $T70 orphan worktree=-" 70

# --- Failures ---------------------------------------------------------------------
stub_reset; stub fail-open x
check "probe 1 query fails -> exit 1, nothing on stdout" 1 "" 7
stub_reset; stub fail-search x
check "probe 2 query fails -> exit 1" 1 "" 7
stub_reset; stub search "31 someone/any-name false"
check "a keyword hit whose body cannot be read -> exit 1" 1 "" 7
stub_reset; stub fail-all x
check "probe 3 history query fails -> exit 1" 1 "" 7
git -C "$REPO" remote set-url origin "$TMP/no-such-origin.git"
stub_reset
out=$(cd "$REPO" && bash "$SCRIPT" 7 2>/dev/null); rc=$?
case $out in
  "probe3-failed git ls-remote exit "*)
    if [ "$rc" = 0 ]; then ok "probe 3 fails twice, no PR -> probe3-failed alone, never none"
    else err "probe 3 failure exit $rc"; fi ;;
  *) err "probe 3 failure printed: $out" ;;
esac
[ "$(grep -c 'ls-remote' "$GH_STUB/log")" = 0 ] || err "git ls-remote went through the gh stub"
stub_reset; stub open-all "21 feat/issue-7-slug false"
out=$(cd "$REPO" && bash "$SCRIPT" 7 2>/dev/null)
if [ "$(printf '%s\n' "$out" | head -n 1)" = "pr #21 feat/issue-7-slug draft=false via=contract worktree=-" ] \
   && printf '%s\n' "$out" | tail -n 1 | grep -q '^probe3-failed '; then
  ok "probe 3 fails with a PR found -> the pr line, then probe3-failed"
else
  err "probe 3 failure with a PR printed: $out"
fi
git -C "$REPO" remote set-url origin "$ORIGIN"

check "missing issue number -> exit 2" 2 "" ""
check "issue 0 -> exit 2" 2 "" 0
check "non-numeric issue -> exit 2" 2 "" 7a

# --- Accounting against docs/scenarios.md ----------------------------------------------
# Rows exercised above, for the probes and their classification only: what the
# orchestrator then does (resume, ask, delete a stale branch) is the prose's.
IN_SCOPE_ROWS="7 8 22 23"
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
  printf '\ntest-resume-check: FAILED\n' >&2
  exit 1
fi
printf '\ntest-resume-check: OK\n'
