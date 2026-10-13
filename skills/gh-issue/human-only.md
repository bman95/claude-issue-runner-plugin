# gh-issue — human-only steps

Read when the work needs a step no agent can or may do (SKILL.md, Edge cases). Such a step must never be lost in prose, never be worked around, and be quick for a person to act on later, often from a phone. Rationale is in [REFERENCE.md](REFERENCE.md).

## Contents

- What counts
- Recording an item
- Blocker or not
- Production verification

## What counts

A step is human-only when one of these reasons applies. The reason decides who can act:

| `why` | Meaning |
|---|---|
| `host-access` | needs a shell on a host the agent cannot reach |
| `root` | needs `sudo` or an admin account |
| `guard` | a hook, permission rule or policy blocks it by design |
| `credentials` | needs a secret or an interactive login (VNC, SSO, 2FA) |
| `other-repo` | the change belongs to another repository (contract-first.md covers code dependencies) |
| `decision` | a judgement call the issue does not settle |
| `prod-check` | verification only possible in the real environment (below) |

Never work around the reason: no hook bypass (hooks.md), no alternative command that reaches the same effect, no asking a helper subagent to try.

## Recording an item

Orchestrated: append one block per step to `<STATE_DIR>/issue-<N>/human-only.md` (beside `result.json`; create it if absent; never rewrite earlier blocks). Interactive: show the same block to the user and offer to file it as an issue. The block, kept short:

```markdown
### <one-line action, imperative>
why: <one value from the table>
do:
    <exact command(s), one per line, indented four spaces>
verify:
    <one read-only command that shows it worked, indented four spaces>
context: <one line: what needs it and why it could not be done here> (#<N>, PR #<P> if any)
```

Commands go in indented lines, never inline in prose. The file is data for the orchestrator's Step 5, which files it as a `human-only` issue only with the user's authorization (summary-report.md). Never run `gh issue create` for it yourself (why: Why human-only items are filed by the orchestrator).

## Blocker or not

- The PR is complete and correct without the step (an operational follow-up, a cleanup, a prod apply after merge) → record the item and carry on to merge; list it in the PR body under `## Human-only` (one line per item, no commands) and in the Step 10 report.
- The PR cannot be finished or merged correctly until the step is done → record the item, then Block `human-only: <action>`. The orchestrator never retries it (escalations.md).

## Production verification

At Step 10, before reporting `merged`: if an acceptance criterion can only be proved in the real environment, record one `why: prod-check` item whose `do:` lists each check as a numbered line and whose `verify:` names what to observe. Real environment means one of:

- a real device: camera, PWA install, mobile upload, HEIC photos, touch gestures;
- production infrastructure: reverse proxy limits and timeouts, several workers, HTTPS and `Secure` cookies, CORS, production-only environment variables or compose files;
- real data: a migration over the existing database, performance or pagination at real volume;
- an external integration with production credentials (OAuth, payment, storage, a paid API's limits);
- the original failure was only ever seen in production.

Logic, validation, CRUD with tests, UI and refactors are proved locally: record nothing.
