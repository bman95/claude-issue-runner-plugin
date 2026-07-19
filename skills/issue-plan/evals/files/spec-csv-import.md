# Fixture: feature spec with a shared contract — CSV contact import

This is a **dry-run fixture**: there is no real repository, no network, and no
`gh` CLI. Do not dispatch Explore subagents and do not run `gh issue create`.
Publishing is simulated: instead of `gh issue create`, write each issue body to
a numbered file as instructed by the task prompt.

## The user's request (passed to /issue-plan)

> Let users import contacts from a CSV file. Three pieces: a reusable parser
> that validates rows (name, email required; email format checked) and reports
> per-row errors; an upload endpoint `POST /api/contacts/import` that streams
> the file through the parser and inserts valid rows; and a summary response
> the web client renders (imported count, list of rejected rows with reasons).
> Rejected rows never abort the import. Max file size 5 MB.

The request is deliberately complete — no user interview is required.

## Codebase map (stand-in for the Explore pass)

- Express 4 + TypeScript; routes under `src/routes/`, one file per resource.
- Contacts already exist: `src/models/contact.ts` with `insertContact(c:
  Contact): number` and unique-email constraint handling.
- Shared pure helpers live in `src/lib/` (e.g. `src/lib/slug.ts`), each with a
  vitest spec beside it in `test/lib/`.
- File uploads elsewhere in the app use `multer` memory storage with a size
  limit option.

Note: the parser and the endpoint are separately demoable (the parser via its
unit tests on fixture CSVs; the endpoint end-to-end), and the endpoint slice
consumes the parser's function signature — a genuine cross-slice contract.
