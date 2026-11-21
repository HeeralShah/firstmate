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
#   fm-session-bind.sh bind <session> [--chat <chat-id>]   bind this chat (or the named one)
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

write_atomic() {  # <path> <value>
  local tmp
  mkdir -p "$(dirname "$1")"
  tmp=$(mktemp "$(dirname "$1")/.bind-XXXXXX")
  printf '%s\n' "$2" >"$tmp"
  mv "$tmp" "$1"
}

cmd_bind() {
  local sid=${1:-} chat="" home_default=0
  [ -n "$sid" ] || die "usage: fm-session-bind.sh bind <session> [--chat <id> | --home-default]"
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --chat) [ "$#" -ge 2 ] || die "--chat needs a value"; chat=$2; shift 2 ;;
      --home-default) home_default=1; shift ;;
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
  write_atomic "$BINDINGS/$chat" "$sid"
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
  rm -f "$BINDINGS/$chat"
  printf 'chat %s unbound\n' "$chat"
}

case "${1:-}" in
  bind)    shift; cmd_bind "$@" ;;
  resolve) shift; cmd_resolve ;;
  show)    shift; cmd_show ;;
  unbind)  shift; cmd_unbind "$@" ;;
  *) die "usage: fm-session-bind.sh {bind|resolve|show|unbind} ..." ;;
esac
