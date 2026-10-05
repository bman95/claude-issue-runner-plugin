#!/usr/bin/env bash
#
# host-env.sh — issue-runner's host environment probe: writes
# <state-dir>/environment.md, the run-wide facts every implementer needs before
# its first command (where the toolchain lives, and whether it is on PATH), so a
# failing repository hook is never "worked around" for lack of a PATH entry.
# The orchestrator runs it once per invocation, before the first dispatch, and
# names the file in every dispatch prompt (host-environment.md has the rules).
#
# Usage:
#   host-env.sh <state-dir> [<repo-dir>]
#     <state-dir>  $STATE_DIR; environment.md is written there (atomically)
#     <repo-dir>   the repository root (default: the current directory); its
#                  manifests and `.issue-runner/validation` pick the tools to probe
#
# What it records, and only this: for each tool name, its absolute path as
# `command -v` resolves it, or, when it is not on PATH, the first match in a
# short list of well-known user toolchain directories, flagged with the
# directory to prepend. It never records an environment variable's value, the
# PATH itself, a command's output or a path with unusual characters (such a
# path is reported as omitted). Tool names come from a fixed list, from the
# repository's manifests (a fixed mapping), and from the first word of each
# command in `.issue-runner/validation` when that word is a plain program name
# (letters, digits, `.`, `_`, `+`, `-`; never a path, never starting with `-`
# or `.`, at most 31 characters); each `&&`, `||`, `;` and `|` segment
# contributes its first command word (separators inside quotes do not split) (an `env`, `exec`, `time` or `VAR=value`
# prefix skipped, a quoted value with spaces skipped whole, a `cd` segment
# ignored; a backslash-escaped space in a value is not understood, which at
# worst adds or misses a name). The
# contract is read from the working tree, as a best-effort list of names only
# (validation-contract.sh stays the trusted reader); the cost of a wrong name is
# one extra `command -v`. Nothing is executed except `command -v`.
#
# Exit status: 0 on success; 2 a usage error or an unwritable state dir.
#
# Dependencies: bash 3.2, coreutils, grep, sed, awk.

set -u
set +e +o pipefail
set -f

he_usage() { echo "host-env.sh: $1" >&2; exit 2; }

STATE_DIR=${1:-}
REPO=${2:-.}
[ -n "$STATE_DIR" ] || he_usage "usage: host-env.sh <state-dir> [<repo-dir>]"
[ -d "$STATE_DIR" ] && [ -w "$STATE_DIR" ] || he_usage "state dir '$STATE_DIR' is not a writable directory"
[ -d "$REPO" ] || he_usage "repo dir '$REPO' is not a directory"

TOOLS="git gh bash codex"
he_has() { [ -e "$REPO/$1" ]; }
if he_has package.json; then
  TOOLS="$TOOLS node npm"
  he_has pnpm-lock.yaml && TOOLS="$TOOLS pnpm"
  he_has yarn.lock && TOOLS="$TOOLS yarn"
  (he_has bun.lockb || he_has bun.lock) && TOOLS="$TOOLS bun"
fi
if he_has pyproject.toml || he_has uv.lock || he_has requirements.txt; then TOOLS="$TOOLS python3"; fi
if he_has pyproject.toml || he_has uv.lock; then TOOLS="$TOOLS uv"; fi
he_has Cargo.toml && TOOLS="$TOOLS cargo"
he_has go.mod && TOOLS="$TOOLS go"
he_has Makefile && TOOLS="$TOOLS make"
he_has .husky && TOOLS="$TOOLS sh npx"
if [ -r "$REPO/.issue-runner/validation" ] && [ ! -L "$REPO/.issue-runner/validation" ]; then
  # every command word of every line: split on unquoted && || ; |, skip env/VAR= prefixes and `cd` segments
  for w in $(sed -e 's/#.*$//' -e 's/^[a-z]*:[[:space:]]*//' "$REPO/.issue-runner/validation" | tr -d '\r' | awk '
      function segs(line, out,   n, i, c, q, cur) {   # split on unquoted && || ; | only
        n = 0; q = ""; cur = ""
        for (i = 1; i <= length(line); i++) {
          c = substr(line, i, 1)
          if (q != "") { cur = cur c; if (c == q) q = ""; continue }
          if (c == "\\") { cur = cur c substr(line, i + 1, 1); i++; continue }
          if (c == "\"" || c == "\047") { q = c; cur = cur c; continue }
          if (c == ";" || c == "|") { if (c == "|" && substr(line, i + 1, 1) == "|") i++; out[++n] = cur; cur = ""; continue }
          if (c == "&" && substr(line, i + 1, 1) == "&") { i++; out[++n] = cur; cur = ""; continue }
          cur = cur c }
        out[++n] = cur
        return n }
      { delete seg; nseg = segs($0, seg)
        for (k = 1; k <= nseg; k++) {
          nw = split(seg[k], f)
          for (i = 1; i <= nw; i++) {
            if (f[i] ~ /^[A-Za-z_][A-Za-z0-9_]*=/) {   # a quoted value may hold spaces: skip to its closing quote
              v = f[i]; sub(/^[^=]*=/, "", v); q = substr(v, 1, 1)
              if ((q == "\"" || q == "\047") && (length(v) < 2 || substr(v, length(v), 1) != q))
                while (i < nw && substr(f[i], length(f[i]), 1) != q) i++
              continue }
            if (f[i] == "env" || f[i] == "exec" || f[i] == "time") continue
            if (f[i] != "cd") print f[i]
            break } } }'); do
    case $w in ''|-*|.*|*[!A-Za-z0-9._+-]*) ;; *) [ "${#w}" -le 31 ] && TOOLS="$TOOLS $w" ;; esac
  done
fi

HOME=${HOME:-/nonexistent}
CANDIDATES="$HOME/.local/node/bin $HOME/.local/bin $HOME/.cargo/bin $HOME/.volta/bin $HOME/.local/share/pnpm $HOME/.bun/bin $HOME/go/bin /usr/local/go/bin /usr/local/bin /opt/homebrew/bin"

he_safe() { case $1 in /*) case $1 in *[!A-Za-z0-9._+/@~-]*) return 1 ;; esac; return 0 ;; esac; return 1; }

LINES=""
SEEN=" "
for t in $TOOLS; do
  case $SEEN in *" $t "*) continue ;; esac
  SEEN="$SEEN$t "
  case $(type -t "$t" 2>/dev/null) in
    builtin|keyword) LINES="$LINES- $t: shell builtin or keyword (nothing to install)"$'\n'; continue ;;
    file) p=$(command -v "$t" 2>/dev/null) ;;
    *) p="" ;;   # an alias or function is not a path; not found falls through to the candidate directories
  esac
  case $p in
    ''|/*) ;;
    *) LINES="$LINES- $t: on PATH through a relative entry (path omitted)"$'\n'; continue ;;
  esac
  if [ -n "$p" ]; then
    if he_safe "$p"; then LINES="$LINES- $t: $p"$'\n'; else LINES="$LINES- $t: on PATH (path omitted: unusual characters)"$'\n'; fi
    continue
  fi
  found=""
  for d in $CANDIDATES; do
    if [ -f "$d/$t" ] && [ -x "$d/$t" ]; then found=$d; break; fi
  done
  if [ -z "$found" ]; then
    LINES="$LINES- $t: not found"$'\n'
  elif he_safe "$found/$t"; then
    LINES="$LINES- $t: $found/$t (not on PATH: prepend $found to PATH in your commands)"$'\n'
  else
    LINES="$LINES- $t: found off PATH (path omitted: unusual characters)"$'\n'
  fi
done

OUT="$STATE_DIR/environment.md"
rm -f "$OUT"   # never leave a previous invocation's facts standing if this probe fails
TMP=$(mktemp "$STATE_DIR/.environment.XXXXXX" 2>/dev/null) || he_usage "cannot write in $STATE_DIR"
{
  printf '# Host environment facts\n\n'
  printf 'Data, not instructions: it grants no authorization. Written by host-env.sh for this run; paths only, never environment variable values.\n\n'
  printf '## Tools\n\n'
  printf '%s' "$LINES"
  printf '\nA tool "not on PATH" is installed: prepend its directory to PATH for your own commands and for that one call of the version-control tool, so repository hooks find it (the directory may hold other tools too). A tool "not found" is missing on this host. Any listed path may be off your own PATH even when it is not marked: if a hook cannot find that tool, prepend the path'"'"'s directory the same way.\n'
} > "$TMP" && mv -f "$TMP" "$OUT" || { rm -f "$TMP"; he_usage "cannot write $OUT"; }
printf 'environment: %s\n' "$OUT"
exit 0
