#!/usr/bin/env bash
#
# Fixtures for gh-issue's "Validation contract" recipe — the ```bash block in
# skills/gh-issue/SKILL.md that discovers `.issue-runner/validation` on the base
# branch's tip and runs its `preflight:` / `full:` command (or, with
# MODE=changed, reports whether the PR itself edited the file).
# `docs/scenarios.md` rows 39–44 are the human-readable contract; this script
# is their executable form for the part that is pure shell: discovery, the
# grammar, the exit-status classes, and the trust rule (the base branch's copy
# runs — never the working tree's; the PR's own edit is judged against the
# merge-base).
#
# The block is extracted from the skill file itself, so the recipe under test
# is exactly the one implementers run — and the Codex edition's canonical copy
# must carry it byte-for-byte (lint's bash -n pass covers only skills/). The
# block's own `gh` calls resolve the base branch; a stub `gh` on PATH answers
# (or refuses) them here, so those lines execute under test too.
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

# Hermetic git: no user/system config (hooksPath, autocrlf, templates, signing) —
# $HOME, the system file, and the XDG/global paths git also reads.
export HOME="$TMP" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
unset XDG_CONFIG_HOME

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
# default branch (`gh repo view`); both answer with $GH_STUB_BRANCH, unless
# GH_STUB_FAIL=pr (only `gh pr view` fails — no PR yet), =prempty (`gh pr view`
# succeeds but prints nothing — the branch's only PR is closed or merged) or =all
# (no gh at all).
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "${GH_STUB_FAIL:-} $1" in
  "all "*|"pr pr") exit 1 ;;
  "prempty pr") exit 0 ;;
esac
printf '%s\n' "${GH_STUB_BRANCH:-main}"
EOF
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"

# Portable "init with branch main" (git >= 2.5 per README; `git init -b` needs 2.28).
init_main() { git init -q "$1" && git -C "$1" symbolic-ref HEAD refs/heads/main; }
gitc() { git config user.email t@example.com; git config user.name t; git config commit.gpgsign false; }

# fixture NAME MODE MAIN_CONTRACT BRANCH_CONTRACT EXPECTED_EXIT EXPECTED_TEXT [OPTS...]
#   NAME            - test label
#   MODE            - check | changed | preflight | full | anything else (the block rejects it)
#   MAIN_CONTRACT   - content of .issue-runner/validation on the base branch at
#                     the fork point, or "-" for no contract at all
#   BRANCH_CONTRACT - content committed to the same path on the feature branch
#                     (the PR's own edit — inert for the run; MODE=changed reports it),
#                     or "-" for none
#   EXPECTED_EXIT   - the block's exit status
#   EXPECTED_TEXT   - a substring that must appear in stdout+stderr
#   OPTS            - any of:
#       base=<name>          what the stub gh reports as the base branch (default main)
#       ghfail=pr|prempty|all  make `gh pr view` fail, print nothing, or every gh call fail
#       advance=<contract>   after the fork, commit this contract to main and push it —
#                            the base tip then differs from the merge-base ("-" removes it)
#       worktree=<contract>  write this to the working tree uncommitted (an edit in
#                            progress — must be ignored)
#       cwd=<subdir>         run the block from this subdirectory of the worktree
#       delete=1             the feature branch deletes the contract (MODE=changed must report it)
#       nofetch=1            origin is unreachable when the block runs (the clone keeps a cached origin/main)
#       strict=1             run the block under an inherited `bash -e -o pipefail`
#       outside=1            run the block from a directory that is in no repository at all
#       corrupt=1            the contract's blob is missing from the clone's object store (the ref is intact)
#
# Builds a bare origin with `main`, a clone on a feature branch one commit
# ahead, and runs the block there — exactly the shape gh-issue Steps 3/5/8/9
# run it in.
fixture() {
  local name="$1" mode="$2" main_contract="$3" branch_contract="$4" expected_exit="$5" expected_text="$6"
  shift 6
  local base=main ghfail="" advance="" advance_set=0 worktree="" worktree_set=0 cwd="" delete=0 nofetch=0 strict=0 outside=0 corrupt=0 opt
  for opt in "$@"; do
    case $opt in
      base=*)     base="${opt#base=}" ;;
      ghfail=*)   ghfail="${opt#ghfail=}" ;;
      advance=*)  advance="${opt#advance=}"; advance_set=1 ;;
      worktree=*) worktree="${opt#worktree=}"; worktree_set=1 ;;
      cwd=*)      cwd="${opt#cwd=}" ;;
      delete=1)   delete=1 ;;
      nofetch=1)  nofetch=1 ;;
      strict=1)   strict=1 ;;
      outside=1)  outside=1 ;;
      corrupt=1)  corrupt=1 ;;
    esac
  done
  local run="$TMP/$(printf '%s' "$name" | tr -c 'A-Za-z0-9' '_')"
  rm -rf "$run"; mkdir -p "$run"
  git init -q --bare "$run/origin.git" && git -C "$run/origin.git" symbolic-ref HEAD refs/heads/main
  init_main "$run/wt"
  (
    set -e   # any setup failure is a fixture failure, never a silent pass
    cd "$run/wt"
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
    [ "$delete" -eq 1 ] && git rm -q .issue-runner/validation
    git commit -q -m change
    if [ "$advance_set" -eq 1 ]; then
      # main moves on after the fork: a clone elsewhere lands a new contract on origin.
      git clone -q --branch main "$run/origin.git" "$run/other" && cd "$run/other" && gitc
      if [ "$advance" = "-" ]; then git rm -q .issue-runner/validation; else
        mkdir -p .issue-runner; printf '%s\n' "$advance" > .issue-runner/validation; git add .issue-runner/validation
      fi
      git commit -q -m advance && git push -q origin main
      cd "$run/wt"
    fi
    if [ "$worktree_set" -eq 1 ]; then
      mkdir -p .issue-runner; printf '%s\n' "$worktree" > .issue-runner/validation
    fi
    if [ "$nofetch" -eq 1 ]; then
      git fetch -q origin main   # a cached origin/main exists, then the remote goes away
      git remote set-url origin "$run/gone.git"
    fi
    if [ "$corrupt" -eq 1 ]; then
      # The commit and tree stay; only the contract's blob goes (a loose object here —
      # `rm` without -f, so a packed one fails the setup loudly instead of passing).
      B=$(git rev-parse "origin/main:.issue-runner/validation"); rm ".git/objects/${B:0:2}/${B:2}"
    fi
  ) >"$run/setup.log" 2>&1 || { err "$name: fixture setup failed:"; cat "$run/setup.log" >&2; return; }

  local actual_exit from="$run/wt/$cwd"
  local -a shell=(bash); [ "$strict" -eq 1 ] && shell=(bash -e -o pipefail)
  if [ "$outside" -eq 1 ]; then
    # No repository here, and none discovered above it either: $TMP is a ceiling
    # for git's discovery, whatever TMPDIR is nested in.
    from="$run/nowhere"; mkdir -p "$from"; export GIT_CEILING_DIRECTORIES="$TMP"
  fi
  (cd "$from" && MODE="$mode" GH_STUB_BRANCH="$base" GH_STUB_FAIL="$ghfail" "${shell[@]}" "$TMP/block.sh") >"$run/out" 2>&1
  actual_exit=$?
  unset GIT_CEILING_DIRECTORIES
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
fixture "row 39: no PR yet — gh pr view fails, gh repo view resolves the base" preflight \
  'preflight: true' - 0 "validation: preflight passed" ghfail=pr
fixture "row 39: only a closed PR on the branch — gh pr view prints nothing, gh repo view resolves the base" preflight \
  'preflight: true' - 0 "validation: preflight passed" ghfail=prempty

# --- Row 40: contract absent → fallback, never an error ------------------------
fixture "row 40: no contract on the base branch" preflight \
  - - 0 "validation: fallback (no contract"
fixture "row 40: MODE=check on an absent contract is the same fallback" check \
  - - 0 "validation: fallback (no contract"

# --- Row 41: preflight failure ------------------------------------------------
fixture "row 41: preflight fails (exit 7 → 1)" preflight \
  'preflight: exit 7' - 1 "validation: preflight failed (exit 7): exit 7"
fixture "row 41: a command exiting 3 is a plain failure — it cannot forge the block's own exits" preflight \
  'preflight: exit 3' - 1 "validation: preflight failed (exit 3)"
fixture "row 41: a command exiting 2 is a plain failure too" preflight \
  'preflight: exit 2' - 1 "validation: preflight failed (exit 2)"

# --- Row 42: optional full validation -----------------------------------------
fixture "row 42: full declared and passes" full \
  $'preflight: true\nfull: true' - 0 "validation: full passed"
fixture "row 42: full declared and fails" full \
  $'preflight: true\nfull: exit 5' - 1 "validation: full failed (exit 5)"
fixture "row 42: full not declared → nothing to run" full \
  'preflight: true' - 0 "validation: full not declared"
fixture "row 42: MODE=check reports a declared full" check \
  $'preflight: true\nfull: true' - 0 "full declared)"
fixture "row 42: full not declared is exit 0 under an inherited -e/pipefail too" full \
  'preflight: true' - 0 "validation: full not declared" strict=1
fixture "row 42: full command not found (127 → 4)" full \
  $'preflight: true\nfull: ./no-such-script-42' - 4 "validation: full command not runnable (exit 127)"

# --- Row 43: invalid contract / command not runnable --------------------------
fixture "row 43: stray key line is invalid (exit 3)" preflight \
  $'preflight: true\nlint: true' - 3 "validation: invalid contract"
fixture "row 43: missing preflight is invalid (exit 3)" preflight \
  'full: true' - 3 "preflight lines=0"
fixture "row 43: duplicate preflight is invalid (exit 3)" preflight \
  $'preflight: true\npreflight: false' - 3 "preflight lines=2"
fixture "row 43: duplicate full is invalid (exit 3)" preflight \
  $'preflight: true\nfull: true\nfull: false' - 3 "full lines=2"
fixture "row 43: empty command is invalid (exit 3)" preflight \
  'preflight:' - 3 "validation: invalid contract"
fixture "row 43: CRLF line endings are invalid (exit 3)" preflight \
  $'preflight: true\r' - 3 "CRLF line endings"
fixture "row 43: invalid contract is judged before full runs too" full \
  $'full: true\nbogus' - 3 "validation: invalid contract"
fixture "row 43: MODE=check rejects an invalid contract (exit 3)" check \
  'bogus' - 3 "validation: invalid contract"
fixture "row 43: unknown MODE is rejected, never a silent pass (exit 6 — its own class, not the contract's)" ful \
  'preflight: true' - 6 "validation: unknown MODE 'ful'"
fixture "row 43: command not found (127 → 4)" preflight \
  'preflight: ./no-such-script-42' - 4 "validation: preflight command not runnable (exit 127)"
fixture "row 43: command not executable (126 → 4)" preflight \
  'preflight: ./README' - 4 "validation: preflight command not runnable (exit 126)"
fixture "row 43: base branch missing on origin (exit 2)" preflight \
  'preflight: true' - 2 "validation: cannot resolve the base branch" base=nope
fixture "row 43: MODE=check exits 2 too, never fallback" check \
  - - 2 "validation: cannot resolve the base branch" base=nope
fixture "row 43: every gh call fails → exit 2, never fallback" preflight \
  'preflight: true' - 2 "validation: cannot resolve the base branch: cannot fetch origin/?" ghfail=all
fixture "row 43: origin unreachable → exit 2, never the cached (possibly stale) origin/main" preflight \
  'preflight: true' - 2 "validation: cannot resolve the base branch: cannot fetch origin/main" nofetch=1
fixture "row 43: run outside any repository → exit 2 at the worktree-root guard (cd \"\" is a no-op in bash)" preflight \
  'preflight: true' - 2 "validation: cannot resolve the worktree root" outside=1
fixture "row 43: run from inside .git (no work tree there) → exit 2 at the guard, never a run in the wrong directory" preflight \
  'preflight: true' - 2 "validation: cannot resolve the worktree root" cwd=.git
fixture "row 43: contract blob missing from the object store → exit 2, never fallback (cat-file -e fails alike for absent and unreadable)" preflight \
  'preflight: true' - 2 "validation: cannot resolve the base branch: cannot read .issue-runner/validation from origin/main" corrupt=1

# --- Row 44: the base branch's copy runs; the PR's own edit is inert -----------
fixture "row 44: branch edit ignored, base copy runs (pass)" preflight \
  'preflight: true' 'preflight: exit 9' 0 "validation: preflight passed"
fixture "row 44: branch edit ignored, base copy runs (fail)" preflight \
  'preflight: exit 9' 'preflight: true' 1 "validation: preflight failed (exit 9)"
fixture "row 44: branch-added contract with none on base → fallback" preflight \
  - 'preflight: exit 9' 0 "validation: fallback (no contract"
fixture "row 44: uncommitted working-tree edit ignored" preflight \
  'preflight: true' - 0 "validation: preflight passed" 'worktree=preflight: exit 9'
fixture "row 44: base tip advanced after the fork — the tip's copy runs (a fix on the base takes effect)" preflight \
  'preflight: exit 9' - 0 "validation: preflight passed" 'advance=preflight: true'
fixture "row 44: contract added to base after the fork → it runs" preflight \
  - - 1 "validation: preflight failed (exit 9)" 'advance=preflight: exit 9'
fixture "row 44: contract removed from base after the fork → fallback" preflight \
  'preflight: exit 9' - 0 "validation: fallback (no contract" advance=-

# --- Row 44: MODE=changed — did this PR edit the contract? ---------------------
fixture "row 44: MODE=changed, untouched → unchanged (exit 0)" changed \
  'preflight: true' - 0 "validation: contract unchanged in this PR"
fixture "row 44: MODE=changed, branch edit → changed (exit 5, diff printed)" changed \
  'preflight: true' 'preflight: exit 9' 5 "+preflight: exit 9"
fixture "row 44: MODE=changed, branch adds a contract → changed (exit 5)" changed \
  - 'preflight: true' 5 "validation: contract changed in this PR"
fixture "row 44: MODE=changed, branch deletes the contract → changed (exit 5)" changed \
  'preflight: true' - 5 "validation: contract changed in this PR" delete=1
fixture "row 44: MODE=changed from a subdirectory still sees the edit (a pathspec is cwd-relative)" changed \
  'preflight: true' 'preflight: exit 9' 5 "validation: contract changed in this PR" cwd=sub
fixture "row 44: MODE=changed from a subdirectory still sees the deletion" changed \
  'preflight: true' - 5 "validation: contract changed in this PR" delete=1 cwd=sub
fixture "row 44: MODE=changed from a subdirectory, untouched → unchanged" changed \
  'preflight: true' - 0 "validation: contract unchanged in this PR" cwd=sub
fixture "row 44: MODE=changed ignores an uncommitted edit (HEAD is what merges)" changed \
  'preflight: true' - 0 "validation: contract unchanged in this PR" 'worktree=preflight: exit 9'
fixture "row 44: MODE=changed, a sibling's change on the base tip is not this PR's" changed \
  'preflight: true' - 0 "validation: contract unchanged in this PR" 'advance=preflight: exit 9'
fixture "row 44: MODE=changed, base missing → exit 2, never unchanged" changed \
  'preflight: true' 'preflight: exit 9' 2 "validation: cannot resolve the base branch" base=nope

if [ "$fail" -ne 0 ]; then
  printf '\ntest-validation-contract: FAILED\n' >&2
  exit 1
fi
printf '\ntest-validation-contract: OK\n'
