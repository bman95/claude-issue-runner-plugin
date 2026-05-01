# Changelog

All notable changes to this plugin will be documented here. Versions follow semver-ish: pre-1.0 minor bumps may include breaking changes to the skill spec.

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
