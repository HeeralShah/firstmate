# Session context, compaction, and the session dashboard

A session can run for weeks, and a chat that holds its state in memory drifts: it forgets, merges two facts, or repeats a claim that stopped being true.
The design keeps one chat per topic by making the chat disposable: everything that matters lives on disk, scripts write the facts, and a compacted or restarted chat is rebuilt from disk instead of from its own summary of a summary.

## The rules

1. **State lives on disk, not in the chat.** The intake log, `data/sessions/<id>/plan.md`, the session home's `state/*.status` lines, and read-only git queries are the record. Pages and cards are recomputed from them on every request, and the card now also carries the guide, decisions already made, and session memory.
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

## The layers of memory

| Layer | File | Holds | Written by |
| --- | --- | --- | --- |
| Repo maintainer rules | the repo's `AGENTS.md` | How to work in that repo | the captain only |
| Session instructions | `data/sessions/<id>/instructions.md` | Task-level guidance across repos | the captain |
| Session guide | `guide.md` | Meta-rules: interaction, organisation, answer style, review cadence | an agent, curated iteratively |
| Session memory | `memory.md` | Durable content: facts, findings, gotchas about the task | an agent, via `fm-session-memory.sh` |
| Session decisions | `decisions.md` | Answered decisions, with the question asked | `fm-intake.sh` only |
| Session state | `plan.md`, the log, status lines | Progress and what is open | scripts, and the captain for the plan |
| Session summary | `summary.md` | A claim about where things stand | an agent, at checkpoints |
| Home preferences and facts | `captain.md`, `learnings.md` | The captain's working style; fleet-wide operational facts | upstream's stow rules |

Routing: knowledge about the task across repos goes to session memory; a rule about how the captain wants this session run goes to the guide; knowledge about one repo goes to that repo's `AGENTS.md`, which only the captain edits; the captain's style across all work goes to `captain.md`; fleet-wide operational facts go to `learnings.md`.

## Memory: tiers, decay, review

`memory.md` uses the stow entry format as trailing comments: aging (`<!--a:date-->`), perishable (`<!--p:date-->`), pinned (`<!--P-->`), and pending capture (`<!--t:NAME-->`, never archived).
`fm-session-memory.sh` owns the mechanics: it dedupes on add, `reinforce` refreshes a date, `archive-stale` moves aging entries older than `memory-stale-after` (default 30 days) and perishable ones older than 14 days to `memory-archive.md` (never deleted), and `review` reports whether a review is due and which entries are stale.
What to remember, merge or rewrite stays the agent's judgment under the stow rules; the script only reports and moves.
Decisions never decay: a `decided:` line stays until the captain reopens it, and the card and briefs tell the agent not to re-ask or contradict one.

## The guide

`guide.md` holds meta-rules about the session itself, not the task: how the captain wants answers shaped, how work is grouped and reported, and how often memory is reviewed.
Settings sit on `key: value` lines before the first heading (`memory-review-every: 7d`, `memory-stale-after: 30d`, `answer-style: ...`), and `fm-session-memory.sh guide <id> add "<rule>"` appends a dated rule.
When the captain states a preference about how a session should run, the agent records it here as one line and rewrites the list down when it grows past about 25 rules, replacing superseded lines instead of piling up.
The state card always carries the guide, so a compacted chat keeps following it.
A due review shows on the card and the dashboard; the agent runs `review`, curates, then `reviewed`.

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
