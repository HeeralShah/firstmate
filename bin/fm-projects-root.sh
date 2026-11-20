#!/usr/bin/env bash
# fm-projects-root.sh - point this home's projects/ at a shared parent folder.
#
# Firstmate reads project clones from $FM_HOME/projects. Many operators already
# keep every repo flat under one folder (for example ~/Projects). This makes
# projects/ a symlink to that folder so firstmate sees those repos in place and
# no second copy is cloned. Hard rule 1 is unchanged: firstmate still reads
# projects and never writes to them; workers still change code only in isolated
# task worktrees.
#
# Usage:
#   fm-projects-root.sh show              where projects/ points and what is registered
#   fm-projects-root.sh set <dir>         link projects/ -> <dir>
#   fm-projects-root.sh scan              git repos under the root, registered or not
#
# `set` refuses to replace a projects/ that already holds clones (move or remove
# them yourself first), refuses a non-directory target, and never touches the
# target folder. It does not register anything: registering a project (delivery
# mode, consent) is the project-management skill's job, so `scan` only lists.
#
# Environment: FM_HOME (the home whose projects/ is managed).
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SELF_DIR/.." && pwd)"
FM_HOME="${FM_HOME:-$FM_ROOT}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
LINK="$FM_HOME/projects"

die() { printf 'fm-projects-root: %s\n' "$*" >&2; exit 1; }

registered() {  # <name>
  [ -r "$DATA/projects.md" ] || return 1
  grep -Eq "^- \`?$1\`?([[:space:]]|:| -)" "$DATA/projects.md"
}

cmd_show() {
  if [ -L "$LINK" ]; then
    printf 'projects/ -> %s\n' "$(readlink "$LINK")"
  elif [ -d "$LINK" ]; then
    printf 'projects/ is a real directory (%s clones)\n' "$(find "$LINK" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')"
  else
    printf 'projects/ does not exist\n'
  fi
}

cmd_set() {
  local target=${1:-}
  [ -n "$target" ] || die "usage: fm-projects-root.sh set <dir>"
  case "$target" in "~"/*) target="$HOME/${target#"~"/}" ;; esac
  [ -d "$target" ] || die "'$target' is not a directory"
  target=$(cd "$target" && pwd -P)
  if [ -L "$LINK" ]; then
    [ "$(readlink "$LINK")" = "$target" ] && { printf 'already set: projects/ -> %s\n' "$target"; return 0; }
    rm "$LINK"
  elif [ -d "$LINK" ]; then
    [ -z "$(find "$LINK" -mindepth 1 -maxdepth 1 -print -quit)" ] \
      || die "projects/ already holds clones; move them out first (nothing was changed)"
    rmdir "$LINK"
  elif [ -e "$LINK" ]; then
    die "projects exists and is not a directory or symlink"
  fi
  ln -s "$target" "$LINK"
  printf 'projects/ -> %s\n' "$target"
}

cmd_scan() {
  local root name
  [ -d "$LINK" ] || die "projects/ is not set up; run: fm-projects-root.sh set <dir>"
  root=$(cd "$LINK" && pwd -P)
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
