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

# scope_logic <workflow> <event> <ci-scope output> -> the logic= value the
# workflow's scope step writes when ci-scope.sh prints <ci-scope output>.
# Runs the step's own shell with a fake git and a stub scripts/ci-scope.sh.
scope_logic() {
  local wf="$1" event="$2" printed="$3" dir
  dir="$(mktemp -d "$TMP/scope.XXXXXX")"
  mkdir -p "$dir/bin" "$dir/scripts"
  printf '#!/usr/bin/env bash\necho README.md\n' >"$dir/bin/git"
  # shellcheck disable=SC2016 # $SCOPE_PRINTS expands in the stub, not here
  printf '#!/usr/bin/env bash\ncat >/dev/null\nprintf "%%s\\n" "$SCOPE_PRINTS"\n' >"$dir/scripts/ci-scope.sh"
  chmod +x "$dir/bin/git"
  yq -r '.jobs.scope.steps[] | select(.id == "scope") | .run' "$wf" >"$dir/step.sh"
  : >"$dir/out"
  (cd "$dir" && PATH="$dir/bin:$PATH" EVENT_NAME="$event" SCOPE_PRINTS="$printed" \
    GITHUB_OUTPUT="$dir/out" bash -e "$dir/step.sh" >/dev/null 2>&1)
  sed -n 's/^logic=//p' "$dir/out"
}

# Unknown scope output must run CI (fail closed): only exactly "non-logic" skips.
test_scope_fails_closed() {
  local wf="$1" label="$2"
  assert_eq false "$(scope_logic "$wf" pull_request non-logic)" "$label: non-logic -> logic=false"
  assert_eq true "$(scope_logic "$wf" pull_request logic)" "$label: logic -> logic=true"
  assert_eq true "$(scope_logic "$wf" pull_request '')" "$label: empty output -> logic=true"
  assert_eq true "$(scope_logic "$wf" pull_request garbage)" "$label: unknown output -> logic=true"
  assert_eq true "$(scope_logic "$wf" pull_request 'non-logic ')" "$label: near-miss output -> logic=true"
  assert_eq true "$(scope_logic "$wf" push non-logic)" "$label: push always logic=true"
  # shellcheck disable=SC2016 # literal text to match
  assert_eq 1 "$(yq -r '.jobs.scope.steps[] | select(.id == "scope") | .run' "$wf" | grep -c '"$kind" = "non-logic"')" \
    "$label: scope step compares against exactly non-logic"
}

test_template_scope_fails_closed() {
  render_stack placeholder main
  test_scope_fails_closed "$TMP/placeholder-main.yml" template
  test_scope_fails_closed "$SKILL/references/examples/step-gated.yml" step-gated-example
}

test_render_and_actionlint
test_template_scope_fails_closed
test_no_trigger_paths
test_ci_ok_needs_all
test_stack_jobs_gated
test_actions_pinned
test_render_trunk_branch
test_no_placeholders_left
finish
