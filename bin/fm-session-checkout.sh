#!/usr/bin/env bash
# fm-session-checkout.sh - give a session its own clone of each repo it spans.
#
# Layout: $FM_HOME/projects/<repo>/<session> is a full clone owned by that
# session, so two sessions touching the same repo never share a working tree,
# index, or branch state. Clones are made with `git clone --local` from the
# projects source (bin/fm-projects-root.sh) and their `origin` is reset to the
# source repo's real remote, so a push still goes to the forge and nothing is
# ever written into the source repo.
#
# A per-session VIEW at data/sessions/<session>/repos/<repo> is a relative
# symlink to that clone. Point a session home's projects directory at the view
# (FM_PROJECTS_OVERRIDE, or a secondmate's projects/) and upstream tooling that
# expects <projects>/<repo> to be a clone works unchanged.
#
# Usage:
#   fm-session-checkout.sh create <session> [<repo>...]   clone missing repos (default: the session's repos)
#   fm-session-checkout.sh status <session>               branch, dirty and ahead state per clone
#   fm-session-checkout.sh sync <session>                 refresh each clone through bin/fm-fleet-sync.sh
#
# `create` is idempotent and never touches an existing clone. It refuses an
# unknown session, a repo outside the session's scope, or a repo with no git dir
# in the source. Environment: FM_HOME, FM_PROJECTS_SOURCE.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SELF_DIR/.." && pwd)"
FM_HOME="${FM_HOME:-$FM_ROOT}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
PROJECTS="$FM_HOME/projects"
# shellcheck source=bin/fm-sessions-lib.sh disable=SC1091
. "$SELF_DIR/fm-sessions-lib.sh"

die() { printf 'fm-session-checkout: %s\n' "$*" >&2; exit 1; }

scope_repos() {  # prints the session's repos, one per line
  local src r
  src=$(sessions_source_root) || die "no projects source configured: run bin/fm-projects-root.sh set <dir>"
  if [ "$SESSION_REPOS" = '*' ]; then
    for d in "$src"/*/; do [ -e "$d/.git" ] && basename "$d"; done
  else
    IFS=',' read -r -a arr <<<"$SESSION_REPOS"
    for r in "${arr[@]}"; do
      r=${r#"${r%%[![:space:]]*}"}; r=${r%"${r##*[![:space:]]}"}
      [ -n "$r" ] && printf '%s\n' "$r"
    done
  fi
}

# The source repo's default branch: its origin/HEAD, else main or master.
default_branch() {  # <repo>
  local b
  b=$(git -C "$1" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || true)
  b=${b#origin/}
  if [ -z "$b" ]; then
    for b in main master; do
      git -C "$1" rev-parse --verify -q "refs/heads/$b" >/dev/null && break
      b=
    done
  fi
  printf '%s\n' "$b"
}

cmd_create() {
  local sid=${1:-} src r dest url view base made=0
  [ -n "$sid" ] || die "usage: fm-session-checkout.sh create <session> [<repo>...]"
  shift
  sessions_get "$sid" || die "no session '$sid'"
  src=$(sessions_source_root) || die "no projects source configured: run bin/fm-projects-root.sh set <dir>"
  local -a want=()
  if [ "$#" -gt 0 ]; then want=("$@"); else while IFS= read -r r; do want+=("$r"); done < <(scope_repos); fi
  view="$(sessions_dir "$sid")/repos"
  mkdir -p "$view"
  for r in ${want[@]+"${want[@]}"}; do
    case "$r" in ''|*/*|.*) die "invalid repo name '$r'" ;; esac
    if [ "$SESSION_REPOS" != '*' ]; then
      case ",$(printf '%s' "$SESSION_REPOS" | tr -d ' ')," in *",$r,"*) ;; *) die "repo '$r' is outside session '$sid' scope ($SESSION_REPOS)" ;; esac
    fi
    [ -e "$src/$r/.git" ] || die "repo '$r' is not a git repo under $src"
    dest="$PROJECTS/$r/$sid"
    if [ -e "$dest" ]; then
      printf 'exists  %s\n' "$dest"
    else
      mkdir -p "$PROJECTS/$r"
      git clone --local -q "$src/$r" "$dest"
      # Start on the repo's DEFAULT branch, not whatever the source has checked
      # out (a feature branch in ~/Projects must not become the session's base).
      base=$(default_branch "$src/$r")
      if [ -n "$base" ] && [ "$(git -C "$dest" rev-parse --abbrev-ref HEAD)" != "$base" ]; then
        git -C "$dest" checkout -q "$base" 2>/dev/null || git -C "$dest" checkout -q -b "$base" "origin/$base"
      fi
      url=$(git -C "$src/$r" remote get-url origin 2>/dev/null || true)
      if [ -n "$url" ]; then
        git -C "$dest" remote set-url origin "$url"
        # origin/* refs were copied from the LOCAL source; refresh them from the
        # real remote so ahead/behind counts are true. Offline is reported, not fatal.
        if ! git -C "$dest" fetch -q --prune origin 2>/dev/null; then
          printf 'warning: could not fetch %s; origin/* in %s reflect the local source until fetched\n' "$url" "$dest" >&2
        fi
      else
        git -C "$dest" remote remove origin 2>/dev/null || true
      fi
      printf 'created %s (on %s)\n' "$dest" "$(git -C "$dest" rev-parse --abbrev-ref HEAD)"
      made=$((made + 1))
    fi
    [ -L "$view/$r" ] || ln -s "../../../../projects/$r/$sid" "$view/$r"
  done
  printf '%d clone(s) created; view: %s\n' "$made" "$view"
}

cmd_status() {
  local sid=${1:-} d r br dirty ahead
  [ -n "$sid" ] || die "usage: fm-session-checkout.sh status <session>"
  sessions_get "$sid" || die "no session '$sid'"
  for d in "$PROJECTS"/*/"$sid"; do
    [ -e "$d/.git" ] || continue
    r=$(basename "$(dirname "$d")")
    br=$(git -C "$d" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')
    dirty=$(git -C "$d" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    ahead=$(git -C "$d" rev-list --count '@{u}..HEAD' 2>/dev/null || echo '-')
    printf '%-24s branch=%-20s dirty=%s ahead=%s\n' "$r" "$br" "$dirty" "$ahead"
  done
}

cmd_sync() {
  local sid=${1:-} d r rc=0
  [ -n "$sid" ] || die "usage: fm-session-checkout.sh sync <session>"
  sessions_get "$sid" || die "no session '$sid'"
  # fm-fleet-sync.sh accepts projects/<name> forms and owns the guarded
  # fast-forward, self-heal and STUCK reporting; reuse it rather than re-implement.
  for d in "$PROJECTS"/*/"$sid"; do
    [ -e "$d/.git" ] || continue
    r=$(basename "$(dirname "$d")")
    "$SELF_DIR/fm-fleet-sync.sh" "projects/$r/$sid" || rc=1
  done
  return "$rc"
}

case "${1:-}" in
  create) shift; cmd_create "$@" ;;
  sync)   shift; cmd_sync "$@" ;;
  status) shift; cmd_status "$@" ;;
  *) die "usage: fm-session-checkout.sh {create|status|sync} <session> ..." ;;
esac
