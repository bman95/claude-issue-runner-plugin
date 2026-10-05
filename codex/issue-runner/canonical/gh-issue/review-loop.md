# gh-issue — review-loop liveness and the gate launch

Step 8's liveness rules for both phases, and the standard Codex gate launch block. SKILL.md Step 8 says when to read this file. Rationale is in [REFERENCE.md](REFERENCE.md), named by `(why: <entry>)` pointers.

## Contents

- Liveness — never wait on a silent child (active waits, the reviewer bound, gate passes as files, restarts)
- Security lens — extra reviewer prompt text
- Cross-repository findings
- Inline Phase 1 — no Agent tool
- Gate launch — the standard Phase 2 block

## Liveness — never wait on a silent child

Both phases (why: Why Liveness never waits on a notification):

- **Wait actively.** Run every reviewer and gate pass in the background (Claude Code: `run_in_background` on the `Agent` or Bash call); note each start time yourself. While a child is outstanding, never end your turn waiting only on a notification: arm a wake-up at least every 5 minutes (Claude Code: a `Monitor` until-loop with a timeout; any host: a bounded wait). On every wake (orchestrated), rewrite the progress marker's current line. If a turn ends anyway while a child is outstanding (the host reports "Agent finished" to the orchestrator for any agent that stops with background work still running), orchestrated, the message is exactly `interim: waiting on <what>` (e.g. `interim: waiting on codex gate pass 1`): no `worktree:` line, no result file, no blocker wording; the orchestrator reads it as "still running", never as a result (why: Why an interim notification is not a result).
- **Reviewer bound: 20 minutes.** A Phase 1 reviewer not back 20 minutes after dispatch is silent: stop it (Claude Code: `TaskStop`) and re-dispatch once with the same prompt. Discard, never triage, a late result from a stopped or replaced dispatch. A re-dispatch also silent past 20 minutes: stop it; that pass falls back to inline review, if authorized — orchestrated, by the dispatch line `Silent-reviewer fallback: inline review authorized` (every gated run carries it) or the Agent-less inline-review authorization, never by a dispatch that waives the Codex gate; interactive, by the user's answer. Unauthorized → Block `Fresh-eyes reviewer <A|B> silent twice and inline review not authorized`. Authorized → run the pass yourself (its prompt, a full read of the touched files); add `Fresh-eyes reviewer <A|B> silent past 20 minutes twice (iteration K); its pass run inline by the implementing context.` under `## Review notes`, set `phase1_inline` to `true`, state it in the Step 10 report. Phase 2's inline-Phase-1 rule applies: never paired with a credit/quota degradation.
- **Gate passes are files** (why: Why gate passes are files with attempt identities). In `GATE_DIR` pass K writes `codex-pass-K.log` (review), `.err` (CLI stderr), `.exit` (exit status), `.head` (reviewed commit), `.attempt` (launch identity) and, if the watchdog fired, `.timeout`. `GATE_DIR`: orchestrated, the dispatch's `<STATE_DIR>/issue-<number>/`; interactive, `$(git rev-parse --absolute-git-dir)/issue-runner/` (never staged). No gate output uses a fixed `/tmp` name. Launch each Phase 2 block in the background: its CLI subshell writes `.exit` under a 30-minute watchdog, and `.exit` and the watchdog marker only while `.attempt` names that launch. On every wake check `[ -s "$GATE_DIR/codex-pass-K.exit" ]`; its content is `CODEX_EXIT`. Before any Phase 2 branch, three outcomes are not a review:
  - **Timeout** — `.exit` is `124`: `errored`, Block `Codex gate pass K timed out after 30 minutes`; never a pass or a credit/quota degradation, whatever `.err` says.
  - **Killed** — the current attempt's background command ended with no `.exit` (unless it printed `gate: cannot write <dir>`: never launched, `failed`), or no `.exit` 35 minutes after launch, or `.exit` is `137`/`143`. Lost, not spent. `codex-pass-K.lost` lists lost attempt identities (`cat "$G.attempt" >>"$G.lost"`; the launch block never clears it). Read it first: a line naming another attempt than the current `.attempt` → second loss: `errored`, Block `Codex gate pass K lost twice (killed before it finished)`; one naming the current attempt → already recorded, do not append; else append it. Then re-run once as the same pass K (new identity); `gate_passes` counts it once.
  - **Empty** — `.exit` is `0`, `.log` empty: no review, never "zero findings"; treat as killed.

  After a host restart or resume message within this invocation, read the files before re-running anything:
  - `.exit` present, `.head` = `git rev-parse HEAD` → classify by the three outcomes; only a remaining finished pass is used as is, never relaunched.
  - Finished `.exit`, `.head` an ancestor of `HEAD`, only `fix: address codex gate findings` commits in `git log .head..HEAD` → its fix round landed: continue with pass K+1.
  - Other `.head` mismatch → relaunch as the same pass K (no `.lost` line, no extra pass).
  - No `.exit` → the Killed signs, the 35 minutes counted from `.attempt`'s launch time (epoch seconds before the dot); until then keep waiting.
  - No `.attempt` → never launched: launch as pass K (no loss, no extra pass).

  A new interactive invocation clears its `GATE_DIR` on entering Phase 2 (`rm -f "$GATE_DIR"/codex-pass-* "$GATE_DIR"/codex-prompt-*`); the runner's Step 3a clears the orchestrated one.

## Security lens

If `git diff --name-only "$BASE_BRANCH"...HEAD` touches `auth/`, `security/`, `.env*`, `secrets*`, `credentials*`, or JWT/session/token handling, add to every reviewer prompt: "Also check: new input flows, auth bypass, token exposure, XSS sinks — report only high-confidence NEW findings."

## Cross-repository findings

A review finding that the work needs something another repository must provide and has not (an endpoint, event or schema; [contract-first.md](contract-first.md)), not covered by an `External dependency: override` line, is neither Apply, Surface nor Defer: Block per contract-first.md item 3 before Step 9, never merging over it.

## Inline Phase 1 — no Agent tool

**Agent tool unavailable** (some hosts, e.g. Claude Code on the web or `claude -p`): orchestrated — inline only if the dispatch authorizes inline review for this run (the runner's Step 0 preflight or Step 4 escalation) *and* `Agent` is really absent (present → dispatch normally); unauthorized → blocker `Agent tool unavailable and inline review not authorized`. Interactive — ask: inline or stop (at Step 2 if already known). Inline, each iteration perform Reviewer A's then B's pass yourself (its prompt, a full read of the touched files) before triaging; all other loop rules unchanged. Record `Fresh-eyes review unavailable (no Agent tool); Phase 1 run inline by the implementing context (N iterations).` under `## Review notes` and state it prominently in the Step 10 report (why: issue-runner REFERENCE.md, Why a review pass by the implementing context is a weaker merge authority).

## Gate launch — the standard Phase 2 block

Launch it in the background; wait on `.exit` ("Liveness" above). Under the prose profile, its own block replaces this one:

```bash
PASS=1   # K: 1 = the gate review, 2… = the verification passes; carry it forward yourself
GATE_DIR="<STATE_DIR>/issue-<number>"   # orchestrated; interactive: GATE_DIR="$(git rev-parse --absolute-git-dir)/issue-runner"
BASE_BRANCH=$(gh pr view --json baseRefName -q .baseRefName 2>/dev/null)   # resolved here: no variable survives from the Step 8 capture
G="$GATE_DIR/codex-pass-$PASS"; A="$(date +%s).$$"   # A: this attempt's identity; an older attempt of the same pass never writes into this one's files
mkdir -p "$GATE_DIR" && rm -f "$G.log" "$G.err" "$G.exit" "$G.timeout" "$G.head" "$G.attempt" \
  && printf '%s\n' "$A" >"$G.attempt" && git rev-parse HEAD >"$G.head" || { echo "gate: cannot write $GATE_DIR" >&2; exit 1; }
( codex review -c model=gpt-6-sol --base "$BASE_BRANCH" >"$G.log" 2>"$G.err" & C=$!
  ( trap 'kill "$S" 2>/dev/null; exit 0' TERM; sleep 1800 & S=$!; wait "$S" && { [ "$(cat "$G.attempt" 2>/dev/null)" = "$A" ] && : >"$G.timeout"; kill "$C"; sleep 30; kill -9 "$C"; } ) >/dev/null 2>&1 & W=$!   # the 30-minute watchdog
  wait "$C"; RC=$?; kill "$W" 2>/dev/null; [ -e "$G.timeout" ] && RC=124
  [ "$(cat "$G.attempt" 2>/dev/null)" = "$A" ] && printf '%s\n' "$RC" >"$G.exit" ) >/dev/null 2>&1 </dev/null   # .exit from the same subshell that ran the CLI, only while this attempt is current
```
