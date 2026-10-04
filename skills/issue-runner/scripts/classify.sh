#!/usr/bin/env bash
#
# classify.sh — issue-runner's two classifications of what an unfinished or
# returned issue *is*: Step 3 item 5's merge proof (`result`) and Step 5's
# unfinished-PR shape (`pr-shape`). Two helpers for Step 3 item 4 live here
# too: the hang threshold (`hang`) and a stopped implementer's worktree
# (`worktree`). SKILL.md runs this script and obeys its
# output; the rules live here, and the rationale in REFERENCE.md ("Why `done`
# needs merge proof", "Why the implementer opens a draft PR right after the
# plan").
#
# Run from the target repository (the orchestrator's own cwd, never a
# worktree): the `gh` calls resolve the repository from it, and `pr-shape`
# fetches and probes its `origin`.
#
# Usage:
#   classify.sh result <N> <issue-dir>
#     <issue-dir> is $STATE_DIR/issue-N. Every input is read from a file there,
#     so the call is the same on every run and re-running it (a retry after a
#     failed query, Step 4's "Mark `done`") classifies the same inputs again:
#       worktree  the implementer's worktree path; absent or empty = none known
#                 (never `git -C ""`: it silently reads the cwd)
#       branch    Step 3a's recorded non-contract resume branch; absent = none
#       outcome   required, one word: merged | ready | blocker | failed —
#                 result.json's `outcome`, or the prose classification of the
#                 final message when that file is absent or unreadable;
#                 hung — stopped by Step 3 item 4; none — crashed
#       blocker   the implementer's `blocker` string or message, or item 4's
#                 hang string, verbatim; absent or empty = none. Untrusted text:
#                 the caller writes it as a file, never on a command line, where
#                 backticks and $(...) would run. Never modified here.
#     It writes `error` (the final error text; removed when there is none).
#     On merge proof (`done P` and `blocked P` below) it also records
#     `merge-oid`: `<merge-commit-oid> <base-branch> <P>`, one line, from the
#     same query that found P. That is the integration hints'
#     ISSUE_RUNNER_REVISION and ISSUE_RUNNER_BASE (docs/integration-rfc.md
#     §8.1). The record is best-effort: a missing or abbreviated oid, or a
#     failed write, removes it and prints a warning on stderr, never a failure.
#     It writes nothing else.
#
#   classify.sh pr-shape <N> <default-branch>
#     for an issue that is not `done` or `ready`: its open PR on the
#     `/issue-N-` branch contract, and its orphan branches (Step 3a probe 3)
#
#   classify.sh hang <N> <issue-dir> <hang-minutes>
#     Step 3 item 4's threshold rule, on <issue-dir>/progress alone: when the
#     file is non-empty and its mtime is more than <hang-minutes> old (`find
#     -mmin +M`), it prints `implementer hung (no completion): progress
#     unchanged for <age>m (--hang-minutes <M>)`, with the age rounded up
#     (GNU stat, else BSD/macOS stat). Otherwise it prints nothing, including
#     when there is no progress file (the relative-silence rule is the
#     orchestrator's). It never writes.
#
#   classify.sh notification <N> <issue-dir>
#     Step 3 item 5's first question: is the completion notification just
#     received final or interim? The caller writes the notification's text to
#     <issue-dir>/notification (a file, never a command line: untrusted text).
#     Prints `final` when <issue-dir>/result.json is readable (one JSON object
#     with an `outcome` of merged/blocker/failed/ready and a non-empty
#     `worktree`, the state-files.md rule), or when the text carries no
#     interim marker. Prints `interim` when result.json is not readable and
#     the host's note `This agent stopped with background work of its own
#     still running` is the file's first line (the caller writes it there,
#     ahead of the message) or the last non-blank line starts `interim:
#     waiting on <what>` (gh-issue's fixed form). A marker anywhere else is
#     quoted text and stays `final`, and so does any message with a line
#     starting `worktree: ` (a real exit; the interim form never has one). It
#     reads only: it writes nothing (not `progress`, `status`,
#     `outcome`, `blocker` or `error`), and on `interim` the caller leaves the
#     issue `implementing` and classifies nothing.
#
#   classify.sh worktree <N> <issue-dir>
#     Step 3 item 4's worktree for a stopped implementer. The first match wins:
#     <issue-dir>/worktree, only while that directory still exists; else the
#     `git worktree list --porcelain` entry whose `locked` line names the agent
#     id in <issue-dir>/agent (`agent-<id>` or bare, matched space-delimited,
#     so an id never matches as a prefix of a longer one); else the first
#     entry on a `/issue-N-` branch. It prints the path and records it in
#     <issue-dir>/worktree (a failed write is a stderr warning, never a lost
#     path), or prints nothing when none is found. Run it from the
#     target repository.
#
# Output — `result` prints exactly one line, `<status> <pr>` (<pr> is the bare
# PR number, or `-`), and leaves the final error in <issue-dir>/error
# (<blocker> below is the `blocker` file's text):
#   done P               CLOSED, and a merged PR P on the proof branch whose
#                        headRefOid is the worktree's HEAD — the only status that
#                        authorizes Step 5's `git branch -D`; no error
#   closed-externally -  CLOSED without that proof (worktree gone, a branch outside
#                        the contract, another head's merged PR); error
#                        `closed without a merged implementer PR`
#   blocked P            open, with that proof; error `PR #P merged but issue still
#                        open — confirm and close by hand`, followed by `: <blocker>`
#                        when there is one, except for outcome `merged`
#   blocked -            open, no proof, outcome `blocker`, worktree real; error is
#                        <blocker>
#   ready P              open, no proof, outcome `ready`, and the first open PR P on
#                        the proof branch is not a draft; no error
#   failed -             open, no proof, and outcome `failed`, `hung` or `none` — or
#                        outcome `blocker` with the worktree gone (an empty or
#                        unreadable branch); error is <blocker>. Outcome `merged`: error
#                        `result.json claims merged but no merged PR on <branch>`;
#                        outcome `ready`: `result.json claims ready but no open,
#                        non-draft PR on <branch>` (<branch> is the worktree's
#                        branch, `(none)` if gone)
#
# `pr-shape` prints one line per open contract PR and per orphan branch, or
# `none` when there is neither:
#   pr #P <branch> draft (checkpoint)                 body still has a `## Plan` heading and the
#                                                     branch holds only the checkpoint
#                                                     commit (1 commit ahead of the
#                                                     default branch)
#   pr #P <branch> draft (implemented, not ready)     any other draft
#   pr #P <branch> non-draft (checkpoint)             the same two shapes on a PR that is
#   pr #P <branch> non-draft (implemented, not ready) not a draft (checkpoint refused, a
#                                                     failed revert, or a crash inside
#                                                     the ready→merge window)
#   pr #P <branch> shape unknown (branch not on origin)
#                                                     an open PR whose head branch origin
#                                                     does not carry (a fork's PR). A fork
#                                                     PR whose branch name origin also
#                                                     carries is not detected: it is shaped
#                                                     from origin's branch like any other
#   branch <B> branch only (no PR)                    a pushed `/issue-N-` branch with no
#                                                     PR at all, in any state (Step 3a's
#                                                     orphan)
#   branch <B> no open PR (only merged or closed PRs: #P …)
#                                                     a pushed branch whose PRs are all
#                                                     merged or closed: it may still hold
#                                                     work nobody merged
#
# Exit status: 0 with the lines above. Non-zero prints nothing on stdout,
# leaves `error` untouched, and is never a classification: 1 — a query failed
# (gh, the fetch, ls-remote, rev-list) or a state file could not be read or
# written: an environment failure; 2 — a usage error (including a missing or
# unknown `outcome`).
#
# Forks: the merge proof is anchored on the worktree's HEAD, so a same-named
# merged PR on another commit proves nothing (one on that same commit merged
# identical content). No query filters on `isCrossRepository`: when `origin` is
# itself a fork of the repository gh targets, every implementer PR is
# cross-repository. The `ready` check keeps the spec's unanchored form.
#
# Dependencies: bash 3.2, coreutils, grep, awk, git, gh (its built-in --jq only
# projects fields; every decision is made here).

set -u
set +e +o pipefail   # every exit status below is read explicitly

die()   { echo "classify.sh: $1" >&2; exit 1; }
usage() { echo "classify.sh: $1" >&2; exit 2; }

MODE=${1:-}
N=${2:-}
case $MODE in result|pr-shape|hang|notification|worktree) ;; *) usage "unknown mode '$MODE' (expected result, pr-shape, hang, notification or worktree)" ;; esac
case $N in ''|*[!0-9]*|0*) usage "issue number must be a positive integer, got '${N}'" ;; esac

# finish STATUS PR ERROR: rewrite the error file (through a temp file in the
# same directory, so a failed write never leaves it half-written), then print.
finish() {
  local tmp
  if [ -n "$3" ]; then
    tmp="$ERROR_FILE.classify.$$"
    # shellcheck disable=SC2015 # intended: clean up and die when either the write or the mv fails
    printf '%s\n' "$3" > "$tmp" && mv -f "$tmp" "$ERROR_FILE" \
      || { rm -f "$tmp"; die "cannot write $ERROR_FILE"; }
  else
    rm -f "$ERROR_FILE" || die "cannot remove $ERROR_FILE"
  fi
  echo "$1 $2"
}

# read_state NAME: a state file's content, "" when absent; exit 1 when unreadable
read_state() {
  [ -e "$DIR/$1" ] || return 0
  cat "$DIR/$1" || die "cannot read $DIR/$1"
}

# record_merge_oid P OID BASE: best-effort; never fails the classification.
record_merge_oid() {
  local tmp="$DIR/merge-oid.classify.$$"
  if printf '%s' "$2" | grep -qE '^([0-9a-f]{40}|[0-9a-f]{64})$' && [ -n "$3" ] \
     && printf '%s %s %s\n' "$2" "$3" "$1" > "$tmp" 2>/dev/null && mv -f "$tmp" "$DIR/merge-oid" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" "$DIR/merge-oid" 2>/dev/null
  echo "classify.sh: warning: no merge-oid recorded for PR #$1 (merge commit '${2:-}', base '${3:-}')" >&2
  return 0
}

classify_result() {
  local wt recorded outcome error
  local state wt_branch="" wt_head="" proof_branch="" merged_pr="" merged_oid="" merged_base="" list pr draft hit
  [ -d "$DIR" ] || usage "not a directory: $DIR"
  wt=$(read_state worktree) || exit 1
  recorded=$(read_state branch) || exit 1
  outcome=$(read_state outcome) || exit 1
  error=$(read_state blocker) || exit 1
  outcome=$(printf '%s' "$outcome" | tr -d '[:space:]')
  case $outcome in merged|ready|blocker|failed|hung|none) ;; *) usage "missing or unknown outcome '$outcome' in $DIR/outcome" ;; esac

  state=$(gh issue view "$N" --json state --jq .state) || die "cannot query the state of issue #$N"
  case $state in OPEN|CLOSED) ;; *) die "unexpected state '$state' for issue #$N" ;; esac

  if [ -n "$wt" ]; then
    wt_branch=$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null) || wt_branch=""
    wt_head=$(git -C "$wt" rev-parse HEAD 2>/dev/null) || wt_head=""
  fi
  # The proof branch: the /issue-N- contract (gh-issue Step 4), or the branch
  # Step 3a recorded for a keyword-only resume. Never empty into the query:
  # `gh pr list --head ""` applies no filter and returns unrelated merged PRs.
  case $wt_branch in */issue-"$N"-*) proof_branch=$wt_branch ;; esac
  [ -n "$wt_branch" ] && [ "$wt_branch" = "$(printf '%s' "$recorded" | tr -d '[:space:]')" ] && proof_branch=$wt_branch
  if [ -n "$proof_branch" ] && [ -n "$wt_head" ]; then
    list=$(gh pr list --head "$proof_branch" --state merged --json number,headRefOid,mergeCommit,baseRefName \
      --jq '.[] | "\(.number) \(.headRefOid) \(.mergeCommit.oid // "-") \(.baseRefName)"') || die "cannot list merged PRs on $proof_branch"
    # Anchored on this attempt's commit: a previous run's merged PR on a
    # recurring branch name is not this attempt's proof.
    hit=$(printf '%s\n' "$list" | awk -v h="$wt_head" '$2 == h { print $1, $3, $4; exit }')
    read -r merged_pr merged_oid merged_base <<EOF_HIT
$hit
EOF_HIT
  fi
  [ -n "$merged_pr" ] && record_merge_oid "$merged_pr" "$merged_oid" "$merged_base"

  if [ "$state" = CLOSED ]; then
    if [ -n "$merged_pr" ]; then finish "done" "$merged_pr" ""
    else finish closed-externally - "closed without a merged implementer PR"; fi
    return
  fi
  if [ -n "$merged_pr" ]; then
    local msg="PR #$merged_pr merged but issue still open — confirm and close by hand"
    [ "$outcome" != merged ] && [ -n "$error" ] && msg="$msg: $error"
    finish blocked "$merged_pr" "$msg"
    return
  fi
  case $outcome in
    blocker)
      if [ -n "$wt_branch" ]; then finish blocked - "$error"; else finish failed - "$error"; fi ;;
    failed|hung|none)
      finish failed - "$error" ;;
    merged)
      finish failed - "result.json claims merged but no merged PR on ${wt_branch:-(none)}" ;;
    ready)
      if [ -n "$proof_branch" ]; then
        # The spec's check, unchanged: the first open PR on the proof branch must
        # be non-draft. It is not anchored on HEAD (REFERENCE.md: a follow-up).
        list=$(gh pr list --head "$proof_branch" --state open --json number,isDraft \
          --jq '.[] | "\(.number) \(.isDraft)"') || die "cannot list open PRs on $proof_branch"
        pr=$(printf '%s\n' "$list" | awk 'NF { print $1; exit }')
        draft=$(printf '%s\n' "$list" | awk 'NF { print $2; exit }')
        if [ -n "$pr" ] && [ "$draft" = false ]; then finish ready "$pr" ""; return; fi
      fi
      finish failed - "result.json claims ready but no open, non-draft PR on ${wt_branch:-(none)}" ;;
  esac
}

classify_pr_shape() {
  local default="$1" list prs out="" p b view draft body count shape refs rc ref any
  [ -n "$default" ] || usage "empty default branch"
  list=$(gh pr list --state open --limit 1000 --json number,headRefName,isDraft \
    --jq '.[] | "\(.number) \(.headRefName) \(.isDraft)"') || die "cannot list open PRs"
  prs=$(printf '%s\n' "$list" | awk -v pat="/issue-$N-" 'NF && index($2, pat) { print $1, $2 }')
  # Explicit destination: a single-branch clone would fetch only into FETCH_HEAD,
  # and a stale default branch inflates the count below.
  if [ -n "$prs" ]; then
    git fetch -q origin "+refs/heads/$default:refs/remotes/origin/$default" </dev/null 2>/dev/null \
      || die "cannot fetch origin/$default"
  fi

  while read -r p b; do
    [ -n "$p" ] || continue
    # A PR whose head branch is not on origin (a same-named fork PR) cannot be
    # shaped; it gets its own line rather than hiding the others.
    if ! git ls-remote --exit-code --heads origin "refs/heads/$b" >/dev/null 2>&1 </dev/null; then
      git ls-remote --heads origin >/dev/null 2>&1 </dev/null || die "cannot reach origin"
      out="${out}pr #$p $b shape unknown (branch not on origin)"$'\n'
      continue
    fi
    git fetch -q origin "+refs/heads/$b:refs/remotes/origin/$b" </dev/null 2>/dev/null || die "cannot fetch origin/$b"
    count=$(git rev-list --count "origin/$default..origin/$b" </dev/null 2>/dev/null) || die "cannot count origin/$default..origin/$b"
    view=$(gh pr view "$p" --json isDraft,body --jq '.isDraft, .body' </dev/null) || die "cannot view PR #$p"
    draft=$(printf '%s\n' "$view" | head -n 1)
    body=$(printf '%s\n' "$view" | tail -n +2 | tr -d '\r')
    shape="implemented, not ready"
    if [ "$count" = 1 ] && printf '%s\n' "$body" | grep -qE '^## Plan([[:space:]]|$)'; then shape=checkpoint; fi
    case $draft in
      true)  out="${out}pr #$p $b draft ($shape)"$'\n' ;;
      false) out="${out}pr #$p $b non-draft ($shape)"$'\n' ;;
      *)     die "unexpected isDraft '$draft' for PR #$p" ;;
    esac
  done <<EOF_PRS
$prs
EOF_PRS

  # Probe 3 (Step 3a): exit 2 = no such branch, 0 = hits, anything else = the
  # probe itself failed — never read as "no branch".
  refs=$(git ls-remote --exit-code --heads origin "*/issue-$N-*" 2>/dev/null); rc=$?
  case $rc in
    0) while read -r _ ref; do
         b=${ref#refs/heads/}
         [ -n "$b" ] || continue
         printf '%s\n' "$prs" | awk -v b="$b" '$2 == b { f = 1 } END { exit !f }' && continue
         any=$(gh pr list --head "$b" --state all --limit 1000 --json number --jq '.[] | .number' </dev/null) \
           || die "cannot list PRs on $b"
         if [ -n "$any" ]; then
           out="${out}branch $b no open PR (only merged or closed PRs: $(printf '%s' "$any" | awk 'NF { printf "%s#%s", (n++ ? " " : ""), $1 }'))"$'\n'
         else
           out="${out}branch $b branch only (no PR)"$'\n'
         fi
       done <<EOF_REFS
$refs
EOF_REFS
       ;;
    2) ;;
    *) die "probe 3 failed (git ls-remote exit $rc)" ;;
  esac

  if [ -n "$out" ]; then printf '%s' "$out"; else echo none; fi
}

# classify_hang MINUTES: Step 3 item 4's threshold rule on $DIR/progress.
classify_hang() {
  local p="$DIR/progress" mtime
  [ -s "$p" ] && [ -n "$(find "$p" -mmin +"$1" 2>/dev/null)" ] || return 0
  # GNU stat first, BSD/macOS stat as the fallback (the same fallback run-state.sh uses).
  mtime=$(stat -c %Y "$p" 2>/dev/null || stat -f %m "$p")
  # Round up: the find test is strictly "more than".
  echo "implementer hung (no completion): progress unchanged for $(( ($(date +%s) - mtime + 59) / 60 ))m (--hang-minutes $1)"
}

# result_readable FILE: state-files.md's "readable" rule: the file is exactly one
# well-formed JSON document (RFC 8259 grammar, a recursive-descent check in awk:
# nothing may follow it, no trailing commas, matched delimiters) that is an
# object whose top-level `outcome` is the string merged, blocker, failed or
# ready and whose top-level `worktree` is a non-empty string. A nested
# `outcome` never counts. Exit 0 = readable.
result_readable() {
  [ -s "$1" ] || return 1
  LC_ALL=C awk '
    function ws() { while (p <= n && index(" \t\r\n", substr(s, p, 1))) p++ }
    function uni(h,   i, v) {
      for (i = 1; i <= 4; i++) v = v * 16 + index("0123456789abcdef", tolower(substr(h, i, 1))) - 1
      return (v > 0 && v < 128) ? sprintf("%c", v) : "\001"
    }
    function str(   c, e, k) {
      p++; buf = ""
      while (p <= n) {
        c = substr(s, p, 1)
        if (c == "\"") { p++; return 1 }
        if (c == "\\") {
          e = substr(s, p + 1, 1)
          if (e != "" && (k = index("\"\\/bfnrt", e))) { buf = buf substr("\"\\/\b\f\n\r\t", k, 1); p += 2; continue }
          if (e == "u" && substr(s, p + 2, 4) ~ /^[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]$/) { buf = buf uni(substr(s, p + 2, 4)); p += 6; continue }
          return 0
        }
        if (c < " ") return 0
        buf = buf c; p++
      }
      return 0
    }
    function value(depth,   r) {
      ws(); c0 = substr(s, p, 1)
      if (c0 == "{") return object(depth)
      if (c0 == "[") return array(depth)
      if (c0 == "\"") return str()
      r = substr(s, p)
      if (match(r, /^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?/)) { p += RLENGTH; return 1 }
      if (match(r, /^(true|false|null)/)) { p += RLENGTH; return 1 }
      return 0
    }
    function array(depth,   c) {
      p++; ws()
      if (substr(s, p, 1) == "]") { p++; return 1 }
      while (1) {
        if (!value(depth + 1)) return 0
        ws(); c = substr(s, p, 1)
        if (c == ",") { p++; continue }
        if (c == "]") { p++; return 1 }
        return 0
      }
    }
    function object(depth,   c, key, isstr) {
      p++; ws()
      if (substr(s, p, 1) == "}") { p++; return 1 }
      while (1) {
        ws()
        if (substr(s, p, 1) != "\"" || !str()) return 0
        key = buf; ws()
        if (substr(s, p, 1) != ":") return 0
        p++; ws(); isstr = (substr(s, p, 1) == "\"")
        if (!value(depth + 1)) return 0
        if (depth == 0) { if (isstr) val[key] = buf; else delete val[key] }
        ws(); c = substr(s, p, 1)
        if (c == ",") { p++; continue }
        if (c == "}") { p++; return 1 }
        return 0
      }
    }
    { s = s $0 "\n" }
    END {
      n = length(s); p = 1; ws()
      ok = (substr(s, p, 1) == "{") && object(0)
      ws()
      exit !(ok && p > n && val["outcome"] ~ /^(merged|blocker|failed|ready)$/ && length(val["worktree"]) > 0)
    }' "$1"
}

# classify_notification: final or interim (see the header). Read-only.
classify_notification() {
  if result_readable "$DIR/result.json"; then
    echo final; return 0
  fi
  # No readable result and no notification file: the orchestrator's write failed
  # or never ran. That is an error, never a verdict (fail-open would be #80).
  [ -r "$DIR/notification" ] || die "notification: $DIR/notification is missing or unreadable"
  # The markers are positional, so a final message that merely quotes one (a
  # blocker report, the Step 10 text) stays final: the host's note is the first
  # line, the implementer's fixed form the last non-blank line.
  local first last
  # A final message always carries a `worktree:` line (gh-issue's dispatch); the
  # interim form never does. So even with the host's note leading, a message
  # with that line is a real exit (a blocker whose result.json write failed).
  if [ -s "$DIR/notification" ] && tr -d '\r' < "$DIR/notification" | grep -aq '^worktree: '; then
    echo final; return 0
  fi
  first=$(head -n 1 "$DIR/notification" 2>/dev/null | tr -d '\r')
  last=$(tr -d '\r' < "$DIR/notification" 2>/dev/null | grep -av '^[[:space:]]*$' | tail -n 1)
  case $first in
    "This agent stopped with background work of its own still running"*) echo interim; return 0 ;;
  esac
  case $last in
    "interim: waiting on "?*) echo interim ;;
    *) echo final ;;
  esac
}

# classify_worktree: Step 3 item 4's worktree resolution for a stopped implementer.
classify_worktree() {
  local wt ag
  wt=$(cat "$DIR/worktree" 2>/dev/null); [ -d "$wt" ] || wt=""   # a recorded path counts only while it exists
  if [ -z "$wt" ]; then
    ag=$(cat "$DIR/agent" 2>/dev/null); ag=${ag#agent-}   # bare id, whichever form was recorded
    wt=$(git worktree list --porcelain | awk -v pat="/issue-$N-" -v ag=" agent-$ag " -v have="$ag" '
      /^worktree /{w=substr($0,10)}
      have!=""&&/^locked /&&index($0,ag){a=w}   # space-delimited: exact id, not a prefix of a longer one
      /^branch /&&index($0,pat)&&b==""{b=w}
      END{print (a!=""?a:b)}')
  fi
  [ -n "$wt" ] || return 0
  printf '%s\n' "$wt"   # printed first: a failed record never hides the worktree
  printf '%s\n' "$wt" > "$DIR/worktree" 2>/dev/null || echo "classify.sh: warning: cannot write $DIR/worktree" >&2
}

case $MODE in
  result)
    [ $# -ge 3 ] && [ -n "$3" ] || usage "result needs <N> <issue-dir>"
    DIR=${3%/}; ERROR_FILE="$DIR/error"
    classify_result ;;
  pr-shape)
    [ $# -ge 3 ] || usage "pr-shape needs <N> <default-branch>"
    classify_pr_shape "$3" ;;
  hang)
    [ $# -ge 4 ] && [ -n "$3" ] || usage "hang needs <N> <issue-dir> <hang-minutes>"
    case $4 in ''|*[!0-9]*|0*) usage "hang minutes must be a positive integer, got '$4'" ;; esac
    DIR=${3%/}
    classify_hang "$4" ;;
  notification)
    [ $# -ge 3 ] && [ -n "$3" ] || usage "notification needs <N> <issue-dir>"
    DIR=${3%/}
    [ -d "$DIR" ] || usage "not a directory: $DIR"
    classify_notification ;;
  worktree)
    [ $# -ge 3 ] && [ -n "$3" ] || usage "worktree needs <N> <issue-dir>"
    DIR=${3%/}
    [ -d "$DIR" ] || usage "not a directory: $DIR"
    classify_worktree ;;
esac
