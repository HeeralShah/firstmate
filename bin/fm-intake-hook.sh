#!/usr/bin/env bash
# fm-intake-hook.sh - Claude Code UserPromptSubmit hook: queue-and-block.
#
# Registered by the captain in ~/.claude/settings.json (this script never edits
# settings itself; `fm-intake.sh` docs show the snippet). On every prompt Claude
# Code runs this with the prompt as JSON on stdin. A plain string comparison, not
# a model decision, picks the path:
#
#   prompt starts with the prefix (default `>>`)  -> save to the intake log,
#       start triage in the background, and BLOCK the prompt so the chat agent
#       never sees it; the captain sees "Queued M-0042".
#   anything else                                  -> exit 0, untouched; Claude
#       handles the message exactly as usual.
#
# Prefix: first line of config/intake-prefix, or FM_INTAKE_PREFIX; default `>>`.
# The triage call's own headless Claude run sets FM_INTAKE_TRIAGE=1, which makes
# this hook a no-op so triage can never recurse into capture.
#
# Fails open: if anything goes wrong the prompt passes through and the captain
# is told, because swallowing a prompt silently is worse than a normal turn.
#
# Registered once in the tracked .claude/settings.json (sessions in this repo).
# Registering it in ~/.claude/settings.json as well, for other repos, is safe:
# both hooks see the same session id and prompt, and fm-intake dedupes that key
# within two minutes, so one prompt is one message.
set -uo pipefail

[ "${FM_INTAKE_TRIAGE:-}" = 1 ] && exit 0

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SELF_DIR/.." && pwd)"
FM_HOME="${FM_HOME:-$FM_ROOT}"
export FM_HOME
command -v python3 >/dev/null 2>&1 || exit 0

payload=$(cat)
prefix="${FM_INTAKE_PREFIX:-}"
if [ -z "$prefix" ] && [ -r "$FM_HOME/config/intake-prefix" ]; then
  prefix=$(sed -n '1{s/[[:space:]]*$//;p;q;}' "$FM_HOME/config/intake-prefix")
fi
prefix="${prefix:-">>"}"

# Extract the prompt. Line 1 is the dedupe key (session id + prompt), the rest
# is the body after the prefix; nothing at all when the prefix does not match.
parsed=$(printf '%s' "$payload" | PREFIX="$prefix" python3 -c '
import hashlib, json, os, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
p = d.get("prompt", "") or ""
pre = os.environ["PREFIX"]
s = p.lstrip()
if s.startswith(pre) and s[len(pre):].strip():
    key = hashlib.sha256(((d.get("session_id") or "") + "\0" + p).encode()).hexdigest()[:24]
    sys.stdout.write(key + "\n" + s[len(pre):].lstrip())
') || exit 0
[ -n "$parsed" ] || exit 0
key=${parsed%%$'\n'*}
body=${parsed#*$'\n'}
[ -n "$body" ] || exit 0

if out=$(printf '%s' "$body" | "$SELF_DIR/fm-intake.sh" add --source hook --dedupe-key "$key" - 2>&1); then
  reason="$out"
  decision=block
else
  # Capture failed: let the prompt through rather than lose it.
  printf 'fm-intake hook: capture failed, sending to Claude instead: %s\n' "$out" >&2
  exit 0
fi
printf '%s' "$reason" | python3 -c '
import json, sys
print(json.dumps({"decision": "block", "reason": sys.stdin.read().strip()}))'
