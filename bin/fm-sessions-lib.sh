#!/usr/bin/env bash
# fm-sessions-lib.sh - the sessions registry: named lanes of work that may span
# several projects, each backed by the primary firstmate or by a secondmate home.
#
# A session answers "who owns this kind of work" at the level a captain thinks
# in: a theme ("quant-models" across three repos), a catch-all ("chores" across
# every repo), or the whole fleet ("all"). It is a routing record, not a second
# architecture: a session either names the primary home or an existing
# secondmate (data/secondmates.md), and delivery to it reuses that home's own
# fm-inbox. Scripts own the lookup; the scope text is for the triage model.
#
# Registry: data/sessions.md, one line per session, anchored on the suffix:
#   - <id> - <one-sentence summary> (kind: theme|chores|all; repos: <a>, <b> | *; home: primary|<secondmate-id>; added YYYY-MM-DD)
#
# `repos: *` means every registered project. `home: primary` delivers to this
# home's own inbox; any other value must be an id in data/secondmates.md.
#
# Sourced; defines functions and SESSION_* output globals only. The caller sets
# DATA (the data directory).

# shellcheck disable=SC2034 # parsed fields are output globals for sourcing callers.
SESSION_ID=
SESSION_SUMMARY=
SESSION_KIND=
SESSION_REPOS=
SESSION_HOME=
SESSION_ADDED=
SESSION_ERROR=

sessions_registry_path() { printf '%s/sessions.md\n' "$DATA"; }
# Task-level instructions for a session; applies across all its repos.
sessions_dir() { printf '%s/sessions/%s\n' "$DATA" "$1"; }
sessions_instructions_path() { printf '%s/sessions/%s/instructions.md\n' "$DATA" "$1"; }

# The source folder firstmate discovers repos from (for example ~/Projects):
# FM_PROJECTS_SOURCE, else the first line of config/projects-source. Prints the
# absolute path, or returns 1 when none is configured. Session checkouts are
# cloned FROM it and never written to; the caller sets CONFIG.
sessions_source_root() {
  local v=${FM_PROJECTS_SOURCE:-} f="${CONFIG:-}/projects-source"
  if [ -z "$v" ] && [ -r "$f" ]; then
    v=$(sed -n '1{s/[[:space:]]*$//;p;q;}' "$f")
  fi
  [ -n "$v" ] && [ -d "$v" ] || return 1
  (cd "$v" && pwd -P)
}

sessions_parse_line() {  # <line>  -> 0 parsed, 1 not a session line
  local line=$1
  local re='^- ([A-Za-z0-9._-]+) - (.+) \(kind:[[:space:]]*(theme|chores|all);[[:space:]]*repos:[[:space:]]*([^;)]*);[[:space:]]*home:[[:space:]]*([A-Za-z0-9._-]+);[[:space:]]*added[[:space:]]+([0-9]{4}-[0-9]{2}-[0-9]{2})\)[[:space:]]*$'
  SESSION_ID= SESSION_SUMMARY= SESSION_KIND= SESSION_REPOS= SESSION_HOME= SESSION_ADDED=
  if [[ "$line" =~ $re ]]; then
    SESSION_ID=${BASH_REMATCH[1]}
    SESSION_SUMMARY=${BASH_REMATCH[2]}
    SESSION_KIND=${BASH_REMATCH[3]}
    SESSION_REPOS=${BASH_REMATCH[4]}
    SESSION_HOME=${BASH_REMATCH[5]}
    SESSION_ADDED=${BASH_REMATCH[6]}
    return 0
  fi
  return 1
}

# Print "<id>\t<kind>\t<repos>\t<home>\t<summary>" for every session.
sessions_list() {
  local file line
  file=$(sessions_registry_path)
  [ -r "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    sessions_parse_line "$line" || continue
    printf '%s\t%s\t%s\t%s\t%s\n' \
      "$SESSION_ID" "$SESSION_KIND" "$SESSION_REPOS" "$SESSION_HOME" "$SESSION_SUMMARY"
  done <"$file"
}

# 0 and sets SESSION_* when <id> exists; 1 otherwise.
sessions_get() {  # <id>
  local file line
  file=$(sessions_registry_path)
  [ -r "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    sessions_parse_line "$line" || continue
    [ "$SESSION_ID" = "$1" ] && return 0
  done <"$file"
  SESSION_ID= SESSION_SUMMARY= SESSION_KIND= SESSION_REPOS= SESSION_HOME= SESSION_ADDED=
  return 1
}

# Resolve the FM_HOME a session delivers into. Prints the absolute home path.
# `primary` is the caller's own home ($1). A secondmate id is looked up in
# data/secondmates.md through the existing registry parser.
sessions_home_path() {  # <primary-home> <session-home-field>
  local primary=$1 field=$2 reg line lib
  if [ "$field" = primary ]; then
    printf '%s\n' "$primary"
    return 0
  fi
  reg="$DATA/secondmates.md"
  [ -r "$reg" ] || { SESSION_ERROR="no data/secondmates.md, so secondmate '$field' is unknown"; return 1; }
  lib="$(dirname "${BASH_SOURCE[0]}")/fm-secondmate-registry-lib.sh"
  # shellcheck source=bin/fm-secondmate-registry-lib.sh disable=SC1091
  . "$lib"
  while IFS= read -r line || [ -n "$line" ]; do
    secondmate_registry_parse_line "$line" || true
    if [ "$SECONDMATE_REGISTRY_ID" = "$field" ]; then
      if [ "$SECONDMATE_REGISTRY_REMOTE" = 1 ]; then
        SESSION_ERROR="secondmate '$field' is remote; intake delivery to remote homes is not wired"
        return 1
      fi
      printf '%s\n' "$SECONDMATE_REGISTRY_HOME"
      return 0
    fi
  done <"$reg"
  SESSION_ERROR="secondmate '$field' is not in data/secondmates.md"
  return 1
}
