#!/usr/bin/env bash
#
# Fixtures for scripts/host-env.sh: issue-runner's host environment probe
# (Step 3a, host-environment.md). Tools on PATH, off PATH in a well-known
# toolchain directory, and missing; the tool list from the repository's
# manifests and validation contract; and what the file must never carry
# (environment variable values, the PATH string, unusual paths).
#
# Run directly, or from scripts/lint.sh (and so from CI). Dependency-free:
# bash + coreutils. Usage: test-host-env.sh [<path to host-env.sh>]

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="${1:-$ROOT/skills/issue-runner/scripts/host-env.sh}"

fail=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ok()  { printf 'ok:   %s\n' "$1"; }
err() { printf 'FAIL: %s\n' "$1" >&2; fail=1; }

[ -f "$SCRIPT" ] || { err "host-env.sh not found: $SCRIPT"; exit 1; }

mk() { mkdir -p "$(dirname "$1")"; printf '#!/bin/sh\nexit 0\n' > "$1"; chmod +x "$1"; }

# A PATH of one fixture bin plus the system directories; HOME is a fixture, so
# the well-known toolchain directories are the fixture's own.
export HOME="$TMP/home"
mkdir -p "$HOME" "$TMP/bin" "$TMP/state" "$TMP/repo/.issue-runner"
for t in git gh bash; do mk "$TMP/bin/$t"; done
BASE_PATH="$TMP/bin:/usr/bin:/bin"
mk "$HOME/.local/node/bin/pnpm"; mk "$HOME/.local/node/bin/node"
printf '{}\n' > "$TMP/repo/package.json"; : > "$TMP/repo/pnpm-lock.yaml"
printf '# contract\npreflight: ./scripts/pre.sh\nfull: lintthing --all   # trailing comment\n' > "$TMP/repo/.issue-runner/validation"
mk "$TMP/bin/lintthing"
OUT="$TMP/state/environment.md"

run() { PATH="$BASE_PATH" SECRET_TOKEN="s3cr3t-value-123" "$BASH" "$SCRIPT" "$@" >"$TMP/stdout" 2>"$TMP/stderr"; RC=$?; }
has()   { grep -qF -- "$2" "$OUT" && ok "$1" || { err "$1: environment.md lacks '$2'"; sed 's/^/  > /' "$OUT" >&2; }; }
hasnt() { grep -qF -- "$2" "$OUT" && { err "$1: environment.md has '$2'"; sed 's/^/  > /' "$OUT" >&2; } || ok "$1"; }

run "$TMP/state" "$TMP/repo"
[ "$RC" -eq 0 ] && ok "exit 0" || err "exit $RC: $(cat "$TMP/stderr")"
grep -qF "environment: $OUT" "$TMP/stdout" && ok "prints the file it wrote" || err "stdout: $(cat "$TMP/stdout")"
has "tool on PATH: its absolute path" "- git: $TMP/bin/git"
has "tool off PATH: path and the directory to prepend" "- pnpm: $HOME/.local/node/bin/pnpm (not on PATH: prepend $HOME/.local/node/bin to PATH"
has "node off PATH too" "- node: $HOME/.local/node/bin/node (not on PATH"
has "missing tool is reported" "- codex: not found"
has "validation contract's command word is probed" "- lintthing: $TMP/bin/lintthing"
hasnt "a script path in the contract is not a tool" "pre.sh"
hasnt "a comment in the contract is not a tool" "trailing"
hasnt "no environment variable value" "s3cr3t-value-123"
hasnt "no PATH string" "$BASE_PATH"
leftover=$(ls -A "$TMP/state" | grep -c '^\.environment\.')
[ "$leftover" -eq 0 ] && ok "no temporary file left" || err "temporary file left behind"

# Manifests choose the tools: no package.json, no node/pnpm.
mkdir -p "$TMP/repo2/.issue-runner"
run "$TMP/state" "$TMP/repo2"
hasnt "no package.json: node is not probed" "- node:"
hasnt "no lockfile: pnpm is not probed" "- pnpm:"

# An unusual path is omitted, never printed.
mkdir -p "$TMP/odd bin"; mk "$TMP/odd bin/oddtool"
printf 'preflight: oddtool x\n' > "$TMP/repo2/.issue-runner/validation"
PATH="$TMP/odd bin:$BASE_PATH" "$BASH" "$SCRIPT" "$TMP/state" "$TMP/repo2" >/dev/null 2>&1
has "a path with a space is reported as omitted" "- oddtool: on PATH (path omitted: unusual characters)"
hasnt "the unusual path is not printed" "odd bin"

# A word that is not a plain program name is never probed.
printf 'preflight: -x\nfull: $(evil) y\n' > "$TMP/repo2/.issue-runner/validation"
run "$TMP/state" "$TMP/repo2"
hasnt "a command substitution is not probed" "evil"

# Usage errors.
run;                          [ "$RC" -eq 2 ] && ok "no arguments -> exit 2" || err "no arguments: exit $RC"
run "$TMP/nope";              [ "$RC" -eq 2 ] && ok "missing state dir -> exit 2" || err "missing state dir: exit $RC"
run "$TMP/state" "$TMP/nope"; [ "$RC" -eq 2 ] && ok "missing repo dir -> exit 2" || err "missing repo dir: exit $RC"

if [ "$fail" -ne 0 ]; then
  printf '\ntest-host-env: FAILED\n' >&2
  exit 1
fi
printf '\ntest-host-env: OK\n'
