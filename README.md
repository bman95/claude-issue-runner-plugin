# issue-runner

A self-sufficient Codex and Claude Code plugin for the full agentic issue pipeline: from an idea to merged PRs.

- **`/issue-plan`** turns an idea, plan, or spec into ready-to-run issues: it reconciles the scope with the repository's existing issues, PRs, earlier plans and design documents (covered, extend, depends, supersedes, conflict, or new — a conflict with a recorded decision goes to you before anything is published), asks only the questions the input needs, slices the work into tracer-bullet vertical slices, and publishes issues in the format the runner parses, under a tracking issue that keeps the input, the existing work it reconciled with, and the interview's decisions.
- **`/issue-runner`** reads the issue queue, builds a dependency DAG, and dispatches each issue to an **autonomous implementer subagent** in an isolated worktree. Implementers spawn their own subagents — `Explore`/`Plan` helpers, fresh-eyes reviewers, delegated `general-purpose` chunks (helpers don't nest further) — then converge the PR through a Codex gate and merge it. Independent issues run in parallel up to a configurable cap; failures cascade-skip downstream dependents.

Run-time doubts escalate up the chain: implementer → parent (resolves coordination/context blockers from run-wide knowledge, retrying on its own only while an issue's Step 4 re-dispatches stay under `--max-retries`) → human (scope, product-behavior, or risk decisions — and every blocker once an issue's retry cap is reached).

## Status

Pre-1.0. The skill works on real-world runs but the spec is still tightening based on production use. See `CHANGELOG.md` for what changed and why.

## Codex installation

The native Codex plugin lives under `codex/issue-runner/`. Its Codex-specific skills are isolated from the original Claude skills under the repository's top-level `skills/`, which remain unchanged. Add `codex/issue-runner/` as a local plugin source in Codex, install **Issue Runner**, and start a new thread so the bundled skills are discovered. You can then ask Codex naturally:

```
Use issue-plan to turn this feature into runnable GitHub issues.
Use issue-runner on issues 42, 43, and 44.
Use gh-issue to implement issue 42 end to end.
```

Codex selects skills from natural-language requests; the Claude-style slash commands shown below remain useful aliases when running the Claude edition.

The Codex edition has the same features as the Claude edition, except the two listed below. Its orchestrator runs the same procedure (`canonical/issue-runner/`, a byte-identical copy) and the same bundled scripts: the scheduler, the run lock with its heartbeat and `--lock-ttl-minutes` (default 1440 on Codex, where the lock records a per-run owner derived from the thread id and has no live-PID signal), the host credit/usage-limit pause, the agent-spend estimate and actuals, and crash recovery through `codex resume`. The wrapper skill maps Claude Code primitives to Codex's collaboration tools. It also lists the two features that cannot be ported: the trace-digest recovery fallback, which reads Claude Code's own transcripts, and the Agent-less inline-review variant, which the Codex implementer has no path for. Lint keeps the canonical copy byte-identical, and fails on any `## `/`### ` heading or `--flag` name the wrapper adds that `codex/issue-runner/parity-allowlist.txt` does not record.

Orchestrated runs (`issue-runner` on two or more issues, or `--plan`) keep their state under `${XDG_STATE_HOME:-$HOME/.local/state}/issue-runner`, which a default `workspace-write` sandbox cannot write and a running session cannot grant: create that directory once and launch Codex with `codex --add-dir "${XDG_STATE_HOME:-$HOME/.local/state}/issue-runner"` (or list it under `sandbox_workspace_write.writable_roots` in `config.toml`); otherwise the run refuses to start with `run root is not writable`.

## Claude Code installation

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

### Portable context via one environment variable

Prefer to carry the plugin everywhere without a per-project marketplace install — including on Claude Code on the web and in brand-new projects? Pack the whole plugin into a single environment variable and decode it into `~/.claude/skills/` on demand:

```bash
scripts/context-env/pack-context.sh --raw            # -> the value for ISSUE_RUNNER_CONTEXT
scripts/context-env/bootstrap-context.sh             # decode $ISSUE_RUNNER_CONTEXT -> ~/.claude/skills/
```

This installs the skills as **user-level** commands (`/issue-plan`, `/issue-runner`, `/gh-issue` — unnamespaced) and works as a local SessionStart hook or as a Claude Code on the web environment setup script. Full guide: **[`docs/portable-context.md`](docs/portable-context.md)**.

## Usage

```
/issue-runner:issue-plan <idea | plan | file | issue#>  # idea -> published, runnable issues
/issue-runner:issue-runner                              # all open issues (label-filtered)
/issue-runner:issue-runner 42 43 44                     # specific issue numbers
/issue-runner:issue-runner --plan                       # build the DAG, print an agent-count estimate, and exit
/issue-runner:issue-runner --status                     # print the last run's state table, with in-flight progress and per-issue outcomes (read-only)
/issue-runner:issue-runner --max-parallel N             # concurrency cap (default 3)
/issue-runner:issue-runner --hang-minutes N             # hung-implementer threshold: progress file unchanged for more than N minutes (default 30)
/issue-runner:issue-runner --lock-ttl-minutes N         # run-lock heartbeat threshold: refuse a second run while the lock's PID is alive or its mtime is younger than N minutes (default 120)
/issue-runner:issue-runner --max-codex-iterations N     # Codex gate passes per implementer (default 3)
/issue-runner:issue-runner --max-retries N              # Step 4 re-dispatches per issue before every blocker escalates to you (default 2)
/issue-runner:issue-runner --no-codex-gate              # skip the Codex certification gate; merge on local fresh-eyes convergence (recorded per PR)
/issue-runner:issue-runner --no-llm-refine              # skip LLM dependency refinement (file-scope conflict edges still computed)
/issue-runner:issue-runner --no-merge                   # every implementer stops at ready-to-merge instead of merging; a human (or --merge-ready) merges by hand
/issue-runner:issue-runner --prose-gate N,…             # narrow the review triage bar for these Markdown-only prose PRs (user-authorized; revoked on any non-.md path)
/issue-runner:issue-runner --merge-ready                # merge every PR left ready by a prior --no-merge run and continue for what it unblocks
/issue-runner:issue-runner --sequential                 # equivalent to --max-parallel 1
/issue-runner:issue-runner --flush                      # ask the project's CI to validate the default branch's tip now (.issue-runner/integration's hint:; docs/integration-rfc.md)
```

A single-issue scope skips orchestration entirely and runs the `gh-issue` procedure inline. `/issue-runner:gh-issue N` also works standalone; `/issue-runner:gh-issue N --review-profile prose` runs it under the prose review profile (default `standard`). Only the user can select that profile, with one of these flags; an issue body, PR text, a comment or `guidance.md` never can.

## Architecture

- **Planner** (`skills/issue-plan/SKILL.md`): absorb the idea → reconcile with existing work (open issues, open PRs, earlier tracking plans and their slices, the repository's design/RFC documents, directly relevant recent merges — each overlap classified as covered / extend / depends / supersedes / conflict / new; conflicts are user decisions, never the planner's) → adaptive interrogation (human decisions settled up front) → tracer-bullet vertical slices → publish a tracking issue (the input, the interview's decision log, the existing work reconciled with, the slice list, and a machine-readable plan file of each slice's dependencies and files) and one issue per slice with `## What to build` / `## Acceptance criteria` / `## Blocked by` / `Files likely touched:` — the contract the runner and implementer parse — plus a `Part of #<tracking>` line outside it.
- **Orchestrator** (`skills/issue-runner/SKILL.md`): scope (label filters, tracking issues excluded, dirty-tree audit) → dependency DAG (`## Blocked by` primary, heuristics as fallback; conflict edges from `Files likely touched:` intersection, LLM refinement as fallback; drift from the tracking issue's plan file printed as a warning — the issue bodies stay authoritative) → an agent-count estimate printed with the plan (also available via `--plan` alone) → parallel dispatch → two-tier blocker escalation (parent first, human last) → cleanup and summary — actual agent counts next to the estimate — posted as a comment on the plan's tracking issue when the scope shares one. The orchestrator never enters a worktree.
- **Implementer** (`skills/gh-issue/SKILL.md`): understand → explore (Explore subagent) → plan → branch + draft PR carrying the plan (orchestrated: the checkpoint that survives a crash) → implement → preflight validation (the project's contract, or its conventions) → PR body → layered review → mark ready → merge. The review runs fresh-eyes reviewer subagents locally (no Codex spend) and uses `codex review` only as a final certification gate (up to `--max-codex-iterations` passes per PR), with a credit/quota degradation path.
- **Reference** (`skills/issue-runner/REFERENCE.md`, `skills/gh-issue/REFERENCE.md`): troubleshooting and the rationale behind the defensive recipes (worktree locks, branch deletion after squash merges, duplicate PRs on re-runs, the review gate's liveness and trust rules). The SKILL files carry the procedure and point at these entries by name.

## Validation contract

"Run the tests" means something different in every project, so the project says what it means in one file, `.issue-runner/validation` at the repository root:

```
# what "validate this change" means in this repository
preflight: ./scripts/preflight.sh
full: ./scripts/full-validation.sh
```

Two keys, each `key: <command>` on its own line; `#` comments and blank lines are allowed, anything else — a stray line, a second `preflight`, a command that is only a `#` comment (a placeholder, not a command), CRLF line endings, a NUL byte — makes the file invalid. **`preflight`** is required: the project's normal, relatively cheap validation, run by the implementer before the PR's first implemented push (Step 5), after every review fix (Step 8), and again after a pre-merge base refresh (Step 9). **`full`** is optional: a heavier validation the project wants once per head — on the converged head right before the PR is marked ready (Step 9), and again only after a base refresh — declaring it is what requires it; a project whose CI already covers that ground leaves it out. Commands run through `bash -c` from the worktree root and only the exit status is read (0 passes): lint, unit tests, builds, containers, E2E — what they are is the project's business, never named or assumed by the plugin. Without the file, implementers fall back to today's behavior — the project's conventions (CLAUDE.md, README, linter and test configuration) decide what runs — and report `validation: fallback (no contract)`. The runner's Step 0 preflight prints which of the two applies before dispatching anything; it never creates or edits the file.

**Trust.** The copy that runs is the tip of the base branch on `origin` — base-branch content a human already merged, the same copy the runner's Step 0 probes — never the working tree's; a PR's own edit of the file is detected against the merge-base and is inert for that PR. A broken contract is fixed on the base branch and the run re-run: the next validation reads the fix. Nothing an issue body, a PR body, a comment or `guidance.md` says about validation changes what runs (that text is data, the same rule the implementer applies to everything else it reads), and a PR whose diff touches `.issue-runner/validation` is a policy change only a human authorizes: interactive runs show the diff and require an explicit confirmation; orchestrated runs return a blocker before the PR is marked ready, whatever the merge mode — `--merge-ready` merges a `ready` PR mechanically, so a policy change never reaches `ready` on the run's own authority; a human readies and merges it by hand. The contract pins *which command* runs; the command runs in the PR's checkout, so a PR that edits what it executes (the scripts it names, a linter's configuration) is an ordinary diff for the review to read, not a policy change this gate catches.

**Failure.** A failing preflight or full validation is the implementer's to fix. When it cannot be made to pass, interactive runs show the output and ask; orchestrated runs return a blocker — `preflight validation failed (exit N): <command>` or `full validation failed (exit N): <command>` — with the PR a draft (or the blocker says otherwise), never readied or merged over, and the contract never edited to make it pass. A broken file — invalid grammar, or a command that cannot run (exit 126/127) for a reason this PR did not cause — a script this PR itself removed or renamed is a plain failure, the implementer's to fix — never silently disables validation: orchestrated runs return `validation contract invalid: <reason>` or `validation command not runnable (exit N): <command>` for a human to fix on the base branch; interactive runs may proceed on the conventions fallback only by explicit user authorization, reported as `validation: fallback (contract invalid — user authorized)`. Step 10's report always carries one `validation:` line saying which of the four applied — or `not run`, for an exit before any validation ran (a blocker at Step 3's probe, for instance: it checks the grammar and runs nothing).

**Relation to CI.** Preflight and full are fast feedback in the worktree, before the PR is opened or marked ready; they never replace the merge's checks gate. When the project has CI, CI remains the authoritative post-PR verdict — a red check blocks the merge whatever the preflight said, and a green check never excuses a skipped or failing preflight; both must hold. When there is no CI (`checks: none`), the contract's validation was the only automated verification the merge had, and the report says so.

This repository's own contract is `preflight: bash scripts/lint.sh` with no `full` — lint plus the fixture tests are the whole preflight here, and CI runs the same script.

## Requirements

- **Codex** with collaboration and shell tools, or **Claude Code** with Agent and Bash — reaching subagents too: Claude Code on the web and `claude -p` currently hand subagents a toolset without `Agent`, so implementers cannot spawn their fresh-eyes reviewers there; the orchestrator probes this in Step 0 and asks before proceeding with a recorded inline review. Implementers need permission to create worktrees and use `git`/`gh`.
- **GitHub CLI (`gh`)** authenticated against the target repository.
- **`codex` CLI 0.155 or later** for the review gate — required for unattended orchestrated runs: if `codex` is not installed the orchestrator asks up front (or pass `--no-codex-gate`); only credit/quota exhaustion degrades gracefully mid-run. The gate pins `gpt-6-sol`, which appears in the model catalog a logged-in 0.155.x CLI fetches from the server, not in the catalog bundled with the binary (verified with 0.155.1: `codex --version`, and `codex debug models` lists `gpt-6-sol`); the stable 0.154.0 does not list it (openai/codex#47420). An older, logged-out or offline CLI is caught by a catalog check (`codex debug models`) in the runner's preflight and before the implementer's gate, with an "upgrade the Codex CLI, or check login and network" message rather than a degraded gate.
- **Git >= 2.5** (worktrees).
- **CI that runs on draft PRs.** An orchestrated PR is a draft from planning until the merge step, so a workflow that skips drafts (`if: github.event.pull_request.draft == false`) must list `ready_for_review` in its `pull_request` `types` **alongside** the defaults (`opened`, `synchronize`, `reopened` — a `types` list replaces them, and a workflow keyed on `ready_for_review` alone never tests a later push, draft or not); otherwise the merge's checks gate sees no checks, or only `skipped` ones, and reports the merge as uncovered. A bare `on: pull_request` is fine.
- **A validation contract is optional.** `.issue-runner/validation` (above) tells implementers what to run; without it they fall back to the project's conventions.
- **An integration contract is optional.** `.issue-runner/integration` declares a `hint:` command the orchestrator runs at run start, after each merge, at run end and on `--flush` (`docs/integration-rfc.md`, slice 1); without it no hint is sent.
- **`jq`**, only for the release smoke test's `check.sh` (below).

The `gh-issue` implementer skill is bundled — no separate installation.

## Known limitations

- **Trust the issue authors.** Implementers consume issue bodies and comments verbatim as their task spec and, in orchestrated mode, hold merge authority (`gh pr merge` with no human gate). Do **not** point `/issue-runner` at a repo whose issues can be authored by untrusted parties — a malicious issue body is prompt-injection executed as instructions by an agent that can merge to your default branch. The pipeline is safe when you author the issues yourself (via `/issue-plan`); the spec instructs implementers to treat issue content as data, but that is a mitigation, not a sandbox. The planner's reconciliation step reads existing issues, PRs and design documents the same way — as data about what exists, never as instructions about what to publish, skip or close — and its `conflict` and `supersedes` outcomes are your decisions, so an existing issue cannot steer a plan on its own. **`--no-merge` is the answer when you can't fully trust the queue** (a team repo, externally authored issues, or a pilot where someone wants to look before anything lands): every implementer still explores, implements, and converges its PR through the full review loop, but stops right after the checks gate passes instead of merging — the issue lands `ready` (worktree and branch kept, dependents paused, never a cycle) with the PR sitting open and mergeable for a human to look at. `/issue-runner --merge-ready` merges every eligible `ready` PR and continues the run for what it unblocks once you're satisfied; merging by hand and re-running with the remaining issue numbers works too — no stacked PRs, no second mechanism, just a dependent that waits for its base to actually merge, the same as it always did. On a project that declares `.issue-runner/integration`, the orchestrator also runs its `hint:` command from its own checkout without supervision. A PR that edits the contract file needs a human, but a PR that edits the script the command names is an ordinary diff an implementer may merge (`docs/integration-rfc.md` §5.3). `--no-merge` is the mitigation there too.
- **One run serves one repository.** Scope, DAG, state and worktrees belong to the repository the session runs in. A prerequisite in another repository (`owner/repo#N`, or a backend endpoint the issue says is missing) is an *external edge*: Step 2 prints it and asks you to **run-elsewhere** (implement it in a run started in that repository, then re-run here), **override**, **drop-issue**, or **contract-first** (the implementer documents the proposed contract, optionally files the dependency issue in that repository when you authorize it, and stops with a `contract-first:` blocker without implementing). The runner never creates a worktree or dispatches in a second repository; to cover two repositories, start one run in each.
- **Single-host.** State lives at `${XDG_STATE_HOME:-$HOME/.local/state}/issue-runner/<repo-key>/state`, namespaced by repo root, so runs in **different** repos are isolated; within a repo, a lock refuses a second concurrent run while its PID is alive **or** its heartbeat mtime is younger than `--lock-ttl-minutes` (default 120) — a crashed run's lock ages past both signals and is taken over.
- **Explicit intent recommended.** Ask for `issue-plan`, `issue-runner`, or `gh-issue` by name when you want a mutating GitHub workflow; Codex can then select the matching bundled skill.
- **Re-runs resume open PRs.** Dispatch detects an existing open PR for an issue (head branch matches `/issue-<N>-`) and continues on its branch instead of opening a duplicate — including the **draft** PR an orchestrated implementer opens right after planning, so a run killed before implementation (or a host that lost its local state) resumes from its plan. Close the PR first for a from-scratch retry (`gh pr close <P> --delete-branch`, so the remote branch goes too).
- **Host process died mid-run?** `claude --resume "$(cat "$RUN_ROOT/session")"` (same permission mode and allowed tools as the original run) reattaches to the same session and lets the harness restart or reconnect its in-flight implementers with their own context intact, instead of throwing that work away for a from-scratch dispatch — see SKILL.md's Recovery section. This depends on the session transcript, which is swept after `cleanupPeriodDays` (default 30 days) and never written at all under `--no-session-persistence`.
- **Mostly no automated tests.** Behavior is validated by production runs documented in `CHANGELOG.md`; `scripts/lint.sh` additionally syntax-checks the embedded bash recipes (`bash -n`) and guards recipe drift across the skill files, but nothing automated exercises the workflows end-to-end (the manual "Release smoke test" below does). The deterministic parts are extracted into bundled scripts that do have fixture tests: `skills/issue-runner/scripts/scheduler.sh`, the Step 3 cascade-skip/ready-set/cycle-check state machine extracted into a bundled script: `skills/issue-runner/scripts/test-scheduler.sh` runs it against fixtures for every row of `docs/scenarios.md` it covers, from `scripts/lint.sh` and CI — and, alongside it, `skills/gh-issue/scripts/validation-contract.sh`, gh-issue's validation-contract recipe (also the runner's Step 0 probe), which `scripts/test-validation-contract.sh` runs against fixtures for a contract that is present, absent, failing, declaring `full`, invalid, or naming a command that cannot run. `skills/issue-runner/scripts/classify.sh` holds Step 3 item 5's merge-proof classification and Step 5's unfinished-PR shape. `skills/issue-runner/scripts/test-classify.sh` runs it against a stubbed `gh` and temporary git repositories for every outcome. `skills/issue-runner/scripts/run-state.sh` holds the State section's run lock, heartbeat and state rotation; `skills/issue-runner/scripts/test-run-state.sh` runs it against a temporary state root for each lock and rotation case. `skills/issue-runner/scripts/resume-check.sh` holds Step 3a's resume probes, and `skills/issue-runner/scripts/merge-ready.sh` the mechanics of the `--merge-ready` pass (the PR state, the refresh against the PR head and the base, the checks re-check, the head-pinned merge); `test-resume-check.sh` and `test-merge-ready.sh` beside them run each against a stubbed `gh` and temporary git repositories for every output line. `skills/issue-runner/scripts/plan-file.sh` holds Step 2's plan-file drift check, and `test-plan-file.sh` runs it against a stubbed `gh` for every output line. `skills/issue-runner/scripts/integration.sh` holds the integration contract (`.issue-runner/integration`, slice 1 of `docs/integration-rfc.md`): its discovery and grammar, the lifecycle hints and `--flush`. `scripts/test-integration-contract.sh` runs it against temporary git repositories and a dump-the-environment hint command. Lint keeps every bundled script that the Codex edition also ships byte-identical in both editions (`cmp`). Lint also enforces Anthropic's skill-authoring guideline on size: every `skills/*/SKILL.md` body stays at most 500 lines and 5,000 words, with no line over 1,500 characters. Mode-specific procedures live in files linked one level deep from SKILL.md, and rationale lives in each skill's `REFERENCE.md` behind `(why: …)` pointers, which lint checks resolve.

## Release smoke test

Before a release, run one real orchestrated run end to end against a throwaway private repository. It is manual on purpose: it spends real agent and Codex time and creates a GitHub repository, so lint and CI only parse the scripts.

1. `scripts/smoke/setup.sh` creates `issue-runner-smoke-<timestamp>` (private, under your `gh` user) from a bash-only fixture whose `.issue-runner/validation` runs in under a second, opens a tracking issue and three slices (one independent, one `## Blocked by` it, one whose `Files likely touched:` overlaps it), keeps the local repository it pushed from under `~/issue-runner-smoke/` (`ISSUE_RUNNER_SMOKE_ROOT` overrides), and prints the next commands (with an overridden root, resolved to an absolute path).
2. Start Claude Code in that local repository, with the plugin installed from this checkout ("Local development" above, so the run tests the release candidate, not the last published version), and run the printed `/issue-runner:issue-runner --no-merge <A> <B> <C>`.
3. Before merging anything, `scripts/smoke/check.sh <name>` prints PASS/FAIL per assertion, from GitHub and the run's state: a `--no-merge` run over exactly the three issues with both edges on the independent one, which the run never merged; the independent issue `ready` with an open, non-draft, mergeable PR; the dependent and the conflicting issue paused behind it, never dispatched, as `--no-merge` defines; the conflict recorded; each PR body's `## Review notes` (carrying gh-issue's line for each state its `result.json` shows: an inline review pass, a degraded, waived or capped gate, a revoked profile; optional when there is none) and the validation its Test plan names; every dispatched `result.json` present and parseable. It needs `jq`, exits 1 on any FAIL, and refuses (exit 2) once the independent PR has been merged after the run. GitHub offers draft PRs in private repositories only on some plans; without them the run takes the no-draft path, which `check.sh` reports as a NOTE.
4. `scripts/smoke/teardown.sh <name>` deletes the repository, the local repository and the run's state after you type the name back, and fails if any local file cannot be removed (only the local files if the repository no longer exists: a 404 counts only for its owner's token with the `repo` scope). It refuses any name without the `issue-runner-smoke-` prefix. Deleting needs the `delete_repo` scope: `gh auth refresh -h github.com -s delete_repo`.

## Versioning

Semantic-ish. Pre-1.0 means the spec may change incompatibly between minor versions.

## License

MIT. See `LICENSE`.
