#!/usr/bin/env bash
#
# resume-check.sh — issue-runner Step 3a's resume check: the three probes that
# find an issue's in-flight work on GitHub before a dispatch. SKILL.md runs this
# script and decides what to do with each line (resume, ask the user, delete a
# stale branch, dispatch fresh); the probes and their classification live here,
# and the rationale in REFERENCE.md ("Why dispatch resumes open PRs",
# "Why the implementer opens a draft PR right after the plan").
#
# This script is the statement of the branch-contract match pattern that the
# SKILL.md prose points at. gh-issue Step 4 names every implementer branch
# `<type>/issue-<number>-<slug>`; an issue's branches are found with exactly
# these two forms. scripts/lint.sh check 10 pins them here and requires
# classify.sh to use the same two (Step 3 item 4's hung-worktree lookup in
# SKILL.md also matches the first, spelled identically):
#   PR head match      a head branch containing  /issue-$N-
#   remote-branch glob git ls-remote pattern     */issue-$N-*
# `issue-7-` never matches `issue-70-`: the trailing `-` is part of the pattern.
#
# Run from the target repository (the orchestrator's own cwd, never a
# worktree): the `gh` calls resolve the repository from it, probe 3 reads its
# `origin`, and the worktree lookup reads its `git worktree list`.
#
# Usage: resume-check.sh <N>
#
# Probes:
#   1  branch contract  open PRs whose head branch contains /issue-N- (a draft
#                       checkpoint is an open PR)
#   2  closing keyword  open PRs `gh pr list --search` returns for
#                       `closes #N OR fixes #N OR resolves #N`, kept only when
#                       the body carries a plain closing reference (close, closes,
#                       closed, fix, fixes, fixed, resolve, resolves, resolved;
#                       any case, an optional `:`, then `#N`) — `#70` never
#                       proves `#7`. Any other search hit is reported as
#                       unconfirmed, for the orchestrator to judge: the search
#                       also matches looser text, and GitHub also closes on
#                       forms this match does not read (`owner/repo#N`, an
#                       issue URL, a keyword in markdown emphasis)
#   3  orphan branch    `git ls-remote --exit-code --heads origin '*/issue-N-*'`:
#                       exit 2 = no such branch, 0 = hits, anything else = the
#                       probe failed; a failed probe is retried once
# The open-PR listings use `--limit 1000`, not gh's default of 30.
#
# Output — one line per open PR (1 and 2, deduplicated by number: the
# checkpoint body carries `Closes #N`, so a run's own PR hits both), then one
# line per unconfirmed keyword hit, then one line per probe-3 branch that no
# open PR line covers — or `none` when there is nothing at all:
#   pr #P <branch> draft=<true|false> via=<contract|keyword|both> worktree=<path|->
#       worktree is where <branch> is checked out (`git worktree list`), `-`
#       when nowhere; the path is the rest of the line and may hold spaces
#   keyword-unconfirmed #P <branch>
#       a closing-keyword search hit whose body has no plain `<keyword> #N`:
#       read it before deciding (it may close #N in another form, or only
#       mention it)
#   branch <B> <tip> orphan
#       no PR at all, in any state: a checkpoint whose `gh pr create` never ran
#   branch <B> <tip> stale #P
#       a merged PR whose headRefOid is the branch's tip <tip>: the undeleted
#       head branch of landed work, safe to delete under a lease on <tip>
#   branch <B> <tip> ask (<#P state>, …)
#       merged PRs whose head is not <tip> (the branch moved on after the
#       merge) and/or closed PRs: unmerged work someone left or rejected; an
#       `open` entry is a PR the open listings missed (opened in between, or
#       past the 1000 limit, or a keyword-unconfirmed hit) — ask all the same
#   probe3-failed <reason>
#       probe 3 failed twice (auth, transport); printed after any PR lines, and
#       never alone with `none`: a blind probe is not "no branch"
#
# Exit status: 0 with the lines above. Non-zero prints nothing on stdout and is
# never a verdict: 1 — a `gh` query or `git worktree list` failed (an
# environment failure: never dispatch on it); 2 — a usage error.
#
# Dependencies: bash 3.2, coreutils, grep, awk, git, gh (its built-in --jq only
# projects fields; every decision is made here).

set -u
set +e +o pipefail   # every exit status below is read explicitly

die()   { echo "resume-check.sh: $1" >&2; exit 1; }
usage() { echo "resume-check.sh: $1" >&2; exit 2; }

N=${1:-}
case $N in ''|*[!0-9]*|0*) usage "issue number must be a positive integer, got '${N}'" ;; esac

CONTRACT="/issue-$N-"      # the PR head match
GLOB="*/issue-$N-*"        # the remote-branch glob

# --- Probe 1: branch contract -------------------------------------------------
list=$(gh pr list --state open --limit 1000 --json number,headRefName,isDraft \
  --jq '.[] | "\(.number) \(.headRefName) \(.isDraft)"' </dev/null) || die "cannot list open PRs"
# "number branch draft via" lines
prs=$(printf '%s\n' "$list" | awk -v pat="$CONTRACT" 'NF && index($2, pat) { print $1, $2, $3, "contract" }')

# --- Probe 2: closing keyword -------------------------------------------------
unconfirmed=""
list=$(gh pr list --state open --limit 1000 --search "closes #$N OR fixes #$N OR resolves #$N" \
  --json number,headRefName,isDraft --jq '.[] | "\(.number) \(.headRefName) \(.isDraft)"' </dev/null) \
  || die "cannot search open PRs for closing keywords"
while read -r p b d; do
  [ -n "$p" ] || continue
  if printf '%s\n' "$prs" | awk -v p="$p" '$1 == p { f = 1 } END { exit !f }'; then
    prs=$(printf '%s\n' "$prs" | awk -v p="$p" '$1 == p { $4 = "both" } NF { print }')
    continue
  fi
  body=$(gh pr view "$p" --json body --jq .body </dev/null) || die "cannot view PR #$p"
  printf '%s\n' "$body" \
    | grep -qiE "(^|[^[:alnum:]_])(close[sd]?|fix(e[sd])?|resolve[sd]?):?[[:space:]]+#$N([^[:alnum:]_]|$)" \
    || { unconfirmed="${unconfirmed}keyword-unconfirmed #$p $b"$'\n'; continue; }
  prs=$(printf '%s\n%s %s %s keyword\n' "$prs" "$p" "$b" "$d" | awk 'NF')
done <<EOF_KW
$list
EOF_KW

# --- Worktrees: where each branch is checked out --------------------------------
wtlist=$(git worktree list --porcelain </dev/null 2>/dev/null) || die "cannot list worktrees"
worktree_of() {   # worktree_of BRANCH -> its worktree path, or -
  printf '%s\n' "$wtlist" | awk -v ref="refs/heads/$1" '
    /^worktree / { path = substr($0, 10) }
    $0 == "branch " ref { print path; found = 1; exit }
    END { if (!found) print "-" }'
}

out=""
while read -r p b d via; do
  [ -n "$p" ] || continue
  out="${out}pr #$p $b draft=$d via=$via worktree=$(worktree_of "$b")"$'\n'
done <<EOF_PRS
$(printf '%s\n' "$prs" | sort -n)
EOF_PRS
out="$out$unconfirmed"

# --- Probe 3: orphan branch -----------------------------------------------------
probe3() { refs=$(git ls-remote --exit-code --heads origin "$GLOB" 2>"$ERRF" </dev/null); rc=$?; }
ERRF=$(mktemp) || die "cannot create a temporary file"
trap 'rm -f "$ERRF"' EXIT
probe3
case $rc in 0|2) ;; *) probe3 ;; esac
case $rc in
  0) while read -r tip ref; do
       b=${ref#refs/heads/}
       [ -n "$b" ] || continue
       printf '%s\n' "$prs" | awk -v b="$b" '$2 == b { f = 1 } END { exit !f }' && continue
       hist=$(gh pr list --head "$b" --state all --limit 1000 --json number,state,headRefOid \
         --jq '.[] | "\(.number) \(.state) \(.headRefOid)"' </dev/null) || die "cannot list PRs on $b"
       if [ -z "$(printf '%s' "$hist" | tr -d '[:space:]')" ]; then
         out="${out}branch $b $tip orphan"$'\n'
         continue
       fi
       stale=$(printf '%s\n' "$hist" | awk -v t="$tip" '$2 == "MERGED" && $3 == t { print $1; exit }')
       if [ -n "$stale" ]; then
         out="${out}branch $b $tip stale #$stale"$'\n'
       else
         out="${out}branch $b $tip ask ($(printf '%s\n' "$hist" | awk 'NF { printf "%s#%s %s", (n++ ? ", " : ""), $1, tolower($2) }'))"$'\n'
       fi
     done <<EOF_REFS
$refs
EOF_REFS
     ;;
  2) ;;
  *) out="${out}probe3-failed git ls-remote exit $rc: $(tr '\n' ' ' <"$ERRF" | sed 's/ *$//')"$'\n' ;;
esac

if [ -n "$out" ]; then printf '%s' "$out"; else echo none; fi
