#!/usr/bin/env bash
# fm-session-work.sh - the session's work ledger: find, record and adopt work a
# chat already did, without moving, stashing or discarding any of it.
#
# When a chat becomes a session mid-way, it may already have committed and
# uncommitted work in one or more repos. This script carries that work into the
# session safely, under AGENTS.md hard rules 1 and 3 (firstmate never writes to
# a project except a concrete captain-approved operation; unlanded work is never
# torn down):
#
#   survey <path>...           READ-ONLY. Per repo: branch, head, upstream
#                              ahead/behind, unpushed local branches, staged,
#                              unstaged and untracked changes, stashes, worktrees.
#   record <session> <path>... Writes data/sessions/<id>/work.md and, for any
#                              uncommitted TRACKED changes, a patch COPY under
#                              data/sessions/<id>/work/ (git diff HEAD --binary).
#                              Untracked files are listed, never copied (they may
#                              be large or secret). Nothing in the repo changes.
#   adopt <session> <path> --branch <b>...
#                              Brings committed branches into the session's own
#                              clone (projects/<repo>/<session>): adds the path as
#                              a fetch-only remote and creates local branches from
#                              it. Never touches <path>. This changes refs in a
#                              firstmate clone, so it runs only after the captain
#                              approved this exact operation (the bind-session
#                              skill asks); it refuses to overwrite an existing
#                              branch that differs.
#
# Uncommitted work is deliberately NOT applied by this script: restoring a
# recorded patch is code work, so it becomes the first step of a worker's
# instructions in an isolated copy based on the recorded head. The original
# stays where it is, untouched, until the captain decides what to do with it.
#
# Environment: FM_HOME, FM_PROJECTS_SOURCE.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SELF_DIR/.." && pwd)"
FM_HOME="${FM_HOME:-$FM_ROOT}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
PROJECTS="$FM_HOME/projects"
# shellcheck source=bin/fm-sessions-lib.sh disable=SC1091
. "$SELF_DIR/fm-sessions-lib.sh"

die() { printf 'fm-session-work: %s\n' "$*" >&2; exit 1; }

repo_root() {  # <path> -> toplevel or fail
  git -C "$1" rev-parse --show-toplevel 2>/dev/null || die "'$1' is not inside a git repository"
}

# Branches with commits on no remote: the work most at risk if a copy is lost.
unpushed_branches() {  # <repo>
  local b
  while IFS= read -r b; do
    [ -n "$b" ] || continue
    if [ -n "$(git -C "$1" rev-list -1 "refs/heads/$b" --not --remotes 2>/dev/null)" ]; then
      printf '%s %s\n' "$b" "$(git -C "$1" rev-parse --short "refs/heads/$b")"
    fi
  done < <(git -C "$1" for-each-ref --format='%(refname:short)' refs/heads)
}

survey_one() {  # <path>
  local repo st staged unstaged untracked stashes wts upstream track
  repo=$(repo_root "$1")
  st=$(git -C "$repo" status --porcelain=v1 2>/dev/null || true)
  staged=$(printf '%s\n' "$st" | grep -c '^[MADRC]' || true)
  unstaged=$(printf '%s\n' "$st" | grep -c '^.[MD]' || true)
  untracked=$(printf '%s\n' "$st" | grep -c '^??' || true)
  stashes=$(git -C "$repo" stash list 2>/dev/null | wc -l | tr -d ' ')
  wts=$(git -C "$repo" worktree list 2>/dev/null | wc -l | tr -d ' ')
  upstream=$(git -C "$repo" rev-parse --abbrev-ref '@{u}' 2>/dev/null || echo none)
  track=$(git -C "$repo" rev-list --left-right --count '@{u}...HEAD' 2>/dev/null | awk '{print "behind " $1 ", ahead " $2}' || true)
  printf '%s\n' "repo: $repo"
  printf '  branch: %s at %s (upstream %s%s)\n' "$(git -C "$repo" rev-parse --abbrev-ref HEAD)" \
    "$(git -C "$repo" rev-parse --short HEAD 2>/dev/null || echo none)" "$upstream" "${track:+; $track}"
  printf '  uncommitted: %s staged, %s unstaged, %s untracked\n' "$staged" "$unstaged" "$untracked"
  printf '  stashes: %s (never touched)\n' "$stashes"
  printf '  worktrees: %s (including the main one)\n' "$wts"
  local up
  up=$(unpushed_branches "$repo")
  if [ -n "$up" ]; then
    printf '  unpushed branches:\n'
    printf '%s\n' "$up" | sed 's/^/    /'
  else
    printf '  unpushed branches: none\n'
  fi
}

cmd_survey() {
  [ "$#" -gt 0 ] || die "usage: fm-session-work.sh survey <path>..."
  local p
  for p in "$@"; do survey_one "$p"; done
}

cmd_record() {
  local sid=${1:-} p repo name ts sd patch untracked
  [ -n "$sid" ] && [ "$#" -ge 2 ] || die "usage: fm-session-work.sh record <session> <path>..."
  shift
  sessions_get "$sid" || die "no session '$sid'"
  sd=$(sessions_dir "$sid")
  mkdir -p "$sd/work"
  [ -e "$sd/work.md" ] || printf '# Session %s work ledger (where its work lives; recorded, never moved)\n' "$sid" >"$sd/work.md"
  ts=$(date -u +%Y%m%dT%H%M%SZ)
  for p in "$@"; do
    repo=$(repo_root "$p")
    name=$(basename "$repo")
    {
      printf '\n## %s (recorded %s)\n\n' "$name" "$ts"
      printf -- '- location: `%s` (original; left untouched)\n' "$repo"
      survey_one "$repo" | sed '1d; s/^    /  - /; s/^  \([^ -]\)/- \1/'
    } >>"$sd/work.md"
    if ! git -C "$repo" diff --quiet HEAD 2>/dev/null; then
      patch="$sd/work/$name-$ts.patch"
      git -C "$repo" diff HEAD --binary >"$patch"
      printf -- '- uncommitted tracked changes copied to `%s` against base `%s` (a copy; restore it in a worker'"'"'s isolated copy)\n' \
        "$patch" "$(git -C "$repo" rev-parse HEAD)" >>"$sd/work.md"
    fi
    untracked=$(git -C "$repo" ls-files --others --exclude-standard)
    if [ -n "$untracked" ]; then
      printf -- '- untracked files (listed, NOT copied; they exist only in the original):\n' >>"$sd/work.md"
      printf '%s\n' "$untracked" | head -50 | sed 's/^/  - /' >>"$sd/work.md"
      [ "$(printf '%s\n' "$untracked" | wc -l)" -le 50 ] || printf '  - ... more not listed\n' >>"$sd/work.md"
    fi
    printf 'recorded %s into %s\n' "$name" "$sd/work.md"
  done
}

cmd_adopt() {
  local sid=${1:-} path=${2:-} repo name dest remote b have want made=0
  [ -n "$sid" ] && [ -n "$path" ] || die "usage: fm-session-work.sh adopt <session> <path> --branch <b>..."
  shift 2
  sessions_get "$sid" || die "no session '$sid'"
  local -a branches=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --branch) [ "$#" -ge 2 ] || die "--branch needs a value"; branches+=("$2"); shift 2 ;;
      *) die "unknown argument '$1'" ;;
    esac
  done
  [ "${#branches[@]}" -gt 0 ] || die "name each branch to adopt with --branch; nothing is adopted implicitly"
  repo=$(repo_root "$path")
  name=$(git -C "$repo" rev-parse --git-common-dir | xargs -I{} sh -c 'cd "$1" && cd "{}" && pwd' _ "$repo")
  name=$(basename "$(dirname "$name")")  # repo name, also right for a linked worktree
  dest="$PROJECTS/$name/$sid"
  [ -e "$dest/.git" ] || die "no session clone at $dest; run: fm-session-checkout.sh create $sid $name"
  remote="adopt-$(printf '%s' "$repo" | cksum | cut -d' ' -f1)"
  git -C "$dest" remote get-url "$remote" >/dev/null 2>&1 || git -C "$dest" remote add "$remote" "$repo"
  git -C "$dest" fetch -q "$remote"
  for b in "${branches[@]}"; do
    want=$(git -C "$dest" rev-parse -q --verify "refs/remotes/$remote/$b") || die "branch '$b' not found in $repo"
    if have=$(git -C "$dest" rev-parse -q --verify "refs/heads/$b"); then
      [ "$have" = "$want" ] || die "branch '$b' already exists in $dest at a different commit; nothing overwritten"
      printf 'already present: %s\n' "$b"
      continue
    fi
    git -C "$dest" branch -q "$b" "$want"
    printf 'adopted %s at %s into %s (original untouched)\n' "$b" "$(git -C "$dest" rev-parse --short "$want")" "$dest"
    made=$((made + 1))
  done
  if [ "$made" -gt 0 ]; then
    printf -- '- adopted into `%s` on %s: %s (fetch-only remote `%s` -> `%s`)\n' "$dest" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      "${branches[*]}" "$remote" "$repo" >>"$(sessions_dir "$sid")/work.md"
  fi
  printf '%d branch(es) adopted\n' "$made"
}

case "${1:-}" in
  survey) shift; cmd_survey "$@" ;;
  record) shift; cmd_record "$@" ;;
  adopt)  shift; cmd_adopt "$@" ;;
  *) die "usage: fm-session-work.sh {survey|record|adopt} ..." ;;
esac
