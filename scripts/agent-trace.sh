#!/usr/bin/env bash
#
# Extract a deterministic trace digest from a dead implementer's session
# transcript, for the one case issue-runner's Step 3 recovery reconciliation
# already documents: an implementer cannot be resumed in place (unknown to
# the host, a `SendMessage` error, or a transcript aged past
# `cleanupPeriodDays`). This is a fallback of last resort, strictly worse
# than resuming — see skills/issue-runner/REFERENCE.md's rationale note.
#
# Scope, deliberately narrow: chain-of-thought is not recoverable (`thinking`
# blocks are persisted with a signature but carry no text in the general
# case), so this digest never emits one. What it recovers is the dispatch
# prompt, assistant text, and tool calls (name, file path, command) — the
# decisions and the evidence, never `tool_result` bodies, which can carry
# environment dumps or secrets.
#
# Usage: scripts/agent-trace.sh <session-id> <issue-number>
#
# Locates the newest subagents/agent-*.meta.json (by mtime) under
# ~/.claude/projects/*/<session-id>/subagents/ whose "description" is
# exactly "Implement issue #<N>", digests its .jsonl transcript, and appends
# the result under a "## Recovered trace" heading to
# $STATE_DIR/issue-N/guidance.md — the file every Step 3a dispatch already
# reads, so a retry or fresh dispatch picks it up with no further wiring.
# $STATE_DIR is derived exactly as SKILL.md's State block derives it, from
# the repo this script is run from.
#
# Exits non-zero with a message on stderr when no matching transcript
# exists, so callers can fall through to a plain fresh dispatch.
#
# Dependency-free: bash + coreutils/grep/sed/awk only (no jq, no python —
# same convention as the rest of scripts/, see scripts/lint.sh).
set -euo pipefail

usage() { echo "usage: agent-trace.sh <session-id> <issue-number>" >&2; }

SESSION_ID="${1:-}"
ISSUE_N="${2:-}"
if [ -z "$SESSION_ID" ] || [ -z "$ISSUE_N" ]; then usage; exit 1; fi
case "$ISSUE_N" in
  ''|*[!0-9]*) echo "agent-trace: issue number must be a positive integer: '$ISSUE_N'" >&2; exit 1 ;;
esac

PROJECTS_DIR="${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"

# Session transcripts live under <projects-dir>/<encoded-cwd>/<session-id>/ —
# the encoding of cwd is an implementation detail of the host, so search for
# the session id rather than reconstructing it.
SESSION_DIR=""
for d in "$PROJECTS_DIR"/*/"$SESSION_ID"; do
  [ -d "$d/subagents" ] || continue
  SESSION_DIR="$d"
  break
done
if [ -z "$SESSION_DIR" ]; then
  echo "agent-trace: no subagent transcripts for session $SESSION_ID under $PROJECTS_DIR" >&2
  exit 1
fi

# Newest agent-*.meta.json (by mtime) whose description is exactly
# "Implement issue #<N>" — a retried issue can have several; the dead
# implementer's own attempt is the most recent one.
DESC="Implement issue #$ISSUE_N"
META=""
# ls -t: newest first. Globbing failure (no matches) leaves the loop body
# unentered, not an error, under `set -u` since the glob itself is quoted.
for f in $(ls -t "$SESSION_DIR"/subagents/agent-*.meta.json 2>/dev/null); do
  val="$(grep -o '"description":"[^"]*"' "$f" 2>/dev/null | head -1)"
  val="${val#\"description\":\"}"; val="${val%\"}"
  if [ "$val" = "$DESC" ]; then META="$f"; break; fi
done
if [ -z "$META" ]; then
  echo "agent-trace: no agent-*.meta.json under $SESSION_DIR/subagents with description '$DESC'" >&2
  exit 1
fi

AGENT_ID="$(basename "$META" .meta.json)"; AGENT_ID="${AGENT_ID#agent-}"
TRANSCRIPT="$SESSION_DIR/subagents/agent-$AGENT_ID.jsonl"
if [ ! -f "$TRANSCRIPT" ]; then
  echo "agent-trace: meta file found but no transcript at $TRANSCRIPT" >&2
  exit 1
fi

# STATE_DIR, derived exactly like SKILL.md's State block (REPO_KEY formula
# must stay byte-identical to that block, or this writes to the wrong run's
# guidance.md).
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "agent-trace: not inside a git repository" >&2
  exit 1
}
REPO_KEY="$(basename "$REPO_ROOT")-$(printf '%s' "$REPO_ROOT" | git hash-object --stdin | cut -c1-8)"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/issue-runner/$REPO_KEY/state"
GUIDANCE="$STATE_DIR/issue-$ISSUE_N/guidance.md"
mkdir -p "$(dirname "$GUIDANCE")"

# Idempotency guard: the fallback bullet that calls this script (SKILL.md
# Step 3) runs before the issue's status is actually written `pending` in a
# later, separate step — if the hosting session is interrupted in between,
# a same-session re-entry can re-run the same fallback for the same
# still-`implementing` issue and the same dead agent id. Detect that via
# the marker line this script itself writes below, and skip re-appending a
# duplicate digest of the identical transcript.
if [ -f "$GUIDANCE" ] && grep -qF "Digest of agent-$AGENT_ID (session $SESSION_ID," "$GUIDANCE"; then
  echo "agent-trace: digest for agent-$AGENT_ID already present in $GUIDANCE, skipping" >&2
  exit 0
fi

# --- Digest the transcript (awk: one JSON record per line, no embedded raw
# newlines, so per-line substring scanning is safe). Each assistant JSONL
# record carries exactly one content block (thinking, text, or tool_use —
# the harness streams them one block per line), which is what makes the
# targeted `index()` scans below sufficient without a real JSON parser.
# Verified against real subagent transcripts (hundreds of records, no
# multi-block lines found); this is an observed property of the harness's
# streaming format, not a documented guarantee — a line that ever carried
# more than one block would only have its first block matched here, with
# the rest of that line silently skipped rather than erroring. ---
AWK_PROG='
# jsonstr() re-emits a real \uXXXX escape as the literal 6-character text
# "\uXXXX" for bash (below) to decode. Known, accepted ambiguity: JSON text
# that instead encodes an escaped backslash directly followed by literal
# characters u/0-9/a-f (i.e. the source string itself contains the literal
# 6 characters \uXXXX, written by the implementer as prose about escapes,
# not as an escape) decodes here to the identical 6-character output — the
# two are indistinguishable once jsonstr returns, so the bash-side decoder
# below will "decode" both alike. This can only misfire on prose that
# quotes a literal \uXXXX-shaped sequence (e.g. discussing JSON escaping),
# and only cosmetically (an em dash in place of literal escape text) — no
# tool_result or command data is affected.
function jsonstr(rest,    i, n, c, c2, out) {
  n = length(rest); out = ""; i = 1
  while (i <= n) {
    c = substr(rest, i, 1)
    if (c == "\"") { return out }
    else if (c == "\\") {
      i++
      c2 = substr(rest, i, 1)
      if (c2 == "n") out = out "\n"
      else if (c2 == "t") out = out "\t"
      else if (c2 == "r") out = out ""
      else if (c2 == "u") { out = out "\\u" substr(rest, i + 1, 4); i += 4 }
      else out = out c2
      i++
    } else { out = out c; i++ }
  }
  return out
}
function push(kind, a, b, c) { n++; kind_[n] = kind; a_[n] = a; b_[n] = b; c_[n] = c }
BEGIN { n = 0; dispatch_found = 0; dispatch = "" }
{
  line = $0
  if (!dispatch_found) {
    marker = "\"message\":{\"role\":\"user\",\"content\":\""
    p = index(line, marker)
    if (p > 0) {
      dispatch = jsonstr(substr(line, p + length(marker)))
      dispatch_found = 1
      next
    }
  }
  if (index(line, "\"type\":\"assistant\"") == 0) next
  if (index(line, "\"content\":[{\"type\":\"thinking\"") > 0) next
  marker = "\"content\":[{\"type\":\"text\",\"text\":\""
  p = index(line, marker)
  if (p > 0) {
    txt = jsonstr(substr(line, p + length(marker)))
    if (txt != "") push("text", txt, "", "")
    next
  }
  marker = "\"content\":[{\"type\":\"tool_use\""
  p = index(line, marker)
  if (p > 0) {
    name = ""; fp = ""; cmd = ""
    q = index(line, "\"name\":\"")
    if (q > 0) name = jsonstr(substr(line, q + 8))
    q = index(line, "\"file_path\":\"")
    if (q > 0) fp = jsonstr(substr(line, q + 13))
    q = index(line, "\"command\":\"")
    if (q > 0) cmd = jsonstr(substr(line, q + 11))
    if (name != "") push("tool", name, fp, cmd)
    next
  }
}
function fmt(i,    s) {
  if (kind_[i] == "text") { print a_[i]; print "" }
  else {
    s = "- tool: " a_[i]
    if (b_[i] != "") s = s " -- file: " b_[i]
    if (c_[i] != "") s = s " -- command: " c_[i]
    print s
  }
}
END {
  print "### Dispatch prompt"
  print ""
  print (dispatch_found ? dispatch : "(no dispatch prompt found in transcript)")
  print ""
  print "### Assistant activity"
  print ""
  if (n == 0) { print "(no assistant text or tool-use blocks found)" }
  for (i = 1; i <= n; i++) fmt(i)
  print ""
  print "### Final messages (last 3, in full)"
  print ""
  start = n - 2; if (start < 1) start = 1
  if (n == 0) { print "(none)" }
  for (i = start; i <= n; i++) fmt(i)
}
'
DIGEST_BODY="$(awk "$AWK_PROG" "$TRANSCRIPT")"

# jsonstr() (above) leaves \uXXXX escapes as literal 6-character sequences —
# decoding a JSON \u escape into real UTF-8 needs bit-level codepoint math
# that isn't portable across awk implementations (gawk vs mawk vs BSD awk),
# so it is done here instead: bash's own printf builtin already implements
# \uHHHH (and \UHHHHHHHH) universal-character-name expansion (bash >= 4.2),
# so feeding it the literal "\uHHHH" text as a format string decodes it
# correctly and portably. Common in real transcripts (em dashes, curly
# quotes are routinely \u-escaped) — left undecoded, they show up as raw
# JSON syntax in the guidance a replacement implementer reads. An invalid
# or truncated escape (bad hex, or fewer than 4 hex digits) is left exactly
# as-is rather than guessed at. A supplementary-plane character (an emoji,
# say) is encoded in JSON as a UTF-16 surrogate PAIR — two adjacent \uXXXX
# escapes, a high one (D800-DBFF) followed immediately by a low one
# (DC00-DFFF) — that must be combined into one codepoint before decoding:
# decoding each half independently (as bash's own \uHHHH would with a lone
# surrogate value) produces invalid UTF-8 bytes, not an error, so a lone or
# mismatched surrogate is left literal rather than trusted.
decode_unicode_escapes() {
  local s="$1" out="" prefix rest hex suffix char hexval nexthex nextval cp
  while [[ "$s" == *'\u'[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]* ]]; do
    prefix="${s%%\\u*}"
    rest="${s#*\\u}"
    # The while-guard above only confirms a valid \uXXXX exists SOMEWHERE in
    # $s — the split above cuts at the first literal "\u" substring, which
    # need not be that one (e.g. a Windows-style path "C:\uploads\bob"
    # ahead of a real "\u2014" later on the same line: "rest" would start
    # with "ploa", not 4 hex digits). Validate before doing arithmetic on
    # it, or an invalid $hex crashes bash's `$((16#...))` under `set -e`
    # instead of degrading gracefully like every other invalid-escape path
    # here. A false "\u" is skipped as literal, 2 characters at a time, so
    # the next iteration's guard finds the real escape further along.
    if [[ "$rest" != [0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]* ]]; then
      out="$out${prefix}\\u"
      s="$rest"
      continue
    fi
    hex="${rest:0:4}"
    suffix="${rest:4}"
    hexval=$((16#$hex))
    if [ "$hexval" -ge 55296 ] && [ "$hexval" -le 56319 ]; then
      # High surrogate: only valid combined with an immediately-following low
      # surrogate escape (no gap — real JSON never separates a pair).
      if [[ "$suffix" == '\u'[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]* ]]; then
        nexthex="${suffix:2:4}"
        nextval=$((16#$nexthex))
        if [ "$nextval" -ge 56320 ] && [ "$nextval" -le 57343 ]; then
          cp=$(( 65536 + (hexval - 55296) * 1024 + (nextval - 56320) ))
          if printf -v char '\U'"$(printf '%08x' "$cp")" 2>/dev/null; then
            out="$out$prefix$char"
            s="${suffix:6}"
            continue
          fi
        fi
      fi
      out="$out${prefix}\\u${hex}"
      s="$suffix"
      continue
    elif [ "$hexval" -ge 56320 ] && [ "$hexval" -le 57343 ]; then
      # Lone low surrogate with no preceding high one: invalid, leave literal.
      out="$out${prefix}\\u${hex}"
      s="$suffix"
      continue
    fi
    if printf -v char '\u'"$hex" 2>/dev/null; then
      out="$out$prefix$char"
    else
      out="$out${prefix}\\u${hex}"
    fi
    s="$suffix"
  done
  printf '%s%s' "$out" "$s"
}
# decode_unicode_escapes' prefix/suffix slicing is O(remaining length) per
# match — fine for ordinary prose, where escapes are sparse, but quadratic
# on a single line dense with them (measured: several seconds at a few
# thousand matches in one string). A \uXXXX escape, or an adjacent
# surrogate pair, never spans a newline (the only way a newline enters
# DIGEST_BODY is between separate field values, or from an already-
# converted \n escape — never mid-escape), so decoding line by line bounds
# each call to one line's length; a pathologically long line is left
# undecoded entirely (escapes literal) rather than risking a multi-second
# hang on this synchronous recovery path. Each line is streamed straight
# to the subshell's stdout rather than accumulated in a bash variable, so
# reassembly itself stays linear instead of trading one quadratic loop for
# another.
#
# Same pass also neutralizes a heading-injection risk: assistant text and
# the dispatch prompt are copied verbatim, so an implementer's own prose
# (quoting its PR report, or this script's own docs) can contain a line
# starting with `#`/`##`/`###`. SKILL.md Step 4 recovers a corrupted
# `retries` counter by counting literal `## Retry K` sections in this same
# guidance.md file, so an unrelated verbatim `##`-line could silently
# corrupt that bookkeeping. Escape a leading `#` run to `\#...` (a line
# this script itself never emits, so the three literal section headers
# below are exempted by exact match) rather than trusting verbatim text to
# never collide with a heading this file's other readers parse structurally.
# Decode BEFORE checking for a leading `#`, not after: decoding can itself
# manufacture a newline a plain per-input-line check would never see — a
# JSON escape for the newline character, spelled with a "u" instead of the
# short "n" form, decodes to a real line break here just like any other
# escape — splitting what was one input line into several. Check every
# line the decode step actually produces, not just the one it started
# from, or a heading introduced this way sails through unescaped.
MAX_DECODE_LINE_LEN=4000
DIGEST_BODY="$(
  while IFS= read -r dline || [ -n "$dline" ]; do
    if [ "${#dline}" -gt "$MAX_DECODE_LINE_LEN" ]; then
      decoded="$dline"
    else
      decoded="$(decode_unicode_escapes "$dline")"
    fi
    while IFS= read -r outline || [ -n "$outline" ]; do
      case "$outline" in
        "### Dispatch prompt"|"### Assistant activity"|"### Final messages (last 3, in full)") ;;
        "#"*) outline="\\$outline" ;;
      esac
      printf '%s\n' "$outline"
    done <<< "$decoded"
  done <<< "$DIGEST_BODY"
)"

# Branch and PR references: best-effort grep over the digest body just
# built (dispatch prompt + assistant text + tool commands already cover the
# transcript's content, so no second pass over the raw jsonl is needed).
REFS="$(printf '%s\n' "$DIGEST_BODY" \
  | grep -oE 'PR #[0-9]+|pull/[0-9]+|[A-Za-z_-]+/issue-[0-9]+-[A-Za-z0-9-]+' \
  | sort -u || true)"
[ -n "$REFS" ] || REFS="(none found)"

{
  echo
  echo "## Recovered trace"
  echo
  echo "Digest of agent-$AGENT_ID (session $SESSION_ID, transcript $TRANSCRIPT)"
  echo "recovered by scripts/agent-trace.sh because in-place resume was"
  echo "unavailable for this implementer. This is a digest of what it did,"
  echo "not what it thought — chain-of-thought is not recoverable and is"
  echo "never included. Tool_result bodies (the densest source of secrets"
  echo "and environment dumps in a transcript) are never included either —"
  echo "but assistant text below is copied verbatim and can still reproduce"
  echo "anything the implementer itself echoed into its own prose."
  echo
  printf '%s\n' "$DIGEST_BODY"
  echo "### Branch / PR references"
  echo
  printf '%s\n' "$REFS" | sed 's/^/- /'
} >> "$GUIDANCE"

echo "agent-trace: appended trace digest for agent-$AGENT_ID to $GUIDANCE" >&2
