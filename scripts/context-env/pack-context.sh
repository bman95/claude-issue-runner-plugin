#!/usr/bin/env bash
#
# Pack the issue-runner plugin's skills into ONE portable string that fits in a
# single environment variable. Decode + install it anywhere with
# bootstrap-context.sh — no marketplace, no clone, works on a brand-new project
# and on Claude Code on the web.
#
# The value is base64(gzip(tar)) of the plugin's `skills/` tree plus its
# `.claude-plugin/plugin.json` (for the version marker). base64 keeps it to a
# single line with no shell-hostile bytes, so it drops straight into a shell
# profile, a `.env` file, or the cloud environment's variables list.
#
# Usage:
#   scripts/context-env/pack-context.sh                 # print `export ISSUE_RUNNER_CONTEXT=...`
#   scripts/context-env/pack-context.sh --raw           # print only the value (no `export `)
#   scripts/context-env/pack-context.sh --file out.txt  # write only the value to a file
#   scripts/context-env/pack-context.sh --var MY_NAME   # use a different variable name
#
# Dependency-free: bash + coreutils + tar + gzip + base64 (all POSIX-standard).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VAR_NAME="${ISSUE_RUNNER_CONTEXT_VAR:-ISSUE_RUNNER_CONTEXT}"

emit_export=1   # 1 = print `export VAR=value`; 0 = print the bare value
out_file=""

usage() { sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//; /^set -euo/d'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --raw)  emit_export=0 ;;
    --file) out_file="${2:?--file needs a path}"; shift ;;
    --var)  VAR_NAME="${2:?--var needs a name}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

[ -d "$ROOT/skills" ] || { printf 'no skills/ under %s\n' "$ROOT" >&2; exit 1; }

# `base64 -w0` is GNU-only; `base64 | tr -d '\n'` is portable to BSD/macOS too.
value="$(tar -czf - -C "$ROOT" skills .claude-plugin/plugin.json | base64 | tr -d '\n')"

version="$(sed -nE 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' \
  "$ROOT/.claude-plugin/plugin.json" | head -1)"

# Human-facing summary goes to stderr so stdout stays a clean, pipeable value.
bytes="${#value}"
printf 'packed issue-runner %s -> %s (%s bytes)\n' "${version:-?}" "$VAR_NAME" "$bytes" >&2

if [ -n "$out_file" ]; then
  printf '%s' "$value" > "$out_file"
  printf 'wrote value to %s\n' "$out_file" >&2
  exit 0
fi

if [ "$emit_export" -eq 1 ]; then
  printf 'export %s=%s\n' "$VAR_NAME" "$value"
else
  printf '%s\n' "$value"
fi
