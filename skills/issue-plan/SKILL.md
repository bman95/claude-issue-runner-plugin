---
name: issue-plan
version: 0.2.0
disable-model-invocation: true
description: "Turns an idea, plan, or spec into ready-to-run GitHub issues: interviews only where the input has gaps, slices the work into tracer-bullet vertical slices, and publishes in the format /issue-runner parses (What to build / Acceptance criteria / Blocked by). Trigger: the user types /issue-plan. Do not auto-invoke."
---

# Issue Plan

Turn `/issue-plan <idea, plan text, file path, or issue reference>` into published GitHub issues that `/issue-runner` can execute unattended. The goal of every step: issues so well specified that an autonomous implementer never needs a human.

## 1. Absorb

Read what you were given — inline text, a file, or an existing issue (`gh issue view`). Then explore before asking anything: dispatch an `Explore` subagent to map the affected area of the codebase. Never ask the user something the repo can answer.

## 2. Interrogate (adaptive depth)

Match the questioning to how clear the input already is:

- **Clear and small** → skip to the breakdown.
- **Gaps, ambiguities, or contradictions** → interview the user, one question at a time, always leading with your recommended answer. Stress-test fuzzy relationships with concrete scenarios ("what happens if X arrives twice?"). When the user's description conflicts with what the code does, surface it.

Stop when you could confidently answer an implementer's questions yourself. Decisions that would otherwise surface as run-time blockers — product behavior, scope edges, real trade-offs — get settled **here**, not during the run.

## 3. Slice

Break the work into **tracer-bullet vertical slices**:

- Each slice cuts through every applicable layer end-to-end (schema, API, UI, tests) — never a horizontal layer on its own.
- A finished slice is demoable or verifiable by itself.
- Prefer many thin slices over few thick ones.
- Minimize coupling: every `Blocked by` edge serializes the run, so only declare real dependencies — fewer edges, more parallelism.
- Keep file scopes disjoint where you can: two slices that touch the same files are serialized by `/issue-runner` exactly like a `Blocked by` edge (conflict edges from `Files likely touched:`, Step 4).

Present the breakdown as a numbered list — title, blocked-by, one-line scope — and ask: granularity right? dependencies right? merge or split anything? Iterate until the user approves.

## 4. Publish

Publish in dependency order (blockers first, so you can reference real issue numbers). One `gh issue create` per slice with this body — it is the contract with `/issue-runner` (`## Blocked by` is its primary DAG source) and with `gh-issue` (the checklist is the implementer's definition of done):

```markdown
## What to build

End-to-end behavior of this slice, described as outcome, not layer-by-layer implementation.

## Acceptance criteria

- [ ] Criterion 1
- [ ] Criterion 2

## Blocked by

- #N

(or "None - can start immediately")

## Interfaces

- `parseConfig(path: string) -> Config` — provided by #N, consumed here
- `POST /api/widgets` — request/response shape agreed across slices

Files likely touched: `src/config.ts`, `src/api/widgets.ts`
```

`Files likely touched:` is **mandatory** and always the last line of the body: the repo-relative paths this slice edits or creates, comma-separated, from your Step 1 exploration; a directory scope ends with `/` (`src/api/`). `/issue-runner` Step 2 intersects these lines pairwise to derive conflict edges deterministically — two slices naming the same path, or one naming a directory that contains the other's path, are serialized. The line's cost model is asymmetric: any in-scope issue **without** it sends the whole run through the LLM refinement pass, while a path **omitted** from it lets two implementers merge over each other — so list every path the slice will touch. `gh-issue` Step 2 also seeds the implementer's codebase exploration with it.

`## Interfaces` is **optional**: include it only when slices share a contract — function signatures, schemas, endpoints, or file boundaries agreed between slices. `/issue-runner` ignores this section; it exists for the implementer, which seeds its codebase exploration with it (gh-issue Step 2). When it is absent, `Files likely touched:` follows `## Blocked by` directly.

## 5. Hand off

Show the published issue numbers and offer to run `/issue-runner` on them right away (all, or the subset the user picks).
