#!/usr/bin/env bash
# Tests for the assertion helpers themselves.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/assert.sh
. "$HERE/lib/assert.sh"

assert_eq a a "assert_eq passes on equal values"
assert_contains "hello world" "lo wo" "assert_contains finds a substring"
assert_not_contains "hello" "xyz" "assert_not_contains passes when absent"
assert_exit 0 true
assert_exit 3 bash -c 'exit 3'

# A failing assertion must make finish exit 1 (run in a subshell, silenced).
(
  # shellcheck source=lib/assert.sh
  . "$HERE/lib/assert.sh"
  assert_eq a b "deliberate failure"
  finish
) >/dev/null 2>&1
assert_eq 1 "$?" "finish exits 1 when an assertion failed"

finish
