#!/usr/bin/env bash
# tests/fm-dashboard.test.sh - session state card, rehydration form, dashboard page,
# and decisions applied through upstream's own answer paths.
#
# Worker state and open decisions come from fm-fleet-snapshot.sh --json (never a
# status-log tail), so these tests stand a fake snapshot in through FM_SNAPSHOT_BIN
# and fake fm-send / fm-captain-hold through FM_SEND_BIN / FM_CAPTAIN_HOLD_BIN that
# record their arguments and make the fake snapshot stop listing a closed decision.
set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-dashboard)
DASH="$ROOT/bin/fm-dashboard.sh"
INTAKE="$ROOT/bin/fm-intake.sh"
HOME_DIR="$TMP_ROOT/home"
REPOS="$TMP_ROOT/repos"
FAKE="$TMP_ROOT/fake"
mkdir -p "$HOME_DIR"/{state,data,config} "$REPOS/repoa" "$FAKE"
git -C "$REPOS/repoa" init -q -b main
git -C "$REPOS/repoa" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$REPOS/repoa" checkout -q -b fm/sharpe
printf 'x\n' >"$REPOS/repoa/a.py"
git -C "$REPOS/repoa" add -A
git -C "$REPOS/repoa" -c user.email=t@t -c user.name=t commit -q -m "add sharpe"
git -C "$REPOS/repoa" checkout -q main

# Fake snapshot: lists D4 (worker decision) and hold-1 (captain hold) until closed.
cat >"$FAKE/snapshot.sh" <<SNAP
#!/usr/bin/env bash
d4='{"key":"D4","verb":"needs-decision","summary":"Use log or simple returns?"}'
[ -e "$FAKE/closed-D4" ] && d4=''
hold='{"id":"hold-1","captain_actionable":true,"title":"Pick data vendor","hold_reason":"vendor choice"}'
[ -e "$FAKE/closed-hold-1" ] && hold=''
[ -e "$FAKE/snapshot-broken" ] && { echo "boom" >&2; exit 3; }
printf '{"tasks":[{"id":"sharpe","kind":"ship","project":"$REPOS/repoa","branch":"fm/sharpe","current_state":{"state":"needs-decision","detail":"waiting on a call"},"hints":{"open_decisions":[%s],"last_event_text":""},"paths":{"worktree":{"path":null,"present":false},"status_log":{"last_event":{"age_seconds":120}}}},{"id":"other","kind":"ship","project":"$REPOS/elsewhere","branch":null,"current_state":{"state":"needs-decision"},"hints":{"open_decisions":[{"key":"X1","verb":"needs-decision","summary":"Not this session"}]},"paths":{}}],"backlog":{"records":[%s]}}\n' "\$d4" "\$hold"
SNAP
cat >"$FAKE/send.sh" <<SEND
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$FAKE/send.log"
touch "$FAKE/closed-D4"
SEND
cat >"$FAKE/hold.sh" <<HOLD
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$FAKE/hold.log"
cat >>"$FAKE/hold.stdin"
touch "$FAKE/closed-hold-1"
HOLD
chmod +x "$FAKE"/*.sh

export FM_HOME="$HOME_DIR"
export FM_INTAKE_NO_TRIAGE=1
export FM_SNAPSHOT_BIN="$FAKE/snapshot.sh" FM_SEND_BIN="$FAKE/send.sh" FM_CAPTAIN_HOLD_BIN="$FAKE/hold.sh"
"$ROOT/bin/fm-projects-root.sh" set "$REPOS" >/dev/null
"$ROOT/bin/fm-sessions.sh" add quant --summary "Quant model work" --kind theme --repos repoa >/dev/null
printf -- '- [x] Reference data in\n- [~] Sharpe plot in review\n- [!] Vol surface blocked\n' >"$HOME_DIR/data/sessions/quant/plan.md"

test_card_is_rebuilt_from_disk_and_snapshot() {
  local card
  card=$("$DASH" card quant)
  case "$card" in
    *"D4"*"hold-1"*"1 accepted, 1 in review, 1 blocked"*"sharpe: needs-decision"*"fm/sharpe: 1 ahead of main"*) ;;
    *) fail "card missing facts: $card" ;;
  esac
  case "$card" in *X1*) fail "another session's decision leaked into this card" ;; esac
  pass "card is rebuilt from the plan, this session's snapshot decisions, worker state and task branches"
}

test_card_carries_guide_decisions_and_memory() {
  local card
  "$ROOT/bin/fm-session-memory.sh" add quant --pin "PINNED_FACT" >/dev/null
  "$ROOT/bin/fm-session-memory.sh" guide quant add "Answer outcome-first" >/dev/null
  printf -- '- 2026-11-20 D1: use log returns (M-0099)\n' >>"$HOME_DIR/data/sessions/quant/decisions.md"
  card=$("$DASH" card quant)
  case "$card" in
    *"Decisions already made"*"use log returns"*"Session guide"*"Answer outcome-first"*"Session memory"*"PINNED_FACT"*"MEMORY REVIEW DUE"*) ;;
    *) fail "card lacks guide, decisions, memory or review flag: $card" ;;
  esac
  pass "card carries the guide rules, decisions already made, session memory and a review-due flag"
}

test_rehydrate_prefers_disk_over_memory() {
  local out
  out=$("$DASH" card quant --rehydrate)
  case "$out" in
    *"Trust this over anything remembered"*"Session instructions"*"state card"*) ;;
    *) fail "rehydrate form wrong: $out" ;;
  esac
  pass "rehydrate form puts instructions and the card behind a trust-disk-over-memory rule"
}

test_session_start_digest_prints_the_card() {
  local out
  printf 'quant\n' >"$HOME_DIR/config/active-session"
  out=$(FM_HOME="$HOME_DIR" "$ROOT/bin/fm-session-start.sh" --reemit 2>&1 || true)
  case "$out" in
    *"session context: quant"*"Trust this over anything remembered"*) ;;
    *) fail "digest lacks the session card: $(printf '%s' "$out" | tail -20)" ;;
  esac
  rm -f "$HOME_DIR/config/active-session"
  pass "the existing session-start re-emit path prints the active session's card"
}

test_static_page_has_decision_ui() {
  local page
  page=$("$DASH" render quant)
  case "$page" in
    *"Progress"*"D4"*"Send decision"*"Code changes"*) ;;
    *) fail "page lacks sections" ;;
  esac
  pass "static page renders progress, decisions with buttons, and code changes"
}

test_server_decisions_apply_through_upstream_paths() {
  local port=$((20000 + RANDOM % 20000)) pid out code
  "$DASH" serve --port "$port" >/dev/null 2>&1 &
  pid=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    curl -s "http://127.0.0.1:$port/api/health" >/dev/null 2>&1 && break
    sleep 0.3
  done
  code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$port/api/note" -d '{"session":"quant","text":"x"}')
  [ "$code" = 403 ] || { kill "$pid" 2>/dev/null; fail "POST without header returned $code"; }
  out=$(curl -s -X POST "http://127.0.0.1:$port/api/decision" -H 'X-FM-Dashboard: 1' \
    -H 'Content-Type: application/json' -d '{"session":"quant","key":"D4","answer":"simple returns"}')
  case "$out" in *'"state": "applied"'*) ;; *) kill "$pid" 2>/dev/null; fail "worker decision not applied: $out" ;; esac
  grep -q "fm-sharpe --resolve-key D4 simple returns" "$FAKE/send.log" || { kill "$pid" 2>/dev/null; fail "fm-send not called with --resolve-key"; }
  out=$(curl -s -X POST "http://127.0.0.1:$port/api/decision" -H 'X-FM-Dashboard: 1' \
    -H 'Content-Type: application/json' -d '{"session":"quant","key":"hold-1","answer":"Use vendor B"}')
  case "$out" in *'"state": "applied"'*) ;; *) kill "$pid" 2>/dev/null; fail "hold decision not applied: $out" ;; esac
  grep -q "^answers --source intake:M-" "$FAKE/hold.log" || { kill "$pid" 2>/dev/null; fail "fm-captain-hold answers not called"; }
  grep -q "hold-1.*Use vendor B" "$FAKE/hold.stdin" || { kill "$pid" 2>/dev/null; fail "keyed answer line wrong"; }
  curl -s "http://127.0.0.1:$port/s/quant" | grep -q "Send decision" && { kill "$pid" 2>/dev/null; fail "closed decisions still listed"; }
  out=$(curl -s -X POST "http://127.0.0.1:$port/api/decision" -H 'X-FM-Dashboard: 1' \
    -H 'Content-Type: application/json' -d '{"session":"quant","key":"ghost","answer":"x"}')
  case "$out" in *'"state": "delivered"'*"no open decision"*) ;; *) kill "$pid" 2>/dev/null; fail "unknown key did not fall back to delivery: $out" ;; esac
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  pass "dashboard decisions close through fm-send --resolve-key and fm-captain-hold answers, and an unknown key falls back to delivery"
}

test_long_card_keeps_lines_and_priorities() {
  local card sd="$HOME_DIR/data/sessions/quant" i
  python3 -c "print('Summary sentence. ' * 400)" >"$sd/summary.md"
  for i in $(seq 1 40); do "$ROOT/bin/fm-session-memory.sh" add quant "fact $i about calibration and vendor data quality checks" >/dev/null; done
  cp "$sd/plan.md" "$sd/plan.md.keep"
  for i in $(seq 1 80); do printf -- '- [ ] step %s: reconcile the curve inputs against the reference pricer output\n' "$i" >>"$sd/plan.md"; done
  card=$("$DASH" card quant)
  mv "$sd/plan.md.keep" "$sd/plan.md"
  [ "$(printf '%s\n' "$card" | wc -l | tr -d ' ')" -gt 15 ] || fail "card collapsed onto few lines"
  case "$card" in *"Decisions already made"*"Session guide"*) ;; *) fail "high-priority sections dropped: $card" ;; esac
  case "$card" in *"card trimmed to 700 words; omitted:"*) ;; *) fail "omissions not named" ;; esac
  case "$card" in *"older entries not shown"*) ;; *) fail "hidden memory entries not disclosed" ;; esac
  rm -f "$sd/summary.md"
  pass "a long card keeps its line structure, keeps decisions and the guide, and names what it omitted"
}

test_snapshot_failure_is_shown_not_hidden() {
  local card out
  touch "$FAKE/snapshot-broken"
  card=$("$DASH" card quant)
  case "$card" in *"FLEET SNAPSHOT UNAVAILABLE"*"UNKNOWN, not zero"*) ;; *) rm -f "$FAKE/snapshot-broken"; fail "snapshot failure hidden: $card" ;; esac
  out=$("$DASH" render quant)
  case "$out" in *"Fleet snapshot unavailable"*) ;; *) rm -f "$FAKE/snapshot-broken"; fail "page hides snapshot failure" ;; esac
  case "$out" in *"Nothing is waiting on you"*) rm -f "$FAKE/snapshot-broken"; fail "page claims all clear while blind" ;; esac
  rm -f "$FAKE/snapshot-broken"
  pass "a failed fleet snapshot is shown as unknown on the card and page, never as an all-clear"
}

test_server_refuses_foreign_host() {
  local port=$((20000 + RANDOM % 20000)) pid code
  "$DASH" serve --port "$port" >/dev/null 2>&1 &
  pid=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do curl -s "http://127.0.0.1:$port/api/health" >/dev/null 2>&1 && break; sleep 0.3; done
  code=$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: evil.example' "http://127.0.0.1:$port/s/quant")
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  [ "$code" = 403 ] || fail "foreign Host header served: $code"
  pass "the server refuses requests whose Host is not a loopback name"
}

fm_test_run \
  test_card_is_rebuilt_from_disk_and_snapshot \
  test_card_carries_guide_decisions_and_memory \
  test_rehydrate_prefers_disk_over_memory \
  test_session_start_digest_prints_the_card \
  test_static_page_has_decision_ui \
  test_server_decisions_apply_through_upstream_paths \
  test_long_card_keeps_lines_and_priorities \
  test_snapshot_failure_is_shown_not_hidden \
  test_server_refuses_foreign_host
