#!/usr/bin/env bash
# tests/fm-session-bind.test.sh - chat-to-session binding and the session work ledger.
#
# Covers: a chat binding wins over the home default and two chats can follow
# two sessions; the session-start digest loads the bound chat's card; binding
# refuses an unknown session or a missing chat id; `survey` and `record` leave
# the original repo byte-identical; the recorded patch restores on its recorded
# base; a session clone keeps branches that were never pushed; `adopt` needs an
# explicit branch and never overwrites a differing branch; and a --session
# brief carries the work ledger; the user-level card hook loads only a chat's
# own binding and stays silent inside Firstmate.
set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-session-bind)
BIND="$ROOT/bin/fm-session-bind.sh"
WORK="$ROOT/bin/fm-session-work.sh"
HOME_DIR="$TMP_ROOT/home"
SRC="$TMP_ROOT/src"
mkdir -p "$HOME_DIR"/{state,data,config} "$SRC/repoa"
git -C "$SRC/repoa" init -q -b main
printf 'a\n' >"$SRC/repoa/a"
git -C "$SRC/repoa" add a
git -C "$SRC/repoa" -c user.email=t@t -c user.name=t commit -q -m init
git -C "$SRC/repoa" checkout -q -b feature/x
printf 'b\n' >"$SRC/repoa/b"
git -C "$SRC/repoa" add b
git -C "$SRC/repoa" -c user.email=t@t -c user.name=t commit -q -m wip
printf 'changed\n' >>"$SRC/repoa/a"
printf 'staged\n' >"$SRC/repoa/c"
git -C "$SRC/repoa" add c
printf 'junk\n' >"$SRC/repoa/untracked.txt"

export FM_HOME="$HOME_DIR"
STATE_DIR="$HOME_DIR/state"
export FM_SNAPSHOT_BIN="$TMP_ROOT/snap.sh"
printf '#!/usr/bin/env bash\necho "{\\"tasks\\":[],\\"backlog\\":{\\"records\\":[]}}"\n' >"$FM_SNAPSHOT_BIN"
chmod +x "$FM_SNAPSHOT_BIN"
"$ROOT/bin/fm-projects-root.sh" set "$SRC" >/dev/null
"$ROOT/bin/fm-sessions.sh" add alpha --summary "Alpha work" --kind theme --repos repoa >/dev/null
"$ROOT/bin/fm-sessions.sh" add beta --summary "Beta work" --kind theme --repos repoa >/dev/null

source_state() { (cd "$SRC/repoa" && git status --porcelain && git rev-parse HEAD && git stash list && git for-each-ref); }
BEFORE=$(source_state)

test_chat_binding_wins_over_home_default() {
  "$BIND" bind beta --home-default >/dev/null
  CLAUDE_CODE_SESSION_ID=chat-1 "$BIND" bind alpha >/dev/null
  [ "$(CLAUDE_CODE_SESSION_ID=chat-1 "$BIND" resolve)" = alpha ] || fail "bound chat did not resolve to its session"
  [ "$(CLAUDE_CODE_SESSION_ID=chat-2 "$BIND" resolve)" = beta ] || fail "unbound chat did not fall back to the home default"
  pass "a chat's binding wins over the home default, and another chat falls back to it"
}

test_binding_refuses_guesses() {
  if CLAUDE_CODE_SESSION_ID=chat-1 "$BIND" bind nosuch >/dev/null 2>&1; then fail "bound an unknown session"; fi
  if env -u CLAUDE_CODE_SESSION_ID "$BIND" bind alpha >/dev/null 2>&1; then fail "bound without a chat id"; fi
  pass "binding refuses an unknown session and a missing chat id"
}

test_digest_loads_the_bound_chats_card() {
  local out
  out=$(CLAUDE_CODE_SESSION_ID=chat-1 "$ROOT/bin/fm-session-start.sh" --reemit 2>&1 || true)
  case "$out" in *"session context: alpha"*) ;; *) fail "digest did not load the bound session" ;; esac
  out=$(CLAUDE_CODE_SESSION_ID=chat-2 "$ROOT/bin/fm-session-start.sh" --reemit 2>&1 || true)
  case "$out" in *"session context: beta"*) ;; *) fail "digest did not fall back to the home default" ;; esac
  pass "the session-start digest loads the card of the session this chat is bound to"
}

test_survey_and_record_leave_the_original_untouched() {
  local out
  out=$("$WORK" survey "$SRC/repoa")
  case "$out" in *"1 staged, 1 unstaged, 1 untracked"*"feature/x"*) ;; *) fail "survey wrong: $out" ;; esac
  "$WORK" record alpha "$SRC/repoa" >/dev/null
  [ "$(source_state)" = "$BEFORE" ] || fail "survey or record changed the original repo"
  grep -q "untracked.txt" "$HOME_DIR/data/sessions/alpha/work.md" || fail "untracked file not listed"
  ls "$HOME_DIR/data/sessions/alpha/work/"*.patch >/dev/null 2>&1 || fail "no patch copy recorded"
  pass "survey and record leave the original byte-identical and list untracked files"
}

test_recorded_patch_restores_on_its_base() {
  local base patch tmp="$TMP_ROOT/restore"
  base=$(grep -o 'against base `[0-9a-f]*' "$HOME_DIR/data/sessions/alpha/work.md" | head -1 | awk '{print $3}' | tr -d '`')
  patch=$(ls "$HOME_DIR/data/sessions/alpha/work/"*.patch | head -1)
  git clone -q "$SRC/repoa" "$tmp"
  git -C "$tmp" checkout -q "$base"
  git -C "$tmp" apply --index "$patch" || fail "recorded patch does not apply on its recorded base"
  [ "$(cat "$tmp/c")" = staged ] && grep -q changed "$tmp/a" || fail "restored content differs"
  pass "the recorded patch restores the uncommitted changes on the recorded base"
}

test_session_clone_keeps_unpushed_branches_and_adopt_is_explicit() {
  local dest="$HOME_DIR/projects/repoa/alpha"
  "$ROOT/bin/fm-session-checkout.sh" create alpha >/dev/null 2>&1
  git -C "$dest" rev-parse -q --verify refs/remotes/source/feature/x >/dev/null || fail "unpushed source branch unreachable in the clone"
  if "$WORK" adopt alpha "$SRC/repoa" >/dev/null 2>&1; then fail "adopt ran without a named branch"; fi
  git -C "$dest" branch -q -D feature/x 2>/dev/null || true
  "$WORK" adopt alpha "$SRC/repoa" --branch feature/x >/dev/null
  [ "$(git -C "$dest" rev-parse feature/x)" = "$(git -C "$SRC/repoa" rev-parse feature/x)" ] || fail "adopted branch at the wrong commit"
  git -C "$dest" branch -q -f feature/x main
  if "$WORK" adopt alpha "$SRC/repoa" --branch feature/x >/dev/null 2>&1; then fail "adopt overwrote a differing branch"; fi
  [ "$(source_state)" = "$BEFORE" ] || fail "adopt changed the original repo"
  pass "a session clone keeps unpushed branches, adopt needs a named branch, never overwrites one, and never touches the original"
}

test_session_brief_carries_the_work_ledger() {
  "$ROOT/bin/fm-brief.sh" t1 repoa --mode local-only --session alpha >/dev/null 2>&1 || fail "brief failed"
  case "$(cat "$HOME_DIR/data/t1/brief.md")" in *"Session work ledger"*"untracked.txt"*) ;; *) fail "brief lacks the work ledger" ;; esac
  pass "a --session brief carries the work ledger so a worker can restore recorded work"
}

test_user_hook_reloads_only_bound_chats_outside_firstmate() {
  local hook="$ROOT/bin/fm-session-card-hook.sh" out
  out=$(cd "$TMP_ROOT" && printf '{}' | CLAUDE_CODE_SESSION_ID=chat-1 "$hook")
  case "$out" in *"bound to Firstmate session alpha"*"Trust this over anything remembered"*) ;; *) fail "bound chat got no card: $out" ;; esac
  out=$(cd "$TMP_ROOT" && printf '{}' | CLAUDE_CODE_SESSION_ID=chat-2 "$hook")
  [ -z "$out" ] || fail "an unbound chat got the home default injected: $out"
  out=$(cd "$ROOT" && printf '{}' | CLAUDE_CODE_SESSION_ID=chat-1 "$hook")
  [ -z "$out" ] || fail "hook duplicated the digest inside Firstmate"
  pass "the user-level hook reloads the card only for a chat bound in its own right, and stays silent inside Firstmate"
}

test_bind_registers_the_intake_hook_in_the_chats_repo() {
  local r="$TMP_ROOT/chatrepo" wt="$TMP_ROOT/chatrepo-wt" settings out
  git init -q -b main "$r"
  git -C "$r" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  mkdir -p "$r/.claude"
  printf '{\n  "permissions": {"allow": ["Bash(ls)"]},\n  "hooks": {"UserPromptSubmit": [{"hooks": [{"type": "command", "command": "/their/own.sh"}]}]}\n}\n' >"$r/.claude/settings.local.json"
  settings="$r/.claude/settings.local.json"
  CLAUDE_CODE_SESSION_ID=rchat-1 "$BIND" bind alpha --repo "$r" >/dev/null
  grep -q 'fm-intake-hook.sh' "$settings" || fail "hook not registered in the chat's repo"
  grep -q '/their/own.sh' "$settings" && grep -q 'Bash(ls)' "$settings" || fail "existing settings were not kept"
  [ -f "$settings.bak-firstmate" ] || fail "no backup written before editing"
  git -C "$r" check-ignore -q .claude/settings.local.json || fail "settings.local.json not excluded from git"
  CLAUDE_CODE_SESSION_ID=rchat-1 "$BIND" bind alpha --repo "$r" >/dev/null
  [ "$(grep -c 'fm-intake-hook.sh' "$settings")" = 1 ] || fail "re-binding added a second entry"
  git -C "$r" worktree add -q "$wt" -b wt-branch
  CLAUDE_CODE_SESSION_ID=rchat-wt "$BIND" bind alpha --repo "$wt" >/dev/null
  grep -q 'fm-intake-hook.sh' "$wt/.claude/settings.local.json" || fail "a worktree chat did not get its own registration"
  CLAUDE_CODE_SESSION_ID=rchat-2 "$BIND" bind alpha --repo "$r" >/dev/null
  CLAUDE_CODE_SESSION_ID=rchat-1 "$BIND" unbind >/dev/null
  grep -q 'fm-intake-hook.sh' "$settings" || fail "unbinding one chat removed the hook another bound chat in that repo needs"
  CLAUDE_CODE_SESSION_ID=rchat-2 "$BIND" unbind >/dev/null
  grep -q 'fm-intake-hook.sh' "$settings" && fail "unbinding the last chat left the hook"
  grep -q '/their/own.sh' "$settings" && grep -q 'Bash(ls)' "$settings" || fail "unbind damaged the captain's own settings"
  printf '{ not json' >"$TMP_ROOT/bad.json"
  mkdir -p "$TMP_ROOT/badrepo/.claude" && cp "$TMP_ROOT/bad.json" "$TMP_ROOT/badrepo/.claude/settings.local.json"
  if out=$(CLAUDE_CODE_SESSION_ID=rchat-3 "$BIND" bind alpha --repo "$TMP_ROOT/badrepo" 2>&1); then fail "bound despite unparseable settings: $out"; fi
  cmp -s "$TMP_ROOT/bad.json" "$TMP_ROOT/badrepo/.claude/settings.local.json" || fail "unparseable settings were rewritten"
  [ ! -e "$STATE_DIR/session-bindings/rchat-3" ] || fail "chat was bound although its hook could not be registered"
  out=$(CLAUDE_CODE_SESSION_ID=rchat-4 "$BIND" bind alpha --repo "$ROOT" 2>&1)
  case "$out" in *"tracked settings already carry"*) ;; *) fail "Firstmate repo was not skipped: $out" ;; esac
  pass "bind registers the intake hook in the chat's own repo or worktree, keeps existing settings, and unbind removes it only after the last chat there"
}

test_skill_is_registered() {
  grep -q '^name: bind-session$' "$ROOT/.agents/skills/bind-session/SKILL.md" || fail "skill frontmatter missing"
  grep -q '^user-invocable: true$' "$ROOT/.agents/skills/bind-session/SKILL.md" || fail "skill not user-invocable"
  grep -q '`/bind-session' "$ROOT/README.md" || fail "skill missing from the README command table"
  grep -q 'ask the captain for the path to their Firstmate repo' "$ROOT/.agents/skills/bind-session/SKILL.md" || fail "skill lacks the ask-for-path fallback"
  grep -q 'never search the disk' "$ROOT/.agents/skills/bind-session/SKILL.md" || fail "skill lookup is not bounded"
  pass "the bind-session skill is user-invocable, listed in the README, and finds Firstmate or asks for its path"
}

fm_test_run \
  test_chat_binding_wins_over_home_default \
  test_binding_refuses_guesses \
  test_digest_loads_the_bound_chats_card \
  test_survey_and_record_leave_the_original_untouched \
  test_recorded_patch_restores_on_its_base \
  test_session_clone_keeps_unpushed_branches_and_adopt_is_explicit \
  test_session_brief_carries_the_work_ledger \
  test_user_hook_reloads_only_bound_chats_outside_firstmate \
  test_bind_registers_the_intake_hook_in_the_chats_repo \
  test_skill_is_registered
