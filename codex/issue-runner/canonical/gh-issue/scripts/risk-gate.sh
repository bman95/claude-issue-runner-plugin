#!/usr/bin/env bash
#
# risk-gate.sh — gh-issue's "Risk gate" (merge.md): does this PR touch a path
# the project marks as needing a human's approval before merge?
#
# Usage: bash risk-gate.sh [<base-branch>]
#   run from anywhere inside the worktree (it cds to the worktree root itself)
#   <base-branch>  optional; skips the `gh` lookup. Default: the open PR's base
#                  branch (`gh pr view`), else the repository's default branch
#                  (`gh repo view`). Passed but empty → exit 2, never the default.
#
# Trust rule: the policy is read from the freshly fetched tip of
# `origin/<base>` (`.issue-runner/risk`), never from the working tree, so a PR
# can never narrow the policy that judges it. Absent → the built-in defaults
# below. The diff judged is HEAD against its merge-base with that tip.
#
# Grammar of `.issue-runner/risk`: `#` comment lines and blank lines, plus one
# pattern per line. A pattern ending in `/` matches every path under that
# directory at any depth (`migrations/` matches `db/migrations/0001.sql`); any
# other pattern is a shell glob matched against the full path and against its
# basename (`*.tf`, `Dockerfile`, `.env*`). A file with no pattern lines leaves
# only the always-on entry below. CRLF or a NUL byte make the file invalid.
# `.issue-runner/` is always risky, whatever the file says: a change to the
# repository's own run policy is a policy change.
#
# Output and exit status:
#   0  `risk: none` — no changed path matches
#   3  `risk: awaiting approval` then one `risk: <path>` line per matching path
#   2  `risk: cannot ...` — an environment failure (base, fetch, merge-base,
#      diff) or an invalid policy file; the caller treats it as risky
#      (fail closed), never as `none`
#
# Dependencies: bash 3.2, coreutils, grep, sed, git; gh unless <base-branch> is given.

set +e +o pipefail
# shellcheck disable=SC2015   # A && B || C is intended: the error branch must run when any link fails
TOP=$(git rev-parse --show-toplevel 2>/dev/null) && [ -n "$TOP" ] && cd "$TOP" || { echo "risk: cannot resolve the worktree root" >&2; exit 2; }
POLICY_PATH=.issue-runner/risk
DEFAULTS='auth/
security/
.env*
*secret*
*credential*
migrations/
migrate/
.github/workflows/
Dockerfile
docker-compose*.yml
*.tf
k8s/
helm/
package.json
package-lock.json
pnpm-lock.yaml
yarn.lock
requirements*.txt
pyproject.toml
poetry.lock
go.mod
go.sum
Cargo.toml
Cargo.lock
Gemfile
Gemfile.lock
*.csproj'
if [ $# -ge 1 ] && [ -z "$1" ]; then
  echo "risk: cannot resolve the base branch: empty base argument" >&2; exit 2
fi
BASE_BRANCH=${1:-}
if [ -z "$BASE_BRANCH" ]; then
  BASE_BRANCH=$(gh pr view --json baseRefName,state -q 'select(.state=="OPEN") | .baseRefName' 2>/dev/null) && [ -n "$BASE_BRANCH" ] \
    || BASE_BRANCH=$(gh repo view --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null)
fi
[ -n "$BASE_BRANCH" ] || { echo "risk: cannot resolve the base branch" >&2; exit 2; }
FETCHED=0; for i in 1 2 3; do git fetch -q origin "+refs/heads/$BASE_BRANCH:refs/remotes/origin/$BASE_BRANCH" 2>/dev/null && { FETCHED=1; break; }; [ "$i" -lt 3 ] && sleep 1; done
[ "$FETCHED" -eq 1 ] || { echo "risk: cannot fetch origin/$BASE_BRANCH" >&2; exit 2; }
REF=$(git rev-parse -q --verify "refs/remotes/origin/$BASE_BRANCH^{commit}" 2>/dev/null) && [ -n "$REF" ] \
  || { echo "risk: cannot resolve origin/$BASE_BRANCH" >&2; exit 2; }
ENTRY=$(git ls-tree --full-tree "$REF" -- "$POLICY_PATH" 2>/dev/null) || { echo "risk: cannot read the tree of origin/$BASE_BRANCH" >&2; exit 2; }
if [ -z "$ENTRY" ]; then
  PATTERNS=$DEFAULTS
else
  if [ "$(git show "$REF:$POLICY_PATH" | tr -d '\000' | wc -c)" -ne "$(git show "$REF:$POLICY_PATH" | wc -c)" ]; then
    echo "risk: invalid policy ($POLICY_PATH on $BASE_BRANCH): NUL byte" >&2; exit 2
  fi
  RAW=$(git show "$REF:$POLICY_PATH") || { echo "risk: cannot read $POLICY_PATH from origin/$BASE_BRANCH" >&2; exit 2; }
  if printf '%s\n' "$RAW" | grep -q $'\r'; then
    echo "risk: invalid policy ($POLICY_PATH on $BASE_BRANCH): CRLF line endings" >&2; exit 2
  fi
  PATTERNS=$(printf '%s\n' "$RAW" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | grep -vE '^(#|$)')
fi
PATTERNS=$(printf '%s\n.issue-runner/\n' "$PATTERNS")   # always on
MB=$(git merge-base HEAD "$REF" 2>/dev/null) && [ -n "$MB" ] || { echo "risk: cannot resolve the merge-base with origin/$BASE_BRANCH" >&2; exit 2; }
FILES=$(git diff --name-only "$MB" HEAD 2>/dev/null); RC=$?
[ "$RC" -eq 0 ] || { echo "risk: cannot diff HEAD against $MB (git exit $RC)" >&2; exit 2; }

HITS=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  base=${f##*/}
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    hit=0
    case $p in
      */) d=${p%/}
          case "/$f" in */"$d"/*) hit=1 ;; esac ;;
      *)  # shellcheck disable=SC2254   # $p is a glob on purpose
          case $f in $p) hit=1 ;; esac
          # shellcheck disable=SC2254
          case $base in $p) hit=1 ;; esac ;;
    esac
    if [ "$hit" -eq 1 ]; then HITS="$HITS$f"$'\n'; break; fi
  done <<EOF
$PATTERNS
EOF
done <<EOF
$FILES
EOF

if [ -z "$HITS" ]; then echo "risk: none"; exit 0; fi
echo "risk: awaiting approval"
printf '%s' "$HITS" | sed 's/^/risk: /'
exit 3
