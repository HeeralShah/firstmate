# Session context, compaction, and the session dashboard

A session can run for weeks, and a chat that holds its state in memory drifts: it forgets, merges two facts, or repeats a claim that stopped being true.
The design keeps one chat per topic by making the chat disposable: everything that matters lives on disk, scripts write the facts, and a compacted or restarted chat is rebuilt from disk instead of from its own summary of a summary.

## What controls drift, and what each control watches

Two different things can go wrong, and they have different clocks, so they have different controls:

| Problem | What drives it | Control | Trigger |
| --- | --- | --- | --- |
| The **chat** gets too large and starts to forget or blur facts | Context size in tokens | Compaction, then a rebuild from disk | Tokens (upstream's `config/stow-guard` `tokens=` and `config/warm-compact` `min-context-tokens=`) |
| A **stored fact** stops being true | Time and activity | Memory decay and review | Messages and size, with days only as a floor |

1. **State lives on disk, not in the chat.** The intake log, `data/sessions/<id>/plan.md`, the fleet snapshot, and read-only git queries are the record. Pages and cards are recomputed from them on every request.
2. **Scripts write facts; the model writes only claims.** Counts, branch heads, open decisions and message states come from scripts. The one model-authored status file is `summary.md`, and the card labels it a claim that the facts above it override.
3. **Rebuild, never trust, after compaction.** Upstream already re-emits context on `/clear` and compaction (`fm-sessionstart-run.sh` routes them to `fm-session-start.sh --reemit`, registered in `.claude/settings.json`). When `config/active-session` names this chat's session, that same digest includes `fm-dashboard.sh card <id> --rehydrate`: the session instructions plus a fresh state card behind a rule to trust it over remembered facts. No extra hook is needed. A secondmate home that backs a session needs `data/sessions` linked to the session folders.
4. **Compact on size, not on a calendar.** How soon a chat is compacted is a token threshold, and it is yours to set: `config/stow-guard` (`tokens=<n>`, default 300000 context tokens) asks for a `/stow` before compaction, and `config/warm-compact` compacts an idle session. A very active captain should set `tokens=` well below the default. These are upstream's knobs and this design reuses them unchanged.
5. **Keep the card small.** It is capped near 700 words and lists only what is unsettled; detail stays behind pointers.
6. **Verify at the seams.** `fm-intake.sh check` audits that no captured message is lost or stuck, and a claim in `summary.md` or a worker report is evidence, not truth, until the card's facts agree.

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

`memory.md` uses the stow entry format as trailing comments: aging (`<!--a:date-->`), perishable (`<!--p:date-->`), pinned (`<!--P-->`), and pending capture (`<!--t:NAME-->`, never archived). `/stow` covers it under the same tier rules (see the stow skill's "Session memory" section).
Staleness follows the pattern stow's optional pass horizon already uses, "whichever is reached first", but measures session activity: an aging entry is stale after `memory-stale-after-messages` (default 120) messages captured for the session since it was last reinforced, or `memory-stale-after-days` (30) days, and a perishable one after a quarter of the message limit or 7 days. A busy session therefore decays and reviews faster than a quiet one; calendar days are only a floor for quiet sessions, where facts rot with time rather than traffic.
A review is due on whichever comes first: `memory-review-every-messages` (40) messages since the last review, `memory-review-every-days` (14) days, or memory over `memory-max-words` (600). All five limits are `key: value` lines in the guide and the captain can set them per session.
`fm-session-memory.sh` owns the mechanics (dedupe on add, `reinforce`, `archive-stale` to `memory-archive.md` and never deletes, `review`, `reviewed`); what to remember, merge or rewrite stays the agent's judgment under the stow rules.
Decisions never decay: a `decided:` line stays until the captain reopens it, and the card and briefs tell the agent not to re-ask or contradict one.

## The guide

`guide.md` holds meta-rules about the session itself, not the task: how the captain wants answers shaped, how work is grouped and reported, and how often memory is reviewed.
Settings sit on `key: value` lines above the first `##` heading (the five memory limits above, and `answer-style: ...`), and `fm-session-memory.sh guide <id> add "<rule>"` appends a dated rule.
When the captain states a preference about how a session should run, the agent records it here as one line and rewrites the list down when it grows past about 25 rules, replacing superseded lines instead of piling up.
The state card always carries the guide, so a compacted chat keeps following it.
A due review shows on the card and the dashboard; the agent runs `/stow`, which covers the session memory, then `fm-session-memory.sh reviewed`.

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
