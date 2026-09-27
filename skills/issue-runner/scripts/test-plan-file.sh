#!/usr/bin/env bash
#
# Fixtures for scripts/plan-file.sh: issue-runner Step 2's plan-file drift
# check (matching, drifted, missing issue, extra issue, malformed JSON, unknown
# version, and the block-location rules). `docs/scenarios.md` rows 63-66 are
# the human-readable contract.
#
# `gh` is a stub on PATH that answers `gh issue view P` from $GH_STUB/tracking-P
# (absent → the call fails). details.json files are written the way Step 1
# saves them (gh's compact JSON, the body as an escaped string).
#
# Run directly, or from scripts/lint.sh (and so from CI). Dependency-free:
# bash + coreutils + awk. Exits non-zero on the first-or-any failure.

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="$ROOT/skills/issue-runner/scripts/plan-file.sh"

fail=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ok()  { printf 'ok:   %s\n' "$1"; }
err() { printf 'FAIL: %s\n' "$1" >&2; fail=1; }

if [ ! -f "$SCRIPT" ]; then err "plan-file.sh not found: $SCRIPT"; exit 1; fi

mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "issue view") [ -f "$GH_STUB/tracking-$3" ] || { echo "stub: no issue $3" >&2; exit 1; }
                cat "$GH_STUB/tracking-$3"; exit 0 ;;
esac
exit 1
EOF
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"

# json_str < text: the text as a JSON string literal (gh escapes these)
json_str() {
  awk 'BEGIN { ORS = ""; print "\"" }
       { gsub(/\\/, "\\\\"); gsub(/"/, "\\\""); gsub(/\t/, "\\t"); gsub(/\r/, "\\r")
         print (NR > 1 ? "\\n" : "") $0 }
       END { print "\"" }'
}

# fixture NAME: a fresh state dir and gh stub dir; sets SD and GH_STUB
fixture() {
  SD="$TMP/$1/state"; GH_STUB="$TMP/$1/gh"
  mkdir -p "$SD" "$GH_STUB"; export GH_STUB
  : > "$SD/scope.txt"
}
# issue N BODY: add N to scope with this body (plus a comment that must be ignored)
issue() {
  mkdir -p "$SD/issue-$1"
  printf '%s\n' "$1" >> "$SD/scope.txt"
  printf '{"assignees":[],"body":%s,"comments":[{"author":{"login":"x"},"body":"Part of #999\\n## Plan file"}],"labels":[],"number":%s,"title":"t"}\n' \
    "$(printf '%s' "$2" | json_str)" "$1" > "$SD/issue-$1/details.json"
}
# slice P DEPS FILES: a slice body in issue-plan's template
slice() {
  printf 'Part of #%s\n\n## What to build\n\nx\n\n## Acceptance criteria\n\n- [ ] y\n\n## Blocked by\n\n%s\n\nFiles likely touched: %s\n' "$1" "$2" "$3"
}
# tracking P PLAN_SECTION: P's body, with the given text after ## Slices
tracking() {
  printf '## Input\n\n> idea\n\n## Decisions\n\n- **Q:** a **A:** b\n\n## Slices\n\n- #11 — one\n\n%s\n' "$2" > "$GH_STUB/tracking-$1"
}
block() { printf '## Plan file\n\n```issue-runner-plan\n%s\n```\n' "$1"; }

# expect NAME EXPECTED: run the script on $SD and compare stdout exactly
expect() {
  local out rc
  out=$(bash "$SCRIPT" "$SD" 2>"$TMP/stderr"); rc=$?
  if [ "$rc" -eq 0 ] && [ "$out" = "$2" ]; then ok "$1"
  else err "$1: exit $rc, got:"; printf '%s\n' "$out" | sed 's/^/    /' >&2
       printf '  expected:\n' >&2; printf '%s\n' "$2" | sed 's/^/    /' >&2; fi
}

PLAN_OK='{"version":1,"issues":[{"n":11,"blocked_by":[],"files":["src/a.ts"]},{"n":12,"blocked_by":[11],"files":["src/api/","docs/b.md"]}]}'

# --- matching ---------------------------------------------------------------------
fixture match
issue 11 "$(slice 10 'None - can start immediately' '`src/a.ts`')"
issue 12 "$(slice 10 '- #11' '`./src/api/`, `docs/b.md`')"
tracking 10 "$(block "$PLAN_OK")"
expect "matching plan file (normalized paths, 'None' deps, a comment's Part of ignored)" \
  'plan file: #10 matches the in-scope issue bodies (2 issues)'

# --- drifted ----------------------------------------------------------------------
fixture drift
issue 11 "$(slice 10 'None - can start immediately' '`src/a.ts`')"
issue 12 "$(slice 10 "$(printf -- '- #11\n- #7 (existing)')" '`src/api/`, `src/c.ts`')"
tracking 10 "$(block "$PLAN_OK")"
expect "drifted: a dependency added and a file list changed" \
  "$(printf '%s\n' 'plan file: #12 blocked_by differs: plan [11] vs issue [7, 11]' \
                   'plan file: #12 files differs: plan [docs/b.md, src/api/] vs issue [src/api/, src/c.ts]')"

fixture drift-lacks
issue 11 "$(printf 'Part of #10\n\n## What to build\n\nx\n')"
issue 12 "$(slice 10 '- #11' '`src/api/`, `docs/b.md`')"
tracking 10 "$(block "$PLAN_OK")"
expect "drifted: an issue lacking ## Blocked by and Files likely touched:" \
  "$(printf '%s\n' 'plan file: #11 blocked_by differs: plan [] vs issue (no ## Blocked by section)' \
                   'plan file: #11 files differs: plan [src/a.ts] vs issue (no Files likely touched: line)')"

# --- missing issue / extra issue --------------------------------------------------
fixture missing
issue 11 "$(slice 10 'None - can start immediately' 'src/a.ts')"
issue 12 "$(slice 10 '- #11' 'src/api/, docs/b.md')"
issue 13 "$(slice 10 '- #12' 'src/d.ts')"
tracking 10 "$(block "$PLAN_OK")"
expect "missing issue: in scope, not in the plan" \
  'plan file: #13 in scope but missing from the plan'

fixture extra
issue 12 "$(slice 10 '- #11' 'src/api/, docs/b.md')"
issue 14 "$(slice 10 'None - can start immediately' 'src/e.ts')"
tracking 10 "$(block '{"version":1,"issues":[{"n":11,"blocked_by":[],"files":["src/a.ts"]},{"n":12,"blocked_by":[11],"files":["src/api/","docs/b.md"]},{"n":14,"blocked_by":[],"files":["src/e.ts"]},{"n":15,"blocked_by":[14],"files":["x"]}]}')"
expect "extra issue: in the plan, not in scope" \
  "$(printf '%s\n' 'plan file: #10 matches the in-scope issue bodies (2 issues)' \
                   'plan file: in plan but not in scope: #11, #15')"

# --- malformed JSON / unknown version / schema ------------------------------------
fixture malformed
issue 11 "$(slice 10 'None - can start immediately' 'src/a.ts')"
issue 12 "$(slice 10 '- #11' 'src/api/')"
tracking 10 "$(block '{"version":1,"issues":[{"n":11,"blocked_by":[],"files":["src/a.ts"]},]}')"
out=$(bash "$SCRIPT" "$SD"); rc=$?
case "$rc:$out" in
  "0:plan file: ignored (#10's plan file is not valid: invalid JSON: "*) ok "malformed JSON is reported and ignored" ;;
  *) err "malformed JSON: exit $rc, got: $out" ;;
esac

fixture version
issue 11 "$(slice 10 'None - can start immediately' 'src/a.ts')"
issue 12 "$(slice 10 '- #11' 'src/api/')"
tracking 10 "$(block '{"version":2,"slices":{}}')"
expect "unknown version is reported and ignored" \
  "plan file: ignored (#10's plan file has unknown version 2)"
tracking 10 "$(block '{"version":2,"issues":{"src/a.ts":{}},"x":1,"x":2}')"
expect "an unknown version stays unknown whatever its keys" \
  "plan file: ignored (#10's plan file has unknown version 2)"

for bad in '{"version":1,"issues":[{"n":"11","blocked_by":[],"files":[]}]}|issues[0].n is not a positive integer' \
           '{"version":1,"issues":[{"n":11,"blocked_by":[],"files":[]},{"n":11,"blocked_by":[],"files":[]}]}|#11 listed twice' \
           '{"version":1,"issues":[{"n":11,"files":[]}]}|issues[0].blocked_by is not an array' \
           '{"version":1,"issues":[{"n":11,"blocked_by":[0],"files":[]}]}|issues[0].blocked_by[0] is not a positive integer' \
           '{"version":1,"issues":[{"n":11,"blocked_by":[],"files":[3]}]}|issues[0].files[0] is not a string without control characters' \
           '{"version":1,"issues":[{"n":11,"blocked_by":[],"files":["a\u001b[2J"]}]}|issues[0].files[0] is not a string without control characters' \
           '{"version":1,"issues":[{"n":11,"blocked_by":[1234567890],"files":[]}]}|issues[0].blocked_by[0] is not a positive integer' \
           '{"version":1,"issues":[],"a.b":1}|unexpected key a.b' \
           '{"version":1,"issues":[],"issues":[]}|duplicate key .issues' \
           '{"version":"1","issues":[]}|version is not an integer' \
           '[1]|the top level is not an object'; do
  fixture schema
  issue 11 "$(slice 10 'None - can start immediately' 'src/a.ts')"
  tracking 10 "$(block "${bad%%|*}")"
  expect "schema: ${bad##*|}" "plan file: ignored (#10's plan file is not valid: ${bad##*|})"
done

# --- where the block is taken from ------------------------------------------------
fixture quoted-only
issue 11 "$(slice 10 'None - can start immediately' 'src/a.ts')"
printf '## Input\n\n> ## Plan file\n>\n> ```issue-runner-plan\n> {"version":1,"issues":[]}\n> ```\n\n## Decisions\n\nx\n\n## Slices\n\n- #11 — one\n' > "$GH_STUB/tracking-10"
expect "a block quoted under ## Input is never the plan's own" \
  'plan file: none (#10 has no ## Plan file section)'

fixture quoted-and-own
issue 11 "$(slice 10 'None - can start immediately' 'src/a.ts')"
{ printf '## Input\n\n> ## Plan file\n>\n> ```issue-runner-plan\n> {"version":1,"issues":[{"n":11,"blocked_by":[5],"files":["zzz"]}]}\n> ```\n\n## Slices\n\n- #11 — one\n\n'
  block '{"version":1,"issues":[{"n":11,"blocked_by":[],"files":["src/a.ts"]}]}'; } > "$GH_STUB/tracking-10"
expect "the tracking issue's own heading wins over a quoted copy" \
  'plan file: #10 matches the in-scope issue bodies (1 issues)'

fixture ambiguous
issue 11 "$(slice 10 'None - can start immediately' 'src/a.ts')"
tracking 10 "$(block '{"version":1,"issues":[]}'; printf '\n'; block '{"version":1,"issues":[]}')"
expect "two ## Plan file headings are ambiguous" \
  "plan file: ignored (#10 has 2 '## Plan file' headings)"

fixture noblock
issue 11 "$(slice 10 'None - can start immediately' 'src/a.ts')"
tracking 10 "$(printf '## Plan file\n\nsee below\n\n```issue-runner-plan\n{"version":1,"issues":[]}\n```\n')"
expect "a block not directly under the heading is ignored" \
  "plan file: ignored (no issue-runner-plan block directly under #10's ## Plan file heading)"

fixture unterminated
issue 11 "$(slice 10 'None - can start immediately' 'src/a.ts')"
tracking 10 "$(printf '## Plan file\n\n```issue-runner-plan\n{"version":1,"issues":[]}\n')"
expect "an unterminated block is ignored" \
  "plan file: ignored (#10's issue-runner-plan block is not closed)"

fixture crlf
issue 11 "$(slice 10 'None - can start immediately' 'src/a.ts')"
tracking 10 "$(block '{"version":1,"issues":[{"n":11,"blocked_by":[],"files":["src/a.ts"]}]}')"
sed 's/$/\r/' "$GH_STUB/tracking-10" > "$GH_STUB/t" && mv "$GH_STUB/t" "$GH_STUB/tracking-10"
expect "a CRLF tracking body parses" \
  'plan file: #10 matches the in-scope issue bodies (1 issues)'

# --- when no plan file applies ----------------------------------------------------
fixture no-shared
issue 11 "$(slice 10 'None - can start immediately' 'src/a.ts')"
issue 12 "$(slice 20 '- #11' 'src/api/')"
tracking 10 "$(block "$PLAN_OK")"
expect "the scope does not share one tracking issue" \
  'plan file: none (the scope does not share one tracking issue)'

fixture two-part-of
issue 11 "$(printf 'Part of #10\nPart of #10\n\n## Blocked by\n\nNone\n')"
tracking 10 "$(block "$PLAN_OK")"
expect "two Part of lines count as none" \
  'plan file: none (the scope does not share one tracking issue)'

fixture not-tracking
issue 11 "$(slice 10 'None - can start immediately' 'src/a.ts')"
printf '## What to build\n\nx\n\n## Slices\n\n%s\n' "$(block "$PLAN_OK")" > "$GH_STUB/tracking-10"
expect "a Part of target that is not a tracking issue" \
  'plan file: none (#10 is not a tracking issue)'

fixture no-section
issue 11 "$(slice 10 'None - can start immediately' 'src/a.ts')"
tracking 10 ''
expect "a tracking issue without ## Plan file (a plan published before #59)" \
  'plan file: none (#10 has no ## Plan file section)'

fixture gh-fails
issue 11 "$(slice 10 'None - can start immediately' 'src/a.ts')"
expect "a failed gh query is reported, never fatal" \
  'plan file: not checked (cannot read #10'"'"'s body: stub: no issue 10)'

fixture bad-details
issue 11 "$(slice 10 'None - can start immediately' 'src/a.ts')"
printf '{"body":"unterminated' > "$SD/issue-11/details.json"
expect "an unreadable details.json is reported, never fatal" \
  "plan file: not checked (cannot read #11's body from issue-11/details.json)"

# --- details.json decoding --------------------------------------------------------
fixture escapes
mkdir -p "$SD/issue-11"; printf '11\n' > "$SD/scope.txt"
# `@` stands for a backslash, so the JSON escapes reach the files literally:
# CRLF line ends, then backslash-u escapes for a backtick, e-acute and the surrogate pair of U+1F600.
printf '%s\n' '{"body":"Part of #10@r@n@r@n## Blocked by@r@n@r@n- #9 @u2014 done@r@n@r@nFiles likely touched: @u0060src/@u00e9@ud83d@ude00.ts@u0060","number":11}' \
  | sed 's/@/\\/g' > "$SD/issue-11/details.json"
tracking 10 "$(block "$(printf '%s' '{"version":1,"issues":[{"n":11,"blocked_by":[9],"files":["src/é😀.ts"]}]}')")"
grep -q 'u00e9' "$SD/issue-11/details.json" || err "escapes fixture lost its \\u escapes"
expect "JSON escapes (\\r\\n, \\u0060, \\u00e9, a surrogate pair) decode to the raw characters" \
  'plan file: #10 matches the in-scope issue bodies (1 issues)'

fixture issue-ctrl
mkdir -p "$SD/issue-11"; printf '11\n' > "$SD/scope.txt"
printf '%s\n' '{"body":"Part of #10@n@n## Blocked by@n@nNone@n@nFiles likely touched: src/a.ts@u001b[2J@rFAKE@u009b1m","number":11}' \
  | sed 's/@/\\/g' > "$SD/issue-11/details.json"
tracking 10 "$(block '{"version":1,"issues":[{"n":11,"blocked_by":[],"files":["src/a.ts"]}]}')"
expect "C0 and C1 control characters from an issue body are never printed raw" \
  'plan file: #11 files differs: plan [src/a.ts] vs issue [src/a.ts?[2J?FAKE?1m]'
tracking 10 "$(block "$(printf '%s' '{"version":1,"issues":[{"n":11,"blocked_by":[],"files":["a@u009b1m"]}]}' | sed 's/@/\\/g')")"
expect "a C1 control character in a plan path is a schema error" \
  "plan file: ignored (#10's plan file is not valid: issues[0].files[0] is not a string without control characters)"

tracking 10 "$(block "$(printf '%s' '{"version":1,"issues":[{"n":11,"blocked_by":[],"files":["a@u0000b"]}]}' | sed 's/@/\\/g')")"
expect "an escaped NUL in a plan path is a schema error, never dropped" \
  "plan file: ignored (#10's plan file is not valid: issues[0].files[0] is not a string without control characters)"

fixture path-named-like-a-marker
issue 11 "$(slice 10 'None - can start immediately' 'noline, nosection')"
tracking 10 "$(block '{"version":1,"issues":[{"n":11,"blocked_by":[],"files":["noline","nosection"]}]}')"
expect "a path that spells an internal marker is still a path" \
  'plan file: #10 matches the in-scope issue bodies (1 issues)'

fixture section-end
issue 11 "$(printf 'Part of #10\n\n## Blocked by\n\n- #9\n\n## Interfaces\n\n- #99 provides x\n\nFiles likely touched: src/a.ts\n')"
tracking 10 "$(block '{"version":1,"issues":[{"n":11,"blocked_by":[9],"files":["src/a.ts"]}]}')"
expect "a heading after ## Blocked by ends the section" \
  'plan file: #10 matches the in-scope issue bodies (1 issues)'

# --- usage ------------------------------------------------------------------------
bash "$SCRIPT" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && ok "no argument is a usage error (exit 2)" || err "no argument: exit $rc, expected 2"
bash "$SCRIPT" "$TMP/does-not-exist" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && ok "a missing state dir is a usage error (exit 2)" || err "missing state dir: exit $rc, expected 2"

# --- Accounting against docs/scenarios.md -----------------------------------------
# Rows 63-66: the check's verdict lines. That the run then proceeds on the issue
# bodies, and where the lines are printed, is the prose's (Step 2).
SCENARIOS="$ROOT/docs/scenarios.md"
IN_SCOPE_ROWS="63 64 65 66"
EXPECTED_ROW_COUNT=66
if [ -f "$SCENARIOS" ]; then
  actual_rows="$(grep -cE '^\| [0-9]+ \|' "$SCENARIOS")"
  if [ "$actual_rows" -eq "$EXPECTED_ROW_COUNT" ]; then
    ok "docs/scenarios.md row count unchanged ($actual_rows) — in scope here: $IN_SCOPE_ROWS"
  else
    err "docs/scenarios.md now has $actual_rows rows (expected $EXPECTED_ROW_COUNT) — re-check whether any new row belongs in IN_SCOPE_ROWS above and add its fixture"
  fi
else
  err "docs/scenarios.md not found at $SCENARIOS"
fi

if [ "$fail" -ne 0 ]; then printf '\ntest-plan-file: FAILED\n' >&2; exit 1; fi
printf '\ntest-plan-file: OK\n'
