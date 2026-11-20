# Session context, compaction, and the session dashboard

A session can run for weeks, and a chat that holds its state in memory drifts: it forgets, merges two facts, or repeats a claim that stopped being true.
The design keeps one chat per topic by making the chat disposable: everything that matters lives on disk, scripts write the facts, and a compacted or restarted chat is rebuilt from disk instead of from its own summary of a summary.

## The rules

1. **State lives on disk, not in the chat.** The intake log, `data/sessions/<id>/plan.md`, the session home's `state/*.status` lines, and read-only git queries are the record. Pages and cards are recomputed from them on every request.
2. **Scripts write facts; the model writes only claims.** Counts, branch heads, open decisions, and message states come from scripts. The one model-authored file is `data/sessions/<id>/summary.md`, written at checkpoints, and the card labels it a claim that the facts above it override.
3. **Rebuild, never trust, after compaction.** `fm-dashboard.sh card <id> --rehydrate` prints the session instructions plus a fresh state card behind a rule: trust this over anything remembered, and re-check any fact the card does not confirm. Wire it to a Claude Code `SessionStart` hook with matcher `compact` (and `startup`/`resume`) so every compaction ends with the card in context:

   ```json
   { "hooks": { "SessionStart": [ { "matcher": "compact",
       "hooks": [ { "type": "command",
         "command": "FM_HOME=/abs/firstmate /abs/firstmate/bin/fm-dashboard.sh card quant --rehydrate" } ] } ] } }
   ```

   Firstmate never edits `~/.claude/settings.json`; the captain adds the hook per session id.
4. **Keep the card small.** It is capped near 700 words and lists only what is not settled: unaccepted steps, open decisions, open messages, latest worker status, and branch heads. Detail stays behind pointers (files, the log, the dashboard), so the chat carries references, not copies.
5. **Compact early, at a checkpoint.** Before a planned compaction, update `summary.md` (and tick `plan.md`) so the claim layer is current; upstream's warm-cache compaction and `/stow` already handle timing and memory curation.
6. **Verify at the seams.** `fm-intake.sh check` audits that no captured message is lost or stuck. A claim in `summary.md` or a worker report is evidence, not truth, until the card's facts agree with it.

## Files

| File | Written by | Holds |
| --- | --- | --- |
| `data/sessions.md` | `fm-sessions.sh` | The route: kind, repos, home |
| `data/sessions/<id>.md` | the captain | Task-level instructions across repos |
| `data/sessions/<id>/plan.md` | captain or worker | Steps as `- [ ]` todo, `[~]` in review, `[!]` blocked, `[x]` accepted |
| `data/sessions/<id>/summary.md` | an agent, at checkpoints | A short claim about where things stand |
| `state/intake/log.jsonl` | `fm-intake.sh` | Every message and decision, append-only |

## The dashboard

`fm-dashboard.sh serve` starts a loopback-only server (default `http://127.0.0.1:8787`, or `config/dashboard-port`).
`/` lists sessions; `/s/<id>` is the session page, top to bottom: attention tiles, a progress bar and step cards, the **Decisions** section, the session summary, workers, code changes (each `fm/*` branch with commits ahead and changed files by directory), and messages.
Decisions are made only here: each open decision (a `needs-decision [key=...]` status line) has a text box and Send, Approve, and Reject buttons. A click POSTs to the server, which logs a message through `fm-intake.sh` routed to that session as an `answer <key>: ...` decision, so the answer is a durable event and the decision leaves the page. A note box queues a fire-and-forget message the same way.
The page re-fetches every 15 seconds without disturbing a focused text box and shows a red banner if the server stops answering, so a stale page announces itself. `fm-dashboard.sh render <id> --out file.html` writes a static read-only snapshot.
POSTs need an `X-FM-Dashboard` header and a loopback origin, and the server binds to 127.0.0.1 only.

## Limits

- Decision buttons log the answer and route it; the receiving firstmate still acts on it and records the resolution under the usual authority rules.
- Worker status is read from the session's home `state/*.status`; a session backed by the primary home shows that home's workers.
- Code changes are read-only git queries on repos under the projects root; worktrees outside it are not scanned.
