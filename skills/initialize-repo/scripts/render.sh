#!/usr/bin/env bash
# render.sh <template> <output> [KEY=VALUE ...] [--insert MARKER=FILE ...]
#
# Replaces every {{KEY}} with VALUE (pure bash, no sed, so values may contain
# / & spaces and backslashes). --insert replaces a line whose trimmed content
# is "# {{MARKER}}" with the contents of FILE, indented to match the marker.
# GitHub Actions ${{ ... }} expressions are left untouched. Exit 1 (output
# still written) if any {{UPPER_SNAKE}} placeholder remains; exit 2 on bad usage.
# Bash 3.2 compatible.

# bash 5.2 treats & in a replacement as the match; turn that off where supported.
shopt -u patsub_replacement 2>/dev/null

usage() {
  echo "usage: render.sh <template> <output> [KEY=VALUE ...] [--insert MARKER=FILE ...]" >&2
  exit 2
}

[ "$#" -ge 2 ] || usage
template="$1"
output="$2"
shift 2
[ -f "$template" ] || { echo "render.sh: template not found: $template" >&2; exit 2; }
[ -r "$template" ] || { echo "render.sh: template not readable: $template" >&2; exit 2; }

keys=()
vals=()
ins_markers=()
ins_files=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --insert)
      [ "$#" -ge 2 ] || usage
      case "$2" in *=*) ;; *) usage ;; esac
      ins_markers+=("${2%%=*}")
      ins_files+=("${2#*=}")
      [ -r "${2#*=}" ] || { echo "render.sh: insert file not readable: ${2#*=}" >&2; exit 2; }
      shift 2
      ;;
    *=*)
      keys+=("${1%%=*}")
      vals+=("${1#*=}")
      shift
      ;;
    *) usage ;;
  esac
done

mkdir -p "$(dirname "$output")" || exit 2

nkeys=${#keys[@]}
nins=${#ins_markers[@]}

{
  while :; do
    IFS= read -r line
    rc=$?
    nonl=0
    if [ "$rc" -ne 0 ]; then
      [ -n "$line" ] || break
      nonl=1
    fi
    trimmed="${line#"${line%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
    handled=0
    i=0
    while [ "$i" -lt "$nins" ]; do
      if [ "$trimmed" = "# {{${ins_markers[$i]}}}" ]; then
        indent="${line%%[![:space:]]*}"
        while IFS= read -r sline || [ -n "$sline" ]; do
          if [ -n "$sline" ]; then
            printf '%s%s\n' "$indent" "$sline"
          else
            printf '\n'
          fi
        done <"${ins_files[$i]}"
        handled=1
        break
      fi
      i=$((i + 1))
    done
    if [ "$handled" -eq 0 ]; then
      i=0
      while [ "$i" -lt "$nkeys" ]; do
        k="{{${keys[$i]}}}"
        v="${vals[$i]}"
        line="${line//"$k"/$v}"
        i=$((i + 1))
      done
      if [ "$nonl" -eq 1 ]; then printf '%s' "$line"; else printf '%s\n' "$line"; fi
    fi
  done <"$template"
  :
} >"$output" || { echo "render.sh: cannot write $output" >&2; exit 2; }

[ -r "$output" ] || { echo "render.sh: cannot read back $output" >&2; exit 2; }

# Report placeholders that remain (not preceded by $), de-duplicated.
missing=""
re='(^|[^$])\{\{([A-Z0-9_]+)\}\}'
while IFS= read -r line || [ -n "$line" ]; do
  rest="$line"
  while [[ "$rest" =~ $re ]]; do
    name="${BASH_REMATCH[2]}"
    case " $missing " in *" $name "*) ;; *) missing="$missing $name" ;; esac
    rest="${rest#*"{{$name}}"}"
  done
done <"$output"

if [ -n "$missing" ]; then
  echo "render.sh: unfilled placeholders:$missing" >&2
  exit 1
fi
exit 0
