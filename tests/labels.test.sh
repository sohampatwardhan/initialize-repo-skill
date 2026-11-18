#!/usr/bin/env bash
# Tests for the labels area of repo-settings.sh
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../skills/initialize-repo/templates/scripts/repo-settings.sh"
# shellcheck source=lib/assert.sh
. "$HERE/lib/assert.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export GH="$HERE/fake-gh/gh"
TAB="$(printf '\t')"
LIVE="repos__o__r__labels?per_page=100.json"

# setup <desired-labels-json> <live-labels-json>
setup() {
  rm -rf "$TMP/gh" "$TMP/settings"
  mkdir -p "$TMP/gh" "$TMP/settings"
  printf '%s' "$1" >"$TMP/settings/labels.json"
  printf '%s' "$2" >"$TMP/gh/$LIVE"
  echo '{"nameWithOwner":"o/r"}' >"$TMP/gh/repo-view.json"
  export FAKE_GH_DIR="$TMP/gh"
  : >"$TMP/gh/calls.log"
}

run() {
  OUT="$(bash "$SCRIPT" "$@" 2>"$TMP/stderr")"
  RC=$?
  ERR="$(cat "$TMP/stderr")"
}

DESIRED='{"labels":[
 {"name":"bug","color":"d73a4a","description":"Something isn'"'"'t working"},
 {"name":"good first issue","color":"#7057FF","description":"Good for newcomers"},
 {"name":"task","color":"1D76DB","description":"A specific piece of work"}],
 "declined":[]}'
LIVE_OK='[{"name":"bug","color":"d73a4a","description":"Something isn'"'"'t working"},
 {"name":"good first issue","color":"7057ff","description":"Good for newcomers"},
 {"name":"task","color":"1d76db","description":"A specific piece of work"},
 {"name":"wontfix","color":"ffffff","description":"This will not be worked on"}]'

test_missing_task_label() {
  setup "$DESIRED" '[{"name":"bug","color":"d73a4a","description":"Something isn'"'"'t working"},{"name":"good first issue","color":"7057ff","description":"Good for newcomers"}]'
  run audit --repo o/r --dir "$TMP/settings"
  assert_eq 1 "$RC" "missing label: exit 1"
  assert_contains "$OUT" "DIFF${TAB}labels.task${TAB}live=missing${TAB}desired=present" "task reported missing"
  assert_not_contains "$OUT" "labels.bug" "matching label not reported"
}

test_extra_live_label_ignored() {
  setup "$DESIRED" "$LIVE_OK"
  run audit --repo o/r --dir "$TMP/settings"
  assert_eq 0 "$RC" "extras and case/# differences: clean"
  assert_not_contains "$OUT" "wontfix" "extra live label not reported"
}

test_labels_apply_idempotent() {
  setup "$DESIRED" "$LIVE_OK"
  run apply --repo o/r --dir "$TMP/settings" --all
  assert_eq 0 "$RC" "apply --all clean: exit 0"
  run apply --repo o/r --dir "$TMP/settings" --all
  assert_eq 0 "$RC" "second apply: exit 0"
  assert_not_contains "$(cat "$TMP/gh/calls.log")" "POST" "no POST"
  assert_eq "" "$(cat "$TMP/gh/calls.log")" "no writes at all"
}

test_label_with_space() {
  setup "$DESIRED" '[{"name":"good first issue","color":"000000","description":"Good for newcomers"}]'
  run audit --repo o/r --dir "$TMP/settings"
  assert_contains "$OUT" "DIFF${TAB}labels.good first issue${TAB}" "id keeps spaces"
  echo '{"name":"good first issue","color":"7057ff","description":"Good for newcomers"}' >"$TMP/gh/repos__o__r__labels__good%20first%20issue.PATCH.json"
  run apply --repo o/r --dir "$TMP/settings" 'labels.good first issue'
  assert_eq 0 "$RC" "apply named label: exit 0"
  assert_contains "$OUT" "APPLIED${TAB}labels.good first issue" "APPLIED"
  local log
  log="$(cat "$TMP/gh/calls.log")"
  assert_contains "$log" "PATCH repos/o/r/labels/good%20first%20issue" "encoded PATCH endpoint"
  assert_contains "$log" '"color":"7057ff"' "color sent lowercase, no #"
  assert_not_contains "$log" "POST" "no POST for an existing label"
}

test_missing_label_posts_and_verifies() {
  setup "$DESIRED" '[]'
  # the fake returns {} for a POST: GitHub-accepted but no created label shown
  run apply --repo o/r --dir "$TMP/settings" labels.task
  assert_eq 3 "$RC" "unverified create: exit 3"
  assert_contains "$OUT" "UNAVAILABLE${TAB}labels.task" "UNAVAILABLE"
  assert_contains "$(cat "$TMP/gh/calls.log")" "POST repos/o/r/labels" "POST logged"
  echo '{"name":"task","color":"1d76db","description":"A specific piece of work"}' >"$TMP/gh/repos__o__r__labels.POST.json"
  run apply --repo o/r --dir "$TMP/settings" labels.task
  assert_eq 0 "$RC" "verified create: exit 0"
  assert_contains "$OUT" "APPLIED${TAB}labels.task" "APPLIED"
  assert_contains "$(cat "$TMP/gh/calls.log")" '"name":"task","color":"1d76db","description":"A specific piece of work"' "body has name/color/description"
}

test_description_mismatch_and_ignored_patch() {
  setup "$DESIRED" '[{"name":"bug","color":"d73a4a","description":"old"}]'
  run audit --repo o/r --dir "$TMP/settings"
  assert_contains "$OUT" "DIFF${TAB}labels.bug${TAB}" "description diff reported"
  # a PATCH answered with the unchanged label = ignored write
  echo '{"name":"bug","color":"d73a4a","description":"old"}' >"$TMP/gh/repos__o__r__labels__bug.PATCH.json"
  run apply --repo o/r --dir "$TMP/settings" labels.bug
  assert_eq 3 "$RC" "ignored PATCH: exit 3"
  assert_contains "$OUT" "UNAVAILABLE${TAB}labels.bug" "UNAVAILABLE"
}

test_apply_all_only_differing() {
  setup "$DESIRED" '[{"name":"bug","color":"d73a4a","description":"Something isn'"'"'t working"},{"name":"good first issue","color":"000000","description":"Good for newcomers"}]'
  run apply --repo o/r --dir "$TMP/settings" --all --dry-run
  assert_contains "$OUT" "WOULD${TAB}PATCH repos/o/r/labels/good%20first%20issue" "dry-run PATCH"
  assert_contains "$OUT" "WOULD${TAB}POST repos/o/r/labels" "dry-run POST"
  assert_not_contains "$OUT" "labels/bug" "matching label untouched"
  assert_eq "" "$(cat "$TMP/gh/calls.log")" "dry-run writes nothing"
}

test_declined_label() {
  setup '{"labels":[{"name":"task","color":"1D76DB","description":"x"}],"declined":[{"item":"labels.task","reason":"no"}]}' '[]'
  run audit --repo o/r --dir "$TMP/settings"
  assert_eq 0 "$RC" "declined missing label: clean"
  assert_not_contains "$OUT" "labels.task" "declined not reported"
}

test_pagination_multiple_pages() {
  setup "$DESIRED" "$LIVE_OK"
  # two JSON arrays back to back, as gh --paginate prints them
  printf '[{"name":"bug","color":"d73a4a","description":"Something isn'"'"'t working"}]\n[{"name":"good first issue","color":"7057ff","description":"Good for newcomers"},{"name":"task","color":"1d76db","description":"A specific piece of work"}]' >"$TMP/gh/$LIVE"
  run audit --repo o/r --dir "$TMP/settings"
  assert_eq 0 "$RC" "labels spread over pages are all found"
}

test_glob_and_special_names() {
  setup '{"labels":[{"name":"a*b [x]","color":"ffffff","description":""}],"declined":[]}' '[]'
  run audit --repo o/r --dir "$TMP/settings"
  assert_contains "$OUT" "DIFF${TAB}labels.a*b [x]${TAB}live=missing" "glob chars literal"
  run apply --repo o/r --dir "$TMP/settings" 'labels.a*b [x]' --dry-run
  assert_contains "$OUT" "WOULD${TAB}POST repos/o/r/labels" "applies"
}

test_invalid_config() {
  setup '{"labels":[{"name":"x","color":"red","description":""}],"declined":[]}' '[]'
  run audit --repo o/r --dir "$TMP/settings"
  assert_eq 2 "$RC" "bad color: exit 2"
  assert_contains "$ERR" "labels.x" "names the label"
}

test_read_error_exit_2() {
  setup "$DESIRED" '[]'
  echo "gh: Server Error (HTTP 500)" >"$TMP/gh/${LIVE%.json}.err"
  run audit --repo o/r --dir "$TMP/settings"
  assert_eq 2 "$RC" "read error: exit 2"
}

test_missing_task_label
test_extra_live_label_ignored
test_labels_apply_idempotent
test_label_with_space
test_missing_label_posts_and_verifies
test_description_mismatch_and_ignored_patch
test_apply_all_only_differing
test_declined_label
test_pagination_multiple_pages
test_glob_and_special_names
test_invalid_config
test_read_error_exit_2
finish
