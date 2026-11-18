#!/usr/bin/env bash
# Minimal assertion helpers. Source this file from a *.test.sh script.
# Bash 3.2 compatible.

_ASSERT_PASS=0
_ASSERT_FAIL=0

_assert_ok() {
  _ASSERT_PASS=$((_ASSERT_PASS + 1))
  printf 'ok   - %s\n' "$1"
}

_assert_bad() {
  _ASSERT_FAIL=$((_ASSERT_FAIL + 1))
  printf 'FAIL - %s\n' "$1" >&2
}

# assert_eq <expected> <actual> <msg>
assert_eq() {
  if [ "$1" = "$2" ]; then
    _assert_ok "$3"
  else
    _assert_bad "$3"
    printf '       expected: %s\n       actual:   %s\n' "$1" "$2" >&2
  fi
}

# assert_contains <haystack> <needle> <msg>
assert_contains() {
  case "$1" in
    *"$2"*) _assert_ok "$3" ;;
    *)
      _assert_bad "$3"
      printf '       %s\n       does not contain: %s\n' "$1" "$2" >&2
      ;;
  esac
}

# assert_not_contains <haystack> <needle> <msg>
assert_not_contains() {
  case "$1" in
    *"$2"*)
      _assert_bad "$3"
      printf '       %s\n       unexpectedly contains: %s\n' "$1" "$2" >&2
      ;;
    *) _assert_ok "$3" ;;
  esac
}

# assert_exit <code> <cmd...>
assert_exit() {
  local expected="$1" actual
  shift
  "$@" >/dev/null 2>&1
  actual=$?
  if [ "$expected" = "$actual" ]; then
    _assert_ok "exit $expected: $*"
  else
    _assert_bad "exit $expected: $*"
    printf '       actual exit: %s\n' "$actual" >&2
  fi
}

# finish: print totals; exit 1 if any assertion failed.
finish() {
  printf '%s passed, %s failed\n' "$_ASSERT_PASS" "$_ASSERT_FAIL"
  [ "$_ASSERT_FAIL" -eq 0 ] || exit 1
  exit 0
}
