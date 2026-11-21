#!/usr/bin/env bash
# tests/fm-running.test.sh - the read-only running view prints every section and
# changes nothing. Uses a fixture home so it runs in well under a second.
set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-running)
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR"/{state/session-bindings,data,config}
printf -- '- demo - Demo work (kind: theme; repos: repoa; home: primary; added 2026-11-21)\n' >"$HOME_DIR/data/sessions.md"
printf 'demo\n' >"$HOME_DIR/config/active-session"
printf 'demo\n' >"$HOME_DIR/state/session-bindings/chat-1"

test_running_view_has_every_section() {
  local out before after
  before=$(find "$HOME_DIR" -type f | sort | xargs cat 2>/dev/null | cksum)
  out=$(FM_HOME="$HOME_DIR" FM_RUNNING_TIMEOUT=5 "$ROOT/bin/fm-running.sh")
  for s in "== FLEET ==" "== SESSIONS ==" "== BOUND CHATS ==" "== INTAKE" "== SERVICES =="; do
    case "$out" in *"$s"*) ;; *) fail "missing section: $s" ;; esac
  done
  case "$out" in *"chat-1"*"-> demo"*) ;; *) fail "bound chat not shown" ;; esac
  after=$(find "$HOME_DIR" -type f | sort | xargs cat 2>/dev/null | cksum)
  [ "$before" = "$after" ] || fail "the running view changed a file"
  pass "the running view prints every section, shows bound chats, and changes nothing"
}

test_running_view_skill_is_registered() {
  grep -q '^name: running$' "$ROOT/.agents/skills/running/SKILL.md" || fail "skill frontmatter missing"
  grep -q '^user-invocable: true$' "$ROOT/.agents/skills/running/SKILL.md" || fail "skill not user-invocable"
  grep -q 'fm-running.sh' "$ROOT/.agents/skills/running/SKILL.md" || fail "skill does not call the view"
  pass "the running skill is user-invocable and calls the view"
}

fm_test_run \
  test_running_view_has_every_section \
  test_running_view_skill_is_registered
