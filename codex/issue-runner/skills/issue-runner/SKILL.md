---
name: issue-runner
version: 0.9.0
description: Use when the user explicitly asks to run or orchestrate a GitHub issue queue using dependency-aware, worktree-isolated implementers.
disable-model-invocation: false
---

# Issue Runner for Codex

Read [the bundled canonical orchestrator procedure](../../canonical/issue-runner/SKILL.md) and its [reference](../../canonical/issue-runner/REFERENCE.md) completely. Follow them with the Codex adaptations below taking precedence wherever they name Claude Code primitives.

## Codex adaptations

- Natural-language requests such as “run issues 42, 43, and 44” are equivalent to `/issue-runner 42 43 44`.
- Resolve `GH_ISSUE_SKILL` to the absolute path of this plugin's `skills/gh-issue/SKILL.md`. Do not use `CLAUDE_PLUGIN_ROOT` or the Claude implementer skill.
- Ask the user directly instead of using `AskUserQuestion`.
- Dispatch each implementer with `spawn_agent`, using a stable task name such as `issue_42`. The implementer must read the resolved Codex `gh-issue` skill first.
- Codex subagents share the filesystem. The dispatch prompt must tell a fresh implementer to create and enter its own unique worktree before editing; a resumed implementer must enter the existing recorded worktree. The parent never enters an implementer worktree.
- Use `list_agents`, agent completion messages, and `wait_agent` to supervise the in-flight set. Respect the four-slot host limit even when `--max-parallel` is higher: reserve one slot for the parent, so at most three direct implementers may run concurrently unless the active environment exposes a larger limit.
- Step 3 item 4's hang wake-up maps to a bounded `wait_agent` (timeout well under `HANG_MINUTES`); on every return — completion or timeout — drain results first, then run the hang check. `TaskStop` maps to `close_agent` (not `interrupt_agent`, which interrupts a turn and leaves the agent alive), and `list_agents` is the liveness check before stopping an agent, after stopping it and before classifying, and before a retry re-enters its worktree.
- Implementers may use bounded helpers only when a slot is available. Helpers must not spawn further agents.
- Replace the Claude `Agent` dispatch template with `spawn_agent`, preserving every input path, review cap, merge rule, blocker rule, and required `worktree:` result line from that template.
- For rescue, dispatch a fresh diagnostic subagent instead of invoking `/codex:rescue`.
- `$PPID` may not identify the long-lived Codex session host. Before relying on a live PID lock, verify the recorded process belongs to the active run; otherwise treat filesystem state plus active-agent inspection as authoritative. Never remove a lock known to belong to a live run.
- **Launch-time precondition: the run root must be writable.** `${XDG_STATE_HOME:-$HOME/.local/state}/issue-runner` lies outside the default `workspace-write` sandbox's writable roots (the workspace, `/tmp`, `$TMPDIR`), writable roots are fixed when Codex starts, and the State block has no `/tmp` fallback: its write probe refuses scope ≥ 2 and `--plan` with `run root is not writable` plus the relaunch instruction. Before orchestrating, create the root from an unsandboxed shell (`mkdir -p`; sandboxes resolve writable roots against existing paths) and launch Codex with it granted — `codex --add-dir "${XDG_STATE_HOME:-$HOME/.local/state}/issue-runner"` or `sandbox_workspace_write.writable_roots` in `config.toml`. If the check fails mid-session, relay its message and stop: the user must relaunch; do not retry under a different root.

The DAG contract, state files, cascade behavior, positive merge proof, dirty-tree protection, review gates, and cleanup rules remain exactly as defined by the canonical procedure.
