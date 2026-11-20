#!/usr/bin/env bash
# tests/fm-intake.test.sh - fire-and-forget intake, sessions registry, projects root.
#
# Covers: capture without a model, deterministic prefix routing, fallback when
# model triage is unavailable (the message is still delivered, never dropped),
# session routing into a secondmate-style home, idempotent re-delivery,
# acknowledgement derived from the target's handled/ directory, the fidelity
# audit flagging a lost body and a failed delivery, the UserPromptSubmit hook's
# block/pass-through split, and the projects-root symlink refusing to clobber
# real clones. The tests share one fixture home and run in order.
set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-intake)
INTAKE="$ROOT/bin/fm-intake.sh"
SESSIONS="$ROOT/bin/fm-sessions.sh"
HOOK="$ROOT/bin/fm-intake-hook.sh"
PROOT="$ROOT/bin/fm-projects-root.sh"

HOME_DIR="$TMP_ROOT/home"
SM_HOME="$TMP_ROOT/sm"
REPOS="$TMP_ROOT/repos"
mkdir -p "$HOME_DIR"/{state,data,config} "$SM_HOME"/{state,data,config} "$REPOS"/{repoa,repob}
git -C "$REPOS/repoa" init -q
git -C "$REPOS/repob" init -q
printf -- '- repoa [local-only] - A (added 2026-11-20)\n' >"$HOME_DIR/data/projects.md"
printf -- '- quant-sm - quant model work (home: %s; scope: quant models; projects: repoa; added 2026-11-20)\n' \
  "$SM_HOME" >"$HOME_DIR/data/secondmates.md"
printf 'rules\n' >"$HOME_DIR/config/intake-triage"

export FM_HOME="$HOME_DIR"
export FM_INTAKE_NO_TRIAGE=1

test_projects_root_links_and_scans() {
  local scan
  "$PROOT" set "$REPOS" >/dev/null
  [ "$(readlink "$HOME_DIR/projects")" = "$(cd "$REPOS" && pwd -P)" ] || fail "set did not link projects/"
  scan=$("$PROOT" scan)
  case "$scan" in
    *repoa*"registered"*repob*"not registered"*) ;;
    *) fail "scan output wrong: $scan" ;;
  esac
  pass "projects root links projects/ to the shared folder and scan reports registration"
}

test_projects_root_refuses_real_clones() {
  rm "$HOME_DIR/projects"
  mkdir -p "$HOME_DIR/projects/clone"
  if "$PROOT" set "$REPOS" >/dev/null 2>&1; then fail "replaced a populated projects/"; fi
  [ -d "$HOME_DIR/projects/clone" ] || fail "refusal still removed the clone"
  rm -r "$HOME_DIR/projects"
  "$PROOT" set "$REPOS" >/dev/null
  pass "projects root refuses to replace real clones and changes nothing"
}

test_sessions_validate_routes() {
  "$SESSIONS" add quant --summary "Quant model work" --kind theme --repos repoa,repob --home quant-sm >/dev/null
  "$SESSIONS" add chores --summary "Small fixes anywhere" --kind chores >/dev/null
  if "$SESSIONS" add ghost --summary "x" --kind theme --repos repoa --home nobody >/dev/null 2>&1; then
    fail "accepted an unknown secondmate"
  fi
  if "$SESSIONS" add bad --summary "x" --kind theme --repos nope >/dev/null 2>&1; then
    fail "accepted a repo outside the projects root"
  fi
  case "$("$SESSIONS" list)" in *quant*quant-sm*chores*) ;; *) fail "list wrong" ;; esac
  pass "sessions add validates secondmate and repos, and list shows both"
}

test_session_instructions_reach_the_brief() {
  local ifile brief
  ifile=$("$SESSIONS" instructions quant)
  [ -r "$ifile" ] || fail "add did not create the instructions stub"
  printf '\nALWAYS_USE_ZSCORE_NORMALISATION\n' >>"$ifile"
  "$ROOT/bin/fm-brief.sh" t1 repoa --mode local-only --session quant >/dev/null 2>&1 || fail "brief with --session failed"
  brief=$(cat "$HOME_DIR/data/t1/brief.md")
  case "$brief" in *"Session instructions (quant)"*ALWAYS_USE_ZSCORE_NORMALISATION*) ;; *) fail "brief lacks session instructions" ;; esac
  if "$ROOT/bin/fm-brief.sh" t2 repoa --mode local-only --session nosuch >/dev/null 2>&1; then fail "brief accepted a session with no file"; fi
  pass "session instructions are created as a stub and inlined into briefs, and a missing file is refused"
}

test_capture_needs_no_model() {
  local out
  out=$("$INTAKE" add "fix typo in readme")
  [ "$out" = "Queued M-0001" ] || fail "capture printed '$out'"
  "$INTAKE" add "@quant add a sharpe plot" >/dev/null
  "$INTAKE" add "D3: yes, option B" >/dev/null
  "$INTAKE" add "python3: command not found is the error" >/dev/null
  pass "capture allocates sequential ids with no model"
}

test_prefix_routing_and_fallback() {
  local i out
  for i in 1 2 3 4; do "$INTAKE" triage "M-000$i"; done
  case "$("$INTAKE" show M-0002)" in *'"session": "quant"'*'"by": "rule"'*) ;; *) fail "@session not routed by rule" ;; esac
  case "$("$INTAKE" show M-0003)" in *decision-answer*'"ref": "D3"'*) ;; *) fail "D3: not a decision answer" ;; esac
  case "$("$INTAKE" show M-0004)" in *decision-answer*) fail "'python3:' misread as a decision" ;; esac
  case "$("$INTAKE" show M-0001)" in *'"by": "fallback"'*) ;; *) fail "model-off message was not marked fallback" ;; esac
  out=$("$INTAKE" list)
  case "$out" in *"M-0001 "*delivered*) ;; *) fail "fallback message was not delivered: $out" ;; esac
  pass "prefixes route by rule and model-off triage falls back to primary but still delivers"
}

test_delivery_into_session_home() {
  local body
  ls "$SM_HOME/state/inbox"/*.note >/dev/null 2>&1 || fail "nothing in the secondmate inbox"
  body=$(cat "$SM_HOME/state/inbox"/*.note)
  case "$body" in *"[intake M-0002 kind=new session=quant]"*sharpe*) ;; *) fail "body lacks header: $body" ;; esac
  pass "quant message lands in the secondmate inbox with id and session header"
}

test_redelivery_is_idempotent() {
  local before after
  before=$(find "$SM_HOME/state/inbox" -name '*.note' | wc -l | tr -d ' ')
  "$INTAKE" route M-0002 quant >/dev/null
  after=$(find "$SM_HOME/state/inbox" -name '*.note' | wc -l | tr -d ' ')
  [ "$before" = "$after" ] || fail "duplicate note: $before -> $after"
  pass "re-delivery reuses the request id and creates no duplicate note"
}

test_ack_is_derived_from_target_handled() {
  local out
  "$INTAKE" check >/dev/null || fail "false alarm while messages are in flight"
  mkdir -p "$SM_HOME/state/inbox/handled"
  mv "$SM_HOME/state/inbox"/*.note "$SM_HOME/state/inbox/handled/"
  out=$("$INTAKE" list --all)
  case "$out" in *"M-0002 "*acked*) ;; *) fail "handled/ did not settle the message: $out" ;; esac
  pass "check is clean in flight and handled/ in the target home settles the message"
}

test_check_flags_lost_body() {
  rm "$HOME_DIR/state/intake/msgs/M-0001.txt"
  if "$INTAKE" check >/dev/null 2>&1; then fail "missed a lost message body"; fi
  pass "check flags a message whose body file is missing"
}

test_unroutable_session_fails_visibly() {
  local out
  printf -- '- orphan - lost route (kind: theme; repos: repoa; home: gone; added 2026-11-20)\n' >>"$HOME_DIR/data/sessions.md"
  "$INTAKE" add "@orphan do a thing" >/dev/null
  "$INTAKE" triage M-0005 || true
  case "$("$INTAKE" show M-0005)" in *delivery_failed*) ;; *) fail "no delivery_failed recorded" ;; esac
  out=$("$INTAKE" check 2>&1 || true)
  case "$out" in *"M-0005: delivery failed"*) ;; *) fail "check missed the failed delivery: $out" ;; esac
  pass "an unroutable session records delivery_failed and check names it"
}

test_hook_blocks_prefixed_only() {
  local out
  out=$(printf '{"prompt":">> remember pineapple"}' | "$HOOK")
  case "$out" in *'"decision": "block"'*"Queued M-0006"*) ;; *) fail "prefixed prompt: $out" ;; esac
  out=$(printf '{"prompt":"hello, normal chat"}' | "$HOOK")
  [ -z "$out" ] || fail "touched a normal prompt: $out"
  out=$(printf '{"prompt":">> nested"}' | FM_INTAKE_TRIAGE=1 "$HOOK")
  [ -z "$out" ] || fail "hook recursed inside the triage call"
  pass "hook blocks only prefixed prompts and is a no-op inside triage"
}

test_log_is_valid_json_lines() {
  python3 -c '
import json, sys
for line in open(sys.argv[1]):
    json.loads(line)' "$HOME_DIR/state/intake/log.jsonl" || fail "log has an invalid line"
  pass "every log line is valid JSON"
}

fm_test_run \
  test_projects_root_links_and_scans \
  test_projects_root_refuses_real_clones \
  test_sessions_validate_routes \
  test_session_instructions_reach_the_brief \
  test_capture_needs_no_model \
  test_prefix_routing_and_fallback \
  test_delivery_into_session_home \
  test_redelivery_is_idempotent \
  test_ack_is_derived_from_target_handled \
  test_check_flags_lost_body \
  test_unroutable_session_fails_visibly \
  test_hook_blocks_prefixed_only \
  test_log_is_valid_json_lines
