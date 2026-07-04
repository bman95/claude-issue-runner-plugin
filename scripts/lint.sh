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
#   3. README --max-parallel default == issue-runner SKILL default
#   4. CHANGELOG has an entry for the manifest version
#   5. the issue-body contract strings appear in both issue-plan and issue-runner
#   6. no skill references retired command names (e.g. /to-issues)
#
# Dependency-free: bash + coreutils/grep/sed/awk only (no jq). Exits non-zero on
# the first-or-any failure, printing every problem it found.

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0

err() { printf 'FAIL: %s\n' "$1" >&2; fail=1; }
ok()  { printf 'ok:   %s\n' "$1"; }

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

# 3. README vs SKILL --max-parallel default ------------------------------------
readme_mp="$(max_parallel_default "$README")"
skill_mp="$(max_parallel_default "$SKILL_RUNNER")"
if [ -z "$readme_mp" ] || [ -z "$skill_mp" ]; then
  err "could not read --max-parallel default (README='$readme_mp' SKILL='$skill_mp')"
elif [ "$readme_mp" != "$skill_mp" ]; then
  err "--max-parallel default drift: README=$readme_mp SKILL=$skill_mp"
else
  ok "--max-parallel default agrees ($readme_mp)"
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

if [ "$fail" -ne 0 ]; then
  printf '\nlint: FAILED\n' >&2
  exit 1
fi
printf '\nlint: OK\n'
