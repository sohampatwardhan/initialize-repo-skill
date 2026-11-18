#!/usr/bin/env bash
# Tests for skills/initialize-repo/templates/scripts/repo-settings.sh
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../skills/initialize-repo/templates/scripts/repo-settings.sh"
# shellcheck source=lib/assert.sh
. "$HERE/lib/assert.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export GH="$HERE/fake-gh/gh"
TAB="$(printf '\t')"

# setup <fixture>: fresh FAKE_GH_DIR copy; sets FAKE_GH_DIR, SETTINGS
setup() {
  rm -rf "$TMP/gh" "$TMP/settings"
  cp -R "$HERE/fixtures/$1/gh" "$TMP/gh"
  cp -R "$HERE/fixtures/$1/settings" "$TMP/settings"
  export FAKE_GH_DIR="$TMP/gh"
  : >"$TMP/gh/calls.log"
}

# run <args...>: sets OUT, ERR, RC
run() {
  OUT="$(bash "$SCRIPT" "$@" 2>"$TMP/stderr")"
  RC=$?
  ERR="$(cat "$TMP/stderr")"
}

test_audit_reports_diffs() {
  setup repo-basic
  run audit --repo o/r --dir "$TMP/settings"
  assert_eq 1 "$RC" "audit with diffs: exit 1"
  assert_contains "$OUT" "DIFF${TAB}repo.allow_auto_merge${TAB}live=false${TAB}desired=true" "reports allow_auto_merge"
  assert_contains "$OUT" "DIFF${TAB}repo.delete_branch_on_merge${TAB}live=false${TAB}desired=true" "reports delete_branch_on_merge"
  assert_not_contains "$OUT" "repo.has_wiki" "matching item not reported"
}

test_audit_default_repo_from_gh() {
  setup repo-basic
  run audit --dir "$TMP/settings"
  assert_eq 1 "$RC" "repo resolved via gh repo view"
}

test_audit_clean() {
  setup repo-clean
  run audit --repo o/r --dir "$TMP/settings"
  assert_eq 0 "$RC" "clean audit: exit 0"
  assert_not_contains "$OUT" "DIFF" "no DIFF lines"
}

test_declined_not_reported() {
  setup repo-basic
  jq '.declined=[{"item":"repo.allow_auto_merge","reason":"no"}]' "$TMP/settings/repo.json" >"$TMP/x" && mv "$TMP/x" "$TMP/settings/repo.json"
  run audit --repo o/r --dir "$TMP/settings"
  assert_not_contains "$OUT" "repo.allow_auto_merge" "declined item not reported"
  assert_contains "$OUT" "repo.delete_branch_on_merge" "other diffs still reported"
  run apply --repo o/r --dir "$TMP/settings" --all
  assert_not_contains "$(cat "$TMP/gh/calls.log")" "allow_auto_merge" "declined item not applied"
}

test_apply_named_item() {
  setup repo-basic
  run apply --repo o/r --dir "$TMP/settings" repo.allow_auto_merge
  assert_eq 0 "$RC" "apply named: exit 0"
  assert_contains "$OUT" "APPLIED${TAB}repo.allow_auto_merge" "APPLIED line"
  local log
  log="$(cat "$TMP/gh/calls.log")"
  assert_contains "$log" "PATCH repos/o/r" "PATCH logged"
  assert_contains "$log" '{"allow_auto_merge":true}' "body has a real boolean"
  assert_not_contains "$log" "delete_branch_on_merge" "only the named item written"
}

test_apply_all_only_differing() {
  setup repo-basic
  run apply --repo o/r --dir "$TMP/settings" --all
  assert_eq 0 "$RC" "apply --all: exit 0"
  local n
  n="$(grep -c '^PATCH' "$TMP/gh/calls.log")"
  assert_eq 2 "$n" "two PATCHes for two differing items"
}

test_apply_dry_run() {
  setup repo-basic
  run apply --repo o/r --dir "$TMP/settings" --dry-run --all
  assert_eq 0 "$RC" "dry-run: exit 0"
  assert_contains "$OUT" "WOULD${TAB}PATCH repos/o/r" "WOULD line"
  assert_not_contains "$OUT" "APPLIED" "dry-run never says APPLIED"
  assert_eq "" "$(cat "$TMP/gh/calls.log")" "calls.log empty"
}

test_secret_scanning_unavailable() {
  setup repo-basic
  jq '.security_and_analysis.secret_scanning.status="disabled"' "$TMP/gh/repos__o__r.json" >"$TMP/x" && mv "$TMP/x" "$TMP/gh/repos__o__r.json"
  echo 'gh: Secret scanning is not available for this repository (HTTP 422)' >"$TMP/gh/repos__o__r.PATCH.err"
  run apply --repo o/r --dir "$TMP/settings" security.secret_scanning
  assert_eq 3 "$RC" "unavailable: exit 3"
  assert_contains "$OUT" "UNAVAILABLE${TAB}security.secret_scanning${TAB}" "UNAVAILABLE line"
  assert_contains "$OUT" "not available for this repository" "API message kept"
  assert_not_contains "$OUT" "APPLIED" "not reported as applied"
}

test_write_failure_is_failed() {
  setup repo-basic
  echo 'gh: Server Error (HTTP 500)' >"$TMP/gh/repos__o__r.PATCH.err"
  run apply --repo o/r --dir "$TMP/settings" repo.allow_auto_merge
  assert_eq 1 "$RC" "failure: exit 1"
  assert_contains "$OUT" "FAILED${TAB}repo.allow_auto_merge${TAB}" "FAILED line"
  assert_not_contains "$OUT" "APPLIED" "never APPLIED"
}

test_security_audit_and_apply() {
  setup repo-basic
  rm "$TMP/gh/repos__o__r__vulnerability-alerts.json"          # 404 => disabled
  echo '{"enabled":false,"paused":false}' >"$TMP/gh/repos__o__r__automated-security-fixes.json"
  jq 'del(.security_and_analysis.secret_scanning_push_protection)' "$TMP/gh/repos__o__r.json" >"$TMP/x" && mv "$TMP/x" "$TMP/gh/repos__o__r.json"
  run audit --repo o/r --dir "$TMP/settings"
  assert_contains "$OUT" "DIFF${TAB}security.vulnerability_alerts${TAB}live=disabled${TAB}desired=enabled" "alerts 404 = disabled"
  assert_contains "$OUT" "DIFF${TAB}security.automated_security_fixes${TAB}live=disabled${TAB}desired=enabled" "fixes disabled"
  assert_contains "$OUT" "DIFF${TAB}security.secret_scanning_push_protection${TAB}live=unknown${TAB}desired=enabled" "absent = unknown"
  assert_not_contains "$OUT" "security.secret_scanning${TAB}" "enabled secret scanning not reported"
  run apply --repo o/r --dir "$TMP/settings" security.vulnerability_alerts security.automated_security_fixes security.secret_scanning_push_protection
  assert_eq 0 "$RC" "apply security: exit 0"
  local log
  log="$(cat "$TMP/gh/calls.log")"
  assert_contains "$log" "PUT repos/o/r/vulnerability-alerts" "PUT alerts"
  assert_contains "$log" "PUT repos/o/r/automated-security-fixes" "PUT fixes"
  assert_contains "$log" '{"security_and_analysis":{"secret_scanning_push_protection":{"status":"enabled"}}}' "push protection body"
}

test_security_disable_uses_delete() {
  setup repo-clean
  jq '.security.vulnerability_alerts="disabled"' "$TMP/settings/repo.json" >"$TMP/x" && mv "$TMP/x" "$TMP/settings/repo.json"
  run apply --repo o/r --dir "$TMP/settings" security.vulnerability_alerts
  assert_contains "$(cat "$TMP/gh/calls.log")" "DELETE repos/o/r/vulnerability-alerts" "DELETE when desired disabled"
}

test_read_error_exit_2() {
  setup repo-basic
  echo 'gh: Server Error (HTTP 500)' >"$TMP/gh/repos__o__r.err"
  run audit --repo o/r --dir "$TMP/settings"
  assert_eq 2 "$RC" "read error: exit 2"
}

test_security_read_error_exit_2() {
  setup repo-basic
  echo 'gh: Server Error (HTTP 500)' >"$TMP/gh/repos__o__r__vulnerability-alerts.err"
  run audit --repo o/r --dir "$TMP/settings"
  assert_eq 2 "$RC" "security read error: exit 2"
}

test_missing_settings_dir() {
  setup repo-basic
  run audit --repo o/r --dir nope
  assert_eq 2 "$RC" "missing dir: exit 2"
  assert_contains "$ERR" "nope" "stderr names the dir"
}

test_named_items_keep_spaces() {
  setup repo-basic
  run apply --repo o/r --dir "$TMP/settings" 'labels.good first issue' repo.allow_auto_merge
  assert_eq 2 "$RC" "unknown item with spaces: exit 2"
  assert_contains "$ERR" "unknown item: labels.good first issue" "error names the full id, spaces intact"
  assert_eq "" "$(cat "$TMP/gh/calls.log")" "validation aborts before any write (valid sibling not applied)"
  run apply --repo o/r --dir "$TMP/settings" 'repo.a b' repo.allow_auto_merge
  assert_contains "$ERR" "item not in" "known area, unknown key"
  assert_contains "$ERR" "repo.a b" "full id with space reported"
}

test_bad_usage() {
  setup repo-basic
  run apply --repo o/r --dir "$TMP/settings"
  assert_eq 2 "$RC" "apply without items or --all: exit 2"
  run apply --repo o/r --dir "$TMP/settings" bogus.item
  assert_eq 2 "$RC" "unknown item: exit 2"
  run frobnicate
  assert_eq 2 "$RC" "unknown command: exit 2"
}

test_audit_reports_diffs
test_audit_default_repo_from_gh
test_audit_clean
test_declined_not_reported
test_apply_named_item
test_apply_all_only_differing
test_apply_dry_run
test_secret_scanning_unavailable
test_write_failure_is_failed
test_security_audit_and_apply
test_security_disable_uses_delete
test_read_error_exit_2
test_security_read_error_exit_2
test_missing_settings_dir
test_named_items_keep_spaces
test_bad_usage
finish
