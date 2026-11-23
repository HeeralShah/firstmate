#!/usr/bin/env bash
# fm-session-bind.sh - bind a chat to a named session.
#
# A binding tells the session-start digest which session's state card to load
# for THIS chat, including on the --reemit path after compaction, so one chat
# can stay on one topic for its whole life. Claude Code gives every hook and
# tool shell the chat's id as CLAUDE_CODE_SESSION_ID (bin/fm-session-lock-lib.sh
# relies on the same variable); the binding is keyed by it, so two chats in one
# home can be bound to two different sessions.
#
# Usage:
#   fm-session-bind.sh bind <session> [--chat <chat-id>] [--repo <dir> | --no-repo-hook]
#                                                          bind this chat (or the named one)
#   fm-session-bind.sh bind <session> --home-default       make it the home's default instead
#   fm-session-bind.sh show                                this chat's binding and the home default
#   fm-session-bind.sh resolve                             print the session for this chat, or nothing
#   fm-session-bind.sh unbind [--chat <chat-id>]           remove this chat's binding
#
# Resolution order (resolve, and the digest): this chat's binding in
# state/session-bindings/<chat-id>, else config/active-session, else none.
# `bind` refuses an unknown session and, without a chat id, tells the caller to
# pass --chat or --home-default rather than guessing. /clear starts a new chat
# id, so a cleared chat falls back to the home default until bound again.
#
# Per-repo intake hook. Claude Code runs only hooks registered in user settings
# or in the open project's settings, never per chat. So `bind` registers
# bin/fm-intake-hook.sh in the chat's repo, in its UNTRACKED
# `.claude/settings.local.json`, and the hook itself captures only for bound
# chats. The repo is --repo, else $CLAUDE_PROJECT_DIR, else the git top level of
# the current directory; the Firstmate repo is skipped (its tracked settings
# already carry the hook). The edit is append-only: existing settings are kept
# byte-for-byte apart from the one added entry, a backup is written first, an
# unparseable file is refused rather than rewritten, and
# `.claude/settings.local.json` is added to the repo's local `.git/info/exclude`
# when git would otherwise see it. The repo is recorded on line 2 of the binding
# file; `unbind` removes Firstmate's entry only when no other bound chat still
# records that repo, and deletes the file only if that leaves it empty.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SELF_DIR/.." && pwd)"
FM_HOME="${FM_HOME:-$FM_ROOT}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
BINDINGS="$STATE/session-bindings"
# shellcheck source=bin/fm-sessions-lib.sh disable=SC1091
. "$SELF_DIR/fm-sessions-lib.sh"

die() { printf 'fm-session-bind: %s\n' "$*" >&2; exit 1; }

valid_token() {
  case "$1" in ''|.*|*[!A-Za-z0-9._-]*) return 1 ;; esac
  [ "${#1}" -le 128 ]
}

first_line() { [ -r "$1" ] && sed -n '1{s/[[:space:]]*$//;p;q;}' "$1"; }

chat_id() {  # [<explicit>]
  local id=${1:-${CLAUDE_CODE_SESSION_ID:-}}
  [ -n "$id" ] || return 1
  valid_token "$id" || die "unusable chat id '$id'"
  printf '%s\n' "$id"
}

HOOK_CMD="$FM_ROOT/bin/fm-intake-hook.sh"

# The repo a chat is open in: --repo, else CLAUDE_PROJECT_DIR, else git top level.
chat_repo() {  # [<explicit>]
  local d=${1:-${CLAUDE_PROJECT_DIR:-}}
  [ -n "$d" ] || d=$(git rev-parse --show-toplevel 2>/dev/null || true)
  [ -n "$d" ] && [ -d "$d" ] || return 1
  (cd "$d" && pwd -P)
}

# Add or remove Firstmate's intake hook in <root>/.claude/settings.local.json.
repo_hook() {  # add|remove <root>
  python3 - "$1" "$2/.claude/settings.local.json" "$HOOK_CMD" <<'PY'
import json, os, shutil, sys, tempfile
mode, path, cmd = sys.argv[1:4]
existed = os.path.exists(path)
if existed:
    raw = open(path).read()
    try:
        data = json.loads(raw) if raw.strip() else {}
    except ValueError as exc:
        sys.exit("refusing to edit %s: it is not valid JSON (%s); nothing changed" % (path, exc))
    if not isinstance(data, dict):
        sys.exit("refusing to edit %s: top level is not an object; nothing changed" % path)
else:
    if mode == "remove":
        print("no %s; nothing to remove" % path); sys.exit(0)
    data = {}
groups = data.setdefault("hooks", {}).setdefault("UserPromptSubmit", [])
ours = lambda h: isinstance(h, dict) and h.get("command") == cmd
present = any(ours(h) for g in groups if isinstance(g, dict) for h in g.get("hooks", []))
if mode == "add":
    if present:
        print("intake hook already registered in %s" % path); sys.exit(0)
    groups.append({"hooks": [{"type": "command", "command": cmd, "timeout": 10}]})
else:
    if not present:
        print("intake hook not registered in %s; nothing to remove" % path); sys.exit(0)
    for g in groups:
        if isinstance(g, dict):
            g["hooks"] = [h for h in g.get("hooks", []) if not ours(h)]
    groups[:] = [g for g in groups if not (isinstance(g, dict) and not g.get("hooks"))]
    if not groups:
        del data["hooks"]["UserPromptSubmit"]
    if not data["hooks"]:
        del data["hooks"]
if existed:
    shutil.copy2(path, path + ".bak-firstmate")
if mode == "remove" and not data:
    os.remove(path); print("removed intake hook; %s was left empty and deleted" % path); sys.exit(0)
os.makedirs(os.path.dirname(path), exist_ok=True)
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".settings-")
with os.fdopen(fd, "w") as f:
    json.dump(data, f, indent=2); f.write("\n")
os.replace(tmp, path)
print("%s intake hook in %s" % ("registered" if mode == "add" else "removed", path))
PY
}

# Keep settings.local.json out of git without touching the tracked .gitignore.
repo_exclude() {  # <root>
  local ex
  git -C "$1" rev-parse --git-dir >/dev/null 2>&1 || return 0
  git -C "$1" check-ignore -q .claude/settings.local.json 2>/dev/null && return 0
  ex=$(git -C "$1" rev-parse --git-path info/exclude)
  case "$ex" in /*) ;; *) ex="$1/$ex" ;; esac
  mkdir -p "$(dirname "$ex")"
  printf '%s\n' '.claude/settings.local.json' >>"$ex"
  printf 'added .claude/settings.local.json to %s\n' "$ex"
}

write_atomic() {  # <path> <value>
  local tmp
  mkdir -p "$(dirname "$1")"
  tmp=$(mktemp "$(dirname "$1")/.bind-XXXXXX")
  printf '%s\n' "$2" >"$tmp"
  mv "$tmp" "$1"
}

cmd_bind() {
  local sid=${1:-} chat="" home_default=0 repo_arg="" repo_hook_on=1 root=""
  [ -n "$sid" ] || die "usage: fm-session-bind.sh bind <session> [--chat <id> | --home-default]"
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --chat) [ "$#" -ge 2 ] || die "--chat needs a value"; chat=$2; shift 2 ;;
      --home-default) home_default=1; shift ;;
      --repo) [ "$#" -ge 2 ] || die "--repo needs a value"; repo_arg=$2; shift 2 ;;
      --no-repo-hook) repo_hook_on=0; shift ;;
      *) die "unknown argument '$1'" ;;
    esac
  done
  valid_token "$sid" || die "invalid session id '$sid'"
  [ "$sid" = primary ] || sessions_get "$sid" || die "no session '$sid' (create it with fm-sessions.sh add)"
  if [ "$home_default" -eq 1 ]; then
    write_atomic "$CONFIG/active-session" "$sid"
    printf 'home default session: %s\n' "$sid"
    return 0
  fi
  chat=$(chat_id "$chat") || die "no chat id: CLAUDE_CODE_SESSION_ID is unset here; pass --chat <id> or --home-default"
  if [ "$repo_hook_on" -eq 1 ] && root=$(chat_repo "$repo_arg"); then
    if [ "$root" = "$(cd "$FM_ROOT" && pwd -P)" ]; then
      printf 'Firstmate repo: its tracked settings already carry the intake hook\n'
      root=""
    else
      repo_hook add "$root" || die "the intake hook could not be registered in $root; the chat was NOT bound"
      repo_exclude "$root"
    fi
  elif [ "$repo_hook_on" -eq 1 ]; then
    printf 'warning: no repo found for this chat, so no intake hook was registered; pass --repo <dir>\n' >&2
  fi
  write_atomic "$BINDINGS/$chat" "$sid${root:+
repo=$root}"
  printf 'chat %s bound to session %s\n' "$chat" "$sid"
}

cmd_resolve() {
  local chat sid=""
  if chat=$(chat_id 2>/dev/null) && [ -r "$BINDINGS/$chat" ]; then
    sid=$(first_line "$BINDINGS/$chat")
  fi
  [ -n "$sid" ] || sid=$(first_line "$CONFIG/active-session" || true)
  if [ -n "$sid" ] && valid_token "$sid"; then printf '%s\n' "$sid"; fi
}

cmd_show() {
  local chat
  if chat=$(chat_id 2>/dev/null); then
    printf 'this chat (%s): %s\n' "$chat" "$(first_line "$BINDINGS/$chat" || true)"
  else
    printf 'this chat: (no CLAUDE_CODE_SESSION_ID)\n'
  fi
  printf 'home default: %s\n' "$(first_line "$CONFIG/active-session" || true)"
  printf 'resolves to: %s\n' "$(cmd_resolve)"
}

cmd_unbind() {
  local chat=""
  [ "${1:-}" = --chat ] && chat=${2:-}
  chat=$(chat_id "$chat") || die "no chat id: pass --chat <id>"
  local root="" f
  root=$(sed -n 's/^repo=//p' "$BINDINGS/$chat" 2>/dev/null | head -1)
  rm -f "$BINDINGS/$chat"
  printf 'chat %s unbound\n' "$chat"
  [ -n "$root" ] || return 0
  # Another chat still bound in the same repo keeps the hook.
  for f in "$BINDINGS"/*; do
    [ -f "$f" ] || continue
    if [ "$(sed -n 's/^repo=//p' "$f" | head -1)" = "$root" ]; then
      printf 'kept the intake hook in %s: another chat there is still bound\n' "$root"
      return 0
    fi
  done
  repo_hook remove "$root"
}

case "${1:-}" in
  bind)    shift; cmd_bind "$@" ;;
  resolve) shift; cmd_resolve ;;
  show)    shift; cmd_show ;;
  unbind)  shift; cmd_unbind "$@" ;;
  *) die "usage: fm-session-bind.sh {bind|resolve|show|unbind} ..." ;;
esac
