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

**Context.** Parallel implementers merge to the default branch independently. Today's mitigations: conflict edges from LLM refinement serialize likely-colliding issues, and resumed PRs get a freshness check. What's missing is the classic two-trains problem: A and B both pass review against the main they branched from; A merges; B's tests were never run against main+A.

**Options.**
1. Status quo. Cheap; squash merges surface textual conflicts, but semantic conflicts land silently.
2. Full merge queue: before each merge, the implementer rebases (or merges main into) its branch, re-runs the test suite against current main, then merges — serially, one PR at a time through the queue.

**Recommendation.** Sketch, don't build yet. Cost is one extra test run per merge plus queue serialization at the end of the run; value scales with parallelism and test coverage. Below ~N=6 parallel slices on repos with decent suites, the conflict-edge serialization has been sufficient in production runs. Shape when needed: a "merge token" file in `$STATE_DIR` — an implementer ready to merge waits for the token, refreshes against main, tests, merges, releases. Fits the existing state-through-files rule with no new machinery.

---

## 3. Pluggable review gate

**Status:** proposed

**Context.** The Codex gate exists for cost discipline, not cross-model diversity — CHANGELOG 0.4.0 justifies the Phase 1/Phase 2 split purely as "Codex tokens are the scarce resource". Nothing in the contract requires the gate to be Codex specifically: what the spec actually relies on is (a) a final reviewer with no implementation bias, (b) an exit-code-keyed degradation path (credit/quota → degrade loudly; anything else → block).

**Options.**
1. Status quo: `codex review` hardcoded.
2. Configurable gate command, default `codex review -c model=gpt-5.6-terra`. Alternatives: `claude -p` at high effort with the gate-review framing (same-vendor, but fresh context — weaker diversity, zero extra tooling); `none` + rely on CI checks (for repos with strong pipelines).
3. Multiple gates in sequence. Rejected: cost multiplies, convergence semantics get murky.

**Recommendation.** Option 2, as a `--gate-cmd` flag (or per-repo config) that must preserve the contract: the command's own exit status and stderr drive the degradation decision, never its stdout text (the 0.7.0 injection fix). `--no-codex-gate` (0.8.0) is already the `none` case; this generalizes it. Keep the default as-is — the pinned Codex gate has earned its keep in production.

---

## 4. Structured planner artifact

**Status:** proposed

**Context.** `/issue-plan` does expensive work — codebase exploration, an adaptive interview, slice design — and then discards everything except the issue bodies. Only `## Blocked by` (and the optional `## Interfaces`) survive as machine-readable signal. The runner then re-derives what the planner already knew: conflict edges come from a second LLM pass guessing at file-scope overlap the planner had explicitly decided.

**Options.**
1. Status quo: issues are the only artifact; LLM refinement re-infers conflicts.
2. Planner also emits a machine-readable plan file — DAG plus per-issue file-scopes — committed to the repo or attached to a tracking issue. The runner reads it: file-scope intersection becomes a deterministic conflict check; `--no-llm-refine` becomes the default when a plan file exists.
3. Encode file-scopes into each issue body as another `##` contract section. Lighter, but per-issue scopes without the cross-issue view still need assembly.

**Recommendation.** Option 2, attached to a tracking issue (committing planner output pollutes repo history for what is run metadata). Deterministic overlap detection removes the least reliable LLM pass in the pipeline and gives entry point for the hybrid scheduler (note 1) to consume the same file. Requires a versioned schema — keep it minimal: `{issues: [{n, blocked_by: [], files: []}]}`.

---

## 5. Spend telemetry and budget limits

**Status:** blocked-upstream (partial: proposed)

**Context.** Token budgets cannot be enforced from a skill spec — the harness meters tokens, and neither the orchestrator nor the implementers can observe their own consumption. "Stop when you've spent X" is not implementable as prose.

**Options.**
1. Do nothing; cost control stays with the caps that exist (`--max-parallel`, `--max-codex-iterations`, Phase 1 iteration cap).
2. What's feasible today: agent-count *estimates* at `--plan` time (issues × expected agents per issue: implementer + Explore + 2 reviewers × iterations + gate passes), and per-run aggregation of actuals — iteration counts and gate passes are already in every implementer's Step 10 report; the orchestrator can sum them into the Step 5 summary.
3. Real budget enforcement — requires harness support (a per-Agent-call token ceiling or a session meter readable from the session). Track upstream; not buildable here.

**Recommendation.** Option 2 now (the per-run aggregation half is added as of this pass; the `--plan` estimate is cheap to add), option 3 when the harness grows a meter. The estimate's value is pre-flight sticker shock — "this run will dispatch ~40 agents" before dispatching any — which is the decision point a budget would have guarded anyway.
