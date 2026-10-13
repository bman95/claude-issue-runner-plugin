#!/usr/bin/env bash
#
# Fixtures for gh-issue's "Risk gate" (merge.md) — the bundled script
# skills/gh-issue/scripts/risk-gate.sh, which decides whether a converged PR
# merges on the run's authority or stops at `awaiting-approval` for a human.
# Covers the built-in defaults, a project policy read from the base tip (never
# from the PR), the always-on `.issue-runner/` entry, directory and glob
# matching, and the fail-closed exit on an environment failure.
#
# Run directly, or from scripts/lint.sh (and so from CI). Dependency-free:
# bash + git + coreutils. Exits non-zero on the first-or-any failure.

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/skills/gh-issue/scripts/risk-gate.sh"

fail=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
unset XDG_CONFIG_HOME

ok()  { printf 'ok:   %s\n' "$1"; }
err() { printf 'FAIL: %s\n' "$1" >&2; fail=1; }

[ -f "$SCRIPT" ] || { err "risk-gate script not found: skills/gh-issue/scripts/risk-gate.sh"; exit 1; }
if bash -n "$SCRIPT" 2>"$TMP/parse.err"; then ok "risk-gate script parses (bash -n)"; else err "risk-gate script does not parse"; cat "$TMP/parse.err" >&2; fi

init_main() { git init -q "$1" && git -C "$1" symbolic-ref HEAD refs/heads/main; }
gitc() { git config user.email t@example.com; git config user.name t; git config commit.gpgsign false; }

# fixture NAME MAIN_POLICY BRANCH_FILES EXPECTED_EXIT EXPECTED_TEXT [BRANCH_POLICY]
#   MAIN_POLICY   - content of .issue-runner/risk on main, or "-" for none
#   BRANCH_FILES  - space-separated paths the feature branch adds
#   BRANCH_POLICY - optional: the PR's own edit of .issue-runner/risk
fixture() {
  name=$1; main_policy=$2; files=$3; want_exit=$4; want_text=$5; branch_policy=${6:--}
  d="$TMP/$(printf '%s' "$name" | tr -c 'a-zA-Z0-9' _)"
  init_main "$d.origin" >/dev/null
  ( cd "$d.origin" && gitc && echo seed > README.md && git add README.md \
    && if [ "$main_policy" != - ]; then mkdir -p .issue-runner && printf '%s' "$main_policy" > .issue-runner/risk && git add .issue-runner; fi \
    && git commit -qm seed ) || { err "$name: cannot build origin"; return; }
  git clone -q "$d.origin" "$d" 2>/dev/null || { err "$name: cannot clone"; return; }
  ( cd "$d" && gitc && git checkout -qb feature \
    && for f in $files; do mkdir -p "$(dirname "$f")"; echo x > "$f"; git add "$f"; done \
    && if [ "$branch_policy" != - ]; then mkdir -p .issue-runner && printf '%s' "$branch_policy" > .issue-runner/risk && git add .issue-runner; fi \
    && git commit -qm change ) || { err "$name: cannot build branch"; return; }
  out=$(cd "$d" && bash "$SCRIPT" main 2>&1); rc=$?
  if [ "$rc" -ne "$want_exit" ]; then err "$name: exit $rc, want $want_exit — $out"; return; fi
  case $out in *"$want_text"*) ok "$name" ;; *) err "$name: output lacks '$want_text' — $out" ;; esac
}

fixture "plain source change, defaults"        -  "src/app.ts"                  0 "risk: none"
fixture "auth dir, defaults"                   -  "src/auth/login.ts"           3 "risk: src/auth/login.ts"
fixture "nested migrations, defaults"          -  "db/migrations/0001.sql"      3 "risk: db/migrations/0001.sql"
fixture "workflow, defaults"                   -  ".github/workflows/ci.yml"    3 "risk: .github/workflows/ci.yml"
fixture "dotenv basename glob, defaults"       -  "config/.env.production"      3 "risk: config/.env.production"
fixture "dependency manifest, defaults"        -  "web/package.json"            3 "risk: web/package.json"
fixture "only risky paths are listed"          -  "src/a.ts auth/b.ts"          3 "risk: awaiting approval
risk: auth/b.ts"
fixture "project policy replaces defaults"     "# ours
payments/
"                                                 "src/auth/x.ts"               0 "risk: none"
fixture "project policy matches its own entry" "payments/
*.sql
"                                                 "billing/payments/charge.py"  3 "risk: billing/payments/charge.py"
fixture "project policy glob"                  "*.sql
"                                                 "db/seed.sql"                 3 "risk: db/seed.sql"
fixture "empty policy keeps the always-on entry" "# nothing
"                                                 "auth/x.ts"                   0 "risk: none"
fixture "PR editing the policy is risky"       "payments/
"                                                 "src/a.ts"                    3 "risk: .issue-runner/risk" "src/
"
fixture "PR cannot narrow the policy"          "src/
"                                                 "src/a.ts"                    3 "risk: src/a.ts" "# none
"
fixture "CRLF policy fails closed"             "auth/$(printf '\r')
"                                                 "src/a.ts"                    2 "CRLF"

# Environment failure: no origin to fetch → exit 2, never `none`.
d="$TMP/noorigin"; init_main "$d" >/dev/null
( cd "$d" && gitc && echo a > a && git add a && git commit -qm a )
out=$(cd "$d" && bash "$SCRIPT" main 2>&1); rc=$?
if [ "$rc" -eq 2 ]; then ok "no origin fails closed (exit 2)"; else err "no origin: exit $rc, want 2 — $out"; fi
out=$(cd "$d" && bash "$SCRIPT" "" 2>&1); rc=$?
if [ "$rc" -eq 2 ]; then ok "empty base argument refused (exit 2)"; else err "empty base: exit $rc, want 2 — $out"; fi

exit "$fail"
