# FABLE5 Audit — claude-issue-runner-plugin

Audited: 2026-07-01. Repo state: v0.6.0 committed (last commit 2026-06-14), **3 files with uncommitted changes**.

## Overview

A Claude Code plugin ("issue-runner", marketplace `bman95-plugins`) implementing a full agentic GitHub-issue pipeline: `/issue-plan` turns an idea into vertical-slice issues; `/issue-runner` builds a dependency DAG over open issues and dispatches each to an autonomous worktree-isolated implementer subagent following the bundled `gh-issue` procedure (explore → implement → PR → fresh-eyes review loop → Codex gate → merge). There is no executable code — the plugin is four Markdown skill specs plus manifests:

- `skills/issue-runner/SKILL.md` (~200 lines, orchestrator)
- `skills/gh-issue/SKILL.md` (~185 lines, implementer, v0.4.0)
- `skills/issue-plan/SKILL.md` (60 lines, planner, v0.1.0)
- `skills/issue-runner/REFERENCE.md` (troubleshooting + rationale)
- `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, README, CHANGELOG, LICENSE (MIT), .gitignore

## Current State

Actively developed and battle-tested: 9 commits from 2026-04-30 to 2026-06-14, each documented in an unusually rigorous `CHANGELOG.md` that traces spec changes back to audited production runs (e.g. the 11-issue run behind v0.1.0's defensive recipes). Self-declared pre-1.0.

**Uncommitted work in the tree** (`git status`: `skills/gh-issue/SKILL.md`, `skills/issue-runner/SKILL.md`, `skills/issue-runner/REFERENCE.md` modified). The diff is substantive, not cosmetic:

1. `STATE_DIR` re-namespaced per repo (`/tmp/issue-runner/<repo-key>/state`, sha1 of repo root) to fix cross-repo state clobbering.
2. `gh-issue` interactive mode now creates/tears down its own worktree (Step 4 / Step 9).
3. `--max-parallel` default changed 10 → 5.

This work is unreleased: `plugin.json` is still 0.6.0, `gh-issue` frontmatter still 0.4.0, and `CHANGELOG.md` has no entry for it — violating the project's own versioning discipline. It should be committed as 0.6.1/0.7.0 or reverted.

## Architecture & Code Quality

Architecture is coherent and deliberately layered: planner → orchestrator (never enters a worktree; state through files under `/tmp`) → implementers (nested subagents, capped at parent → implementer → helper) → two-tier escalation (parent first, human only for scope/risk). `REFERENCE.md` explaining *why* each defensive recipe exists (worktree locks, `-D` vs `-d` after squash merges, duplicate PRs on re-runs) is a real strength — the specs are dense but every rule is justified.

Concrete issues:

- **Doc drift from the uncommitted change — `README.md:49`** still documents `--max-parallel` default 10; `skills/issue-runner/SKILL.md:19` now says 5. `README.md:76` ("Concurrent `/issue-runner` runs collide on `/tmp/issue-runner/state/`") is likewise stale versus the new per-repo-key path at `skills/issue-runner/SKILL.md:27`.
- **Spec inconsistency in the execute loop — `skills/issue-runner/SKILL.md:103` (Step 3, item 6).** The cycle check declares "nothing in flight, nothing ready, `pending` issues remain → DAG cycle → mark `skipped`". But item 1 (line 94) says a `blocked` dep keeps dependents `pending`. If one issue is `blocked` and its dependents are `pending` with nothing else in flight, item 6's condition fires and would wrongly skip healthy dependents as a "cycle" while the blocker awaits Step 4 handling. The cycle check needs an exclusion for issues transitively pending on a `blocked` dep.
- **Space-unsafe awk parsing — `skills/gh-issue/SKILL.md:165`.** `git worktree list --porcelain | awk '/^worktree /{print $2; exit}'` truncates the main-checkout path at the first space; the teardown then `cd`s to a wrong/nonexistent path and the `git worktree remove` runs from inside the worktree being removed, which fails. Same class of fragility as the recipes this project usually defends against.
- **Interactive worktree path collisions — `skills/gh-issue/SKILL.md:76`.** `WT="$ROOT/../$(basename "$ROOT")-issue-<number>"` will fail on `git worktree add` if a previous aborted interactive run left the directory behind; no recovery guidance exists (REFERENCE.md covers only orchestrated leaks).
- **`done` inferred from issue state — `skills/issue-runner/SKILL.md:99`.** `gh issue view N --json state` = `CLOSED` → `done`. An issue closed manually (or by an unrelated PR's `Closes #N`) during the run is indistinguishable from a merged implementer PR, and Step 5 will then `git branch -D` its branch on "positive proof of merge" that isn't.
- **Dual-maintenance version fields.** `plugin.json` and `.claude-plugin/marketplace.json` both carry `version: 0.6.0` and near-duplicate descriptions; they will drift (the uncommitted work already demonstrates the failure mode).
- **`.gitignore` confusion.** The `/tmp/issue-runner/` entry is repo-relative in gitignore semantics (i.e. `<repo>/tmp/issue-runner/`), which never exists; the actual state lives in system `/tmp`, which gitignore cannot cover. Harmless but indicates a misunderstanding.

## Bugs & Risks

- The blocked-vs-cycle misclassification above is the most likely real-run bug: it silently converts a paused run into skipped issues.
- The `git branch -D` in Step 5 cleanup (`skills/issue-runner/SKILL.md:175`) and Step 9 teardown (`skills/gh-issue/SKILL.md:170`) is force-deletion driven by inferred merge status; combined with the `CLOSED → done` inference it can destroy unmerged work in edge cases.
- The whole system's correctness depends on an LLM faithfully executing ~400 lines of dense procedure across nested subagents; there is no mechanical enforcement of any invariant ("never enter a worktree", "state through files"). This is inherent to the design and honestly acknowledged, but it means every spec ambiguity is a potential runtime bug.
- Prompt-injection surface: issue bodies and comments are fed verbatim into autonomous implementers that hold push/merge authority (`gh pr merge` without human review in orchestrated mode). On a repo with external issue authors this is a real risk; the spec never mentions it. Mitigated in practice because `/issue-plan` authors the issues, but the runner also accepts arbitrary open issues.
- Credit/quota degradation path (`skills/gh-issue/SKILL.md:127`) merges without any Codex coverage on a regex match against error output — an attacker-controlled or coincidental `429` string in review output could skip the gate. Low probability, worth noting.

## Tests & Docs

- **Tests: none**, and none are really possible in the conventional sense for a prompt-spec plugin; the README states this openly and the CHANGELOG documents validation via audited production runs. A lightweight CI lint (frontmatter validity, plugin.json/marketplace.json version agreement, README-vs-SKILL default consistency) would catch the drift class of bug found above and is feasible.
- **Docs: excellent.** README covers install (marketplace + local dev), usage, architecture, requirements, and an honest known-limitations section. CHANGELOG is exemplary — each entry explains rationale, not just deltas. REFERENCE.md is a genuine troubleshooting asset. Main defects are the two stale README lines listed above.

## Hygiene

- Clean tree apart from the three intentionally-modified skill files. No dead files, build artifacts, screenshots, or scratch content; 10 tracked files total.
- **No secrets found.** Grep for keys/tokens/passwords returns only prose about Codex token spend. The author email `bfrias@sicma21.com` appears in `plugin.json` and `marketplace.json` — intentional public plugin metadata, but note it is a work address on a personal plugin.
- Minor: the ineffective `/tmp/issue-runner/` gitignore entry (see above); `FABLE5-AUDIT.md` (this file) is the only untracked addition.

## Verdict

**Maturity: active** (working and in real use, pre-1.0, spec still moving). This is a well-run, unusually disciplined project for what is essentially executable documentation: the architecture is thought through, every defensive recipe traces to a documented production failure, and the docs/changelog hygiene is better than most code repos. The immediate debts are all process-shaped: ~60 lines of substantive uncommitted spec changes with no version bump or changelog entry, README defaults now contradicting the spec, and duplicated version metadata across two manifests. The one design-level bug worth fixing before the next release is the Step 3 cycle check misfiring on `blocked`-dep chains; the space-unsafe path parsing and the `CLOSED → done` inference are smaller but real. Ship the pending work as a proper release, add a trivial consistency lint, and this is a solid 0.7.
