#!/usr/bin/env bash
# test.sh — the fixture's whole validation: run every tests/test-*.sh from the
# project root and exit non-zero if any fails. Bash only, no dependencies.
cd "$(dirname "$0")" || exit 1
status=0
for t in tests/test-*.sh; do
  if bash "$t"; then
    printf 'ok:   %s\n' "$t"
  else
    printf 'FAIL: %s\n' "$t"
    status=1
  fi
done
exit "$status"
