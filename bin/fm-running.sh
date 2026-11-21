#!/usr/bin/env bash
# fm-running.sh - one read-only view of everything running right now.
#
# Sections: the fleet (workers, queue, secondmates, via fm-fleet-view.sh), the
# sessions with the chats bound to each, pending intake messages, and the local
# services this layer starts (the dashboard server and any triage in flight).
# It takes no lock, drains no wake and changes nothing, so it is safe to run
# while another session supervises. Every section is bounded by a timeout, so a
# slow part prints a line saying so instead of hanging the view.
#
# Usage: fm-running.sh [--json]   (--json is reserved; the text view is the contract)
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SELF_DIR/.." && pwd)"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
BOUND="${FM_RUNNING_TIMEOUT:-20}"

section() { printf '\n== %s ==\n' "$1"; }
bounded() { timeout "$BOUND" "$@" 2>&1 || printf '(no answer within %ss)\n' "$BOUND"; }

section "FLEET"
bounded "$SELF_DIR/fm-fleet-view.sh"

section "SESSIONS"
if [ -f "$FM_HOME/data/sessions.md" ]; then
  bounded env FM_HOME="$FM_HOME" "$SELF_DIR/fm-sessions.sh" list
else
  printf 'no sessions yet\n'
fi
home_default=$(sed -n '1{s/[[:space:]]*$//;p;q;}' "$CONFIG/active-session" 2>/dev/null || true)
printf 'home default chat session: %s\n' "${home_default:-(none)}"

section "BOUND CHATS"
shown=0
for f in "$STATE"/session-bindings/*; do
  [ -f "$f" ] || continue
  printf '%-40s -> %s\n' "$(basename "$f")" "$(sed -n '1{s/[[:space:]]*$//;p;q;}' "$f")"
  shown=$((shown + 1))
done
[ "$shown" -gt 0 ] || printf 'no chat is bound to a session\n'

section "INTAKE (messages not yet settled)"
if [ -f "$STATE/intake/log.jsonl" ]; then
  open=$(bounded env FM_HOME="$FM_HOME" "$SELF_DIR/fm-intake.sh" list)
  printf '%s\n' "$open"
else
  printf 'no messages captured yet\n'
fi

section "SERVICES"
dash=$(pgrep -fl "fm_dashboard.py serve" 2>/dev/null || true)
if [ -n "$dash" ]; then printf 'dashboard server running:\n%s\n' "$dash"; else printf 'dashboard server: not running\n'; fi
tri=$(pgrep -fl "fm_intake.py triage" 2>/dev/null || true)
if [ -n "$tri" ]; then printf 'triage in flight:\n%s\n' "$tri"; else printf 'triage in flight: none\n'; fi
