#!/usr/bin/env bash
#
# Fixtures for gh-issue's "Validation contract" recipe — the ```bash block in
# skills/gh-issue/SKILL.md that discovers `.issue-runner/validation` at the
# merge-base with the base branch and runs its `preflight:` / `full:` command.
# `docs/scenarios.md` rows 39–44 are the human-readable contract; this script
# is their executable form for the part that is pure shell: discovery, the
# grammar, the exit-status classes, and the trust rule (the base branch's copy
# runs, never the working tree's).
#
# The block is extracted from the skill file itself, so the recipe under test
# is exactly the one implementers run — and the Codex edition's canonical copy
# must carry it byte-for-byte (lint's bash -n pass covers only skills/).
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
if cmp -s "$TMP/block.sh" "$TMP/block-canon.sh"; then
  ok "validation-contract block byte-identical in both editions"
else
  err "validation-contract block differs between skills/gh-issue and the Codex canonical copy:"
  diff "$TMP/block.sh" "$TMP/block-canon.sh" >&2 || true
fi
if bash -n "$TMP/block.sh" 2>"$TMP/block.err"; then
  ok "validation-contract block parses (bash -n)"
else
  err "validation-contract block does not parse:"; cat "$TMP/block.err" >&2
fi

# fixture NAME MODE MAIN_CONTRACT BRANCH_CONTRACT EXPECTED_EXIT EXPECTED_TEXT
#   NAME            - test label
#   MODE            - preflight | full
#   MAIN_CONTRACT   - content of .issue-runner/validation on the base branch,
#                     or "-" for no contract at all
#   BRANCH_CONTRACT - content committed to the same path on the feature branch
#                     (the PR's own edit — must be ignored), or "-" for none
#   EXPECTED_EXIT   - the block's exit status
#   EXPECTED_TEXT   - a substring that must appear in stdout+stderr
#
# Builds a bare origin with `main`, a clone on a feature branch one commit
# ahead, and runs the block there with MODE and BASE_BRANCH pre-set (so no
# `gh` call is made) and BASE_BRANCH=main — exactly the shape gh-issue Step 8
# runs it in.
fixture() {
  local name="$1" mode="$2" main_contract="$3" branch_contract="$4" expected_exit="$5" expected_text="$6"
  local run="$TMP/$(printf '%s' "$name" | tr -c 'A-Za-z0-9' '_')"
  rm -rf "$run"; mkdir -p "$run"
  git init -q --bare "$run/origin.git"
  git init -q -b main "$run/wt"
  (
    cd "$run/wt" || exit 1
    git config user.email t@example.com; git config user.name t; git config commit.gpgsign false
    printf 'x\n' > README; git add README; git commit -q -m base
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
  ) >"$run/setup.log" 2>&1 || { err "$name: fixture setup failed:"; cat "$run/setup.log" >&2; return; }

  local actual_exit
  (cd "$run/wt" && MODE="$mode" BASE_BRANCH=main bash "$TMP/block.sh") >"$run/out" 2>&1
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
fixture "row 39: preflight runs from the worktree root" preflight \
  'preflight: test -f README && test -f change' - 0 "validation: preflight passed"

# --- Row 40: contract absent → fallback, never an error ------------------------
fixture "row 40: no contract on the base branch" preflight \
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

# --- Row 43: invalid contract / command not runnable --------------------------
fixture "row 43: stray key line is invalid (exit 3)" preflight \
  $'preflight: true\nlint: true' - 3 "validation: invalid contract"
fixture "row 43: missing preflight is invalid (exit 3)" preflight \
  'full: true' - 3 "preflight lines=0"
fixture "row 43: duplicate preflight is invalid (exit 3)" preflight \
  $'preflight: true\npreflight: false' - 3 "preflight lines=2"
fixture "row 43: empty command is invalid (exit 3)" preflight \
  'preflight:' - 3 "validation: invalid contract"
fixture "row 43: invalid contract is judged before full runs too" full \
  $'full: true\nbogus' - 3 "validation: invalid contract"
fixture "row 43: command not found (127 → 4)" preflight \
  'preflight: ./no-such-script-42' - 4 "validation: preflight command not runnable (exit 127)"
fixture "row 43: command not executable (126 → 4)" preflight \
  'preflight: ./README' - 4 "validation: preflight command not runnable (exit 126)"

# --- Row 44: the PR's own edit of the contract is inert -----------------------
fixture "row 44: branch edit ignored, base copy runs (pass)" preflight \
  'preflight: true' 'preflight: exit 9' 0 "validation: preflight passed"
fixture "row 44: branch edit ignored, base copy runs (fail)" preflight \
  'preflight: exit 9' 'preflight: true' 1 "validation: preflight failed (exit 9)"
fixture "row 44: branch-added contract with none on base → fallback" preflight \
  - 'preflight: exit 9' 0 "validation: fallback (no contract"

# --- Base unresolvable: an environment failure, never a fallback ---------------
run="$TMP/base_unresolvable"; rm -rf "$run"; mkdir -p "$run"
git init -q -b main "$run/wt" && (
  cd "$run/wt" && git config user.email t@example.com && git config user.name t \
    && git config commit.gpgsign false && printf 'x\n' > README && git add README && git commit -q -m base
) >/dev/null 2>&1
(cd "$run/wt" && MODE=preflight BASE_BRANCH=nope bash "$TMP/block.sh") >"$run/out" 2>&1
actual_exit=$?
if [ "$actual_exit" -eq 2 ] && grep -qF "validation: cannot resolve the base branch" "$run/out"; then
  ok "base unresolvable → exit 2, no fallback"
else
  err "base unresolvable: exit $actual_exit (expected 2), output:"; sed 's/^/  > /' "$run/out" >&2
fi

if [ "$fail" -ne 0 ]; then
  printf '\ntest-validation-contract: FAILED\n' >&2
  exit 1
fi
printf '\ntest-validation-contract: OK\n'
