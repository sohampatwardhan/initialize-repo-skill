#!/usr/bin/env bash
# Tests for ci-scope.sh. Works in this repo and in a generated repo's scripts/.
# Bash 3.2 compatible.

HERE="$(cd "$(dirname "$0")" && pwd)"
SCOPE="$HERE/ci-scope.sh"

ASSERT_LIB="${ASSERT_LIB:-$HERE/../../../../tests/lib/assert.sh}"
if [ -f "$ASSERT_LIB" ]; then
  # shellcheck source=/dev/null
  . "$ASSERT_LIB"
else
  # Minimal inline fallback; same names and exit behaviour as tests/lib/assert.sh.
  _ASSERT_PASS=0
  _ASSERT_FAIL=0
  assert_eq() {
    if [ "$1" = "$2" ]; then
      _ASSERT_PASS=$((_ASSERT_PASS + 1))
      printf 'ok   - %s\n' "$3"
    else
      _ASSERT_FAIL=$((_ASSERT_FAIL + 1))
      printf 'FAIL - %s\n       expected: %s\n       actual:   %s\n' "$3" "$1" "$2" >&2
    fi
  }
  finish() {
    printf '%s passed, %s failed\n' "$_ASSERT_PASS" "$_ASSERT_FAIL"
    [ "$_ASSERT_FAIL" -eq 0 ] || exit 1
    exit 0
  }
fi

classify() { printf '%s\n' "$@" | bash "$SCOPE"; }

test_changelog_override() {
  local tmp
  tmp="$(mktemp -d)"
  sed -e "s/^  # 'CHANGELOG.md'/  'CHANGELOG.md'/" "$SCOPE" >"$tmp/ci-scope.sh"
  assert_eq logic "$(printf 'CHANGELOG.md\n' | bash "$tmp/ci-scope.sh")" "uncommented CHANGELOG.md is logic"
  assert_eq non-logic "$(printf 'README.md\n' | bash "$tmp/ci-scope.sh")" "README.md stays non-logic"
  rm -rf "${tmp:?}"
}

test_readme_only()       { assert_eq non-logic "$(classify README.md)" "README only"; }
test_nested_docs()       { assert_eq non-logic "$(classify docs/a/b.md guide.txt)" "nested docs and txt"; }
test_source_file()       { assert_eq logic "$(classify src/main.rs)" "source file"; }
test_mixed()             { assert_eq logic "$(classify README.md src/main.rs)" "docs plus source"; }
test_unlisted_path()     { assert_eq logic "$(classify Makefile)" "unlisted path"; }
test_always_logic_wins() { assert_eq logic "$(classify scripts/notes.md)" "ALWAYS_LOGIC beats NON_LOGIC"; }
test_workflow_is_logic() { assert_eq logic "$(classify .github/workflows/ci.yml)" "workflow is logic"; }
test_empty_input()       { assert_eq logic "$(printf '' | bash "$SCOPE")" "empty input"; }
test_path_with_spaces()  { assert_eq non-logic "$(classify 'docs/my notes.md')" "path with spaces"; }
test_deleted_doc_only()  { assert_eq non-logic "$(classify old-guide.md)" "deleted doc path"; }
test_issue_template()    { assert_eq non-logic "$(classify .github/ISSUE_TEMPLATE/bug.yml)" "issue template"; }

test_readme_only
test_nested_docs
test_source_file
test_mixed
test_unlisted_path
test_always_logic_wins
test_workflow_is_logic
test_empty_input
test_path_with_spaces
test_deleted_doc_only
test_issue_template
test_changelog_override

finish
