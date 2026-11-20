#!/usr/bin/env bash
# fm-intake.sh - fire-and-forget intake with a durable log.
#
# Send a message and forget it: it is saved and given an id (M-0001...) by plain
# code, triaged afterwards by a tool-less model call that can only classify, and
# delivered into the right session's inbox. Nothing here asks the working agent
# to remember anything; the log (state/intake/log.jsonl) and the target home's
# handled/ directory are the record. Full contract: bin/fm_intake.py header and
# docs/intake.md.
#
# Usage:
#   fm-intake.sh add [--session <id>] [--no-triage] <text>...   (or: add -)
#   fm-intake.sh list [--all] [--json]    open messages (all = include settled)
#   fm-intake.sh show M-NNNN              full history and body
#   fm-intake.sh check                    fidelity audit; exit 1 if anything is stuck
#   fm-intake.sh retry                    re-run triage/delivery for unsettled messages
#   fm-intake.sh route M-NNNN <session>   override a mis-triage and re-deliver
#   fm-intake.sh close M-NNNN [reason]    captain closes a message (answered elsewhere)
#   fm-intake.sh snapshot                 rewrite state/intake/snapshot.json
#
# Deterministic prefixes (no model): `@<session> text` routes to that session,
# and `D3: text` / `answer <key>: text` is a decision answer.
#
# Config (gitignored config/): intake-triage = `model` (default) or `rules`;
# intake-triage-model = a model id for the triage call (default: harness default).
# Environment: FM_HOME, FM_INTAKE_NO_TRIAGE=1 (capture only, for tests).
#
# Python3 is required; a firstmate home already depends on it.
set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
command -v python3 >/dev/null 2>&1 || { echo "fm-intake: python3 is required" >&2; exit 1; }
exec python3 "$SELF_DIR/fm_intake.py" "$@"
