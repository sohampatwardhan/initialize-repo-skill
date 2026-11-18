#!/usr/bin/env bash
# repo-settings.sh: keep a GitHub repo's settings in sync with committed JSON.
#
#   repo-settings.sh <audit|apply> [--repo OWNER/NAME] [--dir DIR] [--dry-run]
#                    [--all | ITEM ...]
#
# Desired state lives in DIR (default .github/settings). Items are named
# "<area>.<key>", e.g. repo.allow_auto_merge, security.secret_scanning.
#
# audit  prints "DIFF<TAB>item<TAB>live=..<TAB>desired=.." per difference.
#        Exit 0 no differences, 1 differences, 2 error.
# apply  writes the named items (or every differing item with --all).
#        Prints APPLIED / UNAVAILABLE / FAILED per item; with --dry-run prints
#        "WOULD<TAB>METHOD endpoint" and calls nothing.
#        Exit 0 all applied, 1 any failed, 3 some unavailable and none failed.
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

AREAS="repo security"

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
usage: repo-settings.sh <audit|apply> [--repo OWNER/NAME] [--dir DIR] [--dry-run] [--all | ITEM ...]
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
      -h | --help) usage ;;
      -*) die "unknown option: $1" ;;
      *) ITEMS="$ITEMS$1$NL"; shift ;;
    esac
  done

  if [ "$MODE" = audit ] && { [ -n "$ITEMS" ] || [ "$ALL" -eq 1 ] || [ "$DRY_RUN" -eq 1 ]; }; then
    die "audit takes no items, --all or --dry-run"
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
