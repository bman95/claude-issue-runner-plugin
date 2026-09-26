#!/usr/bin/env bash
#
# Consistency lint for the issue-runner plugin.
#
# A prompt-spec plugin has no runnable code to test, but its manifests and docs
# drift against each other in mechanically-checkable ways. This script guards the
# drift classes that have actually bitten releases:
#
#   1. plugin.json version == marketplace.json version
#   2. every skills/*/SKILL.md frontmatter has name + description + version
#   3. --max-parallel default agrees across README, SKILL arg line, and the
#      Step 3 runtime `Set \`MAX_PARALLEL\` (default N)` line; likewise
#      --hang-minutes against the `\`HANG_MINUTES\` (default N` runtime phrase;
#      and --max-codex-iterations across README, both editions' issue-runner
#      arg line, gh-issue flag line, Phase 2 heading and REFERENCE cap entry,
#      and the Step 2 estimate's `Resolve \`MAX_CODEX_ITERATIONS\` (default N` phrase
#   4. CHANGELOG has an entry for the manifest version
#   5. the issue-body contract strings appear in both issue-plan and issue-runner,
#      the planner's slice template ends with the `Files likely touched:` line and
#      starts with `Part of #`, its tracking-issue template has `## Slices` and no
#      `## What to build`, and the `Part of` pattern and Step 1 exclusion message
#      are present at every site — checked for the Claude skills and for the
#      Codex edition's canonical copies
#   6. no skill references retired command names (e.g. /to-issues)
#   7. every ```bash block embedded in skills/*/SKILL.md parses (bash -n,
#      after neutralizing <placeholder> tokens)
#   8. shellcheck (if installed) over this script, the bundled
#      skills/*/scripts/*.sh and the extracted blocks — findings are WARNINGS
#      only, never failures
#   9. the default-branch resolution one-liner is byte-identical at every site
#  10. the branch-contract match pattern is stated once, in
#      skills/issue-runner/scripts/resume-check.sh: classify.sh uses the same
#      forms, both issue-runner editions point at the script, and gh-issue (both
#      editions) still creates branches in that shape
#  11. the result.json key set is spelled identically on every contract line
#      (a line starting with `{` and carrying `"outcome":` — the shape line and
#      the write recipe) in gh-issue and issue-runner — Claude skills and the
#      Codex edition's canonical copies alike; compared per line, not per file,
#      with the contract-line count pinned per file and the shape line (enum
#      values included) byte-identical across the four files
#  12. skills/issue-runner/scripts/test-scheduler.sh passes — the golden
#      fixtures for scripts/scheduler.sh, the extracted Step 3 cascade-skip /
#      ready-set / blocked-chain-vs-cycle state machine
#  13. this repository's own .issue-runner/validation parses under the grammar
#      skills/gh-issue/scripts/validation-contract.sh applies (comment/blank
#      lines, exactly one `preflight:` line, at most one `full:` line, LF
#      endings, nothing else)
#  14. scripts/test-validation-contract.sh passes — the fixtures for that
#      script, run directly
#  15. skills/issue-plan/SKILL.md and the Codex edition's canonical copy are
#      byte-identical — the planner is ported in full, and its wrapper reads
#      the canonical copy, so any drift is a divergence between editions
#  16. the prose review profile is one contract in both editions: gh-issue's
#      Step 8 "Review profile" section and its Phase 2 prose invocation are
#      byte-identical across editions, both carry the --review-profile flag
#      line, the unknown-profile refusal and the dispatch-line contract, and
#      both runners' Step 3a write that same dispatch line and carry the
#      Step 4 prose-retry offer
#  17. reviewer and gate liveness: gh-issue's Step 8 "Liveness" section and
#      the Phase 2 launch block are byte-identical across editions, and no
#      fixed /tmp gate-output path comes back
#  18. every bundled script under skills/*/scripts/ parses (bash -n), and every
#      one with a Codex counterpart under codex/issue-runner/canonical/ is
#      byte-identical to it (cmp); a Codex script with no original fails, and
#      so does a missing Codex copy of validation-contract.sh, classify.sh,
#      resume-check.sh or merge-ready.sh;
#      gh-issue's "## Validation contract" section and skills/gh-issue/REFERENCE.md
#      are byte-identical across editions
#  19. skills/issue-runner/scripts/test-classify.sh passes — the golden
#      fixtures for scripts/classify.sh, the extracted Step 3 item 5 merge
#      proof and Step 5 unfinished-PR shape classifications
#  20. skills/issue-runner/scripts/test-run-state.sh passes — the fixtures for
#      scripts/run-state.sh, the extracted State-section run root, run lock,
#      heartbeat, same-session re-entry / rotation and release
#  21. skills/issue-runner/scripts/test-resume-check.sh passes — the fixtures
#      for scripts/resume-check.sh, the extracted Step 3a resume probes
#  22. skills/issue-runner/scripts/test-merge-ready.sh passes — the fixtures
#      for scripts/merge-ready.sh, the extracted --merge-ready state, refresh,
#      checks re-check and head-pinned merge
#  23. spec size ceilings: skills/issue-runner/SKILL.md at most 11000 words and
#      skills/gh-issue/SKILL.md at most 9000 (`wc -w`), and no line in either
#      over 1500 characters — each failure names the file, its count and the
#      ceiling; rationale belongs in REFERENCE.md, not in the procedure
#
# Dependency-free: bash + coreutils/grep/sed/awk only (no jq; shellcheck is
# optional and advisory). Exits non-zero on the first-or-any failure, printing
# every problem it found.

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0

err()  { printf 'FAIL: %s\n' "$1" >&2; fail=1; }
ok()   { printf 'ok:   %s\n' "$1"; }
warn() { printf 'WARN: %s\n' "$1"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Extract the first `"version": "X.Y.Z"` value from a JSON file.
json_version() {
  sed -nE 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' "$1" | head -1
}

# Print the YAML frontmatter block (between the first two `---` lines) of a file.
frontmatter() {
  awk 'NR==1 && $0=="---" {f=1; next} f && $0=="---" {exit} f {print}' "$1"
}

# Extract the integer following the first "default N" on a --max-parallel line.
max_parallel_default() {
  grep -E '\-\-max-parallel N' "$1" | grep -oE 'default[[:space:]]+[0-9]+' \
    | grep -oE '[0-9]+' | head -1
}

PLUGIN_JSON="$ROOT/.claude-plugin/plugin.json"
MARKET_JSON="$ROOT/.claude-plugin/marketplace.json"
README="$ROOT/README.md"
CHANGELOG="$ROOT/CHANGELOG.md"
SKILL_RUNNER="$ROOT/skills/issue-runner/SKILL.md"
SKILL_GH="$ROOT/skills/gh-issue/SKILL.md"
# The Codex edition's canonical copies (its wrappers read these, not skills/).
CANON_RUNNER="$ROOT/codex/issue-runner/canonical/issue-runner/SKILL.md"
CANON_GH="$ROOT/codex/issue-runner/canonical/gh-issue/SKILL.md"
REF_RUNNER="$ROOT/skills/issue-runner/REFERENCE.md"
CANON_REF_RUNNER="$ROOT/codex/issue-runner/canonical/issue-runner/REFERENCE.md"

# 1. Manifest version agreement -------------------------------------------------
plugin_version="$(json_version "$PLUGIN_JSON")"
market_version="$(json_version "$MARKET_JSON")"
if [ -z "$plugin_version" ]; then
  err "could not read version from $PLUGIN_JSON"
elif [ -z "$market_version" ]; then
  err "could not read version from $MARKET_JSON"
elif [ "$plugin_version" != "$market_version" ]; then
  err "version mismatch: plugin.json=$plugin_version marketplace.json=$market_version"
else
  ok "manifest versions agree ($plugin_version)"
fi

# 2. SKILL frontmatter completeness --------------------------------------------
for skill in "$ROOT"/skills/*/SKILL.md; do
  [ -f "$skill" ] || continue
  rel="${skill#"$ROOT"/}"
  fm="$(frontmatter "$skill")"
  for field in name description version; do
    if ! printf '%s\n' "$fm" | grep -qE "^${field}:[[:space:]]*[^[:space:]]"; then
      err "$rel frontmatter missing '$field'"
    fi
  done
  ok "frontmatter fields present: $rel"
done

# 3. --max-parallel default: README arg, SKILL arg, SKILL runtime ---------------
readme_mp="$(max_parallel_default "$README")"
skill_mp="$(max_parallel_default "$SKILL_RUNNER")"
# The Step 3 runtime line: Set `MAX_PARALLEL` (default N)
runtime_mp="$(grep -E 'Set `MAX_PARALLEL` \(default [0-9]+\)' "$SKILL_RUNNER" \
  | grep -oE 'default[[:space:]]+[0-9]+' | grep -oE '[0-9]+' | head -1)"
if [ -z "$readme_mp" ] || [ -z "$skill_mp" ] || [ -z "$runtime_mp" ]; then
  err "could not read --max-parallel default (README='$readme_mp' SKILL-arg='$skill_mp' SKILL-runtime='$runtime_mp')"
elif [ "$readme_mp" != "$skill_mp" ] || [ "$skill_mp" != "$runtime_mp" ]; then
  err "--max-parallel default drift: README=$readme_mp SKILL-arg=$skill_mp SKILL-runtime=$runtime_mp"
else
  ok "--max-parallel default agrees at all three sites ($readme_mp)"
fi

# 3b. --hang-minutes default: README arg, SKILL arg, SKILL runtime ------------
hang_minutes_default() {
  grep -E '\-\-hang-minutes N' "$1" | grep -oE 'default[[:space:]]+[0-9]+' \
    | grep -oE '[0-9]+' | head -1
}
readme_hm="$(hang_minutes_default "$README")"
skill_hm="$(hang_minutes_default "$SKILL_RUNNER")"
# The Step 3 runtime phrase: `HANG_MINUTES` (default N
runtime_hm="$(grep -E '`HANG_MINUTES` \(default [0-9]+' "$SKILL_RUNNER" \
  | grep -oE '`HANG_MINUTES` \(default [0-9]+' | grep -oE '[0-9]+' | head -1)"
if [ -z "$readme_hm" ] || [ -z "$skill_hm" ] || [ -z "$runtime_hm" ]; then
  err "could not read --hang-minutes default (README='$readme_hm' SKILL-arg='$skill_hm' SKILL-runtime='$runtime_hm')"
elif [ "$readme_hm" != "$skill_hm" ] || [ "$skill_hm" != "$runtime_hm" ]; then
  err "--hang-minutes default drift: README=$readme_hm SKILL-arg=$skill_hm SKILL-runtime=$runtime_hm"
else
  ok "--hang-minutes default agrees at all three sites ($readme_hm)"
fi

# 3c. --max-codex-iterations default: README arg, both editions' issue-runner
# arg line, gh-issue flag line, Phase 2 heading and REFERENCE cap entry, and
# the Step 2 estimate ----------------------------------------------------------
# Each site is `<label>|<file>|<ERE for the line>`; the value read is the first
# "default N" on the first matching line.
mci_default() {
  grep -E -e "$2" "$1" | head -1 | grep -oE 'default[[:space:]]+[0-9]+' \
    | grep -oE '[0-9]+' | head -1
}
mci_ref=""; mci_ok=1; mci_seen=""; mci_n=0
while IFS='|' read -r label file pat; do
  v="$(mci_default "$file" "$pat")"
  mci_n=$((mci_n + 1)); mci_seen="$mci_seen $label=${v:-?}"
  if [ -z "$v" ]; then mci_ok=0
  elif [ -z "$mci_ref" ]; then mci_ref="$v"
  elif [ "$v" != "$mci_ref" ]; then mci_ok=0
  fi
done <<EOF_MCI
README|$README|--max-codex-iterations N
issue-runner-arg|$SKILL_RUNNER|--max-codex-iterations N
canonical-issue-runner-arg|$CANON_RUNNER|--max-codex-iterations N
gh-issue-flag|$SKILL_GH|--max-codex-iterations N
canonical-gh-issue-flag|$CANON_GH|--max-codex-iterations N
gh-issue-Phase-2|$SKILL_GH|^#### Phase 2 .*cap \`MAX_CODEX_ITERATIONS\`, default [0-9]+
canonical-gh-issue-Phase-2|$CANON_GH|^#### Phase 2 .*cap \`MAX_CODEX_ITERATIONS\`, default [0-9]+
issue-runner-Step-2|$SKILL_RUNNER|Resolve \`MAX_CODEX_ITERATIONS\` \(default [0-9]+
REFERENCE|$REF_RUNNER|The cap is \`--max-codex-iterations\` \(default [0-9]+
canonical-REFERENCE|$CANON_REF_RUNNER|The cap is \`--max-codex-iterations\` \(default [0-9]+
EOF_MCI
if [ "$mci_ok" -eq 1 ]; then
  ok "--max-codex-iterations default agrees at all $mci_n sites ($mci_ref)"
else
  err "--max-codex-iterations default drift or unreadable (? = unreadable):$mci_seen"
fi

# 4. CHANGELOG entry for the manifest version ----------------------------------
if [ -n "$plugin_version" ]; then
  if grep -qE "^## \[${plugin_version//./\\.}\]" "$CHANGELOG"; then
    ok "CHANGELOG has an entry for $plugin_version"
  else
    err "CHANGELOG has no '## [$plugin_version]' entry"
  fi
fi

# 5. Issue-body contract strings shared by planner and runner ------------------
SKILL_PLAN="$ROOT/skills/issue-plan/SKILL.md"
# The Codex edition's wrapper reads this canonical copy, not skills/.
CANON_PLAN="$ROOT/codex/issue-runner/canonical/issue-plan/SKILL.md"
for s in '## Blocked by' 'None - can start immediately' 'Files likely touched:' 'Part of #' '## Slices'; do
  for f in "$SKILL_PLAN" "$SKILL_RUNNER" "$CANON_PLAN" "$CANON_RUNNER"; do
    if ! grep -qF "$s" "$f"; then
      err "contract string '$s' missing from ${f#"$ROOT"/}"
    fi
  done
done
ok "issue-body contract strings present in planner and runner (both editions)"
# The runner parses the LAST body line beginning with `Files likely touched:`
# (issue-runner Step 2), so the planner's body template — the ```markdown block
# containing `## What to build` — must end with it.
for f in "$SKILL_PLAN" "$CANON_PLAN"; do
  tmpl_last="$(awk '
    /^```markdown[[:space:]]*$/ { inb=1; hit=0; l=""; next }
    inb && /^```[[:space:]]*$/  { inb=0; if (hit) { print l; exit }; next }
    inb && /^## What to build/  { hit=1 }
    inb && NF                   { l=$0 }
  ' "$f")"
  case "$tmpl_last" in
    'Files likely touched:'*) ok "body template ends with 'Files likely touched:': ${f#"$ROOT"/}" ;;
    *) err "body template's last line is not 'Files likely touched:' in ${f#"$ROOT"/} (got: '$tmpl_last')" ;;
  esac
done
# The runner recognizes a tracking issue by a `## Slices` line with no
# `## What to build` line (issue-runner Step 1) and finds it from each slice's
# first body line, `Part of #<tracking>` (Step 5). Pin both in the planner's
# templates: the tracking template (the ```markdown block containing `## Slices`)
# must not contain `## What to build`; the slice template's first non-blank line
# must begin with `Part of #`.
for f in "$SKILL_PLAN" "$CANON_PLAN"; do
  track="$(awk '
    /^```markdown[[:space:]]*$/ { inb=1; slices=0; wtb=0; next }
    inb && /^```[[:space:]]*$/  { inb=0; if (slices) { print (wtb ? "bad" : "ok"); exit }; next }
    inb && /^## Slices$/        { slices=1 }
    inb && /^## What to build$/ { wtb=1 }
  ' "$f")"
  case "$track" in
    ok)  ok "tracking-issue template has '## Slices' and no '## What to build': ${f#"$ROOT"/}" ;;
    bad) err "tracking-issue template contains '## What to build' in ${f#"$ROOT"/}" ;;
    *)   err "no tracking-issue template (markdown block containing '## Slices') in ${f#"$ROOT"/}" ;;
  esac
  slice_first="$(awk '
    /^```markdown[[:space:]]*$/ { inb=1; hit=0; first=""; next }
    inb && /^```[[:space:]]*$/  { inb=0; if (hit) { print first; exit }; next }
    inb && /^## What to build/  { hit=1 }
    inb && NF && first==""      { first=$0 }
  ' "$f")"
  case "$slice_first" in
    'Part of #'*) ok "slice template starts with 'Part of #': ${f#"$ROOT"/}" ;;
    *) err "slice template's first line is not 'Part of #' in ${f#"$ROOT"/} (got: '$slice_first')" ;;
  esac
done
# Two literals must agree across files: the `Part of #P` pattern the runner matches
# and the planner promises (issue-runner Step 5 / issue-plan Step 5), and the Step 1
# exclusion message (the scenarios cite it by prefix), pinned across both runner
# editions. The exact literal must appear at every site.
literals_ok=1
for f in "$SKILL_PLAN" "$SKILL_RUNNER" "$CANON_PLAN" "$CANON_RUNNER"; do
  if ! grep -qF '^Part of #[0-9]+$' "$f"; then
    err "Part of pattern '^Part of #[0-9]+\$' missing from ${f#"$ROOT"/}"; literals_ok=0
  fi
done
for f in "$SKILL_RUNNER" "$CANON_RUNNER"; do
  if ! grep -qF 'Excluded #P: tracking issue (slice list, no ## What to build)' "$f"; then
    err "Step 1 exclusion message missing from ${f#"$ROOT"/}"; literals_ok=0
  fi
done
[ "$literals_ok" -eq 1 ] && ok "Part of pattern and Step 1 exclusion message present at every site"

# 6. Retired command names ------------------------------------------------------
if grep -rn 'to-issues' "$ROOT/skills" ; then
  err "skills reference retired command /to-issues (use /issue-plan)"
else
  ok "no retired command references in skills/"
fi

# 7. Embedded ```bash blocks must parse (bash -n) --------------------------------
# Placeholder tokens like <type>/issue-<number> are spec notation, not bash;
# neutralize them before parsing. Indented fences (blocks inside list items) count.
have_shellcheck=0
command -v shellcheck >/dev/null 2>&1 && have_shellcheck=1

for skill in "$ROOT"/skills/*/SKILL.md; do
  [ -f "$skill" ] || continue
  rel="${skill#"$ROOT"/}"
  prefix="$TMP/$(printf '%s' "$rel" | tr '/' '_')"
  awk -v prefix="$prefix" '
    !inb && /^[[:space:]]*```bash[[:space:]]*$/ { inb=1; n++; f=sprintf("%s.block%02d", prefix, n); next }
    inb && /^[[:space:]]*```[[:space:]]*$/     { inb=0; close(f); next }
    inb { print > f }
  ' "$skill"
  nblocks=0
  nbad=0
  for b in "$prefix".block*; do
    [ -f "$b" ] || continue
    nblocks=$((nblocks + 1))
    idx="${b##*.block}"
    sed 's/<[^>]*>/PLACEHOLDER/g' "$b" > "$b.sub"
    if ! bash -n "$b.sub" 2>"$b.err"; then
      nbad=$((nbad + 1))
      err "bash syntax error in $rel block $idx: $(head -1 "$b.err" | sed "s|$b.sub|block|")"
    fi
    # 8. shellcheck on the block (advisory only).
    if [ "$have_shellcheck" -eq 1 ]; then
      if ! shellcheck -s bash -e SC2148,SC2034,SC2154,SC2164 "$b.sub" >"$b.sc" 2>&1; then
        warn "shellcheck findings in $rel block $idx (advisory):"
        sed "s|$b.sub|  block $idx|" "$b.sc"
      fi
    fi
  done
  if [ "$nblocks" -gt 0 ] && [ "$nbad" -eq 0 ]; then
    ok "bash blocks parse: $rel ($nblocks blocks)"
  fi
done

# 8. shellcheck over this script and the bundled scripts (advisory) --------------
if [ "$have_shellcheck" -eq 1 ]; then
  for f in "$ROOT/scripts/lint.sh" "$ROOT"/skills/*/scripts/*.sh \
           "$ROOT/scripts/test-validation-contract.sh"; do
    rel="${f#"$ROOT"/}"
    if shellcheck "$f" >"$TMP/lint.sc" 2>&1; then
      ok "shellcheck clean: $rel"
    else
      warn "shellcheck findings in $rel (advisory):"
      cat "$TMP/lint.sc"
    fi
  done
else
  ok "shellcheck not installed - skipped (advisory check only)"
fi

# 9. Default-branch resolution one-liner: byte-identical everywhere --------------
DB_PAT='DEFAULT_BRANCH=$(git symbolic-ref'
occ_runner="$(grep -cF "$DB_PAT" "$SKILL_RUNNER")"
occ_gh="$(grep -cF "$DB_PAT" "$SKILL_GH")"
if [ "$occ_runner" -eq 0 ] || [ "$occ_gh" -eq 0 ]; then
  err "default-branch resolution one-liner missing (issue-runner=$occ_runner gh-issue=$occ_gh occurrences)"
else
  variants="$(grep -hF "$DB_PAT" "$SKILL_RUNNER" "$SKILL_GH" | sort -u | grep -c .)"
  if [ "$variants" -ne 1 ]; then
    err "default-branch resolution one-liner drifted: $variants variants across $((occ_runner + occ_gh)) sites (must be byte-identical)"
    grep -hF "$DB_PAT" "$SKILL_RUNNER" "$SKILL_GH" | sort -u | sed 's/^/  variant: /' >&2
  else
    ok "default-branch one-liner byte-identical across $((occ_runner + occ_gh)) sites"
  fi
fi

# 10. Branch-contract match pattern: resume-check.sh is its one statement --------
# gh-issue Step 4 names every implementer branch <type>/issue-<number>-<slug>.
# issue-runner finds an issue's branches with two forms, stated once in
# skills/issue-runner/scripts/resume-check.sh (its CONTRACT= and GLOB= lines):
# classify.sh must use the same two forms, both issue-runner editions must point
# at the script (Step 3 item 4's hung-worktree lookup still spells the first
# form, identically; this is not checked), and gh-issue (both editions)
# must still create and guard branches in that shape. Each file keeps its own
# placeholder spelling (<N> in issue-runner, <number> in gh-issue): the script,
# not the prose, is what matches.
RESUME_SCRIPT="$ROOT/skills/issue-runner/scripts/resume-check.sh"
CLASSIFY_SH="$ROOT/skills/issue-runner/scripts/classify.sh"
contract_ok=1
# shellcheck disable=SC2016 # literal on purpose: the script's own spelling
for form in 'CONTRACT="/issue-$N-"' 'GLOB="*/issue-$N-*"'; do
  grep -qF "$form" "$RESUME_SCRIPT" 2>/dev/null \
    || { err "branch-contract form '$form' missing from skills/issue-runner/scripts/resume-check.sh"; contract_ok=0; }
done
# shellcheck disable=SC2016 # literal on purpose
for form in '"/issue-$N-"' '"*/issue-$N-*"'; do
  grep -qF "$form" "$CLASSIFY_SH" 2>/dev/null \
    || { err "classify.sh does not use the branch-contract form $form that resume-check.sh states"; contract_ok=0; }
done
for f in "$SKILL_RUNNER" "$CANON_RUNNER"; do
  # shellcheck disable=SC2016 # literal on purpose
  grep -qF '`resume-check.sh` is the one statement of its match pattern' "$f" \
    || { err "${f#"$ROOT"/} does not point at resume-check.sh as the branch-contract pattern's statement"; contract_ok=0; }
done
for f in "$SKILL_GH" "$CANON_GH"; do
  { grep -qF 'git checkout -b <type>/issue-<number>-<short-slug>' "$f" && grep -qF "'*/issue-<number>-*'" "$f"; } \
    || { err "${f#"$ROOT"/} lost the branch-contract shape (<type>/issue-<number>-<slug>, '*/issue-<number>-*')"; contract_ok=0; }
done
[ "$contract_ok" -eq 1 ] && ok "branch-contract pattern stated once (resume-check.sh), used by classify.sh, created by gh-issue (both editions)"

# 11. result.json key set identical on every contract line, both editions -------
# A contract line starts with `{` and carries `"outcome":` — the shape line in
# both SKILL files and gh-issue's write recipe; prose that mentions "outcome" is
# not one. Compared per line (not unioned per file), so a key dropped from one
# of a file's two lines cannot hide behind the other. Values are free.
result_key_lines() {   # prints "<line-no>:<sorted,keys>" for each contract line of $1
  grep -nE '^[[:space:]]*\{.*"outcome":' "$1" | while IFS=: read -r ln rest; do
    printf '%s:%s\n' "$ln" "$(printf '%s' "$rest" | grep -oE '"[A-Za-z0-9_]+":' | tr -d '":' | sort -u | paste -sd, -)"
  done
}
# First contract line of gh-issue is the reference. Taken in the shell rather
# than via `| head -1`, which would close the pipe while the second line is
# still being printed and litter stderr with "Broken pipe".
gh_lines="$(result_key_lines "$SKILL_GH")"
keys_ref="${gh_lines%%$'\n'*}"; keys_ref="${keys_ref#*:}"
if [ -z "$keys_ref" ]; then
  err "result.json shape line (starting with '{', carrying '\"outcome\":') missing from ${SKILL_GH#"$ROOT"/}"
else
  keys_ok=1
  # Expected contract lines per file: gh-issue carries the shape line and the
  # write recipe (2); issue-runner carries the shape line only (1). Pinning the
  # count means a line that lost `"outcome":` itself cannot silently drop out.
  for entry in "$SKILL_GH:2" "$SKILL_RUNNER:1" "$CANON_GH:2" "$CANON_RUNNER:1"; do
    f="${entry%:*}"; want="${entry##*:}"
    lines="$(result_key_lines "$f")"
    have="$(printf '%s\n' "$lines" | grep -c .)"
    if [ "$have" -ne "$want" ]; then
      err "result.json contract lines in ${f#"$ROOT"/}: found $have, expected $want"
      keys_ok=0
    fi
    [ -n "$lines" ] || continue
    while IFS=: read -r ln k; do
      if [ "$k" != "$keys_ref" ]; then
        err "result.json key set drift at ${f#"$ROOT"/}:$ln: got '$k', expected '$keys_ref'"
        keys_ok=0
      fi
    done <<EOF_KEYS
$lines
EOF_KEYS
  done
  # The shape line (the first contract line of each file) also carries the enum
  # values Step 5 aggregates on; it must be byte-identical across all four files.
  shapes="$(for f in "$SKILL_GH" "$SKILL_RUNNER" "$CANON_GH" "$CANON_RUNNER"; do
    grep -m1 -E '^[[:space:]]*\{.*"outcome":' "$f" | sed 's/^[[:space:]]*//'
  done | sort -u | grep -c .)"
  if [ "$shapes" -ne 1 ]; then
    err "result.json shape line drifted: $shapes variants across the four SKILL files (enum values must match)"
    keys_ok=0
  fi
  [ "$keys_ok" -eq 1 ] && ok "result.json key set identical on every contract line and shape line byte-identical (both editions): $keys_ref"
fi

# 12. Scheduler golden fixtures --------------------------------------------------
TEST_SCHEDULER="$ROOT/skills/issue-runner/scripts/test-scheduler.sh"
if [ -f "$TEST_SCHEDULER" ]; then
  if bash "$TEST_SCHEDULER" >"$TMP/test-scheduler.out" 2>&1; then
    ok "scheduler golden fixtures pass (skills/issue-runner/scripts/test-scheduler.sh)"
  else
    err "scheduler golden fixtures failed:"
    cat "$TMP/test-scheduler.out" >&2
  fi
else
  err "$TEST_SCHEDULER not found"
fi

# 13. This repository's own validation contract parses -------------------------
# Same grammar as skills/gh-issue/scripts/validation-contract.sh (which reads the
# base branch's copy; this check reads the working tree's, before it lands):
# a typo here would block every implementer run on this repo at Step 5.
CONTRACT_FILE="$ROOT/.issue-runner/validation"
if [ -f "$CONTRACT_FILE" ]; then
  stray="$(grep -vE '^[[:space:]]*(#|$)' "$CONTRACT_FILE" | grep -vE '^(preflight|full):[[:space:]]*[^[:space:]#]' || true)"
  n_pre="$(grep -cE '^preflight:[[:space:]]*[^[:space:]#]' "$CONTRACT_FILE")"
  n_full="$(grep -cE '^full:[[:space:]]*[^[:space:]#]' "$CONTRACT_FILE")"
  if [ "$(tr -d '\000' < "$CONTRACT_FILE" | wc -c)" -ne "$(wc -c < "$CONTRACT_FILE")" ]; then
    err ".issue-runner/validation contains a NUL byte (the recipe rejects it: a shell variable would drop it and run a different command)"
  elif grep -q $'\r' "$CONTRACT_FILE"; then
    err ".issue-runner/validation has CRLF line endings (the recipe rejects them: the command would run with a trailing CR)"
  elif [ -n "$stray" ] || [ "$n_pre" -ne 1 ] || [ "$n_full" -gt 1 ]; then
    err ".issue-runner/validation is invalid (preflight lines=$n_pre, full lines=$n_full, first stray line: $(printf '%s\n' "$stray" | head -1))"
  else
    ok ".issue-runner/validation parses (preflight declared; full $([ "$n_full" -eq 1 ] && echo declared || echo not declared))"
  fi
else
  err "$CONTRACT_FILE not found"
fi

# 14. Validation-contract recipe fixtures -----------------------------------------
TEST_CONTRACT="$ROOT/scripts/test-validation-contract.sh"
if [ -f "$TEST_CONTRACT" ]; then
  if bash "$TEST_CONTRACT" >"$TMP/test-validation-contract.out" 2>&1; then
    ok "validation-contract fixtures pass (scripts/test-validation-contract.sh)"
  else
    err "validation-contract fixtures failed:"
    cat "$TMP/test-validation-contract.out" >&2
  fi
else
  err "$TEST_CONTRACT not found"
fi

# 15. issue-plan: Claude skill and Codex canonical copy byte-identical ------------
if cmp -s "$SKILL_PLAN" "$CANON_PLAN"; then
  ok "issue-plan skill byte-identical in both editions"
else
  err "issue-plan skill differs between ${SKILL_PLAN#"$ROOT"/} and ${CANON_PLAN#"$ROOT"/} (copy the Claude skill over the canonical file)"
fi

# 16. Prose review profile: one contract in both editions -------------------------
# gh-issue's Step 8 "Review profile" section (authority, revoke-only guard, the
# fixed profile text, prose triage) and the Phase 2 prose invocation must be
# byte-identical across editions; the dispatch line the runner writes must be
# the one gh-issue honors, in both editions.
profile_section() {   # the "#### Review profile" section, up to the next ####
  awk '/^#### Review profile/ {f=1; print; next} f && /^#### / {exit} f {print}' "$1"
}
prose_invocation() {  # the bash block that runs `codex review ... -` from the prompt file
  awk '/^```bash$/ {buf=""; f=1; next} f && /^```$/ {if (buf ~ /codex-prompt-/) {printf "%s", buf; exit} f=0; next} f {buf = buf $0 "\n"}' "$1"
}
prof_ok=1
for f in "$SKILL_GH" "$CANON_GH"; do
  [ -n "$(profile_section "$f")" ] || { err "gh-issue Review profile section missing from ${f#"$ROOT"/}"; prof_ok=0; }
  [ -n "$(prose_invocation "$f")" ] || { err "gh-issue prose Codex invocation missing from ${f#"$ROOT"/}"; prof_ok=0; }
  grep -qF 'Review profile: prose (user-authorized for issue #<number>)' "$f" \
    || { err "gh-issue dispatch-line contract missing from ${f#"$ROOT"/}"; prof_ok=0; }
  grep -qF 'Optional flag: `--review-profile standard|prose`' "$f" \
    || { err "gh-issue --review-profile flag line missing from ${f#"$ROOT"/}"; prof_ok=0; }
  grep -qF "unknown review profile '<name>' (expected standard or prose)" "$f" \
    || { err "gh-issue unknown-profile refusal missing from ${f#"$ROOT"/}"; prof_ok=0; }
done
if [ "$(profile_section "$SKILL_GH")" != "$(profile_section "$CANON_GH")" ]; then
  err "gh-issue Review profile section differs between editions"; prof_ok=0
fi
if [ "$(prose_invocation "$SKILL_GH")" != "$(prose_invocation "$CANON_GH")" ]; then
  err "gh-issue prose Codex invocation differs between editions"; prof_ok=0
fi
for f in "$SKILL_RUNNER" "$CANON_RUNNER"; do
  grep -qF '`- Review profile: prose (user-authorized for issue #<N>)`' "$f" \
    || { err "issue-runner Step 3a prose dispatch line missing from ${f#"$ROOT"/}"; prof_ok=0; }
  grep -qF '**Retry under the prose profile**' "$f" \
    || { err "issue-runner Step 4 prose-retry offer missing from ${f#"$ROOT"/}"; prof_ok=0; }
done
[ "$prof_ok" -eq 1 ] && ok "prose review profile: gh-issue section and invocation byte-identical in both editions; dispatch line agrees (4 files)"

# 17. Reviewer and gate liveness: one contract in both editions ------------------
# gh-issue's Step 8 "Liveness" section and the standard Phase 2 launch block
# (per-pass files, watchdog, .exit from the same subshell) must be byte-identical
# across editions, and no fixed /tmp gate-output name may come back.
liveness_section() {   # the "#### Liveness" section, up to the next ####
  awk '/^#### Liveness/ {f=1; print; next} f && /^#### / {exit} f {print}' "$1"
}
gate_launch() {        # the bash block that runs `codex review ... --base`
  awk '/^```bash$/ {buf=""; f=1; next} f && /^```$/ {if (buf ~ /codex review -c model=[^ ]+ --base/) {printf "%s", buf; exit} f=0; next} f {buf = buf $0 "\n"}' "$1"
}
live_ok=1
for f in "$SKILL_GH" "$CANON_GH"; do
  [ -n "$(liveness_section "$f")" ] || { err "gh-issue Liveness section missing from ${f#"$ROOT"/}"; live_ok=0; }
  for blk in gate_launch prose_invocation; do
    "$blk" "$f" | grep -qF '&& printf '"'"'%s\n'"'"' "$RC" >"$G.exit"' \
      || { err "gh-issue $blk block does not write .exit from its own subshell in ${f#"$ROOT"/}"; live_ok=0; }
  done
done
if [ "$(liveness_section "$SKILL_GH")" != "$(liveness_section "$CANON_GH")" ]; then
  err "gh-issue Liveness section differs between editions"; live_ok=0
fi
if [ "$(gate_launch "$SKILL_GH")" != "$(gate_launch "$CANON_GH")" ]; then
  err "gh-issue gate launch block differs between editions"; live_ok=0
fi
for f in "$SKILL_GH" "$CANON_GH" "$SKILL_RUNNER" "$CANON_RUNNER"; do
  grep -qF 'Silent-reviewer fallback: inline review authorized' "$f" \
    || { err "silent-reviewer fallback dispatch line missing from ${f#"$ROOT"/}"; live_ok=0; }
done
if grep -rn '/tmp/codex-review-\|/tmp/codex-prompt-' "$ROOT/skills" "$ROOT/codex" >/dev/null; then
  err "fixed /tmp Codex gate paths still referenced: $(grep -rln '/tmp/codex-review-\|/tmp/codex-prompt-' "$ROOT/skills" "$ROOT/codex" | tr '\n' ' ')"; live_ok=0
fi
[ "$live_ok" -eq 1 ] && ok "reviewer and gate liveness: gh-issue section and launch block byte-identical in both editions; no fixed /tmp gate paths"

# 18. Bundled scripts: parse, and Codex copies byte-identical ---------------------
# Deterministic recipes live as scripts under skills/<skill>/scripts/; the Codex
# edition ships its copy at codex/issue-runner/canonical/<skill>/scripts/. Every
# bundled script must parse, and every one with a Codex counterpart must be
# byte-identical to it (cmp), so the two editions never run different recipes.
# A Codex script with no Claude original is drift too, and so is a missing copy
# of a script the Codex canonical procedure runs.
bundled_ok=1; n_bundled=0; n_pairs=0
for f in "$ROOT"/skills/*/scripts/*; do
  [ -f "$f" ] || continue
  rel="${f#"$ROOT"/skills/}"; n_bundled=$((n_bundled + 1))
  case "$f" in
    *.sh) bash -n "$f" 2>"$TMP/bundled.err" \
            || { err "bash syntax error in skills/$rel: $(head -1 "$TMP/bundled.err")"; bundled_ok=0; } ;;
  esac
  c="$ROOT/codex/issue-runner/canonical/$rel"
  [ -e "$c" ] || continue
  n_pairs=$((n_pairs + 1))
  cmp -s "$f" "$c" \
    || { err "skills/$rel differs from its Codex copy codex/issue-runner/canonical/$rel (copy the Claude script over it)"; bundled_ok=0; }
done
for c in "$ROOT"/codex/issue-runner/canonical/*/scripts/*; do
  [ -f "$c" ] || continue
  rel="${c#"$ROOT"/codex/issue-runner/canonical/}"
  [ -f "$ROOT/skills/$rel" ] \
    || { err "codex/issue-runner/canonical/$rel has no original at skills/$rel"; bundled_ok=0; }
done
for required in gh-issue/scripts/validation-contract.sh issue-runner/scripts/classify.sh \
                issue-runner/scripts/resume-check.sh issue-runner/scripts/merge-ready.sh; do
  [ -f "$ROOT/codex/issue-runner/canonical/$required" ] \
    || { err "codex/issue-runner/canonical/$required missing (the Codex canonical procedure runs it)"; bundled_ok=0; }
done
# The procedure that runs the script (resolution, modes, outcomes) is one
# contract too: gh-issue's "## Validation contract" section, byte-identical.
vc_section() { awk '/^## Validation contract$/ {f=1; print; next} f && /^## / {exit} f {print}' "$1"; }
if [ -z "$(vc_section "$SKILL_GH")" ] || [ "$(vc_section "$SKILL_GH")" != "$(vc_section "$CANON_GH")" ]; then
  err "gh-issue '## Validation contract' section missing or differs between editions"; bundled_ok=0
fi
# Those shared sections point at gh-issue's REFERENCE.md rationale entries, so the
# Codex edition ships the same file.
cmp -s "$ROOT/skills/gh-issue/REFERENCE.md" "$ROOT/codex/issue-runner/canonical/gh-issue/REFERENCE.md" \
  || { err "skills/gh-issue/REFERENCE.md missing or differs from codex/issue-runner/canonical/gh-issue/REFERENCE.md"; bundled_ok=0; }
[ "$bundled_ok" -eq 1 ] && ok "bundled scripts parse ($n_bundled); Codex copies byte-identical ($n_pairs pairs); Validation contract section and gh-issue REFERENCE.md byte-identical in both editions"

# 19. Merge-proof and PR-shape classification fixtures ----------------------------
TEST_CLASSIFY="$ROOT/skills/issue-runner/scripts/test-classify.sh"
if [ -f "$TEST_CLASSIFY" ]; then
  if bash "$TEST_CLASSIFY" >"$TMP/test-classify.out" 2>&1; then
    ok "classification fixtures pass (skills/issue-runner/scripts/test-classify.sh)"
  else
    err "classification fixtures failed:"
    cat "$TMP/test-classify.out" >&2
  fi
else
  err "$TEST_CLASSIFY not found"
fi

# 20. Run-state fixtures ----------------------------------------------------------
TEST_RUN_STATE="$ROOT/skills/issue-runner/scripts/test-run-state.sh"
if [ -f "$TEST_RUN_STATE" ]; then
  if bash "$TEST_RUN_STATE" >"$TMP/test-run-state.out" 2>&1; then
    ok "run-state fixtures pass (skills/issue-runner/scripts/test-run-state.sh)"
  else
    err "run-state fixtures failed:"
    cat "$TMP/test-run-state.out" >&2
  fi
else
  err "$TEST_RUN_STATE not found"
fi

# 21. Resume-check fixtures -------------------------------------------------------
TEST_RESUME="$ROOT/skills/issue-runner/scripts/test-resume-check.sh"
if [ -f "$TEST_RESUME" ]; then
  if bash "$TEST_RESUME" >"$TMP/test-resume-check.out" 2>&1; then
    ok "resume-check fixtures pass (skills/issue-runner/scripts/test-resume-check.sh)"
  else
    err "resume-check fixtures failed:"
    cat "$TMP/test-resume-check.out" >&2
  fi
else
  err "$TEST_RESUME not found"
fi

# 22. Merge-ready fixtures --------------------------------------------------------
TEST_MERGE_READY="$ROOT/skills/issue-runner/scripts/test-merge-ready.sh"
if [ -f "$TEST_MERGE_READY" ]; then
  if bash "$TEST_MERGE_READY" >"$TMP/test-merge-ready.out" 2>&1; then
    ok "merge-ready fixtures pass (skills/issue-runner/scripts/test-merge-ready.sh)"
  else
    err "merge-ready fixtures failed:"
    cat "$TMP/test-merge-ready.out" >&2
  fi
else
  err "$TEST_MERGE_READY not found"
fi

# 23. Spec size ceilings -----------------------------------------------------------
# Procedure stays in SKILL.md; rationale lives in REFERENCE.md. The ceilings stop
# the specs regrowing: `wc -w` words per file, and no line longer than the limit.
MAX_LINE_CHARS=1500
size_ok=1
while IFS='|' read -r f ceiling; do
  [ -r "$f" ] || { err "${f#"$ROOT"/} missing or unreadable (spec size ceilings)"; size_ok=0; continue; }
  words="$(wc -w < "$f" | tr -d ' ')"
  case $words in ''|*[!0-9]*) err "${f#"$ROOT"/}: cannot count words"; size_ok=0; continue ;; esac
  if [ "$words" -gt "$ceiling" ]; then
    err "${f#"$ROOT"/} has $words words, over its ceiling of $ceiling"; size_ok=0
  fi
  longest="$(awk '{ n = length($0); if (n > m) m = n } END { print m + 0 }' "$f")"
  if [ "$longest" -gt "$MAX_LINE_CHARS" ]; then
    err "${f#"$ROOT"/} has a $longest-character line, over the ceiling of $MAX_LINE_CHARS"; size_ok=0
  fi
done <<EOF_SIZE
$SKILL_RUNNER|11000
$SKILL_GH|9000
EOF_SIZE
[ "$size_ok" -eq 1 ] && ok "spec size ceilings hold (issue-runner SKILL.md <= 11000 words, gh-issue SKILL.md <= 9000, lines <= $MAX_LINE_CHARS chars)"

if [ "$fail" -ne 0 ]; then
  printf '\nlint: FAILED\n' >&2
  exit 1
fi
printf '\nlint: OK\n'
