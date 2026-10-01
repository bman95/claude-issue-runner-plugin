# Research: warpdotdev-demos/cloud-factory-demo

*Snapshot 2026-10-01, against issue-runner 0.14.0. Source: https://github.com/warpdotdev-demos/cloud-factory-demo (default branch, shallow clone). This is input for `/issue-plan` and `docs/design-notes.md`, not a plan: nothing here is scheduled.*

## What it is

Warp's reference "cloud software factory": agent skills under `.agents/skills/` plus GitHub Actions workflows that move an issue from intake to a reviewed PR, running each stage as an Oz cloud agent (`warpdotdev/oz-agent-action`). About 6,000 lines: seven skills, six Python helper scripts, five workflows (duplicated under `templates/` for an installer), a `vision.md` and a `roadmap.md` for a toy product.

Pipeline (each arrow is a GitHub event or a label):

```
issue opened → triage (read-only agent → JSON) → apply job sets 1 of 4 labels
  "Ready to spec"      → spec agent → PRODUCT.md + TECH.md → specs PR → human review
  "Ready to implement" → implementation agent → validate vs specs → verify-behavior → PR
PR opened/synced → review agent (trusted checkout) → review.json → publish job → GitHub review
daily cron → improve-review-pr: human reactions to bot comments → PR editing review-pr skill
```

Humans merge everything; no stage holds merge authority.

## Where the two projects differ in philosophy

| Axis | cloud-factory-demo | issue-runner |
|---|---|---|
| Intake | External issues; triage decides readiness | Issues born in `/issue-plan`; agent-ready by construction (REFERENCE.md "Why there is no triage stage") |
| Runtime | Event-driven Actions, one cloud agent per stage | One local/web session orchestrating subagents |
| Merge | Never; humans merge | Implementer merges after convergence (`--no-merge` opt-out) |
| Review | One agent, structured `review.json`, inline GitHub comments | Two fresh-eyes reviewers + Codex gate, findings as text, history in `## Review notes` |
| Evidence | Video/screenshots via computer-use subagents | Exit codes of a validation contract + CI checks gate |
| Rigor | Prose skills, few tests, heuristics | 28-check lint, fixture-tested scripts, 72 golden scenarios |

So most of the demo is *not* worth copying wholesale: its triage stage solves a problem our planner removes, and its orchestration is far less hardened than ours (see "What not to copy"). The value is in five specific mechanisms.

## Ideas worth adopting, ranked

### 1. Split "agent reads untrusted text" from "agent holds write power" (high value)

**What they do.** `triage-issues.yml` runs the agent with `contents: read, issues: read`; it may only *print* a JSON object (`state`, `label`, `remove_labels`, `comment`). A second job with `issues: write` and no LLM extracts the last matching JSON object and applies it to the triggering issue only. The review workflow does the same: the agent job has `pull-requests: read`, checks out the **trusted base revision** (never the PR head), gets the PR as files it is told are untrusted (`pr_diff.txt`, `pr_description.txt`, `spec_context.md`, `followup_context.txt`), and writes `review.json`; a separate `publish` job validates and posts.

**Why it matters to us.** Our README's "Trust the issue authors" limitation is exactly the hole this closes: an implementer that reads the issue body also holds `gh pr merge`. We already have the analogue in one place: `classify.sh` decides status from git/GitHub proof, never from `result.json`.

**Where it could land.**
- Design note 9 (research issues): the research agent emits the report as a file; a deterministic step posts it with the `<!-- issue-runner:report -->` marker and closes the issue. "Read-only is a promise, not a sandbox" becomes partly mechanical.
- Merge: the implementer could stop at `ready` and let the *orchestrator* (which never reads issue bodies as instructions) run `merge-ready.sh`'s head-pinned merge. That is close to `--no-merge` + `--merge-ready` today; the idea is to make it the default path for untrusted queues instead of a manual two-step.

### 2. Machine-checkable review output (high value)

**What they do.** The review agent must write `review.json` (`verdict`, `body`, `comments[{path,line,side,start_line?,body}]`), and `validate_review_json.py` rejects it unless:
- every comment's `path/line/side` exists in an annotated diff (`annotate_diff.py` rewrites the unified diff as `[OLD:n]`, `[NEW:n]`, `[OLD:n,NEW:m]` lines, so the model copies coordinates instead of counting);
- each comment starts with one of four severity prefixes (`🚨 [CRITICAL]`, `⚠️ [IMPORTANT]`, `💡 [SUGGESTION]`, `🧹 [NIT]`), nits only with a suggestion block;
- suggestion blocks do not duplicate the context line just above/below their range; ranges ≤ 10 lines; ≤ 50 comments.

The agent re-runs the validator until it passes.

**Why it matters to us.** Our Phase 1 reviewers return free text "file:line + recommendation"; dedup is `file:line + claim` by the LLM, and "bouncing" (a finding re-appearing after a fix) is detected by the LLM reading prose. A small JSON contract for reviewer output — `{id, path, line, severity, class, claim}` validated against the touched-file list — would let a script do the dedup, the cross-iteration tracking and the bouncing test, in line with design note 1's "deterministic transitions in scripts, judgement in prose". `annotate_diff.py` is 110 lines and portable; a bash/awk port fits lint's dependency contract.

**Not needed:** posting inline GitHub comments. Our reviewers' audience is the implementer, not a human; the PR body remains the record.

### 3. Follow-up reviews scoped to the delta, with prior findings as context (medium–high)

**What they do.** `build_review_context.py` finds the latest review *signed by this workflow and authored by the trusted bot login* (signature string + `github-actions[bot]`), takes its `commit_id`, fetches `compare/<that>...<head>`, and gives the agent: earlier review bodies, each inline thread with replies, and the annotated delta. The skill says: decide whether each earlier finding was addressed, remains open, or was declined; treat author replies as product decisions unless correctness/security evidence overrides; review the delta for new issues and use the full diff only for context.

**Why it matters to us.** Codex verification passes and Phase 1 iterations ≥ 2 re-review the full `--base` diff. Giving pass K+1 the delta since pass K's `.head` (we already record it) plus pass K's findings and the triage decision for each (Applied / Skip-and-documented with rebuttal) should (a) cut cost, and (b) reduce the "bouncing" retries the 0.14.0 CHANGELOG measured, because a reviewer that sees the rebuttal is less likely to re-raise a skipped finding. Caveat: the Codex CLI refuses a prompt next to `--base` (design note 3), so for Phase 2 this needs the prose block's "prompt names the diff" form.

### 4. A learning loop from human feedback (medium; needs data we don't yet collect)

**What they do.** A daily job (`collect_review_feedback.py`) gathers the bot's review comments of the last 24 h with human replies and reactions, classifies each as validated / corrected / refined / ambiguous, and an agent decides `no_changes | update core skill | update review-pr-local | both`. Rules worth keeping: reject one-off learnings; never touch the output schema, severities or safety rules; repo-specific conventions go to a `-local` companion skill so the core stays portable; open a small PR, never merge it.

**Weakness.** The reply classifier is a keyword list (`"thanks"` → validated, `"wrong"` → corrected), so "thanks, but this is wrong" counts as validated. Copy the shape, not the heuristic.

**Our equivalent.** We have no human feedback on reviews (no inline comments), but we do have rich, structured run outcomes: `result.json`, Step 10 reports, `## Review notes` (Skip-and-document rebuttals, cap-stops, bouncing), blocker strings and retry `guidance.md`. A `/issue-retro` (or a mode of the summary report) could read the last N runs' state and propose — as an `/issue-plan` input, never a direct edit — changes to reviewer prompts or a repo-local `guidance` file. Two ideas transfer directly:
- **core vs. local split:** a per-repo `.issue-runner/review-guidance.md` read from the base tip (like the validation contract, never from the PR), appended to reviewer prompts as data, with lint-pinned rules that it cannot change triage classes;
- **"durable or nothing" rule:** no PR when nothing recurring was found.

### 5. Spec-conformance check before the PR (medium)

**What they do.** Implementation reads `specs/<slug>/PRODUCT.md` and `TECH.md` first, and runs a `validate-changes-match-specs` skill on the final diff; mismatches are fixed or reported as "stale spec, not full alignment" — never claimed as aligned.

**Our equivalent.** The issue body *is* the spec, and gh-issue Step 5 says the acceptance checklist is the definition of done, but only the implementer checks it. A cheap addition: Reviewer B's prompt gets the issue's `## Acceptance criteria` and must report each item as met / not met / not verifiable with a file:line, and an unmet item is Apply-class. The prose profile already has "violated acceptance criterion" as class 4; this extends it to `standard`.

PRODUCT/TECH documents as separate files are not needed: `/issue-plan`'s tracking issue (`## Decisions`, `## Existing work`) plays that role and stays reconciled.

## Smaller ideas

- **Stale-review refusal.** The publish job re-reads the PR and refuses if base or head SHA moved since review. We already pin the merge with `--match-head-commit`; the same check could guard the PR-body refresh after a review round (a human push between review and refresh currently gets a body describing commits it did not see).
- **Signed bot output.** Prior reviews count only if they carry a signature *and* come from the trusted login. Our tracking-issue summary and the proposed research report marker should check the author too, not just the marker text (design note 9 decision 4 already says "by the run's account" — keep it).
- **Evidence status vocabulary.** verify-behavior reports `confirmed | partially confirmed | not reproduced | blocked` and `verified | partially verified | not verified | blocked`, and forbids claiming verification without evidence or an explicit blocker. Our `validation:` line could adopt the same "explicit blocker beats silence" phrasing for acceptance criteria that cannot be checked by the contract.
- **Behavioral verification as an optional contract line.** We have no UI evidence at all. Rather than computer use, a natural fit is an optional `verify:` line in `.issue-runner/validation` (e.g. a Playwright smoke command) run at Step 9 on UI-touching diffs, exit status only. Low priority until a target repo needs it.
- **Product-direction docs for scope decisions.** Triage reads `vision.md` / `roadmap.md` to say "fits but needs a spec" vs. "doesn't fit, wait". `/issue-plan`'s reconcile step could read such files when a target repo has them, as design records, with a `conflict` outcome for out-of-vision input.
- **Guided setup skill.** `oz-cloud-factory-demo` inventories the target (clean / partial / current / customized), diffs before overwriting, and stops at each billable checkpoint. That is the shape design note 6 (bootstrapping the validation contract) needs: a `/issue-runner --setup` that inventories `.issue-runner/validation`, `integration`, labels and the Codex CLI, and proposes rather than writes.
- **Skill evals.** `triage/evals/evals.json` (prompt + expected behavior) is thin, but it is the format Anthropic's skill-creator understands. Some `docs/scenarios.md` rows could be exported to it for model-driven regression runs.

## What not to copy

- **Label chaining under `GITHUB_TOKEN`.** Labels applied by the triage job do not trigger the `issues.labeled` spec/implement workflows (GitHub suppresses events from `GITHUB_TOKEN`); their own setup skill documents the workaround as "remove and re-add the label by hand". Our in-session DAG has no such gap.
- **Matching label names by hard-coded variants** (`'Ready to implement' || 'ready-to-implement' || 'ready to implement'`). Our case/separator-insensitive parked-label match is better.
- **Scraping the decision out of free agent text.** Both extract steps scan the agent's whole output for the *last* JSON object with the expected keys (falling back to the last object of any shape, which later field checks then reject). A quoted or injected object later in the transcript wins. If we adopt idea 1, the agent writes one file and the deterministic step reads only that file.
- **Polling with `sleep 60` to "let pushes settle"** and a 1-hour poll loop on run state. Our file-based liveness (`.attempt` identities, watchdogs) is more robust.
- **Implementation agent with `contents/issues/pull-requests: write` reading the issue directly.** Their own trust split stops at triage and review; implementation has the same exposure we document.
- **Keyword sentiment classification** (see idea 4).

## Suggested next steps

1. Design note: "Structured reviewer findings" (idea 2 + 3): JSON finding schema, annotated-diff helper, script-side dedup and bouncing detection, delta-scoped follow-up passes. Best ratio of value to risk; touches gh-issue Step 8 and `review-loop.md` only.
2. Fold idea 1 into design note 9 (report posted by a deterministic step) and into the README limitation as the long-term answer to untrusted queues.
3. Reviewer B acceptance-criteria check (idea 5): one prompt change plus a `docs/scenarios.md` row; candidate for the next patch release.
4. Defer the learning loop (idea 4) until runs record enough structured outcomes; start by making the Step 10 report machine-readable enough to aggregate.
