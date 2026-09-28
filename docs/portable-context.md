# Portable context via one environment variable

Carry the whole issue-runner plugin in a single environment variable and install
it into **any** project — a brand-new one, an existing one, local or on Claude
Code on the web — without the marketplace, without cloning, without committing
anything to the target repo.

The plugin's "context" is its three skills (`issue-plan`, `issue-runner`,
`gh-issue`, ~58 KB of Markdown). `scripts/context-env/pack-context.sh` squeezes
that tree into one base64 line (~29 KB) you park in an env var;
`scripts/context-env/bootstrap-context.sh` decodes it into a Claude Code skills
directory so the `/issue-plan`, `/issue-runner`, and `/gh-issue` commands appear.

> **Why an env var and not the marketplace?** The marketplace install is
> per-project and needs network + a `/plugin` step each time. An env var travels
> with your shell and with a Claude Code on the web *environment*, so every
> session in that environment — including new projects — gets the commands with
> zero per-project setup.

## How it works

There is **no** built-in Claude Code variable that turns its own contents into
context — a variable's value only becomes usable if a script reads it. So the
flow is two halves:

1. **pack** — `pack-context.sh` → `base64(gzip(tar))` of `skills/` +
   `plugin.json`. One line, no shell-hostile bytes, fits a shell profile, a
   `.env`, or the cloud environment's variable list. The whole `skills/` tree
   travels, so the scripts the skills run are bundled with them: every
   `skills/<skill>/scripts/*.sh` (issue-runner's `run-state.sh`,
   `scheduler.sh`, `classify.sh` and the recovery fallback `agent-trace.sh`;
   gh-issue's `validation-contract.sh`), and so are the Markdown files a
   `SKILL.md` links one level deep (issue-plan's `templates.md`,
   `reconcile.md`, `continuation.md` and `handoff.md`; issue-runner's
   `merge-ready.md`, `recovery.md`, `escalations.md` and the rest). Nothing outside
   `skills/` is packed — which is why a script a skill runs must live under
   `skills/`.
2. **bootstrap** — `bootstrap-context.sh` reads `$ISSUE_RUNNER_CONTEXT` (or a
   file it points to), decodes it, and writes the skill folders into
   `~/.claude/skills/`. Claude Code discovers `~/.claude/skills/<name>/SKILL.md`
   at startup, so the commands become available. Installing here also satisfies
   `issue-runner` Step 0's own fallback lookup of `gh-issue` at
   `$HOME/.claude/skills/gh-issue/SKILL.md`, so the orchestrator finds its
   implementer without `CLAUDE_PLUGIN_ROOT`.

Because they install as **user-level** skills (not a namespaced plugin), the
commands are `/issue-plan`, `/issue-runner`, `/gh-issue` — unnamespaced. That is
the only behavioral difference from the marketplace install (which namespaces
them as `/issue-runner:issue-plan`, etc.).

## 1. Generate the variable value (once)

From a clone of this repo:

```bash
# Print an `export …` line you can paste or append to a shell profile:
scripts/context-env/pack-context.sh >> ~/.bashrc      # or ~/.zshrc

# …or capture just the value (no `export ` prefix) for a .env / cloud UI:
scripts/context-env/pack-context.sh --raw
```

Re-run whenever you update the plugin and want the new spec everywhere.

## 2. Local machine

Put the `export ISSUE_RUNNER_CONTEXT=…` line in your shell profile (step 1 did
this if you used `>>`). Then install the skills either **once**:

```bash
scripts/context-env/bootstrap-context.sh
```

…or **automatically every session** with a SessionStart hook in
`~/.claude/settings.json` (adjust the path to where you keep the script — or
inline it, see the self-contained variant below):

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          { "type": "command", "command": "bash /ABSOLUTE/PATH/TO/scripts/context-env/bootstrap-context.sh --hook" }
        ]
      }
    ]
  }
}
```

`--hook` makes the script emit the SessionStart JSON with `reloadSkills: true`
(so the just-written commands load without a restart) and stay a clean no-op
when the variable is unset — it never blocks a session.

## 3. Claude Code on the web (the cloud)

The web container is a fresh Ubuntu box (`HOME=/root`); your local
`~/.claude/…` does **not** carry over, but the *environment's* variables and
setup script do. Wire it there:

1. **Environment variable** — in the environment's settings, add the variable
   (`.env` format, one line):

   ```
   ISSUE_RUNNER_CONTEXT=<paste the --raw value from step 1>
   ```

2. **Setup script** — the environment runs this at container start, before
   Claude Code launches, so it is the natural place to materialize the skills
   into the container's `~/.claude/skills/`. Add a **self-contained** bootstrap
   (no repo checkout needed — it only depends on the variable):

   ```bash
   mkdir -p "$HOME/.claude/skills"
   tmp="$(mktemp -d)"
   printf '%s' "$ISSUE_RUNNER_CONTEXT" | base64 -d | tar -xzf - -C "$tmp"
   cp -R "$tmp"/skills/. "$HOME/.claude/skills/"
   rm -rf "$tmp"
   ```

   Every session in that environment — including brand-new projects — then has
   `/issue-plan`, `/issue-runner`, `/gh-issue`.

> If you prefer to keep the setup script trivial, commit
> `scripts/context-env/bootstrap-context.sh` to a repo the environment checks
> out and call it with `--hook` from a `.claude/settings.json` SessionStart hook
> instead. Both reach the same place; the setup-script route needs nothing in
> the repo.

## Variables and flags

| Variable / flag | Default | Meaning |
| --- | --- | --- |
| `ISSUE_RUNNER_CONTEXT` | — | The packed value (what everything reads). |
| `ISSUE_RUNNER_CONTEXT_FILE` | — | Fallback: a file holding the value, if the var is unset. |
| `ISSUE_RUNNER_SKILLS_DIR` / `--dest DIR` | `$HOME/.claude/skills` | Where to install. |
| `ISSUE_RUNNER_CONTEXT_VAR` / `--var NAME` | `ISSUE_RUNNER_CONTEXT` | Use a different variable name. |
| `pack-context.sh --raw` | off | Print the bare value (no `export `). |
| `pack-context.sh --file PATH` | off | Write the bare value to a file. |
| `bootstrap-context.sh --hook` | off | Emit SessionStart JSON (`reloadSkills`), no-op when unset. |

## Verify

```bash
scripts/context-env/bootstrap-context.sh          # prints what it installed
ls ~/.claude/skills                               # -> gh-issue  issue-plan  issue-runner
ls ~/.claude/skills/issue-runner/scripts          # -> agent-trace.sh  classify.sh  run-state.sh  scheduler.sh  test-*.sh
```

To check a pack before installing it, list what it carries:

```bash
scripts/context-env/pack-context.sh --raw 2>/dev/null | base64 -d | tar -tzf - | grep '/scripts/'
```

Then in a Claude Code session, `/issue-plan`, `/issue-runner`, and `/gh-issue`
are available in any project.

## Limitations

- **Trust boundary is unchanged.** The [README security note](../README.md#known-limitations)
  still applies: implementers execute issue bodies as instructions and can merge.
  Only point the runner at repos whose issues you author.
- **Snapshot, not a live link.** The variable is a point-in-time pack. Re-run
  `pack-context.sh` and refresh the variable to pick up plugin updates.
- **Unnamespaced commands.** User-level install means `/issue-runner`, not
  `/issue-runner:issue-runner`. If a project *also* has the marketplace plugin
  installed, prefer one to avoid duplicate command names.
