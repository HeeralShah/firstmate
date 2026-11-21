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

## Turning a chat into a session

`/bind-session` (the `bind-session` skill) does this at the start of a chat, from the context given, or mid-chat, from what the chat has established.
It drafts the instructions, guide, memory and plan, surveys the repos the chat already changed, shows everything for one confirmation, writes the session through the scripts above, and binds the chat.
`/bind-session <id>` in a new chat resumes an existing session.
The skill works in a chat opened in any repository. It finds Firstmate from the current directory, `$FM_HOME`, a path saved in `~/.config/firstmate/home`, the repo its user-level link points to, or `~/Projects/firstmate` and `~/firstmate`, validating each candidate. If none is valid, it asks the captain for the path and offers to save it. Outside Firstmate it never runs the session-start digest, so it cannot take the fleet lock.

**Binding.** Claude Code passes each chat's id to hooks and tool shells as `CLAUDE_CODE_SESSION_ID`. `bin/fm-session-bind.sh` writes `state/session-bindings/<chat-id>`, and the session-start digest loads that chat's session card, falling back to `config/active-session`. Two chats in one home can therefore follow two different sessions. `/clear` starts a new chat id, so rebind after it.

**Existing work.** A chat may already hold committed and uncommitted work. `bin/fm-session-work.sh` carries it into the session without risk to it:
- `survey` only reads.
- `record` writes the ledger `work.md` and a patch copy of uncommitted tracked changes, and lists untracked files without copying them.
- `adopt` brings named committed branches into the session's own clone through a fetch-only remote, only after the captain approves that exact operation.

Nothing in an original repo is ever moved, stashed, reset, committed or deleted. Uncommitted work is restored by a worker, in its own isolated copy, from the recorded patch and base: `fm-brief.sh --session` includes the ledger.
Session clones keep the local source as a fetch-only `source` remote, so branches that were never pushed stay reachable.

**Hooks.** Inside the Firstmate repo no new hook is needed. The existing `SessionStart` hook runs the digest on startup, `/clear` and compaction and passes the chat id through. The existing `UserPromptSubmit` registration carries the intake hook. Upstream's opt-in `config/stow-guard` Stop hook already asks for `/stow` before compaction on a token threshold.

**Outside the Firstmate repo.** A chat in another repo has no Firstmate digest. If the skill is installed for the user (a link at `~/.claude/skills/bind-session`), register `bin/fm-session-card-hook.sh` as a user-level `SessionStart` hook in `~/.claude/settings.json`. It prints the card only for a chat bound in its own right, never the home default, and stays silent inside Firstmate, where the digest already prints it. Without it, a bound chat in another repo needs `/bind-session <id>` again after compaction.

## The layers of memory

| Layer | File | Holds | Written by |
| --- | --- | --- | --- |
| Repo maintainer rules | the repo's `AGENTS.md` | How to work in that repo | the captain only |
| Session instructions | `data/sessions/<id>/instructions.md` | Task-level guidance across repos | the captain |
| Session guide | `guide.md` | Meta-rules: interaction, organisation, answer style, review cadence | an agent, curated iteratively |
| Session memory | `memory.md` | Durable content: facts, findings, gotchas about the task | an agent, via `fm-session-memory.sh` |
| Session decisions | `decisions.md` | Decisions upstream accepted, with the question asked | `fm-intake.sh` only, after the answer was applied |
| Session state | `plan.md`, the log, the fleet snapshot | Progress and what is open | scripts, and the captain for the plan |
| Session summary | `summary.md` | A claim about where things stand | an agent, at checkpoints |
| Home preferences and facts | `captain.md`, `learnings.md` | The captain's working style; fleet-wide operational facts | upstream's stow rules |

Routing: knowledge about the task across repos goes to session memory; a rule about how the captain wants this session run goes to the guide; knowledge about one repo goes to that repo's `AGENTS.md`, which only the captain edits; the captain's style across all work goes to `captain.md`; fleet-wide operational facts go to `learnings.md`.

## Memory: tiers, decay, review

`memory.md` uses the stow entry format as trailing comments: aging (`<!--a:date-->`), perishable (`<!--p:date-->`), pinned (`<!--P-->`), and pending capture (`<!--t:NAME-->`, never archived). `/stow` covers it under the same tier rules (see the stow skill's "Session memory" section).
Day horizons match stow: an aging entry is stale at 30 days since it was last reinforced and a perishable one at 7 (`memory-stale-after-days` changes the aging one).
This layer also has a message horizon: an aging entry is stale after `memory-stale-after-messages` (default 120) messages captured for the session on later days, a perishable one after a quarter of that, whichever horizon comes first. Message volume does not make a fact false, so this horizon is under review; set it very high in the guide to rely on days and size alone.
A review is due on whichever comes first: `memory-review-every-messages` (40) messages since the last review, `memory-review-every-days` (14) days, or memory over `memory-max-words` (600). All five limits are `key: value` lines in the guide and the captain can set them per session.
`fm-session-memory.sh` owns the mechanics (dedupe on add, `reinforce`, `archive-stale` to `memory-archive.md` and never deletes, `review`, `reviewed`); what to remember, merge or rewrite stays the agent's judgment under the stow rules.
Decisions never decay: a recorded decision stays until the captain reopens it, and the card and briefs tell the agent not to re-ask or contradict one. Only decisions upstream accepted are recorded, so this rule cannot entrench a typo or a guess.

## The guide

`guide.md` holds meta-rules about the session itself, not the task: how the captain wants answers shaped, how work is grouped and reported, and how often memory is reviewed.
Settings sit on `key: value` lines above the first `##` heading (the five memory limits above, and `answer-style: ...`), and `fm-session-memory.sh guide <id> add "<rule>"` appends a dated rule.
When the captain states a preference about how a session should run, the agent records it here as one line and rewrites the list down when it grows past about 25 rules, replacing superseded lines instead of piling up.
The state card always carries the guide, so a compacted chat keeps following it.
A due review shows on the card and the dashboard; the agent runs `/stow`, which covers the session memory, then `fm-session-memory.sh reviewed`.

## The dashboard

`fm-dashboard.sh serve` starts a loopback-only server (default `http://127.0.0.1:8787`, or `config/dashboard-port`).
`/` lists sessions; `/s/<id>` is the session page, top to bottom: attention tiles, a progress bar and step cards, the **Decisions** section, the session summary, memory and guide, workers, code changes (each task branch the fleet snapshot records, diffed in its own work copy), and messages.
Open decisions come from the fleet snapshot (a worker's open keyed decision, or a captain-held task) and are filtered to the session's repos where the record names one.
Each has a text box and Send, Approve, and Reject buttons. A click POSTs to the server, which logs the answer through `fm-intake.sh` and applies it at once through `fm-send --resolve-key` or `fm-captain-hold.sh answers`; the page says whether it was applied or, if not, why it was routed to the first mate instead. A note box queues a fire-and-forget message.
If the fleet snapshot fails or times out, the page and the card say so instead of showing an empty, all-clear fleet.
The state card keeps under about 700 words by dropping whole items from its lowest-priority sections first (summary, then branches, then progress and workers) and naming what it omitted; open decisions, decisions already made and the guide are kept longest, then session memory and open messages.
The page re-fetches every 15 seconds without disturbing a focused text box and shows a red banner if the server stops answering, so a stale page announces itself. `fm-dashboard.sh render <id> --out file.html` writes a static read-only snapshot.
The server binds to 127.0.0.1 only, refuses any request whose `Host` is not a loopback name, and accepts a POST only with an `X-FM-Dashboard` header and a loopback origin.

## Limits

- Decision buttons log the answer and route it; the receiving firstmate still acts on it and records the resolution under the usual authority rules.
- Workers and decisions come from the session home's fleet snapshot; a captain-held task that names no repo shows on every session of that home.
- Code changes are read-only git queries on each task's recorded work copy or project clone.
