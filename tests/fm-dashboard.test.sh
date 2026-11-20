#!/usr/bin/env bash
# tests/fm-dashboard.test.sh - session state card, rehydration form, dashboard page,
# and the decision endpoint that writes to the intake log.
#
# Covers: the card is rebuilt from disk (plan, open decision, branch), the
# rehydrate form tells the agent to trust the card over memory, a decision shows
# until an answer is logged and then drops, the server refuses a POST without the
# dashboard header, and an accepted decision lands in the log routed to the session.
set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-dashboard)
DASH="$ROOT/bin/fm-dashboard.sh"
INTAKE="$ROOT/bin/fm-intake.sh"
HOME_DIR="$TMP_ROOT/home"
REPOS="$TMP_ROOT/repos"
mkdir -p "$HOME_DIR"/{state,data,config} "$REPOS/repoa"
git -C "$REPOS/repoa" init -q -b main
git -C "$REPOS/repoa" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$REPOS/repoa" checkout -q -b fm/sharpe
printf 'x\n' >"$REPOS/repoa/a.py"
git -C "$REPOS/repoa" add -A
git -C "$REPOS/repoa" -c user.email=t@t -c user.name=t commit -q -m "add sharpe"
git -C "$REPOS/repoa" checkout -q main

export FM_HOME="$HOME_DIR"
export FM_INTAKE_NO_TRIAGE=1
"$ROOT/bin/fm-projects-root.sh" set "$REPOS" >/dev/null
"$ROOT/bin/fm-sessions.sh" add quant --summary "Quant model work" --kind theme --repos repoa >/dev/null
printf -- '- [x] Reference data in\n- [~] Sharpe plot in review\n- [!] Vol surface blocked\n' >"$HOME_DIR/data/sessions/quant/plan.md"
printf '2026-11-20T10:05:00Z needs-decision [key=D4]: Use log or simple returns?\n' >"$HOME_DIR/state/sharpe.status"

test_card_is_rebuilt_from_disk() {
  local card
  card=$("$DASH" card quant)
  case "$card" in
    *"1 accepted, 1 in review, 1 blocked"*"D4"*"fm/sharpe: 1 ahead of main"*) ;;
    *) fail "card missing facts: $card" ;;
  esac
  pass "card is rebuilt from the plan, open decision and branch state on disk"
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

test_static_page_has_decision_ui() {
  local page
  page=$("$DASH" render quant)
  case "$page" in
    *"Progress"*"D4"*"Send decision"*"Code changes"*) ;;
    *) fail "page lacks sections" ;;
  esac
  pass "static page renders progress, decisions with buttons, and code changes"
}

test_server_decision_flow() {
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
  case "$out" in *'"id": "M-0001"'*) ;; *) kill "$pid" 2>/dev/null; fail "decision not accepted: $out" ;; esac
  case "$("$INTAKE" show M-0001)" in *"answer D4: simple returns"*) ;; *) kill "$pid" 2>/dev/null; fail "answer not in log" ;; esac
  curl -s "http://127.0.0.1:$port/s/quant" | grep -q "Send decision" && { kill "$pid" 2>/dev/null; fail "answered decision still listed"; }
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  pass "server rejects headerless POSTs, logs a decision routed to the session, and drops it from the page"
}

fm_test_run \
  test_card_is_rebuilt_from_disk \
  test_rehydrate_prefers_disk_over_memory \
  test_static_page_has_decision_ui \
  test_server_decision_flow
