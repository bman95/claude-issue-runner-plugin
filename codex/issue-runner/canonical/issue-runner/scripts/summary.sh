#!/usr/bin/env bash
#
# summary.sh — issue-runner Step 5's closing summary: the table, the per-issue
# telemetry and the actual-vs-estimated spend line, printed from the files in
# $STATE_DIR so the orchestrator relays them instead of paraphrasing them.
# SKILL.md runs this script and obeys its output; the rules live here, and the
# rationale in REFERENCE.md ("Why the Step 5 summary is a script").
#
# Run from the target repository (the orchestrator's own cwd) when the optional
# <default-branch> is given: `classify.sh pr-shape` resolves the repository from
# it. Without that argument nothing here touches git or gh.
#
# Usage:
#   summary.sh <state-dir> <max-codex-iterations> [--gateless] [<default-branch>]
#     <state-dir>             $STATE_DIR; every in-scope issue is read from its
#                             scope.txt (one number per line), never from a
#                             directory listing
#     <max-codex-iterations>  this run's MAX_CODEX_ITERATIONS (positive integer)
#     --gateless              the run has no Codex gate: the gate-pass estimate
#                             is 0 instead of N-N*MAX_CODEX_ITERATIONS
#     <default-branch>        adds `classify.sh pr-shape` (the sibling script,
#                             or $CLASSIFY_SCRIPT) for every blocked, failed,
#                             skipped or closed-externally issue
#
# Per issue it reads, from <state-dir>/issue-N/: `status` (absent = unknown),
# `details.json` (the title), `error`, `progress` (first line, shown for
# failed issues), `outcome` (a hung implementer is `hung`), `retries` (absent or
# not a number = 0), `profile` and `result.json`. A result.json is readable only
# when it is one JSON object on one line with an `outcome` of merged, blocker,
# failed or ready and a non-empty `worktree`; anything else is `no result
# recorded`, never zeros. Telemetry comes only from that file. Every free-text
# cell (title, error, progress) is sanitized for Markdown: newlines and tabs
# collapse to spaces, backticks become ', backslashes become /, `|` becomes
# `\|`, and a non-empty cell is wrapped in a code span.
#
# Output, in order: `## Summary table`, `## Telemetry` (per-issue lines, `!`
# flag lines for anything that needs a human, totals), the one-line `Actual
# agents: <A> (estimate: <N*4>–<N*12>); actual Codex gate passes: <P>
# (estimate: <G>)` and its caveat. <A> counts, over every issue not `pending`
# or `skipped` (dispatched at least once), 1 + retries implementers, 1 +
# retries Explore helpers (none when phase1_inline is true) and 2 ×
# phase1_iterations reviewers (none when phase1_inline is true or no result is
# recorded); <P> sums gate_passes. N is scope.txt's issue count.
#
# Exit status: 0 on success; 2 a usage error or an unreadable/empty scope.txt.
# A missing or unreadable per-issue file is never an error (it prints as absent).
#
# Dependencies: bash 3.2, coreutils, grep, sed, awk.

set -u
set +e +o pipefail   # every exit status below is read explicitly

usage() { echo "summary.sh: $1" >&2; exit 2; }

STATE_DIR=${1:-}
MAXG=${2:-}
[ -n "$STATE_DIR" ] || usage "usage: summary.sh <state-dir> <max-codex-iterations> [--gateless] [<default-branch>]"
[ -d "$STATE_DIR" ] || usage "state dir '$STATE_DIR' is not a directory"
case $MAXG in ''|*[!0-9]*|0*) usage "max-codex-iterations must be a positive integer, got '${MAXG}'" ;; esac
shift 2
GATELESS=0 DEFAULT_BRANCH=""
for a in "$@"; do
  case $a in
    --gateless) GATELESS=1 ;;
    '') usage "empty argument" ;;
    -*) usage "unknown option '$a'" ;;
    *) [ -z "$DEFAULT_BRANCH" ] || usage "more than one default branch given"; DEFAULT_BRANCH=$a ;;
  esac
done

SCOPE_FILE="$STATE_DIR/scope.txt"
[ -r "$SCOPE_FILE" ] || usage "cannot read $SCOPE_FILE"
SCOPE=$(tr -s ' \t\r\n' '\n\n\n\n' < "$SCOPE_FILE" | grep -v '^$')
[ -n "$SCOPE" ] || usage "$SCOPE_FILE lists no issues"
for n in $SCOPE; do
  case $n in *[!0-9]*|0*) usage "scope.txt entry '$n' is not a positive integer" ;; esac
done

CLASSIFY=${CLASSIFY_SCRIPT:-$(dirname "$0")/classify.sh}
NL='
'
SHAPE_ERR=""
if [ -n "$DEFAULT_BRANCH" ]; then
  SHAPE_TMP=$(mktemp -d 2>/dev/null) || usage "cannot create a temporary directory"
  trap 'rm -rf "$SHAPE_TMP"' EXIT
  SHAPE_ERR="$SHAPE_TMP/err"
fi

# cell TEXT -> the sanitized code-span cell ('' stays empty).
cell() {
  local t
  t=$(printf '%s' "$1" | tr '\r\n\t' '   ' | tr '`\\' "'/" | sed -e 's/|/\\|/g' -e 's/^ *//' -e 's/ *$//')
  if [ -n "$t" ]; then printf '`%s`' "$t"; fi
}

# rd FILE -> the file's content without trailing newlines; empty when unreadable.
rd() { [ -r "$1" ] && cat "$1" 2>/dev/null; }

# title DETAILS_JSON -> the last top-level "title" string, JSON-unescaped.
title_of() {
  [ -r "$1" ] || return 0
  tr '\n' ' ' < "$1" 2>/dev/null | awk '
    { s = $0; m = "\"title\":\""; last = 0; off = 0
      while ((p = index(substr(s, off + 1), m)) > 0) { off += p + length(m) - 1; last = off }
      if (!last) exit
      rest = substr(s, last + 1); out = ""
      for (i = 1; i <= length(rest); i++) {
        c = substr(rest, i, 1)
        if (c == "\"") break
        if (c == "\\") {
          i++; c = substr(rest, i, 1)
          if (c == "n" || c == "t" || c == "r") c = " "
          else if (c == "b" || c == "f") c = ""
        }
        out = out c
      }
      printf "%s", out }'
}

# jv KEY -> the value of KEY in $RJ (a string without quotes, or a bare token).
jv() {
  printf '%s' "$RJ" | awk -v k="\"$1\":" '
    { p = index($0, k); if (!p) exit
      r = substr($0, p + length(k))
      if (substr(r, 1, 1) == "\"") { r = substr(r, 2); q = index(r, "\""); print (q ? substr(r, 1, q - 1) : r) }
      else { q = match(r, /[,}]/); print (q ? substr(r, 1, q - 1) : r) } }'
}

# load_result DIR -> 0 and sets RJ (the one-line object without its blocker) when readable.
load_result() {
  local f="$1/result.json" raw lines
  RJ=""
  [ -f "$f" ] && [ -r "$f" ] || return 1
  lines=$(awk 'NF { n++ } END { print n + 0 }' "$f" 2>/dev/null)
  [ "$lines" = 1 ] || return 1
  raw=$(awk 'NF { print; exit }' "$f" 2>/dev/null | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
  case $raw in '{'*'}') ;; *) return 1 ;; esac
  RJ=${raw%%,\"blocker\":*}
  case $(jv outcome) in merged|blocker|failed|ready) ;; *) RJ=""; return 1 ;; esac
  case $RJ in *'"worktree":""'*) RJ=""; return 1 ;; esac
  [ -n "$(jv worktree)" ] || { RJ=""; return 1; }
  return 0
}

isnum() { case $1 in ''|*[!0-9]*) return 1 ;; esac; return 0; }

N_SCOPE=0; for n in $SCOPE; do N_SCOPE=$((N_SCOPE + 1)); done
TOTAL_ITER=0 TOTAL_GATE=0 AGENTS=0 REFUSED=0 SKIPPED=0
TABLE="" NOTES="" TELE="" SHAPES=""

for n in $SCOPE; do
  d="$STATE_DIR/issue-$n"
  ckp=""
  status=$(rd "$d/status" | head -1 | tr -d '\r')
  [ -n "$status" ] || status=unknown
  ttl=$(title_of "$d/details.json")
  err=$(rd "$d/error")
  outcome=$(rd "$d/outcome" | head -1 | tr -d '\r')
  retries=$(rd "$d/retries" | head -1 | tr -d ' \r')
  isnum "$retries" || retries=0

  prog=""
  if [ "$status" = failed ]; then
    p1=$(rd "$d/progress" | head -1 | tr -d '\r')
    if [ -n "$p1" ]; then prog=$(cell "$p1"); else prog="no progress recorded"; fi
  fi
  TABLE="$TABLE| #$n | $status | $(cell "$ttl") | $(cell "$err") | $prog |$NL"

  if [ "$outcome" = hung ]; then
    case $status in
      done|blocked|closed-externally)
        NOTES="$NOTES- #$n: stopped as hung after merge: $(cell "$err"); classified $status$NL" ;;
    esac
  fi
  case $status in
    pending|skipped) dispatched=0 ;;
    *) dispatched=1 ;;
  esac

  prof_rt=""
  if [ "$dispatched" = 0 ]; then
    TELE="$TELE- #$n: not dispatched ($status)$NL"
  elif load_result "$d"; then
    it=$(jv phase1_iterations); gp=$(jv gate_passes)
    p1s=$(jv phase1_state); gs=$(jv gate_state); inl=$(jv phase1_inline)
    chk=$(jv checks); ckp=$(jv checkpoint); rp=$(jv review_profile)
    it_n=0; isnum "$it" && it_n=$it
    gp_n=0; isnum "$gp" && gp_n=$gp
    TOTAL_ITER=$((TOTAL_ITER + it_n)); TOTAL_GATE=$((TOTAL_GATE + gp_n))
    TELE="$TELE- #$n: phase1 iterations=${it:-?}; gate passes=${gp:-?}; checks=${chk:-?}; checkpoint=${ckp:-?}; retries=$retries$NL"
    case $p1s in cap-stop|bouncing) TELE="$TELE  ! phase1_state $p1s$NL" ;; esac
    case $gs in degraded|waived|cap-stop|errored|bouncing|unavailable) TELE="$TELE  ! gate_state $gs$NL" ;; esac
    [ "$inl" = true ] && TELE="$TELE  ! phase1_inline true (review ran inline, not by fresh-eyes subagents)$NL"
    case $ckp in
      refused) REFUSED=$((REFUSED + 1)); TELE="$TELE  ! checkpoint refused (the draft-PR checkpoint push or draft creation was refused)$NL" ;;
      skipped) SKIPPED=$((SKIPPED + 1)); TELE="$TELE  ! checkpoint skipped (the implementer did not run the Step 4 checkpoint; not a refused push)$NL" ;;
    esac
    a=$((2 + 2 * retries))
    if [ "$inl" = true ]; then a=$((a - 1 - retries)); else a=$((a + 2 * it_n)); fi
    AGENTS=$((AGENTS + a))
    prof_rt="$rp"
  else
    TELE="$TELE- #$n: no result recorded (retries=$retries)$NL"
    AGENTS=$((AGENTS + 2 + 2 * retries))
  fi

  if [ -s "$d/profile" ]; then
    src=$(head -1 "$d/profile" | tr -d '\r' | awk '{ print $2 }')
    case $prof_rt in
      prose|revoked|standard) eff=$prof_rt ;;
      *) eff="no result recorded" ;;
    esac
    TELE="$TELE  review profile: prose (${src:-?}) → $eff$NL"
  fi

  if [ -n "$DEFAULT_BRANCH" ]; then
    case $status in
      blocked|failed|skipped|closed-externally)
        shape=$(bash "$CLASSIFY" pr-shape "$n" "$DEFAULT_BRANCH" 2>"$SHAPE_ERR")
        rc=$?
        if [ "$rc" -ne 0 ]; then
          SHAPES="$SHAPES- #$n: PR shape unknown: $(head -1 "$SHAPE_ERR" 2>/dev/null)$NL"
        else
          SHAPES="$SHAPES- #$n:$NL$(printf '%s\n' "$shape" | sed 's/^/  /')$NL"
          case $shape in *'no open PR (only merged or closed PRs'*) SHAPES="$SHAPES  the branch may hold unmerged work$NL" ;; esac
          case $shape in *'shape unknown (branch not on origin)'*) SHAPES="$SHAPES  a fork's PR, never the runner's$NL" ;; esac
          case $shape in *'non-draft ('*) SHAPES="$SHAPES  non-draft: checkpoint=${ckp:-no result recorded}; a refused checkpoint is expected, otherwise a failed revert to draft or a death in gh-issue's ready→merge window: an unfinished PR a human could merge by hand$NL" ;; esac
        fi ;;
    esac
  fi
done

if [ "$GATELESS" = 1 ]; then G=0; else G="$N_SCOPE–$((N_SCOPE * MAXG))"; fi

printf '## Summary table\n\n| # | Status | Title | Error | Last progress |\n|---|---|---|---|---|\n%s' "$TABLE"
[ -n "$NOTES" ] && printf '\n%s' "$NOTES"
[ -n "$SHAPES" ] && printf '\nUnfinished PRs:\n%s' "$SHAPES"

printf '\n## Telemetry\n\n%s' "$TELE"
[ "$REFUSED" -ge 2 ] && printf -- '- run-level note: checkpoint refused on %s issues (drafts are probably unavailable on this repository)\n' "$REFUSED"
[ "$SKIPPED" -ge 1 ] && printf -- '- run-level note: checkpoint skipped on %s issue(s): the crash-recovery checkpoint did not run there\n' "$SKIPPED"
printf -- '- totals: phase1 iterations=%s; gate passes=%s\n' "$TOTAL_ITER" "$TOTAL_GATE"

printf '\nActual agents: %s (estimate: %s–%s); actual Codex gate passes: %s (estimate: %s)\n' \
  "$AGENTS" "$((N_SCOPE * 4))" "$((N_SCOPE * 12))" "$TOTAL_GATE" "$G"
printf 'Caveat: best-effort; it can under- or overcount.\n'
exit 0
