#!/usr/bin/env bash
#
# Golden fixtures for scripts/summary.sh: issue-runner Step 5's summary table,
# telemetry and actual-vs-estimated spend line, built from a fake $STATE_DIR.
# Every branch of the script has a fixture: the readable/unreadable
# result.json rule, the flag lines (checkpoint `skipped` apart from `refused`),
# the agent arithmetic, the hung-after-merge note, the optional pr-shape
# section (against a stub classify.sh) and the usage errors.
#
# Usage: test-summary.sh [path/to/summary.sh]   (default: the sibling script)
# Run directly, or from scripts/lint.sh (and so from CI). Dependency-free:
# bash + coreutils. Exits non-zero on any failure.

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${1:-$HERE/summary.sh}"

fail=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ok()  { printf 'ok:   %s\n' "$1"; }
err() { printf 'FAIL: %s\n' "$1" >&2; fail=1; }

[ -f "$SCRIPT" ] || { err "summary.sh not found at $SCRIPT"; exit 1; }

# --- Fixture helpers ------------------------------------------------------------
S="$TMP/state"
reset() { rm -rf "$S"; mkdir -p "$S"; }
scope() { : > "$S/scope.txt"; for n in "$@"; do printf '%s\n' "$n" >> "$S/scope.txt"; done; }
# issue N STATUS [TITLE]: creates issue-N with a status and a gh-shaped details.json.
issue() {
  mkdir -p "$S/issue-$1"
  printf '%s\n' "$2" > "$S/issue-$1/status"
  printf '{"assignees":[],"body":"see \\"title\\":\\"decoy\\"","comments":[],"labels":[],"number":%s,"title":"%s"}\n' \
    "$1" "${3:-Title $1}" > "$S/issue-$1/details.json"
}
# result N OUTCOME ITER P1STATE INLINE GATES GSTATE CHECKS CHECKPOINT PROFILE BLOCKER-JSON
result() {
  printf '{"outcome":"%s","pr":%s,"branch":"feat/issue-%s-x","worktree":"/w/%s","phase1_iterations":%s,"phase1_inline":%s,"phase1_state":"%s","gate_passes":%s,"gate_state":"%s","checks":"%s","checkpoint":"%s","security_lens":false,"review_profile":"%s","blocker":%s}\n' \
    "$2" "$1" "$1" "$1" "$3" "$5" "$4" "$6" "$7" "$8" "$9" "${10}" "${11}" > "$S/issue-$1/result.json"
}
clean_result() { result "$1" merged 2 converged false 1 clean pass created standard null; }

OUT="" RC=0
run() { OUT=$(bash "$SCRIPT" "$@" 2>"$TMP/stderr"); RC=$?; }
has()   { case $OUT in *"$2"*) ok "$1" ;; *) err "$1: output lacks '$2'"; printf '%s\n' "$OUT" | sed 's/^/  > /' >&2 ;; esac; }
hasnt() { case $OUT in *"$2"*) err "$1: output has '$2'"; printf '%s\n' "$OUT" | sed 's/^/  > /' >&2 ;; *) ok "$1" ;; esac; }
rc_is() { [ "$RC" -eq "$2" ] && ok "$1" || { err "$1: exit $RC, expected $2"; cat "$TMP/stderr" >&2; }; }

# --- Table, titles and sanitizing ---------------------------------------------------
reset; scope 1 2 3
issue 1 done 'Plain title'; clean_result 1
issue 2 blocked 'Pipe | and `tick` and \\back'; result 2 blocker 3 cap-stop false 0 unavailable none created standard '"x"'
printf 'line one\nline | two with `tick`\n' > "$S/issue-2/error"
issue 3 failed 'Failed one'; printf 'step=8.1 iter=2 pr=#9\n' > "$S/issue-3/progress"
printf 'boom\n' > "$S/issue-3/error"
run "$S" 3
rc_is "table: exit 0" 0
has "table: header" '| # | Status | Title | Error | Last progress |'
has "table: plain row has no error or progress cell content" '| #1 | done | `Plain title` |  |  |'
has "table: title is sanitized (pipe, backtick, backslash)" '`Pipe \| and '"'"'tick'"'"' and /back`'
has "table: multi-line error collapses to one cell" '`line one line \| two with '"'"'tick'"'"'`'
has "table: failed issue shows its last progress line" '| #3 | failed | `Failed one` | `boom` | `step=8.1 iter=2 pr=#9` |'
hasnt "table: a title decoy in the body is ignored" 'decoy'

# --- A failed issue without a progress file -------------------------------------------
reset; scope 4
issue 4 failed; : > "$S/issue-4/progress"
run "$S" 3
has "failed with an empty progress file -> no progress recorded" '| no progress recorded |'
rm -f "$S/issue-4/progress"
run "$S" 3
has "failed with no progress file -> no progress recorded" '| no progress recorded |'
issue 5 blocked; scope 5
run "$S" 3
hasnt "a non-failed issue never prints a progress cell" 'no progress recorded'

# --- Unreadable result.json -------------------------------------------------------------
reset; scope 1 2 3 4 5 6
for n in 1 2 3 4 5 6; do issue "$n" blocked; done
# 1 absent; 2 two lines; 3 bad outcome; 4 empty worktree; 5 not an object; 6 empty file
printf '{"outcome":"merged","worktree":"/w"}\n{"outcome":"merged","worktree":"/w"}\n' > "$S/issue-2/result.json"
printf '{"outcome":"nonsense","worktree":"/w","phase1_iterations":9}\n' > "$S/issue-3/result.json"
printf '{"outcome":"merged","worktree":"","phase1_iterations":9}\n' > "$S/issue-4/result.json"
printf 'phase1_iterations: 9\n' > "$S/issue-5/result.json"
: > "$S/issue-6/result.json"
run "$S" 3
rc_is "unreadable results: exit 0" 0
for n in 1 2 3 4 5 6; do has "unreadable result #$n -> no result recorded" "- #$n: no result recorded (retries=0)"; done
has "unreadable results add no phase1 iterations" 'totals: phase1 iterations=0; gate passes=0'

# --- Telemetry, flags, checkpoint skipped vs refused -----------------------------------
reset; scope 1 2 3 4
issue 1 done; result 1 merged 2 converged false 1 clean pass created standard null
issue 2 blocked; result 2 blocker 5 cap-stop true 3 degraded fail skipped standard '"a \"checkpoint\":\"refused\" decoy"'
issue 3 done; result 3 merged 1 converged false 0 waived none refused standard null
issue 4 done; result 4 merged 1 converged false 0 clean none-after-ready refused prose null
run "$S" 3
has "telemetry: clean issue line" '- #1: phase1 iterations=2; gate passes=1; checks=pass; checkpoint=created; retries=0'
has "telemetry: phase1 cap-stop flagged" '  ! phase1_state cap-stop'
has "telemetry: gate degraded flagged" '  ! gate_state degraded'
has "telemetry: gate waived flagged" '  ! gate_state waived'
has "telemetry: inline flagged" '  ! phase1_inline true'
has "telemetry: skipped checkpoint is flagged as skipped" '  ! checkpoint skipped'
has "telemetry: refused checkpoint is flagged as refused" '  ! checkpoint refused'
has "telemetry: a skipped checkpoint is not reported as refused" '- #2: phase1 iterations=5; gate passes=3; checks=fail; checkpoint=skipped; retries=0'
has "telemetry: blocker text cannot spoof a telemetry key" 'checkpoint=skipped'
hasnt "telemetry: clean states carry no flag" '! gate_state clean'
has "telemetry: repeated refusals are a run-level note" 'run-level note: checkpoint refused on 2 issues'
has "telemetry: skipped checkpoint is a run-level note" 'run-level note: checkpoint skipped on 1 issue(s)'
has "telemetry: totals" 'totals: phase1 iterations=9; gate passes=4'

# --- Review profile ----------------------------------------------------------------------
reset; scope 1 2 3 4
issue 1 done; result 1 merged 1 converged false 1 clean pass created prose null
issue 2 done; result 2 merged 1 converged false 1 clean pass created revoked null
issue 3 done; result 3 merged 1 converged false 1 clean pass created standard null
issue 4 blocked
printf 'prose flag\n' > "$S/issue-1/profile"; printf 'prose escalation\n' > "$S/issue-2/profile"
printf 'prose flag\n' > "$S/issue-3/profile"; printf 'prose flag\n' > "$S/issue-4/profile"
run "$S" 3
has "profile: flag -> prose" 'review profile: prose (flag) → prose'
has "profile: escalation -> revoked" 'review profile: prose (escalation) → revoked'
has "profile: flag -> standard" 'review profile: prose (flag) → standard'
has "profile: no result -> no result recorded" 'review profile: prose (flag) → no result recorded'

# --- Actual vs. estimate -----------------------------------------------------------------
reset; scope 1 2 3 4 5
issue 1 done; result 1 merged 2 converged false 1 clean pass created standard null          # 2 + 4 = 6
issue 2 done; result 2 merged 3 converged true 2 clean pass created standard null           # inline: 1 + 0 = 1
issue 3 failed                                                                              # no result: 2
issue 4 pending                                                                             # not dispatched
issue 5 skipped; result 5 failed 4 converged false 4 clean none created standard null        # not dispatched
printf '2\n' > "$S/issue-1/retries"; printf 'junk\n' > "$S/issue-3/retries"
run "$S" 3
# issue 1: (1+2) implementers + (1+2) explore + 2*2 reviewers = 10; issue 2: 1 implementer; issue 3: 2
has "actual: agent arithmetic with retries, inline and no result" 'Actual agents: 13 (estimate: 20–60); actual Codex gate passes: 3 (estimate: 5–15)'
has "undispatched issues carry no telemetry" '- #5: not dispatched (skipped)'
has "actual: caveat follows" 'Caveat: best-effort; it can under- or overcount.'
has "retries: a non-numeric retries file counts as 0" '- #3: no result recorded (retries=0)'
run "$S" 2 --gateless
has "actual: gateless estimate is 0" 'actual Codex gate passes: 3 (estimate: 0)'
run "$S" 2
has "actual: estimate follows MAX_CODEX_ITERATIONS" '(estimate: 5–10)'

# --- Hung after merge ---------------------------------------------------------------------
reset; scope 1 2
issue 1 done; clean_result 1; printf 'hung\n' > "$S/issue-1/outcome"
printf 'implementer hung (no completion): progress unchanged for 47m\n' > "$S/issue-1/error"
issue 2 failed; printf 'hung\n' > "$S/issue-2/outcome"; printf 'implementer hung (no completion): progress unchanged for 31m\n' > "$S/issue-2/error"
run "$S" 3
has "hung + done -> stopped as hung after merge" '#1: stopped as hung after merge: `implementer hung (no completion): progress unchanged for 47m`; classified done'
hasnt "hung + failed -> no after-merge note (the error is verbatim in the table)" '#2: stopped as hung after merge'
has "hung + failed -> error verbatim" '`implementer hung (no completion): progress unchanged for 31m`'

# --- Numbers are decimal, titles are unescaped, odd statuses are contained ------------------
reset; scope 1 2 3
issue 1 done 'A \u0026 B \u0060 \u005c \u007f \u00e9'; result 1 merged 09 converged false 08 clean pass created standard null
printf '08\n' > "$S/issue-1/retries"
issue 2 'a|b'; clean_result 2
issue 3 done; result 3 merged 99999999999999999999 converged false 1 clean pass created standard null
run "$S" 3
rc_is "leading zeros and huge numbers: exit 0" 0
has "leading-zero retries and counts do not abort the loop" '- #1: phase1 iterations=09; gate passes=08; checks=pass; checkpoint=created; retries=8'
has "later issues still print after a leading-zero value" '| #2 | unknown |'
has "\\u escapes in a title are decoded and sanitized" 'A & B '"'"' / '
has "a huge phase1_iterations counts as 0" 'totals: phase1 iterations=11; gate passes=10'
# agents: issue 1 (1+8)*2 + 2*9 = 36; issue 2: 2 + 2*2 = 6; issue 3: 2 -> 44
has "agent arithmetic is decimal" 'Actual agents: 44 '
run "$S" 1000000;                 rc_is "oversized max-codex-iterations -> exit 2" 2

# --- Posted text is enumerated or sanitized ---------------------------------------------------
reset; scope 1 1 2
issue 1 blocked; result 1 blocker 1 '[x](http://e)' false 1 '@team' '[y](z)' '@org' standard null
issue 2 'a|b'
run "$S" 3
has "free-form telemetry values print as ?" '- #1: phase1 iterations=1; gate passes=1; checks=?; checkpoint=?; retries=0'
hasnt "an injected link never reaches the output" 'http://e'
hasnt "an injected mention never reaches the output" '@team'
has "a status outside the word set is unknown" '| #2 | unknown |'
has "duplicate scope entries count once" '(estimate: 8–24)'

# --- A spaced one-line result.json reads like the compact one ------------------------------
reset; scope 1
issue 1 blocked
printf '{"outcome": "blocker", "pr": 5, "branch": "b", "worktree": "/w x", "phase1_iterations": 2, "phase1_inline": false, "phase1_state": "converged", "gate_passes": 1, "gate_state": "clean", "checks": "none", "checkpoint": "skipped", "security_lens": false, "review_profile": "standard", "blocker": "a, \\"checkpoint\\": \\"refused\\""}\n' > "$S/issue-1/result.json"
run "$S" 3
has "spaced result.json is read" '- #1: phase1 iterations=2; gate passes=1; checks=none; checkpoint=skipped; retries=0'
has "spaced result.json still flags a skipped checkpoint" '  ! checkpoint skipped'

# --- Key order does not matter: only the blocker member is dropped -------------------------
T='"phase1_iterations":2,"phase1_inline":false,"phase1_state":"converged","gate_passes":1,"gate_state":"clean","checks":"none","checkpoint":"skipped","security_lens":false,"review_profile":"standard"'
reorder() {  # reorder LABEL JSON
  reset; scope 1; issue 1 blocked
  printf '%s\n' "$2" > "$S/issue-1/result.json"
  run "$S" 3
  has "$1" '- #1: phase1 iterations=2; gate passes=1; checks=none; checkpoint=skipped; retries=0'
}
reorder "blocker first" "{\"blocker\":\"x, \\\"checkpoint\\\": \\\"refused\\\"\",\"outcome\":\"blocker\",\"pr\":5,\"branch\":\"b\",\"worktree\":\"/w\",$T}"
reorder "blocker in the middle" "{\"outcome\":\"blocker\",\"worktree\":\"/w\",\"blocker\":\"a, b\",$T,\"pr\":5}"
reorder "blocker null before the telemetry" "{\"outcome\":\"blocker\",\"worktree\":\"/w\",\"blocker\":null,$T}"
reorder "blocker as an object" "{\"outcome\":\"blocker\",\"blocker\":{\"checkpoint\":\"refused\",\"a\":[1,{\"b\":\"}\"}]},\"worktree\":\"/w\",$T}"
reorder "blocker last" "{\"outcome\":\"blocker\",\"worktree\":\"/w\",$T,\"blocker\":\"z\"}"

# --- Missing per-issue pieces never fail --------------------------------------------------
reset; scope 7
run "$S" 3
rc_is "no issue directory at all -> exit 0" 0
has "no issue directory -> status unknown" '| #7 | unknown |  |  |  |'
has "no issue directory -> no result recorded" '- #7: no result recorded (retries=0)'

# --- pr-shape section (stub classify.sh) ------------------------------------------------------
cat > "$TMP/classify-stub.sh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$STUB_LOG"
case $2 in
  1) printf 'pr #5 feat/issue-1-x non-draft (checkpoint)\n' ;;
  2) printf 'branch feat/issue-2-x no open PR (only merged or closed PRs: #6)\n' ;;
  3) printf 'pr #7 fork/issue-3-x shape unknown (branch not on origin)\n' ;;
  4) echo "gh exploded" >&2; exit 1 ;;
  7) printf 'pr #8 feat/issue-7-x@team draft (checkpoint)\nbranch `evil` | [l](http://e) no open PR\n' ;;
  8) printf 'bad `tick` @org\nsecond | line\n' >&2; exit 1 ;;
  *) printf 'none\n' ;;
esac
EOF
export STUB_LOG="$TMP/stub.log" CLASSIFY_SCRIPT="$TMP/classify-stub.sh"
reset; scope 1 2 3 4 5 6; : > "$STUB_LOG"
issue 1 blocked; result 1 blocker 1 converged false 1 clean pass refused standard '"x"'
issue 2 failed; issue 3 skipped; issue 4 closed-externally; issue 5 done; clean_result 5; issue 6 ready
run "$S" 3 main
rc_is "pr-shape: exit 0" 0
has "pr-shape: a non-draft PR names its checkpoint value" 'non-draft: checkpoint=refused'
has "pr-shape: merged-or-closed branch warns of unmerged work" 'the branch may hold unmerged work'
has "pr-shape: a fork PR is never the runner's" "a fork's PR, never the runner's"
has "pr-shape: a failing classifier is listed, not fatal" '#4: PR shape unknown: `gh exploded`'
if grep -qx 'pr-shape 1 main' "$STUB_LOG" && grep -qx 'pr-shape 4 main' "$STUB_LOG" \
   && ! grep -qE 'pr-shape (5|6) ' "$STUB_LOG"; then
  ok "pr-shape: runs for blocked/failed/skipped/closed-externally only"
else
  err "pr-shape: unexpected classifier calls:"; sed 's/^/  > /' "$STUB_LOG" >&2
fi
reset; scope 7 8; issue 7 blocked; issue 8 failed
run "$S" 3 main
has "pr-shape: each hostile shape line is a code span" '  `branch '"'"'evil'"'"' \| [l](http://e) no open PR`'
has "pr-shape: a hostile branch name stays inside a code span" '  `pr #8 feat/issue-7-x@team draft (checkpoint)`'
has "pr-shape: a hostile stderr line is a code span" '#8: PR shape unknown: `bad '"'"'tick'"'"' @org`'
hasnt "pr-shape: only the first stderr line is used" 'second'
: > "$STUB_LOG"
run "$S" 3
hasnt "no default branch -> no pr-shape section" 'Unfinished PRs'
[ ! -s "$STUB_LOG" ] && ok "no default branch -> classifier never called" || err "classifier called without a default branch"
unset CLASSIFY_SCRIPT

# --- Usage errors ---------------------------------------------------------------------------
reset; scope 1; issue 1 done
run;                              rc_is "no arguments -> exit 2" 2
run "$S";                         rc_is "missing max-codex-iterations -> exit 2" 2
run "$S" 0;                       rc_is "max-codex-iterations 0 -> exit 2" 2
run "$S" x;                       rc_is "non-numeric max-codex-iterations -> exit 2" 2
run "$S" 3 --bogus;               rc_is "unknown option -> exit 2" 2
run "$S" 3 main extra;            rc_is "two default branches -> exit 2" 2
run "$TMP/no-such-dir" 3;         rc_is "missing state dir -> exit 2" 2
rm -f "$S/scope.txt"
run "$S" 3;                       rc_is "missing scope.txt -> exit 2" 2
: > "$S/scope.txt"
run "$S" 3;                       rc_is "empty scope.txt -> exit 2" 2
printf '1\nabc\n' > "$S/scope.txt"
run "$S" 3;                       rc_is "non-numeric scope entry -> exit 2" 2
printf '*\n' > "$S/scope.txt"
run "$S" 3;                       rc_is "a glob in scope.txt is refused, never expanded -> exit 2" 2
printf '1 \r\n' > "$S/scope.txt"
run "$S" 3;                       rc_is "CRLF and trailing space in scope.txt tolerated -> exit 0" 0

if [ "$fail" -ne 0 ]; then
  printf '\ntest-summary: FAILED\n' >&2
  exit 1
fi
printf '\ntest-summary: OK\n'
