#!/usr/bin/env bash
# Tests for the CI workflow template and stack snippets. Bash 3.2 compatible.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="$HERE/../skills/initialize-repo"
RENDER="$SKILL/scripts/render.sh"
BASE="$SKILL/templates/.github/workflows/ci.yml"
# shellcheck source=lib/assert.sh
. "$HERE/lib/assert.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

STACKS="python node go rust placeholder"

# render_stack <stack> <branch> -> writes $TMP/<stack>-<branch>.yml
render_stack() {
  bash "$RENDER" "$BASE" "$TMP/$1-$2.yml" "DEFAULT_BRANCH=$2" \
    --insert "STACK_JOBS=$SKILL/templates/ci/$1.yml" 2>"$TMP/err"
}

have_actionlint() { command -v actionlint >/dev/null 2>&1; }

test_render_and_actionlint() {
  local s rc
  for s in $STACKS; do
    render_stack "$s" main
    assert_eq 0 "$?" "render $s: exit 0"
    if have_actionlint; then
      actionlint "$TMP/$s-main.yml" >"$TMP/al" 2>&1
      rc=$?
      assert_eq 0 "$rc" "actionlint $s: exit 0"
      [ "$rc" -eq 0 ] || cat "$TMP/al" >&2
    else
      echo "SKIP - actionlint $s (actionlint not installed)"
    fi
  done
}

test_no_trigger_paths() {
  local s
  for s in $STACKS; do
    render_stack "$s" main
    assert_eq "null" "$(yq '.on.pull_request.paths' "$TMP/$s-main.yml")" "$s: no pull_request paths"
    assert_eq "null" "$(yq '.on.pull_request."paths-ignore"' "$TMP/$s-main.yml")" "$s: no pull_request paths-ignore"
    assert_eq "null" "$(yq '.on.push.paths' "$TMP/$s-main.yml")" "$s: no push paths"
    assert_eq "null" "$(yq '.on.push."paths-ignore"' "$TMP/$s-main.yml")" "$s: no push paths-ignore"
    assert_eq 0 "$(grep -cE '^[[:space:]]*paths(-ignore)?:' "$TMP/$s-main.yml")" "$s: no paths keys at all"
  done
}

test_ci_ok_needs_all() {
  local s
  for s in $STACKS; do
    render_stack "$s" main
    assert_eq "scope,checks,lint,test" \
      "$(yq -r '.jobs."ci-ok".needs | join(",")' "$TMP/$s-main.yml")" "$s: ci-ok needs all jobs"
    assert_eq "always()" "$(yq -r '.jobs."ci-ok".if' "$TMP/$s-main.yml")" "$s: ci-ok if always()"
  done
}

test_stack_jobs_gated() {
  local s j
  for s in $STACKS; do
    render_stack "$s" main
    for j in lint test; do
      assert_eq "scope" "$(yq -r ".jobs.$j.needs" "$TMP/$s-main.yml")" "$s: $j needs scope"
      assert_eq "needs.scope.outputs.logic == 'true'" "$(yq -r ".jobs.$j.if" "$TMP/$s-main.yml")" "$s: $j gated on logic"
    done
  done
}

test_actions_pinned() {
  local s bad
  for s in $STACKS; do
    render_stack "$s" main
    bad="$(yq -r '.jobs[].steps[].uses | select(. != null)' "$TMP/$s-main.yml" | grep -Ev '@[0-9a-f]{40}$')"
    assert_eq "" "$bad" "$s: every uses: pinned to a 40-char SHA"
  done
}

test_render_trunk_branch() {
  local s
  for s in $STACKS; do
    render_stack "$s" trunk
    assert_eq "trunk" "$(yq -r '.on.push.branches[0]' "$TMP/$s-trunk.yml")" "$s: push branch is trunk"
  done
}

test_no_placeholders_left() {
  local s
  for s in $STACKS; do
    render_stack "$s" main
    assert_eq 0 "$(grep -c '{{[A-Z_]*}}' "$TMP/$s-main.yml")" "$s: no unfilled placeholders"
  done
}

test_render_and_actionlint
test_no_trigger_paths
test_ci_ok_needs_all
test_stack_jobs_gated
test_actions_pinned
test_render_trunk_branch
test_no_placeholders_left
finish
