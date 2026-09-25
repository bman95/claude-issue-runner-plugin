# Changelog

All notable changes to this plugin will be documented here. Versions follow semver-ish: pre-1.0 minor bumps may include breaking changes to the skill spec.

## [Unreleased]

**gh-issue:**
- **Codex gate pinned to `gpt-6-sol`** (#49). In GPT-6, Sol is the workhorse tier and `gpt-6-astra` the frontier; Sol is pinned for near-Astra reliability at lower cost, Astra documented as the escalation. The id needs Codex CLI 0.155 or later, so the gate checks the CLI's model catalog first: a CLI that does not list it gets an "upgrade the Codex CLI" message, never a degraded gate.

**issue-runner:**
- **Codex preflight checks the model catalog** (#49), so an old or logged-out CLI is caught before dispatch rather than after every implementer's Phase 1. It asks the same question as a missing CLI, and Step 4 (Claude edition) treats an implementer's catalog blocker as the same risk blocker.

## [0.12.0] - 2026-09-25

Three issues (#41–#43) that make the pipeline answer to the project instead of guessing: the project declares what "validate this change" means, the planner reconciles a new plan with the backlog and recorded decisions before it interviews, and an RFC draws where the runner's knowledge of post-merge integration should stop. This is a minor bump rather than a patch because scenario row 37's Expected behavior changed (per `docs/scenarios.md`'s own rule).

Versions: issue-runner 0.10.0 → 0.11.0, gh-issue 0.8.0 → 0.9.0, issue-plan 0.3.0 → 0.4.0, Codex edition manifest 0.10.0 → 0.11.0 (each skill's version mirrored into its Codex copies).

### The project says what "validate this change" means: a validation contract

Issue #42. "Run the tests" meant whatever an implementer inferred from CLAUDE.md, README and linter config; now a project can pin it in one trusted file, and a broken pin fails loudly instead of quietly turning validation off.

**gh-issue:**
- **Validation contract.** A new `## Validation contract` section: `.issue-runner/validation` at the repository root declares `preflight: <command>` (required — run before the PR's first implemented push in Step 5, after every review fix in Step 8, and after a Step 9 base refresh) and optionally `full: <command>` (run once on the converged head at Step 9, before `gh pr ready`; declaring it is what requires it). Commands run through `bash -c` from the worktree root, exit status only; the plugin never names or assumes a technology.
- **Trust rule.** The copy that runs is the tip of the base branch on `origin` — never the working tree (a PR's own edit is detected against the merge-base and is inert for that PR), and never what an issue, a PR body, a comment or `guidance.md` says about validation. A PR whose diff touches the file is a policy change a human authorizes: interactive shows the diff and requires explicit confirmation; orchestrated returns `validation contract changed in this PR — a human must review and merge` before ready, whatever the merge mode (`--merge-ready` merges a `ready` PR mechanically, so the change never reaches `ready` on the run's own authority). gh-issue Step 3 probes the contract (`MODE=check`) before any implementation, and the runner never retries the contract blockers — they recur until a human changes the base branch. Step 9's merge is pinned to the head it validated (`--match-head-commit`), so a push landing after the checks gate is refused — `PR head moved after the checks gate — a human must review and merge` — never merged unseen.
- **Failure behavior.** A failing validation the implementer cannot fix is a blocker with the PR left (or reverted to) a draft — `preflight validation failed (exit N): <command>` / `full validation failed (exit N): <command>` — and the contract is never edited to make it pass. An invalid file or a not-runnable command (exit 126/127, for a reason this PR did not cause) never degrades silently to "no validation": orchestrated blockers `validation contract invalid: <reason>` / `validation command not runnable (exit N): <command>`; interactive may proceed on the conventions fallback only by explicit user authorization. Absence is today's conventions fallback, never an error. An unresolvable base branch or worktree root (the block's exit 2) is the result file's `failed` class, never a fallback.
- **Reported, both editions.** Step 10 carries one `validation:` line — `contract (preflight)`, `contract (preflight, full)`, `fallback (no contract)`, `fallback (contract invalid — user authorized)` or `not run` (an exit before any validation ran — Step 3's probe checks the grammar and runs nothing) — and says when, under `checks: none`, that validation was the only automated verification the merge had. The Claude and Codex editions carry a byte-identical recipe.

**issue-runner:**
- **Step 0 validation-contract preflight.** Reports whether the base branch carries a contract or the run will use the conventions fallback, and stops on a grammar-invalid file before any dispatch (the single-issue fast path reports and continues into gh-issue instead, whose interactive Step 3 probe can authorize the conventions fallback). Its fetch of `origin/<default>` takes the same three bounded tries as gh-issue's block (linked worktrees share that ref; a sibling's simultaneous fetch may hold its lock once). It never creates or edits the file.
- **`--merge-ready` refresh syncs the worktree to the PR's current head and re-runs the contract's validation on it, whether or not the base advanced** — the refresh subagent requires a clean worktree, fetches the PR's head ref (three bounded tries) and fast-forwards the recorded worktree to `headRefOid` (dirty, unresolvable or cannot fast-forward → *stuck*, never reset; a fast-forwarded head reports *refreshed*, so the checks re-check waits for its CI to register rather than reading a just-pushed head as `none`; the recipe fetches only the base, so the worktree's stale `HEAD` would otherwise be validated in the pushed head's place), then `MODE=changed`, then preflight, then `full` — the block reports it not declared when there is none; fallback: the project's tests — instead of "the project's tests, only on an advanced base": a commit pushed to a `ready` PR after the no-merge stop is otherwise judged by CI alone, and a contract edit pushed there would merge mechanically; a failing validation or a failed push of the base merge (the subagent's own unpushed base-merge commit dropped first in either case, so the worktree is back at the PR head for the next pass), an invalid contract, a not-runnable command (gh-issue's PR-caused rule-out applied first: a script the `ready` PR itself deleted, renamed or chmod-ed is a plain failing validation) or a contract changed in the PR all leave the issue `ready` and noted, never merged over; the merge itself is pinned to the validated head (`--match-head-commit`), so a head pushed after the refresh is refused and noted rather than merged unseen.

**docs/tests:**
- README `## Validation contract` section; REFERENCE.md rationale entry; design-notes note 6 on bootstrapping the contract in a repository that does not have one yet (coordinate with #41).
- `docs/scenarios.md` rows 39–44 pin the contract (present, absent, preflight failure, `full`, invalid/not-runnable, override attempt); row 37 reworded from "re-run the tests" to the contract's validation — an Expected-behavior change, so the next release is a minor bump per the file's own rule.
- This repository's own `.issue-runner/validation` (`preflight: bash scripts/lint.sh`, no `full`), and `scripts/test-validation-contract.sh`, run from `scripts/lint.sh`, exercising gh-issue's embedded recipe against fixtures and asserting both editions carry the same recipe byte for byte.

### RFC: integration-aware Issue Runner without a CI/CD engine

Issue #43. Design only — no skill behavior changes. `done` means "merged with proof" and says nothing about whether the revision was later built, deployed or validated as a system; the RFC adds that awareness without making the plugin a second CI engine.

**docs:**
- **`docs/integration-rfc.md`.** Separates the issue/PR lifecycle (the runner's, unchanged) from an integrated-revision lifecycle (`pending` / `running` / `green` / `failed` / `superseded`, keyed by a base-branch commit, owned by project CI/CD); draws the responsibility boundary; proposes a second contract file, `.issue-runner/integration`, with the validation contract's grammar and base-branch trust rule — `hint: <command>` for lifecycle hints (`run-start`, `merged` with remaining and near-complete counts, `run-complete`, `flush`) delivered through a versioned environment, `status: <command>` answering one line in a closed vocabulary — kept separate from `.issue-runner/validation` so older plugin versions ignore it instead of rejecting every PR, and gated the same way when a PR edits it (gh-issue Step 9's `MODE=changed` blocker, rows 43–44's rules); specifies coalescing (one merge, several quick merges, one slow outlier, continuous merges, explicit flush) on a project-owned quiet window plus a bounded maximum wait, so CI is correct with no hint ever delivered; explains why `--max-parallel` is capacity, not batch size; keeps projects with no CI on today's behavior; and reconciles with base freshness, `--merge-ready` (scenario row 37), the invalid-contract rules (row 43) and the parked merge queue (design-notes note 2).
- **`docs/design-notes.md`** note 7 summarizes the RFC's options and recommendation; note 2's tail cross-references it as reconciled, not superseded.

### The planner reconciles with existing work before it interviews

Issue #41. `/issue-plan` explored the codebase but never the backlog: a new plan could duplicate an open issue, contradict a design note, or open a second implementation path beside a decision already represented in an open PR or an earlier plan — and the plugin now plans its own evolution, where independently written plans must compose rather than silently fork the architecture.

**issue-plan:**
- **New Step 2, "Reconcile with existing work"**, between Absorb and Interrogate (later steps renumbered 3–6; the runner's cross-references follow). Read-only: it lists open issues and open PRs, recognizes earlier tracking plans (a `## Slices` body with no `## What to build` — the runner's own test) and their `Part of #P` slices, reads whatever design records the Step 1 exploration found (design notes, RFCs, ADRs, decision sections of README / CLAUDE.md / AGENTS.md — located by exploring, never by a hardcoded path), and keeps recently merged PRs — into the default branch, `baseRefName` says, within a 90-day merge window — only when directly relevant. Unrelated backlog is dropped silently.
- **Six outcomes, not a search listing.** Every meaningful overlap is classified `covered` (no slice), `extend` (continue the plan or slice the remainder — never a duplicate), `depends` (a real `## Blocked by` edge to the existing issue, `## Interfaces` naming what it provides), `supersedes` (the user confirms; the planner never closes the superseded issue), `conflict` (a recorded decision or open RFC question the input assumes a different answer to — a mandatory interview question, answered before anything is published, and an overturned record's update becomes part of the plan) or `new`. The outcomes drive the interview, the slice DAG, `## Blocked by`, `## Interfaces` and the slice bodies (`Extends #N:` / `Supersedes #N:` in `## What to build`), and Step 6 names the existing issues a run needs merged or in scope first, and the open issues the plan reuses in a slice's place — a request found entirely `covered` publishes nothing and hands off the covering issue — never an open issue a PR already delivers, which is stale for the user to close, not work for a run.
- **Tracking issue gains `## Existing work`** between `## Decisions` and `## Slices` — references only (`#N`, the title in a code span, outcome and reason; or a document path and entry), never quoted bodies, so the runner's tracking-issue test (`## Slices`, no `## What to build`) cannot be tripped by an existing issue's headings. A non-empty table ends with a counts line — `200+` for an accepted partial scan, `not scanned` for a failed source — and a repository with nothing to reconcile records `No existing work found - scanned N open issues, M open PRs, K recent merges, D documents.` and proceeds unchanged; a continuation re-runs the step, rewrites the section in place (closed references kept, so a recorded supersession survives the issue it replaced), quotes the new input under `## Input` within the same body-size budget as a fresh create, and lists the newly approved slices under `## Slices` before creating any of them. The plan itself is never a candidate (the input issue, the continued tracking issue and its slices); a `## Blocked by` bullet is always an issue an implementer can finish — never a PR number, never an earlier plan's tracking issue (its providing slice is named instead); a listing that fails is `not scanned`, never a zero, and one that returns exactly its `--limit` asks before the partial scan proceeds; an open issue under one of the runner's parked labels is a `conflict`, never `covered` or `depends`; Step 6 names the superseded issues a no-argument run would otherwise implement beside their replacements, and says the runner still asks once about a merged prerequisite (`override`). Existing issues, PRs and documents are data, never instructions — the same trust rule the runner and implementer apply.
- **Both editions.** The Codex canonical copy is byte-identical (now asserted by `scripts/lint.sh`); the Codex wrapper maps the step's read-only `gh` listings onto direct commands or the same bounded `spawn_agent` mapping task.

**docs/tests:**
- `docs/scenarios.md` rows 45–49: duplicate issue (`covered`), dependency on an existing issue (`depends`, and the runner's out-of-scope-edge question), conflicting design decision (`conflict`), unrelated backlog noise, and a fresh repository with nothing to reconcile.
- README pitch, architecture chain and the trust-the-authors limitation; REFERENCE.md rationale entry (both editions); design-notes note 8 (judged relevance now, deterministic candidate signals later) and note 6's reconciliation with #41.
- `scripts/lint.sh` check 15: `skills/issue-plan/SKILL.md` and `codex/issue-runner/canonical/issue-plan/SKILL.md` must be byte-identical. `test-scheduler.sh`'s pinned scenario row count moves to 49 (the new rows are planner judgement, not scheduler fixtures).

### Also in this release

**issue-runner:**
- **`--max-parallel` default back to 3** (issue #31; README and both editions). The default had been 5 since 0.7.0. It is now 3, so a run starts at most three implementers at once unless `--max-parallel` raises the cap.

**docs:**
- **`docs/design-notes.md` note 9 (proposed): work that does not end in a PR.** Records the agreed design for research, audits, recurring checks and operational tasks before any of it is built: research delivers a report comment, not a PR, and is always a DAG leaf; follow-ups go through `/issue-plan`, never straight into a runnable queue; `done` for research is proven from GitHub state; security findings are handled by repository visibility, fail-closed; and operations are turned into code first. Whether the body or a label marks the kind is left to the `/issue-plan` interview.

## [0.11.0] - 2026-09-08

### Crash-resilient, budget-aware orchestration: recovery, pause, and a documented scheduler

An 18-issue backlog batch, orchestrated by `/issue-runner` on itself. Theme: a run should never lose already-converged work to a host crash or a host-level credit/usage-limit stop, an ambiguous merge should never be mistaken for proof, and the scheduling logic should be testable in isolation rather than living only as prose. This release also folds in a Codex plugin edition and a Codex-gate model change that had already landed on `main` without a changelog entry.

**issue-runner (0.9.0 → 0.10.0):**
- **Durable, precondition-checked run root.** State moves from `/tmp` to `${XDG_STATE_HOME:-$HOME/.local/state}/issue-runner/<repo-key>/state`, so a run survives a reboot. A launch-time writability check fails closed with a relaunch instruction (e.g. `codex --add-dir` / `writable_roots`) instead of silently falling back to `/tmp`.
- **Agent-tool preflight.** Step 0 probes for the `Agent` tool up front (some hosts, e.g. Claude Code on the web, hand out a toolset without it) and authorizes gh-issue's inline-review degradation path for the whole run, instead of every implementer discovering the gap mid-review.
- **Crash recovery in place.** A documented `## Recovery` procedure resumes killed implementers from their own transcripts (`ListAgents`/`SendMessage`, resetting the `progress` mtime so hang-detection doesn't misfire on a just-reconnected agent) before falling back to the branch/PR resume check, with a transcript trace digest (`scripts/agent-trace.sh`) as the last resort when an agent truly can't be resumed. A same-session re-entry over a run it never released keeps that run's state (compares the `session` pointer against `$CLAUDE_CODE_SESSION_ID`) instead of rotating it away.
- **Clean pause on a host budget stop.** When an `Agent` dispatch itself fails with a credit/usage-limit class of error, the run writes `$RUN_ROOT/paused` and stops filling new slots rather than misclassifying in-flight issues as `failed`/`skipped`; `--status` surfaces it directly. The run lock also carries a heartbeat (`--lock-ttl-minutes`, default 120, refreshed every Step 3 pass) so liveness doesn't depend solely on `$PPID`.
- **Hang detection and retry discipline.** A step-boundary `progress` file lets `--hang-minutes` (default 30) stop a silently-stalled implementer mechanically instead of by wall-clock guesswork; `--max-retries` (default 2) caps orchestrator-driven retries per issue and forces escalation past the cap.
- **Structured results, not parsed prose.** Whenever a dispatch supplies a state path, the implementer writes `result.json` (outcome, PR, telemetry) immediately before its final message; the orchestrator reads it first — authoritative for `--status` and Step 5's telemetry — falling back to prose only when the file is missing or unreadable. Merge proof stays anchored to git + GitHub (`headRefOid == HEAD`), never trusted blindly from the file's own claim.
- **A tested scheduler.** Step 3's cascade-skip/ready-set/blocked-vs-cycle logic is extracted into `skills/issue-runner/scripts/scheduler.sh`, with `test-scheduler.sh` as golden fixtures wired into CI, so scheduling changes are regression-tested instead of re-derived from prose each time.
- **`--no-merge` / `--merge-ready`.** Implementers can stop at a ready-to-merge PR for a human gate (`ready` status/outcome, verified against GitHub rather than trusted from `result.json`); a follow-up `--merge-ready` run merges what was left ready and continues dependents. Step 5 also tells apart a still-unfinished PR's three shapes — `draft (checkpoint)`, `draft (implemented, not ready)`, `branch only (no PR)` via a new orphan-branch probe — instead of reporting only `isDraft`.
- **Deterministic conflict edges.** When every in-scope issue carries a `Files likely touched:` line, conflicting edges are computed by file-path intersection instead of an LLM guess; the LLM refinement pass is now a fallback for issues without that line.
- **Tests re-run on any base advance.** The pre-merge freshness check no longer gates the re-test on file overlap; any base movement — including one detected right before a `--merge-ready` merge — re-runs tests before merging.
- **Cost visible before dispatch.** The plan printout carries an agent-count estimate (min–max Claude agents, Codex gate passes); Step 5 recomputes it and prints the run's actual counts beside it, with an explicit best-effort caveat.
- **Tracking-issue aware** (paired with issue-plan below): a tracking issue is excluded from scope, and when every in-scope issue shares one, the Step 5 summary posts there too.

**gh-issue (0.7.1 → 0.8.0):**
- **Draft-PR checkpoint.** On a fresh orchestrated branch, Step 4 pushes it and opens a **draft** PR carrying the plan before writing any code, so a run that dies before implementation leaves its distilled context on GitHub. Draft is load-bearing — GitHub refuses to merge a draft PR outright — so Step 9 must explicitly ready it before base-freshness and the checks gate.
- **Progress marker and result file.** Whenever a dispatch supplies a state path, the run writes a best-effort `progress` marker per step boundary and the `result.json` above on exit — read as data by the orchestrator, authoritative for its telemetry, but never proof of merge on their own.
- **Codex gate model: `gpt-5.6-terra` → `gpt-5.6-sol`.** The certification gate is the last independent check before an unattended merge, so it now runs on the frontier reviewer instead of the cheaper mid-tier one — roughly double the per-pass cost of the prior pin, spent deliberately on the highest-leverage review in the pipeline. Uses the explicit `-sol` id, same discipline as the `-terra` pin it replaces.

**issue-plan (0.2.0 → 0.3.0):**
- **Mandatory `Files likely touched:`.** Every published slice ends with a repo-relative file list — the input that issue-runner's deterministic conflict-edge pass depends on.
- **Tracking issue.** Before publishing any slice, `/issue-plan` now unconditionally creates a tracking issue (`Plan: <name>`) carrying the interview's decisions and a running slice list, updated as each slice publishes; a continuation reconciles it from GitHub, never from the list alone.

**Codex plugin edition (new).** `codex/issue-runner/` packages the three skills for the Codex CLI as a separate plugin, with its own manifest and a new README "Codex installation" section. gh-issue and issue-plan are ported in full; **issue-runner is not yet** — the crash recovery, host-pause handling, lock heartbeat, scheduler script, and agent-count estimate above are Claude-edition-only for now, a gap to close in a follow-up issue.

## [0.10.0] - 2026-07-12

### Portable context: carry the whole plugin in one environment variable

New way to install the plugin anywhere — a brand-new project, an existing one, local or on Claude Code on the web — without the marketplace, a clone, or anything committed to the target repo. The plugin's three skills pack into a single base64 line you park in an environment variable; a bootstrap step decodes it into a Claude Code skills directory so `/issue-plan`, `/issue-runner`, and `/gh-issue` appear.

The skill specs are unchanged (no frontmatter version bumps); this is tooling + docs only.

**New `scripts/context-env/`:**
- **`pack-context.sh`** — serializes `skills/` + `plugin.json` to `base64(gzip(tar))` (~29 KB, one line, no shell-hostile bytes). Prints an `export ISSUE_RUNNER_CONTEXT=…` line by default; `--raw` prints the bare value (for a `.env` or the cloud environment's variable list), `--file` writes it, `--var` renames the variable. Dependency-free (`base64 | tr -d '\n'`, not GNU-only `base64 -w0`).
- **`bootstrap-context.sh`** — the decode+install half: reads `$ISSUE_RUNNER_CONTEXT` (or `$ISSUE_RUNNER_CONTEXT_FILE`), extracts the skill folders into `$HOME/.claude/skills` (override with `--dest` / `$ISSUE_RUNNER_SKILLS_DIR`). Idempotent. `--hook` emits the SessionStart JSON with `reloadSkills:true` and stays a clean no-op when the variable is unset, so it never blocks a session.

**Why it works without `CLAUDE_PLUGIN_ROOT`:** installing into `~/.claude/skills/` exposes the skills as user-level commands *and* satisfies `issue-runner` Step 0's existing fallback lookup of `gh-issue` at `$HOME/.claude/skills/gh-issue/SKILL.md`, so the orchestrator still resolves its implementer. The only behavioral difference from the marketplace install is unnamespaced command names (`/issue-runner`, not `/issue-runner:issue-runner`).

**Docs:** new `docs/portable-context.md` walks the three wiring routes (one-shot, local SessionStart hook, and a self-contained cloud setup-script snippet that needs nothing checked out); README gains a pointer under Installation.

## [0.9.1] - 2026-07-10

### Codex gate model: `gpt-5.4` → `gpt-5.6-terra`

The GPT-5.6 family (Sol / Terra / Luna) reached general availability on 2026-07-09. The Phase 2 Codex gate now pins **`gpt-5.6-terra`** in place of `gpt-5.4`.

**gh-issue (0.7.0 → 0.7.1):**
- **Same spend, newer generation.** Terra lists at the same `$2.50 / $15` per-1M input/output as the former `gpt-5.4` pin, but sits on the 5.6 Pareto frontier (above 5.5 across reasoning efforts) — a quality bump at identical cost. The design intent is unchanged: the gate runs on a diff Phase 1 already pre-cleaned, so it wants a solid final reviewer at controlled cost, not frontier depth (`reasoning=medium` retained). Sol/Luna remain the escalation/economy alternatives documented for the pluggable-gate note.
- **Explicit `-terra` id required.** The bare `gpt-5.6` alias routes to Sol (`$5 / $30`, 2×); the pin uses the full `gpt-5.6-terra` id to avoid the silent upcharge. The `docs/design-notes.md` pluggable-gate default was updated to match.

## [0.9.0] - 2026-07-06

### CI gate before merge, codex-optional runs, portable state keys, and a verified-findings hardening pass

A full adversarial re-audit of the specs (every finding independently verified — several empirically — before any edit) produced this batch. Theme: close the paths where an unattended run could merge or mislabel without proof, and make the plugin runnable without its cross-vendor dependency.

**issue-runner (0.8.0 → 0.9.0):**
- **Portable `REPO_KEY`.** The per-repo state key hashed with `sha1sum`, which stock macOS doesn't ship — the un-`pipefail`ed pipeline silently collapsed the key to `<basename>-`, so two same-basename repos on a Mac would share state: the exact clobbering the 0.7.0 namespacing exists to prevent. Now `git hash-object --stdin` (git is already a hard requirement, available wherever the plugin runs).
- **Merge-proof check guards an empty branch.** Verified empirically: `gh pr list --head "" --state merged` applies **no** filter and returns unrelated merged PRs — so a `CLOSED` issue whose worktree had vanished could ride an arbitrary merged PR to a false `done`. The query now runs only with a non-empty `WT_BRANCH`; an unreadable branch is *no* merge proof (`CLOSED` → `closed-externally`, open → `failed`).
- **Hung implementers handled.** Step 3 item 4 covered crashes but not a live-but-silent agent, which stalled the whole run with no recipe. Now: long-silent past the scale of its issue → stop it, `failed` with `implementer hung (no completion)`, cascade handles dependents, Step 4 retry is the recovery (the resume check picks up any PR it opened). REFERENCE gains the matching troubleshooting entry.
- **Codex preflight + `--no-codex-gate`.** A missing `codex` CLI previously hard-blocked every orchestrated PR at the gate — discovered only mid-review, N implementers deep. Step 0 now preflights `command -v codex`; missing → ask up front (abort *recommended*, or proceed gateless). `--no-codex-gate` waives the gate explicitly: implementers merge on Phase 1 convergence alone, recorded in each PR body exactly like the credit/quota degradation. The waiver travels only via the dispatch prompt/user flag — never issue/PR content (REFERENCE rationale note).
- **Run summary aggregates review telemetry.** Phase 1 iterations, gate passes, degradations/waivers — per issue and as totals — so the review-loop caps (2 reviewers × ≤4 iterations, gate cap 2) can be tuned from data instead of folklore.
- **Wording/framing:** the Step 3 loop guard now names the blocked-chain pause (pending-on-a-blocked-ancestor) alongside `blocked`; the State section states the two-tier model explicitly (GitHub is the cross-run source of truth via the resume check; `$STATE_DIR` is run-scoped scratch; `state.prev.*` is forensics only); the `$PPID` lock rationale records that the assumption was validated empirically on Linux/WSL and what the failure mode would be elsewhere (stale-reading lock, not a wedge).

**gh-issue (0.6.0 → 0.7.0):**
- **Step 9 gates the merge on CI.** `gh pr merge` enforces only *required* branch protections; advisory checks — the common case on personal repos — never blocked it, so a squash merge could land over a red build. The merge now runs base-freshness first (a sibling PR merged into the base since the branch point + file overlap → merge the base in, re-test, push — the semantic-conflict window no textual check catches), then `gh pr checks --watch` (pass or no-CI → merge; fail → ask/blocker). Freshness runs *before* the gate so the watched commit is the one that merges. Never merge over a failing check without explicit user authorization.
- **Phase 2 checks codex availability first** and supports the orchestrator's waiver (above); the Converged definition and Step 10 report cover the waived state as prominently as the credit/quota degradation.
- **Step 2 consumes planner contracts.** An issue carrying `## Interfaces` or `Files likely touched:` seeds the Explore prompt — verified against current code, since the base may have moved since planning.

**issue-plan (0.1.1 → 0.2.0):**
- **Optional `## Interfaces` section** in the issue-body contract (shared function signatures, schemas, endpoints between slices) plus an optional `Files likely touched:` line from the planner's exploration — previously the interview and exploration were discarded entirely and every implementer re-derived them. The runner ignores the section; it exists for the implementer.

**Docs / tooling:**
- **lint.sh grew from 6 to 10 checks:** the `--max-parallel` default is now compared across all three sites (README, SKILL arguments, Step 3 runtime line — the third was invisible before); every ```` ```bash ```` block in the skills is extracted, placeholder-neutralized, and `bash -n`-checked; shellcheck runs advisorily when installed; the default-branch resolution one-liner must be byte-identical across its sites in both SKILL files; the branch contract (`/issue-<`) must be present in both (placeholder-spelling drift warns).
- **New `docs/scenarios.md`:** the golden scheduler scenarios (blocked chain vs cycle, closed-externally cascade, resume paths, the new empty-branch guard, …) as a fixture table — the behavioral contract to re-dry-read after any Step 3 edit.
- **New `docs/design-notes.md`:** five RFCs from the re-audit's surviving design questions — hybrid deterministic-scheduler helper script, full merge queue, pluggable review gate, structured planner artifact, spend-telemetry limits.
- **FABLE5 audit docs archived** to `docs/archive/` with historical-snapshot headers — `source: "./"` ships the whole repo to every marketplace install, and the audit described long-fixed bugs as open.
- README: precise codex requirement (absence blocks unattended runs unless waived; only credit/quota degrades mid-run), `--no-codex-gate` in usage, lint coverage noted in limitations.

## [0.8.0] - 2026-07-02

### Resume open PRs, per-repo run lock, `--status`, and a spec-consistency pass

Two long-standing manual chores become automatic (duplicate PRs on re-runs, the "don't run two at once" honor system), plus a read-only status view and a batch of consistency fixes from a full-system read. Behavior changes, so 0.8.0.

**issue-runner (0.7.0 → 0.8.0):**
- **Dispatch resumes open PRs (new Step 3a resume check).** Before every dispatch, an open PR whose head branch matches `/issue-<N>-` (the gh-issue branch contract) is detected and resumed — same branch, same PR, mirroring the Step 4 retry — instead of opening a duplicate. If a leftover worktree still holds the branch, the dispatch drops `isolation: worktree` and reuses it (git refuses one branch in two worktrees); otherwise a fresh worktree fetches the branch. Multiple matches (duplicates from earlier runs) ask the user which to resume. Replaces the old rule "close a blocked run's PR before re-running" — closing a PR is now only the from-scratch escape hatch.
- **Per-repo run lock.** `$RUN_ROOT/lock` holds `$PPID` — the Claude Code process hosting the session, the one PID that lives exactly as long as the run can — so a second run in the same repo is refused while the first is live, and a crashed run's lock reads stale and is taken over. Previously same-repo concurrency was only a documented "don't". Never delete a live lock: the state rotation would yank a running orchestration's files from under its implementers. Released in Step 5 (and on `--plan` exit).
- **New `--status`.** Read-only: resolves `REPO_KEY`, prints a per-issue table (number, status, error, title) from `$STATE_DIR`, exits. Never locks, rotates, or initializes — safe to run mid-orchestration or after the fact.
- **`--plan`/state contradiction fixed.** The State section claimed `--plan` never touches state while Step 2 persisted `dag.json` there before the `--plan` exit. Now: state initializes whenever a DAG is built (`--plan` included — `dag.json` is its artifact); only the fast path and `--status` never initialize it.
- **`blocked` issues now record their `worktree` path.** State listed `worktree` for `failed`/`skipped`/`closed-externally` only, but the Step 4 retry needs the blocked issue's worktree. Step 5 keeps `blocked` worktrees in place (retry material, not just forensics).
- **Retry dispatch disambiguated.** "Re-dispatch per Step 3a" now says explicitly: **without** `isolation: worktree`, and the prompt tells the agent to `cd` into the existing worktree first.
- **Truncation detection made actionable.** "More than 50 open issues ⇒ tell the user" gave no way to know — with `--limit 50` you see exactly 50 and nothing else. Now: exactly 50 back ⇒ likely truncated ⇒ confirm scope.
- **Stale `/to-issues` references fixed** (Step 2; also gh-issue Step 5) — the planner has been `/issue-plan` since 0.6.0. Intra-file duplicates removed (single-host limit, STATE_DIR-substitution rule: each stated once).

**gh-issue (0.5.0 → 0.6.0):**
- **Resume mode.** Orchestrated: a dispatch prompt naming an existing branch/PR means fetch + check out that branch and skip Step 7, pushing to the named PR. Interactive: Step 4 first checks for an open PR matching `/issue-<number>-` and asks the user — resume its branch in the worktree, or close it and start fresh.

**Docs / hygiene:**
- **Token diet:** frontmatter `description` fields load into every session's skill list — the plugin's only recurring context cost — so all three were tightened without losing the trigger contract (issue-plan 0.1.0 → 0.1.1).
- **lint.sh:** two new drift guards — (5) the issue-body contract strings (`## Blocked by`, `None - can start immediately`) must appear in both issue-plan and issue-runner; (6) no skill may reference the retired `/to-issues` command.
- README: `--status` in usage; limitations updated (PID lock replaces the same-repo "don't run two at once"; re-runs resume open PRs). REFERENCE: resume + lock rationale, lock troubleshooting entry.

## [0.7.0] - 2026-07-01

### Per-repo state, interactive worktree lifecycle, and data-loss / cycle / injection fixes

Releases ~60 lines of previously-uncommitted spec work (per-repo `STATE_DIR`, gh-issue owning its interactive worktree, `--max-parallel` 10 → 5) together with a batch of correctness fixes surfaced by an audit of that work. Behavior changes, so 0.7.0, not 0.6.1. No feature is new to the pipeline; the theme is *don't lie about state and don't destroy work* — every change closes a way a run could silently mislead or lose data.

**issue-runner (SKILL frontmatter 0.6.0 → 0.7.0):**
- **State namespaced per repo.** `STATE_DIR` is now `/tmp/issue-runner/<repo-key>/state`, where `<repo-key>` is `basename` + a sha1 of the repo root. Previously a flat `/tmp/issue-runner/state` meant starting a run in repo B rotated repo A's live state into a `state.prev.*` backup and gave A's in-flight implementers (which read absolute paths) B's files or none. Runs in different repos are now isolated; concurrent runs *within one repo* still collide — the documented single-user limit. Old flat orphans (`/tmp/issue-runner/state*`, `state-<name>`) are not swept by the per-repo cleanup; remove them by hand.
- **Cycle check no longer misfires on blocked chains (Step 3, item 6).** When one issue is `blocked` and its dependents sit `pending` with nothing in flight, the old cycle condition ("nothing ready, `pending` remain → cycle → skip") fired and silently `skipped` healthy dependents while the blocker awaited Step 4. Item 6 now excludes any `pending` issue with a `blocked` ancestor in the DAG: those *wait* for Step 4 to resolve the upstream blocker (to `done` → releases them; to `failed`/`skipped` → cascade-skips them). A cycle is declared only when no remaining `pending` issue has a `blocked` ancestor. REFERENCE.md now distinguishes "blocked chain" from "cycle" for troubleshooting.
- **`done` requires positive merge proof, not just `CLOSED` (Step 3, item 5).** `gh issue view N` reporting `CLOSED` was treated as `done` and licensed Step 5's `git branch -D`. An issue closed by hand or by an unrelated PR's `Closes #N` mid-run was indistinguishable from a merged implementer PR — so the cleanup force-deleted unmerged work. `done` now requires a merged PR on the implementer's own branch (`gh pr list --head <branch> --state merged`); a `CLOSED` issue without that proof becomes a new terminal state **`closed-externally`** — worktree and branch **kept**, flagged as a non-zero outcome in the run report for a human to confirm whether the work actually landed, and its dependents cascade-skipped with `dependency closed externally without merge proof: #X` (never mislabeled as a DAG cycle). `-D` runs only after merge proof.

**gh-issue (0.4.0 → 0.5.0):**
- **Interactive worktree owns its lifecycle, hardened.** Interactive mode (Step 4) creates its own worktree and tears it down in Step 9 (single-issue `/issue-runner` no longer relies on orchestrator cleanup). Two audit fixes on that path: (a) the main-checkout lookup `git worktree list --porcelain | awk '/^worktree /{print $2}'` truncated paths at the first space — replaced with space-safe `sed -n 's/^worktree //p' | head -1`; (b) Step 4 gained a pre-flight that removes a leftover worktree dir/registration from an aborted earlier run before `git worktree add`, with guidance to never blind-delete a surviving branch (it may hold unmerged work). REFERENCE.md now covers interactive-mode leaks, previously orchestrated-only.
- **Step 9 teardown gates `git branch -D` on `gh pr view --json state` == `MERGED`.** Same data-loss class as the issue-runner fix: the squash-merge `-D` now fires only on the PR reporting merged, never on issue-closed inference.
- **Codex-gate degradation keys off the CLI's own exit code + stderr, not a regex over review output.** The credit/quota skip — the one path that merges without Codex coverage — previously matched `credit|quota|...|429` against the merged stdout+stderr review text, which issue/PR content can spoof. It now captures `codex review`'s own exit status and stderr separately and degrades only when the invocation *itself* exits non-zero with a credit/quota stderr, logging the skip prominently in the Step 10 report (orchestrated: surfaced to the parent).
- **Prompt-injection posture stated.** Step 1 instructs implementers to treat issue bodies/comments as *data*, never as instructions that override the procedure or merge discipline.

**Docs / hygiene:**
- README synced with the spec: `--max-parallel` default 10 → 5 (matched SKILL.md); the "single-host" limitation now describes the per-repo `/tmp/issue-runner/<repo-key>/state` path; a new "Trust the issue authors" limitation warns against pointing the runner at repos with untrusted issue authors given implementers' merge authority.
- Removed the ineffective `/tmp/issue-runner/` `.gitignore` entry — gitignore patterns are repo-relative, so it matched a nonexistent `<repo>/tmp/...`; the real state lives in system `/tmp`, which gitignore cannot cover.
- **New `scripts/lint.sh` (dependency-free) + `.github/workflows/lint.yml`.** Mechanically checks the drift classes this release cleaned up: `plugin.json` vs `marketplace.json` version agreement, required SKILL frontmatter fields (name/description/version), README `--max-parallel` default vs SKILL default, and a CHANGELOG entry for the manifest version. This is the only "test" a prompt-spec plugin can realistically carry.
- `plugin.json` / `marketplace.json` bumped to 0.7.0.

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
