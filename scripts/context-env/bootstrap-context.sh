#!/usr/bin/env bash
#
# Install the issue-runner plugin's skills from the ISSUE_RUNNER_CONTEXT
# environment variable into a Claude Code skills directory, so /issue-runner,
# /issue-plan and /gh-issue work in ANY project — new or existing, local or on
# the web — with nothing checked into the repo and no marketplace install.
#
# The value is produced by pack-context.sh. This script is the decode+install
# half: it is idempotent (safe to run every session) and never aborts a session
# when the variable is unset (it just no-ops in --hook mode).
#
# Two ways to run it:
#   1. Manually, once per machine / environment:
#        scripts/context-env/bootstrap-context.sh
#   2. As a Claude Code SessionStart hook (see docs/portable-context.md); pass
#      --hook so it emits the SessionStart JSON with reloadSkills:true and stays
#      silent+successful when the variable is absent.
#
# Resolution order for the payload:
#   $ISSUE_RUNNER_CONTEXT           (the value itself), else
#   $ISSUE_RUNNER_CONTEXT_FILE      (a path to a file holding the value).
#
# Install target (first that applies):
#   --dest DIR, else $ISSUE_RUNNER_SKILLS_DIR, else $HOME/.claude/skills
# Installing into ~/.claude/skills exposes the skills as USER-LEVEL commands
# (/issue-runner, /issue-plan, /gh-issue) and satisfies issue-runner Step 0's
# own fallback lookup of gh-issue at $HOME/.claude/skills/gh-issue/SKILL.md.
#
# Dependency-free: bash + coreutils + tar + gzip + base64.
set -euo pipefail

VAR_NAME="${ISSUE_RUNNER_CONTEXT_VAR:-ISSUE_RUNNER_CONTEXT}"
DEST="${ISSUE_RUNNER_SKILLS_DIR:-$HOME/.claude/skills}"
hook_mode=0

usage() { sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//; /^set -euo/d'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --hook) hook_mode=1 ;;
    --dest) DEST="${2:?--dest needs a path}"; shift ;;
    --var)  VAR_NAME="${2:?--var needs a name}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

# SessionStart-hook JSON: a note for the model + a skills reload so the freshly
# written commands are picked up without restarting the session.
emit_hook_json() {
  ctx="$1"
  # Minimal, dependency-free JSON string escaping (backslash, quote, newline).
  esc="${ctx//\\/\\\\}"; esc="${esc//\"/\\\"}"; esc="${esc//$'\n'/\\n}"
  printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s","reloadSkills":true}}\n' "$esc"
}

# Never break a session: an unset variable in --hook mode is a clean no-op.
die() {
  if [ "$hook_mode" -eq 1 ]; then
    printf '{"hookSpecificOutput":{"hookEventName":"SessionStart"}}\n'
    exit 0
  fi
  printf 'bootstrap-context: %s\n' "$1" >&2
  exit 1
}

value="${!VAR_NAME:-}"
if [ -z "$value" ] && [ -n "${ISSUE_RUNNER_CONTEXT_FILE:-}" ] && [ -f "$ISSUE_RUNNER_CONTEXT_FILE" ]; then
  value="$(cat "$ISSUE_RUNNER_CONTEXT_FILE")"
fi
[ -n "$value" ] || die "\$$VAR_NAME is unset (and no \$ISSUE_RUNNER_CONTEXT_FILE); run pack-context.sh first"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

printf '%s' "$value" | base64 -d 2>/dev/null | tar -xzf - -C "$tmp" 2>/dev/null \
  || die "could not decode \$$VAR_NAME (corrupt or truncated value?)"
[ -d "$tmp/skills" ] || die "decoded payload has no skills/ tree"

mkdir -p "$DEST"
# Copy each skill directory's contents into DEST so DEST/<skill>/SKILL.md lands
# exactly where Claude Code (and issue-runner Step 0) look for them.
cp -R "$tmp"/skills/. "$DEST"/

version="?"
[ -f "$tmp/.claude-plugin/plugin.json" ] && version="$(sed -nE \
  's/.*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' \
  "$tmp/.claude-plugin/plugin.json" | head -1)"
installed="$(cd "$tmp/skills" && ls -d */ 2>/dev/null | tr -d '/' | tr '\n' ' ' | sed 's/ $//')"

note="issue-runner ${version} skills installed to ${DEST}: ${installed}. Available as /issue-runner, /issue-plan, /gh-issue."
if [ "$hook_mode" -eq 1 ]; then
  emit_hook_json "$note"
else
  printf '%s\n' "$note"
fi
