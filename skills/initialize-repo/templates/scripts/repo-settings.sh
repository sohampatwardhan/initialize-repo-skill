#!/usr/bin/env bash
# repo-settings.sh: keep a GitHub repo's settings in sync with committed JSON.
#
#   repo-settings.sh <audit|apply> [--repo OWNER/NAME] [--dir DIR] [--dry-run]
#                    [--allow-unseen-checks] [--all | ITEM ...]
#
# Desired state lives in DIR (default .github/settings). Items are named
# "<area>.<key>", e.g. repo.allow_auto_merge, security.secret_scanning.
#
# audit  prints "DIFF<TAB>item<TAB>live=..<TAB>desired=.." per difference.
#        Exit 0 no differences, 1 differences, 2 error.
# apply  writes the named items (or every differing item with --all).
#        Prints APPLIED / UNAVAILABLE / FAILED per item; with --dry-run prints
#        "WOULD<TAB>METHOD endpoint" and calls nothing.
#        Prints BLOCKED when a guard holds an item back (the ruleset area's
#        required-check guard; --allow-unseen-checks skips it).
#        Exit 0 all applied; otherwise the first that applies of: 2 error,
#        1 any FAILED, 4 any BLOCKED, 3 any UNAVAILABLE.
#
# Adding an area <a> (see the "area hook contract" below): define the hook
# functions and append <a> to AREAS. The dispatcher itself does not change.
#
# Area hook contract (all hooks are plain functions named <hook>_<area>):
#   config_file_<a>      print the config file name inside --dir (e.g. repo.json).
#                        An area whose file is absent is skipped entirely; if no
#                        area's file exists the script exits 2 naming --dir.
#   validate_<a>         (optional) check the config; on a problem call
#                        `die "<msg>"` (exit 2). Runs before any read or write.
#   declined_<a>         print declined entries of this area's file, one per
#                        line as "<item-id><TAB><reason>" (nothing if none).
#   has_<a> <item>       return 0 if the item id is defined in the area config.
#   audit_<a>            for each differing, non-declined item call
#                        `emit_diff <item> <live> <desired>`; on read errors call
#                        `soft_error <msg>` (exit 2 at the end).
#   apply_<a> <item>     write ONE item via `write_item` (see its comment).
# Item ids are "<a>.<name>"; the area is the text before the first dot. The
# name may contain spaces or glob characters; ids are always passed quoted.
#
# Needs bash 3.2+, git, gh, jq. gh is called as "${GH:-gh}".
set -u

AREAS="repo security labels ruleset"

MODE=""
REPO=""
DIR=".github/settings"
DRY_RUN=0
ALL=0
ITEMS=""
QUIET=0          # 1: audit functions record diffs without printing
DIFF_ITEMS=""    # newline-separated item ids that differ
HAD_ERROR=0
FAILED_N=0
UNAVAIL_N=0
BLOCKED_N=0      # items held back by a guard (exit 4)
ALLOW_UNSEEN=0   # --allow-unseen-checks: skip the ruleset required-check guard
TAB="$(printf '\t')"
NL='
'
CONFIG=""
DECLINED=""   # lines of "<item><TAB><reason>" from every active area
ACTIVE_AREAS=""
REPO_JSON=""
GH_OUT=""
GH_ERR=""
SEC_LIVE=""
ERRF=""

usage() {
  cat >&2 <<'USAGE'
usage: repo-settings.sh <audit|apply> [--repo OWNER/NAME] [--dir DIR] [--dry-run] [--allow-unseen-checks] [--all | ITEM ...]
USAGE
  exit 2
}

die() {
  printf 'repo-settings.sh: %s\n' "$*" >&2
  exit 2
}

# soft_error <msg>: report an error, keep going, exit 2 at the end.
soft_error() {
  printf 'repo-settings.sh: %s\n' "$*" >&2
  HAD_ERROR=1
}

one_line() { printf '%s' "$1" | tr '\t\r\n' '   '; }

# ---- gh helpers -------------------------------------------------------------

# gh_get <endpoint>: sets GH_OUT / GH_ERR, returns gh's exit status.
gh_get() {
  GH_OUT="$("${GH:-gh}" api "$1" 2>"$ERRF")"
  local rc=$?
  GH_ERR="$(cat "$ERRF")"
  return $rc
}

# gh_msg: GH_ERR without the "gh: " prefix and the "(HTTP nnn)" suffix.
gh_msg() {
  local m
  m="$(one_line "$GH_ERR")"
  m="${m#gh: }"
  printf '%s' "$m"
}

# write_item <item> <METHOD> <endpoint> [json-body [jq-filter expected key]]
# Performs (or, with --dry-run, announces) one write and reports its outcome.
# With a jq-filter (using $k, bound to key) the response is checked after a
# successful call: GitHub answers 200 to a PATCH that silently ignored a field,
# so a response whose value is not `expected` is UNAVAILABLE, never APPLIED.
write_item() {
  local item="$1" method="$2" endpoint="$3" body="${4:-}" vfilter="${5:-}" want="${6:-}" key="${7:-}" rc reason got
  if [ "$DRY_RUN" -eq 1 ]; then
    printf 'WOULD%s%s %s\n' "$TAB" "$method" "$endpoint"
    return 0
  fi
  if [ -n "$body" ]; then
    GH_OUT="$(printf '%s' "$body" | "${GH:-gh}" api -X "$method" "$endpoint" --input - 2>"$ERRF")"
  else
    GH_OUT="$("${GH:-gh}" api -X "$method" "$endpoint" 2>"$ERRF")"
  fi
  rc=$?
  GH_ERR="$(cat "$ERRF")"
  if [ $rc -eq 0 ]; then
    if [ -n "$vfilter" ]; then
      got="$(printf '%s' "$GH_OUT" | jq -r --arg k "$key" "($vfilter) | if . == null then \"unknown\" else tostring end" 2>/dev/null)"
      if [ "$got" != "$want" ]; then
        UNAVAIL_N=$((UNAVAIL_N + 1))
        printf 'UNAVAILABLE%s%s%sGitHub accepted the request but did not change %s (now %s)\n' "$TAB" "$item" "$TAB" "$key" "${got:-unknown}"
        return 1
      fi
    fi
    printf 'APPLIED%s%s\n' "$TAB" "$item"
    return 0
  fi
  reason="$(gh_msg)"
  [ -n "$reason" ] || reason="gh exited $rc"
  case "$GH_ERR" in
    *"(HTTP 403)"* | *"(HTTP 422)"*)
      UNAVAIL_N=$((UNAVAIL_N + 1))
      printf 'UNAVAILABLE%s%s%s%s\n' "$TAB" "$item" "$TAB" "$reason"
      ;;
    *)
      FAILED_N=$((FAILED_N + 1))
      printf 'FAILED%s%s%s%s\n' "$TAB" "$item" "$TAB" "$reason"
      ;;
  esac
  return 1
}

# ---- config -----------------------------------------------------------------

# desired <area> <key>: prints the desired value (booleans as true/false).
desired() {
  jq -r --arg a "$1" --arg k "$2" '.[$a][$k] | tostring' "$CONFIG"
}

# config_keys <area>: prints the keys configured for an area.
config_keys() {
  jq -r --arg a "$1" '(.[$a] // {}) | keys_unsorted[]' "$CONFIG"
}

is_declined() {
  case "$NL$DECLINED" in
    *"$NL$1$TAB"*) return 0 ;;
  esac
  return 1
}

# declined_reason <item>
declined_reason() {
  printf '%s\n' "$DECLINED" | while IFS="$TAB" read -r id reason; do
    if [ "$id" = "$1" ]; then printf '%s' "$reason"; break; fi
  done
}

# emit_diff <item> <live> <desired>
emit_diff() {
  DIFF_ITEMS="$DIFF_ITEMS$1$NL"
  [ "$QUIET" -eq 1 ] || printf 'DIFF%s%s%slive=%s%sdesired=%s\n' "$TAB" "$1" "$TAB" "$2" "$TAB" "$3"
}

# check_item <item> <live> <desired>: skips declined items, emits a diff.
check_item() {
  is_declined "$1" && return 0
  [ "$2" = "$3" ] || emit_diff "$1" "$2" "$3"
  return 0
}

# load_repo_json: fetch repos/{r} once; returns 1 (after reporting) on error.
load_repo_json() {
  [ -n "$REPO_JSON" ] && return 0
  if ! gh_get "repos/$REPO"; then
    soft_error "cannot read repos/$REPO: $(gh_msg)"
    return 1
  fi
  REPO_JSON="$GH_OUT"
  return 0
}

# ---- area: repo -------------------------------------------------------------

REPO_KEYS="allow_squash_merge allow_merge_commit allow_rebase_merge delete_branch_on_merge allow_auto_merge has_issues has_wiki"
SECURITY_KEYS="vulnerability_alerts automated_security_fixes secret_scanning secret_scanning_push_protection"

# check_known_keys <area> <known-keys>: die on a key the script cannot apply.
check_known_keys() {
  local key
  for key in $(config_keys "$1"); do
    case " $2 " in
      *" $key "*) ;;
      *) die "unknown key $1.$key in $CONFIG (known: $2)" ;;
    esac
  done
}

config_file_repo() { echo repo.json; }
validate_repo() { check_known_keys repo "$REPO_KEYS"; }
declined_repo() { jq -r '.declined[]? | [.item, (.reason // "")] | join("\t")' "$CONFIG"; }
has_repo() { jq -e --arg k "${1#repo.}" '(.repo // {}) | has($k)' "$CONFIG" >/dev/null 2>&1; }

audit_repo() {
  local key live want
  load_repo_json || return 0
  for key in $(config_keys repo); do
    want="$(desired repo "$key")"
    live="$(printf '%s' "$REPO_JSON" | jq -r --arg k "$key" 'if .[$k] == null then "unknown" else (.[$k] | tostring) end')"
    check_item "repo.$key" "$live" "$want"
  done
}

apply_repo() {
  local item="$1" key want body
  key="${item#repo.}"
  want="$(desired repo "$key")"
  case "$want" in
    true | false) ;;
    *) soft_error "$item: desired value must be true or false (got '$want')"; return 0 ;;
  esac
  body="$(jq -nc --arg k "$key" --argjson v "$want" '{($k): $v}')"
  # shellcheck disable=SC2016 # $k is a jq variable
  write_item "$item" PATCH "repos/$REPO" "$body" '.[$k]' "$want" "$key"
}

# ---- area: security ---------------------------------------------------------

config_file_security() { echo repo.json; }
validate_security() { check_known_keys security "$SECURITY_KEYS"; }
declined_security() { :; } # shares repo.json with the repo area; declined_repo lists all
has_security() { jq -e --arg k "${1#security.}" '(.security // {}) | has($k)' "$CONFIG" >/dev/null 2>&1; }

# security_live <key>: sets SEC_LIVE to enabled|disabled|unknown; returns 1 on a read error.
security_live() {
  local key="$1" v
  case "$key" in
    vulnerability_alerts)
      # 204 (empty body) when enabled, 404 when disabled.
      if gh_get "repos/$REPO/vulnerability-alerts"; then
        SEC_LIVE=enabled
      else
        case "$GH_ERR" in
          *"(HTTP 404)"*) SEC_LIVE=disabled ;;
          *) soft_error "cannot read vulnerability-alerts: $(gh_msg)"; return 1 ;;
        esac
      fi
      ;;
    automated_security_fixes)
      # 200 {"enabled":bool,"paused":bool}; 404 when alerts are off.
      if gh_get "repos/$REPO/automated-security-fixes"; then
        v="$(printf '%s' "$GH_OUT" | jq -r 'if .enabled == true then "enabled" elif .enabled == false then "disabled" else "unknown" end')"
        SEC_LIVE="${v:-unknown}"
      else
        case "$GH_ERR" in
          *"(HTTP 404)"*) SEC_LIVE=disabled ;;
          *) soft_error "cannot read automated-security-fixes: $(gh_msg)"; return 1 ;;
        esac
      fi
      ;;
    secret_scanning | secret_scanning_push_protection)
      load_repo_json || return 1
      SEC_LIVE="$(printf '%s' "$REPO_JSON" | jq -r --arg k "$key" '.security_and_analysis[$k].status // "unknown"')"
      ;;
    *)
      SEC_LIVE=unknown
      ;;
  esac
}

audit_security() {
  local key
  for key in $(config_keys security); do
    is_declined "security.$key" && continue
    security_live "$key" || continue
    check_item "security.$key" "$SEC_LIVE" "$(desired security "$key")"
  done
}

apply_security() {
  local item="$1" key want body method
  key="${item#security.}"
  want="$(desired security "$key")"
  case "$want" in
    enabled | disabled) ;;
    *) soft_error "$item: desired value must be enabled or disabled (got '$want')"; return 0 ;;
  esac
  case "$key" in
    vulnerability_alerts | automated_security_fixes)
      method=PUT
      [ "$want" = enabled ] || method=DELETE
      write_item "$item" "$method" "repos/$REPO/${key//_/-}"
      ;;
    secret_scanning | secret_scanning_push_protection)
      body="$(jq -nc --arg k "$key" --arg s "$want" '{security_and_analysis: {($k): {status: $s}}}')"
      # shellcheck disable=SC2016 # $k is a jq variable
      write_item "$item" PATCH "repos/$REPO" "$body" '.security_and_analysis[$k].status' "$want" "$key"
      ;;
    *)
      soft_error "$item: unknown security setting"
      ;;
  esac
}

# ---- area: labels -----------------------------------------------------------
# labels.json: {"labels":[{"name","color","description"}],"declined":[...]}.
# Items are "labels.<name>". Extra live labels are left alone; none is deleted.

LABELS_LIVE=""   # JSON array of every live label (loaded once)
LV_COLOR=""
LV_DESC=""

config_file_labels() { echo labels.json; }

validate_labels() {
  local f="$DIR/labels.json" bad
  jq -e '(.labels | type) == "array"' "$f" >/dev/null 2>&1 || die "$f: \"labels\" must be an array"
  bad="$(jq -r '.labels[] | select((.name | type) != "string" or (.name | test("^[^\u0000-\u001f]+$") | not)) | tojson' "$f" | head -n 1)"
  [ -z "$bad" ] || die "$f: label without a usable name: $bad"
  bad="$(jq -r '.labels[] | select((.color | type) != "string" or (.color | test("^#?[0-9a-fA-F]{6}$") | not)) | "labels." + .name + " (color " + (.color | tojson) + ")"' "$f" | head -n 1)"
  [ -z "$bad" ] || die "$f: color must be 6 hex digits: $bad"
  bad="$(jq -r '.labels[] | select((.description // "") | type != "string") | "labels." + .name' "$f" | head -n 1)"
  [ -z "$bad" ] || die "$f: description must be a string: $bad"
  bad="$(jq -r '[.labels[].name | ascii_downcase] | group_by(.) | map(select(length > 1)) | first // empty | .[0]' "$f")"
  [ -z "$bad" ] || die "$f: duplicate label name (names are case-insensitive): $bad"
}

declined_labels() { jq -r '.declined[]? | [.item, (.reason // "")] | join("\t")' "$DIR/labels.json"; }

has_labels() {
  jq -e --arg n "${1#labels.}" '.labels | any(.name == $n)' "$DIR/labels.json" >/dev/null 2>&1
}

# load_labels: fetch every live label (all pages) once; 1 after reporting on error.
load_labels() {
  [ -n "$LABELS_LIVE" ] && return 0
  local raw
  if ! raw="$("${GH:-gh}" api --paginate "repos/$REPO/labels?per_page=100" 2>"$ERRF")"; then
    GH_ERR="$(cat "$ERRF")"
    soft_error "cannot read repos/$REPO/labels: $(gh_msg)"
    return 1
  fi
  LABELS_LIVE="$(printf '%s' "$raw" | jq -sc 'add // []' 2>/dev/null)"
  if [ -z "$LABELS_LIVE" ]; then
    soft_error "cannot parse the label list from repos/$REPO/labels"
    return 1
  fi
}

# label_field <name> <field>: desired value; color is lowercase without "#".
label_field() {
  jq -r --arg n "$1" --arg f "$2" '.labels[] | select(.name == $n)
    | if $f == "color" then (.color | ltrimstr("#") | ascii_downcase) else (.description // "") end' "$DIR/labels.json"
}

# live_label <name>: returns 1 if absent; else sets LV_COLOR / LV_DESC.
live_label() {
  local lj
  lj="$(printf '%s' "$LABELS_LIVE" | jq -c --arg n "$1" '[.[] | select((.name | ascii_downcase) == ($n | ascii_downcase))] | first // empty')"
  [ -n "$lj" ] || return 1
  LV_COLOR="$(printf '%s' "$lj" | jq -r '.color | ascii_downcase')"
  LV_DESC="$(printf '%s' "$lj" | jq -r '.description // ""')"
}

audit_labels() {
  local name want_c want_d
  load_labels || return 0
  while IFS= read -r name <&4; do
    [ -n "$name" ] || continue
    is_declined "labels.$name" && continue
    want_c="$(label_field "$name" color)"
    want_d="$(label_field "$name" description)"
    if ! live_label "$name"; then
      emit_diff "labels.$name" missing present
    elif [ "$LV_COLOR" != "$want_c" ] || [ "$LV_DESC" != "$want_d" ]; then
      emit_diff "labels.$name" "color=$LV_COLOR description=$(one_line "$LV_DESC")" "color=$want_c description=$(one_line "$want_d")"
    fi
  done 4<<EOF_LABELS
$(jq -r '.labels[].name' "$DIR/labels.json")
EOF_LABELS
}

apply_labels() {
  local item="$1" name want_c want_d body enc
  name="${item#labels.}"
  load_labels || return 0
  want_c="$(label_field "$name" color)"
  want_d="$(label_field "$name" description)"
  # The response must echo the color and description we asked for.
  # shellcheck disable=SC2016 # jq program
  local vf='((.color // "" | ascii_downcase) + "|" + (.description // ""))'
  if live_label "$name"; then
    body="$(jq -nc --arg c "$want_c" --arg d "$want_d" '{color: $c, description: $d}')"
    enc="$(jq -rn --arg s "$name" '$s | @uri')"
    write_item "$item" PATCH "repos/$REPO/labels/$enc" "$body" "$vf" "$want_c|$want_d" "color/description"
  else
    body="$(jq -nc --arg n "$name" --arg c "$want_c" --arg d "$want_d" '{name: $n, color: $c, description: $d}')"
    write_item "$item" POST "repos/$REPO/labels" "$body" "$vf" "$want_c|$want_d" "color/description"
  fi
}

# ---- area: ruleset ----------------------------------------------------------
# ruleset-default-branch.json: a repository-ruleset request body (name, target,
# enforcement, conditions, bypass_actors, rules) plus an optional top-level
# "declined" that is never sent. One item: "ruleset.<name>".
#
# Comparison: both sides are normalized to {enforcement, conditions,
# bypass_actors, rules (sorted by type)} and compared with jq -S. GitHub fills
# default parameters into the rules it returns, so for each rule type the live
# parameters are projected onto the parameter keys the desired rule names
# (and required-status-check entries onto the keys desired entries use).
# Parameters the config omits are therefore not compared.
#
# apply runs a guard first: every required status check context must already
# have run (check run or commit status) on the default branch head or on the
# head of the most recently merged PR; otherwise BLOCKED (exit 4), unless
# --allow-unseen-checks.

RS_FILE="ruleset-default-branch.json"
RS_DESIRED=""      # request body: the config without "declined" (compact JSON)
RS_LOADED=0
RS_LIST=""         # JSON array from the rulesets list (all pages)
RS_PLAN_MSG=""     # set when rulesets cannot be read on this plan (HTTP 403)
RS_LIVE_LOADED=0
RS_ID=""           # id of the live ruleset with the configured name ("" if none)
RS_LIVE=""         # its full JSON (GET by id)
RS_BRANCH=""       # default branch name
RS_SEEN=""         # newline-separated check names / status contexts seen

# jq definitions: norm($d) normalizes a ruleset against the desired one ($d).
# shellcheck disable=SC2016 # jq program
RS_JQ='
def proj($dp):
  if type == "object" and ($dp | type) == "object" then
    with_entries(select(.key as $k | $dp | has($k)))
    | if (.required_status_checks | type) == "array" and ($dp.required_status_checks | type) == "array" then
        ([$dp.required_status_checks[] | objects | keys[]] | unique) as $ck
        | .required_status_checks |= map(if type == "object" then with_entries(select(.key as $k | $ck | index($k))) else . end)
      else . end
  else . end;
def sortchecks:
  if (.required_status_checks | type) == "array" then .required_status_checks |= sort_by(.context) else . end;
def norm($d):
  {
    enforcement: .enforcement,
    conditions: {ref_name: {include: ((.conditions.ref_name.include // []) | sort),
                            exclude: ((.conditions.ref_name.exclude // []) | sort)}},
    bypass_actors: ((.bypass_actors // [])
      | map({actor_id, actor_type, bypass_mode: (.bypass_mode // "always")})
      | sort_by(.actor_type, .actor_id)),
    rules: ((.rules // []) | map(
      . as $r
      | ([($d.rules // [])[] | select(.type == $r.type)] | first) as $dr
      | {type: .type}
        + ((if $dr == null then (.parameters // {}) else ((.parameters // {}) | proj($dr.parameters // {})) end)
           | sortchecks
           | if . == {} then {} else {parameters: .} end)
    ) | sort_by(.type))
  };
'

config_file_ruleset() { echo "$RS_FILE"; }

rs_name() { jq -r '.name' "$DIR/$RS_FILE"; }

validate_ruleset() {
  local f="$DIR/$RS_FILE"
  jq -e '(.name | type) == "string" and (.name | test("^[^\u0000-\u001f]+$"))' "$f" >/dev/null 2>&1 \
    || die "$f: \"name\" must be a non-empty string"
  jq -e '(.enforcement | type) == "string"' "$f" >/dev/null 2>&1 || die "$f: \"enforcement\" must be a string"
  jq -e '(.rules | type) == "array" and all(.rules[]; type == "object" and (.type | type) == "string")' "$f" >/dev/null 2>&1 \
    || die "$f: \"rules\" must be an array of objects with a string \"type\""
  jq -e '[.rules[].type] | length == (unique | length)' "$f" >/dev/null 2>&1 \
    || die "$f: each rule type may appear only once in \"rules\""
  jq -e 'all(.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks[]?;
             (.context | type) == "string" and (.context | test("^[^\u0000-\u001f]+$")))' "$f" >/dev/null 2>&1 \
    || die "$f: every required status check needs a string \"context\""
  jq -e '(.declined // []) | type == "array"' "$f" >/dev/null 2>&1 || die "$f: \"declined\" must be an array"
  RS_DESIRED="$(jq -c 'del(.declined)' "$f")"
}

declined_ruleset() { jq -r '.declined[]? | [.item, (.reason // "")] | join("\t")' "$DIR/$RS_FILE"; }

has_ruleset() { [ "$1" = "ruleset.$(rs_name)" ]; }

# rs_note <text>: print a NOTE line (suppressed in the quiet pre-audit of --all).
rs_note() { [ "$QUIET" -eq 1 ] || printf 'NOTE%s%s\n' "$TAB" "$1"; }

uri() { jq -rn --arg s "$1" '$s | @uri'; }

# rs_norm <ruleset-json>: normalized, key-sorted JSON (projected onto desired).
rs_norm() {
  printf '%s' "$1" | jq -S --argjson d "$RS_DESIRED" "$RS_JQ norm(\$d)"
}

# load_rulesets: list every ruleset (all pages) once. A 403 means the plan has
# no rulesets: RS_PLAN_MSG is set and the list is empty. 1 after reporting.
load_rulesets() {
  [ "$RS_LOADED" -eq 1 ] && return 0
  local raw
  if raw="$("${GH:-gh}" api --paginate "repos/$REPO/rulesets?per_page=100" 2>"$ERRF")"; then
    RS_LIST="$(printf '%s' "$raw" | jq -sc 'add // []' 2>/dev/null)"
    if [ -z "$RS_LIST" ]; then
      soft_error "cannot parse the ruleset list from repos/$REPO/rulesets"
      return 1
    fi
  else
    GH_ERR="$(cat "$ERRF")"
    case "$GH_ERR" in
      *"(HTTP 403)"*) RS_LIST='[]'; RS_PLAN_MSG="$(gh_msg)" ;;
      *) soft_error "cannot read repos/$REPO/rulesets: $(gh_msg)"; return 1 ;;
    esac
  fi
  RS_LOADED=1
}

# rs_load_live: find the configured ruleset by name and GET it by id once.
# Only the repository's own rulesets count (not ones inherited from the org).
rs_load_live() {
  [ "$RS_LIVE_LOADED" -eq 1 ] && return 0
  load_rulesets || return 1
  RS_ID="$(printf '%s' "$RS_LIST" | jq -r --arg n "$(rs_name)" \
    '[.[] | select(.name == $n and (.source_type // "Repository") == "Repository")] | first | .id // empty')"
  if [ -n "$RS_ID" ]; then
    if ! gh_get "repos/$REPO/rulesets/$RS_ID"; then
      soft_error "cannot read repos/$REPO/rulesets/$RS_ID: $(gh_msg)"
      return 1
    fi
    RS_LIVE="$GH_OUT"
  fi
  RS_LIVE_LOADED=1
}

# rs_default_branch: set RS_BRANCH; 1 after reporting.
rs_default_branch() {
  [ -n "$RS_BRANCH" ] && return 0
  load_repo_json || return 1
  RS_BRANCH="$(printf '%s' "$REPO_JSON" | jq -r '.default_branch // empty')"
  if [ -z "$RS_BRANCH" ]; then
    soft_error "cannot determine the default branch of $REPO"
    return 1
  fi
}

# rs_other_notes: NOTE each other branch ruleset that targets the default branch.
rs_other_notes() {
  local id name
  while IFS="$TAB" read -r id name <&5; do
    [ -n "$id" ] || continue
    if ! gh_get "repos/$REPO/rulesets/$id"; then
      case "$GH_ERR" in
        *"(HTTP 403)"* | *"(HTTP 404)"*) continue ;;
        *) soft_error "cannot read repos/$REPO/rulesets/$id: $(gh_msg)"; continue ;;
      esac
    fi
    if printf '%s' "$GH_OUT" | jq -e --arg b "refs/heads/$RS_BRANCH" \
      '(.conditions.ref_name.include // []) | any(. == "~DEFAULT_BRANCH" or . == $b)' >/dev/null 2>&1; then
      rs_note "other ruleset targets default branch: $(one_line "$name")"
    fi
  done 5<<EOF_RS
$(printf '%s' "$RS_LIST" | jq -r --arg own "$RS_ID" '.[] | select((.id | tostring) != $own and (.target // "branch") == "branch") | [(.id | tostring), .name] | @tsv')
EOF_RS
}

# rs_classic_note: NOTE when classic branch protection is on the default branch.
rs_classic_note() {
  if gh_get "repos/$REPO/branches/$(uri "$RS_BRANCH")/protection"; then
    rs_note "classic branch protection is enabled on $RS_BRANCH"
    return 0
  fi
  case "$GH_ERR" in
    *"(HTTP 404)"* | *"(HTTP 403)"*) ;; # none, or not available on this plan
    *) soft_error "cannot read branch protection for $RS_BRANCH: $(gh_msg)" ;;
  esac
}

# rs_print_diff <live-normalized|""> <desired-normalized>: unified diff, each
# line prefixed with two spaces (git is a runtime dependency; diff(1) is not).
rs_print_diff() {
  local a b
  a="$(mktemp)" || return 0
  b="$(mktemp)" || { rm -f "$a"; return 0; }
  [ -z "$1" ] || printf '%s\n' "$1" >"$a"
  printf '%s\n' "$2" >"$b"
  git --no-pager diff --no-index --no-color --no-ext-diff "$a" "$b" 2>/dev/null | sed -n '/^@@/,$s/^/  /p'
  rm -f "$a" "$b"
}

audit_ruleset() {
  local item live_n want_n
  item="ruleset.$(rs_name)"
  is_declined "$item" && return 0
  rs_default_branch || return 0
  rs_load_live || return 0
  want_n="$(rs_norm "$RS_DESIRED")"
  if [ -n "$RS_PLAN_MSG" ]; then
    rs_note "$item${TAB}rulesets are not available on this plan: $RS_PLAN_MSG"
  elif [ -z "$RS_ID" ]; then
    emit_diff "$item" missing present
    [ "$QUIET" -eq 1 ] || rs_print_diff "" "$want_n"
  else
    live_n="$(rs_norm "$RS_LIVE")"
    if [ "$live_n" != "$want_n" ]; then
      emit_diff "$item" differs present
      [ "$QUIET" -eq 1 ] || rs_print_diff "$live_n" "$want_n"
    fi
  fi
  rs_other_notes
  rs_classic_note
}

# rs_collect_checks <ref>: add the check-run names and commit-status contexts
# of <ref> to RS_SEEN. A missing ref (404/409/422) adds nothing. 1 on error.
rs_collect_checks() {
  local ref="$1" raw
  if raw="$("${GH:-gh}" api --paginate "repos/$REPO/commits/$ref/check-runs?per_page=100" 2>"$ERRF")"; then
    RS_SEEN="$RS_SEEN$(printf '%s' "$raw" | jq -rs '.[].check_runs[]?.name' 2>/dev/null)$NL"
  else
    GH_ERR="$(cat "$ERRF")"
    case "$GH_ERR" in
      *"(HTTP 404)"* | *"(HTTP 409)"* | *"(HTTP 422)"*) ;;
      *) soft_error "cannot read check runs for $ref: $(gh_msg)"; return 1 ;;
    esac
  fi
  if gh_get "repos/$REPO/commits/$ref/status"; then
    RS_SEEN="$RS_SEEN$(printf '%s' "$GH_OUT" | jq -r '.statuses[]?.context' 2>/dev/null)$NL"
  else
    case "$GH_ERR" in
      *"(HTTP 404)"* | *"(HTTP 409)"* | *"(HTTP 422)"*) ;;
      *) soft_error "cannot read commit statuses for $ref: $(gh_msg)"; return 1 ;;
    esac
  fi
}

# rs_unseen <contexts>: print the contexts (one per line) not in RS_SEEN.
rs_unseen() {
  local ctx
  while IFS= read -r ctx; do
    [ -n "$ctx" ] || continue
    case "$NL$RS_SEEN$NL" in
      *"$NL$ctx$NL"*) ;;
      *) printf '%s\n' "$ctx" ;;
    esac
  done <<EOF_CTX
$1
EOF_CTX
}

# rs_guard <item>: 0 if every required check has run; else prints BLOCKED (or
# reports a read error) and returns 1.
rs_guard() {
  local item="$1" ctxs unseen sha ctx
  ctxs="$(printf '%s' "$RS_DESIRED" | jq -r '.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks[]?.context')"
  [ -n "$ctxs" ] || return 0
  rs_default_branch || return 1
  RS_SEEN=""
  rs_collect_checks "$(uri "$RS_BRANCH")" || return 1
  unseen="$(rs_unseen "$ctxs")"
  if [ -n "$unseen" ]; then
    if gh_get "repos/$REPO/pulls?state=closed&sort=updated&direction=desc&per_page=10"; then
      sha="$(printf '%s' "$GH_OUT" | jq -r '[.[]? | select(.merged_at != null)] | first | .head.sha // empty' 2>/dev/null)"
      if [ -n "$sha" ]; then
        rs_collect_checks "$sha" || return 1
        unseen="$(rs_unseen "$ctxs")"
      fi
    else
      case "$GH_ERR" in
        *"(HTTP 404)"*) ;;
        *) soft_error "cannot read recent pull requests: $(gh_msg)"; return 1 ;;
      esac
    fi
  fi
  [ -n "$unseen" ] || return 0
  while IFS= read -r ctx; do
    [ -n "$ctx" ] || continue
    printf 'BLOCKED%s%s%srequired check %s has not run on %s yet; merge the setup PR and re-run\n' \
      "$TAB" "$item" "$TAB" "$(one_line "$ctx")" "$RS_BRANCH"
  done <<EOF_UNSEEN
$unseen
EOF_UNSEEN
  BLOCKED_N=$((BLOCKED_N + 1))
  return 1
}

apply_ruleset() {
  local item="$1" vf
  if [ "$ALLOW_UNSEEN" -eq 0 ]; then
    rs_guard "$item" || return 0
  fi
  rs_load_live || return 0
  # The response (the ruleset as GitHub stored it) must normalize to desired.
  vf="$RS_JQ ($RS_DESIRED) as \$D | if norm(\$D) == (\$D | norm(\$D)) then \"matching\" else \"different\" end"
  if [ -n "$RS_ID" ]; then
    write_item "$item" PUT "repos/$REPO/rulesets/$RS_ID" "$RS_DESIRED" "$vf" matching "the ruleset"
  else
    write_item "$item" POST "repos/$REPO/rulesets" "$RS_DESIRED" "$vf" matching "the ruleset"
  fi
}

# ---- dispatcher -------------------------------------------------------------

area_known() {
  case " $AREAS " in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

area_active() {
  case " $ACTIVE_AREAS " in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

run_audits() {
  local area
  for area in $ACTIVE_AREAS; do
    "audit_$area"
  done
}

cmd_audit() {
  run_audits
  [ "$HAD_ERROR" -eq 0 ] || exit 2
  [ -z "$DIFF_ITEMS" ] || exit 1
  exit 0
}

cmd_apply() {
  local item area reason todo=""
  if [ "$ALL" -eq 1 ]; then
    QUIET=1
    run_audits
    QUIET=0
    [ "$HAD_ERROR" -eq 0 ] || exit 2
    todo="$DIFF_ITEMS"
  else
    # ITEMS is newline-delimited so ids with spaces stay intact. Validate all
    # first: one bad item aborts (exit 2) before anything is written.
    # Lines are read with `read` (no word splitting, no globbing).
    while IFS= read -r item <&3; do
      [ -n "$item" ] || continue
      area="${item%%.*}"
      area_known "$area" || die "unknown item: $item"
      area_active "$area" || die "no settings file for area '$area' in $DIR (item: $item)"
      "has_$area" "$item" || die "item not defined in $DIR: $item"
      if is_declined "$item"; then
        reason="$(declined_reason "$item")"
        printf 'NOTE%s%s is declined (%s); skipped\n' "$TAB" "$item" "$(one_line "$reason")"
        continue
      fi
      todo="$todo$item$NL"
    done 3<<EOF_ITEMS
$ITEMS
EOF_ITEMS
  fi
  while IFS= read -r item <&3; do
    [ -n "$item" ] || continue
    area="${item%%.*}"
    "apply_$area" "$item"
  done 3<<EOF_TODO
$todo
EOF_TODO
  [ "$HAD_ERROR" -eq 0 ] || exit 2
  [ "$FAILED_N" -eq 0 ] || exit 1
  [ "$BLOCKED_N" -eq 0 ] || exit 4
  [ "$UNAVAIL_N" -eq 0 ] || exit 3
  exit 0
}

# ---- main -------------------------------------------------------------------

main() {
  local area file
  [ $# -ge 1 ] || usage
  MODE="$1"
  shift
  case "$MODE" in
    audit | apply) ;;
    *) usage ;;
  esac

  while [ $# -gt 0 ]; do
    case "$1" in
      --repo) [ $# -ge 2 ] || usage; REPO="$2"; shift 2 ;;
      --dir) [ $# -ge 2 ] || usage; DIR="$2"; shift 2 ;;
      --dry-run) DRY_RUN=1; shift ;;
      --all) ALL=1; shift ;;
      --allow-unseen-checks) ALLOW_UNSEEN=1; shift ;;
      -h | --help) usage ;;
      -*) die "unknown option: $1" ;;
      *) ITEMS="$ITEMS$1$NL"; shift ;;
    esac
  done

  if [ "$MODE" = audit ] && { [ -n "$ITEMS" ] || [ "$ALL" -eq 1 ] || [ "$DRY_RUN" -eq 1 ] || [ "$ALLOW_UNSEEN" -eq 1 ]; }; then
    die "audit takes no items, --all, --dry-run or --allow-unseen-checks"
  fi
  if [ "$MODE" = apply ]; then
    { [ -n "$ITEMS" ] || [ "$ALL" -eq 1 ]; } || die "apply needs --all or at least one ITEM"
    { [ -z "$ITEMS" ] || [ "$ALL" -eq 0 ]; } || die "use either --all or named items, not both"
  fi

  [ -d "$DIR" ] || die "settings directory not found: $DIR"

  # An area is active when its config file exists; the rest are skipped.
  for area in $AREAS; do
    file="$DIR/$("config_file_$area")"
    [ -f "$file" ] || continue
    jq -e 'type == "object"' "$file" >/dev/null 2>&1 || die "not a valid JSON object: $file"
    ACTIVE_AREAS="$ACTIVE_AREAS$area "
  done
  [ -n "$ACTIVE_AREAS" ] || die "no settings files found in $DIR"

  # CONFIG is the shared repo.json used by the repo and security areas.
  CONFIG="$DIR/repo.json"
  for area in $ACTIVE_AREAS; do
    if [ "$(type -t "validate_$area")" = function ]; then "validate_$area"; fi
    DECLINED="$DECLINED$("declined_$area")$NL"
  done

  ERRF="$(mktemp)" || die "cannot create temp file"
  trap 'rm -f "$ERRF"' EXIT

  if [ -z "$REPO" ]; then
    REPO="$("${GH:-gh}" repo view --json nameWithOwner 2>"$ERRF" | jq -r '.nameWithOwner // empty')"
    [ -n "$REPO" ] || die "cannot determine repository (pass --repo OWNER/NAME): $(cat "$ERRF")"
  fi

  "cmd_$MODE"
}

# Run unless sourced (tests source this file to register extra areas).
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
