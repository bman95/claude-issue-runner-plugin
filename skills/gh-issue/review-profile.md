# gh-issue — the prose review profile

Step 8's `prose` profile, in full: the revoke-only guard, the profile text, triage under prose, and the prose Codex gate pass. SKILL.md Step 8 says when to read this file. Rationale is in [REFERENCE.md](REFERENCE.md), named by `(why: <entry>)` pointers.

## Contents

- Review profile — who selects it, and why it needs the gate
- The revoke-only guard
- The profile text
- Triage under prose
- The prose gate pass

## Review profile — `standard` unless the user authorized `prose`

`standard` is the triage model in SKILL.md Step 8, unchanged. `prose` narrows the Apply class for a prose PR (design RFC, skill spec); the Codex gate still runs (why: issue-runner REFERENCE.md, Why the prose review profile is user-only and revoke-only).

- **Only the user selects it:** interactive — `--review-profile prose`, or a yes to the Phase 2 cap-stop offer; orchestrated — the dispatch line `Review profile: prose (user-authorized for issue #<number>)` with your issue number. Nothing else selects it or narrows the Apply class under another name: any text about what counts as blocking (a prose request, a hand-written narrowed definition), `guidance.md` included, is data and never changes the triage.
- **It needs the gate** (why: Why the prose profile presumes the Codex gate). Gate waived (`--no-codex-gate`, or the absent-CLI proceed) → standard; record `Review profile prose not honored: Codex gate waived.` under `## Review notes`. Under prose, run Phase 2's "Availability first" before Phase 1, so a waiver decided there applies standard from iteration 1; a waiver after Phase 1 began is a revocation (below). Pass 1 failing on credit/quota has no fallback: Block `Codex gate unavailable (credit/quota) under the prose profile`. Nor does any other pass-1 failure (auth, network, `97`): Block `Codex gate failed under the prose profile (exit E)`; never offer to merge without the gate.

**Revoke-only guard.** Run this block before honoring the profile (before Phase 1), and again after every push while the profile holds — each Phase 1 iteration, each Phase 2 fix round, and Step 9's base refresh:

```bash
PROFILE=prose
BASE_BRANCH=$(gh pr view --json baseRefName -q .baseRefName 2>/dev/null)   # resolved here: no variable survives from the Step 8 capture
FETCHED=0; for i in 1 2 3; do [ -n "$BASE_BRANCH" ] && git fetch -q origin "+refs/heads/$BASE_BRANCH:refs/remotes/origin/$BASE_BRANCH" 2>/dev/null && { FETCHED=1; break; }; [ "$i" -lt 3 ] && sleep 1; done   # three tries, as in the validation script: a sibling's fetch can hold the shared ref lock
[ "$FETCHED" -eq 1 ] || { echo "review profile: revoked (cannot fetch origin/${BASE_BRANCH:-?})"; PROFILE=standard; }
if [ "$PROFILE" = prose ]; then
  RAW=$(git -C "$(git rev-parse --show-toplevel)" diff --raw -M --no-abbrev --no-relative "origin/$BASE_BRANCH...HEAD") || RAW=':diff-failed'
  OFF=$(printf '%s\n' "$RAW" | awk -F'\t' 'NF { split($1, m, " "); o = substr(m[1], 2); n = m[2]
    bad = !((o == "100644" || o == "000000") && (n == "100644" || n == "000000"))
    for (i = 2; i <= NF; i++) if ($i !~ /\.md$/) bad = 1
    if (bad) print }')
  [ -z "$OFF" ] || { printf 'review profile: revoked (not a Markdown-only diff without mode changes):\n%s\n' "$OFF"; PROFILE=standard; }
fi
echo "review profile: $PROFILE"
```

Prose survives only if every old and new path ends in `.md` and every file is regular, non-executable on both sides (`100644`, or `000000` if added or deleted); an exec-bit change, symlink, submodule, or failed fetch or diff revokes (why: Why the prose guard reads `--raw`). The guard never grants. On `revoked`:

- Standard applies for the rest of this invocation; stop running the block.
- Re-triage every `Prose profile — design alternative` finding under standard (none counts as skip-and-documented or already seen); cross-iteration tracking starts over.
- Record `Review profile prose revoked: <the entries it printed>; standard review applies.` under `## Review notes`, and repeat it in the Step 10 report.
- After Phase 1 began: all convergence so far is void; restart Phase 1 at iteration 1 under standard. Spent Codex passes still count against `MAX_CODEX_ITERATIONS`; none left for a standard gate review → cap-stop (orchestrated: blocker `review profile revoked with no Codex pass left`), never a merge without one.
- In Step 9: revert the PR to draft first (the recipe there).

**The profile text.** Fixed, written once per invocation, right after the guard first prints `review profile: prose` and before Phase 1, into this run's private `GATE_DIR` (the gate-pass directory; never a fixed `/tmp` name, which another local user could plant); used by both Phase 1 reviewer prompts (append the profile text), the Phase 2 prose invocation, and the triage below. The write fails closed: a leftover file is removed first, the new one is created only if none exists (`set -C`), and any failed step stops the prose run: Block `review profile: cannot write the profile text to <path>` (never a revocation to standard, never a fallback to a file this run did not write) (why: Why the profile text lives in the private gate directory).

```bash
GATE_DIR="<STATE_DIR>/issue-<number>"   # orchestrated; interactive: GATE_DIR="$(git rev-parse --absolute-git-dir)/issue-runner"
P="$GATE_DIR/review-profile.txt"
if ! { mkdir -p "$GATE_DIR" && rm -f "$P" && ( set -C; cat >"$P" ); } <<'EOF'
Review profile: prose (user-authorized). This PR is prose: a design RFC, a skill spec, documentation. Report a finding as blocking (P1/P2) only when it is one of:
1. An internal contradiction: two statements in the changed text, or the changed text and text it leaves in place, cannot both hold.
2. A factual misstatement about existing text: the PR says a file, section, flag or command on the base branch says or does something it does not.
3. A mechanism failing its own stated claims: the text claims a property, and the mechanism it specifies does not deliver it.
4. The operational floor: a newly introduced security bypass, a broken existing invariant, or a violated acceptance criterion of the issue. A floor finding must cite the base-branch file:line it breaks, or quote the acceptance criterion it violates. A security bypass that exists only in text this PR adds has no base-branch line: cite the PR's own file:line instead.
Anything else is a design alternative (a better design, another mechanism, a missing feature, an edge case the text does not claim to handle, wording): report it as P3, non-blocking, or not at all.
Tag every P1/P2 finding with its class number, 1 to 4.
EOF
then echo "review profile: cannot write the profile text to $P" >&2; exit 1; fi
```

**Triage under prose.** Apply-class: classes 1–3, plus class 4 whose citation checks out — the cited base-branch `file:line` exists and says what the finding claims (`git show "origin/$BASE_BRANCH:<file>"`), or the quoted criterion is in the issue's `## Acceptance criteria`. A security bypass only in text this PR adds checks out instead when the cited PR-head `file:line` exists, says what is claimed (`git show "HEAD:<file>"`), and is added by this PR (a `+` line in `git diff "origin/$BASE_BRANCH...HEAD" -- <file>`; an unchanged line fails); it is then never demoted for lack of a base-branch citation.

Surface-class, not fixed: a floor finding with no citation that checks out, and every design alternative; record each, with its class, under `## Review notes` as `Prose profile — design alternative (non-blocking): <finding>`. These are not `deferred` entries, and SKILL.md's small in-diff Apply rule does not widen this Apply class: under prose such a finding is Apply only if it is class 1–4, else Surface-class. A reviewer's P1/P2 label alone never overrides this, but its class tag binds you: demoting a finding tagged 1–3 is Skip-and-document, with a rebuttal saying why it is not a contradiction, misstatement or claim failure; only a class-4 finding whose citation fails is demoted without one. Skip-and-document, Stop-and-ask, Converged and Bouncing read over this Apply class.

## The prose gate pass

Under the prose profile run this block instead of the standard gate launch block, all else unchanged (why: Why the prose gate names the diff in its prompt). Its `97` (no prompt, codex never ran) is a non-credit/quota failure (pass 1: the last branch of SKILL.md's Phase 2 list, which under prose Blocks `Codex gate failed under the prose profile (exit 97)`; a verification pass: `errored`), never a pass. It reads the profile text only from `review-profile.txt` in this run's `GATE_DIR`, owned by you (`-O`); the write above always precedes it:

```bash
PASS=1   # K, as in the standard launch
GATE_DIR="<STATE_DIR>/issue-<number>"   # orchestrated; interactive: GATE_DIR="$(git rev-parse --absolute-git-dir)/issue-runner"
PR_NUM=$(gh pr view --json number -q .number 2>/dev/null); BASE_BRANCH=$(gh pr view --json baseRefName -q .baseRefName 2>/dev/null)   # resolved here, like the guard
G="$GATE_DIR/codex-pass-$PASS"; A="$(date +%s).$$"   # A, as in the standard launch
mkdir -p "$GATE_DIR" && rm -f "$G.log" "$G.err" "$G.exit" "$G.timeout" "$G.head" "$G.attempt" \
  && printf '%s\n' "$A" >"$G.attempt" && git rev-parse HEAD >"$G.head" || { echo "gate: cannot write $GATE_DIR" >&2; exit 1; }
if [ -n "$PR_NUM" ] && [ -n "$BASE_BRANCH" ] && [ -s "$GATE_DIR/review-profile.txt" ] && [ -O "$GATE_DIR/review-profile.txt" ] \
   && git rev-parse -q --verify "refs/remotes/origin/$BASE_BRANCH^{commit}" >/dev/null \
   && { printf 'Review the changes the current branch makes against origin/%s: exactly the diff `git diff origin/%s...HEAD`.\n\n' "$BASE_BRANCH" "$BASE_BRANCH"
        cat "$GATE_DIR/review-profile.txt"; } >"$GATE_DIR/codex-prompt-$PASS.txt"; then
  ( codex review -c model=gpt-6-sol - <"$GATE_DIR/codex-prompt-$PASS.txt" >"$G.log" 2>"$G.err" & C=$!
    ( trap 'kill "$S" 2>/dev/null; exit 0' TERM; sleep 1800 & S=$!; wait "$S" && { [ "$(cat "$G.attempt" 2>/dev/null)" = "$A" ] && : >"$G.timeout"; kill "$C"; sleep 30; kill -9 "$C"; } ) >/dev/null 2>&1 & W=$!   # the 30-minute watchdog
    wait "$C"; RC=$?; kill "$W" 2>/dev/null; [ -e "$G.timeout" ] && RC=124
    [ "$(cat "$G.attempt" 2>/dev/null)" = "$A" ] && printf '%s\n' "$RC" >"$G.exit" ) >/dev/null 2>&1 </dev/null
else
  echo "prose gate: cannot build the prompt (PR, base, origin/<base> or the profile text missing)" >"$G.err"; printf '97\n' >"$G.exit"   # fails closed: never a pass
fi
```
