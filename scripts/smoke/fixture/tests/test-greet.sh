#!/usr/bin/env bash
# Tests for greet.sh; test.sh runs this from the project root.
# shellcheck disable=SC1091 # sourced from the project root, not this file's dir
. ./greet.sh
got=$(greet World)
[ "$got" = "Hello, World!" ] || { echo "greet World: got '$got'"; exit 1; }
