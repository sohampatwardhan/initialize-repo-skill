#!/usr/bin/env bash
# Tests for skills/initialize-repo/scripts/render.sh
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RENDER="$HERE/../skills/initialize-repo/scripts/render.sh"
# shellcheck source=lib/assert.sh
. "$HERE/lib/assert.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

test_substitutes_values() {
  printf 'Hi {{NAME}}\n' >"$TMP/t1"
  bash "$RENDER" "$TMP/t1" "$TMP/o1" 'NAME=A & B/C \d'
  assert_eq 'Hi A & B/C \d' "$(cat "$TMP/o1")" "substitutes values with & / spaces and backslashes"
}

test_actions_expressions_untouched() {
  # shellcheck disable=SC2016
  printf '  if: ${{ github.ref }} {{X}}\n' >"$TMP/t2"
  bash "$RENDER" "$TMP/t2" "$TMP/o2" X=1
  assert_eq 0 "$?" "actions expression: exit 0"
  # shellcheck disable=SC2016
  assert_eq '  if: ${{ github.ref }} 1' "$(cat "$TMP/o2")" "actions expression untouched, placeholder filled"
}

test_unfilled_placeholder_fails() {
  printf '{{MISSING}}\n' >"$TMP/t3"
  local err
  err="$(bash "$RENDER" "$TMP/t3" "$TMP/o3" 2>&1 >/dev/null)"
  assert_exit 1 bash "$RENDER" "$TMP/t3" "$TMP/o3"
  assert_contains "$err" "MISSING" "stderr names the unfilled placeholder"
  assert_contains "$err" "render.sh: unfilled placeholders:" "stderr has the standard prefix"
  assert_eq '{{MISSING}}' "$(cat "$TMP/o3")" "output still written"
}

test_insert_indents() {
  printf 'jobs:\n  # {{JOBS}}\nend\n' >"$TMP/t4"
  printf 'a:\n  b\n' >"$TMP/snip"
  bash "$RENDER" "$TMP/t4" "$TMP/o4" --insert JOBS="$TMP/snip"
  assert_eq "$(printf 'jobs:\n  a:\n    b\nend')" "$(cat "$TMP/o4")" "insert indents to marker"
}

test_creates_parent_dirs() {
  printf 'x\n' >"$TMP/t5"
  bash "$RENDER" "$TMP/t5" "$TMP/deep/nested/x"
  assert_eq 0 "$?" "nested output: exit 0"
  assert_eq x "$(cat "$TMP/deep/nested/x")" "parent dirs created"
}

test_bad_usage() {
  assert_exit 2 bash "$RENDER"
  assert_exit 2 bash "$RENDER" "$TMP/nonexistent" "$TMP/o6"
}

test_preserves_lines() {
  printf '  keep \\n\n\nlast' >"$TMP/t7"
  bash "$RENDER" "$TMP/t7" "$TMP/o7"
  assert_eq "$(printf '  keep \\n\n\nlast')" "$(cat "$TMP/o7")" "whitespace, backslashes, blanks, no final newline"
}

test_substitutes_values
test_actions_expressions_untouched
test_unfilled_placeholder_fails
test_insert_indents
test_creates_parent_dirs
test_bad_usage
test_preserves_lines
finish
