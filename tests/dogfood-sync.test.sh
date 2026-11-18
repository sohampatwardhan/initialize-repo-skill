#!/usr/bin/env bash
# This repo is set up with its own skill. Its copies of the generated-repo
# scripts must stay in sync with the skill's templates, and its CI must keep
# the ci-ok design. Bash 3.2 compatible.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/.."
TPL="$ROOT/skills/initialize-repo/templates"
CI="$ROOT/.github/workflows/ci.yml"
# shellcheck source=lib/assert.sh
. "$HERE/lib/assert.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

same() { cmp -s "$1" "$2" && echo same || echo differs; }

# outside_patterns <file>: the file with the lines strictly between
# "# BEGIN SCOPE PATTERNS" and "# END SCOPE PATTERNS" removed.
outside_patterns() {
  awk '/^# END SCOPE PATTERNS$/ { inside = 0 } !inside { print } /^# BEGIN SCOPE PATTERNS$/ { inside = 1 }' "$1"
}

test_repo_settings_in_sync() {
  assert_eq same "$(same "$ROOT/scripts/repo-settings.sh" "$TPL/scripts/repo-settings.sh")" \
    "scripts/repo-settings.sh is identical to the template"
}

test_ci_scope_test_in_sync() {
  assert_eq same "$(same "$ROOT/scripts/ci-scope.test.sh" "$TPL/scripts/ci-scope.test.sh")" \
    "scripts/ci-scope.test.sh is identical to the template"
}

test_ci_scope_in_sync() {
  local f
  for f in scripts/ci-scope.sh skills/initialize-repo/templates/scripts/ci-scope.sh; do
    assert_eq 1 "$(grep -cx '# BEGIN SCOPE PATTERNS' "$ROOT/$f" 2>/dev/null)" "$f has one BEGIN marker"
    assert_eq 1 "$(grep -cx '# END SCOPE PATTERNS' "$ROOT/$f" 2>/dev/null)" "$f has one END marker"
  done
  [ -f "$ROOT/scripts/ci-scope.sh" ] || return 0
  outside_patterns "$ROOT/scripts/ci-scope.sh" >"$TMP/repo"
  outside_patterns "$TPL/scripts/ci-scope.sh" >"$TMP/tpl"
  assert_eq same "$(same "$TMP/repo" "$TMP/tpl")" "scripts/ci-scope.sh matches the template outside the pattern block"
  [ "$(same "$TMP/repo" "$TMP/tpl")" = same ] || diff "$TMP/tpl" "$TMP/repo" >&2
}

# This repo's extra patterns. scripts/ci-scope.test.sh must stay identical to
# the template, so the cases for them live here.
test_repo_scope_patterns() {
  local s="$ROOT/scripts/ci-scope.sh" p
  [ -f "$s" ] || { assert_eq exists missing "scripts/ci-scope.sh exists"; return 0; }
  for p in skills/initialize-repo/SKILL.md skills/initialize-repo/references/ci-design.md \
    tests/skill.test.sh tests/fixtures/repo-basic/settings/repo.json .claude-plugin/plugin.json \
    .github/workflows/ci.yml scripts/ci-scope.sh; do
    assert_eq logic "$(printf '%s\n' "$p" | bash "$s")" "$p is logic"
  done
  for p in README.md AGENTS.md CHANGELOG.md docs/superpowers/plans/x.md LICENSE .github/ISSUE_TEMPLATE/bug.yml; do
    assert_eq non-logic "$(printf '%s\n' "$p" | bash "$s")" "$p is non-logic"
  done
}

test_ci_scope_job() {
  local tpl_run
  tpl_run="$(yq -r '.jobs.scope.steps[] | select(.id == "scope") | .run' "$TPL/.github/workflows/ci.yml")"
  assert_eq "$tpl_run" "$(yq -r '.jobs.scope.steps[] | select(.id == "scope") | .run' "$CI")" \
    "ci.yml scope step runs the same script as the template"
  # shellcheck disable=SC2016 # GitHub Actions expression, not shell
  assert_eq '${{ steps.scope.outputs.logic }}' "$(yq -r '.jobs.scope.outputs.logic' "$CI")" "ci.yml scope job exposes logic"
  assert_eq 2 "$(yq -r '.jobs.scope.steps[0].with."fetch-depth"' "$CI")" "ci.yml scope checks out with fetch-depth 2"
}

test_ci_heavy_jobs_gated() {
  local j
  for j in shellcheck actionlint tests; do
    assert_eq scope "$(yq -r ".jobs.$j.needs" "$CI")" "ci.yml: $j needs scope"
    assert_eq "needs.scope.outputs.logic == 'true'" "$(yq -r ".jobs.$j.if" "$CI")" "ci.yml: $j gated on logic"
  done
}

test_ci_ok() {
  local want
  want="$(yq -r '.jobs | keys | .[] | select(. != "ci-ok")' "$CI" | sort | tr '\n' ',')"
  assert_eq "$want" "$(yq -r '.jobs."ci-ok".needs[]' "$CI" | sort | tr '\n' ',')" "ci.yml: ci-ok needs every other job"
  assert_eq "always()" "$(yq -r '.jobs."ci-ok".if' "$CI")" "ci.yml: ci-ok runs always()"
  assert_eq "$(yq -r '.jobs."ci-ok".steps' "$TPL/.github/workflows/ci.yml")" "$(yq -r '.jobs."ci-ok".steps' "$CI")" \
    "ci.yml: ci-ok steps match the template"
  assert_eq ci-ok "$(jq -r '.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks[].context' \
    "$ROOT/.github/settings/ruleset-default-branch.json" 2>/dev/null | tr '\n' ' ' | sed 's/ $//')" \
    "the ruleset requires only ci-ok"
}

test_ci_hygiene() {
  assert_eq 0 "$(grep -cE '^[[:space:]]*paths(-ignore)?:' "$CI")" "ci.yml has no paths filters"
  assert_eq read "$(yq -r '.permissions.contents' "$CI")" "ci.yml permissions: contents: read"
  assert_eq "" "$(grep -E '^[[:space:]]*-?[[:space:]]*uses:' "$CI" | grep -vE 'uses: [^@]+@[0-9a-f]{40} # v[0-9]+\.[0-9]+\.[0-9]+$')" \
    "ci.yml pins every action to a SHA with a version comment"
}

test_repo_settings_in_sync
test_ci_scope_test_in_sync
test_ci_scope_in_sync
test_repo_scope_patterns
test_ci_scope_job
test_ci_heavy_jobs_gated
test_ci_ok
test_ci_hygiene
finish
