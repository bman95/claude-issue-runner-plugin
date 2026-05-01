# issue-runner

A Claude Code plugin that orchestrates multi-issue GitHub workflows end-to-end.

The orchestrator reads the open-issue queue, builds a dependency DAG, and dispatches each issue through an Explore -> optional Plan -> Implement-in-worktree pipeline. Independent issues run in parallel up to a configurable cap; failures cascade-skip downstream dependents. Implementer subagents follow the `gh-issue` procedure (branch -> implement -> PR -> review -> merge) inside isolated worktrees.

## Status

Pre-1.0. The skill works on real-world runs but the spec is still tightening based on production use. See `CHANGELOG.md` for what changed and why.

## Installation

This plugin is not yet published to a public marketplace. To install locally:

```bash
git clone <this-repo> ~/personal/claude-issue-runner-plugin
ln -s ~/personal/claude-issue-runner-plugin/skills/issue-runner ~/.claude/skills/issue-runner
ln -s ~/personal/claude-issue-runner-plugin/skills/gh-issue ~/.claude/skills/gh-issue
```

Reload Claude Code (or run `/reload-plugins` if available) and invoke `/issue-runner`.

When this plugin is installed via a marketplace, the symlinks above are not needed — Claude Code discovers both bundled skills (`issue-runner` and `gh-issue`) inside the plugin's install directory and exposes `${CLAUDE_PLUGIN_ROOT}` so `issue-runner` can locate `gh-issue` portably (see Step 0 in `skills/issue-runner/SKILL.md`).

## Usage

```
/issue-runner                              # all open issues (label-filtered)
/issue-runner 42 43 44                     # specific issue numbers
/issue-runner --plan                       # build the DAG and exit
/issue-runner --max-parallel N             # concurrency cap (default 2)
/issue-runner --max-codex-iterations N     # codex review loop cap (default 3)
/issue-runner --no-llm-refine              # skip LLM dependency refinement
/issue-runner --sequential                 # equivalent to --max-parallel 1
```

The full procedure is documented inside `skills/issue-runner/SKILL.md` (the orchestrator reads it at run time).

## Requirements

- **Claude Code** with the Agent and Bash tools available.
- **GitHub CLI (`gh`)** installed and authenticated against the target repository.
- **`codex` CLI** if you want the Codex review loop to run inside implementers (`codex review --base $BASE_BRANCH`).
- **`/codex:rescue` plugin command** for Step 5's "Hand off to /codex:rescue" escalation. Optional but referenced by the spec.
- **Git worktree support** (any modern git, >= 2.5).

The `gh-issue` skill (the implementer procedure) is **bundled** in this plugin under `skills/gh-issue/` — no separate installation needed.

## What it does well

- Builds a real dependency graph from issue bodies + comments (heuristic + optional LLM refinement pass).
- Runs implementers in worktree-isolated subagents so parallel work does not collide.
- Cascade-skips failed dependents instead of trying everything serially.
- Detects DAG cycles and surfaces them rather than deadlocking.
- Persists state under `/tmp/issue-runner/state/` so a partial-failure run can be inspected (and partially resumed via re-invocation with the failed subset).
- Pre-flight checks: parked-label filter, dirty-tree audit, scope-shaping addendum.

## Known limitations

- **Single-host, single-user assumption.** Two concurrent `/issue-runner` runs on the same machine collide on `/tmp/issue-runner/state/`. See "Hard rules" in `SKILL.md`.
- **Not auto-invocable** (`disable-model-invocation: true`). The skill only runs when the user types `/issue-runner` — it never auto-loads from descriptions. Same for `/gh-issue`.
- **No automated tests yet.** Behavior is validated by production runs documented in `CHANGELOG.md`.
- **`gh-issue` is forked into this plugin.** If the upstream `gh-issue` skill (if/when published independently) gains improvements, they have to be manually merged here. Trade-off accepted to keep the plugin self-contained on install.

## Versioning

Semantic-ish. Pre-1.0 means the spec inside `SKILL.md` may still change in incompatible ways between minor versions (e.g. status names, escalation options). Once 1.0 ships, breaking changes will bump the major.

## License

MIT. See `LICENSE`.
