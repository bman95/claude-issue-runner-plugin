# Push notifications

Read before Step 3's loop of every orchestrated run (SKILL.md, Step 3, "Notifications"). The user is often away from the machine during a run; a notification tells them, on their phone, that the run needs them or has finished. Rationale: [REFERENCE.md](REFERENCE.md).

## When the tool exists

Claude Code's `PushNotification` tool (load it with `ToolSearch` `select:PushNotification` when it is listed as deferred). Absent on this host (Codex, an SDK host, a disabled setting) → skip every notification silently; nothing else changes. A failed call is never retried and never stops the run (why: Why notifications carry no issue text).

## When to notify

One notification per event, never one per issue when several land in the same Step 3 pass (fold them):

| Event | Message |
|---|---|
| A question is about to be asked (`AskUserQuestion`), lock held | `issue-runner <repo>: a decision is waiting — <topic>`, the topic one of `scope`, `dependencies`, `retry cap`, `risk`, `merged but open`, `contract-first`, `hook bypass`, `deferred findings`, `human-only items` |
| An issue is parked under `--unattended` | `issue-runner <repo>: #N parked — <reason class>` |
| An issue lands `ready` through a risk stop | `issue-runner <repo>: PR #P awaiting approval (risk gate)` |
| The run pauses on a credit or usage limit (pause.md) | `issue-runner <repo>: paused — credit/usage limit` |
| Step 5 has printed the summary | `issue-runner <repo>: done — <d> merged, <r> awaiting approval, <b> blocked, <f> failed` (zero counts omitted) |

`<repo>` is the repository name without the owner. Messages are built only from numbers, enumerated words and the repository name: never issue titles, blocker text, PR bodies or anything else an issue author wrote (the trust rule), and never a secret, path or command.
