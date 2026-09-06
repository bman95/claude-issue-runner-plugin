#!/usr/bin/env bash
#
# Consistency lint for the issue-runner plugin.
#
# A prompt-spec plugin has no runnable code to test, but its manifests and docs
# drift against each other in mechanically-checkable ways. This script guards the
# drift classes that have actually bitten releases:
#
#   1. plugin.json version == marketplace.json version == codex plugin.json version
#   2. every skills/*/SKILL.md frontmatter has name + description + version
#   3. --max-parallel default agrees across README, SKILL arg line, and the
#      Step 3 runtime `Set \`MAX_PARALLEL\` (default N)` line
#   4. CHANGELOG has an entry for the manifest version
#   5. the issue-body contract strings appear in both issue-plan and issue-runner
#   6. no skill references retired command names (e.g. /to-issues)
#   7. every ```bash block embedded in skills/*/SKILL.md parses (bash -n,
#      after neutralizing <placeholder> tokens)
#   8. shellcheck (if installed) over this script and the extracted blocks —
#      findings are WARNINGS only, never failures
#   9. the default-branch resolution one-liner is byte-identical at every site
#  10. both SKILL files carry the /issue-< branch-contract match (placeholder
#      spelling drift <N> vs <number> is a warning)
#  11. the Codex edition's canonical copies (codex/issue-runner/canonical/) are
#      byte-identical to skills/ — its stubs say "follow the canonical procedure" —
#      and each stub's frontmatter version matches the skill it wraps
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

# 1. Manifest version agreement -------------------------------------------------
CODEX_JSON="$ROOT/codex/issue-runner/.codex-plugin/plugin.json"
plugin_version="$(json_version "$PLUGIN_JSON")"
market_version="$(json_version "$MARKET_JSON")"
codex_version="$(json_version "$CODEX_JSON")"
if [ -z "$plugin_version" ]; then
  err "could not read version from $PLUGIN_JSON"
elif [ -z "$market_version" ]; then
  err "could not read version from $MARKET_JSON"
elif [ -z "$codex_version" ]; then
  err "could not read version from $CODEX_JSON"
elif [ "$plugin_version" != "$market_version" ] || [ "$plugin_version" != "$codex_version" ]; then
  err "version mismatch: plugin.json=$plugin_version marketplace.json=$market_version codex plugin.json=$codex_version"
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
for s in '## Blocked by' 'None - can start immediately'; do
  for f in "$SKILL_PLAN" "$SKILL_RUNNER"; do
    if ! grep -qF "$s" "$f"; then
      err "contract string '$s' missing from ${f#"$ROOT"/}"
    fi
  done
done
ok "issue-body contract strings present in planner and runner"

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

# 8. shellcheck over this script itself (advisory only) --------------------------
if [ "$have_shellcheck" -eq 1 ]; then
  if shellcheck "$ROOT/scripts/lint.sh" >"$TMP/lint.sc" 2>&1; then
    ok "shellcheck clean: scripts/lint.sh"
  else
    warn "shellcheck findings in scripts/lint.sh (advisory):"
    cat "$TMP/lint.sc"
  fi
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

# 10. Branch-contract match pattern in both SKILL files --------------------------
contract_ok=1
for f in "$SKILL_RUNNER" "$SKILL_GH"; do
  if ! grep -qF '/issue-<' "$f"; then
    err "branch-contract pattern '/issue-<' missing from ${f#"$ROOT"/}"
    contract_ok=0
  fi
done
if [ "$contract_ok" -eq 1 ]; then
  ok "branch-contract '/issue-<' present in both SKILL files"
  # Placeholder spelling drift is cosmetic: warn, don't fail.
  spellings() {
    s=""
    grep -qF '/issue-<N>' "$1" && s="$s<N>"
    grep -qF '/issue-<number>' "$1" && s="$s<number>"
    printf '%s' "$s"
  }
  sp_runner="$(spellings "$SKILL_RUNNER")"
  sp_gh="$(spellings "$SKILL_GH")"
  if [ "$sp_runner" != "$sp_gh" ]; then
    warn "branch-contract placeholder spelling differs: issue-runner uses '$sp_runner', gh-issue uses '$sp_gh'"
  fi
fi

# 11. Codex edition canonical copies byte-identical to skills/ ------------------
CANON="$ROOT/codex/issue-runner/canonical"
canon_ok=1
for src in "$ROOT"/skills/*/SKILL.md "$ROOT"/skills/issue-runner/REFERENCE.md; do
  rel="${src#"$ROOT"/skills/}"
  if ! cmp -s "$src" "$CANON/$rel"; then
    err "codex canonical copy drifted: codex/issue-runner/canonical/$rel != skills/$rel"
    canon_ok=0
  fi
done
for stub in "$ROOT"/codex/issue-runner/skills/*/SKILL.md; do
  [ -f "$stub" ] || continue
  name="$(basename "$(dirname "$stub")")"
  stub_v="$(frontmatter "$stub" | sed -nE 's/^version:[[:space:]]*//p' | head -1)"
  skill_v="$(frontmatter "$ROOT/skills/$name/SKILL.md" | sed -nE 's/^version:[[:space:]]*//p' | head -1)"
  if [ -z "$skill_v" ] || [ "$stub_v" != "$skill_v" ]; then
    err "codex stub version drift: codex/issue-runner/skills/$name ($stub_v) != skills/$name ($skill_v)"
    canon_ok=0
  fi
done
[ "$canon_ok" -eq 1 ] && ok "codex canonical copies byte-identical to skills/, stub versions match"

if [ "$fail" -ne 0 ]; then
  printf '\nlint: FAILED\n' >&2
  exit 1
fi
printf '\nlint: OK\n'
