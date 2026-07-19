# Skill evals

Each skill ships an eval suite under `skills/<name>/evals/`:

```
skills/<name>/evals/
├── evals.json   # eval definitions (skill-creator schema: prompt, files, expectations)
└── files/       # dry-run fixtures referenced by the prompts
```

- `skills/issue-runner/evals/` — 6 evals over the orchestrator's scheduling and
  hygiene rules: cascade skip, blocked-chain vs true cycle, the merge-proof
  invariant, the Step 3a resume check, the single-issue fast path, and Step 1
  scope hygiene (truncation warning, parked labels, dirty-tree audit).
- `skills/gh-issue/evals/` — 5 evals over the implementer's trust and merge
  discipline: issue-body prompt-injection resistance, the Codex-gate
  degradation matrix (exit-status/stderr vs spoofable review text), bouncing
  vs converged review loops, the advisory-CI checks gate, and the interactive
  resume choice.
- `skills/issue-plan/evals/` — 3 evals over the planner's output contract:
  vertical slicing in the exact issue-body format, minimal coupling (no
  artificial `Blocked by` edges), and the shared `## Interfaces` section.

## Why dry-run fixtures

A real end-to-end run of these skills creates branches, opens PRs, and — in
orchestrated mode — **merges to the default branch**, and it requires `gh`
auth, the `codex` CLI, and a sacrificial repository. That is the wrong cost and
blast radius for a regression check. Instead, every fixture records the
`gh`/`git`/`codex` outputs the skill would observe at a specific decision point
and asks the model, following the SKILL.md, to produce its decisions as small
JSON/markdown artifacts. The expectations then check those artifacts — the same
dry-reading contract as `docs/scenarios.md`, but executable by an agent instead
of a human.

The issue-runner rows derive directly from the golden scheduler scenarios in
[`docs/scenarios.md`](scenarios.md). That document's rule carries over: a spec
edit that changes an expected behavior pinned here is a **breaking change**
(version bump + CHANGELOG entry), and the eval must be updated in the same
commit.

## Running the evals

The suites follow the schema used by the `skill-creator` skill
(`evals/evals.json` with `prompt` / `files` / `expectations`). To run one eval
by hand, for each entry:

1. Spawn a fresh agent with the skill's `SKILL.md`, the eval `prompt`, and the
   fixture(s) listed in `files` (paths are relative to the skill directory).
   Tell it to save outputs to a scratch directory.
2. Grade each `expectations` entry against the produced artifacts (most are
   checkable mechanically against the JSON the prompt requests; the rest are a
   short judgment call with the fixture in hand).

With `skill-creator` installed, its benchmark flow (with-skill vs baseline
runs, grading, and the review viewer) works on these files as-is.

Fixtures are self-contained on purpose: an eval run must **never** need
network, `gh`, `codex`, or a real repository. If you add an eval, keep that
property — record the command outputs in the fixture and have the prompt ask
for decisions, not side effects.
