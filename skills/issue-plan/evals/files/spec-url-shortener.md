# Fixture: feature spec + codebase map — URL shortener

This is a **dry-run fixture**: there is no real repository, no network, and no
`gh` CLI. Do not dispatch Explore subagents and do not run `gh issue create`.
The codebase map below stands in for the Step 1 exploration you would normally
run. Publishing is simulated: instead of `gh issue create`, write each issue
body to a numbered file as instructed by the task prompt.

## The user's request (passed to /issue-plan)

> Add a URL shortener to our Express API. Users POST a long URL and get back a
> short code; hitting `GET /:code` redirects to the original URL; and we want a
> stats endpoint that shows per-code click counts. Codes should be 7-char
> base62. Anonymous users allowed. No custom aliases for now, no expiry.

The request is deliberately complete — every product decision an implementer
would need is settled above, so no user interview is required.

## Codebase map (stand-in for the Explore pass)

- Express 4 app; routes registered in `src/routes/index.ts`, one file per
  resource under `src/routes/` (e.g. `src/routes/users.ts` — follow its shape).
- Persistence: better-sqlite3 via a thin DAO layer in `src/db.ts`; migrations
  are numbered SQL files in `migrations/` applied at boot.
- Tests: vitest + supertest, one spec per route file under `test/routes/`.
- No existing shortener, redirect, or stats code anywhere.
