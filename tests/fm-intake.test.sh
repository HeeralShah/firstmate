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
for r in repoa repob; do git -C "$REPOS/$r" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init; done
printf -- '- repoa [local-only] - A (added 2026-11-20)\n' >"$HOME_DIR/data/projects.md"
printf -- '- quant-sm - quant model work (home: %s; scope: quant models; projects: repoa; added 2026-11-20)\n' \
  "$SM_HOME" >"$HOME_DIR/data/secondmates.md"
printf 'rules\n' >"$HOME_DIR/config/intake-triage"

export FM_HOME="$HOME_DIR"
export FM_INTAKE_NO_TRIAGE=1

test_projects_root_records_source_and_scans() {
  local scan
  "$PROOT" set "$REPOS" >/dev/null
  [ "$(cat "$HOME_DIR/config/projects-source")" = "$(cd "$REPOS" && pwd -P)" ] || fail "set did not record the source"
  [ ! -e "$HOME_DIR/projects" ] || fail "set must not create or link projects/"
  scan=$("$PROOT" scan)
  case "$scan" in
    *repoa*"registered"*repob*"not registered"*) ;;
    *) fail "scan output wrong: $scan" ;;
  esac
  if "$PROOT" set "$REPOS/nope" >/dev/null 2>&1; then fail "accepted a non-directory"; fi
  pass "projects root records the source folder, never links projects/, and scan reports registration"
}

test_session_checkout_clones_from_source() {
  local before after
  "$SESSIONS" add quant --summary "Quant model work" --kind theme --repos repoa,repob --home quant-sm >/dev/null
  before=$(git -C "$REPOS/repoa" status --porcelain | wc -l | tr -d ' ')
  git -C "$REPOS/repoa" remote add origin https://example.com/repoa.git 2>/dev/null || true
  "$ROOT/bin/fm-session-checkout.sh" create quant >/dev/null
  [ -e "$HOME_DIR/projects/repoa/quant/.git" ] || fail "no clone at projects/<repo>/<session>"
  [ -e "$HOME_DIR/data/sessions/quant/repos/repoa/.git" ] || fail "view symlink does not resolve to the clone"
  [ "$(git -C "$HOME_DIR/projects/repoa/quant" remote get-url origin)" = "https://example.com/repoa.git" ] || fail "origin not reset to the real remote"
  after=$(git -C "$REPOS/repoa" status --porcelain | wc -l | tr -d ' ')
  [ "$before" = "$after" ] || fail "source repo was modified"
  if "$ROOT/bin/fm-session-checkout.sh" create quant nope >/dev/null 2>&1; then fail "accepted a repo outside scope"; fi
  pass "session checkout clones projects/<repo>/<session> from the source, resets origin, builds the view, and leaves the source alone"
}

test_sessions_validate_routes() {
  "$SESSIONS" add chores --summary "Small fixes anywhere" --kind chores >/dev/null
  if "$SESSIONS" add ghost --summary "x" --kind theme --repos repoa --home nobody >/dev/null 2>&1; then
    fail "accepted an unknown secondmate"
  fi
  if "$SESSIONS" add bad --summary "x" --kind theme --repos nope >/dev/null 2>&1; then
    fail "accepted a repo outside the source folder"
  fi
  case "$("$SESSIONS" list)" in *quant*quant-sm*chores*) ;; *) fail "list wrong" ;; esac
  for f in instructions guide memory decisions plan; do [ -f "$HOME_DIR/data/sessions/quant/$f.md" ] || fail "missing stub $f.md"; done
  pass "sessions add validates secondmate and repos, creates the session folder, and list shows both"
}

test_session_instructions_reach_the_brief() {
  local ifile brief
  ifile=$("$SESSIONS" instructions quant)
  [ -r "$ifile" ] || fail "add did not create the instructions stub"
  printf '\nALWAYS_USE_ZSCORE_NORMALISATION\n' >>"$ifile"
  "$ROOT/bin/fm-session-memory.sh" add quant "REFERENCE_MODEL_B_IS_TRUSTED" >/dev/null
  printf -- '- 2026-11-20 D1: use log returns (M-9999)\n' >>"$HOME_DIR/data/sessions/quant/decisions.md"
  "$ROOT/bin/fm-brief.sh" t1 repoa --mode local-only --session quant >/dev/null 2>&1 || fail "brief with --session failed"
  brief=$(cat "$HOME_DIR/data/t1/brief.md")
  case "$brief" in *"Session instructions (quant)"*ALWAYS_USE_ZSCORE_NORMALISATION*"Decisions already made"*"use log returns"*"Session memory"*REFERENCE_MODEL_B_IS_TRUSTED*) ;; *) fail "brief lacks session instructions, decisions or memory" ;; esac
  if "$ROOT/bin/fm-brief.sh" t2 repoa --mode local-only --session nosuch >/dev/null 2>&1; then fail "brief accepted a session with no file"; fi
  pass "session instructions, decisions and memory are inlined into briefs, and a missing instructions file is refused"
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

test_answered_decision_is_logged_to_decisions_file() {
  local out
  cat >"$TMP_ROOT/snap.sh" <<'SNAP'
#!/usr/bin/env bash
printf '{"tasks":[{"id":"sharpe","kind":"ship","project":"repoa","current_state":{"state":"needs-decision"},"hints":{"open_decisions":[{"key":"D3","verb":"needs-decision","summary":"Use log or simple returns?"}]}}],"backlog":{"records":[]}}\n'
SNAP
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"%s/send.log"\n' "$TMP_ROOT" >"$TMP_ROOT/send.sh"
  chmod +x "$TMP_ROOT/snap.sh" "$TMP_ROOT/send.sh"
  export FM_SNAPSHOT_BIN="$TMP_ROOT/snap.sh" FM_SEND_BIN="$TMP_ROOT/send.sh"
  "$INTAKE" add "@quant D3: simple returns" >/dev/null
  "$INTAKE" triage M-0006
  unset FM_SNAPSHOT_BIN FM_SEND_BIN
  out=$(cat "$HOME_DIR/data/sessions/quant/decisions.md")
  case "$out" in *"D3: simple returns"*"[asked: Use log or simple returns?]"*"(M-0006)"*) ;; *) fail "decisions.md: $out" ;; esac
  grep -q "fm-sharpe --resolve-key D3 simple returns" "$TMP_ROOT/send.log" || fail "explicit rule answer was not applied through fm-send"
  case "$("$INTAKE" show M-0006)" in *applied*) ;; *) fail "message not marked applied" ;; esac
  "$INTAKE" route M-0006 quant >/dev/null
  [ "$(grep -c '(M-0006)' "$HOME_DIR/data/sessions/quant/decisions.md")" = 1 ] || fail "decision recorded twice"
  pass "an explicit decision answer is applied through fm-send, and recorded once in decisions.md with its question"
}

test_session_memory_tiers_decay_and_cadence() {
  local mem="$ROOT/bin/fm-session-memory.sh" out sd="$HOME_DIR/data/sessions/quant"
  "$mem" add quant --pin "PINNED_FACT" >/dev/null
  out=$("$mem" add quant "REFERENCE_MODEL_B_IS_TRUSTED")
  case "$out" in *"already remembered"*) ;; *) fail "duplicate not caught: $out" ;; esac
  printf -- '- OLD_FACT <!--a:2020-01-01-->\n' >>"$sd/memory.md"
  out=$("$mem" review quant)
  case "$out" in *"REVIEW DUE"*"stale (aging, 2020-01-01): OLD_FACT"*) ;; *) fail "review: $out" ;; esac
  "$mem" archive-stale quant >/dev/null
  grep -q OLD_FACT "$sd/memory-archive.md" || fail "stale entry not archived"
  grep -q OLD_FACT "$sd/memory.md" && fail "stale entry still in memory"
  grep -q PINNED_FACT "$sd/memory.md" || fail "pinned entry lost"
  "$mem" reviewed quant >/dev/null
  case "$("$mem" review quant)" in *"review not due"*) ;; *) fail "review still due right after a review" ;; esac
  sed -i.bak 's/^memory-review-every-messages:.*/memory-review-every-messages: 2/' "$sd/guide.md"
  "$INTAKE" add --session quant "activity one" >/dev/null
  "$INTAKE" add --session quant "activity two" >/dev/null
  case "$("$mem" review quant)" in *"REVIEW DUE"*"2 messages since the last review"*) ;; *) fail "activity did not make the review due: $("$mem" review quant)" ;; esac
  "$mem" reviewed quant >/dev/null
  sed -i.bak 's/^memory-max-words:.*/memory-max-words: 3/' "$sd/guide.md"
  case "$("$mem" review quant)" in *"REVIEW DUE"*"memory is"*"words (limit 3)"*) ;; *) fail "size did not make the review due" ;; esac
  sed -i.bak 's/^memory-max-words:.*/memory-max-words: 600/' "$sd/guide.md"
  "$mem" guide quant add "Answer outcome-first" >/dev/null
  grep -q "Answer outcome-first" "$sd/guide.md" || fail "guide rule not recorded"
  pass "session memory dedupes, archives stale entries without deleting, honours pins, and makes a review due on activity or size"
}

test_unknown_decision_key_is_never_recorded() {
  local before after out
  before=$(grep -c '^- ' "$HOME_DIR/data/sessions/quant/decisions.md" || true)
  "$INTAKE" add --session quant "D99: go with option C" >/dev/null
  out=$("$INTAKE" add --session quant "D99: go with option C" | sed 's/Queued //')
  "$INTAKE" triage "$out"
  after=$(grep -c '^- ' "$HOME_DIR/data/sessions/quant/decisions.md" || true)
  [ "$before" = "$after" ] || fail "an answer to a key nothing owns was recorded as decided"
  case "$("$INTAKE" show "$out")" in *apply_failed*delivered*) ;; *) fail "unknown key was not routed to the first mate: $("$INTAKE" show "$out")" ;; esac
  pass "an answer to an unknown decision key is delivered as a note and never recorded as decided"
}

test_handled_messages_read_as_settled_everywhere() {
  local id note
  id=$("$INTAKE" add "@chores tidy the readme" | sed 's/Queued //')
  "$INTAKE" triage "$id"
  mkdir -p "$HOME_DIR/state/inbox/handled"
  for note in "$HOME_DIR/state/inbox"/*.note; do [ -e "$note" ] && mv "$note" "$HOME_DIR/state/inbox/handled/"; done
  FM_SNAPSHOT_BIN="$TMP_ROOT/snap.sh" "$ROOT/bin/fm-dashboard.sh" card chores | grep -q "$id" && fail "card still lists a handled message as open"
  case "$("$INTAKE" list)" in *"$id"*) fail "list still shows a handled message" ;; esac
  pass "a message the target home handled reads as settled in the card and list without a manual sync"
}

test_hook_dedupes_double_registration() {
  local a b
  a=$(printf '{"session_id":"s1","prompt":">> same thing twice"}' | "$HOOK")
  b=$(printf '{"session_id":"s1","prompt":">> same thing twice"}' | "$HOOK")
  [ "$a" = "$b" ] || fail "two hooks for one prompt made two messages: $a / $b"
  a=$(printf '{"session_id":"s2","prompt":">> same thing twice"}' | "$HOOK")
  [ "$a" != "$b" ] || fail "a different session was wrongly deduped"
  pass "the same prompt seen by two registered hooks is one message, and another session's is not"
}

test_concurrent_triage_applies_once() {
  local id
  rm -f "$TMP_ROOT/send.log"
  export FM_SNAPSHOT_BIN="$TMP_ROOT/snap.sh" FM_SEND_BIN="$TMP_ROOT/send.sh"
  id=$("$INTAKE" add "@quant D3: log returns after all" | sed 's/Queued //')
  "$INTAKE" triage "$id" & "$INTAKE" triage "$id" & "$INTAKE" triage "$id" &
  wait
  unset FM_SNAPSHOT_BIN FM_SEND_BIN
  [ "$(grep -c 'resolve-key D3' "$TMP_ROOT/send.log")" = 1 ] || fail "decision applied $(grep -c 'resolve-key D3' "$TMP_ROOT/send.log") times"
  pass "three concurrent triages of one decision apply it exactly once"
}

test_session_clone_starts_on_default_branch() {
  "$SESSIONS" add feat --summary "Feature work" --kind theme --repos repob >/dev/null
  git -C "$REPOS/repob" checkout -q -b feature/wip
  "$ROOT/bin/fm-session-checkout.sh" create feat >/dev/null 2>&1
  git -C "$REPOS/repob" checkout -q -
  [ "$(git -C "$HOME_DIR/projects/repob/feat" rev-parse --abbrev-ref HEAD)" != feature/wip ] || fail "clone started on the source's feature branch"
  pass "a session clone starts on the repo's default branch, not whatever the source has checked out"
}

test_same_day_messages_do_not_age_new_facts() {
  local mem="$ROOT/bin/fm-session-memory.sh" i
  for i in $(seq 1 35); do "$INTAKE" add --session quant "busy $i" >/dev/null; done
  "$mem" add quant --perishable "FRESH_PERISHABLE_FACT" >/dev/null
  case "$("$mem" review quant)" in *FRESH_PERISHABLE_FACT*) fail "a fact recorded today is stale from earlier messages today" ;; esac
  pass "messages captured earlier the same day do not make a newly recorded fact stale"
}

test_hook_blocks_prefixed_only() {
  local out
  out=$(printf '{"prompt":">> remember pineapple"}' | "$HOOK")
  case "$out" in *'"decision": "block"'*"Queued M-"*) ;; *) fail "prefixed prompt: $out" ;; esac
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
  test_projects_root_records_source_and_scans \
  test_session_checkout_clones_from_source \
  test_sessions_validate_routes \
  test_session_instructions_reach_the_brief \
  test_capture_needs_no_model \
  test_prefix_routing_and_fallback \
  test_delivery_into_session_home \
  test_redelivery_is_idempotent \
  test_ack_is_derived_from_target_handled \
  test_check_flags_lost_body \
  test_unroutable_session_fails_visibly \
  test_answered_decision_is_logged_to_decisions_file \
  test_session_memory_tiers_decay_and_cadence \
  test_unknown_decision_key_is_never_recorded \
  test_handled_messages_read_as_settled_everywhere \
  test_hook_dedupes_double_registration \
  test_concurrent_triage_applies_once \
  test_session_clone_starts_on_default_branch \
  test_same_day_messages_do_not_age_new_facts \
  test_hook_blocks_prefixed_only \
  test_log_is_valid_json_lines
