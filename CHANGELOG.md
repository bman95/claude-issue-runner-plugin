# Changelog

All notable changes to this plugin will be documented here. Versions follow semver-ish: pre-1.0 minor bumps may include breaking changes to the skill spec.

## [0.6.0] - 2026-06-13

### Self-sufficient pipeline: /issue-plan added, triage removed, two-tier escalation

The plugin now covers the whole flow from idea to merged PRs, fully agentic. Human decisions concentrate at two points: the planning interview (up front) and scope/risk escalations (during the run).

- **New bundled skill `issue-plan` (0.1.0).** Adapts the grill-with-docs + to-issues pair into one command without the docs machinery (no CONTEXT.md/ADR updates) and without triage labels: absorb the idea → explore the codebase before asking → adaptive interrogation (one question at a time, recommended answer first; run-time-blocker-shaped decisions settled here) → tracer-bullet vertical slices (user approves the breakdown) → publish in dependency order using the `## What to build` / `## Acceptance criteria` / `## Blocked by` contract → offer to launch `/issue-runner`.
- **Triage dropped from the pipeline.** The 0.5.0 `ready-for-agent` scope filter and gh-issue's agent-brief mention are removed. Rationale (REFERENCE.md): label state machines filter *incoming external* issues; this pipeline's issues are born agent-ready from `/issue-plan`. The parked-label blacklist remains as the manual brake.
- **Two-tier blocker escalation (Step 4).** The parent now tries to resolve a blocker itself first — it holds the DAG, other issues' status, merged PRs, and the repo; coordination/context blockers get answered via `guidance.md` + retry without user involvement. Only scope / product-behavior / risk decisions escalate to the human.
- **Implementer subagent powers made explicit (gh-issue 0.4.0, new "Your subagents" section).** Implementers have the full tool surface: Explore, Plan, general-purpose helpers (reviewers, delegated chunks), codex via Bash. Two rules: helpers inherit the implementer's worktree (never nested worktree isolation), and helpers must not spawn further subagents — depth is capped at parent → implementer → helper, and the implementer stays the single integrator of its PR.
- plugin.json description rewritten for the pipeline; README updated (architecture, usage, third symlink for `issue-plan`).

## [0.5.1] - 2026-06-12

### Restore `## Blocked by` as the primary DAG source

The pre-plugin standalone copy of issue-runner parsed the `## Blocked by` section that `/to-issues` emits in every issue body; that behavior was lost when the plugin became canonical (its divergences were never ported). Restored in Step 2: bullets referencing `#X` are dependency edges, "None - can start immediately" means no deps, and the inline-phrase regex (`depends on #X` etc.) is now the fallback for issues not authored by `/to-issues`. When every in-scope issue carries the section, the LLM refinement pass is asked for `conflict` edges only — dependencies are already explicit and deterministic.

Also: gh-issue (0.3.1) now treats an `## Acceptance criteria` checklist in the issue body as the definition of done, verified before opening the PR.

## [0.5.0] - 2026-06-12

### Redesign around nested subagents; spec cut roughly in half

Subagents can now spawn their own subagents (`general-purpose` exposes the full tool surface, including `Agent`). The orchestrator no longer pre-chews context or enters worktrees — implementers are autonomous. `issue-runner` SKILL.md 534 → ~210 lines, `gh-issue` 219 → ~140 lines, with the audit-derived defensive knowledge preserved (compressed in place or moved to the new `skills/issue-runner/REFERENCE.md`).

**issue-runner (spec restructured, Steps renumbered 0–5):**
- **Removed the Explore/Plan pre-pass** (old Step 3) and its state files (`exploration.md`, `plan.md`), wave management, and `Files:`-block parsing. Implementers gather their own context by spawning an `Explore` subagent (gh-issue Step 2).
- **Escalations 6 → 4** (retry / rescue / fail / bump-and-rerun). "Parent-side codex re-review" and "parent-applied inline fix" are gone: a retried implementer runs its own codex passes and helpers inside the worktree. Consequently the `pushd`/`popd` discipline, the Step 6 cwd-verification recipe, and the old "Parent stays in main repo" rule collapse into one hard rule: **the parent never enters a worktree**.
- **Merge procedure moved into gh-issue Step 9** (single source of truth, shared by interactive and orchestrated runs). The dispatch prompt's converged/bouncing contract now just defers to gh-issue Step 8 instead of restating it.
- Dispatch prompt rewritten: ~20 lines instead of ~150; per-issue guidance still travels via `guidance.md` file paths only.
- **Optional triage integration:** when the repo's labels include `ready-for-agent` (the `/triage` state machine), Step 1 offers it as a positive scope filter. The triage agent brief reaches implementers for free via the issue comments in `details.json`.
- New `REFERENCE.md` holds troubleshooting and recipe rationale (worktree locks, `-D` vs `-d` after squash, cosmetic merge failure, duplicate-PR-on-rerun, blocked-vs-failed semantics).

**gh-issue 0.2.0 → 0.3.0:**
- Step 8 Phase 1 is no longer self-review: each iteration dispatches **two fresh reviewer subagents in parallel** (adversarial + gate-prep framings) with no implementation bias. The bundled `adversarial-review.md` prompt lookup is dropped — the framings are inline.
- Explicit interactive/orchestrated mode definitions up front; orchestrated-mode behavior (pre-approved plan, self-merge on convergence, blockers) lives here instead of being injected as dispatch-prompt overrides.
- New Step 9 (merge) owns the squash + `## Review notes` body-stripping recipe and issue-closed verification.
- The `Skill()` warning is stated once, at the top, instead of five times across both skills.
- Four-way triage model, converged/bouncing definitions, credit/quota degradation, and PR-body discipline all preserved, compressed.

**Docs:** README rewritten for the new architecture; stale defaults fixed (`--max-parallel` 2 → 10, `--max-codex-iterations` 3 → 2).

## [0.4.0] - 2026-06-10

### gh-issue Step 8b redesigned: local adversarial loop first, Codex as the final gate

Codex tokens are the scarce resource. The old loop ran `codex review` on every fix cycle (N passes per PR). The new shape inverts it — typical Codex spend drops to 1–2 passes per PR while Codex remains the merge authority:

- **Phase 1 — local adversarial loop** (no Codex spend, cap `MAX_LOCAL_ITERATIONS`=4): each iteration runs Pass A (bundled `adversarial-review.md` prompt, with inline fallback framing if the plugin is missing) + Pass B (counter-Codex framing), dedups the union by `file:line_start + claim`, triages with the shared four-way model, applies fixes, pushes. Converges when an iteration yields no new Apply-class findings.
- **Phase 2 — Codex gate** (`MAX_CODEX_ITERATIONS`, default **2**, was 3): one `codex review -c model=gpt-5.4` pass on the already-converged PR. Clean → merge path. Findings → fix → exactly one verification pass; still dirty → cap-stop (blocker in orchestrated runs). Never leaves a P1/P2 fix unverified.
- **Credit/quota degradation:** if the gate exits non-zero on a credit/quota error, it degrades to Phase 1's verdict (the PR already converged locally) and records `Codex gate unavailable (credit/quota); merged on local adversarial convergence` under `## Review notes`. Any other non-zero (auth, network) still reports/blocks as before. This is the only path that merges without Codex coverage.
- Model pinned to `gpt-5.4` (medium reasoning) on every `codex review` invocation — including issue-runner's parent-side escalation calls, which previously ran unpinned at 5.5's xhigh default.
- gh-issue skill version 0.1.0 → 0.2.0.

### issue-runner coherence updates

- Step 4 / Step 4a override 3: `codex review` non-zero now blocks only for non-credit/quota reasons; the credit/quota degradation (with its `## Review notes` audit line, which the merger must verify is present) is added to the **converged** list. Without this, override 3 would have silently overridden the gh-issue fallback in every orchestrated run.
- `--max-codex-iterations` documented as the **gate** cap (default 3 → 2).
- Default `--max-parallel` bumped 2 → 10 (Arguments and Step 4 now agree; they previously contradicted each other).

## [0.3.0] - 2026-06-10

### Step 6 now cleans up merged local branches

Previously, Step 6 removed worktrees and ran `git worktree prune`, but never deleted the **local** branches left behind after merge. `gh pr merge --delete-branch` (Step 4a) only deletes the *remote* branch, so each completed issue leaked its local `feat/...` branch plus the Agent tool's `worktree-agent-<hash>` scratch branch. Over several runs these accumulate and have to be pruned by hand.

- **Per-`done`-issue branch deletion.** The worktree-removal recipe now captures each `done` issue's branch before removing the worktree and force-deletes it (`git branch -D`). `-D` (not `-d`) is required because Step 4a's default `--squash` merge rewrites history — the branch's commits are not ancestors of the squashed default-branch commit, so `git branch -d` would refuse it. `-D` is safe here because `done` status is positive proof the PR merged; `failed`/`skipped` branches are left in place for forensics.
- **Scratch-branch sweep.** After `git worktree prune`, a sweep deletes leftover `worktree-agent-*` branches with the safe `git branch -d` (they point at ancestors of the default branch). Belt-and-suspenders for the Agent tool's current branch-naming convention.
- **Default-branch resolution** added at the top of the Step 6 cleanup so branch deletions never target it.
- Both deletions rely on `git branch`'s built-in refusal to delete a branch checked out in another worktree, which protects a concurrent run's in-flight branch.
- New Troubleshooting entry covering the squash-vs-`-d` ancestry gotcha and how to clean branches from an aborted run by hand.

## [0.2.0] - 2026-05-01

### Bundled gh-issue skill

The plugin is now self-contained: the `gh-issue` skill (the implementer procedure that every per-issue subagent inlines) lives at `skills/gh-issue/SKILL.md` inside this plugin instead of being read by absolute path from `~/.claude/skills/gh-issue/`. Users installing the plugin via a marketplace no longer need a separate `gh-issue` install.

- Moved `skills/gh-issue/SKILL.md` (203 lines, version 0.1.0) into the plugin.
- For local development, the `~/.claude/skills/gh-issue` directory is now a symlink to the bundled copy — single source of truth, `/gh-issue` continues to work standalone.
- Added `version: 0.1.0` to `gh-issue`'s frontmatter (independent of the plugin's version).

### Skill-spec changes (`skills/issue-runner/SKILL.md`)

- **New Step 0 — resolve bundled dependencies.** Runs once at the start of every invocation. Resolves `$GH_ISSUE_SKILL` to an absolute path using `${CLAUDE_PLUGIN_ROOT}/skills/gh-issue/SKILL.md` (preferred, set by Claude Code for installed plugins) or `${HOME}/.claude/skills/gh-issue/SKILL.md` (local dev fallback via symlink). Fails loudly if neither resolves. The orchestrator must substitute the resolved path into implementer dispatch prompts because subagents do not necessarily inherit `CLAUDE_PLUGIN_ROOT`. For orchestrated runs the resolved path is also written to `$STATE_DIR/gh_issue_skill_path` for forensics.
- Replaced both hard-coded references to `~/.claude/skills/gh-issue/SKILL.md` (Step 1c single-issue fast path, Step 4a implementer dispatch template) with `$GH_ISSUE_SKILL` / `<GH_ISSUE_SKILL>` placeholders.

### Plugin metadata

- `plugin.json` version 0.1.0 → 0.2.0.
- `plugin.json` description updated to mention the bundled `gh-issue` skill.
- `README.md`: removed the "hard dependency on gh-issue" known limitation; added a "gh-issue is forked into this plugin" caveat (trade-off for self-containment); installation snippet now creates two symlinks for local dev.

### Versioning rationale

Pre-1.0 minor bumps are reserved for meaningful structural changes. Bundling a previously-external dependency qualifies — even though it is functionally backwards-compatible (the fallback path keeps existing local installs working), the deployment unit is now different.

## [0.1.0] - 2026-04-30

Initial versioned release. Wraps the existing `issue-runner` skill (previously living loose in `~/.claude/skills/`) into a publishable Claude Code plugin.

### Plugin scaffolding
- `.claude-plugin/plugin.json` with name, version, description, author, license, keywords.
- `LICENSE` (MIT).
- `README.md` with installation, usage, requirements, known limitations.
- `CHANGELOG.md` (this file).
- Symlink `~/.claude/skills/issue-runner -> ./skills/issue-runner` so existing local invocations of `/issue-runner` continue to work against the repo-managed source of truth.

### Spec changes derived from the 2026-04-29/30 production audit
The audit covered an 11-issue orchestrated run that completed all 11 PRs but exposed friction worth codifying. Findings IDs reference the audit notes (private scratchpad, not in this repo).

- **F1 / C1** Step 1b: clarified empty-parked behavior (skip the question silently) and added an optional scope-shaping addendum so the orchestrator can ask one extra `AskUserQuestion` when the bulk-list reveals decision-needed labels or obviously obsolete issues. Closing or modifying out-of-scope issues now requires explicit user choice in the addendum.
- **F2 / C3** Step 4a override 3: replaced the rigid "CLEAN review loop" definition (zero findings on final iteration) with explicit `converged` vs `bouncing` semantics. "Cap reached with only P3 / skip-documented findings" is now mergeable, fixing the false-blocker case that drove ~5 user round-trips in the audited run.
- **F3 / Hard rule** Added a Hard rule "Parent stays in main repo" and required `pushd`/`popd` discipline for any Step 5 escalation that enters a worktree. The audited run had the parent's cwd silently drift across 8 different worktrees because bash `cd` is sticky across tool calls.
- **F4 / C6** Step 6: replaced single-`--force` worktree removal recipe with `git worktree unlock` + `git worktree remove -f -f`. The Agent tool's worktree isolation keeps a process-scoped lock that single-force does not bypass; all 11 worktrees in the audited run leaked.
- **F5 / C8** Added Step 1c-pre: pre-existing dirty tree audit via `git status --porcelain=v1 -uall` before scope is initialized. Long runs interact badly with stale staged content; without this check, leftover state at the end of a run looks like the orchestrator left it.
- **F6 / C2** Step 4a: added override 5 forbidding inline `NOTE`/`Additional guidance` blocks in dispatch prompts. Per-issue guidance now lives in `$STATE_DIR/issue-N/guidance.md` referenced by path, restoring the Hard rule "State always goes through files" that the audited run worked around.
- **F7 / C7** Introduced `blocked` as an officially-defined non-terminal status. The audited orchestrator invented this state ad hoc; cascade-skip in Step 4 step 1 now treats `blocked` as paused (not failed), and Step 4 step 5 result handling is documented as a 4-way decision (`done` / `blocked` / `failed` / crash).
- **F9 + F10 / C4 + C5** Step 5 rewritten with six explicit escalations (retry, parent-side codex re-review, parent-applied inline fix, mark failed, hand off to /codex:rescue, bump cap and re-run) and a formal "re-dispatch prompt shape" specification. The audited run discovered "parent runs codex itself" and "parent applies an inline fix" as load-bearing patterns that were nowhere in the spec.
- **F8 / Step 4a + Troubleshooting** Documented the cosmetic `gh pr merge --delete-branch` failure that occurs when merging from a worktree where the parent has `main` checked out elsewhere — server-side merge succeeds, only local-branch-delete fails, `git worktree prune` reconciles after Step 6.
- Added 4 new Troubleshooting entries for the lock-file-survives-session case, the cosmetic merge failure, the leftover-staged-files post-run, and the cascading-codex-findings vs true-bouncing distinction.

### Files
- `skills/issue-runner/SKILL.md` (~462 lines): the skill itself, with `version: 0.1.0` added to frontmatter.

### Not in this release
- `gh-issue` skill is still consumed by absolute path (`~/.claude/skills/gh-issue/SKILL.md`). Bundling it as a sibling skill or declaring a plugin prerequisite is deferred to a future release.
- No automated tests.
- Not yet published to a public marketplace.
