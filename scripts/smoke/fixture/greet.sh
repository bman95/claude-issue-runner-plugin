#!/usr/bin/env bash
# greet.sh — the smoke fixture's library: source it, then call its functions.

# greet NAME — print a greeting for NAME.
greet() {
  printf 'Hello, %s!\n' "$1"
}
