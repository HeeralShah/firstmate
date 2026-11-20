#!/usr/bin/env bash
# fm-dashboard.sh - per-session dashboard, state card, and decision server.
#
# Usage:
#   fm-dashboard.sh serve [--port N]       local server on 127.0.0.1 (default 8787,
#                                          or config/dashboard-port): an overview of
#                                          sessions and a page per session with a
#                                          progress tracker, summary, workers, code
#                                          changes, and a Decisions section whose
#                                          buttons write to the intake log
#   fm-dashboard.sh card <session> [--rehydrate]
#                                          compact markdown state card rebuilt from
#                                          disk with no model; --rehydrate is the
#                                          form for a SessionStart(compact) hook
#   fm-dashboard.sh render <session> [--out FILE]
#                                          one static read-only HTML snapshot
#
# `primary` names the main home as a session. Every page is derived from durable
# files on each request, so it cannot disagree with disk and a restart loses
# nothing. Decisions and notes POST to the local server only (loopback bind, a
# required header, and an origin check) and land through bin/fm-intake.sh, so a
# decision is a logged event, not chat. Contract: docs/session-context.md.
set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
command -v python3 >/dev/null 2>&1 || { echo "fm-dashboard: python3 is required" >&2; exit 1; }
exec python3 "$SELF_DIR/fm_dashboard.py" "$@"
