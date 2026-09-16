#!/usr/bin/env bash
#
# Fixtures for gh-issue's "Validation contract" recipe — the ```bash block in
# skills/gh-issue/SKILL.md that discovers `.issue-runner/validation` at the
# merge-base with the base branch and runs its `preflight:` / `full:` command.
# `docs/scenarios.md` rows 39–44 are the human-readable contract; this script
# is their executable form for the part that is pure shell: discovery, the
# grammar, the exit-status classes, and the trust rule (the merge-base copy
# runs — never the working tree's, never the base tip's).
#
# The block is extracted from the skill file itself, so the recipe under test
# is exactly the one implementers run — and the Codex edition's canonical copy
# must carry it byte-for-byte (lint's bash -n pass covers only skills/). The
# block's own `gh` calls resolve the base branch; a stub `gh` on PATH answers
# them here, so those lines execute under test too.
#
# Run directly, or from scripts/lint.sh (and so from CI). Dependency-free:
# bash + git + coreutils. Exits non-zero on the first-or-any failure.

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL_GH="$ROOT/skills/gh-issue/SKILL.md"
CANON_GH="$ROOT/codex/issue-runner/canonical/gh-issue/SKILL.md"

fail=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ok()   { printf 'ok:   %s\n' "$1"; }
err()  { printf 'FAIL: %s\n' "$1" >&2; fail=1; }

# Extract the recipe: the one ```bash block whose first line sets MODE.
extract_block() {
  awk '
    !inb && /^[[:space:]]*```bash[[:space:]]*$/ { inb=1; buf=""; next }
    inb && /^[[:space:]]*```[[:space:]]*$/     { inb=0; if (buf ~ /^MODE=/) printf "%s", buf; next }
    inb { buf = buf $0 "\n" }
  ' "$1"
}

extract_block "$SKILL_GH" > "$TMP/block.sh"
extract_block "$CANON_GH" > "$TMP/block-canon.sh"
if [ ! -s "$TMP/block.sh" ]; then
  err "no validation-contract block (first line MODE=...) found in skills/gh-issue/SKILL.md"
  exit 1
fi
if [ "$(cat "$TMP/block.sh")" = "$(cat "$TMP/block-canon.sh")" ]; then
  ok "validation-contract block byte-identical in both editions"
else
  err "validation-contract block differs between skills/gh-issue and the Codex canonical copy (compare the MODE= bash blocks)"
fi
if bash -n "$TMP/block.sh" 2>"$TMP/block.err"; then
  ok "validation-contract block parses (bash -n)"
else
  err "validation-contract block does not parse:"; cat "$TMP/block.err" >&2
fi

# Stub `gh`: the block asks it for the PR's base branch (`gh pr view`) or the
# default branch (`gh repo view`); both answer with $GH_STUB_BRANCH.
mkdir -p "$TMP/bin"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "${GH_STUB_BRANCH:-main}"\n' > "$TMP/bin/gh"
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"

# Portable "init with branch main" (git >= 2.5 per README; `git init -b` needs 2.28).
init_main() { git init -q "$1" && git -C "$1" symbolic-ref HEAD refs/heads/main; }
gitc() { git config user.email t@example.com; git config user.name t; git config commit.gpgsign false; }

# fixture NAME MODE MAIN_CONTRACT BRANCH_CONTRACT EXPECTED_EXIT EXPECTED_TEXT [OPTS...]
#   NAME            - test label
#   MODE            - check | preflight | full | anything else (the block rejects it)
#   MAIN_CONTRACT   - content of .issue-runner/validation on the base branch at
#                     the fork point, or "-" for no contract at all
#   BRANCH_CONTRACT - content committed to the same path on the feature branch
#                     (the PR's own edit — must be ignored), or "-" for none
#   EXPECTED_EXIT   - the block's exit status
#   EXPECTED_TEXT   - a substring that must appear in stdout+stderr
#   OPTS            - any of:
#       base=<name>          what the stub gh reports as the base branch (default main)
#       advance=<contract>   after the fork, commit this contract to main and push it —
#                            the base tip then differs from the merge-base ("-" removes it)
#       worktree=<contract>  write this to the working tree uncommitted (an edit in
#                            progress — must be ignored)
#       cwd=<subdir>         run the block from this subdirectory of the worktree
#
# Builds a bare origin with `main`, a clone on a feature branch one commit
# ahead, and runs the block there — exactly the shape gh-issue Steps 3/5/8/9
# run it in.
fixture() {
  local name="$1" mode="$2" main_contract="$3" branch_contract="$4" expected_exit="$5" expected_text="$6"
  shift 6
  local base=main advance="" advance_set=0 worktree="" worktree_set=0 cwd="" opt
  for opt in "$@"; do
    case $opt in
      base=*)     base="${opt#base=}" ;;
      advance=*)  advance="${opt#advance=}"; advance_set=1 ;;
      worktree=*) worktree="${opt#worktree=}"; worktree_set=1 ;;
      cwd=*)      cwd="${opt#cwd=}" ;;
    esac
  done
  local run="$TMP/$(printf '%s' "$name" | tr -c 'A-Za-z0-9' '_')"
  rm -rf "$run"; mkdir -p "$run"
  git init -q --bare "$run/origin.git"
  init_main "$run/wt"
  (
    cd "$run/wt" || exit 1
    gitc
    printf 'x\n' > README; mkdir -p sub; printf 'z\n' > sub/file; git add README sub/file; git commit -q -m base
    if [ "$main_contract" != "-" ]; then
      mkdir -p .issue-runner; printf '%s\n' "$main_contract" > .issue-runner/validation
      git add .issue-runner/validation; git commit -q -m contract
    fi
    git remote add origin "$run/origin.git"; git push -q origin main
    git checkout -q -b feature
    printf 'y\n' > change; git add change
    if [ "$branch_contract" != "-" ]; then
      mkdir -p .issue-runner; printf '%s\n' "$branch_contract" > .issue-runner/validation
      git add .issue-runner/validation
    fi
    git commit -q -m change
    if [ "$advance_set" -eq 1 ]; then
      # main moves on after the fork: a clone elsewhere lands a new contract on origin.
      git clone -q "$run/origin.git" "$run/other" && cd "$run/other" && gitc || exit 1
      if [ "$advance" = "-" ]; then git rm -q .issue-runner/validation; else
        mkdir -p .issue-runner; printf '%s\n' "$advance" > .issue-runner/validation; git add .issue-runner/validation
      fi
      git commit -q -m advance && git push -q origin main
      cd "$run/wt" || exit 1
    fi
    if [ "$worktree_set" -eq 1 ]; then
      mkdir -p .issue-runner; printf '%s\n' "$worktree" > .issue-runner/validation
    fi
  ) >"$run/setup.log" 2>&1 || { err "$name: fixture setup failed:"; cat "$run/setup.log" >&2; return; }

  local actual_exit
  (cd "$run/wt/$cwd" && MODE="$mode" GH_STUB_BRANCH="$base" bash "$TMP/block.sh") >"$run/out" 2>&1
  actual_exit=$?
  if [ "$actual_exit" -eq "$expected_exit" ] && grep -qF -- "$expected_text" "$run/out"; then
    ok "$name"
  else
    err "$name: exit $actual_exit (expected $expected_exit), output:"
    sed 's/^/  > /' "$run/out" >&2
    printf '  expected text> %s\n' "$expected_text" >&2
  fi
}

# --- Row 39: contract present -------------------------------------------------
fixture "row 39: contract present, preflight passes" preflight \
  $'# comment\n\npreflight: true' - 0 "validation: preflight passed"
fixture "row 39: preflight runs from the worktree root (invoked from a subdirectory)" preflight \
  'preflight: test -f README && test -f change && test -f sub/file' - 0 "validation: preflight passed" cwd=sub
fixture "row 39: MODE=check reports the contract without running it" check \
  'preflight: exit 7' - 0 "validation: contract ok (preflight declared; full not declared)"
fixture "row 39: this repository's own contract passes the grammar" check \
  "$(cat "$ROOT/.issue-runner/validation")" - 0 "validation: contract ok"

# --- Row 40: contract absent → fallback, never an error ------------------------
fixture "row 40: no contract on the base branch" preflight \
  - - 0 "validation: fallback (no contract"
fixture "row 40: MODE=check on an absent contract is the same fallback" check \
  - - 0 "validation: fallback (no contract"

# --- Row 41: preflight failure ------------------------------------------------
fixture "row 41: preflight fails (exit 7 → 1)" preflight \
  'preflight: exit 7' - 1 "validation: preflight failed (exit 7): exit 7"

# --- Row 42: optional full validation -----------------------------------------
fixture "row 42: full declared and passes" full \
  $'preflight: true\nfull: true' - 0 "validation: full passed"
fixture "row 42: full declared and fails" full \
  $'preflight: true\nfull: exit 5' - 1 "validation: full failed (exit 5)"
fixture "row 42: full not declared → nothing to run" full \
  'preflight: true' - 0 "validation: full not declared"
fixture "row 42: MODE=check reports a declared full" check \
  $'preflight: true\nfull: true' - 0 "full declared)"

# --- Row 43: invalid contract / command not runnable --------------------------
fixture "row 43: stray key line is invalid (exit 3)" preflight \
  $'preflight: true\nlint: true' - 3 "validation: invalid contract"
fixture "row 43: missing preflight is invalid (exit 3)" preflight \
  'full: true' - 3 "preflight lines=0"
fixture "row 43: duplicate preflight is invalid (exit 3)" preflight \
  $'preflight: true\npreflight: false' - 3 "preflight lines=2"
fixture "row 43: empty command is invalid (exit 3)" preflight \
  'preflight:' - 3 "validation: invalid contract"
fixture "row 43: CRLF line endings are invalid (exit 3)" preflight \
  $'preflight: true\r' - 3 "CRLF line endings"
fixture "row 43: invalid contract is judged before full runs too" full \
  $'full: true\nbogus' - 3 "validation: invalid contract"
fixture "row 43: MODE=check rejects an invalid contract (exit 3)" check \
  'bogus' - 3 "validation: invalid contract"
fixture "row 43: unknown MODE is rejected, never a silent pass (exit 3)" ful \
  'preflight: true' - 3 "validation: unknown MODE 'ful'"
fixture "row 43: command not found (127 → 4)" preflight \
  'preflight: ./no-such-script-42' - 4 "validation: preflight command not runnable (exit 127)"
fixture "row 43: command not executable (126 → 4)" preflight \
  'preflight: ./README' - 4 "validation: preflight command not runnable (exit 126)"

# --- Row 44: only the merge-base copy is trusted ------------------------------
fixture "row 44: branch edit ignored, base copy runs (pass)" preflight \
  'preflight: true' 'preflight: exit 9' 0 "validation: preflight passed"
fixture "row 44: branch edit ignored, base copy runs (fail)" preflight \
  'preflight: exit 9' 'preflight: true' 1 "validation: preflight failed (exit 9)"
fixture "row 44: branch-added contract with none on base → fallback" preflight \
  - 'preflight: exit 9' 0 "validation: fallback (no contract"
fixture "row 44: uncommitted working-tree edit ignored" preflight \
  'preflight: true' - 0 "validation: preflight passed" 'worktree=preflight: exit 9'
fixture "row 44: base tip advanced after the fork — the merge-base copy runs, not the tip's" preflight \
  'preflight: true' - 0 "validation: preflight passed" 'advance=preflight: exit 9'
fixture "row 44: contract added to base after the fork → still the fork point's fallback" preflight \
  - - 0 "validation: fallback (no contract" 'advance=preflight: exit 9'
fixture "row 44: contract removed from base after the fork → the fork point's copy still runs" preflight \
  'preflight: exit 9' - 1 "validation: preflight failed (exit 9)" advance=-

# --- Base unresolvable: an environment failure, never a fallback ---------------
fixture "base unresolvable: remote exists, branch missing (exit 2)" preflight \
  'preflight: true' - 2 "validation: cannot resolve the base branch" base=nope
fixture "base unresolvable: MODE=check exits 2 too, never fallback" check \
  - - 2 "validation: cannot resolve the base branch" base=nope

if [ "$fail" -ne 0 ]; then
  printf '\ntest-validation-contract: FAILED\n' >&2
  exit 1
fi
printf '\ntest-validation-contract: OK\n'
