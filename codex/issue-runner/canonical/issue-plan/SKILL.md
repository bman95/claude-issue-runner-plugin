---
name: issue-plan
version: 0.2.0
disable-model-invocation: true
description: "Turns an idea, plan, or spec into ready-to-run GitHub issues: interviews only where the input has gaps, slices the work into tracer-bullet vertical slices, and publishes a tracking issue (input, interview decisions, slice list) plus one issue per slice in the format /issue-runner parses (What to build / Acceptance criteria / Blocked by / Files likely touched). Trigger: the user types /issue-plan. Do not auto-invoke."
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

Keep a **decision log** as you go — one entry per question: the question, the answer chosen, and your recommended answer when the user chose differently. Step 4 publishes it on the tracking issue: the interview is where the product decisions get made, and the slice bodies only carry what fits, so without the log nobody can later see why an option was chosen or what was rejected. A skipped interview logs a single entry: `No interview needed - input was clear.`

## 3. Slice

Break the work into **tracer-bullet vertical slices**:

- Each slice cuts through every applicable layer end-to-end (schema, API, UI, tests) — never a horizontal layer on its own.
- A finished slice is demoable or verifiable by itself.
- Prefer many thin slices over few thick ones.
- Minimize coupling: every `Blocked by` edge serializes the run, so only declare real dependencies — fewer edges, more parallelism.
- Keep file scopes disjoint where you can: two slices that touch the same files are serialized by `/issue-runner` exactly like a `Blocked by` edge (conflict edges from `Files likely touched:`, Step 4).

Present the breakdown as a numbered list — title, blocked-by, one-line scope — and ask: granularity right? dependencies right? merge or split anything? Iterate until the user approves.

## 4. Publish

**Tracking issue first.** Before any slice, `gh issue create` one tracking issue titled `Plan: <short name>` — the durable home of the planning work, which otherwise disappears at publish time. Its body:

```markdown
## Input

The original input, verbatim: the inline idea or plan text; for a file, its path followed by its contents; for an issue, `#N` followed by its body.

## Decisions

- **Q:** Question asked in Step 2. **A:** Answer chosen. *(recommended: the planner's answer, only when it differed)*

(or "No interview needed - input was clear.")

## Slices

(filled in after the slices are published)
```

Never put a `## What to build` section in it: `## Slices` without `## What to build` is how `/issue-runner` Step 1 recognizes a tracking issue and keeps it out of scope — it is never implemented. After the slices are published, `gh issue edit <tracking> --body-file` the same body with `## Slices` filled in from the real numbers, one line per slice in dependency order: `- #N — title (blocked by #M)` or `- #N — title`.

**Then the slices**, in dependency order (blockers first, so you can reference real issue numbers). One `gh issue create` per slice with this body — it is the contract with `/issue-runner` (`## Blocked by` is its primary DAG source) and with `gh-issue` (the checklist is the implementer's definition of done):

```markdown
Part of #<tracking>

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

`Part of #<tracking>` is **mandatory** and always the **first** line of the body, on a line of its own, outside every contract section: `/issue-runner` and `gh-issue` parse the `##` sections and the last line exactly as before, and it is not a `## Blocked by` bullet, so it never becomes a dependency edge. `/issue-runner` Step 5 reads it to find the tracking issue and posts the run summary there when every issue in its scope names the same one; the `gh-issue` implementer follows it like any other issue reference and finds the decision log behind its spec.

`Files likely touched:` is **mandatory** and always the last line of the body: the repo-relative paths this slice edits or creates, comma-separated, from your Step 1 exploration; a directory scope ends with `/` (`src/api/`); no globs — a pattern is matched literally and never intersects anything. `/issue-runner` Step 2 intersects these lines pairwise to derive conflict edges deterministically — two slices naming the same path, or one naming a directory that contains the other's path, are serialized. The line's cost model is asymmetric: any in-scope issue **without** it sends the whole run through the LLM refinement pass, while a path **omitted** from it lets two implementers merge over each other — so list every path the slice will touch. `gh-issue` Step 2 also seeds the implementer's codebase exploration with it.

`## Interfaces` is **optional**: include it only when slices share a contract — function signatures, schemas, endpoints, or file boundaries agreed between slices. `/issue-runner` reads nothing from its bullets; they exist for the implementer, which seeds its codebase exploration with them (gh-issue Step 2). When the section is absent, `Files likely touched:` follows `## Blocked by` directly.

## 5. Hand off

Show the tracking issue and the published slice numbers, and offer to run `/issue-runner` on the slices right away (all, or the subset the user picks). The run's summary and telemetry land on the tracking issue as a comment (issue-runner Step 5), so the plan and its outcome stay together.
