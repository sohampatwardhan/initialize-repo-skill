#!/usr/bin/env bash
# preflight.sh [DIR] -- check tools and auth, then report which situation the
# initialize-repo skill is in. Bash 3.2 compatible. Needs git, gh, jq.
#
# Output: one key=value per line on stdout, in this order:
#   git gh jq        ok | missing
#   auth             ok | none
#   scopes           comma-separated token scopes, or "unknown"
#   repo             OWNER/NAME | none
#   default_branch
#   situation        new | existing-first | configured
#   owner_type       User | Organization | unknown
#   issue_types      yes | no
# plus optional warning=<msg> lines and, on failure, error=<msg> lines (last).
# Exit 0 when the skill can proceed, 1 otherwise. Keys not reached are omitted.
set -u

DIR="${1:-.}"
GH_BIN="${GH:-gh}"
ERRORS=""

add_error() { ERRORS="${ERRORS}error=$1
"; }
finish_run() {
  printf '%s' "$ERRORS"
  [ -z "$ERRORS" ]
  exit $?
}

# --- tools: check all before stopping so every problem shows at once --------
have() { command -v "$1" >/dev/null 2>&1; }

if have git; then echo "git=ok"; else
  echo "git=missing"
  add_error "git is not installed. Install it (macOS: xcode-select --install or brew install git)."
fi
if have "$GH_BIN"; then echo "gh=ok"; else
  echo "gh=missing"
  add_error "gh (GitHub CLI) is not installed. Install it (macOS: brew install gh), then run: gh auth login"
fi
if have jq; then echo "jq=ok"; else
  echo "jq=missing"
  add_error "jq is not installed. Install it (macOS: brew install jq)."
fi
[ -z "$ERRORS" ] || finish_run

# --- auth and scopes --------------------------------------------------------
if ! AUTH_OUT="$("$GH_BIN" auth status 2>&1)"; then
  echo "auth=none"
  add_error "gh is not logged in. Run: gh auth login"
  finish_run
fi
echo "auth=ok"

SCOPE_LINE="$(printf '%s\n' "$AUTH_OUT" | sed -n 's/.*Token scopes: *//p' | head -n 1)"
if [ -z "$SCOPE_LINE" ]; then
  echo "scopes=unknown"
  echo "warning=could not read token scopes (env-var or fine-grained token?); make sure the token has repo and workflow access"
else
  SCOPES="$(printf '%s' "$SCOPE_LINE" | tr -d "' ")"
  echo "scopes=$SCOPES"
  case ",$SCOPES," in *,repo,*) ;; *)
    add_error "token lacks the repo scope. Run: gh auth refresh -s repo" ;;
  esac
  case ",$SCOPES," in *,workflow,*) ;; *)
    add_error "token lacks the workflow scope (needed to push workflow files). Run: gh auth refresh -s workflow" ;;
  esac
  [ -z "$ERRORS" ] || finish_run
fi

# --- repo detection (from the origin remote, not gh) ------------------------
REPO=none
REMOTE="$(git -C "$DIR" remote get-url origin 2>/dev/null || true)"
if [ -n "$REMOTE" ]; then
  REPO="$(printf '%s\n' "$REMOTE" |
    sed -n -E 's#^(https://github\.com/|git@github\.com:|ssh://git@github\.com/)([^/]+)/([^/]+)$#\2/\3#p' |
    sed -e 's#/$##' -e 's#\.git$##' | head -n 1)"
  [ -n "$REPO" ] || REPO=none
fi

HAS_COMMITS=no
git -C "$DIR" rev-parse --verify HEAD >/dev/null 2>&1 && HAS_COMMITS=yes

LOCAL_BRANCH="$(git -C "$DIR" symbolic-ref --short HEAD 2>/dev/null || true)"
[ -n "$LOCAL_BRANCH" ] || LOCAL_BRANCH=main

DEFAULT_BRANCH="$LOCAL_BRANCH"
OWNER_TYPE=unknown
ISSUE_TYPES=no
if [ "$REPO" != none ]; then
  if INFO="$("$GH_BIN" api "repos/$REPO" 2>/dev/null)"; then
    B="$(printf '%s' "$INFO" | jq -r '.default_branch // empty' 2>/dev/null)"
    T="$(printf '%s' "$INFO" | jq -r '.owner.type // empty' 2>/dev/null)"
    [ -z "$B" ] || DEFAULT_BRANCH="$B"
    [ -z "$T" ] || OWNER_TYPE="$T"
  fi
  # Issue types: asked of the repo itself, never inferred from the owner type.
  # shellcheck disable=SC2016 # $o/$r are GraphQL variables, not shell
  if GQL="$("$GH_BIN" api graphql \
    -f query='query($o:String!,$r:String!){repository(owner:$o,name:$r){issueTypes(first:10){nodes{name}}}}' \
    -F o="${REPO%%/*}" -F r="${REPO#*/}" 2>/dev/null)"; then
    N="$(printf '%s' "$GQL" | jq -r '(.data.repository.issueTypes.nodes // []) | length' 2>/dev/null)"
    case "$N" in '' | *[!0-9]*) N=0 ;; esac
    [ "$N" -gt 0 ] && ISSUE_TYPES=yes
  fi
fi

# --- situation --------------------------------------------------------------
if [ "$REPO" = none ] || [ "$HAS_COMMITS" = no ]; then
  SITUATION=new
elif [ -d "$DIR/.github/settings" ]; then
  SITUATION=configured
else
  SITUATION=existing-first
fi

echo "repo=$REPO"
echo "default_branch=$DEFAULT_BRANCH"
echo "situation=$SITUATION"
echo "owner_type=$OWNER_TYPE"
echo "issue_types=$ISSUE_TYPES"
finish_run
