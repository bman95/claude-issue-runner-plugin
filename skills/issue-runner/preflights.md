# Step 0 — Codex, validation-contract and Agent-tool preflights

Read at Step 0 (SKILL.md) before running any preflight: the Codex preflight in every mode but `--flush`; the validation-contract preflight in every mode but `--plan`, `--status` and `--flush` (the single-issue fast path included); and the Agent-tool preflight, which Step 1 runs once scope ≥ 2 (never on the fast path, `--plan` or `--status`). Rationale: [REFERENCE.md](REFERENCE.md).

## Codex preflight

**Codex preflight** (not `--flush`): `GATE_MODEL` is `--codex-model` (validated, [model-choices.md](model-choices.md)), else `gpt-6-sol`, gh-issue Step 8 Phase 2's pinned model; the check names that model, the one the gate will run. `command -v codex >/dev/null`, then:

```bash
GATE_MODEL="gpt-6-sol"   # or the validated --codex-model slug
codex debug models 2>/dev/null | grep -Eq "\"slug\": *\"$(printf '%s' "$GATE_MODEL" | sed 's/[.]/\\./g')\""
```

Either failing without `--no-codex-gate` → tell the user codex is absent or does not list `<GATE_MODEL>` (upgrade to 0.155 or later, or check `codex login` and network; include `codex --version`) and ask via `AskUserQuestion`: abort *(recommended)* or proceed without the gate (≡ `--no-codex-gate`).

## Validation-contract preflight

**Validation-contract preflight** (skipped by `--plan`, `--status` and `--flush`): learn whether the base branch carries a `.issue-runner/validation` contract (gh-issue "Validation contract"). Resolve `DEFAULT_BRANCH` as Step 5's cleanup does (reference that one-liner, never copy it). `VALIDATION_CONTRACT_SCRIPT` is the copy beside `GH_ISSUE_SKILL`, the one implementers run; pass it literally to any subagent that runs it (the `--merge-ready` refresh). In one tool call:

```bash
VALIDATION_CONTRACT_SCRIPT="$(dirname "<GH_ISSUE_SKILL>")/scripts/validation-contract.sh"   # the resolved absolute path from the block above
case $VALIDATION_CONTRACT_SCRIPT in /*) ;; *) echo "validation: validation-contract.sh not found (not an absolute path: $VALIDATION_CONTRACT_SCRIPT)" >&2; exit 7 ;; esac   # never run a checkout's own scripts/
[ -f "$VALIDATION_CONTRACT_SCRIPT" ] || { echo "validation: validation-contract.sh not found: $VALIDATION_CONTRACT_SCRIPT" >&2; exit 7; }
bash "$VALIDATION_CONTRACT_SCRIPT" check "<default branch>"   # an explicit base: no gh lookup, whatever branch this checkout is on
```

- **0, `contract ok`** → print `validation: contract (.issue-runner/validation on <default branch>)`.
- **0, `fallback (no contract …)`** → print `validation: fallback (no contract — implementers validate by the project's conventions; see README "Validation contract" to declare one)` — a notice, not an error.
- **2** (`cannot resolve the base branch: …`, `cannot resolve the worktree root`) → unresolvable, never "no contract": print the line and stop, whatever the scope.
- **3, `invalid contract (…)`** → print the rule the file breaks; decide at Step 1's fast-path check: scope 1 → continue into gh-issue, which asks; scope ≥ 2 → stop before the dirty-tree audit and state initialization, telling the user to fix the file on the base branch (why: Why validation is declared by the project and read from the base branch, never guessed by the implementer or taken from the PR).
- **7 or any other exit** → stop and report it: never "no contract", never a skipped probe.

It runs on the single-issue fast path too. It never creates or edits the file, and the run never persists a guessed policy (`docs/design-notes.md` note 6).

## Agent-tool preflight

**Agent-tool preflight**: implementers need `Agent` for gh-issue Step 8 Phase 1's fresh-eyes reviewers, and some hosts withhold it from subagents. Run it from Step 1, right after the fast-path check settles scope ≥ 2, before the dirty-tree audit and state initialization; the fast path, `--plan` and `--status` skip it. Probe once with a foreground `general-purpose` subagent (no worktree isolation):

```
subagent_type: general-purpose
description: "Preflight: Agent tool probe"
prompt: |
  Do no work. Check whether a tool named `Agent` is in your own toolset
  (use `ToolSearch` with `select:Agent` if it is deferred). Reply with
  exactly one line — `AGENT-TOOL: yes` or `AGENT-TOOL: no` — and spawn nothing.
```

Anything but a reply whose only non-blank line is `AGENT-TOOL: yes` (no reply, an error, anything else) counts as `no`. `no` → tell the user implementers cannot spawn reviewers here and ask via `AskUserQuestion`: abort *(recommended)* or proceed with inline exploration and review (why: Why a review pass by the implementing context is a weaker merge authority). If the Codex gate is also absent or waived, the question says proceeding merges with no independent review at all. `Agent` missing from *your* toolset → orchestration is impossible: stop and tell the user; issues can still run one at a time via the single-issue fast path, which asks at gh-issue Step 2 whether to review inline.
