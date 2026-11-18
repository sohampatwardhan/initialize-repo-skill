#!/usr/bin/env bash
# Classify changed files as "logic" or "non-logic".
# Reads newline-separated paths on stdin; prints exactly one word.
#   logic      at least one path can affect how the program runs
#   non-logic  every path is docs or similar (CI may skip heavy jobs)
# Empty input is "logic". Always exits 0.
# Patterns are bash globs where '*' also matches '/'. ALWAYS_LOGIC is
# checked first; a path matching neither array is logic.
# Bash 3.2 compatible.

# BEGIN SCOPE PATTERNS
NON_LOGIC=(
  '*.md'
  '*.txt'
  'docs/*'
  'LICENSE*'
  '.gitignore'
  '*/.gitignore'
  '.github/ISSUE_TEMPLATE/*'
  '.github/pull_request_template.md'
)
ALWAYS_LOGIC=(
  '.github/workflows/*'
  'scripts/*'
  'skills/*'         # the skill is the product, its markdown included
  'tests/*'
  '.claude-plugin/*' # plugin and marketplace manifests
  # 'CHANGELOG.md'  # uncomment if release tooling reads it
)
# END SCOPE PATTERNS

matches_any() {
  local path="$1" pattern
  shift
  for pattern in "$@"; do
    # shellcheck disable=SC2053
    [[ $path == $pattern ]] && return 0
  done
  return 1
}

seen=0
while IFS= read -r path || [ -n "$path" ]; do
  [ -n "$path" ] || continue
  seen=1
  if matches_any "$path" "${ALWAYS_LOGIC[@]}"; then
    echo logic
    exit 0
  fi
  if ! matches_any "$path" "${NON_LOGIC[@]}"; then
    echo logic
    exit 0
  fi
done

if [ "$seen" -eq 0 ]; then
  echo logic
else
  echo non-logic
fi
