#!/usr/bin/env bash
#
# teardown.sh — delete a smoke repository created by setup.sh (README,
# "Release smoke test"), with its local clone, its .env and the run's state.
#
# Usage: scripts/smoke/teardown.sh <repo>   (<name> or <owner>/<name>; the owner
#                                           defaults to the authenticated gh user)
#
# Refuses any name that does not start with `issue-runner-smoke-`, and asks you
# to type the name back before deleting anything. Deleting a repository needs
# the gh token's `delete_repo` scope; when the token lacks it, the script says
# how to grant it (`gh auth refresh -h github.com -s delete_repo`) and deletes
# nothing. Local files are removed only after the repository is deleted.
#
# Needs: bash, git, gh (authenticated).

set -u

PREFIX=issue-runner-smoke-
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SMOKE_ROOT=${ISSUE_RUNNER_SMOKE_ROOT:-$HOME/issue-runner-smoke}
case $SMOKE_ROOT in /*) ;; *) SMOKE_ROOT="$PWD/$SMOKE_ROOT" ;; esac   # absolute: the .env records paths
RUN_STATE="$HERE/../../skills/issue-runner/scripts/run-state.sh"
SCOPE_HINT="grant it with: gh auth refresh -h github.com -s delete_repo"

die() { printf 'teardown: %s\n' "$1" >&2; exit 1; }

[ $# -eq 1 ] || die "usage: teardown.sh <repo>"
NAME=${1##*/}
case $NAME in "$PREFIX"?*) ;; *) die "refusing: '$1' does not start with $PREFIX" ;; esac
printf '%s\n' "$1" | grep -Eqx "([A-Za-z0-9-]+/)?${PREFIX}[A-Za-z0-9_-]+" \
  || die "refusing: '$1' is not a plain <owner>/<name> repository name"
command -v gh >/dev/null 2>&1 || die "gh not found"
case $1 in
  */*) REPO=$1 ;;
  *) OWNER=$(gh api user -q .login) && [ -n "$OWNER" ] || die "cannot resolve the authenticated gh user"
     REPO="$OWNER/$NAME" ;;
esac

CLONE="$SMOKE_ROOT/$NAME"
META="$SMOKE_ROOT/$NAME.env"
RUN_ROOT=""
if [ -d "$CLONE" ]; then
  RUN_ROOT=$( (cd "$CLONE" && bash "$RUN_STATE" resolve 2>/dev/null) | sed -n 's/^run-root //p')
  case ${RUN_ROOT##*/} in "$NAME"-*) ;; *) RUN_ROOT="" ;; esac   # only this clone's own run root
fi

# An absent repository (setup failed before creating it, or an earlier
# teardown deleted it) leaves only the local files; any other lookup failure stops.
REPO_EXISTS=1
PROBE_ERR=$(mktemp) || die "mktemp failed"
trap 'rm -f "$PROBE_ERR"' EXIT
if ! gh api "repos/$REPO" --silent 2>"$PROBE_ERR"; then
  grep -q 'HTTP 404' "$PROBE_ERR" || { cat "$PROBE_ERR" >&2; die "cannot check whether $REPO exists"; }
  REPO_EXISTS=0
fi

# Deleting the repository needs delete_repo. A classic token lists its scopes
# in X-OAuth-Scopes; a fine-grained token sends no such header, and the delete
# below reports its own refusal.
if [ "$REPO_EXISTS" -eq 1 ]; then
  SCOPES=$(gh api -i user 2>/dev/null | tr -d '\r' | sed -n 's/^[Xx]-[Oo][Aa]uth-[Ss]copes: *//p')
  if [ -n "$SCOPES" ] && ! printf '%s\n' "$SCOPES" | tr ',' '\n' | sed 's/^ *//' | grep -qx delete_repo; then
    die "the gh token lacks the delete_repo scope; $SCOPE_HINT"
  fi
fi

echo "This deletes:"
if [ "$REPO_EXISTS" -eq 1 ]; then echo "  https://github.com/$REPO (the GitHub repository, permanently)"
else echo "  (https://github.com/$REPO does not exist - local files only)"; fi
[ -e "$CLONE" ] && echo "  $CLONE (local clone)"
[ -e "$META" ] && echo "  $META"
[ -n "$RUN_ROOT" ] && [ -e "$RUN_ROOT" ] && echo "  $RUN_ROOT (the run's state)"
printf 'Type %s to confirm: ' "$NAME"
read -r reply || reply=""
[ "$reply" = "$NAME" ] || die "not confirmed - nothing deleted"

if [ "$REPO_EXISTS" -eq 1 ]; then
  gh repo delete "$REPO" --yes \
    || die "gh repo delete $REPO failed - local files kept. If the token lacks the delete_repo scope, $SCOPE_HINT"
fi
rm -rf "$CLONE" "$META"
[ -n "$RUN_ROOT" ] && rm -rf "$RUN_ROOT"
echo "deleted $NAME"
