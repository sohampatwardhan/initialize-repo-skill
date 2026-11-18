#!/usr/bin/env bash
# Tests for skills/initialize-repo/SKILL.md and its references. Bash 3.2 compatible.
#
# Path rule checked here: in SKILL.md, a path that starts with scripts/,
# templates/, references/ or config/ and follows a backtick, "$SKILL/" or a
# Markdown link "](" is a path in the skill directory and must exist there.
# Paths in the repo being set up are written from its root as ./scripts/...
# or .github/..., so they never match. Paths holding a <placeholder> or a
# $variable are skipped.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="$HERE/../skills/initialize-repo"
DOC="$SKILL/SKILL.md"
EXAMPLE="$SKILL/references/examples/step-gated.yml"
# shellcheck source=lib/assert.sh
. "$HERE/lib/assert.sh"

have() { command -v "$1" >/dev/null 2>&1; }
doc_text() { [ -f "$DOC" ] && cat "$DOC"; }

# frontmatter_field <key>: the value of a top-level key in SKILL.md's frontmatter.
frontmatter_field() {
  [ -f "$DOC" ] || return 0
  yq --front-matter=extract ".$1 // \"\"" "$DOC" 2>/dev/null
}

test_frontmatter_name() {
  local dir
  dir="$(basename "$(cd "$SKILL" && pwd)")"
  assert_eq "---" "$(head -n 1 "$DOC" 2>/dev/null)" "SKILL.md starts with YAML frontmatter"
  assert_eq "initialize-repo" "$(frontmatter_field name)" "frontmatter name is initialize-repo"
  assert_eq "$dir" "$(frontmatter_field name)" "frontmatter name matches the skill directory"
}

test_description_length() {
  local d n
  d="$(frontmatter_field description)"
  n="$(printf '%s' "$d" | wc -c | tr -d ' ')"
  assert_eq yes "$([ "$n" -gt 0 ] && echo yes || echo no)" "description is not empty"
  assert_eq yes "$([ "$n" -le 1024 ] && echo yes || echo no)" "description is at most 1024 characters (got $n)"
  case "$d" in
    "Use when"*) assert_eq ok ok "description starts with 'Use when'" ;;
    *) assert_eq "Use when..." "$d" "description starts with 'Use when'" ;;
  esac
}

# skill_paths: every skill-directory path referenced in SKILL.md, one per line.
# shellcheck disable=SC2016 # backticks and $SKILL are literal text to match
skill_paths() {
  doc_text | grep -oE '(`|\$SKILL/|\]\()(scripts|templates|references|config)/[^`"'"'"' )]*' |
    sed -E 's#^(`|\$SKILL/|\]\()##' | sed -E 's#[.,:;]+$##' | sort -u
}

test_referenced_paths_exist() {
  local p n=0 missing=""
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    case "$p" in *'<'* | *'>'* | *'$'*) continue ;; esac # placeholders: templates/ci/<stack>.yml, templates/$rel
    n=$((n + 1))
    case "$p" in
      *'*'*)
        # shellcheck disable=SC2086 # the glob must expand
        ls -d "$SKILL"/$p >/dev/null 2>&1 || missing="$missing $p"
        ;;
      *) [ -e "$SKILL/$p" ] || missing="$missing $p" ;;
    esac
  done < <(skill_paths)
  assert_eq yes "$([ "$n" -ge 10 ] && echo yes || echo no)" "SKILL.md references at least 10 skill paths (found $n)"
  assert_eq "" "$missing" "every referenced skill path exists"
}

test_step_gated_example_lints() {
  assert_eq yes "$([ -f "$EXAMPLE" ] && echo yes || echo no)" "references/examples/step-gated.yml exists"
  [ -f "$EXAMPLE" ] || return 0
  if have actionlint; then
    local out rc
    out="$(actionlint "$EXAMPLE" 2>&1)"
    rc=$?
    assert_eq 0 "$rc" "actionlint step-gated.yml: exit 0"
    [ "$rc" -eq 0 ] || printf '%s\n' "$out" >&2
  else
    echo "SKIP - actionlint step-gated.yml (actionlint not installed)"
  fi
  local matrix_jobs
  matrix_jobs="$(yq -r '.jobs | to_entries[] | select(.value.strategy.matrix) | .key' "$EXAMPLE")"
  assert_eq yes "$([ -n "$matrix_jobs" ] && echo yes || echo no)" "example has a matrix job"
  # Gated jobs: every job that needs scope. Counts, not literals: yq prints a
  # literal string even after an empty select.
  # shellcheck disable=SC2016 # ${{ }} is GitHub Actions syntax, not shell
  local gated='.jobs[] | select([.needs] | flatten | any_c(. == "scope"))'
  assert_eq yes "$([ "$(yq -r "[$gated] | length" "$EXAMPLE")" -ge 1 ] && echo yes || echo no)" "example has a job that needs scope"
  assert_eq 0 "$(yq -r '[.jobs[] | select(.strategy.matrix) | select([.needs] | flatten | any_c(. == "scope") | not)] | length' "$EXAMPLE")" \
    "matrix job needs scope"
  # shellcheck disable=SC2016 # ${{ }} is GitHub Actions syntax, not shell
  assert_eq 0 "$(yq -r "[$gated | select(.if != \"\${{ !cancelled() }}\")] | length" "$EXAMPLE")" \
    'every gated job has job-level if: ${{ !cancelled() }} and no other condition'
  assert_eq 0 "$(yq -r "[$gated | select(.steps[0].if != \"needs.scope.result != 'success'\")] | length" "$EXAMPLE")" \
    "every gated job's first step fails when scope did not succeed"
  assert_eq 0 "$(yq -r "[$gated | select(.steps[0].run | test(\"exit 1\") | not)] | length" "$EXAMPLE")" \
    "the scope guard step exits 1"
  assert_eq "" "$(yq -r "$gated | .steps[1:][] | select((.if // \"\") | test(\"needs\\\\.scope\\\\.outputs\\\\.logic\") | not) | (.name // .uses // .run)" "$EXAMPLE")" \
    "every gated step after the guard depends on needs.scope.outputs.logic"
  assert_eq "" "$(grep -E '^[[:space:]]*-?[[:space:]]*uses:' "$EXAMPLE" | grep -vE 'uses: [^@]+@[0-9a-f]{40} # v[0-9]+\.[0-9]+\.[0-9]+$')" \
    "every action is pinned to a SHA with a version comment"
  assert_eq 0 "$(grep -cE '^[[:space:]]*paths(-ignore)?:' "$EXAMPLE")" "example has no paths filters"
}

test_steps_in_order() {
  local want="Preflight|Gather|Create or connect|Write files|CI in existing repos|Commit|Settings|Summary|Proof PR"
  local headings n i=1 kw line
  headings="$(doc_text | grep -E '^### [0-9]+\. ')"
  n="$(printf '%s\n' "$headings" | grep -c .)"
  assert_eq 9 "$n" "SKILL.md has nine numbered step headings"
  while IFS= read -r kw; do
    line="$(printf '%s\n' "$headings" | sed -n "${i}p")"
    assert_contains "$line" "### $i. " "step $i heading is numbered $i"
    assert_contains "$line" "$kw" "step $i heading contains '$kw'"
    i=$((i + 1))
  done < <(printf '%s\n' "$want" | tr '|' '\n')
}

test_required_content() {
  local d
  d="$(doc_text)"
  assert_contains "$d" "Resolve these paths from the directory containing this SKILL.md." "SKILL.md says how to resolve paths"
  assert_contains "$d" "gh pr list --state merged --limit 10 --json number,files" "step 5 gives the backtest command"
  assert_contains "$d" "BLOCKED" "step 7 explains BLOCKED"
  assert_contains "$d" "exit 4" "step 7 names exit 4"
  assert_contains "$d" "UNAVAILABLE" "step 7 explains UNAVAILABLE"
  assert_contains "$d" "chore/initialize-repo" "existing repos use the setup branch"
  # shellcheck disable=SC2088 # literal text, not a path to expand
  assert_contains "$d" "~/.config/initialize-repo/defaults.yaml" "SKILL.md names the preferences file"
  local c s
  c="$(cat "$SKILL/references/ci-design.md" 2>/dev/null)"
  assert_contains "$c" "examples/step-gated.yml" "ci-design.md links the step-gated example"
  assert_contains "$c" "ci-ok" "ci-design.md covers the ci-ok mode"
  assert_contains "$c" "matrix" "ci-design.md explains the matrix pitfall"
  s="$(cat "$SKILL/references/settings-baseline.md" 2>/dev/null)"
  assert_contains "$s" "bypass" "settings-baseline.md explains the bypass"
  assert_contains "$s" "free" "settings-baseline.md names the free-plan limit"
  assert_contains "$s" "replaces" "settings-baseline.md says a PUT replaces the ruleset"
}

test_frontmatter_name
test_description_length
test_referenced_paths_exist
test_step_gated_example_lints
test_steps_in_order
test_required_content
finish
