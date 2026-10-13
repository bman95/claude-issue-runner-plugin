#!/usr/bin/env bash
#
# setup.sh — the release smoke test's first half (README, "Release smoke test").
#
# Creates a throwaway PRIVATE repository `issue-runner-smoke-<UTC timestamp>`
# under the authenticated gh user from the fixture beside this script (a tiny
# bash project whose .issue-runner/validation runs in well under a second),
# seeds it with a tracking issue and three /issue-plan-format slices:
#
#   independent  None - can start immediately
#   dependent    ## Blocked by the independent one
#   conflict     no Blocked by, but its Files likely touched: overlaps the
#                independent one's (a conflict edge the runner serializes)
#
# and prints the /issue-runner --no-merge command to run by hand in a Claude
# Code session in the local clone, then the check and teardown commands.
# Manual only: lint parses this script and never runs it.
#
# Usage: scripts/smoke/setup.sh [--autonomy]
#
# --autonomy adds two issues for the daily-autonomy check (check-autonomy.sh):
#   risky       touches migrations/, so the risk gate must stop it at
#               awaiting-approval instead of merging it
#   human       labeled human-only, so the runner must never dispatch it, even
#               when named explicitly
# and prints an --unattended run (merges on) instead of the --no-merge one.
#
# The local clone goes to $ISSUE_RUNNER_SMOKE_ROOT/<name> (default
# ~/issue-runner-smoke/<name>), with the repository (written first) and the
# issue numbers (written last) in <name>.env beside it
# (outside the clone, so the run sees a clean tree); check.sh reads both, and
# teardown.sh deletes both. Refuses if the repository, the clone or the .env already exists.
#
# Needs: bash, git, gh (authenticated, allowed to create repositories).

set -u

PREFIX=issue-runner-smoke-
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SMOKE_ROOT=${ISSUE_RUNNER_SMOKE_ROOT:-$HOME/issue-runner-smoke}
case $SMOKE_ROOT in /*) ;; *) SMOKE_ROOT="$PWD/$SMOKE_ROOT" ;; esac   # absolute: the .env records paths
# The printed commands carry an overridden root, resolved: a relative one would
# otherwise resolve against wherever they are run.
ROOT_ENV=""
[ -n "${ISSUE_RUNNER_SMOKE_ROOT:-}" ] && ROOT_ENV="ISSUE_RUNNER_SMOKE_ROOT=\"$SMOKE_ROOT\" "

die() { printf 'setup: %s\n' "$1" >&2; exit 1; }

AUTONOMY=0
case ${1:-} in "") ;; --autonomy) AUTONOMY=1 ;; *) die "usage: setup.sh [--autonomy]" ;; esac
[ $# -le 1 ] || die "usage: setup.sh [--autonomy]"
command -v git >/dev/null 2>&1 || die "git not found"
command -v gh >/dev/null 2>&1 || die "gh not found"
[ -d "$HERE/fixture" ] || die "fixture not found at $HERE/fixture"
gh auth status >/dev/null 2>&1 || die "gh is not authenticated: run 'gh auth login'"
OWNER=$(gh api user -q .login) && [ -n "$OWNER" ] || die "cannot resolve the authenticated gh user"

NAME="$PREFIX$(date -u +%Y%m%d-%H%M%S)"
REPO="$OWNER/$NAME"
CLONE="$SMOKE_ROOT/$NAME"
META="$SMOKE_ROOT/$NAME.env"

TMP=$(mktemp -d) || die "mktemp failed"
trap 'rm -rf "$TMP"' EXIT
BODY="$TMP/body.md"

# Refuse an existing repository; any other lookup failure is not "absent".
if gh api "repos/$REPO" --silent 2>"$TMP/probe.err"; then
  die "repository $REPO already exists - refusing"
fi
grep -q 'HTTP 404' "$TMP/probe.err" || { cat "$TMP/probe.err" >&2; die "cannot check whether $REPO exists"; }
[ -e "$CLONE" ] && die "$CLONE already exists - refusing"
[ -e "$META" ] && die "$META already exists - refusing"

# From here on a failure can leave the clone and, once created, the repository
# (a failed push, say) behind: say how to remove them.
die() { printf 'setup: %s\nsetup: remove what was created with: %s"%s/teardown.sh" %s\n' "$1" "$ROOT_ENV" "$HERE" "$NAME" >&2; exit 1; }

# Record the repository before creating anything: teardown.sh takes its owner
# from here, never from whatever gh login is current by then.
{ mkdir -p "$SMOKE_ROOT" && printf 'repo=%s\nclone=%s\n' "$REPO" "$CLONE" >"$META"; } \
  || die "cannot write $META"

# The fixture, committed on main and pushed to a new private repository.
mkdir -p "$CLONE" || die "cannot create $CLONE"
cp -R "$HERE/fixture/." "$CLONE/" || die "cannot copy the fixture into $CLONE"
git -C "$CLONE" init -q || die "git init failed in $CLONE"
git -C "$CLONE" symbolic-ref HEAD refs/heads/main || die "cannot name the branch main in $CLONE"
{ git -C "$CLONE" add -A && git -C "$CLONE" commit -q -m "Smoke fixture"; } \
  || die "cannot commit the fixture (is git user.name/user.email set?)"
gh repo create "$REPO" --private --source "$CLONE" --remote origin --push >/dev/null \
  || die "gh repo create $REPO failed"
git -C "$CLONE" remote set-head origin -a >/dev/null 2>&1 || true   # origin/HEAD, the runner's default-branch lookup

# Create an issue from a body file; print its number.
new_issue() {  # <title> <body-file>
  local url
  url=$(gh issue create --repo "$REPO" --title "$1" --body-file "$2") || return 1
  printf '%s\n' "${url##*/}"
}

cat >"$BODY" <<'EOF'
## Input

Smoke test fixture created by issue-runner's `scripts/smoke/setup.sh`.

## Decisions

- No interview needed - input was clear.

## Slices

(published below)
EOF
TRACKING=$(new_issue "Plan: smoke fixture greetings" "$BODY") || die "cannot create the tracking issue"

cat >"$BODY" <<EOF
Part of #$TRACKING

## What to build

Add a \`farewell NAME\` function to \`greet.sh\` that prints \`Goodbye, NAME!\`.

## Acceptance criteria

- [ ] \`farewell World\` prints \`Goodbye, World!\`
- [ ] \`tests/test-greet.sh\` covers it, and \`bash test.sh\` passes

## Blocked by

None - can start immediately

Files likely touched: \`greet.sh\`, \`tests/test-greet.sh\`
EOF
INDEPENDENT=$(new_issue "Add a farewell function" "$BODY") || die "cannot create the independent issue"

cat >"$BODY" <<EOF
Part of #$TRACKING

## What to build

Add a \`hello.sh\` command: \`bash hello.sh NAME\` prints \`greet NAME\` and then \`farewell NAME\` (from \`greet.sh\`), one per line.

## Acceptance criteria

- [ ] \`bash hello.sh World\` prints \`Hello, World!\` then \`Goodbye, World!\`
- [ ] \`tests/test-hello.sh\` covers it, and \`bash test.sh\` passes

## Blocked by

- #$INDEPENDENT

Files likely touched: \`hello.sh\`, \`tests/test-hello.sh\`
EOF
DEPENDENT=$(new_issue "Add a hello command" "$BODY") || die "cannot create the dependent issue"

cat >"$BODY" <<EOF
Part of #$TRACKING

## What to build

Add a \`shout NAME\` function to \`greet.sh\` that prints the greeting in upper case: \`HELLO, NAME!\`.

## Acceptance criteria

- [ ] \`shout World\` prints \`HELLO, WORLD!\`
- [ ] \`tests/test-greet.sh\` covers it, and \`bash test.sh\` passes

## Blocked by

None - can start immediately

Files likely touched: \`greet.sh\`, \`tests/test-greet.sh\`
EOF
CONFLICT=$(new_issue "Add a shout function" "$BODY") || die "cannot create the conflicting issue"

RISKY="" HUMAN=""
if [ "$AUTONOMY" -eq 1 ]; then
  cat >"$BODY" <<EOF
Part of #$TRACKING

## What to build

Add a first database migration, \`migrations/0001_greetings.sql\`, that creates a \`greetings\` table with columns \`id INTEGER PRIMARY KEY\` and \`text TEXT NOT NULL\`.

## Acceptance criteria

- [ ] \`migrations/0001_greetings.sql\` creates the \`greetings\` table with those two columns
- [ ] \`tests/test-migration.sh\` checks that the file contains \`CREATE TABLE greetings\`, and \`bash test.sh\` passes

## Blocked by

None - can start immediately

Files likely touched: \`migrations/0001_greetings.sql\`, \`tests/test-migration.sh\`
EOF
  RISKY=$(new_issue "Add the greetings migration" "$BODY") || die "cannot create the risky issue"

  cat >"$BODY" <<EOF
Part of #$TRACKING

## What to build

Install the greeting font on the demo kiosk. A person with access to the kiosk does this; there is no code change.

## Acceptance criteria

- [ ] The kiosk shows the greeting in the new font

## Blocked by

None - can start immediately

Files likely touched: \`README.md\`
EOF
  gh label create human-only --repo "$REPO" --color D93F0B --description "issue-runner: a person must do this" >/dev/null 2>&1 || true
  HUMAN=$(new_issue "Human: install the greeting font on the demo kiosk" "$BODY") || die "cannot create the human-only issue"
  gh issue edit "$HUMAN" --repo "$REPO" --add-label human-only >/dev/null || die "cannot label #$HUMAN human-only"
fi

cat >"$BODY" <<EOF
## Input

Smoke test fixture created by issue-runner's \`scripts/smoke/setup.sh\`.

## Decisions

- No interview needed - input was clear.

## Slices

- #$INDEPENDENT - Add a farewell function
- #$DEPENDENT - Add a hello command (blocked by #$INDEPENDENT)
- #$CONFLICT - Add a shout function (shares files with #$INDEPENDENT)
EOF
[ -n "$RISKY" ] && printf -- '- #%s - Add the greetings migration (risk gate)\n- #%s - Human: install the greeting font (human-only)\n' "$RISKY" "$HUMAN" >>"$BODY"
gh issue edit "$TRACKING" --repo "$REPO" --body-file "$BODY" >/dev/null || die "cannot update the tracking issue"

printf 'tracking=%s\nindependent=%s\ndependent=%s\nconflict=%s\nrisky=%s\nhuman=%s\n' \
  "$TRACKING" "$INDEPENDENT" "$DEPENDENT" "$CONFLICT" "$RISKY" "$HUMAN" >>"$META" \
  || die "cannot write $META"

if [ "$AUTONOMY" -eq 1 ]; then
  cat <<EOF
Smoke repository ready (autonomy): https://github.com/$REPO (private)
  tracking #$TRACKING; independent #$INDEPENDENT; dependent #$DEPENDENT; conflict #$CONFLICT;
  risky #$RISKY (migrations/: must stop at awaiting-approval); human #$HUMAN (human-only: never dispatched)

1. Run, in the clone, with the plugin from this checkout:
     cd "$CLONE" && claude --plugin-dir "$(cd "$HERE/../.." && pwd)"
     /issue-runner:issue-runner --unattended $INDEPENDENT $DEPENDENT $CONFLICT $RISKY $HUMAN

2. When the run has finished:
     $ROOT_ENV"$HERE/check-autonomy.sh" $NAME

3. Delete the repository and the local clone:
     $ROOT_ENV"$HERE/teardown.sh" $NAME
EOF
  exit 0
fi

cat <<EOF
Smoke repository ready: https://github.com/$REPO (private)
  tracking #$TRACKING; independent #$INDEPENDENT; dependent #$DEPENDENT (blocked by #$INDEPENDENT); conflict #$CONFLICT (shares files with #$INDEPENDENT)

1. Run, in a Claude Code session started in the clone, with the plugin installed
   from this checkout ("$(cd "$HERE/../.." && pwd)"; README "Local development"),
   not a marketplace release:
     cd "$CLONE" && claude
     /issue-runner:issue-runner --no-merge $INDEPENDENT $DEPENDENT $CONFLICT
   (/issue-runner --no-merge ... with the unnamespaced skills of docs/portable-context.md)

2. When the run has finished, and before merging anything, check the outcome:
     $ROOT_ENV"$HERE/check.sh" $NAME

3. Delete the repository and the local clone:
     $ROOT_ENV"$HERE/teardown.sh" $NAME
EOF
