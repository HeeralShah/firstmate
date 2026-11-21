#!/usr/bin/env bash
# fm-session-card-hook.sh - user-level Claude Code SessionStart hook that reloads
# a bound chat's session card in ANY repository.
#
# Inside the Firstmate repo, bin/fm-session-start.sh already prints the card (on
# startup, /clear and compaction through the existing project hook), so this
# hook stays silent there. Elsewhere it prints the card only when THIS chat has
# its own binding (state/session-bindings/<CLAUDE_CODE_SESSION_ID>, written by
# /bind-session). The home default is deliberately ignored here: it must never
# inject a session into every chat in every repo. Claude Code adds a
# SessionStart hook's stdout to the chat's context.
#
# Register in ~/.claude/settings.json (firstmate never edits that file itself):
#   {"hooks":{"SessionStart":[{"hooks":[{"type":"command",
#     "command":"/abs/path/to/firstmate/bin/fm-session-card-hook.sh","timeout":30}]}]}}
#
# Always exits 0: a hook failure must never block a chat from opening.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SELF_DIR/.." && pwd -P)"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
cat >/dev/null 2>&1 || true  # drain the hook payload

chat=${CLAUDE_CODE_SESSION_ID:-}
case "$chat" in ''|.*|*[!A-Za-z0-9._-]*) exit 0 ;; esac
# Inside Firstmate the digest already prints the card: stay silent.
here=$(pwd -P 2>/dev/null || pwd)
case "$here/" in "$FM_ROOT/"*) exit 0 ;; esac
[ -r "$STATE/session-bindings/$chat" ] || exit 0
sid=$(sed -n '1{s/[[:space:]]*$//;p;q;}' "$STATE/session-bindings/$chat")
case "$sid" in ''|.*|*[!A-Za-z0-9._-]*) exit 0 ;; esac
printf 'This chat is bound to Firstmate session %s; its state card follows.\n\n' "$sid"
FM_HOME="$FM_HOME" FM_SNAPSHOT_TIMEOUT="${FM_SESSION_CARD_SNAPSHOT_TIMEOUT:-20}" \
  "$SELF_DIR/fm-dashboard.sh" card "$sid" --rehydrate 2>/dev/null || printf '(session card unavailable)\n'
exit 0
