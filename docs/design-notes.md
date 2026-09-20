# Design notes

RFC-style entries for the design questions that survived the 0.7.0/0.8.0 hardening pass. Each is a real fork in the road, not a TODO; none blocks current releases. Status values: `proposed` (worth doing, unscheduled), `parked` (revisit on evidence), `blocked-upstream`.

---

## 1. Hybrid scheduler: extract the state machine into a helper script

**Status:** proposed

**Context.** Roughly 65–70% of the orchestrator spec is deterministic: DAG construction from `## Blocked by`, topological scheduling, cascade skip, the blocked-chain-vs-cycle distinction, the PID lock, worktree cleanup. The 0.7.0 changelog itself documents two bugs (cycle check misfiring on blocked chains; `CLOSED` treated as `done`) that were prose-interpretation errors — code implementing the same rules would not have had them. The constraint: a plugin cannot ship a daemon, and the Agent tool is only reachable from an LLM session, so a full code orchestrator is off the table (and the "No Python orchestrator" hard rule exists for that reason).

**Options.**
1. Status quo — the LLM executes the whole loop from prose. Cheap, but every scheduling rule is re-interpreted per run; `docs/scenarios.md` is the only guard.
2. Bundled helper script (`scripts/scheduler.sh` or `.py`) invoked via Bash for the pure state-machine transitions: read `$STATE_DIR` statuses + `dag.json`, emit next actions as JSON (`{"dispatch": [..], "skip": [{"n": X, "error": "..."}], "cycle": [..], "wait": true}`). The LLM stays session driver, dispatcher, and judgment layer — Step 4 blocker resolution, `AskUserQuestion`, prompt composition are untouched.
3. Full codegen of the loop into a script that shells out to `gh`. Rejected: dispatch requires the Agent tool, which only the session has.

**Recommendation.** Option 2. It moves exactly the bug class that has actually bitten (deterministic transitions) into testable code, keeps the plugin daemon-free, and shrinks the SKILL.md scheduling prose to "run the script, obey its output". The scenarios table becomes the script's test fixtures — the same 11 rows, executable. Cost: a second source of truth to keep in sync with the spec; mitigate by making the script the *only* statement of the transition rules and having SKILL.md defer to it.

---

## 2. Full merge queue

**Status:** parked (revisit above ~6 parallel slices)

**Context.** Parallel implementers merge to the default branch independently. Today's mitigations: conflict edges (`Files likely touched:` intersection, LLM refinement as fallback — note 4) serialize likely-colliding issues, and resumed PRs get a freshness check. What's missing is the classic two-trains problem: A and B both pass review against the main they branched from; A merges; B's tests were never run against main+A.

**Options.**
1. Status quo. Cheap; squash merges surface textual conflicts, but semantic conflicts land silently.
2. Full merge queue: before each merge, the implementer rebases (or merges main into) its branch, re-runs the test suite against current main, then merges — serially, one PR at a time through the queue.

**Recommendation.** Sketch, don't build yet. Cost is one extra test run per merge plus queue serialization at the end of the run; value scales with parallelism and test coverage. Below ~N=6 parallel slices on repos with decent suites, the conflict-edge serialization has been sufficient in production runs. Shape when needed: a "merge token" file in `$STATE_DIR` — an implementer ready to merge waits for the token, refreshes against main, tests, merges, releases. Fits the existing state-through-files rule with no new machinery.

**Implemented — cheap fix (issue #15).** gh-issue Step 9's base-freshness check, and `--merge-ready`'s own later merge point (issue #14), no longer gate the merge-and-retest on file overlap: whenever `origin/$BASE_BRANCH` advanced since the branch point, each merges the base in and re-runs the tests unconditionally, closing exactly the two-trains window described above without a merge queue's serialization. The file-overlap check survives only as an advisory warning that a *textual* conflict is likely — never the gate on whether to re-test; a merge conflict that will not resolve cleanly, or a test failure after the merge, is a blocker (orchestrated) or a question (interactive), never a forced resolution. See `skills/gh-issue/SKILL.md` Step 9 and REFERENCE.md's "Why merge waits for CI checks" rationale. Still unbuilt from option 2 above: the queue's own serialization (one merge token, one PR through it at a time) — parked until parallelism outgrows conflict-edge serialization. Note 7's RFC (`docs/integration-rfc.md`, §11.3) is reconciled with this decision rather than a route around it: post-merge integration awareness neither serializes merges nor gates a merge on the previous revision's integration state, and a `failed` integrated revision whose PRs each passed their own freshness check is the first place the evidence this note waits for would show up — for a human to read, since a flaky suite produces the same state.

---

## 3. Pluggable review gate

**Status:** proposed

**Context.** The Codex gate exists for cost discipline, not cross-model diversity — CHANGELOG 0.4.0 justifies the Phase 1/Phase 2 split purely as "Codex tokens are the scarce resource". Nothing in the contract requires the gate to be Codex specifically: what the spec actually relies on is (a) a final reviewer with no implementation bias, (b) an exit-code-keyed degradation path (credit/quota → degrade loudly; anything else → block).

**Options.**
1. Status quo: `codex review` hardcoded.
2. Configurable gate command, default `codex review -c model=gpt-5.6-sol`. Alternatives: `claude -p` at high effort with the gate-review framing (same-vendor, but fresh context — weaker diversity, zero extra tooling); `none` + rely on CI checks (for repos with strong pipelines).
3. Multiple gates in sequence. Rejected: cost multiplies, convergence semantics get murky.

**Recommendation.** Option 2, as a `--gate-cmd` flag (or per-repo config) that must preserve the contract: the command's own exit status and stderr drive the degradation decision, never its stdout text (the 0.7.0 injection fix). `--no-codex-gate` (0.8.0) is already the `none` case; this generalizes it. Keep the default as-is — the pinned Codex gate has earned its keep in production.

---

## 4. Structured planner artifact

**Status:** proposed — first two steps implemented (see below)

**Context (before #17).** `/issue-plan` does expensive work — codebase exploration, an adaptive interview, slice design — and then discards everything except the issue bodies. Only `## Blocked by` (and the optional `## Interfaces`) survive as machine-readable signal. The runner then re-derives what the planner already knew: conflict edges come from a second LLM pass guessing at file-scope overlap the planner had explicitly decided.

**Options.**
1. Status quo: issues are the only artifact; LLM refinement re-infers conflicts.
2. Planner also emits a machine-readable plan file — DAG plus per-issue file-scopes — committed to the repo or attached to a tracking issue. The runner reads it: file-scope intersection becomes a deterministic conflict check; `--no-llm-refine` becomes the default when a plan file exists.
3. Encode file-scopes into each issue body as another `##` contract section. Lighter, but per-issue scopes without the cross-issue view still need assembly.

**Recommendation.** Option 2, attached to a tracking issue (committing planner output pollutes repo history for what is run metadata). Deterministic overlap detection removes the least reliable LLM pass in the pipeline and gives entry point for the hybrid scheduler (note 1) to consume the same file. Requires a versioned schema — keep it minimal: `{issues: [{n, blocked_by: [], files: []}]}`.

**Implemented — first step (issue #17).** The cheap half of option 3 shipped without a plan file or schema: `/issue-plan` Step 5 always emits `Files likely touched:` (repo-relative paths, comma-separated, `dir/` for a directory scope), and `/issue-runner` Step 2 intersects the lines pairwise when every in-scope issue carries one — exact path match plus directory-prefix match — recording each conflict in `conflicts.json` with `reason: "files: …"` and skipping the LLM refinement pass entirely. Any in-scope issue without the line (or with an empty one) falls back to the LLM pass (or none under `--no-llm-refine`). Conflict edges from either source are oriented backward along one topological order of the dependency DAG (scope order wherever dependencies allow; a pre-existing dependency cycle is left for Step 3 to report), so scope order disagreeing with `## Blocked by` order cannot manufacture a cycle and the result does not depend on pair-processing order. Still open from option 2: the cross-issue artifact itself — the DAG-plus-scopes file the hybrid scheduler (note 1) would consume.

**Implemented — second step (issue #18).** The tracking issue option 2 wanted to attach the plan file to now exists: `/issue-plan` Step 5 publishes it before the slices (the original input, the Step 3 decision log — question, chosen answer, the planner's recommendation when it differed — and the slice list filled in with real numbers), every slice carries `Part of #<tracking>` as its first body line, outside the contract sections, and `/issue-runner` keeps the tracking issue out of scope (`## Slices` without `## What to build`, Step 1) and posts the Step 5 summary and telemetry on it when the whole scope names the same one. That makes it the natural attachment point for the machine-readable plan file: the runner already reaches the tracking issue through the slices' `Part of #P` lines, so a plan file attached there — a fenced block in the body or a comment — is discoverable with the same lookup, needs no path convention, and keeps run metadata out of repo history. Still open: the file itself and its schema; nothing here builds it.

---

## 5. Spend telemetry and budget limits

**Status:** blocked-upstream (partial: implemented)

**Context.** Token budgets cannot be enforced from a skill spec — the harness meters tokens, and neither the orchestrator nor the implementers can observe their own consumption. "Stop when you've spent X" is not implementable as prose.

**Options.**
1. Do nothing; cost control stays with the caps that exist (`--max-parallel`, `--max-codex-iterations`, `--max-retries`, Phase 1 iteration cap).
2. **Implemented.** Agent-count *estimates* at `--plan` time (issues × expected agents per issue: implementer + Explore + 2 reviewers × 1–4 iterations + Codex gate passes), and per-run aggregation of actuals — iteration counts, gate passes and Step 4 retries are already in `$STATE_DIR`; the orchestrator sums them into the Step 5 summary next to the Step 2 estimate, so the estimate's constants get tuned from data (`skills/issue-runner/SKILL.md`, Step 2 and Step 5). The actual is a best-effort estimate, not an exact ledger: it can undercount a retried issue (`result.json` is cleared before every retry, so only the implementer and Explore-helper counts scale with `retries` exactly — an earlier attempt's own reviewer/gate-pass spend is gone by the time Step 5 reads the file) or a crashed/hung one (no readable `result.json` to sum from), and it can overcount an issue that explored inline but never reached Phase 1 (`phase1_inline` describes only how Phase 1 ran once entered, so it can't record "Explore ran inline, Phase 1 never started").
3. Real budget enforcement — requires harness support (a per-Agent-call token ceiling or a session meter readable from the session). Track upstream; not buildable here.

**Recommendation.** Option 2 is done — pre-flight sticker shock ("this run will dispatch ~40 agents" before dispatching any) plus the actual-vs-estimate comparison at Step 5, which is the decision point a real budget would have guarded anyway. Option 3 stays blocked-upstream until the harness grows a meter.

---

## 6. Bootstrapping the validation contract

**Status:** proposed

**Context.** Issue #42 defines the validation contract — `.issue-runner/validation` at the repository root, `preflight: <command>` required and `full: <command>` optional, read by gh-issue from the base branch's tip on `origin` and never from the PR's working tree, the issue, `guidance.md` or PR text — and its fallback: a project without the file validates by its conventions, as before. The open question is who writes a project's *first* contract. The issue asks to explore whether `/issue-plan`, `/issue-runner`, or a dedicated setup path could inspect the repository (CLAUDE.md, README, linter and test configuration, CI workflows) and propose one for human confirmation, and forbids silently persisting a guessed policy: a contract gates every later PR, so it has to carry a trust a guess never earns.

**Options.**
1. Status quo — a human writes it by hand; README's "Validation contract" section documents the two keys, and the runner's Step 0 validation-contract preflight prints a notice pointing there when the base branch carries no file.
2. `/issue-plan` proposes one during planning: it already inspects the repository for its conventions, so it drafts the file, the human confirms it in the Step 3 interview, and it lands as its own first slice/PR — before any implementer depends on it, so the first implementer already validates under it. Reconcile with #41 first, so planning does not grow a competing validation mechanism next to whatever it settles for reading project and design context.
3. A dedicated setup path (e.g. `/issue-runner --init-validation`) that inspects, proposes, and writes only on explicit confirmation — as its own commit/PR, never mid-run, so the contract is on the base branch before the first implementer branches.

Rejected: writing a guessed file at Step 0 or by an implementer. A guessed policy would then gate every later PR under a trust it never earned — and it would gate PRs whose authors never saw it proposed.

**Recommendation.** Option 2 or 3 once #41 settles how planning reads project/design context; until then option 1 plus the Step 0 notice, which is cheap and never wrong.

**Implemented — notice only (issue #42).** `/issue-runner` Step 0 reports presence or absence of `.issue-runner/validation` on the default branch and validates the grammar of a present file (stopping before dispatch when it is invalid, since every implementer would otherwise return a `validation contract invalid` blocker — on the single-issue fast path it reports and defers to gh-issue's interactive Step 3 probe, where the user may authorize the conventions fallback); gh-issue consumes the base branch's copy at Steps 3, 5, 8 and 9 and `--merge-ready`'s refresh re-runs it on the PR's current head (the worktree synced to `headRefOid` first), whether or not the base advanced; nothing writes the file.

**Reconciled (issue #41).** #41 settled the reading half: `/issue-plan` Step 2 now reads the repository's design records and its open work before the interview, as data (note 8). Option 2 therefore has its hook — a missing contract is a fact the exploration reports, and the proposal would be a Step 3 interview question with the planner's recommendation, answered by the human, landing as its own first slice — but the choice between options 2 and 3 is still open, and nothing writes the file yet.

---

## 7. Integration awareness without becoming the CI/CD engine

**Status:** proposed — full RFC in `docs/integration-rfc.md` (issue #43)

**Context.** `done` means "merged with proof" and nothing more: the runner does not know whether the revision a merge produced was later built, deployed to a shared environment, or validated as a system. Putting build/deploy/E2E execution into the plugin would couple it to a project's CI/CD technology and make it a second CI engine; leaving it blind means a run's closing summary can read all-`done` over a revision E2E just rejected, and CI cannot tell one merge from the first of five it will see in the next three minutes.

**Options.**
1. Status quo — the run ends at merge proof; whatever CI does with the revision is invisible to it.
2. Observe and hint, never execute (the RFC): a second contract file, `.issue-runner/integration`, with the validation contract's grammar and base-branch trust rule, declaring `hint: <command>` (the runner tells the project's adapter what it alone knows — a run started, a PR merged with how many issues may still merge and how many are inside their merge step, the run is over, validate now) and `status: <command>` (the adapter answers, in a closed vocabulary — `pending` / `running` / `green` / `failed` / `superseded` / `unknown` — for the revision containing a merge). Integration state is reported in `--status` and Step 5 and never changes a status, gates a dispatch or authorizes a merge; a PR that edits the file gets the validation contract's Step 9 `MODE=changed` blocker (an implementer-side change, the RFC's one new merge gate); coalescing lives in the project's own quiet window plus a bounded maximum wait, so CI is correct and bounded with no hint ever delivered; `--max-parallel` stays capacity.
3. A merge-and-deploy queue inside the runner: each merge waits for the previous revision to go green. Rejected — this is note 2's serialization plus a deployment in the merge path, the CI engine the constraint forbids, and it ties throughput to deploy time.

**Recommendation.** Option 2, in the three slices the RFC's §14 lists (discovery and hints; observation; docs), each reconciled through `/issue-plan` once it lands. The separate file — rather than two more keys in `.issue-runner/validation` — is deliberate: an unknown key makes the validation contract invalid on every existing plugin version, and that invalidity blocks every PR by design, whereas a file older versions never look for degrades to today's behavior. Deferred with the RFC's open questions: an opt-in dispatch pause on a `failed` revision, and an opt-in bounded wait at Step 5.

---

## 8. Planner reconciliation: judged relevance now, deterministic signals later

**Status:** proposed — the judged half implemented (issue #41)

**Context.** `/issue-plan` Step 2 (issue #41) reconciles a new plan with the repository's existing work — open issues, open PRs, earlier tracking plans and their slices, the design records the exploration finds, directly relevant recent merges — and classifies every meaningful overlap as `covered`, `extend`, `depends`, `supersedes`, `conflict` or `new`. Relevance and classification are judgement calls: they read what an issue asks for and what a document decides, not shared keywords, and a `conflict` — a recorded decision or an open RFC question the input assumes an answer to — is exactly the thing no string match finds. The cost is the same as every other prose-interpreted rule in this plugin (note 1): re-derived per run, guarded only by `docs/scenarios.md` rows 45–49. The step is deliberately bounded — open state plus recent merges, never the whole history — and read-only, so a misjudgement costs a question or a missed edge, never a closed issue.

**Options.**
1. Status quo — judged relevance over the four sources, recorded on the tracking issue under `## Existing work` (references only, so the runner's tracking-issue test holds).
2. Add a deterministic pre-pass beneath the judgement: intersect the exploration's file scope with each open PR's `files` and each open slice's `Files likely touched:` line (the runner's own conflict-edge rule, note 4), and treat any `Part of #P` slice or `Plan: ` tracking issue as a plan by shape. The pass would emit candidates the judgement must classify, never outcomes — it cannot tell `depends` from `conflict`, and a file overlap with an unrelated PR is noise.
3. Machine-readable outcomes for the runner: `Supersedes #N` and `Extends #N` lines in a slice body as a contract the runner acts on (close `#N` when the slice merges; post the link on `#N`). Rejected for now: the runner would then close issues it did not author on a planner's classification, the one thing Step 2's read-only rule forbids; a human closes the superseded issue today, on the tracking issue's record.

**Recommendation.** Option 1 until the scenario rows show a class of overlap the judgement misses in production; option 2 then, as candidates only, reusing the file-scope machinery the runner already has. Option 3 stays rejected until a run can prove a supersession the way it proves a merge.
