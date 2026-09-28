# `--prose-gate` at Step 1

Read at Step 1 when `--prose-gate` is passed (SKILL.md, Arguments and Step 1). Rationale: [REFERENCE.md](REFERENCE.md), "Why the prose review profile is user-only and revoke-only".

Refused before the run lock, with these messages: any other shape (`--prose-gate takes a comma-separated list of issue numbers`), a number outside the scope (`--prose-gate #N is not in this run's scope`), use with `--merge-ready` (`--prose-gate has no effect with --merge-ready`), and use with `--no-codex-gate` (`--prose-gate needs the Codex gate: the profile narrows its triage and is not honored without it`).

**`--prose-gate` check** (once scope is settled, before the fast path and before any lock): `case $PROSE_GATE in '') ;; *[!0-9,]*|,*|*,|*,,*|0*|*,0*) echo "--prose-gate takes a comma-separated list of issue numbers" >&2; exit 1;; esac`, then refuse a number outside scope (an excluded tracking issue counts as outside) and any use with `--no-codex-gate` (messages above). A run that goes gateless later keeps the files: after a Step 0 proceed the Step 2 printout adds `(not honored: gate waived)`; after a Step 4 answer only Step 5 shows it (`→ standard`).

Then, unless `--plan` (its Step 2 printout reads `PROSE_GATE` directly), write the `profile` files from `PROSE_GATE` (its list verbatim, already checked):

```bash
for N in ${PROSE_GATE//,/ }; do
  printf '%s\n' 'prose flag' > "$STATE_DIR/issue-$N/profile"
done
```
