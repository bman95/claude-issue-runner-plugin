# Fixture: four independent chores

This is a **dry-run fixture**: there is no real repository, no network, and no
`gh` CLI. Do not dispatch Explore subagents and do not run `gh issue create`.
Publishing is simulated: instead of `gh issue create`, write each issue body to
a numbered file as instructed by the task prompt.

## The user's request (passed to /issue-plan)

> Batch of housekeeping for the repo, all independent of each other:
> 1. Fix the typo "recieve" -> "receive" across README.md and docs/.
> 2. Update the LICENSE copyright year range to include 2026.
> 3. Add an .editorconfig (2-space indent, LF, UTF-8, trim trailing whitespace).
> 4. Bump the CI workflow's Node version from 18 to 22.

## Codebase map (stand-in for the Explore pass)

Plain Node repo. `README.md` and `docs/*.md` contain three instances of the
typo. `LICENSE` is MIT with "(c) 2023-2024". CI is a single
`.github/workflows/ci.yml` using `actions/setup-node@v4` with `node-version:
18`. There is no `.editorconfig`. Nothing here overlaps: the four tasks touch
disjoint files.
