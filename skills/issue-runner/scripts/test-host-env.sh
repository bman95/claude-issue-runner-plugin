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
printf '# contract\npreflight: ./scripts/pre.sh\nfull: lintthing --all   # trailing comment\nextra: nonexistent-tool-xyz\n' > "$TMP/repo/.issue-runner/validation"
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
has "missing tool is reported" "- nonexistent-tool-xyz: not found"
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

# Wrapped commands: every segment's first word, env/VAR= prefixes and cd skipped.
printf 'preflight: cd web && CI=1 pnpm lint | tee out; env FOO=1 wrapped-tool x\n' > "$TMP/repo2/.issue-runner/validation"
run "$TMP/state" "$TMP/repo2"
has "wrapped command: the tool after cd and a VAR= prefix" "- pnpm:"
has "wrapped command: the piped tool" "- tee:"
has "wrapped command: the tool after env" "- wrapped-tool:"
hasnt "wrapped command: cd itself is not probed" "- cd:"

# A shell builtin is not a missing tool; a glob in the contract is never expanded.
: > "$TMP/repo2/canary"
printf 'preflight: test -f x && * \n' > "$TMP/repo2/.issue-runner/validation"
run "$TMP/state" "$TMP/repo2"
has "a builtin is reported as such, not as not found" "- test: shell builtin or keyword"
hasnt "a glob in the contract is not expanded against the repo" "canary"

# A tool found through a relative PATH entry is neither a builtin nor a printed path.
mkdir -p "$TMP/rel"; mk "$TMP/rel/reltool"
printf 'preflight: reltool x\n' > "$TMP/repo2/.issue-runner/validation"
( cd "$TMP" && PATH="rel:$BASE_PATH" "$BASH" "$SCRIPT" "$TMP/state" "$TMP/repo2" >/dev/null 2>&1 )
has "a relative PATH entry is reported, not as a builtin" "- reltool: on PATH through a relative entry (path omitted)"

# Other manifests map to their tools.
mkdir -p "$TMP/repo3/.husky"; : > "$TMP/repo3/Cargo.toml"; : > "$TMP/repo3/uv.lock"; : > "$TMP/repo3/go.mod"; : > "$TMP/repo3/Makefile"; : > "$TMP/repo3/yarn.lock"; printf '{}\n' > "$TMP/repo3/package.json"
run "$TMP/state" "$TMP/repo3"
for t in cargo uv go make yarn sh python3; do has "manifest maps to $t" "- $t:"; done

# An unwritable state dir is the documented exit 2.
if [ "$(id -u)" -ne 0 ]; then   # root writes anywhere
  mkdir -p "$TMP/ro"; chmod a-w "$TMP/ro"
  run "$TMP/ro" "$TMP/repo2"; [ "$RC" -eq 2 ] && ok "unwritable state dir -> exit 2" || err "unwritable state dir: exit $RC"
  chmod u+w "$TMP/ro"
fi

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

# A quoted VAR="a b" value is skipped whole, never probed word by word; names are capped at 31 characters.
long31=$(printf 'a%.0s' $(seq 1 31)); long32=${long31}a
printf 'preflight: API_KEY="s3cr3t pass word" qtool && time timed-tool && exec exec-tool && %s && %s\n' "$long31" "$long32" > "$TMP/repo2/.issue-runner/validation"
run "$TMP/state" "$TMP/repo2"
has "a quoted assignment value is skipped: the tool after it is probed" "- qtool:"
hasnt "a word inside a quoted value is not probed" "- pass:"
has "time and exec prefixes are skipped" "- timed-tool:"
has "exec prefix skipped" "- exec-tool:"
has "a 31-character name is probed" "- $long31:"
hasnt "a 32-character name is skipped" "- $long32:"

# Separators inside a quoted value neither split the segment nor leak its contents.
printf 'preflight: TOKEN="prefix; secretpart ;suffix" pnpm lint && FOO='"'"'a && leakb | c'"'"' sepool x\n' > "$TMP/repo2/.issue-runner/validation"
run "$TMP/state" "$TMP/repo2"
has "a quoted separator does not hide the tool after the assignment" "- pnpm:"
has "a single-quoted separator does not hide the tool either" "- sepool:"
hasnt "a word after a quoted separator is not probed" "secretpart"
hasnt "a word after a quoted && is not probed" "leakb"

# Escapes: an escaped quote inside a double-quoted value, an escaped space outside quotes.
printf 'preflight: TOKEN="prefix\\"; secretvalue ;suffix" pnpm lint && ESC=tok\\ en etool && escword\\ part x\n' > "$TMP/repo2/.issue-runner/validation"
run "$TMP/state" "$TMP/repo2"
has "an escaped quote does not close the value: the tool after it is probed" "- pnpm:"
has "an escaped space keeps the assignment whole" "- etool:"
hasnt "a fragment after an escaped quote is not probed" "secretvalue"
hasnt "a fragment after an escaped space is not probed" "- en:"
hasnt "an escaped-space command word is not split into a tool name" "- part:"

# Each well-known toolchain directory is searched (a fixture tool in each).
n=0; names=""
for d in .local/bin .cargo/bin .volta/bin .local/share/pnpm .bun/bin go/bin; do n=$((n + 1)); mk "$HOME/$d/candtool$n"; names="$names candtool$n"; done
printf 'preflight: %s\n' "$(printf '%s && ' $names | sed 's/ && $//')" > "$TMP/repo2/.issue-runner/validation"
run "$TMP/state" "$TMP/repo2"
n=0; for d in .local/bin .cargo/bin .volta/bin .local/share/pnpm .bun/bin go/bin; do n=$((n + 1)); has "candidate directory $d" "- candtool$n: $HOME/$d/candtool$n (not on PATH"; done
has "the footer says any listed path may be off the implementer's PATH" "Any listed path may be off your own PATH"

# A rerun never leaves an earlier invocation's content standing.
printf 'stale-marker\n' > "$OUT"
run "$TMP/state" "$TMP/repo2"
hasnt "a stale environment.md is replaced" "stale-marker"

# Usage errors.
run;                          [ "$RC" -eq 2 ] && ok "no arguments -> exit 2" || err "no arguments: exit $RC"
run "$TMP/nope";              [ "$RC" -eq 2 ] && ok "missing state dir -> exit 2" || err "missing state dir: exit $RC"
run "$TMP/state" "$TMP/nope"; [ "$RC" -eq 2 ] && ok "missing repo dir -> exit 2" || err "missing repo dir: exit $RC"

if [ "$fail" -ne 0 ]; then
  printf '\ntest-host-env: FAILED\n' >&2
  exit 1
fi
printf '\ntest-host-env: OK\n'
