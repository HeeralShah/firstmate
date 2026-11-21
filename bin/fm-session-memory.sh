#!/usr/bin/env bash
# fm-session-memory.sh - a session's durable memory and its meta-rule guide.
#
# Two files per session, with different jobs (docs/session-context.md):
#   memory.md  durable CONTENT memory: facts, findings and gotchas about the
#              task, in the stow tier format so they decay instead of piling up.
#   guide.md   META-rules: how this captain wants the session run (interaction,
#              organisation, answer style, review rhythm), curated iteratively.
# Decisions are a third file, decisions.md, appended by fm-intake when a
# decision is answered; this script never writes it.
#
# Usage:
#   fm-session-memory.sh add <session> [--pin|--perishable] <one-line text>
#   fm-session-memory.sh reinforce <session> <substring>   refresh an entry's date
#   fm-session-memory.sh list <session>
#   fm-session-memory.sh review <session>      is a review due; which entries are stale
#   fm-session-memory.sh reviewed <session>    record that a review happened today
#   fm-session-memory.sh archive-stale <session>   move stale entries to the cold archive
#   fm-session-memory.sh guide <session> add <one-line rule>   record a dated meta-rule
#
# Mechanics only: markers, dedupe, ageing, cadence and the archive. What to
# remember, merge or rewrite is the agent's judgment under the stow rules.
# Review and staleness follow session ACTIVITY (messages captured for the
# session) and memory SIZE, with calendar days only as a floor for quiet sessions;
# every limit is a `key: value` line in the guide. Stale entries are moved, never
# deleted. See bin/fm_session_memory.py for the settings and defaults.
set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
command -v python3 >/dev/null 2>&1 || { echo "fm-session-memory: python3 is required" >&2; exit 1; }
exec python3 "$SELF_DIR/fm_session_memory.py" "$@"
