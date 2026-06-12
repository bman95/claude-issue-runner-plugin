# issue-runner

A Claude Code plugin that orchestrates multi-issue GitHub workflows end-to-end.

The orchestrator reads the open-issue queue, builds a dependency DAG, and dispatches each issue to an **autonomous implementer subagent** in an isolated worktree. Implementers spawn their own subagents — an `Explore` agent to map the codebase, fresh-eyes reviewer agents for the review loop — then converge the PR through a Codex gate and merge it. Independent issues run in parallel up to a configurable cap; failures cascade-skip downstream dependents.

## Status

Pre-1.0. The skill works on real-world runs but the spec is still tightening based on production use. See `CHANGELOG.md` for what changed and why.

## Installation

This plugin is not yet published to a public marketplace. To install locally:

```bash
git clone <this-repo> ~/personal/claude-issue-runner-plugin
ln -s ~/personal/claude-issue-runner-plugin/skills/issue-runner ~/.claude/skills/issue-runner
ln -s ~/personal/claude-issue-runner-plugin/skills/gh-issue ~/.claude/skills/gh-issue
```

Reload Claude Code and invoke `/issue-runner`.

When installed via a marketplace, the symlinks are not needed — Claude Code discovers both bundled skills and exposes `${CLAUDE_PLUGIN_ROOT}` so `issue-runner` can locate `gh-issue` portably (Step 0 in `skills/issue-runner/SKILL.md`).

## Usage

```
/issue-runner                              # all open issues (label-filtered)
/issue-runner 42 43 44                     # specific issue numbers
/issue-runner --plan                       # build the DAG and exit
/issue-runner --max-parallel N             # concurrency cap (default 10)
/issue-runner --max-codex-iterations N     # Codex gate cap per implementer (default 2)
/issue-runner --no-llm-refine              # skip LLM dependency refinement
/issue-runner --sequential                 # equivalent to --max-parallel 1
```

A single-issue scope skips orchestration entirely and runs the `gh-issue` procedure inline. `/gh-issue N` also works standalone.

## Architecture

- **Orchestrator** (`skills/issue-runner/SKILL.md`): scope (label filters, optional `ready-for-agent` triage filter, dirty-tree audit) → dependency DAG (heuristic + LLM refinement) → parallel dispatch → blocker escalation → cleanup. The orchestrator never enters a worktree.
- **Implementer** (`skills/gh-issue/SKILL.md`): understand → explore (Explore subagent) → plan → branch → implement → PR → layered review → merge. The review runs fresh-eyes reviewer subagents locally (no Codex spend) and uses `codex review` only as a final certification gate (1–2 passes per PR), with a credit/quota degradation path.
- **Reference** (`skills/issue-runner/REFERENCE.md`): troubleshooting and the rationale behind the defensive recipes (worktree locks, branch deletion after squash merges, duplicate PRs on re-runs).

## Requirements

- **Claude Code** with the Agent and Bash tools; subagents must be able to spawn subagents (current `general-purpose` agents do).
- **GitHub CLI (`gh`)** authenticated against the target repository.
- **`codex` CLI** for the review gate (degrades gracefully on credit/quota exhaustion).
- **`/codex:rescue`** for the rescue escalation. Optional but referenced by the spec.
- **Git >= 2.5** (worktrees).

The `gh-issue` implementer skill is bundled — no separate installation.

## Known limitations

- **Single-host, single-user.** Concurrent `/issue-runner` runs collide on `/tmp/issue-runner/state/`.
- **Not auto-invocable** (`disable-model-invocation: true` on both skills) — only the user can trigger them.
- **Re-runs are fresh orchestrations.** A re-run does not reuse an existing PR; close a blocked run's PR before re-running its issue.
- **No automated tests.** Behavior is validated by production runs documented in `CHANGELOG.md`.

## Versioning

Semantic-ish. Pre-1.0 means the spec may change incompatibly between minor versions.

## License

MIT. See `LICENSE`.
