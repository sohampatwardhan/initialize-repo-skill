#!/usr/bin/env bash
# Tests for preflight.sh: tools, auth, scopes, repo detection, situation.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../skills/initialize-repo/scripts/preflight.sh"
# shellcheck source=lib/assert.sh
. "$HERE/lib/assert.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export GH="$HERE/fake-gh/gh"

GOOD_AUTH="github.com
  ✓ Logged in to github.com account octo (keyring)
  - Active account: true
  - Git operations protocol: https
  - Token: gho_************************************
  - Token scopes: 'gist', 'project', 'read:org', 'repo', 'workflow'"

# setup: fresh fixture dir + project dir, logged in with good scopes.
setup() {
  rm -rf "$TMP/gh" "$TMP/proj"
  mkdir -p "$TMP/gh" "$TMP/proj"
  export FAKE_GH_DIR="$TMP/gh"
  printf '%s\n' "$GOOD_AUTH" >"$TMP/gh/auth-status.txt"
  echo '{"default_branch":"trunk","owner":{"type":"User"}}' >"$TMP/gh/repos__o__r.json"
  echo '{"data":{"repository":{"issueTypes":{"nodes":[]}}}}' >"$TMP/gh/graphql.json"
}

g() { git -C "$TMP/proj" "$@"; }

# mkrepo [remote-url] [commit?]
mkrepo() {
  git init -q -b main "$TMP/proj"
  [ -n "${1:-}" ] && g remote add origin "$1"
  if [ "${2:-}" = commit ]; then
    g -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q --allow-empty -m init
  fi
}

run() { OUT="$(bash "$SCRIPT" "$TMP/proj" 2>&1)"; RC=$?; }
val() { printf '%s\n' "$OUT" | sed -n "s/^$1=//p" | head -n 1; }

test_new_empty_dir() {
  setup; mkrepo
  run
  assert_eq 0 "$RC" "new: exit 0"
  assert_eq new "$(val situation)" "new: situation"
  assert_eq none "$(val repo)" "new: repo=none"
  assert_eq unknown "$(val owner_type)" "new: owner_type unknown"
  assert_eq no "$(val issue_types)" "new: issue_types no"
  assert_eq main "$(val default_branch)" "new: default_branch local"
  assert_eq ok "$(val auth)" "new: auth ok"
  assert_eq "gist,project,read:org,repo,workflow" "$(val scopes)" "new: scopes parsed"
}

test_output_order() {
  setup; mkrepo https://github.com/o/r.git commit
  run
  keys="$(printf '%s\n' "$OUT" | sed 's/=.*//' | tr '\n' ' ')"
  assert_eq "git gh jq auth scopes repo default_branch situation owner_type issue_types " "$keys" "stable key order"
}

test_no_commits_is_new() {
  setup; mkrepo https://github.com/o/r
  run
  assert_eq new "$(val situation)" "remote but no commits -> new"
  assert_eq o/r "$(val repo)" "repo detected without commits"
}

test_existing_first() {
  setup; mkrepo https://github.com/o/r.git commit
  run
  assert_eq 0 "$RC" "existing: exit 0"
  assert_eq existing-first "$(val situation)" "existing: situation"
  assert_eq o/r "$(val repo)" "existing: repo"
  assert_eq trunk "$(val default_branch)" "existing: default branch from API"
  assert_eq User "$(val owner_type)" "existing: owner_type from API"
}

test_configured() {
  setup; mkrepo https://github.com/o/r.git commit
  mkdir -p "$TMP/proj/.github/settings"; echo '{}' >"$TMP/proj/.github/settings/repo.json"
  run
  assert_eq configured "$(val situation)" "configured: situation"
}

test_remote_forms() {
  local url
  for url in git@github.com:o/r.git git@github.com:o/r ssh://git@github.com/o/r.git https://github.com/o/r; do
    setup; mkrepo "$url" commit
    run
    assert_eq o/r "$(val repo)" "remote form $url"
  done
}

test_non_github_remote() {
  setup; mkrepo https://gitlab.com/o/r.git commit
  run
  assert_eq 0 "$RC" "gitlab: exit 0"
  assert_eq none "$(val repo)" "gitlab: repo=none"
  assert_eq new "$(val situation)" "gitlab: situation new"
}

test_repo_get_fails() {
  setup; mkrepo https://github.com/o/r.git commit
  rm "$TMP/gh/repos__o__r.json"
  run
  assert_eq 0 "$RC" "api failure: exit 0"
  assert_eq unknown "$(val owner_type)" "api failure: owner_type unknown"
  assert_eq main "$(val default_branch)" "api failure: local branch"
  assert_eq existing-first "$(val situation)" "api failure: situation by rules"
}

test_org_owner() {
  setup; mkrepo https://github.com/o/r.git commit
  echo '{"default_branch":"main","owner":{"type":"Organization"}}' >"$TMP/gh/repos__o__r.json"
  run
  assert_eq Organization "$(val owner_type)" "org owner_type"
}

test_missing_workflow_scope() {
  setup; mkrepo
  printf "  - Token scopes: 'gist', 'repo'\n" >"$TMP/gh/auth-status.txt"
  run
  assert_eq 1 "$RC" "no workflow: exit 1"
  assert_contains "$OUT" "error=" "no workflow: error line"
  assert_contains "$OUT" "gh auth refresh -s workflow" "no workflow: names fix"
}

test_missing_repo_scope() {
  setup; mkrepo
  printf "  - Token scopes: 'workflow'\n" >"$TMP/gh/auth-status.txt"
  run
  assert_eq 1 "$RC" "no repo scope: exit 1"
  assert_contains "$OUT" "gh auth refresh -s repo" "no repo scope: names fix"
}

test_unknown_scopes() {
  setup; mkrepo
  printf 'github.com\n  - Token: ghp_xxx\n' >"$TMP/gh/auth-status.txt"
  run
  assert_eq 0 "$RC" "no scopes line: exit 0"
  assert_eq unknown "$(val scopes)" "no scopes line: scopes=unknown"
  assert_contains "$OUT" "warning=" "no scopes line: warning"
}

test_gh_logged_out() {
  setup; mkrepo
  rm "$TMP/gh/auth-status.txt"
  echo "You are not logged into any GitHub hosts." >"$TMP/gh/auth-status.err"
  run
  assert_eq 1 "$RC" "logged out: exit 1"
  assert_eq none "$(val auth)" "logged out: auth=none"
  assert_contains "$OUT" "gh auth login" "logged out: names fix"
}

test_issue_types_detected() {
  setup; mkrepo https://github.com/o/r.git commit
  echo '{"data":{"repository":{"issueTypes":{"nodes":[{"name":"Task"},{"name":"Bug"},{"name":"Feature"}]}}}}' >"$TMP/gh/graphql.json"
  run
  assert_eq User "$(val owner_type)" "types: user repo"
  assert_eq yes "$(val issue_types)" "types: yes"
}

test_issue_types_absent() {
  setup; mkrepo https://github.com/o/r.git commit
  run
  assert_eq no "$(val issue_types)" "types: empty -> no"
}

test_issue_types_graphql_error() {
  setup; mkrepo https://github.com/o/r.git commit
  echo "gh: Field 'issueTypes' doesn't exist (HTTP 200)" >"$TMP/gh/graphql.err"
  run
  assert_eq 0 "$RC" "graphql error: exit 0"
  assert_eq no "$(val issue_types)" "graphql error -> no"
}

# restricted PATH containing everything except the named tool
restricted_path() {
  local d="$TMP/bin" t p
  rm -rf "$d"; mkdir -p "$d"
  for t in bash sed tr grep head cat dirname git jq; do
    [ "$t" = "$1" ] && continue
    p="$(command -v "$t")" && ln -s "$p" "$d/$t"
  done
  printf '%s' "$d"
}

test_missing_jq() {
  setup; mkrepo
  OUT="$(PATH="$(restricted_path jq)" /bin/bash "$SCRIPT" "$TMP/proj" 2>&1)"; RC=$?
  assert_eq 1 "$RC" "no jq: exit 1"
  assert_eq missing "$(val jq)" "no jq: jq=missing"
  assert_eq ok "$(val git)" "no jq: git ok"
  assert_contains "$OUT" "error=" "no jq: error line"
}

test_missing_git_and_jq_reported_together() {
  setup; mkrepo
  d="$(restricted_path git)"; rm -f "$d/jq"
  OUT="$(PATH="$d" /bin/bash "$SCRIPT" "$TMP/proj" 2>&1)"; RC=$?
  assert_eq 1 "$RC" "no git/jq: exit 1"
  assert_eq missing "$(val git)" "no git/jq: git=missing"
  assert_eq missing "$(val jq)" "no git/jq: jq=missing"
}

test_missing_gh() {
  setup; mkrepo
  OUT="$(GH=/nonexistent/gh bash "$SCRIPT" "$TMP/proj" 2>&1)"; RC=$?
  assert_eq 1 "$RC" "no gh: exit 1"
  assert_eq missing "$(val gh)" "no gh: gh=missing"
  assert_contains "$OUT" "error=" "no gh: error line"
}

test_new_empty_dir
test_output_order
test_no_commits_is_new
test_existing_first
test_configured
test_remote_forms
test_non_github_remote
test_repo_get_fails
test_org_owner
test_missing_workflow_scope
test_missing_repo_scope
test_unknown_scopes
test_gh_logged_out
test_issue_types_detected
test_issue_types_absent
test_issue_types_graphql_error
test_missing_jq
test_missing_git_and_jq_reported_together
test_missing_gh

finish
