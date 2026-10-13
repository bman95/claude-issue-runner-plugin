# Arguments in full

Read when one of these flags is passed (SKILL.md, Arguments, names each in one line and links here). Rationale: [REFERENCE.md](REFERENCE.md).

- `/issue-runner --no-merge` — implementers stop at ready-to-merge (gh-issue Step 9's no-merge stop) and return `ready: PR #<P>` for a human to merge; the issue lands `ready`, terminal for the run, worktree and branch kept; dependents wait (Step 3 item 6). Forwarded only via the dispatch prompt (Step 3a).
- `/issue-runner --unattended` — never ask once launched: the recommended answers apply and an issue that needs a person is parked, never the run. Read [unattended.md](unattended.md) at Step 0 of every run; its batching rules apply without the flag too.
- `/issue-runner --prose-gate N,…` — authorize gh-issue's prose review profile (gh-issue Step 8, "Review profile") for these in-scope issues (`--prose-gate 43,45`); Step 1 checks it and writes the `profile` files per [prose-gate.md](prose-gate.md). Refusals: prose-gate.md.
- `/issue-runner --merge-ready` — merge every `ready` PR a prior run left (`--no-merge`, or a risk stop) whose dependencies are `done` and whose checks are green on its current head (re-checked immediately before merging), then continue that run. No issue numbers; needs that run's kept state. When passed, read [merge-ready.md](merge-ready.md) before Step 1: it holds Step 1's `--merge-ready` mode and Step 3's merge pass.
