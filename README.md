# issue-runner

A self-sufficient Claude Code plugin for the full agentic issue pipeline: from an idea to merged PRs.

- **`/issue-plan`** turns an idea, plan, or spec into ready-to-run issues: it asks only the questions the input needs, slices the work into tracer-bullet vertical slices, and publishes issues in the format the runner parses.
- **`/issue-runner`** reads the issue queue, builds a dependency DAG, and dispatches each issue to an **autonomous implementer subagent** in an isolated worktree. Implementers spawn their own subagents — `Explore`/`Plan` helpers, fresh-eyes reviewers, delegated `general-purpose` chunks (helpers don't nest further) — then converge the PR through a Codex gate and merge it. Independent issues run in parallel up to a configurable cap; failures cascade-skip downstream dependents.

Run-time doubts escalate up the chain: implementer → parent (resolves coordination/context blockers from run-wide knowledge) → human (only for scope, product-behavior, or risk decisions).

## Status

Pre-1.0. The skill works on real-world runs but the spec is still tightening based on production use. See `CHANGELOG.md` for what changed and why.

## Installation

Install from the marketplace, then reload plugins:

```
/plugin marketplace add bman95/claude-issue-runner-plugin
/plugin install issue-runner@bman95-plugins
/reload-plugins
```

Claude Code discovers all three bundled skills and exposes `${CLAUDE_PLUGIN_ROOT}`, so `issue-runner` locates `gh-issue` portably (Step 0 in `skills/issue-runner/SKILL.md`) — no symlinks needed.

Plugin skills are namespaced by the plugin name, so the commands are `/issue-runner:issue-plan`, `/issue-runner:issue-runner`, and `/issue-runner:gh-issue` (the examples below use these forms).

### Local development

To run from a working copy without going through a hosted marketplace, point the marketplace at the cloned directory — same install path as above, just a local source:

```bash
git clone <this-repo> ~/personal/claude-issue-runner-plugin
```

```
/plugin marketplace add ~/personal/claude-issue-runner-plugin
/plugin install issue-runner@bman95-plugins
/reload-plugins
```

## Usage

```
/issue-runner:issue-plan <idea | plan | file | issue#>  # idea -> published, runnable issues
/issue-runner:issue-runner                              # all open issues (label-filtered)
/issue-runner:issue-runner 42 43 44                     # specific issue numbers
/issue-runner:issue-runner --plan                       # build the DAG and exit
/issue-runner:issue-runner --max-parallel N             # concurrency cap (default 5)
/issue-runner:issue-runner --max-codex-iterations N     # Codex gate cap per implementer (default 2)
/issue-runner:issue-runner --no-llm-refine              # skip LLM dependency refinement
/issue-runner:issue-runner --sequential                 # equivalent to --max-parallel 1
```

A single-issue scope skips orchestration entirely and runs the `gh-issue` procedure inline. `/issue-runner:gh-issue N` also works standalone.

## Architecture

- **Planner** (`skills/issue-plan/SKILL.md`): absorb the idea → adaptive interrogation (human decisions settled up front) → tracer-bullet vertical slices → publish issues with `## What to build` / `## Acceptance criteria` / `## Blocked by` — the contract the runner and implementer parse.
- **Orchestrator** (`skills/issue-runner/SKILL.md`): scope (label filters, dirty-tree audit) → dependency DAG (`## Blocked by` primary, heuristics + LLM refinement as fallback) → parallel dispatch → two-tier blocker escalation (parent first, human last) → cleanup. The orchestrator never enters a worktree.
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

- **Trust the issue authors.** Implementers consume issue bodies and comments verbatim as their task spec and, in orchestrated mode, hold merge authority (`gh pr merge` with no human gate). Do **not** point `/issue-runner` at a repo whose issues can be authored by untrusted parties — a malicious issue body is prompt-injection executed as instructions by an agent that can merge to your default branch. The pipeline is safe when you author the issues yourself (via `/issue-plan`); the spec instructs implementers to treat issue content as data, but that is a mitigation, not a sandbox.
- **Single-host, single-user.** State lives at `/tmp/issue-runner/<repo-key>/state`, namespaced by repo root, so runs in **different** repos are isolated. Two concurrent `/issue-runner` runs *in the same repo* still collide on that path — don't run two at once in one repo.
- **Not auto-invocable** (`disable-model-invocation: true` on both skills) — only the user can trigger them.
- **Re-runs are fresh orchestrations.** A re-run does not reuse an existing PR; close a blocked run's PR before re-running its issue.
- **No automated tests.** Behavior is validated by production runs documented in `CHANGELOG.md`.

## Versioning

Semantic-ish. Pre-1.0 means the spec may change incompatibly between minor versions.

## License

MIT. See `LICENSE`.
