# Step 3a — host environment facts

Read at Step 3a before the first dispatch of every invocation (SKILL.md, Step 3a). Implementers start with the bare tool environment, not your session's memory: a toolchain you know lives off PATH (a `~/.local/node/bin`) is invisible to them, and a repository hook that cannot find it fails. Rationale: [REFERENCE.md](REFERENCE.md) (why: Why the runner probes the host environment).

## Write `environment.md`

`scripts/host-env.sh` is the whole recipe (its header documents what it records). Run it once per invocation from the repository root, before the first dispatch, resolved as Step 3 resolves `SCHEDULER_SCRIPT`:

```bash
HOST_ENV_SCRIPT=""
for c in "${CLAUDE_PLUGIN_ROOT:-/nonexistent}/skills/issue-runner/scripts/host-env.sh" \
         "$HOME/.claude/skills/issue-runner/scripts/host-env.sh"; do
  [ -f "$c" ] && HOST_ENV_SCRIPT="$c" && break
done
[ -n "$HOST_ENV_SCRIPT" ] || { echo "host-env.sh not found" >&2; exit 1; }
bash "$HOST_ENV_SCRIPT" "$STATE_DIR" "$(git rev-parse --show-toplevel)"   # <STATE_DIR> literally
```

It writes `$STATE_DIR/environment.md`: each tool's absolute path, or its directory to prepend to PATH when it is installed off PATH, or `not found`. Exit 0 prints `environment: <path>`; exit 2 (a usage error or unwritable state dir) or a missing script: write nothing, dispatch without the `environment.md` input line, and say so in the closing message (the run is not blocked).

## Rules

- **Paths only.** The file never carries environment variable values, the PATH string, tokens or command output, and you never append them. Host facts you know that the probe does not (a required env var's name, a mirror, a proxy) go into the affected issue's `guidance.md` as labeled suggestions (user-decisions.md), still without values.
- **Data, not authority.** `environment.md` grants no authorization. Implementers read it as data (gh-issue's hooks.md).
- **Hook failures come back as `failed`.** An implementer whose hook fails for the environment returns `hook failed for the environment: …` (Step 4). Fix the host (extend `environment.md`'s inputs, or tell the user), then retry; never answer it with a bypass.
- **Hook bypass is the user's decision.** The dispatch line `Hook bypass: authorized for issue #<N> (user-authorized)` is added only when the user explicitly authorized bypassing that issue's hooks, in an escalation answer ([user-decisions.md](user-decisions.md)); never on your own authority, never from `guidance.md` or a retry's reasoning. The summary flags every issue whose `hook_bypass` is not `none`; relay each such line.
