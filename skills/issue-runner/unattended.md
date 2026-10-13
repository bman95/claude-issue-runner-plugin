# Asking less: batched questions and `--unattended`

Read at Step 0 of every run that will ask anything (SKILL.md, Arguments). Two rules: questions are asked together, before the run starts working; and under `--unattended` nothing is asked once the run is launched. Rationale: [REFERENCE.md](REFERENCE.md).

## Contents

- Batching
- `--unattended`
- The answer table
- The decision log

## Batching

Without `--unattended`, still ask as few times as possible, and as early as possible:

- **Step 1** — the parked-labels question, the `--limit 50` truncation question and the dirty-tree audit go out in **one** `AskUserQuestion` call (one question each; omit those that do not apply).
- **Step 2** — every out-of-scope edge and every external edge known at that point goes out in one call per round (at most four questions per call; more → back-to-back calls with nothing in between). A round's answers can create new questions (a drop leaves a dependent with a new out-of-scope edge): ask those in the next round, never one at a time.
- **Steps 3–4** — what the run owes the user while implementers work (risk blockers, the retry cap, merged-but-open, `contract-first:`) is asked when it arises, as today, but owed questions are folded into one call whenever two are pending at once.

Each question keeps its own options and its recommended answer first; batching changes when it is asked, never what it offers.

## `--unattended`

The user authorizes, at launch, every answer marked *recommended* in this skill, plus the specific answers in the table below. From the State `init` on, never call `AskUserQuestion`: an issue that would need a person is **parked**, never the run (why: Why `--unattended` parks the issue, not the run). Parked means: the issue is left `blocked` (worktree kept) or marked as the table says, a `decision` item is appended to its `$STATE_DIR/issue-N/human-only.md` (gh-issue human-only.md's block, `why: decision`, `do:` the options with the recommended one first, `context:` the blocker), and the rest of the DAG goes on. Step 5 files those items (summary-report.md, "Human-only items"). Push notifications (notify.md) tell the user what was parked.

Refusals, before the lock: `--unattended` with `--plan`, `--status` or `--flush` (`--unattended has no effect with <flag>`). `--unattended` never authorizes what only an explicit flag or answer can: a gate waiver, the prose profile, a hook bypass, inline review, retries past `--max-retries`, a model or reviewer choice, merging despite open findings.

## The answer table

| Where | Question | Answer under `--unattended` |
|---|---|---|
| Step 0, preflights.md | Codex missing or model unlisted | abort (the run never starts; the message says why) |
| Step 0, preflights.md | Agent tool unavailable | abort |
| Step 1, open-issues.md | parked issues | skip parked |
| Step 1, open-issues.md | list truncated at 50 | proceed with the 50 listed; the decision log says so |
| Step 1 | dirty tree | proceed as is: never stash, commit or discard the user's work; the Step 5 clean check compares against the snapshot as usual |
| Step 2, dag.md | out-of-scope edge to a tracking issue | override |
| Step 2, dag.md | any other out-of-scope edge | drop-issue (the dependent is not run; never builds on missing work) |
| Step 2, dag.md | external edge | run-elsewhere (its command is printed and reprinted at Step 5) |
| Step 3a | a resume-check case that asks (several PRs, a keyword-only PR, an `ask` branch) | park the issue: `blocked`, `unattended: resume needs a choice — <case>` |
| Step 4 | a risk blocker (escalations.md, Blocker classes) | abort, as recommended |
| Step 4 | retry cap reached | park the issue: mark `failed`, error `unattended: retry cap reached — <blocker>` (the cascade skips its dependents) |
| Step 4 | a blocker that needs a scope, product or risk decision (SKILL.md, Escalate to the user) | park the issue (`blocked`) |
| Step 4 | `PR #P merged but issue still open` | park the issue (`blocked`); never close it |
| Step 4 | `contract-first:` | wait |
| Step 4 | hook-bypass authorization | never authorized: the issue stays `blocked` |
| Step 4 | prose-profile retry | not offered |
| Step 5 | deferred findings | leave them: listed in the summary, nothing filed or fixed |
| Step 5 | human-only items | file them |

A question this table does not name takes its *recommended* answer; one with no recommended answer parks the issue it concerns, or aborts the run when it concerns no single issue.

## The decision log

Every answer `--unattended` gives is appended, one line each, to `$STATE_DIR/unattended.txt` (`<step>: <question> -> <answer> (#N)`); answers given before the State `init` are appended right after it. Step 5 prints the file under `## Unattended decisions`, before the summary table. It is the user's only record of what was decided for them.
