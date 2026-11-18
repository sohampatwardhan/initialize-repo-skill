#!/usr/bin/env bash
# Run every tests/*.test.sh and skills/initialize-repo/templates/scripts/*.test.sh.
# Exits non-zero if any test file fails. Bash 3.2 compatible.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

failed=0
ran=0
for f in tests/*.test.sh skills/initialize-repo/templates/scripts/*.test.sh; do
  [ -f "$f" ] || continue # unmatched glob stays literal
  ran=$((ran + 1))
  printf '== %s\n' "$f"
  if ! bash "$f"; then
    printf 'FAILED: %s\n' "$f" >&2
    failed=$((failed + 1))
  fi
done

printf '%s test file(s) run, %s failed\n' "$ran" "$failed"
[ "$failed" -eq 0 ]
