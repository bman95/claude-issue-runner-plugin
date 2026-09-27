#!/usr/bin/env bash
#
# plan-file.sh — issue-runner Step 2's plan-file drift check. /issue-plan keeps
# a machine-readable plan file on the tracking issue (issue-plan Step 5): a
# fenced block with the info string `issue-runner-plan`, directly under the
# tracking body's own `## Plan file` heading, holding versioned JSON:
#
#   {"version":1,"issues":[{"n":123,"blocked_by":[122],"files":["src/a.ts","src/api/"]}]}
#
# The plan file is NOT authoritative: the issue bodies stay the runner's source
# of truth for `## Blocked by` and `Files likely touched:`. This script only
# compares the two and reports where they differ (an issue edited by hand after
# planning, a dependency added or removed, a file list changed). It never
# writes state, and nothing it prints changes the DAG. Rationale: REFERENCE.md,
# "Why the plan file is not authoritative".
#
# Usage: plan-file.sh <STATE_DIR>
#
# Reads STATE_DIR/scope.txt and each STATE_DIR/issue-N/details.json (the bodies
# Step 1 saved, and the ones Step 2's `extend` added), and fetches the tracking
# issue's current body with `gh issue view P --json body`. Run it from the
# target repository, so `gh` resolves the repository from the cwd.
#
# Which plan file:
#   - Every in-scope issue must have exactly one body line that, trimmed,
#     matches `^Part of #[0-9]+$`, naming the same P (Step 5's rule).
#   - P's current body must pass Step 1's tracking-issue test: a line that,
#     trimmed of trailing whitespace, is `## Slices`, and no such line that is
#     `## What to build`.
#   - The block is taken only from under P's own `## Plan file` heading: a line
#     that, trimmed of trailing whitespace, is exactly `## Plan file`. After it
#     and any blank lines, the next line must be exactly ```issue-runner-plan,
#     and the block runs to the next line that is exactly ```. A copy quoted
#     under `## Input` (every line prefixed `> `) never matches, and two
#     heading lines are ambiguous, so the file is ignored.
#
# The JSON is parsed here (bash + awk, no jq). Schema version 1: an object with
# `version` (the integer 1) and `issues`, an array of objects, each with `n` (a
# positive integer, unique), `blocked_by` (an array of positive integers) and
# `files` (an array of strings without control characters). Positive integers
# have at most 9 digits. Other keys are ignored, except that a duplicate key or
# a key containing `.`, `[` or `]` makes a version-1 block invalid (it could
# collide with the paths the parser records). Any other version is unknown,
# whatever its keys, and the file is ignored. On the issue side, control
# characters in a path are printed as `?`.
#
# The issue side is parsed with Step 2's rules:
#   blocked_by  every `#X` on a bullet line (`-`, `*` or `+`) of the body's
#               `## Blocked by` section, which ends at the next heading line or
#               the `Files likely touched:` line. "None - can start immediately"
#               has no `#X`, so it is the empty list.
#   files       the last body line beginning with `Files likely touched:`, split
#               on commas; each element is trimmed of whitespace and surrounding
#               backticks, and a leading `./` is stripped; empty elements are
#               dropped. No paths, or only `none`, means the issue lacks the line.
# Both sides are compared as sets (plan paths are normalized the same way).
#
# Output — every line starts with `plan file: `. The runner prints them
# verbatim in its Step 2 plan printout:
#   none (<reason>)       no plan file applies: the scope does not share one
#                         tracking issue, P is not a tracking issue, or P has
#                         no `## Plan file` heading
#   ignored (<reason>)    a plan file is there but cannot be used: ambiguous
#                         headings, no block directly under the heading, an
#                         unterminated block, invalid JSON or schema, or an
#                         unknown version
#   not checked (<reason>)
#                         an environment failure: scope.txt or a details.json
#                         unreadable, the `gh` query failed, no temp dir
#   #N in scope but missing from the plan
#   #N blocked_by differs: plan [122, 124] vs issue [122]
#   #N files differs: plan [src/a.ts] vs issue [src/a.ts, src/b.ts]
#                         per in-scope issue, in scope.txt order; the issue
#                         side reads `(no ## Blocked by section)` or
#                         `(no Files likely touched: line)` when it lacks one
#   in plan but not in scope: #61, #62
#                         plan entries this run does not cover (a partial run,
#                         a slice already closed, or an issue dropped by hand)
#   #P matches the in-scope issue bodies (K issues)
#                         no per-issue drift
#
# Exit status: 0 for every line above. An environment failure has the same
# disposition as a verdict here (a warning; the run proceeds on the issue
# bodies), so it is reported as `not checked` on exit 0 (the design-notes
# carve-out). 2 — a usage error.
#
# Dependencies: bash 3.2, coreutils, grep, awk, gh (its built-in --jq only projects
# the body; every decision is made here).

set -u
set +e +o pipefail   # every exit status below is read explicitly
export LC_ALL=C      # byte semantics for awk and sort
# C0 controls, DEL and C1 controls (U+0080-U+009F, UTF-8 C2 80-C2 9F): never printed
CTRL_RE=$(printf '[\001-\037\177]|\302[\200-\237]')

usage() { echo "plan-file.sh: $1" >&2; exit 2; }
say()   { printf 'plan file: %s\n' "$1"; }
skip()  { say "not checked ($1)"; exit 0; }

[ $# -eq 1 ] || usage "usage: plan-file.sh <STATE_DIR>"
SD=$1
[ -n "$SD" ] && [ -d "$SD" ] || usage "not a directory: '$SD'"

TMP=$(mktemp -d 2>/dev/null) || skip "cannot create a temp dir"
trap 'rm -rf "$TMP"' EXIT

# --- JSON (a small recursive-descent parser) ------------------------------------
# json_awk MODE [WANT] < json
#   get   print the decoded string at path WANT (e.g. `.body`); exit 3 when it is
#         absent or not a string, 4 when the input is not valid JSON
#   plan  validate schema version 1 and print `issue N`, `dep N X`, `file N PATH`
#         lines after an `ok` line; or one `version V` line (not 1); or one
#         `malformed <reason>` line
json_awk() {
  awk -v mode="$1" -v want="${2:-}" -v CTRL="$CTRL_RE" '
  function fail(m) { if (ERR == "") ERR = m " at byte " P; return 0 }
  function ws() { while (P <= N && (C[P] == " " || C[P] == "\t" || C[P] == "\n" || C[P] == "\r")) P++ }
  function rec(path, t, v) {
    if (path in TYPE) {
      # plan mode: a schema error, raised only once the version is known to be 1
      if (mode == "plan") { if (SCHEMA == "") SCHEMA = "duplicate key " path; return 1 }
      return fail("duplicate key " path)
    }
    TYPE[path] = t; VAL[path] = v; return 1
  }
  function val(path,   c) {
    ws(); if (P > N) return fail("unexpected end")
    c = C[P]
    if (c == "{") return obj(path)
    if (c == "[") return arr(path)
    if (c == "\"") { if (!str()) return 0; return rec(path, "s", SV) }
    if (c == "-" || (c >= "0" && c <= "9")) return num(path)
    if (substr(S, P, 4) == "true")  { P += 4; return rec(path, "b", "true") }
    if (substr(S, P, 5) == "false") { P += 5; return rec(path, "b", "false") }
    if (substr(S, P, 4) == "null")  { P += 4; return rec(path, "z", "") }
    return fail("unexpected character")
  }
  function obj(path,   k) {
    if (!rec(path, "o", "")) return 0
    P++; ws()
    if (C[P] == "}") { P++; return 1 }
    while (1) {
      ws(); if (C[P] != "\"") return fail("expected a key")
      if (!str()) return 0
      k = SV
      ws(); if (C[P] != ":") return fail("expected :"); P++
      if (mode == "plan" && k ~ /[].[]/) {
        # it could collide with a recorded path: parse its value out of the way
        if (SCHEMA == "") SCHEMA = "unexpected key " k
        if (!val(sprintf("%c", 1) path "." k)) return 0
      } else if (!val(path "." k)) return 0
      ws()
      if (C[P] == ",") { P++; continue }
      if (C[P] == "}") { P++; return 1 }
      return fail("expected , or }")
    }
  }
  function arr(path,   i) {
    if (!rec(path, "a", "")) return 0
    P++; ws()
    if (C[P] == "]") { P++; return 1 }
    for (i = 0; ; i++) {
      if (!val(path "[" i "]")) return 0
      ws()
      if (C[P] == ",") { P++; continue }
      if (C[P] == "]") { P++; return 1 }
      return fail("expected , or ]")
    }
  }
  function num(path,   st) {
    st = P
    if (C[P] == "-") P++
    if (C[P] == "0") P++
    else if (C[P] >= "1" && C[P] <= "9") { while (C[P] >= "0" && C[P] <= "9") P++ }
    else return fail("bad number")
    if (C[P] == ".") { P++; if (!(C[P] >= "0" && C[P] <= "9")) return fail("bad number"); while (C[P] >= "0" && C[P] <= "9") P++ }
    if (C[P] == "e" || C[P] == "E") {
      P++; if (C[P] == "+" || C[P] == "-") P++
      if (!(C[P] >= "0" && C[P] <= "9")) return fail("bad number")
      while (C[P] >= "0" && C[P] <= "9") P++
    }
    return rec(path, "n", substr(S, st, P - st))
  }
  function hexval(h,   i, v, d) {
    v = 0
    for (i = 1; i <= 4; i++) {
      d = index("0123456789abcdef", tolower(substr(h, i, 1)))
      if (d == 0) return -1
      v = v * 16 + d - 1
    }
    return v
  }
  function utf8(cp) {
    if (cp < 128) return sprintf("%c", cp)
    if (cp < 2048) return sprintf("%c%c", 192 + int(cp / 64), 128 + cp % 64)
    if (cp < 65536) return sprintf("%c%c%c", 224 + int(cp / 4096), 128 + int(cp / 64) % 64, 128 + cp % 64)
    return sprintf("%c%c%c%c", 240 + int(cp / 262144), 128 + int(cp / 4096) % 64, 128 + int(cp / 64) % 64, 128 + cp % 64)
  }
  function str(   st, c, cp, lo) {
    P++; SV = ""
    while (P <= N) {
      st = P
      while (P <= N && C[P] != "\"" && C[P] != "\\" && C[P] >= " ") P++
      if (P > st) SV = SV substr(S, st, P - st)
      if (P > N) break
      c = C[P]
      if (c == "\"") { P++; return 1 }
      if (c != "\\") return fail("control character in a string")
      P++; c = C[P]
      if (c == "\"" || c == "\\" || c == "/") SV = SV c
      else if (c == "n") SV = SV "\n"
      else if (c == "t") SV = SV "\t"
      else if (c == "r") SV = SV "\r"
      else if (c == "b") SV = SV "\b"
      else if (c == "f") SV = SV "\f"
      else if (c == "u") {
        cp = hexval(substr(S, P + 1, 4)); if (cp < 0) return fail("bad \\u escape")
        P += 4
        if (cp >= 55296 && cp <= 56319 && substr(S, P + 1, 2) == "\\u") {
          lo = hexval(substr(S, P + 3, 4))
          if (lo >= 56320 && lo <= 57343) { cp = 65536 + (cp - 55296) * 1024 + (lo - 56320); P += 6 }
        }
        if (cp > 0) SV = SV utf8(cp)
      }
      else return fail("bad escape")
      P++
    }
    return fail("unterminated string")
  }
  function posint(v) { return v ~ /^[1-9][0-9]*$/ && length(v) <= 9 }
  function plan(   i, j, p, n, seen, out) {
    if (TYPE[""] != "o") return "malformed the top level is not an object"
    if (!(".version" in TYPE)) return "malformed no version"
    if (TYPE[".version"] != "n" || VAL[".version"] !~ /^-?[0-9]+$/) return "malformed version is not an integer"
    if (VAL[".version"] != "1") return "version " VAL[".version"]
    if (SCHEMA != "") return "malformed " SCHEMA
    if (TYPE[".issues"] != "a") return "malformed issues is not an array"
    out = "ok"
    for (i = 0; (".issues[" i "]") in TYPE; i++) {
      p = ".issues[" i "]"
      if (TYPE[p] != "o") return "malformed issues[" i "] is not an object"
      if (TYPE[p ".n"] != "n" || !posint(VAL[p ".n"])) return "malformed issues[" i "].n is not a positive integer"
      n = VAL[p ".n"]
      if (n in seen) return "malformed #" n " listed twice"
      seen[n] = 1
      out = out "\nissue " n
      if (TYPE[p ".blocked_by"] != "a") return "malformed issues[" i "].blocked_by is not an array"
      for (j = 0; (p ".blocked_by[" j "]") in TYPE; j++) {
        if (TYPE[p ".blocked_by[" j "]"] != "n" || !posint(VAL[p ".blocked_by[" j "]"])) return "malformed issues[" i "].blocked_by[" j "] is not a positive integer"
        out = out "\ndep " n " " VAL[p ".blocked_by[" j "]"]
      }
      if (TYPE[p ".files"] != "a") return "malformed issues[" i "].files is not an array"
      for (j = 0; (p ".files[" j "]") in TYPE; j++) {
        if (TYPE[p ".files[" j "]"] != "s" || VAL[p ".files[" j "]"] ~ CTRL) return "malformed issues[" i "].files[" j "] is not a string without control characters"
        out = out "\nfile " n " " VAL[p ".files[" j "]"]
      }
    }
    return out
  }
  { S = S $0 "\n" }
  END {
    N = split(S, C, ""); P = 1; ERR = ""
    if (val("")) { ws(); if (P <= N) fail("trailing content") }
    if (mode == "get") {
      if (ERR != "") exit 4
      if (TYPE[want] != "s") exit 3
      printf "%s", VAL[want]; exit 0
    }
    if (ERR != "") { print "malformed invalid JSON: " ERR; exit 0 }
    print plan()
  }'
}

# --- Issue-side parsing (Step 2's rules) -----------------------------------------
# norm_paths: one raw element per line in, one normalized path per line out
norm_paths() {
  awk -v CTRL="$CTRL_RE" '{ p = $0; gsub(/^[ \t]+|[ \t]+$/, "", p)
         while (p ~ /^`/) p = substr(p, 2)
         while (p ~ /`$/) p = substr(p, 1, length(p) - 1)
         gsub(/^[ \t]+|[ \t]+$/, "", p)
         if (substr(p, 1, 2) == "./") p = substr(p, 3)
         gsub(CTRL, "?", p)   # issue bodies are untrusted: no control byte reaches the printout
         if (p != "") print p }'
}
# body_deps < body: one dependency per line, or `nosection`
body_deps() {
  awk '{ sub(/\r$/, ""); t = $0; sub(/[ \t]+$/, "", t) }
       !seen && t == "## Blocked by" { inb = 1; seen = 1; next }
       inb && ($0 ~ /^#+([ \t]|$)/ || $0 ~ /^Files likely touched:/) { inb = 0 }
       inb && $0 ~ /^[ \t]*[-*+][ \t]/ {
         s = $0
         while (match(s, /#[0-9]+/)) { print substr(s, RSTART + 1, RLENGTH - 1) + 0; s = substr(s, RSTART + RLENGTH) }
       }
       END { if (!seen) print "nosection" }'
}
# body_files < body: one normalized path per line, or `noline`
body_files() {
  local raw
  raw=$(awk '{ sub(/\r$/, "") } /^Files likely touched:/ { l = $0; have = 1 }
             END { if (!have) exit
                   sub(/^Files likely touched:/, "", l); n = split(l, a, ",")
                   for (i = 1; i <= n; i++) print a[i] }' | norm_paths)
  if [ -z "$raw" ] || { [ "$(printf '%s\n' "$raw" | grep -c .)" -eq 1 ] && [ "$(printf '%s' "$raw" | tr 'A-Z' 'a-z')" = none ]; }; then
    echo noline
  else
    printf '%s\n' "$raw"
  fi
}
join_list() { awk 'BEGIN { ORS = "" } { print (NR > 1 ? ", " : "") $0 } END { printf "\n" }'; }

# --- Scope and the shared tracking issue -----------------------------------------
[ -r "$SD/scope.txt" ] || skip "cannot read scope.txt"
SCOPE=$(tr -s ' \t\r' '\n\n\n' < "$SD/scope.txt" | grep .) || skip "scope.txt is empty"
for N in $SCOPE; do
  case $N in *[!0-9]*|0*) skip "scope.txt holds '$N', not an issue number" ;; esac
done

P=""
for N in $SCOPE; do
  [ -r "$SD/issue-$N/details.json" ] || skip "cannot read issue-$N/details.json"
  json_awk get .body < "$SD/issue-$N/details.json" > "$TMP/body-$N" \
    || skip "cannot read #$N's body from issue-$N/details.json"
  p=$(awk '{ sub(/\r$/, ""); gsub(/^[ \t]+|[ \t]+$/, "") } /^Part of #[0-9]+$/ { c++; v = substr($0, 10) + 0 }
           END { if (c == 1) print v }' "$TMP/body-$N")
  if [ -z "$p" ] || { [ -n "$P" ] && [ "$p" != "$P" ]; }; then
    say "none (the scope does not share one tracking issue)"; exit 0
  fi
  P=$p
done

gh issue view "$P" --json body --jq .body > "$TMP/tracking" 2>"$TMP/gh.err" </dev/null \
  || skip "cannot read #$P's body: $(head -1 "$TMP/gh.err")"

track=$(awk '{ sub(/\r$/, ""); sub(/[ \t]+$/, "") } $0 == "## Slices" { s = 1 } $0 == "## What to build" { w = 1 }
             END { print (s && !w) ? "yes" : "no" }' "$TMP/tracking")
[ "$track" = yes ] || { say "none (#$P is not a tracking issue)"; exit 0; }

# --- The block under the tracking body's own heading -----------------------------
awk -v blk="$TMP/block" '
  { sub(/\r$/, ""); t = $0; sub(/[ \t]+$/, "", t) }
  t == "## Plan file" { h++; if (h == 1) { st = 1; next } }
  st == 1 { if (t == "") next; st = (t == "```issue-runner-plan") ? 2 : 3; next }
  st == 2 { if (t == "```") { st = 4; next }; print > blk; next }
  END { if (h == 0) print "none"; else if (h > 1) print "ambiguous " h
        else if (st == 1 || st == 3) print "noblock"; else if (st == 2) print "unterminated"; else print "block" }
' "$TMP/tracking" > "$TMP/where"
where=$(cat "$TMP/where")
case $where in
  none)         say "none (#$P has no ## Plan file section)"; exit 0 ;;
  ambiguous*)   say "ignored (#$P has ${where#ambiguous } '## Plan file' headings)"; exit 0 ;;
  noblock)      say "ignored (no issue-runner-plan block directly under #$P's ## Plan file heading)"; exit 0 ;;
  unterminated) say "ignored (#$P's issue-runner-plan block is not closed)"; exit 0 ;;
esac
[ -f "$TMP/block" ] || : > "$TMP/block"

json_awk plan < "$TMP/block" > "$TMP/plan"
first=$(head -1 "$TMP/plan")
case $first in
  ok) ;;
  version*)   say "ignored (#$P's plan file has unknown version ${first#version })"; exit 0 ;;
  malformed*) say "ignored (#$P's plan file is not valid: ${first#malformed })"; exit 0 ;;
  *)          skip "cannot parse #$P's plan file" ;;
esac

# --- Compare ----------------------------------------------------------------------
drift=0
for N in $SCOPE; do
  if ! grep -qx "issue $N" "$TMP/plan"; then
    say "#$N in scope but missing from the plan"; drift=1; continue
  fi
  pd=$(awk -v n="$N" '$1 == "dep" && $2 == n { print $3 + 0 }' "$TMP/plan" | sort -n -u)
  id=$(body_deps < "$TMP/body-$N")
  if [ "$id" = nosection ]; then
    say "#$N blocked_by differs: plan [$(printf '%s\n' "$pd" | grep . | join_list)] vs issue (no ## Blocked by section)"; drift=1
  else
    id=$(printf '%s\n' "$id" | grep . | sort -n -u)
    if [ "$pd" != "$id" ]; then
      say "#$N blocked_by differs: plan [$(printf '%s\n' "$pd" | grep . | join_list)] vs issue [$(printf '%s\n' "$id" | grep . | join_list)]"; drift=1
    fi
  fi
  pf=$(awk -v n="$N" '$1 == "file" && $2 == n { sub(/^file [0-9]+ /, ""); print }' "$TMP/plan" | norm_paths | sort -u)
  if_=$(body_files < "$TMP/body-$N")
  if [ "$if_" = noline ]; then
    say "#$N files differs: plan [$(printf '%s\n' "$pf" | grep . | join_list)] vs issue (no Files likely touched: line)"; drift=1
  else
    if_=$(printf '%s\n' "$if_" | sort -u)
    if [ "$pf" != "$if_" ]; then
      say "#$N files differs: plan [$(printf '%s\n' "$pf" | grep . | join_list)] vs issue [$(printf '%s\n' "$if_" | grep . | join_list)]"; drift=1
    fi
  fi
done

extra=$(awk '$1 == "issue" { print $2 }' "$TMP/plan" | while read -r n; do
  printf '%s\n' "$SCOPE" | grep -qx "$n" || printf '#%s\n' "$n"
done | join_list)
[ "$drift" -eq 0 ] && say "#$P matches the in-scope issue bodies ($(printf '%s\n' "$SCOPE" | grep -c .) issues)"
[ -n "$extra" ] && say "in plan but not in scope: $extra"
exit 0
