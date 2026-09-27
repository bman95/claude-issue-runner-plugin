---
name: issue-plan
version: 0.5.0
description: Use when the user asks to turn an idea, plan, or specification into dependency-aware GitHub issues that autonomous implementers can execute.
disable-model-invocation: false
---

# Issue Plan for Codex

Read [the bundled canonical planner procedure](../../canonical/issue-plan/SKILL.md) completely and follow it, with the Codex adaptations below taking precedence wherever the procedure names Claude Code primitives.

## Codex adaptations

- Natural-language requests such as “plan this as GitHub issues” are equivalent to `/issue-plan`.
- Use `spawn_agent` for a concrete, bounded, read-only codebase-mapping task instead of an `Explore` agent. If delegation is unavailable or unnecessary, explore inline.
- Step 2's reconciliation with existing work is read-only: run its `gh issue list` / `gh pr list` commands directly and read the design documents the exploration found (or fold both into the same bounded `spawn_agent` mapping task). Its `conflict` and `supersedes` questions are asked directly like any other interview question.
- Ask necessary questions directly. Do not use `AskUserQuestion`. Prefer one concise question at a time and state the recommended answer first.
- Before `gh issue create`, show the final issue breakdown and obtain the same explicit publication approval required by the canonical procedure. Publishing issues is an external write; that approval covers the tracking issue's create and its later `gh issue edit`s as well as the slices — if the host prompts, answer once rather than skip them.
- Read `AGENTS.md` as well as `CLAUDE.md` when either exists. Repository instructions override this skill.

The issue-body contract, dependency ordering, approval boundary, and all GitHub commands remain exactly as defined by the canonical procedure.
