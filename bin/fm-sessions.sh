#!/usr/bin/env bash
# fm-sessions.sh - manage the sessions registry (data/sessions.md).
#
# A session is a named lane of work that can span several projects: a theme, a
# catch-all for chores across every repo, or the whole fleet. It is backed by
# the primary firstmate (`--home primary`, the default) or by an existing
# secondmate (`--home <secondmate-id>`). Contract and line format:
# bin/fm-sessions-lib.sh. Intake routing: bin/fm-intake.sh.
#
# Usage:
#   fm-sessions.sh add <id> --summary <text> [--kind theme|chores|all]
#                   [--repos a,b,c | --repos '*'] [--home primary|<secondmate-id>]
#   fm-sessions.sh list
#   fm-sessions.sh show <id>
#   fm-sessions.sh instructions <id>     print the path of the session's instruction file
#   fm-sessions.sh remove <id>
#
# Each session has task-level instructions in data/sessions/<id>.md, created as a
# stub by `add` and edited by the captain. They apply across every repo in the
# session (repo AGENTS.md/CLAUDE.md stays the repo-maintainer layer). Pass
# `--session <id>` to bin/fm-brief.sh to inline them into a worker brief; `remove`
# leaves the file in place. The directory data/sessions/<id>/ holds plan.md and
# summary.md, which the dashboard and state card read (bin/fm-dashboard.sh).
#
# `add` records the route only. It never creates or launches a secondmate; to
# back a session with its own home, provision the secondmate first (skill
# secondmate-provisioning) and then point `--home` at its id. `add` refuses an
# unknown secondmate id, and refuses repos that are not directories under the
# projects root, so a typo cannot become a silent mis-route.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SELF_DIR/.." && pwd)"
FM_HOME="${FM_HOME:-$FM_ROOT}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
# shellcheck source=bin/fm-sessions-lib.sh disable=SC1091
. "$SELF_DIR/fm-sessions-lib.sh"

die() { printf 'fm-sessions: %s\n' "$*" >&2; exit 1; }

valid_id() {
  case "$1" in ''|*[!A-Za-z0-9._-]*|.*) return 1 ;; esac
  return 0
}

cmd_add() {
  local id=${1:-} summary="" kind=theme repos="" home=primary file
  [ -n "$id" ] || die "usage: fm-sessions.sh add <id> --summary <text> [--kind ...] [--repos ...] [--home ...]"
  shift
  valid_id "$id" || die "invalid session id '$id' (use A-Za-z0-9._-)"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --summary) [ "$#" -ge 2 ] || die "--summary needs a value"; summary=$2; shift 2 ;;
      --kind)    [ "$#" -ge 2 ] || die "--kind needs a value"; kind=$2; shift 2 ;;
      --repos)   [ "$#" -ge 2 ] || die "--repos needs a value"; repos=$2; shift 2 ;;
      --home)    [ "$#" -ge 2 ] || die "--home needs a value"; home=$2; shift 2 ;;
      *) die "unknown argument '$1'" ;;
    esac
  done
  [ -n "$summary" ] || die "--summary is required: one sentence on what this session owns"
  case "$summary" in *$'\n'*|*'('*|*')'*|*';'*) die "--summary must be one line without parentheses or semicolons" ;; esac
  case "$kind" in theme|chores|all) ;; *) die "--kind must be theme, chores or all" ;; esac
  case "$kind" in
    all|chores) [ -n "$repos" ] || repos='*' ;;
    theme) [ -n "$repos" ] || die "a theme session needs --repos a,b,c" ;;
  esac
  if [ "$repos" != '*' ]; then
    local r list=""
    IFS=',' read -r -a arr <<<"$repos"
    for r in "${arr[@]}"; do
      r=${r#"${r%%[![:space:]]*}"}; r=${r%"${r##*[![:space:]]}"}
      [ -n "$r" ] || continue
      [ -d "$PROJECTS/$r" ] || die "repo '$r' is not a directory under $PROJECTS (set the root with bin/fm-projects-root.sh)"
      list="${list:+$list, }$r"
    done
    repos=$list
  fi
  if sessions_get "$id"; then die "session '$id' already exists"; fi
  if [ "$home" != primary ]; then
    sessions_home_path "$FM_HOME" "$home" >/dev/null || die "$SESSION_ERROR"
  fi
  mkdir -p "$DATA"
  file=$(sessions_registry_path)
  printf -- '- %s - %s (kind: %s; repos: %s; home: %s; added %s)\n' \
    "$id" "$summary" "$kind" "$repos" "$home" "$(date +%Y-%m-%d)" >>"$file"
  mkdir -p "$DATA/sessions/$id"
  local ifile
  ifile=$(sessions_instructions_path "$id")
  if [ ! -e "$ifile" ]; then
    printf '# Session %s: task-level instructions\n\n%s\n\nWrite what applies to ALL work in this session, across repos: goals, approach, conventions for\nthis theme, what to check, what not to touch. Repo-specific maintainer rules belong in each\nrepo AGENTS.md or CLAUDE.md, not here.\n' "$id" "$summary" >"$ifile"
  fi
  printf 'added session %s (%s, repos: %s, home: %s)\n  instructions: %s\n' "$id" "$kind" "$repos" "$home" "$ifile"
}

cmd_list() {
  local id kind repos home summary any=0
  while IFS=$'\t' read -r id kind repos home summary; do
    any=1
    printf '%-18s %-7s home=%-14s repos=%s\n    %s\n' "$id" "$kind" "$home" "$repos" "$summary"
  done < <(sessions_list)
  [ "$any" -eq 1 ] || printf '(no sessions; every message routes to the primary home)\n'
}

cmd_show() {
  [ -n "${1:-}" ] || die "usage: fm-sessions.sh show <id>"
  sessions_get "$1" || die "no session '$1'"
  printf 'id: %s\nkind: %s\nrepos: %s\nhome: %s\nsummary: %s\nadded: %s\n' \
    "$SESSION_ID" "$SESSION_KIND" "$SESSION_REPOS" "$SESSION_HOME" "$SESSION_SUMMARY" "$SESSION_ADDED"
}

cmd_instructions() {
  [ -n "${1:-}" ] || die "usage: fm-sessions.sh instructions <id>"
  sessions_get "$1" || die "no session '$1'"
  sessions_instructions_path "$1"
}

cmd_remove() {
  local id=${1:-} file tmp line
  [ -n "$id" ] || die "usage: fm-sessions.sh remove <id>"
  sessions_get "$id" || die "no session '$id'"
  file=$(sessions_registry_path)
  tmp=$(mktemp "$DATA/.sessions-XXXXXX")
  while IFS= read -r line || [ -n "$line" ]; do
    if sessions_parse_line "$line" && [ "$SESSION_ID" = "$id" ]; then continue; fi
    printf '%s\n' "$line"
  done <"$file" >"$tmp"
  mv "$tmp" "$file"
  printf 'removed session %s (its home and any open work are untouched)\n' "$id"
}

case "${1:-}" in
  add)    shift; cmd_add "$@" ;;
  list)   shift; cmd_list ;;
  show)   shift; cmd_show "$@" ;;
  instructions) shift; cmd_instructions "$@" ;;
  remove) shift; cmd_remove "$@" ;;
  *) die "usage: fm-sessions.sh {add|list|show|instructions|remove} ..." ;;
esac
