#!/usr/bin/env bash
# Smoke test: render every content template and check the output.
# Covers everything under templates/ except ci/, scripts/, .github/workflows/.
# Bash 3.2 compatible.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/.."
SKILL="$ROOT/skills/initialize-repo"
TPL="$SKILL/templates"
RENDER="$SKILL/scripts/render.sh"
# shellcheck source=lib/assert.sh
. "$HERE/lib/assert.sh"

OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
: >"$OUT/empty.txt"

RENDER_FAILS=""
render_all() {
  local f rel
  while IFS= read -r f; do
    rel="${f#"$TPL"/}"
    case "$rel" in
      ci/* | scripts/* | .github/workflows/*) continue ;;
    esac
    mkdir -p "$OUT/r/$(dirname "$rel")"
    bash "$RENDER" "$f" "$OUT/r/$rel" \
      PROJECT_NAME=demo 'DESCRIPTION=A demo project.' OWNER=acme REPO=demo \
      DEFAULT_BRANCH=trunk YEAR=2026 'COPYRIGHT_HOLDER=Acme Inc.' \
      LICENSE_NAME=MIT SECURITY_CONTACT=security@example.com \
      'COMMIT_CONVENTION=Conventional Commits' 'STACK_COMMANDS=make test' \
      --insert STACK_ECOSYSTEM="$OUT/empty.txt" >/dev/null 2>&1 ||
      RENDER_FAILS="$RENDER_FAILS $rel"
  done < <(find "$TPL" -type f | sort)
}
render_all

test_all_render_clean() {
  assert_eq "" "$RENDER_FAILS" "every template renders with exit 0"
  local n
  n="$(find "$OUT/r" -type f | wc -l | tr -d ' ')"
  assert_eq 13 "$n" "13 templates rendered"
}

test_yaml_valid() {
  local f
  while IFS= read -r f; do
    assert_exit 0 yq e '.' "$f"
  done < <(find "$OUT/r" -name '*.yml' | sort)
}

test_issue_forms() {
  local k
  for k in bug:Bug:bug feature:Feature:enhancement task:Task:task; do
    local name="${k%%:*}" rest="${k#*:}"
    local type="${rest%%:*}" label="${rest#*:}"
    local f="$OUT/r/.github/ISSUE_TEMPLATE/$name.yml"
    assert_eq "$type" "$(yq e '.type' "$f")" "$name.yml sets type"
    assert_eq "$label" "$(yq e '.labels[0]' "$f")" "$name.yml sets label"
  done
  assert_eq "false" "$(yq e '.blank_issues_enabled' "$OUT/r/.github/ISSUE_TEMPLATE/config.yml")" "blank issues disabled"
}

test_dependabot() {
  local f="$OUT/r/.github/dependabot.yml"
  assert_eq "github-actions" "$(yq e '.updates[].package-ecosystem' "$f" | head -n 1)" "dependabot covers github-actions"
  assert_contains "$(cat "$TPL/.github/dependabot.yml")" "# {{STACK_ECOSYSTEM}}" "dependabot has the stack marker"
}

test_claude_md_imports_agents() {
  assert_eq "@AGENTS.md" "$(cat "$OUT/r/CLAUDE.md")" "CLAUDE.md is exactly @AGENTS.md"
}

test_agents_sections() {
  local a
  a="$(cat "$OUT/r/AGENTS.md")"
  assert_contains "$a" "## GitHub workflow" "AGENTS.md has GitHub workflow"
  assert_contains "$a" "## CI scope" "AGENTS.md has CI scope"
  assert_contains "$a" "## Repository settings" "AGENTS.md has Repository settings"
  assert_contains "$a" "scripts/repo-settings.sh audit" "AGENTS.md names the audit command"
  assert_contains "$a" "do not replace" "AGENTS.md forbids on: paths"
}

test_agents_has_type_fallback() {
  local a
  a="$(cat "$OUT/r/AGENTS.md")"
  assert_contains "$a" "\`bug\`, \`enhancement\` or \`task\` label" "AGENTS.md has the issue-type label fallback"
}

test_agents_embeds_reference() {
  # Every non-blank line of the reference body (after its title) appears in AGENTS.md.
  local missing="" line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    grep -qxF -- "$line" "$OUT/r/AGENTS.md" || missing="$missing|$line"
  done < <(tail -n +2 "$SKILL/references/github-workflow.md" | sed -e 's/^#/##/')
  assert_eq "" "$missing" "AGENTS.md embeds references/github-workflow.md (headings demoted one level)"
}

test_pr_and_changelog() {
  assert_contains "$(cat "$OUT/r/.github/pull_request_template.md")" "Closes #" "PR template has Closes #"
  assert_contains "$(cat "$OUT/r/.github/pull_request_template.md")" "CHANGELOG.md" "PR template has CHANGELOG item"
  assert_contains "$(cat "$OUT/r/CHANGELOG.md")" "## [Unreleased]" "CHANGELOG has Unreleased"
}

test_no_personal_data() {
  local hits
  hits="$(grep -rilE 'soham|patwardhan' "$SKILL/templates" "$SKILL/references" "$SKILL/config" 2>/dev/null)"
  assert_eq "" "$hits" "no personal data in shipped files"
}

test_markdown_lint() {
  if ! command -v npx >/dev/null 2>&1; then
    echo "SKIP - markdown lint (npx not available)"
    return 0
  fi
  local files
  files="$(find "$OUT/r" -name "*.md" ! -name CLAUDE.md | sort)" # CLAUDE.md is exactly @AGENTS.md, which cannot start with a heading
  # shellcheck disable=SC2086
  (cd "$ROOT" && npx --yes markdownlint-cli2@0.24.0 --config .markdownlint-cli2.jsonc $files >"$OUT/lint.log" 2>&1)
  local rc=$?
  assert_eq 0 "$rc" "markdownlint-cli2 passes on rendered markdown"
  [ "$rc" -eq 0 ] || cat "$OUT/lint.log" >&2
}

test_all_render_clean
test_yaml_valid
test_issue_forms
test_dependabot
test_claude_md_imports_agents
test_agents_sections
test_agents_has_type_fallback
test_agents_embeds_reference
test_pr_and_changelog
test_no_personal_data
test_markdown_lint
finish
