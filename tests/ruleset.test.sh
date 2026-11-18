#!/usr/bin/env bash
# Tests for the ruleset area of repo-settings.sh (ruleset.default-branch),
# its required-check guard and the existing-protection notes.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../skills/initialize-repo/templates/scripts/repo-settings.sh"
DEFAULT_CONFIG="$HERE/../skills/initialize-repo/config/ruleset-default-branch.json"
# shellcheck source=lib/assert.sh
. "$HERE/lib/assert.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export GH="$HERE/fake-gh/gh"
TAB="$(printf '\t')"
ITEM="ruleset.default-branch"

# Fixture names (endpoint with "/" -> "__", query kept).
LIST="repos__o__r__rulesets?per_page=100.json"
RS42="repos__o__r__rulesets__42.json"
PROT="repos__o__r__branches__main__protection"
RUNS_MAIN="repos__o__r__commits__main__check-runs?per_page=100.json"
STATUS_MAIN="repos__o__r__commits__main__status.json"
PULLS="repos__o__r__pulls?state=closed&sort=updated&direction=desc&per_page=10.json"
POST_RESP="repos__o__r__rulesets.POST"
PUT_RESP="repos__o__r__rulesets__42.PUT"

# setup: default config, repo on "main", no rulesets, no checks, no protection.
setup() {
  rm -rf "$TMP/gh" "$TMP/settings"
  mkdir -p "$TMP/gh" "$TMP/settings"
  cp "$DEFAULT_CONFIG" "$TMP/settings/ruleset-default-branch.json"
  echo '{"nameWithOwner":"o/r"}' >"$TMP/gh/repo-view.json"
  echo '{"full_name":"o/r","default_branch":"main"}' >"$TMP/gh/repos__o__r.json"
  echo '[]' >"$TMP/gh/$LIST"
  export FAKE_GH_DIR="$TMP/gh"
  : >"$TMP/gh/calls.log"
}

run() {
  OUT="$(bash "$SCRIPT" "$@" 2>"$TMP/stderr")"
  RC=$?
  ERR="$(cat "$TMP/stderr")"
}

calls() { cat "$TMP/gh/calls.log"; }

# live_like_desired [jq-edit]: a GitHub-style GET response for the desired
# ruleset (id 42), with the server fields and GitHub-filled default parameters
# that the request body never mentions, then an optional jq edit.
live_like_desired() {
  jq -c '
    del(.declined)
    | . + {id: 42, source_type: "Repository", source: "o/r", node_id: "RRS_x",
           current_user_can_bypass: "pull_requests_only",
           created_at: "2026-01-01T00:00:00Z", updated_at: "2026-01-01T00:00:00Z",
           _links: {self: {href: "https://api.github.com/repos/o/r/rulesets/42"}}}
    | .rules |= map(
        if .type == "pull_request" then
          .parameters += {allowed_merge_methods: ["merge", "squash", "rebase"],
                          automatic_copilot_code_review_enabled: false}
        elif .type == "required_status_checks" then
          .parameters.required_status_checks |= map(. + {integration_id: 15368})
        else . end)
    | .rules |= reverse
    | '"${1:-.}" "$DEFAULT_CONFIG"
}

# with_live [jq-edit]: live ruleset 42 exists (listed + GET by id).
with_live() {
  echo '[{"id":42,"name":"default-branch","target":"branch","source_type":"Repository","source":"o/r","enforcement":"active"}]' >"$TMP/gh/$LIST"
  live_like_desired "${1:-.}" >"$TMP/gh/$RS42"
}

# check_runs <fixture> <names...>
check_runs() {
  local f="$1"
  shift
  jq -nc '{total_count: ($ARGS.positional | length),
           check_runs: [$ARGS.positional[] | {name: ., status: "completed", conclusion: "success"}]}' \
    --args "$@" >"$TMP/gh/$f"
}

# ok_response <fixture-base>: the write answers with the desired ruleset.
ok_response() { live_like_desired >"$TMP/gh/$1.json"; }

# ---- audit ------------------------------------------------------------------

test_ruleset_missing() {
  setup
  run audit --repo o/r --dir "$TMP/settings"
  assert_eq 1 "$RC" "missing ruleset: exit 1"
  assert_contains "$OUT" "DIFF${TAB}${ITEM}${TAB}live=missing${TAB}desired=present" "DIFF live=missing"
  assert_contains "$OUT" '  +' "proposed ruleset shown as diff lines"
  assert_contains "$OUT" '"~DEFAULT_BRANCH"' "diff shows the target"
  assert_eq "" "$(calls)" "audit writes nothing"
}

test_ruleset_differs_shows_diff() {
  setup
  with_live '.rules |= map(if .type == "pull_request" then .parameters.required_approving_review_count = 1 else . end)'
  run audit --repo o/r --dir "$TMP/settings"
  assert_eq 1 "$RC" "differing ruleset: exit 1"
  assert_contains "$OUT" "DIFF${TAB}${ITEM}${TAB}live=differs${TAB}desired=present" "DIFF live=differs"
  assert_contains "$OUT" '  -' "diff has removed lines"
  assert_contains "$OUT" '"required_approving_review_count": 1' "diff shows live approval count"
  assert_contains "$OUT" '"required_approving_review_count": 0' "diff shows desired approval count"
}

test_ruleset_github_defaults_no_diff() {
  setup
  with_live
  run audit --repo o/r --dir "$TMP/settings"
  assert_eq 0 "$RC" "GitHub-filled params, same desired values: exit 0"
  assert_not_contains "$OUT" "DIFF" "no perpetual DIFF"
}

test_ruleset_extra_live_rule_differs() {
  setup
  with_live '.rules += [{"type":"required_linear_history"}]'
  run audit --repo o/r --dir "$TMP/settings"
  assert_contains "$OUT" "live=differs" "an extra live rule is a difference"
  assert_contains "$OUT" "required_linear_history" "diff names the extra rule"
}

test_classic_protection_note() {
  setup
  with_live
  echo '{"url":"https://api.github.com/repos/o/r/branches/main/protection"}' >"$TMP/gh/$PROT.json"
  run audit --repo o/r --dir "$TMP/settings"
  assert_contains "$OUT" "NOTE${TAB}classic branch protection is enabled on main" "classic protection NOTE"
  assert_eq 0 "$RC" "a NOTE alone is not a difference"
}

test_classic_protection_absent_or_forbidden() {
  setup
  with_live
  run audit --repo o/r --dir "$TMP/settings"
  assert_not_contains "$OUT" "classic" "404: no NOTE"
  echo "gh: Upgrade to GitHub Pro or make this repository public to enable this feature. (HTTP 403)" >"$TMP/gh/$PROT.err"
  run audit --repo o/r --dir "$TMP/settings"
  assert_eq 0 "$RC" "403 on protection: not an error"
  assert_not_contains "$OUT" "classic" "403: no NOTE"
  echo "gh: Server Error (HTTP 500)" >"$TMP/gh/$PROT.err"
  run audit --repo o/r --dir "$TMP/settings"
  assert_eq 2 "$RC" "500 on protection: exit 2"
}

test_other_ruleset_note() {
  setup
  echo '[{"id":7,"name":"legacy","target":"branch","source_type":"Repository"},{"id":8,"name":"tags","target":"tag","source_type":"Repository"},{"id":42,"name":"default-branch","target":"branch","source_type":"Repository"}]' >"$TMP/gh/$LIST"
  live_like_desired >"$TMP/gh/$RS42"
  echo '{"id":7,"name":"legacy","target":"branch","conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"],"exclude":[]}},"rules":[{"type":"deletion"}]}' >"$TMP/gh/repos__o__r__rulesets__7.json"
  echo '{"id":8,"name":"tags","target":"tag","conditions":{"ref_name":{"include":["refs/tags/v*"],"exclude":[]}},"rules":[{"type":"deletion"}]}' >"$TMP/gh/repos__o__r__rulesets__8.json"
  run audit --repo o/r --dir "$TMP/settings"
  assert_contains "$OUT" "NOTE${TAB}other ruleset targets default branch: legacy" "NOTE for other ruleset"
  assert_not_contains "$OUT" "default branch: tags" "tag ruleset not noted"
  assert_not_contains "$OUT" "default branch: default-branch" "own ruleset not noted"
  assert_eq 0 "$RC" "own ruleset matches: exit 0"
}

test_rulesets_unavailable_on_plan() {
  setup
  rm -f "$TMP/gh/$LIST"
  echo "gh: Upgrade to GitHub Pro or make this repository public to enable this feature. (HTTP 403)" >"$TMP/gh/${LIST%.json}.err"
  run audit --repo o/r --dir "$TMP/settings"
  assert_eq 0 "$RC" "403 on rulesets read: not an error, not a diff"
  assert_contains "$OUT" "NOTE${TAB}${ITEM}${TAB}rulesets are not available on this plan: Upgrade to GitHub Pro" "plan NOTE"
}

test_rulesets_read_error() {
  setup
  echo "gh: Server Error (HTTP 500)" >"$TMP/gh/${LIST%.json}.err"
  run audit --repo o/r --dir "$TMP/settings"
  assert_eq 2 "$RC" "500 on rulesets read: exit 2"
}

test_declined_ruleset() {
  setup
  jq '.declined = [{"item":"ruleset.default-branch","reason":"org policy"}]' "$DEFAULT_CONFIG" >"$TMP/settings/ruleset-default-branch.json"
  run audit --repo o/r --dir "$TMP/settings"
  assert_eq 0 "$RC" "declined: clean"
  assert_not_contains "$OUT" "DIFF" "declined: no DIFF"
  run apply --repo o/r --dir "$TMP/settings" "$ITEM"
  assert_contains "$OUT" "NOTE${TAB}${ITEM} is declined (org policy); skipped" "declined named apply skipped"
  assert_eq "" "$(calls)" "declined: nothing written"
}

test_invalid_config() {
  setup
  echo '{"name":"default-branch","enforcement":"active","rules":{}}' >"$TMP/settings/ruleset-default-branch.json"
  run audit --repo o/r --dir "$TMP/settings"
  assert_eq 2 "$RC" "rules not an array: exit 2"
  assert_contains "$ERR" "rules" "names the problem"
}

# ---- apply ------------------------------------------------------------------

test_apply_ruleset_creates() {
  setup
  check_runs "$RUNS_MAIN" lint test ci-ok
  ok_response "$POST_RESP"
  run apply --repo o/r --dir "$TMP/settings" "$ITEM"
  assert_eq 0 "$RC" "create: exit 0"
  assert_contains "$OUT" "APPLIED${TAB}${ITEM}" "APPLIED"
  local log
  log="$(calls)"
  assert_contains "$log" "POST repos/o/r/rulesets" "POST logged"
  assert_not_contains "$log" "PUT" "no PUT"
  assert_contains "$log" '"name":"default-branch"' "body names the ruleset"
  assert_contains "$log" '"actor_id":5' "body has the admin bypass"
  assert_not_contains "$log" "declined" "declined stripped from the body"
}

test_apply_ruleset_updates_existing() {
  setup
  with_live '.rules |= map(if .type == "pull_request" then .parameters.required_approving_review_count = 1 else . end)'
  check_runs "$RUNS_MAIN" ci-ok
  ok_response "$PUT_RESP"
  run apply --repo o/r --dir "$TMP/settings" "$ITEM"
  assert_eq 0 "$RC" "update: exit 0"
  assert_contains "$OUT" "APPLIED${TAB}${ITEM}" "APPLIED"
  local log
  log="$(calls)"
  assert_contains "$log" "PUT repos/o/r/rulesets/42" "PUT to the existing id"
  assert_not_contains "$log" "POST" "no POST (no duplicate ruleset)"
}

test_apply_all_idempotent() {
  setup
  with_live
  check_runs "$RUNS_MAIN" ci-ok
  run apply --repo o/r --dir "$TMP/settings" --all
  assert_eq 0 "$RC" "apply --all on a matching ruleset: exit 0"
  assert_eq "" "$(calls)" "no writes"
}

test_apply_all_dry_run() {
  setup
  check_runs "$RUNS_MAIN" ci-ok
  run apply --repo o/r --dir "$TMP/settings" --all --dry-run
  assert_eq 0 "$RC" "dry-run: exit 0"
  assert_contains "$OUT" "WOULD${TAB}POST repos/o/r/rulesets" "WOULD POST"
  assert_eq "" "$(calls)" "dry-run writes nothing"
}

test_apply_write_not_reflected() {
  setup
  with_live '.enforcement = "disabled"'
  check_runs "$RUNS_MAIN" ci-ok
  # GitHub answers 200 with the unchanged ruleset
  cp "$TMP/gh/$RS42" "$TMP/gh/$PUT_RESP.json"
  run apply --repo o/r --dir "$TMP/settings" "$ITEM"
  assert_eq 3 "$RC" "unreflected write: exit 3"
  assert_contains "$OUT" "UNAVAILABLE${TAB}${ITEM}" "UNAVAILABLE"
  assert_not_contains "$OUT" "APPLIED" "never APPLIED"
}

test_guard_blocks_unseen_check() {
  setup
  check_runs "$RUNS_MAIN" lint test
  run apply --repo o/r --dir "$TMP/settings" "$ITEM"
  assert_eq 4 "$RC" "unseen check: exit 4"
  assert_contains "$OUT" "BLOCKED${TAB}${ITEM}${TAB}required check ci-ok has not run on main yet; merge the setup PR and re-run" "BLOCKED line"
  assert_eq "" "$(calls)" "BLOCKED: nothing written"
}

test_guard_blocks_without_any_checks() {
  setup
  run apply --repo o/r --dir "$TMP/settings" "$ITEM" --dry-run
  assert_eq 4 "$RC" "no check data (404s): exit 4, also in dry-run"
  assert_contains "$OUT" "BLOCKED${TAB}${ITEM}" "BLOCKED"
  assert_not_contains "$OUT" "WOULD" "no WOULD when blocked"
}

test_guard_seen_via_commit_status() {
  setup
  check_runs "$RUNS_MAIN" lint
  echo '{"state":"success","statuses":[{"context":"ci-ok","state":"success"}]}' >"$TMP/gh/$STATUS_MAIN"
  ok_response "$POST_RESP"
  run apply --repo o/r --dir "$TMP/settings" "$ITEM"
  assert_eq 0 "$RC" "context seen as a commit status: exit 0"
  assert_contains "$(calls)" "POST repos/o/r/rulesets" "POST"
}

test_guard_seen_via_merged_pr() {
  setup
  check_runs "$RUNS_MAIN" lint
  echo '[{"number":3,"merged_at":null,"head":{"sha":"aaa"}},{"number":2,"merged_at":"2026-01-02T00:00:00Z","head":{"sha":"bbb"}}]' >"$TMP/gh/$PULLS"
  check_runs "repos__o__r__commits__aaa__check-runs?per_page=100.json" lint
  check_runs "repos__o__r__commits__bbb__check-runs?per_page=100.json" ci-ok
  ok_response "$POST_RESP"
  run apply --repo o/r --dir "$TMP/settings" "$ITEM"
  assert_eq 0 "$RC" "context seen on the last merged PR head: exit 0"
  assert_contains "$OUT" "APPLIED${TAB}${ITEM}" "APPLIED"
}

test_guard_read_error() {
  setup
  echo "gh: Server Error (HTTP 500)" >"$TMP/gh/${RUNS_MAIN%.json}.err"
  run apply --repo o/r --dir "$TMP/settings" "$ITEM"
  assert_eq 2 "$RC" "guard cannot read check runs: exit 2"
  assert_eq "" "$(calls)" "nothing written"
}

test_guard_override() {
  setup
  ok_response "$POST_RESP"
  run apply --repo o/r --dir "$TMP/settings" --allow-unseen-checks "$ITEM"
  assert_eq 0 "$RC" "--allow-unseen-checks: exit 0"
  assert_not_contains "$OUT" "BLOCKED" "no BLOCKED"
  assert_contains "$(calls)" "POST repos/o/r/rulesets" "POST happens"
}

test_allow_unseen_checks_rejected_by_audit() {
  setup
  run audit --repo o/r --dir "$TMP/settings" --allow-unseen-checks
  assert_eq 2 "$RC" "audit --allow-unseen-checks: exit 2"
}

test_private_free_plan_unavailable() {
  setup
  rm -f "$TMP/gh/$LIST"
  echo "gh: Upgrade to GitHub Pro or make this repository public to enable this feature. (HTTP 403)" >"$TMP/gh/${LIST%.json}.err"
  echo "gh: Upgrade to GitHub Pro or make this repository public to enable this feature. (HTTP 403)" >"$TMP/gh/$POST_RESP.err"
  check_runs "$RUNS_MAIN" ci-ok
  run apply --repo o/r --dir "$TMP/settings" "$ITEM"
  assert_eq 3 "$RC" "plan limit: exit 3"
  assert_contains "$OUT" "UNAVAILABLE${TAB}${ITEM}${TAB}Upgrade to GitHub Pro" "UNAVAILABLE with message"
  assert_contains "$(calls)" "POST repos/o/r/rulesets" "POST attempted"
}

test_exit_precedence() {
  setup
  cp "$HERE/../skills/initialize-repo/config/repo.json" "$TMP/settings/repo.json"
  echo '{"full_name":"o/r","default_branch":"main","allow_auto_merge":false}' >"$TMP/gh/repos__o__r.json"
  # PATCH answered with the unchanged repo -> UNAVAILABLE; ruleset BLOCKED
  cp "$TMP/gh/repos__o__r.json" "$TMP/gh/repos__o__r.PATCH.json"
  run apply --repo o/r --dir "$TMP/settings" repo.allow_auto_merge "$ITEM"
  assert_contains "$OUT" "UNAVAILABLE${TAB}repo.allow_auto_merge" "repo item UNAVAILABLE"
  assert_contains "$OUT" "BLOCKED${TAB}${ITEM}" "ruleset BLOCKED"
  assert_eq 4 "$RC" "BLOCKED beats UNAVAILABLE: exit 4"
  rm -f "$TMP/gh/repos__o__r.PATCH.json"
  echo "gh: Server Error (HTTP 500)" >"$TMP/gh/repos__o__r.PATCH.err"
  run apply --repo o/r --dir "$TMP/settings" repo.allow_auto_merge "$ITEM"
  assert_contains "$OUT" "FAILED${TAB}repo.allow_auto_merge" "repo item FAILED"
  assert_eq 1 "$RC" "FAILED beats BLOCKED: exit 1"
}

test_ruleset_missing
test_ruleset_differs_shows_diff
test_ruleset_github_defaults_no_diff
test_ruleset_extra_live_rule_differs
test_classic_protection_note
test_classic_protection_absent_or_forbidden
test_other_ruleset_note
test_rulesets_unavailable_on_plan
test_rulesets_read_error
test_declined_ruleset
test_invalid_config
test_apply_ruleset_creates
test_apply_ruleset_updates_existing
test_apply_all_idempotent
test_apply_all_dry_run
test_apply_write_not_reflected
test_guard_blocks_unseen_check
test_guard_blocks_without_any_checks
test_guard_seen_via_commit_status
test_guard_seen_via_merged_pr
test_guard_read_error
test_guard_override
test_allow_unseen_checks_rejected_by_audit
test_private_free_plan_unavailable
test_exit_precedence
finish
