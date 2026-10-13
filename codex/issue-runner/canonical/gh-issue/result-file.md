# gh-issue — the result file's keys

Read at "Result file" (SKILL.md), before writing `result.json`: what each key means. The key set and its write recipe stay in SKILL.md (lint-checked). Rationale is in [REFERENCE.md](REFERENCE.md).

- `outcome` — `merged` only after Step 9 verified `MERGED` (`gh pr view --json state`); `ready` only after Step 9 verified its no-merge stop (`Merge mode: no-merge`, or a risk stop) (`gh pr merge` never called); `blocker` — spec ambiguity, a `contract-first:` stop, bouncing loop, cap-stop, failing checks, unavailable gate, unauthorized inline review, an unauthorized hook bypass, a failing, invalid, not-runnable or changed validation (or integration) contract ("Validation contract", Step 9), Step 9's base-freshness conflict or post-merge validation failure; `failed` — environmental: credentials, a hook failing for the environment (hooks.md), the validation script's exit 2 or missing script ("Validation contract"), an irresolvable merge conflict outside Step 9's recipe, Step 6's refused push. A refused Step 4 checkpoint push is only `checkpoint: refused`.
- `pr` — `null` before Step 7. `branch`, `worktree` — `git rev-parse --abbrev-ref HEAD`, `--show-toplevel` (= the `worktree:` line).
- `phase1_iterations` (`0` if never entered; the verification iteration counts, so at most 5 per Phase 1 run, which a prose revocation restarts); `phase1_inline` — `true` if Phase 1 or any reviewer pass ran inline ("Liveness"); `phase1_state` — `converged` (the verification iteration included), `cap-stop` (the verification iteration after the capped iteration's fixes still found Apply-class findings), `bouncing`; `null` if never entered.
- `gate_passes` (0–`MAX_CODEX_ITERATIONS`); `gate_state` — `clean`; `degraded` (credit/quota); `waived` (`--no-codex-gate`); `cap-stop` (pass `MAX_CODEX_ITERATIONS` still had Apply-class findings, or a prose revocation left no pass); `errored` (any other non-zero exit; any on a verification pass; credit/quota on pass 1 under prose; timeout; a pass lost twice); `bouncing`; `unavailable` (CLI or pinned model missing, not waived); `null` if Phase 2 never entered.
- `checks` — `pass`, `none`, `fail`, or after `gh pr ready` on a former draft: `none-after-ready`, `all-skipped`, `unchanged-after-ready` (these merge, never silently); `null` if Step 9's gate never ran.
- `checkpoint` — `created` (by this run, orphan resume included), `refused` (reason in Step 10), `skipped` (Step 4), `n/a` (pre-existing PR, or exit before Step 4).
- `security_lens` — Step 8 lens used. `hook_bypass` — `none`, `authorized`, `unauthorized` (hooks.md). `review_profile` — at exit: `standard` (none, or gate waived), `prose`, `revoked` (Step 8 guard); before Step 8, as authorized (`standard` if gate waived). `gate_model` — the slug the gate passes ran on (`GATE_MODEL`, "Reviewer choices"); `null` if no pass launched. `reviewers` — Phase 1's reviewers per iteration (`REVIEWERS`, default 2).
- `deferred` — every Surface and Defer finding (Step 8; prose design alternatives excluded), one `{"finding","reason"}` entry each, `[]` if none. Never leave them only in PR prose.
- `blocker` — your final message's blocker/failure text verbatim; `null` when `merged`.

## Attempt note on the issue

Orchestrated, when `outcome` is `blocker` or `failed`: after writing `result.json`, leave one comment on the issue so the next attempt, or a person reading it from a phone, starts from where you stopped instead of from the transcript (why: Why a stopped attempt comments on the issue). Write the body with the Write tool to a private path (`<STATE_DIR>/issue-<N>/attempt-note.md`, never a fixed `/tmp` name), then `gh issue comment <N> --body-file "<that path>"`; a failed comment is reported in Step 10, never retried another way. K is the number of `## Retry K` sections in `guidance.md` plus one. The body, short:

```markdown
**issue-runner attempt K: blocked | failed** — <the blocker, one line>

- **Tried:** <one to three bullets>
- **Stopped at:** <the gh-issue step and what was happening>
- **Missing:** <what has to happen before this can finish>
- **Files touched:** <`git diff --name-only` against the base, or "none">
- **PR:** #<P> (draft) | none
```

Never put secrets, `environment.md` content, hook output or commands from a human-only item in it (those live in `human-only.md`).
