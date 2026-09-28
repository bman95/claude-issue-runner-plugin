# Issue body templates

Step 5 of [SKILL.md](SKILL.md) publishes one tracking issue and one issue per slice in these formats. They are the contract with `/issue-runner` and `gh-issue`: `skills/issue-runner/scripts/plan-file.sh` parses the plan-file block, and the runner parses the slice bodies. Spell every heading and line exactly as shown.

## Contents

- Tracking issue body
- The plan file
- Slice issue body

## Tracking issue body

The tracking issue is titled `Plan: <short name>`. Its body:

```markdown
## Input

> The original input, quoted verbatim — every line prefixed with `> `: the inline idea or plan text; for a file, its path, then its contents; for an issue, `#N` and its title, then its body.

## Decisions

- **Q:** Question asked in Step 3. **A:** Answer chosen. *(recommended: the planner's answer, only when it differed)*

(or "No interview needed - input was clear.")

## Existing work

- #N — `title`: `depends` — one-line reason
- docs/<file> (entry): `conflict` — resolved under Decisions

Scanned N open issues, M open PRs, K recent merges, D documents.

(or "No existing work found - scanned N open issues, M open PRs, K recent merges, D documents.")

## Slices

- (unpublished) Slice title (blocked by: other slice title)

## Plan file

(the issue-runner-plan block: see "The plan file" below)
```

Never put a `## What to build` section in it: a line that, trimmed of trailing whitespace, is `## Slices` and no such line that is `## What to build` is how `/issue-runner` Step 1 recognizes a tracking issue and keeps it out of scope — it is never implemented.

The `> ` quoting under `## Input` is what keeps that true: an input that is itself an issue or plan in this format carries `## What to build`, `## Blocked by` and `Files likely touched:` lines, and quoted they can never read as this issue's own. `## Existing work` keeps it true by referencing only — issue numbers, titles, document paths and one-line reasons, never a quoted body.

`## Slices` is written at create time from the approved Step 4 breakdown, one `- (unpublished) title (blocked by: title)` line per slice in dependency order, so the list's size is known before the create and a partial publish describes itself.

A GitHub issue body holds 65,536 characters: quote the input up to what fits after `## Decisions`, `## Existing work`, the full slice list and the plan file at its final size (one entry per slice: its `Files likely touched:` paths plus about 60 characters), and end a cut quote with `> (input truncated; full text at <path>, or in the conversation for inline text)`.

## The plan file

`## Plan file` is the body's last section: directly under the heading, one fenced block with the info string `issue-runner-plan` holding one line of versioned JSON, written at create time as `{"version":1,"issues":[]}`:

````text
```issue-runner-plan
{"version":1,"issues":[{"n":123,"blocked_by":[122],"files":["src/a.ts","src/api/"]}]}
```
````

Each published slice has one entry, in publish order: `n` is its issue number; `blocked_by` the numbers its `## Blocked by` bullets name, existing issues included (`[]` for `None - can start immediately`); `files` the paths of its `Files likely touched:` line, trimmed of whitespace and backticks. An `(unpublished)` slice has no number and no entry, so the file fills in with real numbers exactly as `## Slices` does.

It is **not authoritative**: `/issue-runner` builds its DAG from the slice bodies and only compares the file with them (its Step 2), printing each difference (a slice edited by hand after planning, a dependency added or removed, a file list changed) as a warning. So never edit a slice body to match the file, or the file to match a hand edit.

The section adds no `## Slices` or `## What to build` heading and no `Part of #P` line, so the tracking issue still passes the runner's tracking-issue test and never reads as a slice. The runner reads only the block directly under this body's own `## Plan file` heading, so a plan quoted under `## Input` (its lines `> `-prefixed) is never taken for this one.

## Slice issue body

One `gh issue create` per slice with this body — it is the contract with `/issue-runner` (`## Blocked by` is its primary DAG source) and with `gh-issue` (the checklist is the implementer's definition of done):

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

`Part of #<tracking>` is **mandatory** and always the **first** line of the body, on a line of its own with nothing else on it (`/issue-runner` matches the trimmed line against `^Part of #[0-9]+$` and expects exactly one such line), outside every contract section: `/issue-runner` and `gh-issue` parse the `##` sections and the last line exactly as before, and it is not a `## Blocked by` bullet, so it never becomes a dependency edge. `/issue-runner` Step 5 reads it to find the tracking issue and posts the run summary there when every issue in its scope names the same one; the `gh-issue` implementer follows it like any other issue reference and finds the decision log behind its spec.

`## Blocked by` names slices of this plan and, from Step 2's `depends` outcomes, existing issues outside it — the same bullet form for both; the runner treats every `#N` bullet as an edge, so a bullet is always an issue an implementer can finish: never a PR number, never an earlier plan's tracking issue (name the slice that provides the dependency instead). A slice that extends or supersedes existing work says which (`Extends #N: …`, `Supersedes #N: …`) in `## What to build`, so the implementer reads the existing issue before the spec.

`Files likely touched:` is **mandatory** and always the last line of the body: the repo-relative paths this slice edits or creates, comma-separated, from your Step 1 exploration; a directory scope ends with `/` (`src/api/`); no globs — a pattern is matched literally and never intersects anything. `/issue-runner` Step 2 intersects these lines pairwise to derive conflict edges deterministically — two slices naming the same path, or one naming a directory that contains the other's path, are serialized. The line's cost model is asymmetric: any in-scope issue **without** it sends the whole run through the LLM refinement pass, while a path **omitted** from it lets two implementers merge over each other — so list every path the slice will touch. `gh-issue` Step 2 also seeds the implementer's codebase exploration with it.

`## Interfaces` is **optional**: include it only when slices share a contract — function signatures, schemas, endpoints, or file boundaries agreed between slices, or provided by existing work a slice depends on (`— provided by #N (existing), consumed here`, from Step 2). `/issue-runner` reads nothing from its bullets; they exist for the implementer, which seeds its codebase exploration with them (gh-issue Step 2). When the section is absent, `Files likely touched:` follows `## Blocked by` directly.
