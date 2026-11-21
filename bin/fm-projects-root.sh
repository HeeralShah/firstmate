#!/usr/bin/env bash
# fm-projects-root.sh - name the folder firstmate discovers your repos in.
#
# Many operators keep every repo flat under one folder (for example ~/Projects).
# `set` records that folder as the projects SOURCE in config/projects-source.
# Firstmate never writes to it: sessions get their own clones under
# projects/<repo>/<session> (bin/fm-session-checkout.sh), made with
# `git clone --local` from the source, so your own repos stay untouched.
#
# Usage:
#   fm-projects-root.sh show              the source folder and the session checkouts
#   fm-projects-root.sh set <dir>         record <dir> as the source
#   fm-projects-root.sh scan              git repos in the source, registered or not
#
# `set` refuses a non-directory. It registers nothing: registering a project
# (delivery mode, consent) is the project-management skill's job, so `scan` only
# lists. Environment: FM_HOME, FM_PROJECTS_SOURCE (overrides the recorded value).
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SELF_DIR/.." && pwd)"
FM_HOME="${FM_HOME:-$FM_ROOT}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
# shellcheck source=bin/fm-sessions-lib.sh disable=SC1091
. "$SELF_DIR/fm-sessions-lib.sh"

die() { printf 'fm-projects-root: %s\n' "$*" >&2; exit 1; }

registered() {  # <name>
  [ -r "$DATA/projects.md" ] || return 1
  grep -Eq "^- \`?$1\`?([[:space:]]|:| -)" "$DATA/projects.md"
}

cmd_show() {
  local src n
  if src=$(sessions_source_root); then
    printf 'source: %s\n' "$src"
  else
    printf 'source: (none; run: fm-projects-root.sh set <dir>)\n'
  fi
  n=$(find "$FM_HOME/projects" -mindepth 2 -maxdepth 2 -type d 2>/dev/null | wc -l | tr -d ' ')
  printf 'session checkouts: %s under %s/projects/<repo>/<session>\n' "$n" "$FM_HOME"
}

cmd_set() {
  local target=${1:-}
  [ -n "$target" ] || die "usage: fm-projects-root.sh set <dir>"
  case "$target" in "~"/*) target="$HOME/${target#"~"/}" ;; esac
  [ -d "$target" ] || die "'$target' is not a directory"
  target=$(cd "$target" && pwd -P)
  mkdir -p "$CONFIG"
  printf '%s\n' "$target" >"$CONFIG/projects-source"
  printf 'source: %s\n' "$target"
}

cmd_scan() {
  local root d name
  root=$(sessions_source_root) || die "no source configured; run: fm-projects-root.sh set <dir>"
  for d in "$root"/*/; do
    name=$(basename "$d")
    [ -e "$d/.git" ] || continue
    if registered "$name"; then
      printf '%-28s registered\n' "$name"
    else
      printf '%-28s not registered\n' "$name"
    fi
  done
}

case "${1:-}" in
  show) cmd_show ;;
  set)  shift; cmd_set "$@" ;;
  scan) cmd_scan ;;
  *) die "usage: fm-projects-root.sh {show|set <dir>|scan}" ;;
esac
