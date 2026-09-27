# issue-runner smoke fixture

A throwaway project that issue-runner's `scripts/smoke/setup.sh` pushes to a private repository; `scripts/smoke/teardown.sh` deletes it.

- `greet.sh` — a tiny bash library.
- `test.sh` — runs every `tests/test-*.sh`. It is the project's validation (`.issue-runner/validation`) and needs nothing beyond bash.
