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
#                                          compact markdown state card rebuilt with
#                                          no model; --rehydrate is the form
#                                          bin/fm-session-start.sh prints, including
#                                          on its --reemit after compaction
#   fm-dashboard.sh render <session> [--out FILE]
#                                          one static read-only HTML snapshot
#
# `primary` names the main home as a session. Every page is derived on each
# request from the intake log, session files, upstream's fleet snapshot and git,
# so a restart loses nothing; a failed snapshot is shown as unavailable, never as
# an empty fleet. Decisions and notes POST to the local server only (loopback
# bind and Host check, a required header, an origin check), are logged through
# bin/fm-intake.sh, and decisions are applied through fm-send --resolve-key or
# fm-captain-hold.sh answers. FM_SNAPSHOT_TIMEOUT bounds the snapshot (default
# 60 s). Contract: docs/session-context.md.
set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
command -v python3 >/dev/null 2>&1 || { echo "fm-dashboard: python3 is required" >&2; exit 1; }
exec python3 "$SELF_DIR/fm_dashboard.py" "$@"
