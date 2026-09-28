# Step 2 — out-of-scope edges, conflict edges and the plan printout

Read at Step 2 of every orchestrated run and `--plan` (SKILL.md, Step 2), once the `## Blocked by` and heuristic dependency edges are read, and follow it through the plan printout.

## Out-of-scope edges

**Out-of-scope edges are never dropped silently.** For each edge pointing outside `scope.txt`, ask via `AskUserQuestion`: **extend** (append the prerequisite to `scope.txt` and save its `details.json` as in Step 1), **drop-issue** (remove the dependent), or **override** (satisfied externally; record in `$STATE_DIR/overrides.txt`). Touch the lock heartbeat once the question returns (State section). First fetch the prerequisite's body (`gh issue view "$X" --json body -q .body`) and apply Step 1's test: a tracking issue is never extended — print the `Excluded #P` line and offer only **override** *(recommended)* or **drop-issue**.

## Conflict edges

Two in-scope issues that touch the same files must not run in parallel. Take them from the first source that covers the scope (why: Why conflict edges serialize along one total order):

- **Deterministic — `Files likely touched:` intersection**, when **every** in-scope issue carries the line: the **last** body line in `details.json` that **begins with** `Files likely touched:`. Parse it: split on commas, trim whitespace and surrounding backticks, strip a leading `./`, drop empty elements. No paths after the colon, or only `none` (case-insensitive), counts as **lacking** the line. Check every pair: they conflict on a shared exact path, or when a directory scope in one (ending with `/`) prefixes a path in the other. Run no LLM pass (neither `conflict` nor `depends`), with or without `--no-llm-refine`; the printout says so. The reason lists the overlapping paths (both paths of a prefix match): `"reason":"files: a.ts, b.ts"`.
- **Fallback — LLM refinement** (skip if `--no-llm-refine`), only when some in-scope issue lacks the line: dispatch one `Plan` subagent with all issue bodies; it returns one JSON edge per line, `{"kind":"depends","from":X,"on":Y,"reason":"…"}` or `{"kind":"conflict","a":X,"b":Y,"reason":"…"}` — ask for `conflict` edges only when every in-scope issue has a `## Blocked by` section. Log unparseable or out-of-scope lines to `$STATE_DIR/refinement-rejects.txt` and continue; never fail the run on bad refinement output. Merge accepted `depends` edges into the DAG before serializing.

**Serializing conflicts (both sources).** Fix one total order: a topological order of the dependency DAG so far (`## Blocked by`, heuristic edges, resolved out-of-scope edges, accepted `depends` edges), picking the earliest-in-`scope.txt` ready issue at every step. If no issue is ready while some remain unplaced (a cycle), append them in `scope.txt` order and continue — do not resolve it here (Step 3 item 6 reports it) — and omit conflict edges between two appended issues. Serialize each conflict as a `depends` edge from the later issue to the earlier one in that order. Record every conflict in `$STATE_DIR/conflicts.json`, a JSON array of `{"a":X,"b":Y,"reason":"…"}`.

## Printing the plan

After persisting `dag.json` and `dag.txt` (SKILL.md, Step 2), print:

- one line per issue: number, deps, title, and requested profile — `profile: prose (flag)` or `profile: prose (escalation)` from its `profile` file, else `profile: standard`; suffix `(not honored: gate waived)` in a gateless run (the implementer's guard decides the effective one; Step 5 reports it);
- the conflicts forced into serial order, headed `Conflicts (Files likely touched intersection; LLM refinement skipped)`, `Conflicts (LLM refinement; #X, #Y lack Files likely touched:)`, or `Conflicts: none computed (--no-llm-refine; #X, #Y lack Files likely touched:)`;
- the critical-path length (issues on the longest dependency chain; `n/a` when the walk appended unplaced issues);
- if it appended any, `Cycle (unresolved; Step 3 item 6 will skip): #A, #B`;
- the plan-file check, run from the repository root: print its `plan file: …` lines verbatim. Drift is a warning, never a stop: the DAG above stays the issue bodies' (why: Why the plan file is not authoritative).

  ```bash
  PLAN_FILE_SCRIPT=""
  for c in "${CLAUDE_PLUGIN_ROOT:-/nonexistent}/skills/issue-runner/scripts/plan-file.sh" \
           "$HOME/.claude/skills/issue-runner/scripts/plan-file.sh"; do
    [ -f "$c" ] && PLAN_FILE_SCRIPT="$c" && break
  done
  if [ -z "$PLAN_FILE_SCRIPT" ]; then echo "plan file: not checked (plan-file.sh not found)"
  else bash "$PLAN_FILE_SCRIPT" "$STATE_DIR" || echo "plan file: not checked (exit $?)"; fi
  ```

## Overriding the order

To override the order, the user re-invokes with explicit numbers in the desired order; a bogus `files:` edge is removed by correcting one issue's `Files likely touched:` line, not by `--no-llm-refine`.

Then return to SKILL.md Step 2 for the agent-spend estimate, the plan's closing line.
