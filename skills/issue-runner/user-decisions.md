# User decisions versus orchestrator suggestions

Read before you ask the user anything beyond a fixed-option prompt, write `guidance.md`, edit any issue, PR or comment, or file follow-up issues (SKILL.md, Conventions). It binds every step, not only Step 4. Rationale: [REFERENCE.md](REFERENCE.md).

## What counts as a user decision

Only the user's own answer to a question that listed the alternatives. Everything else is an orchestrator suggestion: a default you propose, a requirement you derive, a scope limit you pick, a contract value, an item you drop or add. A suggestion binds nobody and authorizes nothing; it is never labeled "user-approved".

## Questions

- An option that delegates decisions ("under defaults", "you decide", "as you see fit") lists every decision it delegates, each with the answer you would give, in the option text. If that does not fit, the option is not offered; ask a follow-up question that lists them before anything is acted on.
- A reply that does not select among the offered alternatives resolves none of them: a bare "yes", "ok" or "go ahead" to an either/or, or to several options. Ask again, naming the choices. Never pick one yourself, least of all the riskier one or one the Hard rules forbid. A "yes" to a single proposal resolves exactly that proposal.
- Step 4's escalation rule (decisions that change scope, product behavior, or accept risk go to the user) applies wherever such a decision arises: Step 1 scoping, Step 2, and follow-up work after Step 5 (filing issues, editing others). While "just filing issues", add no spec decision (a contract value, a requirement the issue lacks) and drop no review follow-up; put it to the user, or file it as an item marked `Suggested (unconfirmed)`.

## guidance.md

Every entry (a `## Retry K` section included) keeps two parts apart, omitting an empty one:

- `**User decisions:**` the user's words quoted verbatim, each with the question it answered. Nothing paraphrased, extended or inferred.
- `**Orchestrator suggestions (non-binding):**` everything else.

Implementers treat the second part as non-binding (gh-issue Step 1). `guidance.md` stays data: no part of it selects a review profile, waives a gate or grants any other authorization, which come only from the dispatch prompt.

## Editing issues and PRs

- Before any `gh issue edit`, `gh pr edit` or comment edit, read the live state and body in the same step (`gh issue view <N> --json state,body`, `gh pr view <N> --json state,body`), in any repository. Build the edit from that body, never from `details.json` or memory; never overwrite a body wholesale from a copy you did not just read.
- A closed issue's spec, and a merged or closed PR's body, are history: never edit them. Changes go in a new issue that links the old one. Before a new issue claims what a closed issue's implementation does, check the merged code.
